#!/usr/bin/env bash
# =============================================================================
# NFTBan - configured is not deployed: penalty ladder readiness (v1.229.10)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="ddos_penalty_ladder_readiness_truth_v1229_10_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="ddos"
# meta:ta.id="ddos_penalty_ladder_readiness_truth_v1229_10_test"
# meta:ta.owner="ddos"
# meta:ta.module="ddos-status-truth"
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
# meta:description="v1.229.10 closes S1 of STATUS-HEALTH-TRUTH-AUDIT-2026-08-20. nftban ddos status printed 'Status: DEPLOYED' for the penalty ladder purely because the penalty SET existed, with no reference to whether the ladder could operate. The sets are filled only by nftban_ddos_penalty_scan(), which runs solely from the maintenance timer (cron/maintenance.sh:1001) and takes offender input from the SYN flood meter; with either absent the ladder is present and permanently idle and autoban never fires, while the operator was told DEPLOYED. Locks that DEPLOYED now requires BOTH a live producer AND a readable input, that starvation renders explicitly and never as DEPLOYED, that an unobservable producer/input renders UNKNOWN rather than the favourable state, and that this report surface holds no mutation or enforcement authority. Report truth only — the starvation mechanism itself is not repaired here."
# meta:inventory.files="cli/lib/nftban/core/nftban_ddos_classic.sh"
# meta:inventory.binaries="bash,grep"
set -uo pipefail

SD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
F="$SD/../core/nftban_ddos_classic.sh"
PASS=0; FAIL=0
ok(){ printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL+1)); }
# MENTION != CODE — the rule is about rendered output, never about prose.
body="$(grep -vE '^[[:space:]]*#' "$F" || true)"
has(){ grep -q "$1" <<<"$body"; }

echo "=== configured is not deployed: penalty ladder readiness (v1.229.10) ==="
echo ""

# --- P1 DEPLOYED requires BOTH a live producer AND a readable input ----------
if has 'Status: DEPLOYED (sets present' && has '_pl_prod" == "LIVE" && \[\[' 2>/dev/null || has '"\$_pl_prod" == "LIVE" && "\$_pl_input" == "PRESENT"'; then
    ok "P1 DEPLOYED is gated on producer LIVE *and* input PRESENT"
else
    no "P1 DEPLOYED is not conjunctively gated"
fi

# --- P2 starvation renders explicitly, never as DEPLOYED ---------------------
has 'PRESENT but STARVED' && ok "P2 starved state renders explicitly" || no "P2 no explicit STARVED rendering"
has 'autoban will NOT fire' && ok "P2b it states the operational consequence" || no "P2b consequence not stated"

# --- N1 the old unconditional wording must be gone ---------------------------
if grep -qE '^\s*echo "  Status: DEPLOYED"\s*$' <<<"$body"; then
    no "N1 the unconditional 'Status: DEPLOYED' line still exists"
else
    ok "N1 no unconditional DEPLOYED wording remains"
fi

# --- N2 unobservable state is UNKNOWN, never favourable ----------------------
has 'readiness UNKNOWN' && ok "N2 unobservable readiness renders UNKNOWN" || no "N2 no UNKNOWN branch"
has 'NOT established' && ok "N2b UNKNOWN explicitly declines the favourable claim" || no "N2b UNKNOWN reads favourable"
# UNKNOWN must not be able to fall through into the DEPLOYED branch.
if grep -q '_pl_prod="UNKNOWN" _pl_input="UNKNOWN"' <<<"$body"; then
    ok "N2c both axes DEFAULT to UNKNOWN (favourable state must be earned)"
else
    no "N2c axes do not default to UNKNOWN"
fi

# --- N3 the report surface has NO mutation/enforcement authority -------------
# Scope the check to the penalty-ladder status block only; the rest of this file
# legitimately builds rules.
blk="$(awk '/^    echo "Penalty Ladder:"/,/^    echo "Configuration:"/' "$F" | grep -vE '^[[:space:]]*#')"
if grep -qE 'nft (add|delete|insert|flush|create) |nftban_ban_ip' <<<"$blk"; then
    no "N3 the status block acquired mutation capability"
else
    ok "N3 status block is read-only (nft list only) — no mutation authority"
fi
grep -qE 'nft list (set|meter|table)' <<<"$blk" && ok "N3b readiness is observed, not assumed" || no "N3b no observation performed"

# --- P3 the producer named must be the one that actually fills the sets ------
# GUARD SUBJECT == GUARD INPUT: if the caller moves, this must fail, not drift.
if grep -q 'nftban_ddos_penalty_scan' "$SD/../cron/maintenance.sh"; then
    ok "P3 the named producer (maintenance) really does invoke nftban_ddos_penalty_scan"
else
    no "P3 the report names a producer that does not call the scan — stale attribution"
fi
has 'nftban-maintenance.timer' && ok "P3b the report names the exact unit it checked" || no "P3b unit not named"

# --- N4 NEGATIVE CONTROL: the guard must detect the pre-fix text -------------
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf '%s\n' '        echo "  Status: DEPLOYED"' > "$TMP/pre.sh"
if grep -qE '^\s*echo "  Status: DEPLOYED"\s*$' "$TMP/pre.sh"; then
    ok "N4 negative control: the guard detects the pre-fix line (N1 is meaningful)"
else
    no "N4 negative control failed — the guard cannot see the defect"
fi

echo ""
echo "  PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "ddos penalty ladder readiness truth PASSED"
