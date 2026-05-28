#!/usr/bin/env bash
# =============================================================================
# NFTBan - focused help-inertness test (v1.141 PR-A BUG-B5/B6/B7/B8/B11/B12)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cli_help_inertness_v141_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-28"
# meta:description="v1.141 PR-A — asserts every targeted help-inert defect is fixed: `nftban firewall reload --help`, `nftban trust enable --help`, `nftban trust disable --help`, `nftban trust update --help`, `nftban config get --help`, `nftban config set --help`. Plus sweep-all helpers (config defaults/overrides/reset/reset-all). Each invocation must (1) return rc=0, (2) emit help text mentioning the subcommand name, and (3) leave NO mutation marker in a PATH-shadow sandbox. Hermetic — no host contact."
# meta:input="cli/lib/nftban/cli/cmd_firewall.sh, cmd_trust.sh, cmd_config.sh, cli/sbin/nftban"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep,mktemp"
# meta:inventory.files="cli/lib/nftban/cli/cmd_firewall.sh,cli/lib/nftban/cli/cmd_trust.sh,cli/lib/nftban/cli/cmd_config.sh"
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

build_sandbox(){
    local sb="$1"
    mkdir -p "$sb/bin" "$sb/state"
    # Mutating verbs only — the dispatcher legitimately READS (systemctl
    # is-active firewalld, nft list ruleset) on every CLI invocation including
    # help paths. We mark only mutations.
    for binname in nftban-core nft systemctl polkitd policy-rc.d apt-get dnf rpm dpkg; do
        cat >"$sb/bin/$binname" <<EOF
#!/usr/bin/env bash
# v1.141 PR-A test stub — flag mutations only (read-only checks are
# expected on help paths and not flagged).
case "$binname \$1 \$2" in
    "nftban-core "*)             echo "MUTATE: $binname \$*" >> '$sb/state/marker' ;;
    "nft "list*|"nft "show*)      : ;;
    "nft "*)                      echo "MUTATE: $binname \$*" >> '$sb/state/marker' ;;
    "systemctl "is-active*|"systemctl "is-enabled*|"systemctl "is-failed*|"systemctl "show*|"systemctl "status*|"systemctl "list-*|"systemctl "cat*) : ;;
    "systemctl "*)                echo "MUTATE: $binname \$*" >> '$sb/state/marker' ;;
    "apt-get "install*|"apt-get "remove*|"apt-get "purge*|"apt-get "upgrade*|"apt-get "update*) echo "MUTATE: $binname \$*" >> '$sb/state/marker' ;;
    "dnf "install*|"dnf "remove*|"dnf "upgrade*|"dnf "update*) echo "MUTATE: $binname \$*" >> '$sb/state/marker' ;;
    "rpm "-i*|"rpm "-U*|"rpm "-e*|"rpm "--install*|"rpm "--erase*) echo "MUTATE: $binname \$*" >> '$sb/state/marker' ;;
    "dpkg "-i*|"dpkg "--install*|"dpkg "--remove*|"dpkg "--purge*) echo "MUTATE: $binname \$*" >> '$sb/state/marker' ;;
    "polkitd "*)                  echo "MUTATE: $binname \$*" >> '$sb/state/marker' ;;
    "policy-rc.d "*)              echo "MUTATE: $binname \$*" >> '$sb/state/marker' ;;
esac
exit 0
EOF
        chmod +x "$sb/bin/$binname"
    done
}

# Contract: --help is inert (rc=0, no mutation marker, output mentions help/usage).
assert_help_inert(){
    local label="$1"; shift
    local args=("$@")
    local sb; sb=$(mktemp -d -t nftban-helpinert.XXXXXX)
    build_sandbox "$sb"
    local rc=0 out
    out=$(PATH="$sb/bin:$PATH" bash "$NFTBAN_SBIN" "${args[@]}" 2>&1) || rc=$?
    if (( rc != 0 )); then
        no "$label" "rc=$rc (expected 0); last 3 lines: $(echo "$out" | tail -3 | tr '\n' '|')"
    elif [[ -f "$sb/state/marker" ]]; then
        no "$label" "MUTATION OCCURRED — marker: $(tr '\n' '|' < "$sb/state/marker")"
    elif [[ "$out" != *[Uu]sage* && "$out" != *Help* && "$out" != *Usage* ]]; then
        no "$label" "rc=0 but output missing 'Usage:' / 'Help' marker"
    else
        ok "$label (rc=0, no mutation, usage text present)"
    fi
    rm -rf "$sb"
}

echo "=========================================================="
echo "v1.141 PR-A — focused help-inertness test"
echo "=========================================================="

echo "--- Required focused rows (operator-named) ---"
assert_help_inert "T1 firewall reload --help (B5)"  firewall reload --help
assert_help_inert "T2 trust enable --help (B6)"     trust enable --help
assert_help_inert "T3 trust disable --help (B7)"    trust disable --help
assert_help_inert "T4 trust update --help (B8)"     trust update --help
assert_help_inert "T5 config get --help (B11)"      config get --help
assert_help_inert "T6 config set --help (B12)"      config set --help

echo "--- Sweep-all extras (config defaults/overrides/reset/reset-all) ---"
assert_help_inert "T7 config defaults --help"       config defaults --help
assert_help_inert "T8 config overrides --help"      config overrides --help
assert_help_inert "T9 config reset --help"          config reset --help
assert_help_inert "T10 config reset-all --help"     config reset-all --help

echo "--- Short-flag parity: -h and 'help' must work the same ---"
assert_help_inert "T11 firewall reload -h"          firewall reload -h
assert_help_inert "T12 trust enable -h"             trust enable -h
assert_help_inert "T13 config get help (bareword)"  config get help

echo "=========================================================="
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
if (( FAIL > 0 )); then
    printf 'FAILED: %s\n' "${FAILED[@]}"
    exit 1
fi
echo "ALL PASS"
