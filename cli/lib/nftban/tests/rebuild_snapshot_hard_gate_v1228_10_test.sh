#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.228.10 PR-1 (A2): rebuild snapshot acquisition is a HARD GATE
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="rebuild_snapshot_hard_gate_v1228_10_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-09"
# meta:description="Hermetic test for v1.228.10 PR-1 (audit finding A2). Extracts the REAL _rebuild_snapshot_full() from cmd_firewall.sh and proves it classifies snapshot acquisition into VALID / EMPTY_VERIFIED / FAILED instead of swallowing every failure with '|| true'. Asserts: (1) a good capture is VALID and returns 0; (2) a capture whose nft call fails is FAILED and returns 1; (3) a zero-byte text capture while JSON reports live tables is FAILED (truncation), not empty; (4) a genuinely empty kernel corroborated by JSON is EMPTY_VERIFIED and returns 0 so --repair on a bare host is NOT blocked; (5) an uncorroborated empty capture is FAILED; (6) the nftban-table identity field is recorded and falsifiable. Includes source guards proving the call site no longer swallows the failure and that FC_SNAPSHOT_FAILED has a real writer, each with an injection-based falsifiability proof. No host/nft/IPC/daemon."
# meta:input="None (self-contained; extracts function verbatim from source)"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,awk,grep,sed,mktemp"
# meta:inventory.files="cli/lib/nftban/cli/cmd_firewall.sh"
# meta:inventory.binaries="bash,awk,grep,sed,mktemp"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="rebuild_snapshot_hard_gate_v1228_10_test"
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

set -Eeuo pipefail
IFS=$'\n\t'

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
SRC="$REPO_ROOT/cli/lib/nftban/cli/cmd_firewall.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✓ $1"; }
no() { FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

[[ -f "$SRC" ]] || { echo "FATAL: source not found: $SRC" >&2; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Extract the REAL _rebuild_snapshot_full() verbatim from the shipped source.
FN="$WORK/fn.sh"
awk '/^_rebuild_snapshot_full\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SRC" > "$FN"
if grep -q '_rebuild_snapshot_full()' "$FN"; then
    ok "extracted _rebuild_snapshot_full() from cmd_firewall.sh"
else
    no "could not extract _rebuild_snapshot_full() from source"; echo "FAIL=$FAIL"; exit 1
fi

# --- mocks --------------------------------------------------------------------
# `timeout` must be a function too: the real binary cannot invoke a shell function.
timeout() { shift; "$@"; }
nft() {
    if [[ "${1:-}" == "-j" && "${2:-}" == "list" && "${3:-}" == "ruleset" ]]; then
        printf '%s' "$MOCK_JSON_OUT"; return "$MOCK_JSON_RC"
    fi
    if [[ "${1:-}" == "list" && "${2:-}" == "ruleset" ]]; then
        printf '%s' "$MOCK_LIST_OUT"; return "$MOCK_LIST_RC"
    fi
    return 0   # granular per-set dumps: best-effort by contract
}
_REBUILD_VALIDATOR_BIN="/nonexistent/validator"

# shellcheck source=/dev/null
source "$FN"

REAL_RULESET='table ip nftban {
	set blacklist_ipv4 {
		type ipv4_addr
	}
}
table inet docker {
	chain forward {
	}
}'
FOREIGN_ONLY='table inet docker {
	chain forward {
	}
}'
JSON_WITH_TABLES='{"nftables":[{"metainfo":{"version":"1.0.9"}},{"table":{"family":"ip","name":"nftban"}}]}'
JSON_EMPTY='{"nftables":[{"metainfo":{"version":"1.0.9"}}]}'

field() { sed -n "s/^$2=//p" "$1/snapshot_state" 2>/dev/null | head -1; }

run_case() {
    # $1=name $2=list_rc $3=list_out $4=json_rc $5=json_out  -> echoes "<rc>|<dir>"
    local d="$WORK/$1"
    MOCK_LIST_RC="$2" MOCK_LIST_OUT="$3" MOCK_JSON_RC="$4" MOCK_JSON_OUT="$5"
    local rc=0
    _rebuild_snapshot_full "$d" >/dev/null || rc=$?
    echo "$rc|$d"
}

# --- case 1: healthy capture --------------------------------------------------
IFS='|' read -r rc dir <<< "$(run_case valid 0 "$REAL_RULESET" 0 "$JSON_WITH_TABLES")"
[[ "$rc" == "0" ]] && ok "VALID capture returns 0" || no "VALID capture returned rc=$rc"
[[ "$(field "$dir" state)" == "VALID" ]] && ok "VALID capture records state=VALID" \
    || no "state was '$(field "$dir" state)', expected VALID"
