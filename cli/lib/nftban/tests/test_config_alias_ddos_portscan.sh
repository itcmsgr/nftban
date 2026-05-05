#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="test_config_alias_ddos_portscan"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-05"
# meta:description="PR-C3-C: verify nftban_config_alias_env handles canonical/alias for DDoS + Portscan; static-grep guard against compatibility-key writes in production."
# meta:input="None"
# meta:output="Test pass/fail to stdout"
# meta:depends="cli/lib/nftban/lib/nftban_config_alias.sh"
# meta:inventory.files=""
# meta:inventory.binaries="grep,bash,find"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"

set -Eeuo pipefail

# DDOS_ENABLED / NFTBAN_DDOS_ENABLED / PORTSCAN_ENABLED / NFTBAN_PORTSCAN_ENABLED
# are read indirectly by the helper via ${!canonical_name-} / ${!alias_name-}.
# Tell shellcheck not to flag them as unused.
# shellcheck disable=SC2034

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"

# shellcheck source=/dev/null
source "$REPO_ROOT/lib/nftban/lib/nftban_config_alias.sh"

PASS=0
FAIL=0

_assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf "  PASS %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  FAIL %s — expected=%q actual=%q\n" "$name" "$expected" "$actual"
        FAIL=$((FAIL + 1))
    fi
}

_assert_warn_emitted() {
    local name="$1" stderr_capture="$2"
    if grep -q '^WARN nftban_config_alias' <<< "$stderr_capture"; then
        printf "  PASS %s (warn emitted)\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  FAIL %s — expected WARN line in stderr; got=%q\n" "$name" "$stderr_capture"
        FAIL=$((FAIL + 1))
    fi
}

_assert_no_warn() {
    local name="$1" stderr_capture="$2"
    if grep -q '^WARN nftban_config_alias' <<< "$stderr_capture"; then
        printf "  FAIL %s — unexpected WARN line: %q\n" "$name" "$stderr_capture"
        FAIL=$((FAIL + 1))
    else
        printf "  PASS %s (no warn)\n" "$name"
        PASS=$((PASS + 1))
    fi
}

# Reset env for each scenario; sub-shells keep the helper isolated from the
# parent shell's variable state.
_reset_env() {
    unset DDOS_ENABLED NFTBAN_DDOS_ENABLED PORTSCAN_ENABLED NFTBAN_PORTSCAN_ENABLED
}

# -----------------------------------------------------------------------------
# DDoS scenarios
# -----------------------------------------------------------------------------
echo "[1/12] DDoS — canonical only set"
_reset_env
DDOS_ENABLED="true"
out_stderr=$(nftban_config_alias_env DDOS_ENABLED NFTBAN_DDOS_ENABLED "false" 2>&1 >/dev/null)
out_stdout=$(nftban_config_alias_env DDOS_ENABLED NFTBAN_DDOS_ENABLED "false")
_assert_eq "ddos canonical-only returns canonical value" "true" "$out_stdout"
_assert_no_warn "ddos canonical-only no warn" "$out_stderr"

echo "[2/12] DDoS — alias only set"
_reset_env
NFTBAN_DDOS_ENABLED="true"
out_stderr=$(nftban_config_alias_env DDOS_ENABLED NFTBAN_DDOS_ENABLED "false" 2>&1 >/dev/null)
out_stdout=$(nftban_config_alias_env DDOS_ENABLED NFTBAN_DDOS_ENABLED "false")
_assert_eq "ddos alias-only returns alias value" "true" "$out_stdout"
_assert_no_warn "ddos alias-only no warn" "$out_stderr"

echo "[3/12] DDoS — both set, same value"
_reset_env
DDOS_ENABLED="true"
NFTBAN_DDOS_ENABLED="true"
out_stderr=$(nftban_config_alias_env DDOS_ENABLED NFTBAN_DDOS_ENABLED "false" 2>&1 >/dev/null)
out_stdout=$(nftban_config_alias_env DDOS_ENABLED NFTBAN_DDOS_ENABLED "false")
_assert_eq "ddos both-same returns canonical" "true" "$out_stdout"
_assert_no_warn "ddos both-same no warn" "$out_stderr"

echo "[4/12] DDoS — both set, conflict canonical=true"
_reset_env
# shellcheck disable=SC2034  # read indirectly by nftban_config_alias_env via ${!name}
DDOS_ENABLED="true"
# shellcheck disable=SC2034
NFTBAN_DDOS_ENABLED="false"
out_stderr=$(nftban_config_alias_env DDOS_ENABLED NFTBAN_DDOS_ENABLED "false" 2>&1 >/dev/null)
out_stdout=$(nftban_config_alias_env DDOS_ENABLED NFTBAN_DDOS_ENABLED "false")
_assert_eq "ddos conflict canonical-true returns canonical (true)" "true" "$out_stdout"
_assert_warn_emitted "ddos conflict canonical-true emits warn" "$out_stderr"

echo "[5/12] DDoS — both set, conflict canonical=false"
_reset_env
# shellcheck disable=SC2034  # read indirectly by nftban_config_alias_env via ${!name}
DDOS_ENABLED="false"
# shellcheck disable=SC2034
NFTBAN_DDOS_ENABLED="true"
out_stderr=$(nftban_config_alias_env DDOS_ENABLED NFTBAN_DDOS_ENABLED "true" 2>&1 >/dev/null)
out_stdout=$(nftban_config_alias_env DDOS_ENABLED NFTBAN_DDOS_ENABLED "true")
_assert_eq "ddos conflict canonical-false returns canonical (false)" "false" "$out_stdout"
_assert_warn_emitted "ddos conflict canonical-false emits warn" "$out_stderr"

