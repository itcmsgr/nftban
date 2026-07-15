#!/usr/bin/env bash
# =============================================================================
# NFTBan - L3a never-ban add_element guard (regression / reachability)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="l3a_never_ban_add_element_guard_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-06"
# meta:description="Regression guard for L3a: the never-ban invariant is enforced on the generic add path, not only the ban verb. Asserts (1) backend.AddElement calls the exempt guard (exemptAddRejection) as defense-in-depth, (2) ErrNeverBanExempt exists, (3) IsEnforcementSet covers the blacklist/ddos drop sets and excludes whitelist/port sets, (4) handleAddElementRequest pre-checks IsEnforcementSet+IsExempt, (5) backend.Ban still guards via IsExempt (regression), and (6) the opqueue EnqueueBan path is documented as the separate L3b lane (out of scope here). Hermetic: greps shipped source."
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../../.." && pwd)"
BACKEND="$REPO/internal/nftbackend/backend.go"
HANDLER="$REPO/cmd/nftband/daemon_handlers_elements.go"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad() { FAIL=$((FAIL+1)); echo "  [FAIL] $1${2:+ — $2}"; }

echo "=== L3a never-ban add_element guard ==="

# 1) backend.AddElement enforces the guard (defense-in-depth backstop for ALL callers).
if grep -q 'exemptAddRejection(req.Set, req.Element)' "$BACKEND"; then ok "backend.AddElement calls exemptAddRejection"; else bad "backend.AddElement does NOT call the exempt guard"; fi

# 2) sentinel error exists.
if grep -q 'ErrNeverBanExempt = errors.New' "$BACKEND"; then ok "ErrNeverBanExempt defined"; else bad "ErrNeverBanExempt missing"; fi

# 3) enforcement-set classifier covers ALL add_element-reachable drop sets + defense-in-depth.
for s in blacklist_manual_ipv4 blacklist_manual_ipv6 blacklist_ipv4 blacklist_ipv6 ddos_blocked \
         geoban_ipv4 geoban_ipv6 persistent_offenders_ipv4 persistent_offenders_ipv6 bogon_ipv4 bogon_ipv6 \
         http_bot_ban http_bot_emergency; do
  if grep -q "\"$s\": *true" "$BACKEND"; then ok "IsEnforcementSet covers $s"; else bad "IsEnforcementSet missing $s"; fi
done
ES_BLOCK=$(awk '/enforcementSets = map\[string\]bool\{/{f=1} f{print} f&&/^}/{exit}' "$BACKEND")
if printf '%s' "$ES_BLOCK" | grep -qE '"(whitelist_ipv4|whitelist_ipv6|ssh_ports|tcp_ports_in)"'; then bad "whitelist/port set wrongly in enforcementSets"; else ok "whitelist/port sets NOT in enforcementSets"; fi

# 4) handler pre-check (clear operator feedback).
if grep -q 'IsEnforcementSet(set)' "$HANDLER" && grep -q 'd.backend.IsExempt(element)' "$HANDLER"; then ok "handleAddElementRequest pre-checks IsEnforcementSet + IsExempt"; else bad "handler pre-check missing"; fi

# 5) backend.Ban still guards (regression).
if grep -q 'b.exempt.IsExempt(req.IP)' "$BACKEND"; then ok "backend.Ban still guards via IsExempt"; else bad "backend.Ban guard regressed"; fi

# 6) L3b boundary: EnqueueBan (opqueue) is explicitly the next lane, not silently guarded here.
if grep -q 'L3b' "$BACKEND"; then ok "L3b (opqueue EnqueueBan) documented as separate lane"; else bad "L3b boundary note missing"; fi

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
