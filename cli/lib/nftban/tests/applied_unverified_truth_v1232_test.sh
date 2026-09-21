#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# =============================================================================
# NFTBan v1.232.2 — APPLIED_UNVERIFIED shell truth (hermetic falsifiers)
# =============================================================================
# meta:name="applied_unverified_truth_v1232_test"
# meta:type="test"
# meta:version="1.232.2"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="FTH truth split (COMMITTED vs EXPECT_TABLE_PRESENT), known-literal closure for APPLIED_UNVERIFIED, and the transaction-truth renderer refusing to call an applied transaction incomplete"
# meta:inventory.files=""
# meta:inventory.binaries="bash"
# meta:inventory.env_vars="FTH_STATE_FILE,FTH_SKIP_GATHER,FTH_INSTALL_STATE"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="applied_unverified_truth_v1232_test"
# meta:ta.owner="installer"
# meta:ta.module="install-state-truth"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
#
# Subject: BUG-UPDATE-APPLY-CAN-COMMIT-WITHOUT-CONVERGENCE-VERDICT, shell half.
#
# ⛔ THE RULE THESE FALSIFIERS ENFORCE: never make one truthful state impersonate
#    another to keep an existing check working. FTH_COMMITTED was NAMED as an
#    install_state assertion while MEANING "AUTHORITY is EXCLUSIVE or UPDATE".
#    Setting it to Y for APPLIED_UNVERIFIED would have kept the table-absence
#    breach alive at the cost of asserting a commit that never happened — the
#    same semantic collapse that was just removed from the Go state model.
#
# =============================================================================
# shellcheck disable=SC2034  # The FTH_* fixtures below are the test INPUT: the
# sourced helper reads them directly and via indirect (${!var}) expansion, which
# ShellCheck cannot follow across the source boundary. Same waiver, same reason,
# as firewall_transition_health_v1921_test.sh.
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
FTH="$SCRIPT_DIR/../core/nftban_firewall_transition_health.sh"
OUT="$SCRIPT_DIR/../core/nftban_output.sh"
for f in "$FTH" "$OUT"; do
    [[ -f "$f" ]] || { echo "FAIL: helper not found at $f"; exit 1; }
done

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
export FTH_STATE_FILE="$SB/fth.json"

