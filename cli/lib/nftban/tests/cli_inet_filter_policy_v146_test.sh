#!/usr/bin/env bash
# =============================================================================
# NFTBan - CVE-2025-NFTBAN-001 inet-filter classify-then-act test (v1.146 Phase-D)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cli_inet_filter_policy_v146_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-03"
# meta:description="v1.146 Phase-D — asserts the shared CVE-2025-NFTBAN-001 inet-filter classifier and the deliberate DEB/RPM divergence in the terminal 'refuse' action. (1) Functional: the classifier (extracted from packaging/deb/postinst sentinels) returns NONE when no inet filter exists, REMOVED + issues `nft delete` for the empty default distro skeleton, and POPULATED + does NOT delete when operator rules are present — exercised via a PATH-shadow nft stub. (2) Divergence: DEB postinst refuses a populated fresh install with `exit 1` and never deletes operator rules; RPM %post (packaging/build_nftban.sh) carries the verbatim skip-activation runbook message and exits 0 (rpm %post cannot cleanly abort). (3) Both files define the classifier. Hermetic — PATH-shadow nft stub, no real nft, no daemon, no host mutation."
# meta:input="packaging/deb/postinst, packaging/build_nftban.sh"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,awk,grep"
# meta:inventory.files="packaging/deb/postinst,packaging/build_nftban.sh"
# meta:inventory.binaries="bash,awk,grep"
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

POSTINST="$REPO/packaging/deb/postinst"
BUILD="$REPO/packaging/build_nftban.sh"
for f in "$POSTINST" "$BUILD"; do
    [[ -f "$f" ]] || { echo "FAIL: missing $f"; exit 1; }
done

REQUIRED_MSG='nftban installed but firewall activation was skipped because an operator-owned inet filter table exists. Remove or migrate the conflicting table, then run: nftban-installer --repair'

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

# --- Extract the classifier from postinst sentinels and source it ----------
FN="$TMPD/classify.sh"
awk '/# >>> NFTBAN_INETFILTER_FN_BEGIN >>>/{f=1;next} /# <<< NFTBAN_INETFILTER_FN_END <<</{f=0} f' "$POSTINST" > "$FN"
if [[ -s "$FN" ]] && grep -q '_nftban_classify_inet_filter' "$FN"; then
    ok "T0 extracted _nftban_classify_inet_filter from postinst sentinels"
else
    no "T0 extracted _nftban_classify_inet_filter from postinst sentinels" "extract empty"
fi

# --- PATH-shadow nft stub --------------------------------------------------
BIN="$TMPD/bin"; mkdir -p "$BIN"
cat > "$BIN/nft" <<'STUB'
#!/bin/sh
# Fixture-driven nft stub. NFT_FIXTURE: none|empty|populated.
# Records `delete` calls to NFT_DELETE_MARKER.
op="$1 $2 $3 $4"
case "$op" in
    "list table inet filter")
        case "${NFT_FIXTURE:-none}" in
            none) exit 1 ;;
            empty)
                printf '%s\n' 'table inet filter {' \
                    '	chain input {' \
                    '		type filter hook input priority 0; policy accept;' \
                    '	}' \
                    '	chain forward {' \
                    '		type filter hook forward priority 0; policy accept;' \
                    '	}' \
                    '}'
                exit 0 ;;
            populated)
                printf '%s\n' 'table inet filter {' \
                    '	chain input {' \
                    '		type filter hook input priority 0; policy drop;' \
                    '		tcp dport 22 accept' \
                    '		ct state established,related accept' \
                    '	}' \
                    '}'
                exit 0 ;;
        esac ;;
    "delete table inet filter")
        echo deleted >> "${NFT_DELETE_MARKER:-/dev/null}"; exit 0 ;;
esac
exit 0
STUB
chmod +x "$BIN/nft"

# shellcheck source=/dev/null
. "$FN"

run_classify() { # fixture -> echoes verdict; resets delete marker
    NFT_DELETE_MARKER="$TMPD/deleted"; : > "$NFT_DELETE_MARKER"
    export NFT_DELETE_MARKER NFT_FIXTURE="$1"
    PATH="$BIN:$PATH" _nftban_classify_inet_filter
}

# --- T-F: functional classification ----------------------------------------
v=$(run_classify none)
[[ "$v" == "NONE" ]] && ok "T-F1 no inet filter -> NONE" || no "T-F1 no inet filter -> NONE" "got '$v'"

v=$(run_classify empty)
if [[ "$v" == "REMOVED" ]]; then ok "T-F2 empty skeleton -> REMOVED"; else no "T-F2 empty skeleton -> REMOVED" "got '$v'"; fi
if [[ -s "$TMPD/deleted" ]]; then ok "T-F3 empty skeleton issued nft delete"; else no "T-F3 empty skeleton issued nft delete" "no delete recorded"; fi

v=$(run_classify populated)
if [[ "$v" == "POPULATED" ]]; then ok "T-F4 populated table -> POPULATED"; else no "T-F4 populated table -> POPULATED" "got '$v'"; fi
if [[ ! -s "$TMPD/deleted" ]]; then ok "T-F5 populated table NOT deleted (operator content preserved)"; else no "T-F5 populated table NOT deleted" "delete was recorded"; fi

# --- T-D: DEB refuse semantics ---------------------------------------------
if grep -q 'will NOT delete operator-owned' "$POSTINST" && grep -qE '^\s*exit 1' "$POSTINST"; then
    ok "T-D1 postinst refuses populated fresh install (exit 1, no delete)"
else
    no "T-D1 postinst refuses populated fresh install" "missing refuse path"
fi
if grep -q '_nftban_classify_inet_filter' "$POSTINST"; then
    ok "T-D2 postinst defines + uses the classifier"
else
    no "T-D2 postinst defines + uses the classifier" "missing"
fi

# --- T-R: RPM skip-activation semantics ------------------------------------
if grep -Fq "$REQUIRED_MSG" "$BUILD"; then
    ok "T-R1 build_nftban.sh %post carries the verbatim skip-activation runbook"
else
    no "T-R1 build_nftban.sh %post carries the verbatim skip-activation runbook" "message missing/altered"
fi
if grep -q '_nftban_classify_inet_filter' "$BUILD"; then
    ok "T-R2 build_nftban.sh defines the classifier (RPM previously had none)"
else
    no "T-R2 build_nftban.sh defines the classifier" "missing"
fi

echo
echo "=== RESULT: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    printf 'FAILED: %s\n' "${FAILED[@]}"
    exit 1
fi
exit 0
