#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.137 log-durability (PR-A logrotate config + packaging)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="logrotate_config_v137_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-27"
# meta:description="v1.137 log-durability regression. Asserts the config/packaging fixes that close the disk-fill exposure: B-05 (copytruncate on the main nftban stanza), B-09 (installer.log + update.log are covered by a stanza), B-04 (nftban suricata setup installs the suricata logrotate policy into /etc/logrotate.d/ and that policy covers suricata/eve-* + fast.log + stats.log), B-01 (the health-fix repair fallback no longer auto-generates a DIVERGENT policy when the packaged template is missing — single source of truth), the newly-declared logrotate package dependency (RPM Requires + DEB Depends, both build paths), and GEO-CLEANUP-001 (nftban_report_services.sh reads canonical GEOBAN_ENABLED). Behavioral: logrotate -d (debug parse) on a host-sanitized copy of each rendered config parses with no syntax error. No host contact; no root required; logrotate-parse steps SKIP cleanly if logrotate is not installed."
# meta:input="None (reads repo source files; self-contained sandbox)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep,sed,mktemp"
# meta:inventory.files="install/config/nftban.logrotate,install/config/nftban-suricata.logrotate,cli/lib/nftban/cli/cmd_suricata_setup.sh,cli/lib/nftban/core/nftban_health_fixes.sh,cli/lib/nftban/core/nftban_report_services.sh,packaging/build_nftban.sh,packaging/deb/control"
# meta:inventory.binaries="bash,grep,sed,mktemp,logrotate"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="logrotate_config_v137_test"
# meta:ta.owner="packaging"
# meta:ta.module="logrotate"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
# Lane:    NFTBAN_ROADMAP/V1_137_LOG_DURABILITY_SCOPE.md (PR-A)
# Gate:    OPEN_V1_137_PR_A_LOGROTATE_CONFIG_AND_PACKAGING
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)

LR_MAIN="${REPO_ROOT}/install/config/nftban.logrotate"
LR_SURI="${REPO_ROOT}/install/config/nftban-suricata.logrotate"
SURI_SETUP="${REPO_ROOT}/cli/lib/nftban/cli/cmd_suricata_setup.sh"
HEALTH_FIX="${REPO_ROOT}/cli/lib/nftban/core/nftban_health_fixes.sh"
REPORT_SVC="${REPO_ROOT}/cli/lib/nftban/core/nftban_report_services.sh"
BUILD="${REPO_ROOT}/packaging/build_nftban.sh"
DEB_CONTROL="${REPO_ROOT}/packaging/deb/control"
LOGS_GO="${REPO_ROOT}/internal/nftbanconf/logs.go"

SANDBOX=$(mktemp -d); trap 'rm -rf "$SANDBOX"' EXIT
PASS=0; FAIL=0; SKIP=0; FAILED_TESTS=()
ok(){ printf "  [PASS] %s\n" "$1"; PASS=$((PASS+1)); }
no(){ printf "  [FAIL] %s (%s)\n" "$1" "$2"; FAIL=$((FAIL+1)); FAILED_TESTS+=("$1"); }
sk(){ printf "  [SKIP] %s (%s)\n" "$1" "$2"; SKIP=$((SKIP+1)); }

echo "=========================================================="
echo "V1.137 log-durability — PR-A logrotate config/packaging test"
echo "=========================================================="

# Extract a single logrotate stanza (block ending in '}') whose header lines
# include a given log path. Prints the block body.
stanza_for() {
    local file="$1" path="$2"
    awk -v want="$path" '
        # accumulate header path lines until we hit the "{"
        { buf = buf $0 ORS }
        /\{/ { inblk=1 }
        /\}/ { if (inblk && buf ~ want) { printf "%s", buf } ; buf=""; inblk=0 }
    ' "$file"
}

# ---------------------------------------------------------------------------
echo "--- B-05: copytruncate on the main stanza ---"
# ---------------------------------------------------------------------------
main_stanza=$(stanza_for "$LR_MAIN" "nftban.log")
if [[ -n "$main_stanza" ]]; then
    grep -q 'login-monitor.log' <<<"$main_stanza" && ok "main_stanza_groups_login_monitor" || no "main_stanza_groups_login_monitor" "login-monitor.log not in same block as nftban.log"
    grep -q 'copytruncate' <<<"$main_stanza" && ok "main_stanza_has_copytruncate" || no "main_stanza_has_copytruncate" "copytruncate missing from main stanza"
else
    no "main_stanza_present" "could not isolate the nftban.log stanza"
fi
# Every stanza in the main config must use copytruncate (no rename+postrotate left)
if grep -q 'postrotate' "$LR_MAIN"; then
    no "main_no_postrotate_reload" "a postrotate reload still present (rename-mode writer-loss risk)"