PASS=0; FAIL=0
ok(){ echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad(){ echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

# -----------------------------------------------------------------------------
# Section 1 — FTH gather: the two facts must be reported as themselves.
# -----------------------------------------------------------------------------
echo "== 1. FTH gather truth split =="

# shellcheck source=/dev/null
source "$FTH"

# Stub the external authorities so gather is hermetic: no nft, no core, no host
# SSH discovery. The SUBJECT here is the install-state truth split; everything
# upstream of it is held constant on purpose.
FTH_NFT="/bin/false"          # every `list table` fails => FTH_TABLE_PRESENT=N
FTH_CORE="/bin/true"
_fth_ssh_ports(){ echo "22"; }
_fth_live_set(){ echo ""; }
_fth_floor_present(){ echo Y; }

write_state() { # <file> <INSTALL_STATE> <AUTHORITY>
    printf 'INSTALL_STATE=%s\nAUTHORITY=%s\nCONVERGENCE_VERIFIED=NOT_EVALUATED\n' "$2" "$3" > "$1"
}

# 1a. APPLIED_UNVERIFIED must NOT be reported as committed.
export FTH_INSTALL_STATE="$SB/is_applied"
write_state "$FTH_INSTALL_STATE" "APPLIED_UNVERIFIED" ""
_fth_gather
if [[ "$FTH_COMMITTED" == "N" ]]; then
    ok "1a APPLIED_UNVERIFIED does not set FTH_COMMITTED=Y"
else
    bad "1a FTH_COMMITTED=$FTH_COMMITTED for APPLIED_UNVERIFIED — a state is impersonating COMMITTED"
fi
if [[ "$FTH_APPLIED_UNVERIFIED" == "Y" ]]; then
    ok "1a APPLIED_UNVERIFIED is reported as itself"
else
    bad "1a FTH_APPLIED_UNVERIFIED=$FTH_APPLIED_UNVERIFIED — the state is not reported at all"
fi
# ...and the expectation it genuinely carries IS set.
if [[ "$FTH_EXPECT_TABLE_PRESENT" == "Y" ]]; then
    ok "1a APPLIED_UNVERIFIED still expects the table present (the breach is not lost)"
else
    bad "1a FTH_EXPECT_TABLE_PRESENT=N — truthfulness bought by dropping a real breach"
fi

# 1b. AUTHORITY alone (today's pre-split predicate) must NOT assert COMMITTED,
#     but must still carry the expectation. This is the falsifier for the
#     mis-naming: before the split, this exact input produced FTH_COMMITTED=Y.
export FTH_INSTALL_STATE="$SB/is_auth_only"
write_state "$FTH_INSTALL_STATE" "SWITCH_COMPLETE" "EXCLUSIVE"
_fth_gather
if [[ "$FTH_COMMITTED" == "N" ]]; then
    ok "1b AUTHORITY=EXCLUSIVE alone no longer asserts COMMITTED"
else
    bad "1b FTH_COMMITTED=Y from AUTHORITY alone — the variable still means something other than its name"
fi
if [[ "$FTH_EXPECT_TABLE_PRESENT" == "Y" ]]; then
    ok "1b AUTHORITY=EXCLUSIVE still expects the table present (no regression)"
else
    bad "1b AUTHORITY=EXCLUSIVE lost its table expectation — pre-split breaches were dropped"
fi

# 1c. A real COMMITTED still reports as committed.
export FTH_INSTALL_STATE="$SB/is_committed"
write_state "$FTH_INSTALL_STATE" "COMMITTED" "EXCLUSIVE"
_fth_gather
if [[ "$FTH_COMMITTED" == "Y" && "$FTH_EXPECT_TABLE_PRESENT" == "Y" ]]; then
    ok "1c COMMITTED reports committed and expects the table"
else
    bad "1c COMMITTED reported as FTH_COMMITTED=$FTH_COMMITTED expect=$FTH_EXPECT_TABLE_PRESENT"
fi

# 1d. Neither fact => neither claim.
export FTH_INSTALL_STATE="$SB/is_none"
write_state "$FTH_INSTALL_STATE" "FILES_INSTALLED" ""
_fth_gather
if [[ "$FTH_COMMITTED" == "N" && "$FTH_EXPECT_TABLE_PRESENT" == "N" ]]; then
    ok "1d FILES_INSTALLED claims neither"
else
    bad "1d FILES_INSTALLED produced committed=$FTH_COMMITTED expect=$FTH_EXPECT_TABLE_PRESENT"
fi

# -----------------------------------------------------------------------------
# Section 2 — the breach must fire off the EXPECTATION, not off COMMITTED.
# -----------------------------------------------------------------------------
echo "== 2. table-absence breach predicate =="

set_clean_sets() {
    FTH_EFF_TCPIN=""; FTH_EFF_TCPOUT=""; FTH_EFF_UDPIN=""; FTH_EFF_UDPOUT=""
    FTH_FLOOR_4=Y; FTH_FLOOR_6=Y; FTH_IN_RECOVERY=N
}

# 2a. APPLIED_UNVERIFIED + table absent => breach, WITHOUT claiming COMMITTED.
set_clean_sets
FTH_TABLE_PRESENT=N; FTH_COMMITTED=N; FTH_APPLIED_UNVERIFIED=Y
FTH_EXPECT_TABLE_PRESENT=Y; FTH_TABLE_EXPECT_BASIS="install_state APPLIED_UNVERIFIED"
_fth_compute_breaches
if [[ "$FTH_B_TABLE" -eq 1 ]]; then
    ok "2a table absence breaches under APPLIED_UNVERIFIED"
else
    bad "2a FTH_B_TABLE=$FTH_B_TABLE — the breach was lost when COMMITTED stopped being claimed"
fi
if [[ "$FTH_REASON" != *"COMMITTED"* ]]; then
    ok "2a the breach reason does not assert COMMITTED"
else
    bad "2a breach reason still asserts COMMITTED: $FTH_REASON"
fi

# 2b. Pre-split callers that set only FTH_COMMITTED must keep working.
set_clean_sets
FTH_TABLE_PRESENT=N; FTH_COMMITTED=Y; FTH_APPLIED_UNVERIFIED=N
unset FTH_EXPECT_TABLE_PRESENT FTH_TABLE_EXPECT_BASIS
_fth_compute_breaches
if [[ "$FTH_B_TABLE" -eq 1 ]]; then
    ok "2b legacy FTH_COMMITTED-only callers still breach (derived one direction)"
else
    bad "2b FTH_B_TABLE=$FTH_B_TABLE — the split broke existing callers"
fi

# 2c. No expectation => no breach, even with the table absent.
set_clean_sets
FTH_TABLE_PRESENT=N; FTH_COMMITTED=N; FTH_APPLIED_UNVERIFIED=N
FTH_EXPECT_TABLE_PRESENT=N; FTH_TABLE_EXPECT_BASIS=""
_fth_compute_breaches
if [[ "$FTH_B_TABLE" -eq 0 ]]; then
    ok "2c no expectation, no breach (the predicate is not always-on)"
else
    bad "2c FTH_B_TABLE=$FTH_B_TABLE with nothing expecting the table"
fi

# 2d. Recovery window still exempts.
set_clean_sets
FTH_TABLE_PRESENT=N; FTH_EXPECT_TABLE_PRESENT=Y; FTH_IN_RECOVERY=Y
FTH_COMMITTED=N; FTH_APPLIED_UNVERIFIED=Y
_fth_compute_breaches
if [[ "$FTH_B_TABLE" -eq 0 ]]; then
    ok "2d an active recovery window still exempts the table breach"
else
    bad "2d FTH_B_TABLE=$FTH_B_TABLE during recovery — the exemption was dropped"
fi

# -----------------------------------------------------------------------------
# Section 3 — operator wording authorities.
# -----------------------------------------------------------------------------
echo "== 3. operator wording =="

# shellcheck source=/dev/null
source "$OUT"

if nftban_install_state_is_known_literal "APPLIED_UNVERIFIED"; then
    ok "3a APPLIED_UNVERIFIED is a known literal (not reported as 'UNKNOWN STATE')"
else
    bad "3a APPLIED_UNVERIFIED is not in the wording list — a real state would print as unrecognised"
fi

# ⛔ AND THE VERDICT PREDICATE MUST STILL REFUSE IT. Being nameable must never
#    become being acceptable.
if nftban_install_state_is_committed "APPLIED_UNVERIFIED"; then
    bad "3b the commit predicate accepted APPLIED_UNVERIFIED"
else
    ok "3b the commit predicate still refuses APPLIED_UNVERIFIED"
fi

SF="$SB/install_state"
printf 'INSTALL_STATE=APPLIED_UNVERIFIED\nAUTHORITY=UPDATE\nCONVERGENCE_VERIFIED=NOT_EVALUATED\nINSTALL_TIMESTAMP=2026-09-21T00:00:00Z\nPHASE_REACHED=VALIDATE\nINSTALL_VERSION=1.232.2\nFAILURE_REASON=\n' > "$SF"
RENDER=$(nftban_render_install_transaction_truth "$SF" "" || true)

if [[ "$RENDER" != *"did not complete"* ]]; then
    ok "3c the renderer does not claim the transaction 'did not complete'"
else
    bad "3c renderer says 'did not complete' about a transaction whose mutation applied"
fi
if [[ "$RENDER" == *"APPLIED, NOT CERTIFIED"* ]]; then
    ok "3c the renderer states what actually happened"
else
    bad "3c renderer did not identify the state:\n$RENDER"
fi
if [[ "$RENDER" == *"NOT_EVALUATED"* ]]; then
    ok "3c the renderer surfaces the convergence verdict"
else
    bad "3c renderer omitted CONVERGENCE_VERIFIED"
fi
# Control: a genuine failure must STILL get the generic sentence. Without this,
# the new branch could have been written as an unconditional rewrite.
printf 'INSTALL_STATE=FAILED_REBUILD\nAUTHORITY=UPDATE\nFAILURE_REASON=rebuild exited 3\n' > "$SF"
RENDER_FAIL=$(nftban_render_install_transaction_truth "$SF" "" || true)
if [[ "$RENDER_FAIL" == *"did not complete"* ]]; then
    ok "3d a real failure still reads 'did not complete' (the branch is conditional)"
else
    bad "3d FAILED_REBUILD lost its failure wording"
fi

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
