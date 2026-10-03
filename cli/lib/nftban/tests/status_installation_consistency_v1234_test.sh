#!/usr/bin/env bash
# =============================================================================
# NFTBan - status shows installation inconsistency separately (v1.234)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="status_installation_consistency_v1234_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-01"
# meta:description="v1.234 PR #1439 owner status decision, BUG-STATUS-IGNORES-PACKAGE-MANAGER-TRANSACTION-STATE (related BUG-INSTALL-STATE-SAYS-COMMITTED-AFTER-PACKAGE-REMOVE). Measured on deb-clean/el9-clean: dpkg iHR (read-only mount), dpkg iF (postinst died), an RPM upgrade that left rpmdb at 1.233.1 with 1.233.90 files on disk, and a removed package all left `nftban status` at PROTECTED + COMMITTED. Sources the REAL cli/lib/nftban/cli/cmd_status.sh with stub dpkg-query/rpm and a sandbox VERSION/install_state and asserts: an incomplete installation is reported as such with a recovery hint; the firewall runtime state is shown separately and NOT lowered (never claims protection stopped); the overall verdict and `status --brief` become DEGRADED:D-PACKAGE with exit 1; a consistent install stays PROTECTED. FAILS on v1.233.1, PASSES on the fix."
# meta:input="cli/lib/nftban/cli/cmd_status.sh"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,awk,grep"
# meta:inventory.files="cli/lib/nftban/cli/cmd_status.sh"
# meta:inventory.binaries="bash,awk,grep"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_STATE_DIR,NFTBAN_VERSION_FILE"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="status_installation_consistency_v1234_test"
# meta:ta.owner="cli"
# meta:ta.module="status"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="policy-gates"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)
STATUS="$REPO/cli/lib/nftban/cli/cmd_status.sh"
[[ -f "$STATUS" ]] || { echo "NOT_EXECUTED: missing $STATUS" >&2; exit 1; }

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/state" "$W/lib"
# stub package tools: behaviour selected by $PKGMODE
cat > "$W/bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
case "$PKGMODE" in deb-*) ;; *) exit 1;; esac
case "$*" in
  "-W nftban-core") [[ "$PKGMODE" == deb-removed ]] && exit 1; exit 0 ;;
  *db:Status-Abbrev*)
    case "$PKGMODE" in
      deb-ok)  printf 'ii |1.234.0' ;;
      deb-iHR) printf 'iHR|1.233.1' ;;
      deb-iF)  printf 'iF |1.234.0' ;;
    esac ;;
  *) exit 1 ;;
esac
EOF
cat > "$W/bin/rpm" <<'EOF'
#!/usr/bin/env bash
case "$PKGMODE" in rpm-*) ;; *) exit 1;; esac
case "$*" in
  "-q nftban-core") [[ "$PKGMODE" == rpm-removed ]] && exit 1; exit 0 ;;
  *VERSION*) case "$PKGMODE" in rpm-ok) echo 1.234.0 ;; rpm-partial) echo 1.233.1 ;; esac ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$W/bin"/*

probe() {  # MODE FILES_VERSION INSTALL_STATE INSTALL_VERSION -> runs the real probe/overall/brief
    local mode=$1 fver=$2 st=$3 sver=$4
    rm -f "$W/lib/VERSION" "$W/state/install_state"
    [[ -n "$fver" ]] && printf '%s' "$fver" > "$W/lib/VERSION"
    [[ -n "$st" ]] && printf 'INSTALL_STATE=%s\nINSTALL_VERSION=%s\n' "$st" "$sver" > "$W/state/install_state"
    env -i PATH="$W/bin:/usr/bin:/bin" PKGMODE="$mode" NFTBAN_LIB_DIR="$REPO/cli/lib/nftban" \
        NFTBAN_VERSION_FILE="$W/lib/VERSION" NFTBAN_STATE_DIR="$W/state" NFTBAN_CONFIG_DIR="$W/none" \
        NFTBAN_NO_BANNER=1 NFTBAN_VERSION=1.234.0 bash -c '
        set +e
        source "$1" 2>/dev/null || true
        trap - ERR; set +eE
        declare -F _status_package_consistency >/dev/null || { echo "NO_PROBE"; exit 0; }
        _nftban_protection_state() { echo PROTECTED; }
        nftban_stats_count_active_bans() { echo 0; }; nftban_stats_count_whitelist() { echo 0; }
        p=$(_status_package_consistency); echo "PKG=$p"
        echo "OVERALL=$(_status_overall_state PROTECTED "$p")"
        echo "OVERALL_DOWN=$(_status_overall_state DOWN "$p")"
        brc=0; b=$(output_brief) || brc=$?; echo "BRIEF=$b RC=$brc"
        _status_section_system "$(_status_overall_state PROTECTED "$p")" PROTECTED "$p" 2>/dev/null
    ' _ "$STATUS" 2>&1
}

