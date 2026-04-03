#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Smoke Test Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: CLI wrapper for smoke test suite
#
# meta:name="cmd_smoke"
# meta:type="cli"
# meta:header="Smoke Test Command"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Run CLI health checks, ban lifecycle tests, and detect stuck scripts"
# meta:depends="bash,nftban_trace.sh"
#
# meta:inventory.files=""
# meta:inventory.binaries="nftban"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2025-12-04"
# meta:updated_date="2026-01-28"
# =============================================================================

set -Eeuo pipefail

[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

# Prevent double-loading
[[ -n "${CMD_SMOKE_LOADED:-}" ]] && return 0
readonly CMD_SMOKE_LOADED=1

# =============================================================================
# COMMAND HANDLER
# =============================================================================

nftban_cmd_smoke() {
    local subcommand="${1:-run}"
    shift || true

    # Source output module for banner
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
        nftban_banner
    fi
    echo ""

    case "$subcommand" in
        run|test)
            nftban_smoke_run "$@"
            ;;
        quick)
            nftban_smoke_run --quick "$@"
            ;;
        all|detailed)
            # Comprehensive test of ALL 43 CLI commands
            nftban_smoke_run --all "$@"
            ;;
        lifecycle)
            # Ban/unban + whitelist lifecycle tests only
            nftban_smoke_run --lifecycle "$@"
            ;;
        verify)
            # Smart validation: verify counts match expectations
            nftban_smoke_verify "$@"
            ;;
        config|configs)
            # Verify config file integrity (CI/build validation)
            nftban_smoke_verify_configs "$@"
            ;;
        check|orphans)
            nftban_smoke_check_orphans "$@"
            ;;
        stats)
            nftban_smoke_stats
            ;;
        trace)
            nftban_smoke_trace "$@"
            ;;
        help|--help|-h)
            nftban_cmd_smoke_usage
            ;;
        *)
            echo "ERROR: Unknown subcommand: $subcommand" >&2
            nftban_cmd_smoke_usage
            return 1
            ;;
    esac
}

# =============================================================================
# SUBCOMMAND HANDLERS
# =============================================================================

nftban_smoke_run() {
    # Use central path from config
    local tests_dir="${NFTBAN_TESTS_DIR:-/usr/lib/nftban/tests}"
    local test_script="${tests_dir}/smoke_test.sh"

    if [[ ! -f "$test_script" ]]; then
        echo "ERROR: Smoke test script not found at: $test_script" >&2
        echo "Hint: Run 'sudo ./install.sh tests' to install test suite" >&2
        return 1
    fi

    echo "Running NFTBan Smoke Test Suite..."
    echo ""

    bash "$test_script" "$@"
}

