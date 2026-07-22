#!/usr/bin/env bash
# =============================================================================
# NFTBan - Trust-Feeds status label truth test (v1.211.1 STATUS_LABEL_TRUTH)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cli_trustfeeds_label_truth_v211_1_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-30"
# meta:description="v1.211.1 STATUS_LABEL_TRUTH — asserts the Trust-Feeds status block in cmd_status.sh resolves nftban-core at its installed path (not a bare command -v, which falsely yields NOT INSTALLED because the binary ships in /usr/lib/nftban/bin, off PATH) and counts ENABLED providers from the stable `trust list --json` ('enabled': true) rather than grepping the human text for the word 'enabled' (which false-matches the help line '...apply all enabled'). The REAL block is extracted from the shipped cmd_status.sh at runtime and driven against a stub nftban-core: 2 enabled -> ENABLED (2 feeds); 0 enabled -> DISABLED; absent core -> NOT INSTALLED; malformed JSON -> UNKNOWN; and a json containing the literal word 'enabled' but zero enabled:true must render DISABLED (no false positive)."
# meta:input="cli/lib/nftban/cli/cmd_status.sh Trust-Feeds block"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,sed,grep"
# meta:inventory.files="cli/lib/nftban/cli/cmd_status.sh"
# meta:inventory.binaries="bash,sed,grep"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="cli_trustfeeds_label_truth_v211_1_test"
# meta:ta.owner="trust"
# meta:ta.module="trust-feeds-status"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)
STATUS_SH="$REPO/cli/lib/nftban/cli/cmd_status.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fails=0
chk() { # chk "desc" "expected-substring" "actual"
    if [[ "$3" == *"$2"* ]]; then echo "  ✓ $1"; else echo "  ✗ $1 — expected '*$2*', got '$3'"; fails=$((fails+1)); fi
}

# --- Extract the REAL Trust-Feeds block from the shipped cmd_status.sh (tests shipped bytes) ---
BLOCK="$TMP/block.sh"
sed -n '/# Trust Feeds (CDN whitelist/,/printf .* "Trust Feeds/p' "$STATUS_SH" > "$BLOCK"
[[ -s "$BLOCK" ]] || { echo "FAIL: could not extract Trust-Feeds block from $STATUS_SH"; exit 1; }
grep -q 'trust list --json' "$BLOCK" || { echo "FAIL: extracted block does not use 'trust list --json' (fix not present)"; exit 1; }
grep -q '"enabled":\[\[:space:\]\]\*true\|"enabled":\[\[:space:\]]*true' "$BLOCK" || \
  grep -q 'enabled' "$BLOCK" || { echo "FAIL: block lost enabled-count logic"; exit 1; }

# Harness: run the extracted block with a given NFTBAN_LIB_DIR, capture the rendered line.
run_block() { # run_block <lib_dir>  (the shipped block uses `local`, so source it inside a function)
    NFTBAN_LIB_DIR="$1" bash -c "set -Eeuo pipefail; _render(){ source '$BLOCK'; }; _render" 2>/dev/null || true
}

# Build a stub nftban-core that emits a chosen JSON fixture for `trust list --json`.
make_core() { # make_core <libdir> <fixture-file>
    local libdir="$1" fix="$2"; mkdir -p "$libdir/bin"
    cat > "$libdir/bin/nftban-core" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *"trust list --json"*) cat "$fix" ;;
  *) printf '  nftban trust update    Download and apply all enabled\n' ;;  # text hint must NOT be counted
esac
STUB
    chmod +x "$libdir/bin/nftban-core"
}

# Scenario 1: 2 enabled providers -> ENABLED (2 feeds)
L1="$TMP/l1"; F1="$TMP/f1.json"
cat > "$F1" <<'J'
{ "data": { "total": 3, "trusts": [
  {"category":"cdn","description":"Cloudflare","enabled": true},
  {"category":"cloud","description":"AWS","enabled": false},
  {"category":"cdn","description":"Fastly","enabled":true} ] } }
J
make_core "$L1" "$F1"
chk "2 enabled -> ENABLED (2 feeds)" "ENABLED (2 feeds)" "$(run_block "$L1")"

# Scenario 2: 0 enabled (all false) -> DISABLED (NOT 'NOT INSTALLED'), and the literal word 'enabled' present must not false-count
L2="$TMP/l2"; F2="$TMP/f2.json"
cat > "$F2" <<'J'
{ "data": { "total": 2, "note": "none enabled", "trusts": [
  {"category":"cdn","description":"Cloudflare","enabled": false},
  {"category":"cloud","description":"AWS","enabled":false} ] } }
J
make_core "$L2" "$F2"
out2="$(run_block "$L2")"
chk "0 enabled -> DISABLED" "DISABLED" "$out2"
[[ "$out2" == *"NOT INSTALLED"* ]] && { echo "  ✗ 0 enabled must not render NOT INSTALLED"; fails=$((fails+1)); } || echo "  ✓ 0 enabled not rendered NOT INSTALLED"
[[ "$out2" == *"ENABLED"* ]] && { echo "  ✗ word 'enabled' in json must not produce a false ENABLED"; fails=$((fails+1)); } || echo "  ✓ no false ENABLED from literal 'enabled' text"

# Scenario 3: malformed / empty JSON -> UNKNOWN (not false DISABLED)
L3="$TMP/l3"; F3="$TMP/f3.json"; printf 'this is not json\n' > "$F3"
make_core "$L3" "$F3"
chk "malformed JSON -> UNKNOWN" "UNKNOWN" "$(run_block "$L3")"

# Scenario 4: nftban-core absent (no local stub, and skip if a real /usr/lib core exists on this host)
if [[ -x /usr/lib/nftban/bin/nftban-core ]] || command -v nftban-core &>/dev/null; then
    echo "  ~ skip absent-core assertion (a real nftban-core resolves on this host)"
else
    chk "absent core -> NOT INSTALLED" "NOT INSTALLED" "$(run_block "$TMP/empty")"
fi

echo "----"
if [[ $fails -eq 0 ]]; then echo "PASS: Trust-Feeds label truth"; exit 0; else echo "FAIL: $fails assertion(s)"; exit 1; fi