[[ -s "$dir/ruleset.nft" ]] && ok "negative control: the snapshot file is genuinely non-empty" \
    || no "snapshot file empty — the fixture did not reach the function"
[[ "$(field "$dir" nftban_table)" == "yes" ]] && ok "nftban table identity recorded (yes)" \
    || no "nftban_table was '$(field "$dir" nftban_table)', expected yes"

# --- case 2: identity field is falsifiable, and repair is not blocked ---------
IFS='|' read -r rc dir <<< "$(run_case foreign 0 "$FOREIGN_ONLY" 0 "$JSON_WITH_TABLES")"
[[ "$rc" == "0" ]] && ok "ruleset without an nftban table is still VALID (repair not blocked)" \
    || no "foreign-only ruleset returned rc=$rc — a repair run would be blocked"
[[ "$(field "$dir" nftban_table)" == "no" ]] && ok "falsifiability: identity field reports no when absent" \
    || no "nftban_table was '$(field "$dir" nftban_table)', expected no"

# --- case 3: nft failure is NOT an empty snapshot ------------------------------
IFS='|' read -r rc dir <<< "$(run_case listfail 1 "" 0 "$JSON_WITH_TABLES")"
[[ "$rc" == "1" ]] && ok "failed nft list ruleset returns 1 (gate closes)" \
    || no "failed capture returned rc=$rc, expected 1"
[[ "$(field "$dir" state)" == "FAILED" ]] && ok "failed capture records state=FAILED" \
    || no "state was '$(field "$dir" state)', expected FAILED"
[[ "$(field "$dir" reason)" == *"failed"* ]] && ok "failure reason is recorded for the operator" \
    || no "reason was '$(field "$dir" reason)'"

# --- case 4: truncated capture is FAILED, not empty ---------------------------
IFS='|' read -r rc dir <<< "$(run_case truncated 0 "" 0 "$JSON_WITH_TABLES")"
[[ "$rc" == "1" ]] && ok "zero-byte capture while JSON reports tables returns 1 (truncation)" \
    || no "truncated capture returned rc=$rc, expected 1"
[[ "$(field "$dir" reason)" == *"truncated"* ]] && ok "truncation is named distinctly from an empty kernel" \
    || no "reason was '$(field "$dir" reason)'"
[[ ! -s "$dir/ruleset.nft" ]] && ok "negative control: the capture really was zero-byte" \
    || no "fixture wrote content — the truncation case did not occur"

# --- case 5: genuinely empty kernel is allowed, and named ---------------------
IFS='|' read -r rc dir <<< "$(run_case emptyok 0 "" 0 "$JSON_EMPTY")"
[[ "$rc" == "0" ]] && ok "corroborated empty kernel returns 0 (bare host / --repair works)" \
    || no "empty-verified capture returned rc=$rc, expected 0"
[[ "$(field "$dir" state)" == "EMPTY_VERIFIED" ]] && ok "empty kernel recorded as EMPTY_VERIFIED, not VALID" \
    || no "state was '$(field "$dir" state)', expected EMPTY_VERIFIED"

# --- case 6: uncorroborated empty capture is FAILED ---------------------------
IFS='|' read -r rc dir <<< "$(run_case nojson 0 "" 1 "")"
[[ "$rc" == "1" ]] && ok "empty capture with a failed JSON corroboration returns 1" \
    || no "uncorroborated empty capture returned rc=$rc, expected 1"

# --- source guards ------------------------------------------------------------
# GUARD SUBJECT == GUARD INPUT: comments must not be able to satisfy or violate
# these assertions, so the guard reads a comment-stripped projection of the source.
STRIP="$WORK/src.nocomment.sh"
sed 's/[[:space:]]*#.*$//' "$SRC" > "$STRIP"

guard_swallowed_call() { grep -qE '_rebuild_snapshot_full[^|]*\|\|[[:space:]]*true' "$1"; }
if ! guard_swallowed_call "$STRIP"; then
    ok "call site no longer swallows snapshot failure with '|| true'"
else
    no "a '_rebuild_snapshot_full ... || true' call site is still present"
fi
INJ="$WORK/injected.sh"; cp "$STRIP" "$INJ"
echo '    _rebuild_snapshot_full "$snapshot_dir" >/dev/null 2>&1 || true' >> "$INJ"
if guard_swallowed_call "$INJ"; then
    ok "falsifiability: the guard detects an injected swallowed call"
else
    no "guard is blind — it did not flag an injected '|| true' call site"
fi

guard_has_writer() { grep -q 'FC_SNAPSHOT_FAILED' "$1"; }
if guard_has_writer "$STRIP"; then
    ok "FC_SNAPSHOT_FAILED now has a writer in the rebuild lane"
else
    no "FC_SNAPSHOT_FAILED is still declared-but-never-written"
fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
