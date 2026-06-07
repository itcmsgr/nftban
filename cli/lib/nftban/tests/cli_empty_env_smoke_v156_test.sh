#!/usr/bin/env bash
# =============================================================================
# NFTBan - empty-env smoke test (v1.156 PR-B)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cli_empty_env_smoke_v156_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-07"
# meta:description="v1.156 PR-B — empty-env smoke. Runs the read-only CLI entrypoints (version, help) under a SCRUBBED environment (env -i with only PATH + NFTBAN_LIB_DIR) and asserts the dispatcher does NOT crash on an unbound variable under set -u. The CLI runs with set -Eeuo pipefail, so any code path that dereferences an environment variable without a default would abort with 'unbound variable' on a host with a minimal/empty env (cron, systemd ExecStart with a scrubbed environment, etc.). This is a regression-prevention gate: read-only commands only, no host mutation."
# meta:input="cli/sbin/nftban"
# meta:output="Pass/fail assertions per command; exit 0 on all-pass"
# meta:depends="bash,grep,env"
# meta:inventory.files="cli/sbin/nftban"
# meta:inventory.binaries="bash,grep,env"
# meta:inventory.env_vars="PATH,NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)
NFTBAN_SBIN="$REPO/cli/sbin/nftban"
LIB_DIR="$REPO/cli/lib/nftban"

[[ -x "$NFTBAN_SBIN" ]] || { echo "FAIL: missing $NFTBAN_SBIN" >&2; exit 1; }
[[ -d "$LIB_DIR" ]]     || { echo "FAIL: missing $LIB_DIR" >&2; exit 1; }

# A minimal but real PATH so bash + the coreutils the dispatcher reaches for
# resolve. This is deliberately the ONLY env we pass through env -i besides
# NFTBAN_LIB_DIR — the whole point is to prove the CLI does not depend on any
# other ambient variable being set under `set -u`.
MIN_PATH="/usr/sbin:/usr/bin:/sbin:/bin"

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

# Run a read-only CLI invocation under a scrubbed environment and assert:
#   (a) the run does NOT abort with an 'unbound variable' diagnostic, and
#   (b) the exit code is one of the expected codes (rc=0 for help/version on a
#       repo checkout; some commands legitimately rc=1 without a daemon, but the
#       smoke target commands here are inert and must succeed).
# Expected-rc is supplied per command.
assert_empty_env_ok(){
    local label="$1"; local want_rc="$2"; shift 2
    local args=("$@")
    local rc=0 out
    out=$(env -i PATH="$MIN_PATH" NFTBAN_LIB_DIR="$LIB_DIR" \
            bash "$NFTBAN_SBIN" "${args[@]}" 2>&1) || rc=$?

    if grep -qi 'unbound variable' <<<"$out"; then
        no "$label" "set -u unbound-variable crash under empty env: $(grep -i 'unbound variable' <<<"$out" | head -1)"
        return
    fi
    if grep -qiE 'line [0-9]+:.*(bad substitution|parameter null or not set)' <<<"$out"; then
        no "$label" "shell parameter expansion error under empty env"
        return
    fi
    if [[ "$rc" != "$want_rc" ]]; then
        no "$label" "rc=$rc (expected $want_rc); output head: $(head -1 <<<"$out")"
        return
    fi
    ok "$label (rc=$rc, no unbound-variable crash)"
}

echo "=========================================================="
echo "v1.156 PR-B — empty-env smoke (scrubbed env -i, read-only)"
echo "=========================================================="

# version is fully self-contained (sources lib/version.sh) and must run clean.
assert_empty_env_ok "version (empty env)"        0 version
assert_empty_env_ok "version --json (empty env)" 0 version --json
# help is inert and self-contained.
assert_empty_env_ok "help (empty env)"           0 help
# --help on a representative subcommand must also survive a scrubbed env.
assert_empty_env_ok "status --help (empty env)"  0 status --help

echo "=========================================================="
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
if (( FAIL > 0 )); then
    printf 'FAILED: %s\n' "${FAILED[@]}"
    exit 1
fi
echo "ALL PASS — no unbound-variable crash under empty/scrubbed env"
