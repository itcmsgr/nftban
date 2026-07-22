#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.153 PR-A: status output-truth + cross-command consistency
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="status_consistency_v153_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-06"
# meta:description="Locks v1.153 PR-A status consistency: UX-A1 authority block renders 'Firewall authority..🔒 EXCLUSIVE' for owned authority and 'Legacy firewalls..🛡️ NEUTRALIZED:' for recorded conflicts (only AMBIGUOUS shows 'Active conflicts'); UX-A2 timers summary reads 'Core N/M active · Optional K disabled · Failed F' (not a bare ratio); UX-A5 Suricata + service modules say 'not installed (optional add-on)' once; UX-A6 the health roll-up is labelled 'Health' (single authoritative posture lives in the State line); CMD-CONSIST shared nftban_kv helper preserves internal label spaces while dot-padding trailing width. Hermetic: extracts the section functions + a local nftban_kv mirror; no host/nft/IPC/systemctl reliance for the asserted strings."
# meta:input="None (self-contained sandbox)"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep,awk"
# meta:inventory.files="cli/lib/nftban/cli/cmd_status.sh,cli/lib/nftban/core/nftban_output.sh"
# meta:inventory.binaries="bash,grep,awk"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_STATE_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="status_consistency_v153_test"
# meta:ta.owner="cli"
# meta:ta.module="status"
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

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
LIB="$REPO_ROOT/cli/lib/nftban"
S="$LIB/cli/cmd_status.sh"
OUT="$LIB/core/nftban_output.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✓ $1"; }
no() { FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
STATE_DIR="$SANDBOX/state"; mkdir -p "$STATE_DIR"
export NFTBAN_STATE_DIR="$STATE_DIR"

# Local mirror of core/nftban_output.sh::nftban_kv (kept in lockstep). The
# trailing-padding-only dot logic is the contract under test for CMD-CONSIST.
nftban_kv() {
    local label="${1:-}" value="${2:-}" width="${3:-20}"
    local pad_len=$(( width - ${#label} )); (( pad_len < 1 )) && pad_len=1
    local dots; dots=$(printf '%*s' "$pad_len" ''); dots="${dots// /.}"
    printf "  %s%s %s\n" "$label" "$dots" "$value"
}

run_authority_section() {
    awk '/^_status_section_authority\(\) \{/,/^\}/' "$S" > "$SANDBOX/auth.sh"
    # shellcheck source=/dev/null
    ( source "$SANDBOX/auth.sh"; _status_section_authority )
}

write_state() {
    local f="$STATE_DIR/install_state"; : > "$f"
    while (( "$#" )); do echo "$1" >> "$f"; shift; done
}

echo "=== CMD-CONSIST: nftban_kv preserves internal spaces, dot-pads trailing ==="
kv_line="$(nftban_kv "Firewall authority" "X")"
if [[ "$kv_line" == *"Firewall authority"* ]]; then
    ok "nftban_kv keeps the internal label space (no 'Firewall.authority')"
else
    no "internal space corrupted" "$kv_line"
fi
[[ "$kv_line" == *".."* ]] && ok "nftban_kv emits trailing dot leaders" || no "no dot leaders" "$kv_line"
grep -q 'nftban_kv()' "$OUT" && ok "shared nftban_kv defined in core/nftban_output.sh" || no "nftban_kv missing from core"

echo "=== UX-A1: owned authority => EXCLUSIVE + NEUTRALIZED legacy firewalls ==="
write_state "AUTHORITY=UPDATE" "CONFLICTS=UFW,iptables-nft,iptables,CSF"
A_OUT="$(run_authority_section)"
echo "$A_OUT" | grep -qE "Firewall authority\.+ .*EXCLUSIVE \(UPDATE\)" \
    && ok "owned authority shows '🔒 EXCLUSIVE (UPDATE)'" || no "EXCLUSIVE line missing" "$A_OUT"
echo "$A_OUT" | grep -qE "Legacy firewalls\.+ .*NEUTRALIZED: UFW,iptables-nft,iptables,CSF" \
    && ok "recorded conflicts framed as '🛡️ NEUTRALIZED: …'" || no "NEUTRALIZED line missing" "$A_OUT"
echo "$A_OUT" | grep -q "Active conflicts" \
    && no "owned-authority path must NOT say 'Active conflicts'" "$A_OUT" \
    || ok "owned-authority path does not mislabel neutralized firewalls as active"

echo "=== UX-A1: AMBIGUOUS => genuinely active conflicts ==="
write_state "AUTHORITY=AMBIGUOUS" "CONFLICTS=csf,lfd"
B_OUT="$(run_authority_section)"
echo "$B_OUT" | grep -qE "Firewall authority\.+ .*AMBIGUOUS" \
    && ok "AMBIGUOUS authority shows '⚠️  AMBIGUOUS'" || no "AMBIGUOUS line missing" "$B_OUT"
echo "$B_OUT" | grep -qE "Active conflicts\.+ csf,lfd" \
    && ok "AMBIGUOUS path keeps literal 'Active conflicts' (still fighting)" || no "Active conflicts line missing" "$B_OUT"

echo "=== UX-A2: timers summary partitions core/optional/failed ==="
grep -q 'Core ${core_active}/${core_installed} active · Optional ${optional_disabled} disabled · Failed ${timer_failed}' "$S" \
    && ok "timers summary emits 'Core N/M active · Optional K disabled · Failed F'" \
    || no "UX-A2 partitioned timers summary string not found in cmd_status.sh"
grep -q 'core_timer=' "$S" && ok "core-vs-optional timer partition present" || no "core_timer map missing"
# the bare '$timer_active / $timer_count' summary must be gone
grep -qE '"Active timers\.+" "\$timer_active / \$timer_count"' "$S" \
    && no "bare 'N / M' timer ratio still printed" \
    || ok "bare ratio summary removed"

echo "=== UX-A5: optional add-on wording, one term per service ==="
grep -q 'not installed (optional add-on)' "$S" \
    && ok "Suricata / service modules say 'not installed (optional add-on)'" \
    || no "UX-A5 'not installed (optional add-on)' wording missing"
# the bare uppercase 'NOT INSTALLED (optional)' service line should be gone
grep -q 'NOT INSTALLED (optional)' "$S" \
    && no "old 'NOT INSTALLED (optional)' service term still present" \
    || ok "old uppercase service term replaced"

echo "=== UX-A6: health roll-up labelled 'Health' (not a 2nd posture verdict) ==="
grep -q 'nftban_kv "Health"' "$S" \
    && ok "health section roll-up labelled 'Health'" || no "UX-A6 Health label missing"
grep -q '"Overall Status\.+"' "$S" 2>/dev/null \
    && no "old 'Overall Status' second-posture line still present" \
    || ok "no competing 'Overall Status' posture line"

echo ""
echo "================================================================"
echo "status_consistency_v153: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[[ $FAIL -eq 0 ]]