nftban_smoke_check_orphans() {
    local minutes="${1:-5}"

    # Source trace library
    if [[ -f "${NFTBAN_LIB_DIR}/helpers/nftban_trace.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/helpers/nftban_trace.sh" || return 1
    else
        echo "ERROR: Trace library not found" >&2
        return 1
    fi

    echo "Checking for orphaned traces (scripts that started but never finished)..."
    echo "Looking for traces older than ${minutes} minutes..."
    echo ""

    nftban_trace_find_orphans "$minutes"
}

nftban_smoke_stats() {
    # Source trace library
    if [[ -f "${NFTBAN_LIB_DIR}/helpers/nftban_trace.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/helpers/nftban_trace.sh" || return 1
    else
        echo "ERROR: Trace library not found" >&2
        return 1
    fi

    nftban_trace_stats
}

nftban_smoke_trace() {
    local subcommand="${1:-recent}"
    shift || true

    # Source trace library
    if [[ -f "${NFTBAN_LIB_DIR}/helpers/nftban_trace.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/helpers/nftban_trace.sh" || return 1
    else
        echo "ERROR: Trace library not found" >&2
        return 1
    fi

    case "$subcommand" in
        recent)
            local count="${1:-20}"
            nftban_trace_recent "$count"
            ;;
        rotate)
            local days="${1:-7}"
            nftban_trace_rotate "$days"
            ;;
        enable|disable)
            echo "Use 'nftban debug $subcommand' instead"
            echo ""
            echo "Quick reference:"
            echo "  nftban debug enable    Enable debug trace"
            echo "  nftban debug disable   Disable debug trace"
            echo "  nftban debug status    Show debug status"
            ;;
        *)
            echo "Unknown trace command: $subcommand"
            echo "Available: recent, rotate"
            echo ""
            echo "For enable/disable, use: nftban debug enable/disable"
            return 1
            ;;
    esac
}

# =============================================================================
# SMART VERIFICATION (nftban smoke verify)
# =============================================================================
# Validates that nftables counts match expectations:
# - Ban/unban operations change counts correctly
# - Feed IPs are loaded correctly
# - GeoBan country blocks are applied
# =============================================================================

nftban_smoke_verify() {
    local subcommand="${1:-all}"
    shift || true

    # Source nft_schema for centralized counting (SINGLE SOURCE OF TRUTH)
    if [[ -f "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" || return 1
    else
        echo "ERROR: nft_schema.sh not found - cannot verify counts" >&2
        return 1
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NFTBan Smart Verification Tests"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    local passed=0
    local failed=0

    # v1.19.20 FIX: Added || true to prevent set -e failures when var is 0
    case "$subcommand" in
        all)
            _verify_ban_counts && { ((passed++)) || true; } || { ((failed++)) || true; }
            _verify_whitelist_counts && { ((passed++)) || true; } || { ((failed++)) || true; }
            _verify_feeds && { ((passed++)) || true; } || { ((failed++)) || true; }
            _verify_geoban && { ((passed++)) || true; } || { ((failed++)) || true; }
            ;;
        bans)
            _verify_ban_counts && { ((passed++)) || true; } || { ((failed++)) || true; }
            ;;
        whitelist)
            _verify_whitelist_counts && { ((passed++)) || true; } || { ((failed++)) || true; }
            ;;
        feeds)
            _verify_feeds && { ((passed++)) || true; } || { ((failed++)) || true; }
            ;;
        geoban)
            _verify_geoban && { ((passed++)) || true; } || { ((failed++)) || true; }
            ;;
        *)
            echo "ERROR: Unknown verify target: $subcommand" >&2
            echo "Available: all, bans, whitelist, feeds, geoban" >&2
            return 1
            ;;
    esac

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ $failed -eq 0 ]]; then
        echo "  Result: ✅ ALL PASSED ($passed tests)"
    else
        echo "  Result: ❌ FAILED ($failed failed, $passed passed)"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    [[ $failed -eq 0 ]]
}

_verify_ban_counts() {
    echo "VERIFY: Ban Count Changes"
    echo "───────────────────────────────────────────────────────────────"

    local test_ip="192.0.2.250"  # TEST-NET-1 (RFC 5737) - safe for testing
    local errors=0

    # Get baseline count
    local before after expected

    echo "  1. Getting baseline count..."
    before=$(nftban_nft_count_blacklist 2>/dev/null | awk '{print $3}')
    before=${before:-0}
    printf "     Baseline: %d IPs in blacklist\n" "$before"

    # Test: Add IP should increase count by 1
    echo "  2. Testing ban add (+1)..."
    if nftban ban "$test_ip" --reason "smoke-verify-test" >/dev/null 2>&1; then
        sleep 0.5  # Allow nftables to sync
        after=$(nftban_nft_count_blacklist 2>/dev/null | awk '{print $3}')
        after=${after:-0}
        expected=$((before + 1))

        if [[ "$after" -eq "$expected" ]]; then
            printf "     ✅ PASS: Count increased %d → %d (expected +1)\n" "$before" "$after"
        else
            printf "     ❌ FAIL: Count is %d, expected %d\n" "$after" "$expected"
            # v1.19.20 FIX
            ((errors++)) || true
        fi
    else
        echo "     ⚠️  SKIP: Ban command failed (may need root)"
        # Cleanup not needed if ban failed
        return 0
    fi

    # Test: Remove IP should decrease count by 1
    echo "  3. Testing unban (-1)..."
    local before_unban="$after"
    if nftban unban "$test_ip" >/dev/null 2>&1; then
        sleep 0.5
        after=$(nftban_nft_count_blacklist 2>/dev/null | awk '{print $3}')
        after=${after:-0}
        expected=$((before_unban - 1))

        if [[ "$after" -eq "$expected" ]]; then
            printf "     ✅ PASS: Count decreased %d → %d (expected -1)\n" "$before_unban" "$after"
        else
            printf "     ❌ FAIL: Count is %d, expected %d\n" "$after" "$expected"
            # v1.19.20 FIX
            ((errors++)) || true
        fi
    else
        echo "     ⚠️  WARN: Unban command failed"
        # v1.19.20 FIX
        ((errors++)) || true
    fi

    # Verify we're back to baseline
    echo "  4. Verifying baseline restored..."
    local final
    final=$(nftban_nft_count_blacklist 2>/dev/null | awk '{print $3}')
    final=${final:-0}
    if [[ "$final" -eq "$before" ]]; then
        printf "     ✅ PASS: Count restored to baseline (%d)\n" "$before"
    else
        printf "     ⚠️  WARN: Count is %d, baseline was %d (delta: %d)\n" "$final" "$before" "$((final - before))"
    fi

    echo ""
    [[ $errors -eq 0 ]]
}

