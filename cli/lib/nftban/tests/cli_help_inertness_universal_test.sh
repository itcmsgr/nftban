#!/usr/bin/env bash
# =============================================================================
# NFTBan - universal help-inertness sweep test (v1.141 PR-A sweep-all)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cli_help_inertness_universal_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-28"
# meta:description="v1.141 PR-A — sweep-all-subcommands help-inertness audit. Every top-level subcommand the dispatcher recognises must satisfy the help contract: `nftban <cmd> --help` returns rc=0, is inert (no nftban-core, nft, systemctl, package-manager mutation in PATH-shadow sandbox), and emits usage/help/Available text. Non-existent subcommands are SKIPPED (operator-chosen 'drop' for feeds add / feeds remove / update apply / update channel — doc-vs-code drift, not aliased). This test is a regression-prevention gate: any future PR that breaks help inertness on any swept subcommand fails CI."
# meta:input="cli/sbin/nftban + every cli/lib/nftban/cli/cmd_*.sh"
# meta:output="Pass/fail assertions per subcommand; exit 0 on all-pass"
# meta:depends="bash,grep,mktemp"
# meta:inventory.files="cli/sbin/nftban"
# meta:inventory.binaries="bash,grep,mktemp"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,PATH"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="cli_help_inertness_universal_test"
# meta:ta.owner="cli"
# meta:ta.module="help-inertness"
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
NFTBAN_SBIN="$REPO/cli/sbin/nftban"
export NFTBAN_LIB_DIR="$REPO/cli/lib/nftban"
export NFTBAN_NONINTERACTIVE=1
export NFTBAN_NO_BANNER=1

[[ -x "$NFTBAN_SBIN" ]] || { echo "FAIL: missing $NFTBAN_SBIN" >&2; exit 1; }

PASS=0; FAIL=0; SKIP=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }
sk(){ printf '  [SKIP] %s (%s)\n' "$1" "$2"; SKIP=$((SKIP+1)); }

build_sandbox(){
    local sb="$1"
    mkdir -p "$sb/bin" "$sb/state"
    # Mutating verbs only — the dispatcher legitimately READS (systemctl
    # is-active firewalld, nft list ruleset) on every CLI invocation including
    # help paths. We mark only mutations.
    for binname in nftban-core nftban-validate nftban-installer nft systemctl polkitd policy-rc.d apt-get dnf rpm dpkg yum; do
        cat >"$sb/bin/$binname" <<EOF
#!/usr/bin/env bash
case "$binname \$1 \$2" in
    "nftban-core "*|"nftban-validate "*|"nftban-installer "*) echo "MUTATE: $binname \$*" >> '$sb/state/marker' ;;
    "nft "list*|"nft "show*)      : ;;
    "nft "*)                      echo "MUTATE: $binname \$*" >> '$sb/state/marker' ;;
    "systemctl "is-active*|"systemctl "is-enabled*|"systemctl "is-failed*|"systemctl "show*|"systemctl "status*|"systemctl "list-*|"systemctl "cat*) : ;;
    "systemctl "*)                echo "MUTATE: $binname \$*" >> '$sb/state/marker' ;;
    "apt-get "install*|"apt-get "remove*|"apt-get "purge*|"apt-get "upgrade*|"apt-get "update*) echo "MUTATE: $binname \$*" >> '$sb/state/marker' ;;
    "dnf "install*|"dnf "remove*|"dnf "upgrade*|"dnf "update*|"yum "install*|"yum "remove*) echo "MUTATE: $binname \$*" >> '$sb/state/marker' ;;
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

# Top-level subcommands the dispatcher in cli/sbin/nftban recognises.
TOP_LEVEL=(
    ban unban search list status health version
    whitelist blacklist feeds watchdog stats
    install uninstall update rebuild rollback
    login metrics export portscan ddos suricata
    config service services timers geoip geoban
    emulate fhs botguard tunnel firewall trust help
)

# Sub-action surfaces PR-A fixed — each must satisfy the contract under sweep.
SUB_ACTIONS=(
    "firewall reload"
    "trust enable"
    "trust disable"
    "trust update"
    "config get"
    "config set"
    "config defaults"
    "config overrides"
    "config reset"
    "config reset-all"
)

assert_help_inert(){
    local label="$1"; shift
    local args=("$@")
    local sb; sb=$(mktemp -d -t nftban-univ.XXXXXX)
    build_sandbox "$sb"
    local rc=0 out
    out=$(PATH="$sb/bin:$PATH" bash "$NFTBAN_SBIN" "${args[@]}" --help 2>&1) || rc=$?
    if (( rc != 0 )); then
        no "$label" "rc=$rc"
    elif [[ -f "$sb/state/marker" ]]; then
        no "$label" "MUTATION on help path: $(tr '\n' '|' < "$sb/state/marker")"
    elif [[ "$out" != *[Uu]sage* && "$out" != *Help* && "$out" != *help* && "$out" != *Available* ]]; then
        no "$label" "rc=0 but output missing usage/help/Available marker"
    else
        ok "$label (rc=0, no mutation, usage text present)"
    fi
    rm -rf "$sb"
}

SKIP_BECAUSE_DROP_PER_OPERATOR=(
    "feeds add"
    "feeds remove"
    "update apply"
    "update channel"
)

echo "=========================================================="
echo "v1.141 PR-A — universal help-inertness sweep"
echo "=========================================================="

echo "--- top-level subcommands ---"
for cmd in "${TOP_LEVEL[@]}"; do
    assert_help_inert "TL: nftban $cmd --help" "$cmd"
done

echo "--- sub-action surfaces (PR-A-fixed paths must satisfy contract) ---"
for sa in "${SUB_ACTIONS[@]}"; do
    # IFS at the top of this file is \n\t (no space), so a vanilla unquoted
    # $sa would not word-split. Use read -ra with explicit IFS=' ' to split.
    IFS=' ' read -ra _sa_parts <<< "$sa"
    assert_help_inert "SA: nftban $sa --help" "${_sa_parts[@]}"
done

echo "--- dropped per operator (doc-vs-code drift; SKIP not FAIL) ---"
for sa in "${SKIP_BECAUSE_DROP_PER_OPERATOR[@]}"; do
    sk "DROP: nftban $sa --help" "operator SELECT_V1_141_0_B9_B10_B13_B14_DROP_OR_ALIAS = drop — non-existent subcommand"
done

echo "=========================================================="
echo "RESULTS: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
if (( FAIL > 0 )); then
    printf 'FAILED: %s\n' "${FAILED[@]}"
    exit 1
fi
echo "ALL PASS (regression-prevention gate)"
