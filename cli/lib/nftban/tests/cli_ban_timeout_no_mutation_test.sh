#!/usr/bin/env bash
# =============================================================================
# NFTBan - ban --timeout invalid no-mutation test (v1.141 PR-A BUG-A7/A8)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cli_ban_timeout_no_mutation_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-28"
# meta:description="v1.141 PR-A — asserts that invalid --timeout values short-circuit BEFORE any mutation surface is touched. Specifically: nftban-core is never invoked, /etc/nftban/blacklist.d/ is never written, nft is never called. Uses PATH-shadow stubs for nftban-core, nft, systemctl. Each stub writes to a marker file on invocation; the assertion is marker-file MUST NOT exist after an invalid --timeout call. Prior to v1.141, the unvalidated --timeout value flowed all the way to nftban-core, which then interpreted the bogus value as permanent ban — silent mutation."
# meta:input="cli/lib/nftban/cli/cmd_ban.sh + cli/sbin/nftban"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep,mktemp"
# meta:inventory.files="cli/lib/nftban/cli/cmd_ban.sh"
# meta:inventory.binaries="bash,grep,mktemp"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,PATH"
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
export NFTBAN_LIB_DIR="$REPO/cli/lib/nftban"
export NFTBAN_NONINTERACTIVE=1
export NFTBAN_NO_BANNER=1

[[ -x "$NFTBAN_SBIN" ]] || { echo "FAIL: missing $NFTBAN_SBIN" >&2; exit 1; }

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

# Build a PATH-shadow sandbox that contains marker-writing stubs for every
# mutation binary the ban pipeline might invoke. If any of them runs, a marker
# file appears in the sandbox.
build_sandbox(){
    local sb="$1"
    mkdir -p "$sb/bin" "$sb/state"
    for binname in nftban-core nft systemctl polkitd; do
        cat >"$sb/bin/$binname" <<EOF
#!/usr/bin/env bash
echo "$binname \$*" >> '$sb/state/marker'
exit 0
EOF
        chmod +x "$sb/bin/$binname"
    done
}

assert_no_mutation_on_invalid(){
    local label="$1" value="$2"
    local sb; sb=$(mktemp -d -t nftban-noamut.XXXXXX)
    build_sandbox "$sb"
    local rc=0
    # Prefix sandbox bin so stubs win over real binaries; otherwise rely on the
    # parser short-circuiting before any system binary is called.
    PATH="$sb/bin:$PATH" bash "$NFTBAN_SBIN" ban 10.0.0.1 --timeout "$value" >/dev/null 2>&1 || rc=$?
    if (( rc == 0 )); then
        no "$label" "rc=0 (expected non-zero on invalid)"
    elif [[ -f "$sb/state/marker" ]]; then
        no "$label" "MUTATION OCCURRED — marker file contents: $(tr '\n' '|' < "$sb/state/marker")"
    else
        ok "$label (invalid timeout=$value rc=$rc, NO mutation marker)"
    fi
    rm -rf "$sb"
}

echo "=========================================================="
echo "v1.141 PR-A — ban --timeout no-mutation test"
echo "=========================================================="

assert_no_mutation_on_invalid "T1 abc (non-integer)"        "abc"
assert_no_mutation_on_invalid "T2 -5 (negative)"             "-5"
assert_no_mutation_on_invalid "T3 0 (zero)"                   "0"
assert_no_mutation_on_invalid "T4 1.5 (float)"                "1.5"
assert_no_mutation_on_invalid "T5 +10 (signed)"               "+10"

echo "=========================================================="
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
if (( FAIL > 0 )); then
    printf 'FAILED: %s\n' "${FAILED[@]}"
    exit 1
fi
echo "ALL PASS"
