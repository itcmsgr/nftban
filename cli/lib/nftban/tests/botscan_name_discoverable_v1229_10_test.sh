#!/usr/bin/env bash
# =============================================================================
# NFTBan - the name an operator types is the name the report prints (v1.229.10)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="botscan_name_discoverable_v1229_10_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="botscan"
# meta:ta.id="botscan_name_discoverable_v1229_10_test"
# meta:ta.owner="botscan"
# meta:ta.module="botscan-operator-discoverability"
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
# meta:description="v1.229.10 — an operator on a host under attack ran nftban status and reported 'i dont see botscan'. The module WAS rendered, as 'HTTP Exploit Scan'; the token BotScan appeared only inside the explanatory note beneath the row, and BotGuard only as 'HTTP Guard'. The commands are nftban botscan and nftban botguard. Locks that both status rows lead with the product name the operator types, that the descriptive term is retained rather than replaced, and that both labels stay exactly 20 characters so the status column alignment is unchanged. Scope is the two row labels only — no broader terminology cleanup."
# meta:inventory.files="cli/lib/nftban/cli/cmd_status.sh"
# meta:inventory.binaries="bash,grep,awk"
set -uo pipefail

SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ST="$SD/../cli/cmd_status.sh"
PASS=0; FAIL=0
ok(){ printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
# MENTION != CODE — a comment must never satisfy a rule about rendered output.
body="$(grep -vE '^[[:space:]]*#' "$ST" || true)"
has(){ grep -q "$1" <<<"$body"; }

echo "=== the name an operator types is the name the report prints (v1.229.10) ==="
echo ""

# P1 both rows lead with the product name
has 'BotScan (HTTP Scan)\.' && ok "P1 status row leads with BotScan" || no "P1 BotScan not in the row label"
has 'BotGuard (HTTP Grd)\.' && ok "P1b status row leads with BotGuard" || no "P1b BotGuard not in the row label"

# P2 the descriptive term is retained, not replaced
has 'HTTP Scan' && ok "P2 the HTTP descriptor is retained (renamed, not replaced)" || no "P2 descriptor lost"

# P3 column alignment preserved — the printf pads to %-20s, so a label longer
# than 20 shifts that row's value and breaks the column. Assert the exact
# literals, not a re-derived pattern: the literal IS the contract.
for lit in "BotScan (HTTP Scan)." "BotGuard (HTTP Grd)."; do
    if ! grep -Fq "\"$lit\"" <<<"$body"; then
        no "P3 label literal not present: $lit"
    elif [[ "${#lit}" -eq 20 ]]; then
        ok "P3 '$lit' is exactly 20 chars (alignment unchanged)"
    else
        no "P3 '$lit' is ${#lit} chars — breaks the status column"
    fi
done

# P4 the old bare labels are gone from rendered output
if grep -qE '"HTTP Exploit Scan\.\.\."|"HTTP Guard\.\.\.\.\.\.\.\.\."' <<<"$body"; then
    no "P4 a bare HTTP-only label still renders"
else
    ok "P4 no bare HTTP-only row label remains"
fi

# P5 scope fence — this is TWO labels, not a terminology sweep
n=$(grep -c 'BotScan (HTTP Scan)\.\|BotGuard (HTTP Grd)\.' <<<"$body" || true)
[[ "$n" -le 2 ]] && ok "P5 exactly the two row labels changed (no broader cleanup)" \
                 || no "P5 more than two labels touched ($n)"

# N1 NEGATIVE CONTROL — the guard must reject the pre-fix label
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf '%s\n' 'printf "  %-20s %s\n" "HTTP Exploit Scan..." "$botscan_status"' > "$TMP/pre.sh"
if grep -qE '"HTTP Exploit Scan\.\.\."' "$TMP/pre.sh"; then
    ok "N1 negative control: the guard detects the pre-fix label (P4 is meaningful)"
else
    no "N1 negative control failed"
fi

# N2 a comment mentioning the old label must not trip P4
printf '%s\n' '# the row said only "HTTP Exploit Scan..." so operators could not find it' > "$TMP/c.sh"
cbody="$(grep -vE '^[[:space:]]*#' "$TMP/c.sh" || true)"
if grep -qE 'HTTP Exploit Scan' <<<"$cbody"; then
    no "N2 a COMMENT satisfied the check — MENTION != CODE not enforced"
else
    ok "N2 a commented mention does not trip the guard (MENTION != CODE)"
fi

echo ""
echo "  PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "botscan name discoverable PASSED"