else
    ok "main_no_postrotate_reload"
fi

# ---------------------------------------------------------------------------
echo "--- B-09: installer.log + update.log covered ---"
# ---------------------------------------------------------------------------
inst_stanza=$(stanza_for "$LR_MAIN" "installer.log")
grep -q '/var/log/nftban/installer.log' "$LR_MAIN" && ok "installer_log_listed" || no "installer_log_listed" "installer.log path not in config"
grep -q '/var/log/nftban/update.log' "$LR_MAIN" && ok "update_log_listed" || no "update_log_listed" "update.log path not in config"
grep -q 'copytruncate' <<<"$inst_stanza" && ok "installer_update_stanza_copytruncate" || no "installer_update_stanza_copytruncate" "installer/update stanza lacks copytruncate"

# ---------------------------------------------------------------------------
echo "--- B-04: suricata setup installs the logrotate policy to /etc/logrotate.d/ ---"
# ---------------------------------------------------------------------------
grep -q '/etc/logrotate.d/nftban-suricata' "$SURI_SETUP" && ok "suri_setup_targets_logrotate_d" || no "suri_setup_targets_logrotate_d" "cmd_suricata_setup.sh does not install to /etc/logrotate.d/"
grep -Eq 'install -D .*nftban-suricata.logrotate|install -D .*"\$_slr_src" "\$_slr_dst"' "$SURI_SETUP" && ok "suri_setup_install_cmd" || no "suri_setup_install_cmd" "no install of the suricata template found"
# the shipped suricata policy must actually cover the high-volume eve + classic logs
grep -q 'eve-' "$LR_SURI" && ok "suri_policy_covers_eve" || no "suri_policy_covers_eve" "suricata policy does not cover eve-*"
grep -Eq 'fast.log|stats.log' "$LR_SURI" && ok "suri_policy_covers_fast_stats" || no "suri_policy_covers_fast_stats" "suricata policy missing fast.log/stats.log"

# ---------------------------------------------------------------------------
echo "--- B-01: health-fix fallback does NOT generate a divergent policy ---"
# ---------------------------------------------------------------------------
# The previous code wrote a heredoc generating a /*.log wildcard + a suricata
# stanza when the packaged template was absent. That generator must be gone.
if grep -Eq 'cat .*logrotate_dst.*<<|/var/log/nftban/\*\.log' "$HEALTH_FIX"; then
    no "healthfix_no_divergent_gen" "a wildcard/heredoc logrotate generator still present"
else
    ok "healthfix_no_divergent_gen"
fi
grep -q 'not auto-generating a divergent policy' "$HEALTH_FIX" && ok "healthfix_warn_only_path" || no "healthfix_warn_only_path" "warn-only fallback message missing"

# ---------------------------------------------------------------------------
echo "--- dependency: logrotate declared (RPM Requires + DEB Depends) ---"
# ---------------------------------------------------------------------------
grep -Eq '^Requires:[[:space:]]+logrotate' "$BUILD" && ok "rpm_requires_logrotate" || no "rpm_requires_logrotate" "RPM Requires logrotate missing in build_nftban.sh"
grep -Eq '^Depends:.*\blogrotate\b' "$BUILD" && ok "deb_inline_depends_logrotate" || no "deb_inline_depends_logrotate" "DEB inline Depends logrotate missing in build_nftban.sh"
# packaging/deb/control: logrotate must be in Depends, not Recommends
if awk '/^Depends:/{d=1} /^Recommends:/{d=0} d && /logrotate/{found=1} END{exit !found}' "$DEB_CONTROL"; then
    ok "deb_control_depends_logrotate"
else
    no "deb_control_depends_logrotate" "logrotate not under Depends in packaging/deb/control"
fi

# ---------------------------------------------------------------------------
echo "--- GEO-CLEANUP-001: canonical GEOBAN_ENABLED ---"
# ---------------------------------------------------------------------------
if grep -q 'NFTBAN_GEOBAN_ENABLED' "$REPORT_SVC"; then
    no "geoban_var_canonical" "phantom NFTBAN_GEOBAN_ENABLED still present"
else
    ok "geoban_var_canonical"
fi
grep -q 'GEOBAN_ENABLED' "$REPORT_SVC" && ok "geoban_var_referenced" || no "geoban_var_referenced" "GEOBAN_ENABLED not referenced"

