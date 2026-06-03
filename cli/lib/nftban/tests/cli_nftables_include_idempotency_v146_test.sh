#!/usr/bin/env bash
# =============================================================================
# NFTBan - nftables.conf fenced-include idempotency test (v1.146 Phase-D)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cli_nftables_include_idempotency_v146_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-03"
# meta:description="v1.146 Phase-D — asserts the fenced nftban include marker is the single contract shared by the Go writer (internal/installer/render/sysconf.go), the DEB remover (packaging/deb/postrm) and the RPM %postun remover (packaging/build_nftban.sh). (1) Contract: both marker strings + the legacy comment string appear verbatim in all three files. (2) Functional: the postrm strip function (extracted between its sentinels) removes a stale fenced block, every legacy comment, and every stray include from a polluted distro nftables.conf, collapses accumulated duplicates, preserves all operator content (flush ruleset + table inet filter), and is idempotent. (3) Structural: postrm purge AND remove branches both call the strip fn (the remove-branch dangling-include gap fix), and the pre-v1.146 loose 'sed /nftban/d' is gone from both postrm and build_nftban.sh. (4) Syntax: sh -n postrm clean. Hermetic — no host contact, no nft, no daemon."
# meta:input="internal/installer/render/sysconf.go, packaging/deb/postrm, packaging/build_nftban.sh"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,awk,grep,sh"
# meta:inventory.files="internal/installer/render/sysconf.go,packaging/deb/postrm,packaging/build_nftban.sh"
# meta:inventory.binaries="bash,awk,grep,sh"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

GO="$REPO/internal/installer/render/sysconf.go"
POSTRM="$REPO/packaging/deb/postrm"
BUILD="$REPO/packaging/build_nftban.sh"
for f in "$GO" "$POSTRM" "$BUILD"; do
    [[ -f "$f" ]] || { echo "FAIL: missing $f"; exit 1; }
done

BEGIN_MARKER='# >>> nftban firewall include (managed; do not edit between markers) >>>'
END_MARKER='# <<< nftban firewall include (managed) <<<'
LEGACY='# NFTBan firewall configuration'
INCLUDE='include "/etc/nftban/nftables.conf"'

# ──────────────────────────────────────────────────────────────────────────
# Section 1: contract — markers shared verbatim across all three files
# ──────────────────────────────────────────────────────────────────────────
for label in "BEGIN:$BEGIN_MARKER" "END:$END_MARKER" "LEGACY:$LEGACY"; do
    name="${label%%:*}"; needle="${label#*:}"
    for f in "$GO" "$POSTRM" "$BUILD"; do
        base=$(basename "$f")
        if grep -Fq "$needle" "$f"; then
            ok "T1 $name marker present in $base"
        else
            no "T1 $name marker present in $base" "missing"
        fi
    done
done

# ──────────────────────────────────────────────────────────────────────────
# Section 2: functional — extract postrm strip fn and exercise it
# ──────────────────────────────────────────────────────────────────────────
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

FN="$TMPD/strip_fn.sh"
awk '/# >>> NFTBAN_STRIP_FN_BEGIN >>>/{f=1;next} /# <<< NFTBAN_STRIP_FN_END <<</{f=0} f' "$POSTRM" > "$FN"
if [[ -s "$FN" ]] && grep -q '_nftban_strip_conf_include' "$FN"; then
    ok "T2-0 extracted _nftban_strip_conf_include from postrm sentinels"
else
    no "T2-0 extracted _nftban_strip_conf_include from postrm sentinels" "extract empty"
fi
# shellcheck source=/dev/null
. "$FN"

SAMPLE="$TMPD/nftables.conf"
{
    printf '%s\n' '#!/usr/sbin/nft -f'
    printf '%s\n' ''
    printf '%s\n' 'flush ruleset'
    printf '%s\n' ''
    printf '%s\n' 'table inet filter {'
    printf '%s\n' '	chain input {'
    printf '%s\n' '		type filter hook input priority 0;'
    printf '%s\n' '	}'
    printf '%s\n' '}'
    # stale fenced block
    printf '%s\n' "$BEGIN_MARKER"
    printf '%s\n' "$INCLUDE"
    printf '%s\n' "$END_MARKER"
    # accumulated legacy duplicates (the pre-v1.146 bug)
    printf '%s\n' "$LEGACY"
    printf '%s\n' "$INCLUDE"
    printf '%s\n' "$LEGACY"
    printf '%s\n' "$INCLUDE"
} > "$SAMPLE"

