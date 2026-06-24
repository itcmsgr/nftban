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

echo "== MIGRATION GUARD: no direct 'source *.conf.local ... || true' sites remain (outside helper/tests) =="
stray="$(grep -rnE 'source[[:space:]].*\.conf\.local' "$REPO_LIB" 2>/dev/null | grep -vE '/tests/|lib/env\.sh:|_source_local|^\s*#|meta:' || true)"
if [ -z "$stray" ]; then ok "0 direct source-.local call sites remain (all routed through _source_local)"; else no "stray direct source-.local sites:"; echo "$stray"; fi

rm -rf "$_tmproot" /tmp/cl_w1 /tmp/cl_w2 2>/dev/null || true
echo "-----------------------------------------------"
echo "CONFIG_LOCAL IMPL-1 tests: $P passed, $F failed"
[ "$F" -eq 0 ]
