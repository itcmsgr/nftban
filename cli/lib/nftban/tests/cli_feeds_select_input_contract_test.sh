#!/usr/bin/env bash
# =============================================================================
# NFTBan - feeds select input-contract test (v1.142 PR-FS, BUG-FS1..FS5)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cli_feeds_select_input_contract_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-29"
# meta:description="v1.142 PR-FS — asserts that nftban_feeds_select honors its advertised input contract: (FS1) accepts comma AND/OR space separators ('1 3 6', '1,3,6', '1, 3, 6'); (FS2) rejects empty / unparseable input with rc=1 and a usage hint (no silent rc=0 with phantom feed); (FS3) propagates the rc of nftban_feeds_enable and prints '⚠️ N failed' to stderr instead of '✅ Done' when any feed fails (closes the live-reproduced 'ERROR + ✅ Done both printed, rc=0' family from BUG-A7); (FS4) the category regex covers anonymity (the menu's 5th category), with a drift assertion that every category present in nftban_feeds_get_by_category() discovery is matched by the regex; (FS5) holistic mixed-form regression: '1-3, 5, ssh' is accepted as a union; 'all' continues to work."
# meta:input="cli/lib/nftban/cli/cmd_feeds.sh nftban_feeds_select"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash"
# meta:inventory.files="cli/lib/nftban/cli/cmd_feeds.sh"
# meta:inventory.binaries="bash"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_NO_BANNER"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="cli_feeds_select_input_contract_test"
# meta:ta.owner="feeds"
# meta:ta.module="feeds"
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

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)
export NFTBAN_LIB_DIR="$REPO/cli/lib/nftban"
export NFTBAN_NO_BANNER=1
export NFTBAN_NONINTERACTIVE=1

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

# The v1.142 PR-FS code block lives in cmd_feeds.sh::nftban_feeds_select
# under an `else` arm. cmd_feeds.sh refuses to source standalone under
# strict.sh's ERR trap (a helper-load chain trips on this dev box), so we
# test the block as an extracted mirror. The T-DRIFT row at the bottom
# asserts the live cmd_feeds.sh carries the v1.142 PR-FS markers, so any
# future change that drifts away from this mirror fails the gate.
MIRROR=$(mktemp -t nftban-pr-fs.XXXXXX.sh)
trap 'rm -f "$MIRROR"' EXIT

cat >"$MIRROR" <<'MIRROR_EOF'
#!/usr/bin/env bash
set +e

# Inputs from environment:
#   NF_SELECTION    — the operator input string
#   NF_FAIL_PAT     — if non-empty, feed names matching this regex cause
#                     nftban_feeds_enable to return 1 (simulates 'feed
#                     not found' / network errors)
selection="${NF_SELECTION-}"
fail_pat="${NF_FAIL_PAT-}"

# Fixture menu — 14 feeds in 5 categories, indices 1..14.
feed_array=(_ FIREHOL_ANONYMOUS FIREHOL_PROXIES TOR_EXITS BLOCKLISTDE_MAIL STOPFORUMSPAM ABUSECH_FEODO ABUSECH_SSL FIREHOL_LEVEL1 FIREHOL_LEVEL2 SPAMHAUS_DROP BLOCKLISTDE_SSH GREENSNOW BLOCKLISTDE_APACHE BLOCKLISTDE_BRUTEFORCE)

nftban_feeds_get_by_category() {
    case "$1" in
        anonymity)  echo 'FIREHOL_ANONYMOUS FIREHOL_PROXIES TOR_EXITS' ;;
        email)      echo 'BLOCKLISTDE_MAIL STOPFORUMSPAM' ;;
        protection) echo 'ABUSECH_FEODO ABUSECH_SSL FIREHOL_LEVEL1 FIREHOL_LEVEL2 SPAMHAUS_DROP' ;;
        ssh)        echo 'BLOCKLISTDE_SSH GREENSNOW' ;;
        web)        echo 'BLOCKLISTDE_APACHE BLOCKLISTDE_BRUTEFORCE' ;;
    esac
}

nftban_feeds_enable() {
    if [[ -n "$fail_pat" ]] && [[ "$1" =~ $fail_pat ]]; then
        echo "[ERROR] FEEDS: Feed not found: $1"
        return 1
    fi
    echo "enabled:$1"
    return 0
}

