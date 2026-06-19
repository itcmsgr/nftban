#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.194.0 - CI Gate: Protection-Claim Matrix (8C)
# =============================================================================
# meta:name="check-protection-claim-matrix"
# meta:type="script"
# meta:version="1.194.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Static guard over the protection-claim matrix: completeness, field population, enum validity, owner-enforcement guard (claimed enforce + owner NONE must be unowned/deferred), dead-knob guard"
# meta:inventory.files="cli/lib/nftban/tests/protection_claim_matrix_v194.tsv"
# meta:inventory.binaries="bash,awk,grep,sort"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Enforces the v1.194.0 (8C) invariants so a claimed protection cannot silently
# regress to "no runtime owner" and a known dead knob cannot be represented as a
# live enforcer. Read-only, hermetic. Exit 0 = clean, 1 = violation.
# =============================================================================
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MATRIX="${PCM_MATRIX:-$REPO_ROOT/cli/lib/nftban/tests/protection_claim_matrix_v194.tsv}"
EXPECT_ROWS="${PCM_EXPECT_ROWS:-21}"
DEAD_KNOBS=(WordPressXMLRPC WordPressWPLogin)
OWNER_ENUM="BotScan LoginMon BotGuard DDoS/kernel Portscan/kernel Feeds/GeoBan Suricata NONE"
MODE_ENUM="enforce suppress observe-only"
CLASS_ENUM="validated false-claim dead-knob unowned legacy-only unproven deferred observe-only suppress"

FAIL=0
echo "========================================"
echo "NFTBan Architecture Check: Protection-Claim Matrix (8C)"
echo "========================================"
[[ -f "$MATRIX" ]] || { echo "::error::matrix not found: $MATRIX"; exit 1; }

# Strip comments/blank lines → data rows.
mapfile -t ROWS < <(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$MATRIX")

# 1) Row count.
if [[ "${#ROWS[@]}" -ne "$EXPECT_ROWS" ]]; then
    echo "::error::expected $EXPECT_ROWS claim rows, found ${#ROWS[@]} (amend PCM_EXPECT_ROWS only with a scope change)"; FAIL=1
else
    echo "  [OK] row count = ${#ROWS[@]}"
fi

# 2) Unique CLAIM_IDs.
dups="$(printf '%s\n' "${ROWS[@]}" | awk -F'|' '{print $1}' | sort | uniq -d)"
[[ -z "$dups" ]] && echo "  [OK] CLAIM_IDs unique" || { echo "::error::duplicate CLAIM_ID(s): $dups"; FAIL=1; }

in_enum(){ case " $2 " in *" $1 "*) return 0;; *) return 1;; esac; }

# 3) Per-row: 11 populated fields + enum validity + guards.
ow_guard=0; dk_guard=0; field_bad=0; enum_bad=0
for r in "${ROWS[@]}"; do
    # shellcheck disable=SC2034  # EVENT/SOURCE/CONSUMER/ZERO/EXPECT validated for non-empty below, not by name
    IFS='|' read -r CLAIM EVENT SOURCE OWNER CONSUMER BANAUTH MODE ZERO FIXTURE EXPECT CLASS extra <<< "$r"
    nf=$(awk -F'|' '{print NF}' <<< "$r")
    if [[ "$nf" -ne 11 ]]; then echo "::error::$CLAIM: expected 11 fields, got $nf"; field_bad=1; continue; fi
    for v in "$CLAIM" "$EVENT" "$SOURCE" "$OWNER" "$CONSUMER" "$BANAUTH" "$MODE" "$ZERO" "$FIXTURE" "$EXPECT" "$CLASS"; do
        [[ -z "$v" ]] && { echo "::error::$CLAIM: empty field"; field_bad=1; }
    done
    in_enum "$OWNER" "$OWNER_ENUM" || { echo "::error::$CLAIM: bad OWNER '$OWNER'"; enum_bad=1; }
    in_enum "$MODE"  "$MODE_ENUM"  || { echo "::error::$CLAIM: bad MODE '$MODE'"; enum_bad=1; }
    in_enum "$CLASS" "$CLASS_ENUM" || { echo "::error::$CLAIM: bad CLASSIFICATION '$CLASS'"; enum_bad=1; }
    # Owner-enforcement guard: enforce + owner NONE only if unowned/deferred.
    if [[ "$MODE" == "enforce" && "$OWNER" == "NONE" ]]; then
        if [[ "$CLASS" != "unowned" && "$CLASS" != "deferred" ]]; then
            echo "::error::$CLAIM: MODE=enforce + OWNER=NONE but CLASSIFICATION='$CLASS' (must be unowned/deferred with evidence — a CLAIMED protection with no owner is a protection-claim bug)"; ow_guard=1
        fi
    fi
    # Dead-knob guard: a dead knob must never be the live OWNER or BAN_AUTHORITY.
    for k in "${DEAD_KNOBS[@]}"; do
        if [[ "$OWNER" == *"$k"* || "$BANAUTH" == *"$k"* ]]; then
            echo "::error::$CLAIM: dead knob '$k' represented as a live OWNER/BAN_AUTHORITY (it is parsed-never-used)"; dk_guard=1
        fi
    done
done
[[ "$field_bad" -eq 0 ]] && echo "  [OK] every row has 11 populated fields" || FAIL=1
[[ "$enum_bad"  -eq 0 ]] && echo "  [OK] OWNER/MODE/CLASSIFICATION enums valid" || FAIL=1
[[ "$ow_guard"  -eq 0 ]] && echo "  [OK] owner-enforcement guard (no claimed-enforce row orphaned to owner=NONE)" || FAIL=1
[[ "$dk_guard"  -eq 0 ]] && echo "  [OK] dead-knob guard (WordPressXMLRPC/WordPressWPLogin not a live enforcer)" || FAIL=1

# 4) Positive: the xmlrpc/endpoint-flood claim is owned by BotScan (the live detector), not a dead knob.
ef="$(printf '%s\n' "${ROWS[@]}" | awk -F'|' '$1=="ENDPOINT-FLOOD-XMLRPC-WPLOGIN"')"
if [[ -n "$ef" ]] && awk -F'|' '{exit !($4=="BotScan")}' <<< "$ef"; then
    echo "  [OK] xmlrpc/wp-login endpoint-flood owned by BotScan (closed v1.190.1, not the dead Go knob)"
else
    echo "::error::ENDPOINT-FLOOD-XMLRPC-WPLOGIN row missing or not owned by BotScan"; FAIL=1
fi

echo "========================================"
if [[ "$FAIL" -eq 0 ]]; then echo "RESULT: PASS — protection-claim matrix invariants hold"; exit 0; fi
echo "RESULT: FAIL — protection-claim matrix violation (see ::error:: above)"; exit 1
