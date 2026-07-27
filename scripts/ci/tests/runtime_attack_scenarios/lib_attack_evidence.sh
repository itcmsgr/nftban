#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# meta:name="lib_attack_evidence"
# meta:type="test-library"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Shared evidence primitives for the cross-VM runtime attack matrix. Enforces the invariant NO DETECTION PASS WITHOUT PROVEN FIREWALL EFFECT: a ban counts only when the set is referenced by a drop rule in a HOOKED chain, the named counter moves under real traffic, and the attacker observes the block."
# =============================================================================
#
# CONTRACT. Sourced by each scenario. The scenario provides two command
# prefixes so the library is location-independent (controller, hypervisor, or
# dev box via ProxyJump):
#
#   ATTACK_RUN   run one command ON the attacker VM (no NFTBan)
#   TARGET_RUN   run one command ON the protected target (via the MANAGEMENT path)
#   ATTACKER_IP  the attacker's source address AS THE TARGET SEES IT (attack seg)
#   TARGET_IP    the target's address on the ATTACK segment
#   MGMT_IP      the target's management address — banning this is PROHIBITED
#
# Acceptance statuses, per owner spec. A scenario never collapses these:
#   PASS · FAIL_PRODUCT · FAIL_HARNESS · FAIL_ENVIRONMENT · NOT_APPLICABLE · NOT_YET_VERIFIED
#
# set -Eeuo pipefail is the caller's responsibility; helpers below assume it.

: "${ATTACK_RUN:?scenario must set ATTACK_RUN}"
: "${TARGET_RUN:?scenario must set TARGET_RUN}"
: "${ATTACKER_IP:?scenario must set ATTACKER_IP}"
: "${TARGET_IP:?scenario must set TARGET_IP}"
: "${MGMT_IP:?scenario must set MGMT_IP}"

PASS_N=0; FAIL_N=0
# Only FINAL_STATUS is read (scenario_summary). A per-label array was assigned by
# every helper and never read — dead state, and shellcheck was right to say so.
FINAL_STATUS=PASS

# escalate the run's final status, honouring severity ordering
_escalate(){ # new_status
    local n="$1"
    case "$n" in
        FAIL_PRODUCT)     FINAL_STATUS=FAIL_PRODUCT ;;
        FAIL_HARNESS)     [[ "$FINAL_STATUS" == FAIL_PRODUCT ]] || FINAL_STATUS=FAIL_HARNESS ;;
        FAIL_ENVIRONMENT) [[ "$FINAL_STATUS" =~ FAIL_ ]]        || FINAL_STATUS=FAIL_ENVIRONMENT ;;
        NOT_YET_VERIFIED) [[ "$FINAL_STATUS" =~ FAIL_ ]]        || FINAL_STATUS=INCOMPLETE ;;
    esac
}
pass(){ echo "[PASS] $1"; PASS_N=$((PASS_N+1)); }
fail(){ # status label
    local st="$1"; shift
    echo "[$st] $1"; FAIL_N=$((FAIL_N+1)); _escalate "$st"
}
info(){ echo "[INFO] $1"; }
na(){   echo "[N/A ] $1"; }
nyv(){  echo "[NYV ] $1"; _escalate NOT_YET_VERIFIED; }

# --- kernel evidence primitives (all read the TARGET's real kernel state) -----

# set membership — necessary but NOT sufficient for enforcement
in_set(){ # table set ip  -> 0 if present
    $TARGET_RUN "sudo nft list set $1 nftban $2 2>/dev/null | grep -qF '$3'"
}

# the ENFORCEMENT proof: the set is referenced by a drop/reject rule whose chain
# is a base chain WITH A HOOK. Set membership alone is the shipped-P0 trap.
set_enforced_by_hooked_drop(){ # family setname  -> prints "chain|handle" or empty
    local fam="$1" set="$2"
    $TARGET_RUN "sudo nft -a list table ${fam} nftban 2>/dev/null" > "$WORK/ruleset.txt" 2>/dev/null || return 1
    # find each chain's hook status, then the drop rule that references @set
    awk -v S="@${set}" '
        /^[[:space:]]*chain [a-z_]+ \{/ { chain=$2 }
        /type .* hook .* priority/      { hooked[chain]=1 }
        $0 ~ S && /drop|reject/ {
            # capture handle
            h="?"; for(i=1;i<=NF;i++) if($i=="handle") h=$(i+1);
            print chain"|"h"|"(hooked[chain]?"HOOKED":"UNHOOKED")
        }
    ' "$WORK/ruleset.txt"
}

# named-counter value on the target (0 if absent)
counter_val(){ # family name
    $TARGET_RUN "sudo nft list counter $1 nftban $2 2>/dev/null" \
        | grep -oE 'packets [0-9]+' | awk '{print $2}' | head -1
}

# packet-level effect FROM THE ATTACKER: can it open TCP to target:port?
# echoes "open" | "blocked" — blocked = timeout or refused, both mean not-through.
attacker_tcp(){ # port timeout_s
    local port="$1" to="${2:-4}"
    if $ATTACK_RUN "timeout $to bash -c 'exec 3<>/dev/tcp/${TARGET_IP}/${port}' 2>/dev/null"; then
        echo open
    else
        echo blocked
    fi
}

# --- safety: refuse to proceed if the ban target could cut management ---------
assert_ban_target_safe(){
    if [[ "$ATTACKER_IP" == "$MGMT_IP" ]]; then
        fail FAIL_HARNESS "SAFETY: attacker IP equals management IP ($MGMT_IP) — refusing to ban the mgmt path"
        return 1
    fi
    if in_set ip whitelist_ipv4 "$ATTACKER_IP"; then
        fail FAIL_HARNESS "SAFETY: attacker IP $ATTACKER_IP is whitelisted — a ban would be a silent no-op"
        return 1
    fi
    pass "SAFETY: ban target $ATTACKER_IP is neither the mgmt IP nor whitelisted"
}

# every generator has a hard cap; every scenario cleans up on exit
scenario_summary(){ # scenario_id
    echo "----------------------------------------"
    echo "NFTBAN_ATTACK_${1}_PASS=$PASS_N"
    echo "NFTBAN_ATTACK_${1}_FAIL=$FAIL_N"
    echo "NFTBAN_ATTACK_${1}_STATUS=$FINAL_STATUS"
    [[ "$FINAL_STATUS" == PASS ]] && return 0
    [[ "$FINAL_STATUS" == INCOMPLETE ]] && return 2
    return 1
}
