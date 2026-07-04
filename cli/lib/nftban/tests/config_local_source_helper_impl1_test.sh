#!/usr/bin/env bash
# =============================================================================
# NFTBan CONFIG_LOCAL_RECOVERY IMPL-1 — _source_local helper + migration guard
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="config_local_source_helper_impl1_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-24"
# meta:description="IMPL-1: central _source_local (bash -n gate, bypass, no partial-apply, warn-once) + guard that no direct 'source *.conf.local || true' call sites remain outside the helper."
# meta:input="env.sh _source_local + repo grep"
# meta:output="PASS/FAIL per assertion; nonzero exit on any FAIL"
# meta:depends="bash,grep"
# meta:inventory.files="cli/lib/nftban/lib/env.sh"
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR,NFTBAN_IGNORE_LOCAL_CONFIG"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_LIB="$(cd "$SCRIPT_DIR/.." && pwd)"   # .../cli/lib/nftban
export NFTBAN_LIB_DIR="$REPO_LIB"
# Guards scan the WHOLE cli/ tree (lib + sbin/bin entry scripts), not just cli/lib/nftban —
# the original IMPL-1 miss was cli/sbin/nftban (the dispatcher), outside cli/lib/nftban.
SCAN_ROOT="$(cd "$REPO_LIB/../.." && pwd)"   # .../cli
_tmproot="$(mktemp -d)"
export NFTBAN_CONFIG_DIR="$_tmproot/etc/nftban"
mkdir -p "$NFTBAN_CONFIG_DIR/conf.d"
P=0; F=0
ok(){ P=$((P+1)); echo "  PASS: $1"; }
no(){ F=$((F+1)); echo "  FAIL: $1"; }

# Load the helper (preset NFTBAN_CONFIG_LOADED so env.sh skips its own config read).
NFTBAN_CONFIG_LOADED=pretend source "$NFTBAN_LIB_DIR/lib/env.sh"
type _source_local >/dev/null 2>&1 && ok "_source_local helper defined by env.sh" || { no "_source_local NOT defined"; echo "RESULT: $P passed, $((F)) failed"; exit 1; }

echo "== missing .local => silent success, no change =="
BASEVAR=base; _source_local "$NFTBAN_CONFIG_DIR/conf.d/none.conf.local"; rc=$?
{ [ "$BASEVAR" = base ] && [ "$rc" -eq 0 ]; } && ok "missing .local: silent, return 0" || no "missing .local"

echo "== good .local overrides base (semantics preserved) =="
printf 'MYVAR="from_local"\n' > "$NFTBAN_CONFIG_DIR/conf.d/g.conf.local"
MYVAR="base"; _source_local "$NFTBAN_CONFIG_DIR/conf.d/g.conf.local"
[ "$MYVAR" = "from_local" ] && ok "good .local overrides base" || no "good .local override (got '$MYVAR')"

echo "== broken .local: NOT sourced, NO partial-apply, warn ONCE, non-fatal =="
printf 'BEFORE="leaked"\nthis is a (((syntax error\nAFTER="applied"\n' > "$NFTBAN_CONFIG_DIR/conf.d/b.conf.local"
BEFORE="orig"; AFTER="orig"
_source_local "$NFTBAN_CONFIG_DIR/conf.d/b.conf.local" 2>/tmp/cl_w1; rc=$?
[ "$rc" -eq 0 ] && ok "broken .local returns 0 (non-fatal)" || no "broken .local non-zero"
[ "$BEFORE" = "orig" ] && ok "no partial-apply: var before error not leaked" || no "PARTIAL-APPLY: BEFORE='$BEFORE'"
[ "$AFTER" = "orig" ] && ok "var after error not applied" || no "AFTER applied"
grep -q "WARNING: skipping malformed" /tmp/cl_w1 && ok "one actionable WARN emitted" || no "no WARN emitted"
_source_local "$NFTBAN_CONFIG_DIR/conf.d/b.conf.local" 2>/tmp/cl_w2
[ ! -s /tmp/cl_w2 ] && ok "warn-once (2nd inline call silent)" || no "warned more than once"

