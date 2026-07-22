#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.220.3: RBL CLI correctness cluster (provider loader, watchlist,
#                     help banner, help provider-count truth)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="rbl_cli_correctness_v220_3_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-11"
# meta:description="Locks the v1.220.3 RBL CLI correctness fixes. (B1) nftban_rbl_load_providers trims whitespace, skips blank/comment rows, rejects malformed DNS names, de-duplicates, and NEVER emits an empty provider (previously a blank line surfaced first after sort -u and was numbered '1.' in rbl list). (B3) nftban_rbl_watchlist_get on an empty/comment-only watchlist returns rc 0 with no output instead of tripping the ERR trap on the trailing grep '|'. (B4a) rbl help renders the running version, not the frozen literal 'v1.0.0'. (B4c) rbl help no longer asserts a stale '41 RBLs' provider count. Shell-only; RBL observe-only; daemon byte-identical."
# meta:input="Stubbed providers/watchlist temp files + repo cmd_rbl.sh/nftban_rbl.sh"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep,sort"
# meta:inventory.files="cli/lib/nftban/cli/cmd_rbl.sh,cli/lib/nftban/core/nftban_rbl.sh,install/bash-completion/nftban"
# meta:inventory.binaries="bash,grep,sort"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_RBL_PROVIDERS_FILE,NFTBAN_RBL_WATCHLIST_FILE"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="rbl_cli_correctness_v220_3_test"
# meta:ta.owner="rbl"
# meta:ta.module="rbl-cli-correctness"
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
set +eE

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ -f "$SCRIPT_DIR/../core/nftban_hostaddr.sh" ]]; then
    NFTBAN_LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
else
    NFTBAN_LIB_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)/cli/lib/nftban"
fi
export NFTBAN_LIB_DIR
REPO_ROOT="$(cd "$NFTBAN_LIB_DIR/../../.." && pwd)"
RBL_CORE="$NFTBAN_LIB_DIR/core/nftban_rbl.sh"
CMD_RBL="$NFTBAN_LIB_DIR/cli/cmd_rbl.sh"
COMPLETION="$REPO_ROOT/install/bash-completion/nftban"

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); FAILED+=("$1"); }
has(){ [[ "$1" == *"$2"* ]]; }

echo "=== v1.220.3 RBL CLI correctness (B1 loader / B3 watchlist / B4 help+completion) ==="

# --------------------------------------------------------------------------
# B1 — provider loader: never emit an empty provider; trim/skip/validate/dedup
# --------------------------------------------------------------------------
(
  # shellcheck source=/dev/null
  source "$RBL_CORE" 2>/dev/null || true
  set +eE
  PF="$(mktemp)"; export NFTBAN_RBL_PROVIDERS_FILE="$PF"
  # Deliberately messy input: comment, blank, whitespace-only, leading/trailing
  # spaces, a duplicate, and a malformed (dot-less) domain.
  {
    printf '# comment line\n'
    printf '\n'
    printf '   \t  \n'
    printf 'zen.spamhaus.org:https://spamhaus.org/zen/\n'
    printf '   b.barracudacentral.org:http://barracudacentral.org/rbl   \n'
    printf 'zen.spamhaus.org:https://spamhaus.org/zen/\n'
    printf 'not-a-domain:bogus\n'
  } > "$PF"
  # No custom file, so enabled_rbls stays empty (the old blank-provider trigger).
  unset NFTBAN_RBL_CUSTOM_FILE 2>/dev/null || true
  export NFTBAN_RBL_CUSTOM_FILE=/nonexistent-rbl-custom-$$
  out="$(nftban_rbl_load_providers 2>/tmp/b1err.$$)"
  # Count lines, empty lines, and specific domains
  nlines=$(printf '%s\n' "$out" | grep -c . || true)
  nempty=$(printf '%s\n' "$out" | grep -c '^$' || true)
  nzen=$(printf '%s\n' "$out" | grep -c '^zen\.spamhaus\.org:' || true)
  nbar=$(printf '%s\n' "$out" | grep -c '^b\.barracudacentral\.org:' || true)
  nbad=$(printf '%s\n' "$out" | grep -c 'not-a-domain' || true)
  reported=$(grep -c 'ignoring invalid provider' /tmp/b1err.$$ || true)
  echo "NLINES=$nlines NEMPTY=$nempty NZEN=$nzen NBAR=$nbar NBAD=$nbad REPORTED=$reported"
  rm -f "$PF" /tmp/b1err.$$
) > /tmp/b1.$$ 2>&1
b1="$(cat /tmp/b1.$$)"; rm -f /tmp/b1.$$
has "$b1" "NEMPTY=0"  && ok "B1 loader emits NO empty provider (was the blank '1.' bug)" || no "B1 empty provider present ($b1)"
has "$b1" "NLINES=2"  && ok "B1 loader keeps exactly the 2 valid unique providers" || no "B1 wrong effective count ($b1)"
has "$b1" "NZEN=1"    && ok "B1 loader de-duplicates a repeated provider" || no "B1 dedup failed ($b1)"
has "$b1" "NBAR=1"    && ok "B1 loader trims surrounding whitespace and keeps the trimmed domain" || no "B1 trim failed ($b1)"
has "$b1" "NBAD=0"    && ok "B1 loader rejects a malformed (dot-less) domain" || no "B1 malformed leaked ($b1)"
has "$b1" "REPORTED=1" && ok "B1 loader reports the invalid entry with file:line to stderr" || no "B1 no invalid report ($b1)"