# ---------------------------------------------------------------------------
echo "--- B-12: logs.go inventory authority reconciled to current real files ---"
# ---------------------------------------------------------------------------
# Static mirror of the Go drift-test (logs_logrotate_drift_test.go), runnable
# without Go: assert the inventory carries current filenames, not legacy names.
if [[ -f "$LOGS_GO" ]]; then
    grep -q 'func LogInventory()' "$LOGS_GO" && ok "b12_inventory_authority_present" || no "b12_inventory_authority_present" "LogInventory() not found"
    # current/reconciled names present
    for cur in 'ddos-classic.log' 'ddos-suricata.log' 'portscan-classic.log' 'portscan-suricata.log' 'cli-errors.log' 'installer.log' 'update.log' 'suricata/eve-alerts.json'; do
        grep -q "\"$cur\"" "$LOGS_GO" && ok "b12_inventory_has_$cur" || no "b12_inventory_has_$cur" "inventory missing $cur"
    done
    # underscore CLI-errors name must NOT be an inventory entry (hyphen is real)
    if grep -qE 'Name:[[:space:]]*"cli_errors.log"' "$LOGS_GO"; then
        no "b12_no_legacy_cli_errors.log" "legacy name cli_errors.log still an inventory entry"
    else
        ok "b12_no_legacy_cli_errors.log"
    fi
    # v1.137 gap close (Option A): plain ddos.log/portscan.log are LIVE writer
    # targets — must be BOTH inventoried AND template-covered (not removed).
    for plain in 'ddos.log' 'portscan.log'; do
        grep -qE "Name:[[:space:]]*\"$plain\"" "$LOGS_GO" && ok "b12_inventory_has_$plain" || no "b12_inventory_has_$plain" "inventory missing live log $plain"
        grep -qE "^/var/log/nftban/$plain\$" "$LR_MAIN" && ok "b12_template_covers_$plain" || no "b12_template_covers_$plain" "template missing live log $plain"
    done
    # generator direction must be explicitly rejected (templates NOT generated)
    grep -q 'NOT generated from this inventory' "$LOGS_GO" && ok "b12_generator_rejected_documented" || no "b12_generator_rejected_documented" "generator-rejection rationale missing"
    # the Go drift-test (bridge) must exist
    [[ -f "${REPO_ROOT}/internal/nftbanconf/logs_logrotate_drift_test.go" ]] && ok "b12_go_drift_test_present" || no "b12_go_drift_test_present" "Go drift-test missing"
else
    sk "b12_inventory_checks" "logs.go not found at expected path"
fi

# ---------------------------------------------------------------------------
echo "--- behavioral: logrotate -d parses each rendered config (host-sanitized) ---"
# ---------------------------------------------------------------------------
# Sanitize host-state-dependent directives (create owner/group, su) so the
# PARSE check validates config STRUCTURE independent of whether the nftban /
# suricata users exist on the test host. Ownership correctness is covered by the
# static asserts above + the lab-VM fresh-install validation.
sanitize() {
    sed -E 's/(create[[:space:]]+[0-9]+)[[:space:]]+[A-Za-z0-9_-]+[[:space:]]+[A-Za-z0-9_-]+/\1/; /^[[:space:]]*su[[:space:]]+[A-Za-z0-9_-]+[[:space:]]+[A-Za-z0-9_-]+[[:space:]]*$/d; s/(createolddir[[:space:]]+[0-9]+)[[:space:]]+[A-Za-z0-9_-]+[[:space:]]+[A-Za-z0-9_-]+/\1/' "$1"
}
if command -v logrotate >/dev/null 2>&1; then
    for cfg in "$LR_MAIN" "$LR_SURI"; do
        name=$(basename "$cfg")
        san="$SANDBOX/$name"
        sanitize "$cfg" > "$san"
        # -d = debug/dry-run: parse only, no rotation. --state points at a
        # writable sandbox file so a non-root run does not hit the system state
        # file. Pre-create it: logrotate 3.18 (EL9) emits "error opening state
        # file ... No such file" for a missing --state path even in -d, whereas
        # newer logrotate creates it silently — pre-touch makes the test portable.
        : > "$SANDBOX/lr.status"
        out=$(logrotate -d --state "$SANDBOX/lr.status" "$san" 2>&1) || true
        # Real config-syntax errors only. Filter host/version-state notices that
        # are NOT config defects: missing log files (missingok) and the 3.18
        # state-file-open message above.
        real_errs=$(grep -E '^error:' <<<"$out" | grep -v 'error opening state file' || true)
        if [[ -n "$real_errs" ]]; then
            no "logrotate_parse_$name" "logrotate -d error: $(head -1 <<<"$real_errs")"
        else
            ok "logrotate_parse_$name"
        fi
    done
else
    sk "logrotate_parse_main" "logrotate not installed on test host"
    sk "logrotate_parse_suricata" "logrotate not installed on test host"
fi

echo "=========================================================="
echo "RESULTS: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
if (( FAIL > 0 )); then
    printf 'FAILED: %s\n' "${FAILED_TESTS[@]}"
    exit 1
fi
echo "ALL PASS"
exit 0