echo "=========================================================="
echo "v1.234 PR #1439: status separates firewall runtime from installation"
echo "=========================================================="

check_incomplete() {  # LABEL OUTPUT DETAIL_REGEX
    local label=$1 out=$2 re=$3
    if [[ "$out" == *NO_PROBE* ]]; then no "$label" "no installation-consistency probe in cmd_status.sh"; return; fi
    if grep -q '^PKG=INCOMPLETE|' <<< "$out" && grep -qE "$re" <<< "$out" \
       && grep -q '^OVERALL=DEGRADED:D-PACKAGE$' <<< "$out" && grep -q '^OVERALL_DOWN=DOWN$' <<< "$out" \
       && grep -qE '^BRIEF=DEGRADED:D-PACKAGE .* RC=1$' <<< "$out" \
       && grep -qE 'Firewall runtime\.+ +PROTECTED' <<< "$out" && grep -qE 'Installation\.+ +INCOMPLETE' <<< "$out" \
       && grep -q 'Recovery:' <<< "$out"; then
        ok "$label"
    else
        no "$label" "$(grep -E '^(PKG|OVERALL|BRIEF)=|Firewall runtime|Installation|Recovery' <<< "$out" | tr '\n' ';')"
    fi
}

check_incomplete "S1 dpkg iHR (read-only mount, measured B5): INCOMPLETE, overall DEGRADED:D-PACKAGE, runtime PROTECTED, brief rc 1" \
    "$(probe deb-iHR 1.233.1 COMMITTED 1.233.1)" 'iHR'
check_incomplete "S2 dpkg iF (postinst died, measured C1): INCOMPLETE" \
    "$(probe deb-iF 1.234.0 COMMITTED 1.233.1)" '"iF"'
check_incomplete "S3 RPM partial upgrade (rpmdb 1.233.1, files 1.234.0, measured R3): INCOMPLETE" \
    "$(probe rpm-partial 1.234.0 COMMITTED 1.233.1)" 'partial upgrade'
check_incomplete "S4 package removed, install_state still COMMITTED (acceptance U3): INCOMPLETE" \
    "$(probe deb-removed '' COMMITTED 1.234.0)" 'not installed'
check_incomplete "S5 package installed but installer never ran for it (RPM post failure shape): INCOMPLETE" \
    "$(probe rpm-ok 1.234.0 COMMITTED 1.233.1)" 'last installer transaction'

out=$(probe deb-ok 1.234.0 COMMITTED 1.234.0)
if grep -q '^PKG=CONSISTENT|' <<< "$out" && grep -q '^OVERALL=PROTECTED$' <<< "$out" && grep -qE '^BRIEF=PROTECTED .* RC=0$' <<< "$out"; then
    ok "S6 consistent DEB install stays PROTECTED (no false DEGRADED)"
else no "S6 consistent DEB" "$(grep -E '^(PKG|OVERALL|BRIEF)=' <<< "$out" | tr '\n' ';')"; fi
out=$(probe rpm-ok 1.234.0 COMMITTED 1.234.0)
if grep -q '^PKG=CONSISTENT|' <<< "$out" && grep -qE '^BRIEF=PROTECTED .* RC=0$' <<< "$out"; then
    ok "S7 consistent RPM install stays PROTECTED"
else no "S7 consistent RPM" "$(grep -E '^(PKG|OVERALL|BRIEF)=' <<< "$out" | tr '\n' ';')"; fi
out=$(probe none 1.234.0 COMMITTED 1.234.0)
if grep -q '^PKG=UNMEASURED|' <<< "$out" && grep -q '^OVERALL=PROTECTED$' <<< "$out"; then
    ok "S8 no package record (source install): UNMEASURED, overall unchanged"
else no "S8 source install" "$(grep -E '^(PKG|OVERALL)=' <<< "$out" | tr '\n' ';')"; fi

echo "----------------------------------------------------------"
echo "RESULT: PASS=$PASS FAIL=$FAIL"
if (( FAIL > 0 )); then printf '  failed: %s\n' "${FAILED[@]}"; exit 1; fi
(( PASS > 0 )) || { echo "NOT_EXECUTED: zero assertions"; exit 1; }
exit 0