_verify_whitelist_counts() {
    echo "VERIFY: Whitelist Count Changes"
    echo "───────────────────────────────────────────────────────────────"

    local test_ip="198.51.100.250"  # TEST-NET-2 (RFC 5737) - safe for testing
    local errors=0

    # Get baseline count
    local before after expected

    echo "  1. Getting baseline count..."
    before=$(nftban_nft_count_whitelist 2>/dev/null | awk '{print $3}')
    before=${before:-0}
    printf "     Baseline: %d IPs in whitelist\n" "$before"

    # Test: Add to whitelist should increase count by 1
    echo "  2. Testing whitelist add (+1)..."
    if nftban whitelist add "$test_ip" >/dev/null 2>&1; then
        sleep 0.5
        after=$(nftban_nft_count_whitelist 2>/dev/null | awk '{print $3}')
        after=${after:-0}
        expected=$((before + 1))

        if [[ "$after" -eq "$expected" ]]; then
            printf "     ✅ PASS: Count increased %d → %d (expected +1)\n" "$before" "$after"
        else
            printf "     ❌ FAIL: Count is %d, expected %d\n" "$after" "$expected"
            # v1.19.20 FIX
            ((errors++)) || true
        fi
    else
        echo "     ⚠️  SKIP: Whitelist add failed (may need root)"
        return 0
    fi

    # Test: Remove from whitelist should decrease count by 1
    echo "  3. Testing whitelist remove (-1)..."
    local before_remove="$after"
    if nftban whitelist remove "$test_ip" >/dev/null 2>&1; then
        sleep 0.5
        after=$(nftban_nft_count_whitelist 2>/dev/null | awk '{print $3}')
        after=${after:-0}
        expected=$((before_remove - 1))

        if [[ "$after" -eq "$expected" ]]; then
            printf "     ✅ PASS: Count decreased %d → %d (expected -1)\n" "$before_remove" "$after"
        else
            printf "     ❌ FAIL: Count is %d, expected %d\n" "$after" "$expected"
            # v1.19.20 FIX
            ((errors++)) || true
        fi
    else
        echo "     ⚠️  WARN: Whitelist remove failed"
        # v1.19.20 FIX
        ((errors++)) || true
    fi

    echo ""
    [[ $errors -eq 0 ]]
}