echo "== bypass: NFTBAN_IGNORE_LOCAL_CONFIG=1 skips all .local =="
MYVAR="base"; NFTBAN_IGNORE_LOCAL_CONFIG=1 _source_local "$NFTBAN_CONFIG_DIR/conf.d/g.conf.local"
[ "$MYVAR" = "base" ] && ok "bypass: good .local NOT sourced under NFTBAN_IGNORE_LOCAL_CONFIG=1" || no "bypass failed (MYVAR='$MYVAR')"

echo "== MIGRATION GUARD A: no LITERAL 'source .../*.conf.local' sites remain (outside helper/tests) =="
stray="$(grep -rnE 'source[[:space:]].*\.conf\.local' "$SCAN_ROOT" 2>/dev/null | grep -vE '/tests/|lib/env\.sh:|_source_local|^\s*#|meta:' || true)"
if [ -z "$stray" ]; then ok "0 literal source-.local sites remain (all routed through _source_local)"; else no "stray literal source-.local sites:"; echo "$stray"; fi

echo "== MIGRATION GUARD B: no VARIABLE-INDIRECT 'source \"\$VAR\"' where VAR is a .local path (completion regression) =="
# Closes the IMPL-1 false-pass blind spot: a var assigned a *.local path that is bare-sourced
# (e.g. service_control.sh: source \"\$NFTBAN_SERVICES_LOCAL\"; cmd_update.sh: config_local=\"\${config_file}.local\").
strayv=0
while IFS= read -r f; do
    # vars whose assignment RHS ends in .local (covers x.conf.local AND \${base}.local)
    vars="$(grep -oE '^[[:space:]]*(local |readonly |export )?[A-Za-z_][A-Za-z0-9_]*=.*\.local"?[[:space:]]*$' "$f" 2>/dev/null \
            | sed -E 's/^[[:space:]]*(local |readonly |export )?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/' | sort -u || true)"
    for v in $vars; do
        if grep -qE "(^|[[:space:]]|&&)[[:space:]]*(source|\.)[[:space:]]+\"\\\$\{?${v}\}?\"" "$f" 2>/dev/null; then
            strayv=$((strayv+1)); echo "    STRAY: ${f#"$REPO_LIB"/} bare-sources \$$v (a .local-holding var) — must use _source_local"
        fi
    done
done < <(grep -rlE 'source[[:space:]]|\. "$' "$SCAN_ROOT" 2>/dev/null | grep -vE '/tests/')
[ "$strayv" -eq 0 ] && ok "0 variable-indirected .local source sites remain (all routed through _source_local)" || no "$strayv variable-indirected .local source site(s) still bare"

echo "== REGRESSION: broken .local via VARIABLE indirection — skipped whole, no leak (the false-pass class) =="
printf 'NFTBAN_ENABLED="false"\n((( broken\n' > "$NFTBAN_CONFIG_DIR/conf.d/svc.conf.local"
NFTBAN_ENABLED="base"; _svc_local="$NFTBAN_CONFIG_DIR/conf.d/svc.conf.local"   # var holds the .local path
_source_local "$_svc_local" 2>/tmp/cl_w3
[ "$NFTBAN_ENABLED" = "base" ] && ok "variable-indirected broken .local skipped whole — NFTBAN_ENABLED=false did NOT leak" || no "var-indirect partial-apply leaked (NFTBAN_ENABLED='$NFTBAN_ENABLED')"
grep -q "skipping malformed" /tmp/cl_w3 && ok "WARN emitted for var-indirected broken .local" || no "no WARN (var-indirect)"

rm -rf "$_tmproot" /tmp/cl_w1 /tmp/cl_w2 /tmp/cl_w3 2>/dev/null || true
echo "-----------------------------------------------"
echo "CONFIG_LOCAL IMPL-1 tests: $P passed, $F failed"
[ "$F" -eq 0 ]