# --------------------------------------------------------------------------
# B3 — watchlist_get on empty/comment-only watchlist: rc 0, no crash, no output
# --------------------------------------------------------------------------
(
  # shellcheck source=/dev/null
  source "$RBL_CORE" 2>/dev/null || true
  set -Eeuo pipefail            # reinstate strict + ERR trap to prove no trip
  WL="$(mktemp)"; export NFTBAN_RBL_WATCHLIST_FILE="$WL"
  printf '# only a comment, no data rows\n\n' > "$WL"
  rc=0; out="$(nftban_rbl_watchlist_get)" || rc=$?
  echo "RC=$rc LEN=${#out}"
  rm -f "$WL"
) > /tmp/b3.$$ 2>&1
b3="$(cat /tmp/b3.$$)"; rm -f /tmp/b3.$$
{ has "$b3" "RC=0" && has "$b3" "LEN=0"; } && ok "B3 empty watchlist_get → rc0, no output, no ERR-trap crash" || no "B3 watchlist crash/output ($b3)"

# --------------------------------------------------------------------------
# B4a — help banner shows the running version, not the frozen 'v1.0.0'
# --------------------------------------------------------------------------
(
  # shellcheck source=/dev/null
  source "$CMD_RBL" 2>/dev/null || true
  set +eE
  nftban_cmd_rbl_help 2>/dev/null
) > /tmp/b4.$$ 2>&1
b4="$(cat /tmp/b4.$$)"; rm -f /tmp/b4.$$
ver="$(cat "$REPO_ROOT/VERSION" 2>/dev/null | tr -d '[:space:]')"
{ ! has "$b4" "v1.0.0"; }            && ok "B4a help banner no longer prints the stale literal 'v1.0.0'" || no "B4a stale v1.0.0 still in help"
{ [[ -n "$ver" ]] && has "$b4" "NFTBan v${ver}"; } && ok "B4a help banner renders the running version (v${ver})" || no "B4a running version not shown in help"

# --------------------------------------------------------------------------
# B4c — help no longer asserts a stale '41 RBLs' provider count
# --------------------------------------------------------------------------
{ ! has "$b4" "41 RBLs"; } && ok "B4c help no longer asserts the stale '41 RBLs' count" || no "B4c stale '41 RBLs' still in help"

# --------------------------------------------------------------------------
# B4b — bash completion for `nftban rbl` includes config/stats/test
# --------------------------------------------------------------------------
if [[ -f "$COMPLETION" ]]; then
  rbl_line="$(grep -m1 'rbl_cmds=' "$COMPLETION" || true)"
  { has "$rbl_line" " config" && has "$rbl_line" " stats" && has "$rbl_line" " test"; } \
    && ok "B4b completion rbl_cmds includes config/stats/test (dispatcher parity)" \
    || no "B4b completion missing config/stats/test ($rbl_line)"
else
  no "B4b completion file not found at $COMPLETION"
fi

# --------------------------------------------------------------------------
echo "-------------------------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
if [[ $FAIL -gt 0 ]]; then
  printf 'FAILED: %s\n' "${FAILED[@]}"
  exit 1
fi
echo "ALL PASS"
exit 0