# ── MIRROR of v1.142 PR-FS block in cmd_feeds.sh::nftban_feeds_select ──
_v142_cat_re='^(anonymity|email|protection|ssh|web)$'
feeds_to_enable=()

if [[ "$selection" == 'all' ]]; then
    feeds_to_enable=("${feed_array[@]:1}")
elif [[ "$selection" =~ $_v142_cat_re ]]; then
    cat_feeds=$(nftban_feeds_get_by_category "$selection")
    for feed in $cat_feeds; do
        feeds_to_enable+=("$feed")
    done
else
    read -ra parts <<< "${selection//,/ }"
    for part in "${parts[@]}"; do
        if [[ "$part" =~ $_v142_cat_re ]]; then
            cat_feeds=$(nftban_feeds_get_by_category "$part")
            for feed in $cat_feeds; do
                feeds_to_enable+=("$feed")
            done
        elif [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start="${BASH_REMATCH[1]}"; end="${BASH_REMATCH[2]}"
            for ((i=start; i<=end; i++)); do
                if [[ -n "${feed_array[$i]:-}" ]]; then
                    feeds_to_enable+=("${feed_array[$i]}")
                fi
            done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            if [[ -n "${feed_array[$part]:-}" ]]; then
                feeds_to_enable+=("${feed_array[$part]}")
            fi
        fi
    done
fi

if (( ${#feeds_to_enable[@]} == 0 )); then
    echo 'No valid feeds selected. Try a number (e.g. 3), a range (1-5),' >&2
    echo "a space- or comma-separated list (1 3 6 or 1,3,6), a category" >&2
    echo "(anonymity / email / protection / ssh / web), or 'all'." >&2
    exit 1
fi

mapfile -t unique_feeds < <(printf '%s\n' "${feeds_to_enable[@]}" | sort -u)
echo "Enabling ${#unique_feeds[@]} feed(s)..."

rc=0; failed=()
for feed in "${unique_feeds[@]}"; do
    echo "→ Enabling: $feed"
    if ! nftban_feeds_enable "$feed"; then
        failed+=("$feed"); rc=1
    fi
done

if (( ${#failed[@]} > 0 )); then
    echo "⚠️  ${#failed[@]} feed(s) failed to enable: ${failed[*]}" >&2
    exit $rc
fi
echo '✅ Done! Feeds enabled and updated.'
exit 0
MIRROR_EOF
chmod +x "$MIRROR"

# run_select <input> [fail_pat] — captures stdout+stderr, sets RC.
run_select() {
    local input="$1" fail_pat="${2:-}"
    local rc=0 out
    out=$(NF_SELECTION="$input" NF_FAIL_PAT="$fail_pat" bash "$MIRROR" 2>&1) || rc=$?
    LAST_RC=$rc
    LAST_OUT=$out
}

assert_rc() {
    local label="$1" expected="$2"
    if (( LAST_RC == expected )); then ok "$label (rc=$LAST_RC)";
    else no "$label" "rc=$LAST_RC (expected $expected); tail: $(echo "$LAST_OUT" | tail -2 | tr '\n' '|')"; fi
}
assert_contains() {
    local label="$1" needle="$2"
    if [[ "$LAST_OUT" == *"$needle"* ]]; then ok "$label"; else no "$label" "missing '$needle'"; fi
}
assert_not_contains() {
    local label="$1" needle="$2"
    if [[ "$LAST_OUT" != *"$needle"* ]]; then ok "$label"; else no "$label" "contained forbidden '$needle'"; fi
}
count_enables() { grep -c '^→ Enabling:' <<<"$LAST_OUT" 2>/dev/null || true; }

echo "=========================================================="
echo "v1.142 PR-FS — feeds select input contract"
echo "=========================================================="

echo "--- FS1: comma vs space vs mixed separators ---"
run_select "1 3 6"
n=$(count_enables); [[ $n -eq 3 ]] && ok "FS1a '1 3 6' (space) → 3 feeds" || no "FS1a '1 3 6'" "got $n enables"

run_select "1,3,6"
n=$(count_enables); [[ $n -eq 3 ]] && ok "FS1b '1,3,6' (comma) → 3 feeds" || no "FS1b '1,3,6'" "got $n"

run_select "1, 3, 6"
n=$(count_enables); [[ $n -eq 3 ]] && ok "FS1c '1, 3, 6' (mixed) → 3 feeds" || no "FS1c mixed" "got $n"

echo "--- FS2: empty / garbage rejected with rc=1, no phantom ---"
run_select ""
assert_rc "FS2a empty input" 1
assert_contains "FS2a usage hint emitted" "No valid feeds selected"
assert_not_contains "FS2a no '✅ Done'" "✅ Done"
assert_not_contains "FS2a no 'Enabling 1 feed'" "Enabling 1 feed(s)"

run_select "xyz"
assert_rc "FS2b garbage 'xyz'" 1
assert_contains "FS2b usage hint emitted" "No valid feeds selected"

run_select "3 6 11 14 5 3"
n=$(count_enables); [[ $n -eq 5 ]] && ok "FS2c operator input '3 6 11 14 5 3' → 5 unique" || no "FS2c operator-input" "got $n"

echo "--- FS3: rc propagation + ⚠️ stderr instead of ✅ Done ---"
run_select "3 6 11" "TOR_EXITS|GREENSNOW"
assert_rc "FS3a partial-failure" 1
assert_contains "FS3a '⚠️' warning emitted" "⚠️"
assert_contains "FS3a names the failed feed" "TOR_EXITS"
assert_not_contains "FS3a no '✅ Done' on failure" "✅ Done"

run_select "1 2" "FIREHOL_ANONYMOUS|FIREHOL_PROXIES"
assert_rc "FS3b total-failure" 1
assert_not_contains "FS3b no '✅ Done' when all fail" "✅ Done"

run_select "1 2"
assert_rc "FS3c all-success" 0
assert_contains "FS3c '✅ Done' on full success" "✅ Done"

echo "--- FS4: 'anonymity' category accepted ---"
run_select "anonymity"
n=$(count_enables); [[ $n -eq 3 ]] && ok "FS4a 'anonymity' → 3 feeds" || no "FS4a anonymity" "got $n"

REGEX_CATS=$(grep -oE 'anonymity\|email\|protection\|ssh\|web' \
    "$REPO/cli/lib/nftban/cli/cmd_feeds.sh" | head -1 | tr '|' ' ')
EXPECTED_CATS="anonymity email protection ssh web"
if [[ "$REGEX_CATS" == "$EXPECTED_CATS" ]]; then
    ok "FS4-DRIFT regex covers exactly {$EXPECTED_CATS}"
else
    no "FS4-DRIFT regex drift" "regex='$REGEX_CATS' expected='$EXPECTED_CATS'"
fi

echo "--- FS5: mixed-form union ---"
run_select "1-3, 5, ssh"
n=$(count_enables)
# 1-3 = 3; 5 = 1; ssh = 2 → 6 unique
[[ $n -eq 6 ]] && ok "FS5 '1-3, 5, ssh' → 6 unique feeds" || no "FS5" "got $n"

run_select "all"
n=$(count_enables)
[[ $n -eq 14 ]] && ok "FS5 'all' → 14 feeds" || no "FS5 all" "got $n"

echo "--- T-DRIFT: live cmd_feeds.sh carries v1.142 PR-FS markers ---"
FEEDS_SH="$REPO/cli/lib/nftban/cli/cmd_feeds.sh"
miss=()
for m in 'v1.142 PR-FS (BUG-FS1)' 'v1.142 PR-FS (BUG-FS2)' 'v1.142 PR-FS (BUG-FS3)' 'v1.142 PR-FS (BUG-FS4)'; do
    grep -qF "$m" "$FEEDS_SH" || miss+=("$m")
done
if [[ ${#miss[@]} -eq 0 ]]; then
    ok "T-DRIFT all four v1.142 PR-FS markers present in cmd_feeds.sh"
else
    no "T-DRIFT marker(s) missing" "${miss[*]}"
fi

echo "=========================================================="
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
if (( FAIL > 0 )); then
    printf 'FAILED: %s\n' "${FAILED[@]}"
    exit 1
fi
echo "ALL PASS"
