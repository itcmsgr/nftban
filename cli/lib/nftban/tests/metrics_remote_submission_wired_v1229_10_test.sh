#!/usr/bin/env bash
# =============================================================================
# NFTBan - metrics remote submission is wired (v1.229.10)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="metrics_remote_submission_wired_v1229_10_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="metrics"
# meta:ta.id="metrics_remote_submission_wired_v1229_10_test"
# meta:ta.owner="metrics"
# meta:ta.module="metrics-remote-submission"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="60"
# meta:ta.hermetic="true"
# meta:ta.requires_systemd="false"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:description="v1.229.10 — `nftban metrics enable --pro|--remote` dispatched to _metrics_enable_pro / _metrics_enable_remote_user, which were called but never defined anywhere in the tree (2 calls, 0 definitions) so both advertised flags exited 127. Locks: both functions are DEFINED in the file that calls them; the negative control proves the pre-fix state (an undefined callee really does exit 127, so the test subject is the motivating defect); every mutation is GATED BEFORE it runs — --pro refuses when the host is not enrolled or has no token, --remote refuses an absent/non-http URL and a named-but-empty token, and both refuse when the configured scrape target serves nothing (a shipper over a dead target reports success and delivers nothing). Capability is proven, never presence; tool absence is reported, never treated as a pass."
# meta:inventory.files="cli/lib/nftban/cli/cmd_metrics.sh,cli/lib/nftban/setup/install_vmagent.sh"
# meta:inventory.binaries="bash,mktemp,grep,sed"
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI="$SCRIPT_DIR/../cli/cmd_metrics.sh"
PASS=0; FAIL=0
ok(){ printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
chk(){ if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (want=$3 got=$2)"; fi; }

echo "=== metrics remote submission is wired (v1.229.10) ==="
echo ""

# ---------------------------------------------------------------------------
# N1 NEGATIVE CONTROL — the pre-fix state must actually be the failure we claim.
# If an undefined callee did NOT exit 127, this whole test would be testing
# nothing. The control must hit the MOTIVATING defect.
# ---------------------------------------------------------------------------
rc=0; ( set +u; _nftban_definitely_undefined_callee_xyz ) >/dev/null 2>&1 || rc=$?
chk "N1 negative control: an undefined callee really does exit 127" "$rc" "127"

# ---------------------------------------------------------------------------
# P1 both dispatched functions are DEFINED in the file that calls them
# Located by definition, never by line number.
# ---------------------------------------------------------------------------
for fn in _metrics_enable_pro _metrics_enable_remote_user; do
    calls=$(grep -cE "^[[:space:]]+${fn}([[:space:]]|$)" "$CLI" || true)
    defs=$(grep -cE "^${fn}\(\)[[:space:]]*\{" "$CLI" || true)
    if [[ "$defs" -ge 1 && "$calls" -ge 1 ]]; then
        ok "P1 $fn is called ($calls) AND defined ($defs)"
    else
        no "P1 $fn calls=$calls defs=$defs"
    fi
done

# ---------------------------------------------------------------------------
# Load the unit under test in isolation.
# ---------------------------------------------------------------------------
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export NFTBAN_LIB_DIR="$TMP/lib"
mkdir -p "$NFTBAN_LIB_DIR/setup"
: >"$NFTBAN_LIB_DIR/setup/install_vmagent.sh"

# Extract only the wrapper block so the test does not depend on the rest of the
# command surface (config loaders, systemd, prometheus deps).
sed -n '/^: "${NFTBAN_METRICS_SCRAPE_TARGET/,/^nftban_metrics_enable() {/p' "$CLI" \
    | sed '$d' > "$TMP/unit.sh"
# shellcheck disable=SC1090
source "$TMP/unit.sh" || { echo "could not source unit"; exit 1; }

if declare -F _metrics_enable_pro >/dev/null 2>&1 \
   && declare -F _metrics_enable_remote_user >/dev/null 2>&1; then
    ok "P2 both functions load and are callable"
else
    no "P2 functions did not load"
fi

# Force every scrape-target probe to FAIL unless a test opts in, so no test can
# accidentally depend on a live endpoint on the build host.
_metrics_scrape_target_serves() { return "${_TEST_TARGET_RC:-1}"; }

# ---------------------------------------------------------------------------
# P3/P4 --pro GATES BEFORE MUTATION
# ---------------------------------------------------------------------------
export NFTBAN_PRO_TOKEN_FILE="$TMP/pro.token"
export NFTBAN_PRO_SERVER_ID_FILE="$TMP/server_id"
nftban_pro_get_server_id() { cat "$NFTBAN_PRO_SERVER_ID_FILE" 2>/dev/null || true; }

out=$(_metrics_enable_pro 2>&1); rc=$?
chk "P3 --pro refuses when the host is not enrolled" "$rc" "1"
grep -q "not enrolled" <<<"$out" && ok "P3b it names enrolment as the cause" || no "P3b cause not named"
grep -q "nftban pro enroll" <<<"$out" && ok "P3c it names the command that fixes it" || no "P3c no remedy named"

echo "test-server-id" > "$NFTBAN_PRO_SERVER_ID_FILE"
out=$(_metrics_enable_pro 2>&1); rc=$?
chk "P4 --pro refuses when enrolled but the token is absent" "$rc" "1"
grep -q "token" <<<"$out" && ok "P4b it names the token as the cause" || no "P4b cause not named"

# ---------------------------------------------------------------------------
# P5 the dead-target gate — the fail-open shape this fix exists to prevent
# ---------------------------------------------------------------------------
echo "tok" > "$NFTBAN_PRO_TOKEN_FILE"
out=$(_metrics_enable_pro 2>&1); rc=$?
chk "P5 --pro refuses when the scrape target serves nothing" "$rc" "1"
grep -q "Refusing to configure a shipper over a dead target" <<<"$out" \
    && ok "P5b it states WHY configuring anyway would be wrong" || no "P5b rationale absent"
grep -qE "Step [0-9]/4" <<<"$out" && no "P5c MUTATION RAN BEFORE THE GATE" \
    || ok "P5c no mutation step ran — the gate is BEFORE the mutation"

# ---------------------------------------------------------------------------
# P6/P7 --remote input contract
# ---------------------------------------------------------------------------
out=$(_metrics_enable_remote_user "" "" "" 2>&1); rc=$?
chk "P6 --remote refuses an absent URL" "$rc" "1"
grep -q "requires a remote-write URL" <<<"$out" && ok "P6b usage is shown" || no "P6b no usage"

out=$(_metrics_enable_remote_user "ftp://x/y" "" "" 2>&1); rc=$?
chk "P7 --remote refuses a non-http(s) URL" "$rc" "1"

out=$(_metrics_enable_remote_user "https://x/api/v1/write" "$TMP/nope.token" "" 2>&1); rc=$?
chk "P8 --remote refuses a NAMED but absent token" "$rc" "1"
grep -qE "Step [0-9]/4" <<<"$out" && no "P8b mutation ran despite a bad token" \
    || ok "P8b no mutation ran — a named-but-absent token is an error, not a downgrade"

out=$(_metrics_enable_remote_user "https://x/api/v1/write" "" "" 2>&1); rc=$?
chk "P9 --remote refuses a dead scrape target" "$rc" "1"

# ---------------------------------------------------------------------------
# N2 tool absence must be REPORTED, never treated as an empty pass
# ---------------------------------------------------------------------------
unset -f _metrics_scrape_target_serves
# shellcheck disable=SC1090
source "$TMP/unit.sh"
out=$( PATH="$TMP/empty" _metrics_scrape_target_serves localhost:1 2>&1 ); rc=$?
chk "N2 missing curl returns the distinct 'cannot establish' code, not a pass" "$rc" "2"
grep -q "curl is required" <<<"$out" && ok "N2b it says the fact could not be established" || no "N2b silent"

# ---------------------------------------------------------------------------
# N3 a missing installer must be reported by PATH, not guessed around
# ---------------------------------------------------------------------------
rm -f "$NFTBAN_LIB_DIR/setup/install_vmagent.sh"
out=$(_metrics_vmagent_script 2>&1); rc=$?
chk "N3 absent installer is refused" "$rc" "1"
grep -q "expected: " <<<"$out" && ok "N3b it prints the exact path it looked for" || no "N3b path not printed"

echo ""
echo "  PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "metrics remote submission wired PASSED"
