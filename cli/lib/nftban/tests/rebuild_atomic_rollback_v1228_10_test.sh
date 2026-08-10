#!/usr/bin/env bash
# =============================================================================
# NFTBan - atomic rollback (v1.228.10 A1)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="rebuild_atomic_rollback_v1228_10_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-10"
# meta:description="INV-P0-02: rollback must never create a standalone unfiltered interval, and must never mutate foreign tables. Extracts the REAL _rebuild_rollback() from cmd_firewall.sh and drives it with a recording nft shim. Proves rollback eligibility consumes the A2 snapshot_state contract exactly as merged (VALID eligible; EMPTY_VERIFIED and FAILED refused with ZERO mutation), that the commit is ONE nft -f over an NFTBan-scoped self-resetting candidate, that no global flush is ever issued, that foreign tables are never named, and that a commit failure leaves the prior ruleset active. Includes the ATOMIC_ROLLBACK_NOT_INERT positive control so refusing everything cannot masquerade as safety."
# meta:input="None (sandbox fixtures)"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,awk,grep,sed,mktemp"
# meta:inventory.files="cli/lib/nftban/cli/cmd_firewall.sh"
# meta:inventory.binaries="bash,awk,grep,sed,mktemp"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="rebuild_atomic_rollback_v1228_10_test"
# meta:ta.owner="firewall"
# meta:ta.module="firewall-rebuild"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
SRC="$REPO_ROOT/cli/lib/nftban/cli/cmd_firewall.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✓ $1"; }
no() { FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

echo "=== rebuild_atomic_rollback_v1228_10 ==="
[[ -f "$SRC" ]] || { echo "  FATAL: $SRC not found"; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

FN="$WORK/fn.sh"
awk '/^_rebuild_rollback\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$SRC" > "$FN"
grep -q '_rebuild_rollback()' "$FN" && ok "extracted _rebuild_rollback() from cmd_firewall.sh" \
    || { no "could not extract _rebuild_rollback()"; echo "FAIL=$FAIL"; exit 1; }

# A snapshot as the product actually captures it: the COMPLETE HOST ruleset, so it
# contains foreign tables the rollback must never touch.
mk_snapshot() { # $1=dir  $2=state
    mkdir -p "$1"
    cat > "$1/ruleset.nft" <<'EOF'
table inet docker {
	chain forward {
		type filter hook forward priority 0;
	}
}
table ip nftban {
	set blacklist_ipv4 {
		type ipv4_addr
	}
	chain input {
		type filter hook input priority 0; policy drop;
	}
}
table ip6 nftban {
	set blacklist_ipv6 {
		type ipv6_addr
	}
}
table ip panelfw {
	chain input {
		type filter hook input priority 10;
	}
}
EOF
    printf 'state=%s\nreason=fixture\n' "$2" > "$1/snapshot_state"
}

# Recording nft shim. NFT_FAIL controls which invocation fails.
run_rollback() { # $1=snapshot dir ; env NFT_FAIL=none|check|commit  -> echoes rc
    local d="$1"
    : > "$d/nft.log"
    (
        NFT_LOG="$d/nft.log"; export NFT_LOG
        nft() {
            printf '%s\n' "$*" >> "$NFT_LOG"
            case "${NFT_FAIL:-none}" in
                check)  [[ "$1" == "-c" ]] && return 1 ;;
                commit) [[ "$1" == "-f" ]] && return 1 ;;
            esac
            return 0
        }
        # shellcheck source=/dev/null
        . "$FN"
        _rebuild_rollback "$d"
    ) >/dev/null 2>&1
    echo $?
}

logged()     { grep -qF -- "$2" "$1/nft.log" 2>/dev/null; }
# grep -c PRINTS 0 and EXITS 1 on no-match, so `|| echo 0` would emit a second zero.
# That defect made every "zero mutation" assertion compare against "0\n0" and fail.
mutations()  { grep -cE '^-f |^-c -f ' "$1/nft.log" 2>/dev/null; true; }
commits()    { grep -cE '^-f ' "$1/nft.log" 2>/dev/null; true; }

# ---------------------------------------------------------------- eligibility
echo "--- A. rollback eligibility consumes the A2 snapshot_state contract ---"
for st in FAILED EMPTY_VERIFIED; do
    D="$WORK/s_$st"; mk_snapshot "$D" "$st"
    RC=$(run_rollback "$D")
    [[ "$RC" != "0" ]] && ok "$st: refused (rc=$RC)" || no "$st: rollback proceeded"
    [[ "$(mutations "$D")" == "0" ]] && ok "$st: ZERO nft invocation — refused before -c and -f" \
        || no "$st: nft was invoked" "$(head -1 "$D/nft.log")"
done
D="$WORK/s_missing"; mk_snapshot "$D" X; rm -f "$D/snapshot_state"
RC=$(run_rollback "$D")
[[ "$RC" != "0" && "$(mutations "$D")" == "0" ]] && ok "missing snapshot_state: refused, zero mutation" \
    || no "missing snapshot_state: not refused cleanly"