echo "[6/12] DDoS — neither set, fallback honoured"
_reset_env
out_stderr=$(nftban_config_alias_env DDOS_ENABLED NFTBAN_DDOS_ENABLED "fallback-default" 2>&1 >/dev/null)
out_stdout=$(nftban_config_alias_env DDOS_ENABLED NFTBAN_DDOS_ENABLED "fallback-default")
_assert_eq "ddos neither-set returns fallback" "fallback-default" "$out_stdout"
_assert_no_warn "ddos neither-set no warn" "$out_stderr"

# -----------------------------------------------------------------------------
# Portscan scenarios
# -----------------------------------------------------------------------------
echo "[7/12] Portscan — canonical only set"
_reset_env
PORTSCAN_ENABLED="true"
out_stderr=$(nftban_config_alias_env PORTSCAN_ENABLED NFTBAN_PORTSCAN_ENABLED "false" 2>&1 >/dev/null)
out_stdout=$(nftban_config_alias_env PORTSCAN_ENABLED NFTBAN_PORTSCAN_ENABLED "false")
_assert_eq "portscan canonical-only returns canonical value" "true" "$out_stdout"
_assert_no_warn "portscan canonical-only no warn" "$out_stderr"

echo "[8/12] Portscan — alias only set"
_reset_env
NFTBAN_PORTSCAN_ENABLED="true"
out_stderr=$(nftban_config_alias_env PORTSCAN_ENABLED NFTBAN_PORTSCAN_ENABLED "false" 2>&1 >/dev/null)
out_stdout=$(nftban_config_alias_env PORTSCAN_ENABLED NFTBAN_PORTSCAN_ENABLED "false")
_assert_eq "portscan alias-only returns alias value" "true" "$out_stdout"
_assert_no_warn "portscan alias-only no warn" "$out_stderr"

echo "[9/12] Portscan — both set, same value"
_reset_env
PORTSCAN_ENABLED="false"
NFTBAN_PORTSCAN_ENABLED="false"
out_stderr=$(nftban_config_alias_env PORTSCAN_ENABLED NFTBAN_PORTSCAN_ENABLED "true" 2>&1 >/dev/null)
out_stdout=$(nftban_config_alias_env PORTSCAN_ENABLED NFTBAN_PORTSCAN_ENABLED "true")
_assert_eq "portscan both-same returns canonical" "false" "$out_stdout"
_assert_no_warn "portscan both-same no warn" "$out_stderr"

echo "[10/12] Portscan — both set, conflict canonical=true"
_reset_env
# shellcheck disable=SC2034  # read indirectly by nftban_config_alias_env via ${!name}
PORTSCAN_ENABLED="true"
# shellcheck disable=SC2034
NFTBAN_PORTSCAN_ENABLED="false"
out_stderr=$(nftban_config_alias_env PORTSCAN_ENABLED NFTBAN_PORTSCAN_ENABLED "false" 2>&1 >/dev/null)
out_stdout=$(nftban_config_alias_env PORTSCAN_ENABLED NFTBAN_PORTSCAN_ENABLED "false")
_assert_eq "portscan conflict canonical-true returns canonical (true)" "true" "$out_stdout"
_assert_warn_emitted "portscan conflict canonical-true emits warn" "$out_stderr"

echo "[11/12] Portscan — both set, conflict canonical=false"
_reset_env
# shellcheck disable=SC2034  # read indirectly by nftban_config_alias_env via ${!name}
PORTSCAN_ENABLED="false"
# shellcheck disable=SC2034
NFTBAN_PORTSCAN_ENABLED="true"
out_stderr=$(nftban_config_alias_env PORTSCAN_ENABLED NFTBAN_PORTSCAN_ENABLED "true" 2>&1 >/dev/null)
out_stdout=$(nftban_config_alias_env PORTSCAN_ENABLED NFTBAN_PORTSCAN_ENABLED "true")
_assert_eq "portscan conflict canonical-false returns canonical (false)" "false" "$out_stdout"
_assert_warn_emitted "portscan conflict canonical-false emits warn" "$out_stderr"

# -----------------------------------------------------------------------------
# Static-grep guard: no production code path may write the compatibility key.
# Allowed sites: schema declarations (data/config-schema.json), base config
# alias declaration (install/config/nftban.conf), CHANGELOG/history,
# packaging/deb/changelog, .md docs, this very file, and tests.
# -----------------------------------------------------------------------------
echo "[12/12] Negative guard — no production writes of NFTBAN_{DDOS,PORTSCAN}_ENABLED="
_reset_env
HITS=$(grep -rnE '(sed -i|echo).*NFTBAN_(DDOS|PORTSCAN)_ENABLED=' \
        "$REPO_ROOT" 2>/dev/null \
    | grep -v -E '/(tests|test_|CHANGELOG|\.git/|packaging/deb/changelog|data/config-schema\.json|install/config/(nftban\.conf|schema/config-schema\.json)|\.md:)' \
    || true)
if [[ -z "$HITS" ]]; then
    printf "  PASS no production writes of compatibility key\n"
    PASS=$((PASS + 1))
else
    printf "  FAIL compatibility-key writes found in production code:\n%s\n" "$HITS"
    FAIL=$((FAIL + 1))
fi

# -----------------------------------------------------------------------------
echo ""
printf "Total: %d PASS, %d FAIL\n" "$PASS" "$FAIL"
if (( FAIL > 0 )); then
    exit 1
fi
exit 0