_nftban_strip_conf_include "$SAMPLE"

if ! grep -Fq "$BEGIN_MARKER" "$SAMPLE" && ! grep -Fq "$END_MARKER" "$SAMPLE"; then
    ok "T2-1 fenced markers removed"
else
    no "T2-1 fenced markers removed" "marker survived"
fi
if ! grep -Fq "$LEGACY" "$SAMPLE"; then
    ok "T2-2 all legacy comments removed (dupes collapsed)"
else
    no "T2-2 all legacy comments removed (dupes collapsed)" "$(grep -cF "$LEGACY" "$SAMPLE") left"
fi
if ! grep -Fq '/etc/nftban/nftables.conf' "$SAMPLE"; then
    ok "T2-3 all include directives removed"
else
    no "T2-3 all include directives removed" "include survived"
fi
operator_ok=1
for must in 'flush ruleset' 'table inet filter' 'type filter hook input priority 0;'; do
    grep -Fq "$must" "$SAMPLE" || operator_ok=0
done
if [[ $operator_ok -eq 1 ]]; then
    ok "T2-4 operator content preserved (flush ruleset + inet filter)"
else
    no "T2-4 operator content preserved (flush ruleset + inet filter)" "lost a distro line"
fi
# idempotent: second strip changes nothing
BEFORE=$(cat "$SAMPLE"); _nftban_strip_conf_include "$SAMPLE"; AFTER=$(cat "$SAMPLE")
if [[ "$BEFORE" == "$AFTER" ]]; then
    ok "T2-5 strip is idempotent"
else
    no "T2-5 strip is idempotent" "second run changed output"
fi

# ──────────────────────────────────────────────────────────────────────────
# Section 3: structural — both branches call the fn; loose sed is gone
# ──────────────────────────────────────────────────────────────────────────
# purge + remove branches: count calls (expect >=2: one per branch loop)
calls=$(grep -cE '_nftban_strip_conf_include "\$nft_conf"' "$POSTRM" || true)
if [[ "${calls:-0}" -ge 2 ]]; then
    ok "T3-1 postrm calls strip fn in both purge and remove branches ($calls)"
else
    no "T3-1 postrm calls strip fn in both purge and remove branches" "only $calls call(s)"
fi
# Match only ACTIVE (non-comment) lines — explanatory comments may still name
# the old loose sed without it being live code.
active_sed_postrm=$(grep -E "sed -i '/nftban/d'" "$POSTRM" | grep -vE '^[[:space:]]*#' || true)
if [[ -z "$active_sed_postrm" ]]; then
    ok "T3-2 loose 'sed /nftban/d' gone from active postrm code"
else
    no "T3-2 loose 'sed /nftban/d' gone from active postrm code" "$active_sed_postrm"
fi
active_sed_build=$(grep -E "sed -i '/nftban/d'" "$BUILD" | grep -vE '^[[:space:]]*#' || true)
if [[ -z "$active_sed_build" ]]; then
    ok "T3-3 loose 'sed /nftban/d' gone from active build_nftban.sh (%postun) code"
else
    no "T3-3 loose 'sed /nftban/d' gone from active build_nftban.sh (%postun) code" "$active_sed_build"
fi

# ──────────────────────────────────────────────────────────────────────────
# Section 4: syntax
# ──────────────────────────────────────────────────────────────────────────
if sh -n "$POSTRM" 2>/dev/null; then
    ok "T4-1 sh -n postrm clean"
else
    no "T4-1 sh -n postrm clean" "syntax error"
fi

# ──────────────────────────────────────────────────────────────────────────
echo
echo "=== RESULT: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    printf 'FAILED: %s\n' "${FAILED[@]}"
    exit 1
fi
exit 0