# ---------------------------------------------------------------- valid path
echo "--- B. VALID: one transaction, NFTBan-scoped, pre-validated ---"
D="$WORK/s_valid"; mk_snapshot "$D" VALID
RC=$(run_rollback "$D")
[[ "$RC" == "0" ]] && ok "VALID: rollback succeeded (rc=0)" || no "VALID: rc=$RC"
[[ "$(commits "$D")" == "1" ]] && ok "exactly ONE commit transaction (nft -f)" \
    || no "commit count = $(commits "$D"), expected 1"
logged "$D" "-c -f" && ok "pre-validation ran (nft -c -f) before commit" || no "no nft -c pre-validation"
grep -qE '^flush ruleset|^-f$' "$D/nft.log" && no "a global flush was issued" \
    || ok "NO global 'nft flush ruleset' anywhere"

# The candidate is retained on failure (operator forensics), so inspect that sandbox.
D2="$WORK/s_valid2"; mk_snapshot "$D2" VALID; NFT_FAIL=commit run_rollback "$D2" >/dev/null
CAND="$D2/rollback_candidate.nft"
if [[ -f "$CAND" ]]; then
    grep -q "docker" "$CAND" && no "FOREIGN table 'docker' appears in the candidate" \
        || ok "foreign table 'docker' never named in the candidate"
    grep -q "panelfw" "$CAND" && no "FOREIGN table 'panelfw' appears in the candidate" \
        || ok "foreign table 'panelfw' never named in the candidate"
    grep -q "table ip nftban { }" "$CAND" && ok "self-resetting idiom present (idempotent create)" \
        || no "no idempotent create in the candidate"
    grep -q "^delete table ip nftban" "$CAND" && ok "delete precedes the definition, inside the same file" \
        || no "no scoped delete in the candidate"
    grep -q "blacklist_ipv4" "$CAND" && ok "the snapshot's nftban content IS restored" \
        || no "nftban content missing from the candidate"
else
    no "candidate file not produced for inspection"
fi

# ---------------------------------------------------------------- failures
echo "--- C. failure paths mutate nothing / leave prior ruleset active ---"
D="$WORK/s_badsyntax"; mk_snapshot "$D" VALID
RC=$(NFT_FAIL=check run_rollback "$D")
[[ "$RC" != "0" ]] && ok "validation failure: rc!=0" || no "validation failure returned 0"
[[ "$(commits "$D")" == "0" ]] && ok "validation failure: NO commit attempted — zero mutation" \
    || no "a commit was attempted after failed validation"

D="$WORK/s_commitfail"; mk_snapshot "$D" VALID
RC=$(NFT_FAIL=commit run_rollback "$D")
[[ "$RC" != "0" ]] && ok "commit failure: rc!=0 (INV-P0-05 truthful failure)" || no "commit failure returned 0"
grep -qE '^flush ruleset' "$D/nft.log" && no "a flush preceded the failed commit — unfiltered interval" \
    || ok "commit failure: no preceding flush, so no standalone unfiltered interval"

D="$WORK/s_nonftban"; mkdir -p "$D"
printf 'table inet docker {\n\tchain forward {\n\t}\n}\n' > "$D/ruleset.nft"
printf 'state=VALID\n' > "$D/snapshot_state"
RC=$(run_rollback "$D")
[[ "$RC" != "0" && "$(mutations "$D")" == "0" ]] && ok "snapshot with no nftban table: refused, zero mutation" \
    || no "foreign-only snapshot was acted upon"

# ---------------------------------------------------------------- not inert
echo "--- D. ATOMIC_ROLLBACK_NOT_INERT (refusing everything is not safety) ---"
D="$WORK/s_notinert"; mk_snapshot "$D" VALID
RC=$(run_rollback "$D")
if [[ "$RC" == "0" && "$(commits "$D")" == "1" ]]; then
    ok "a VALID snapshot IS actually restored — the fix is not 'refuse everything'"
else
    no "VALID snapshot did not restore" "rc=$RC commits=$(commits "$D")"
fi

# ---------------------------------------------------------------- guard
echo "--- E. the atomicity guard now covers this lane ---"
G="$REPO_ROOT/scripts/ci/check-nft-atomicity.sh"
if [[ -f "$G" ]]; then
    grep -q "_rebuild_rollback" <(grep -E "^REBUILD_EXEMPT=" "$G") \
        && no "_rebuild_rollback is still exempt from the atomicity guard" \
        || ok "_rebuild_rollback is no longer exempt"
    grep -q "nft\[\[:space:\]\]+flush\[\[:space:\]\]+ruleset" "$G" \
        && ok "guard pattern detects the global 'nft flush ruleset' form" \
        || no "guard still blind to global flush"
else
    no "check-nft-atomicity.sh not found"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