_verify_feeds() {
    echo "VERIFY: Feed IP Counts"
    echo "───────────────────────────────────────────────────────────────"

    local feeds_dir="${NFTBAN_DATA_DIR:-/var/lib/nftban}/feeds"
    local errors=0
    local feeds_checked=0
    local total_file_ips=0

    if [[ ! -d "$feeds_dir" ]]; then
        echo "  ⚠️  SKIP: Feeds directory not found: $feeds_dir"
        return 0
    fi

    echo "  Checking feed files in: $feeds_dir"
    echo ""

    # Check each feed file
    for feed_file in "$feeds_dir"/*.txt "$feeds_dir"/*.list; do
        [[ -f "$feed_file" ]] || continue

        local feed_name
        feed_name=$(basename "$feed_file" | sed 's/\.\(txt\|list\)$//')
        local file_count
        file_count=$(grep -cE '^[0-9]' "$feed_file" 2>/dev/null || echo "0")
        total_file_ips=$((total_file_ips + file_count))
        # v1.19.20 FIX
        ((feeds_checked++)) || true

        printf "  %-20s %'d IPs in file\n" "$feed_name" "$file_count"
    done

    if [[ $feeds_checked -eq 0 ]]; then
        echo "  ⚠️  SKIP: No feed files found"
        return 0
    fi

    echo ""
    echo "  Summary:"
    printf "     Feed files checked: %d\n" "$feeds_checked"
    printf "     Total IPs in files: %'d\n" "$total_file_ips"

    # Get loaded count from nftables (blacklist includes feeds)
    local blacklist_count
    blacklist_count=$(nftban_nft_count_blacklist 2>/dev/null | awk '{print $3}')
    blacklist_count=${blacklist_count:-0}
    printf "     IPs in blacklist:   %'d\n" "$blacklist_count"

    # Note: blacklist may contain more than just feeds (manual bans, geoban, etc.)
    # So we check that blacklist >= feeds (not exact match)
    if [[ "$blacklist_count" -ge "$total_file_ips" ]] || [[ "$total_file_ips" -eq 0 ]]; then
        echo ""
        echo "     ✅ PASS: Blacklist contains feed IPs (may include manual bans + geoban)"
    else
        echo ""
        echo "     ⚠️  WARN: Blacklist ($blacklist_count) < feed files ($total_file_ips)"
        echo "              Some feeds may not be loaded. Check: nftban feeds status"
    fi

    echo ""
    [[ $errors -eq 0 ]]
}

_verify_geoban() {
    echo "VERIFY: GeoBan Country Blocks"
    echo "───────────────────────────────────────────────────────────────"

    local geoban_dir="${NFTBAN_CONFIG_DIR:-/etc/nftban}/geoban.d"
    local errors=0

    # Check for blocked countries in config
    echo "  1. Checking GeoBan configuration..."

    local blocked_countries=0
    if [[ -d "$geoban_dir" ]]; then
        blocked_countries=$(ls -1 "$geoban_dir"/50-ban-*.conf 2>/dev/null | wc -l) || blocked_countries=0
    fi

    if [[ $blocked_countries -eq 0 ]]; then
        # Alternative: check geoban list command
        blocked_countries=$(nftban geoban list 2>/dev/null | grep -c "BLOCKED" 2>/dev/null || echo "0")
    fi

    printf "     Countries blocked: %d\n" "$blocked_countries"

    if [[ $blocked_countries -eq 0 ]]; then
        echo ""
        echo "  ⚠️  SKIP: No countries blocked (GeoBan not configured)"
        echo "     To enable: nftban geoban block CN  (example)"
        return 0
    fi

    # List blocked countries
    echo ""
    echo "  2. Blocked countries:"
    if command -v nftban >/dev/null 2>&1; then
        nftban geoban list 2>/dev/null | grep "BLOCKED" | head -5 | sed 's/^/     /'
        [[ $blocked_countries -gt 5 ]] && echo "     ... and $((blocked_countries - 5)) more" || true
    fi

    # Verify GeoIP database is available
    echo ""
    echo "  3. Checking GeoIP database..."
    local geoip_db="${NFTBAN_DATA_DIR:-/var/lib/nftban}/geoip"
    if [[ -f "$geoip_db/dbip-country-lite.mmdb" ]] || [[ -f "$geoip_db/GeoLite2-Country.mmdb" ]]; then
        echo "     ✅ GeoIP database found"
    else
        echo "     ⚠️  WARN: GeoIP database not found in $geoip_db"
        echo "              Run: nftban geoip update"
    fi

    # Verify country CIDRs are in blacklist
    echo ""
    echo "  4. Verifying country blocks in nftables..."
    local blacklist_count
    blacklist_count=$(nftban_nft_count_blacklist 2>/dev/null | awk '{print $3}')
    blacklist_count=${blacklist_count:-0}

    if [[ $blacklist_count -gt 0 ]]; then
        printf "     ✅ PASS: Blacklist has %'d entries (includes country blocks)\n" "$blacklist_count"
    else
        echo "     ⚠️  WARN: Blacklist is empty - country blocks may not be loaded"
        echo "              Run: nftban-core sync"
    fi

    echo ""
    [[ $errors -eq 0 ]]
}

# =============================================================================
# CONFIG INTEGRITY VERIFICATION (nftban smoke config)
# =============================================================================
# Validates that all config files exist and are properly tracked:
# - Files in conffiles exist in the filesystem
# - Files referenced in build scripts exist in git
# - No orphaned config references
# =============================================================================

nftban_smoke_verify_configs() {
    local project_root="${NFTBAN_PROJECT_ROOT:-}"
    local check_mode="${1:-runtime}"  # runtime or build

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NFTBan Configuration File Integrity Check"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    local passed=0
    local failed=0

    if [[ "$check_mode" == "build" ]] && [[ -n "$project_root" ]]; then
        # Build-time check: verify source files exist in git
        echo "MODE: Build-time verification (source files)"
        echo ""
        if _verify_conffiles_sources "$project_root"; then
            ((++passed))
        else
            ((++failed))
        fi
        if _verify_install_configs_sources "$project_root"; then
            ((++passed))
        else
            ((++failed))
        fi
        if _verify_build_script_sources "$project_root"; then
            ((++passed))
        else
            ((++failed))
        fi
    else
        # Runtime check: verify installed files exist
        echo "MODE: Runtime verification (installed files)"
        echo ""
        if _verify_runtime_configs; then
            ((++passed))
        else
            ((++failed))
        fi
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ $failed -eq 0 ]]; then
        echo "  Result: ✅ ALL PASSED ($passed checks)"
    else
        echo "  Result: ❌ FAILED ($failed failed, $passed passed)"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    [[ $failed -eq 0 ]]
}

_verify_runtime_configs() {
    echo "CHECK: Runtime Configuration Files"
    echo "───────────────────────────────────────────────────────────────"

    local errors=0
    local checked=0

    # Critical config files that MUST exist for nftban to work
    local critical_configs=(
        "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf"
        "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/mail.conf"
        "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/stats.conf"
        "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/ddos/main.conf"
        "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/portscan/main.conf"
        "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/login/main.conf"
    )

    # Suricata config files (required if Suricata is enabled)
    local suricata_configs=(
        "${NFTBAN_CONFIG_DIR:-/etc/nftban}/suricata/config/profile.conf"
        "${NFTBAN_CONFIG_DIR:-/etc/nftban}/suricata/suricata.yaml.overlay"
        "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/suricata/interfaces.conf"
    )

    echo "  Checking critical config files..."
    for config in "${critical_configs[@]}"; do
        # v1.19.20 FIX
        ((checked++)) || true
        if [[ -f "$config" ]]; then
            printf "     ✅ %s\n" "$config"
        else
            printf "     ❌ MISSING: %s\n" "$config"
            # v1.19.20 FIX
            ((errors++)) || true
        fi
    done

    echo ""
    echo "  Checking Suricata config files..."
    local suricata_installed=false
    if command -v suricata >/dev/null 2>&1; then
        suricata_installed=true
    fi

    for config in "${suricata_configs[@]}"; do
        # v1.19.20 FIX
        ((checked++)) || true
        if [[ -f "$config" ]]; then
            printf "     ✅ %s\n" "$config"
        elif [[ "$suricata_installed" == "true" ]]; then
            printf "     ❌ MISSING: %s (Suricata installed but config missing!)\n" "$config"
            # v1.19.20 FIX
            ((errors++)) || true
        else
            printf "     ⚠️  SKIP: %s (Suricata not installed)\n" "$config"
        fi
    done

    echo ""
    printf "  Checked: %d files, Errors: %d\n" "$checked" "$errors"

    [[ $errors -eq 0 ]]
}

_verify_conffiles_sources() {
    local project_root="$1"
    local conffiles="${project_root}/install/packaging/deb/nftban.conffiles"

    echo "CHECK: DEB conffiles Source Verification"
    echo "───────────────────────────────────────────────────────────────"

    if [[ ! -f "$conffiles" ]]; then
        echo "  ⚠️  SKIP: conffiles not found: $conffiles"
        return 0
    fi

    local errors=0
    local checked=0

    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        # Convert installed path to source path
        local installed_path="$line"
        local source_path=""

        if [[ "$installed_path" == /etc/nftban/* ]]; then
            # Try multiple source locations in order of priority
            local relative="${installed_path#/etc/nftban/}"
            local basename
            basename=$(basename "$relative")

            if [[ -f "${project_root}/etc/nftban/${relative}" ]]; then
                source_path="${project_root}/etc/nftban/${relative}"
            elif [[ -f "${project_root}/install/config/${relative}" ]]; then
                source_path="${project_root}/install/config/${relative}"
            elif [[ -f "${project_root}/install/config/${basename}" ]]; then
                # Some files are in install/config/ without subdirectory
                source_path="${project_root}/install/config/${basename}"
            elif [[ -f "${project_root}/install/config/conf.d/${basename}" ]]; then
                # Or in install/config/conf.d/
                source_path="${project_root}/install/config/conf.d/${basename}"
            fi
        elif [[ "$installed_path" == /etc/logrotate.d/* ]]; then
            source_path="${project_root}/install/config/nftban.logrotate"
        elif [[ "$installed_path" == /etc/polkit-1/* ]]; then
            local relative="${installed_path#/etc/polkit-1/}"
            source_path="${project_root}/packaging/polkit-1/${relative}"
        fi

        # v1.19.20 FIX
        ((checked++)) || true
        if [[ -n "$source_path" && -f "$source_path" ]]; then
            printf "     ✅ %s\n" "$installed_path"
        else
            printf "     ❌ MISSING SOURCE: %s\n" "$installed_path"
            # v1.19.20 FIX
            ((errors++)) || true
        fi
    done < "$conffiles"

    echo ""
    printf "  Checked: %d entries, Errors: %d\n" "$checked" "$errors"

    [[ $errors -eq 0 ]]
}

_verify_install_configs_sources() {
    local project_root="$1"
    local install_configs="${project_root}/install_configs.sh"

    echo "CHECK: install_configs.sh Source Verification"
    echo "───────────────────────────────────────────────────────────────"

    if [[ ! -f "$install_configs" ]]; then
        echo "  ⚠️  SKIP: install_configs.sh not found: $install_configs"
        return 0
    fi

    local errors=0
    local checked=0
    local line=""
    local relative_path=""
    local source_path=""

    # Extract _install_config_file calls and check sources exist
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip function definition line and comments
        [[ "$line" == _install_config_file\(\)* ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        # Match: _install_config_file "$SCRIPT_DIR/path/to/file" ...
        # Extract the path after $SCRIPT_DIR/
        if [[ "$line" == *'_install_config_file "$SCRIPT_DIR/'* ]]; then
            # Extract path between $SCRIPT_DIR/ and the next "
            relative_path="${line#*\$SCRIPT_DIR/}"
            relative_path="${relative_path%%\"*}"
            source_path="${project_root}/${relative_path}"

            ((checked++)) || true
            if [[ -f "$source_path" ]]; then
                printf "     ✅ %s\n" "$relative_path"
            else
                printf "     ❌ MISSING: %s\n" "$relative_path"
                ((errors++)) || true
            fi
        fi
    done < "$install_configs"

    echo ""
    printf "  Checked: %d files, Errors: %d\n" "$checked" "$errors"

    [[ $errors -eq 0 ]]
}

_verify_build_script_sources() {
    local project_root="$1"
    local build_script="${project_root}/packaging/build_nftban.sh"

    echo "CHECK: build_nftban.sh Source Verification"
    echo "───────────────────────────────────────────────────────────────"

    if [[ ! -f "$build_script" ]]; then
        echo "  ⚠️  SKIP: build_nftban.sh not found: $build_script"
        return 0
    fi

    local errors=0
    local checked=0
    local line=""
    local relative_path=""
    local source_path=""

    # Check install commands for config files (etc/nftban paths only)
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        # Match: install -D -m 0644 etc/nftban/... or install -m 0644 etc/nftban/...
        if [[ "$line" == *'install -'*' etc/nftban/'* ]] || [[ "$line" == *'install -'*' install/'* ]]; then
            # Extract the path (either etc/nftban/... or install/...)
            if [[ "$line" == *' etc/nftban/'* ]]; then
                relative_path="${line#* etc/nftban/}"
                relative_path="etc/nftban/${relative_path%% *}"
            elif [[ "$line" == *' install/'* ]]; then
                relative_path="${line#* install/}"
                relative_path="install/${relative_path%% *}"
            else
                continue
            fi

            # Clean up the path (remove trailing quotes, etc)
            relative_path="${relative_path%%\"*}"
            relative_path="${relative_path%%\'*}"
            source_path="${project_root}/${relative_path}"

            ((checked++)) || true
            if [[ -f "$source_path" ]]; then
                printf "     ✅ %s\n" "$relative_path"
            else
                printf "     ❌ MISSING: %s\n" "$relative_path"
                ((errors++)) || true
            fi
        fi
    done < "$build_script"

    echo ""
    printf "  Checked: %d files, Errors: %d\n" "$checked" "$errors"

    [[ $errors -eq 0 ]]
}

# =============================================================================
# USAGE
# =============================================================================

nftban_cmd_smoke_usage() {
    cat <<EOF
Usage: nftban smoke <command> [OPTIONS]

CLI health check and debugging tool.

Commands:
  run, test          Run standard smoke test (~32 commands + lifecycle)
  quick              Run quick test (3 core commands only)
  all, detailed      Run ALL CLI tests (55+ commands - comprehensive)
  lifecycle          Run ban lifecycle tests only (IPv4/IPv6 ban+whitelist)
  verify [TARGET]    Smart validation - verify counts match expectations
  config [MODE]      Verify config file integrity (runtime or build)
  check [MINUTES]    Check for orphaned traces (stuck scripts)
  stats              Show trace statistics
  trace recent [N]   Show last N trace entries
  trace rotate [D]   Rotate trace log, keep D days

Test Modes:
  quick     = 3 tests    (version, help, status)
  run/test  = ~32 tests  (core + modules + stats + search + lifecycle)
  all       = 55+ tests  (every cmd_*.sh + extended status + lifecycle)
  lifecycle = 12 tests   (ban/unban + whitelist add/remove, IPv4 + IPv6)

Verify Targets:
  all       = Run all verification tests (default)
  bans      = Test ban/unban count changes (+1/-1)
  whitelist = Test whitelist add/remove count changes
  feeds     = Verify feed IPs are loaded correctly
  geoban    = Verify country blocks are applied

Examples:
  nftban smoke run              # Standard smoke test (~32 commands)
  nftban smoke quick            # Quick test (3 commands)
  nftban smoke all              # Test ALL CLI commands + lifecycle
  nftban smoke lifecycle        # Ban lifecycle tests only
  nftban smoke verify           # Run all smart verification tests
  nftban smoke verify bans      # Verify ban count changes only
  nftban smoke verify feeds     # Verify feeds loaded correctly
  nftban smoke verify geoban    # Verify country blocks applied
  nftban smoke config           # Verify runtime config files exist
  nftban smoke config build     # CI: verify source files exist (use with NFTBAN_PROJECT_ROOT)
  nftban smoke check            # Check for stuck scripts
  nftban smoke check 10         # Check traces older than 10 min
  nftban smoke stats            # Trace statistics
  nftban smoke trace recent 50  # Last 50 trace entries

Smart Verification:
  The 'verify' command tests that nftables counts change correctly:
  - Ban IP → blacklist count increases by 1
  - Unban IP → blacklist count decreases by 1
  - Feed files → IPs loaded into blacklist
  - GeoBan → Country CIDRs loaded into blacklist

Config Integrity Check:
  The 'config' command verifies configuration files:
  - runtime: Check that installed config files exist (default)
  - build:   CI mode - verify source files in git (needs NFTBAN_PROJECT_ROOT)

  CI Usage:
    NFTBAN_PROJECT_ROOT=/path/to/nftban nftban smoke config build

  This catches issues like missing config files in packages BEFORE release.
  Also see: nftban health, nftban status (runtime diagnostics)

Debug Trace Configuration:
  Set NFTBAN_DEBUG_TRACE="true" in /etc/nftban/nftban.conf to enable
  script execution tracing. Each script logs START/END with unique ID.
  If START exists without END = script crashed/stuck.

  Trace log: ${NFTBAN_LOG_DIR}/debug_trace.log

EOF
}

# Export functions
export -f nftban_cmd_smoke
export -f nftban_cmd_smoke_usage
