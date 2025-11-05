#!/usr/bin/env bash

# =============================================================================
# NFTBan Services Report Core Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: System services status scanning and reporting
#
# meta:name=nftban_report_services
# meta:type=core
# meta:header=Services Report Core
# meta:version=0.31.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Scans and reports status of all required system services
# meta:input=Service check options, output format
# meta:output=Service status reports (terminal, HTML, mail)
#
# **Inventory & Requirements**
# meta:depends=bash,systemctl
#
# meta:created_date=2025-11-05
# =============================================================================

# Strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# =============================================================================
# GLOBALS
# =============================================================================

declare -g -A NFTBAN_SERVICE_STATUS=()  # key: service_name -> "status|version|required|notes"
declare -g NFTBAN_SERVICE_TIMESTAMP="$(date --iso-8601=seconds)"
declare -g NFTBAN_SERVICE_OUTPUT_FORMAT="${NFTBAN_SERVICE_OUTPUT_FORMAT:-table}"

# Color symbols
NFTBAN_SERVICE_SYM_OK="✔"
NFTBAN_SERVICE_SYM_KO="✖"
NFTBAN_SERVICE_SYM_WARN="⚠"
C_RESET="\e[0m"
C_RED="\e[31m"
C_GREEN="\e[32m"
C_YELLOW="\e[33m"
C_CYAN="\e[36m"
C_BOLD="\e[1m"

# =============================================================================
# SERVICE SCANNING
# =============================================================================

#
# nftban_services_scan - Scan all required services
#
# Checks:
#   - nftables (systemd service)
#   - fail2ban (systemd service)
#   - golang (binary)
#   - mailx (binary)
#   - curl (binary)
#   - jq (binary)
#
nftban_services_scan() {
    # Clear previous scan
    NFTBAN_SERVICE_STATUS=()

    # ==========================================================================
    # SYSTEMD SERVICES
    # ==========================================================================

    # nftables
    local nft_status="NOT_FOUND"
    local nft_version="n/a"
    local nft_notes=""

    if command -v systemctl &>/dev/null && systemctl list-unit-files nftables.service &>/dev/null 2>&1; then
        if systemctl is-active nftables.service &>/dev/null 2>&1; then
            nft_status="RUNNING"
        elif systemctl is-enabled nftables.service &>/dev/null 2>&1; then
            nft_status="ENABLED"
        else
            nft_status="STOPPED"
        fi

        if command -v nft &>/dev/null; then
            nft_version=$(nft --version 2>&1 | head -1 | awk '{print $2}' || echo "unknown")
        fi
        nft_notes="Netfilter tables firewall"
    else
        nft_notes="Service not found or systemd not available"
    fi

    NFTBAN_SERVICE_STATUS["nftables"]="${nft_status}|${nft_version}|required|${nft_notes}"

    # fail2ban
    local f2b_status="NOT_FOUND"
    local f2b_version="n/a"
    local f2b_notes=""

    if command -v systemctl &>/dev/null && systemctl list-unit-files fail2ban.service &>/dev/null 2>&1; then
        if systemctl is-active fail2ban.service &>/dev/null 2>&1; then
            f2b_status="RUNNING"
        elif systemctl is-enabled fail2ban.service &>/dev/null 2>&1; then
            f2b_status="ENABLED"
        else
            f2b_status="STOPPED"
        fi

        if command -v fail2ban-server &>/dev/null; then
            f2b_version=$(fail2ban-server --version 2>&1 | head -1 | awk '{print $2}' || echo "unknown")
        fi
        f2b_notes="Intrusion prevention framework"
    else
        f2b_notes="Service not found"
    fi

    NFTBAN_SERVICE_STATUS["fail2ban"]="${f2b_status}|${f2b_version}|required|${f2b_notes}"

    # ==========================================================================
    # BINARY DEPENDENCIES
    # ==========================================================================

    # golang
    local go_status="NOT_FOUND"
    local go_version="n/a"
    local go_notes=""

    if command -v go &>/dev/null; then
        go_status="INSTALLED"
        go_version=$(go version 2>&1 | awk '{print $3}' | sed 's/go//' || echo "unknown")
        go_notes="GeoIP and advanced features"
    else
        go_notes="Not installed (GeoIP features disabled)"
    fi

    NFTBAN_SERVICE_STATUS["golang"]="${go_status}|${go_version}|optional|${go_notes}"

    # mailx/mail
    local mail_status="NOT_FOUND"
    local mail_version="n/a"
    local mail_notes=""

    if command -v mailx &>/dev/null; then
        mail_status="INSTALLED"
        mail_version=$(mailx -V 2>&1 | head -1 | awk '{print $2}' || echo "unknown")
        mail_notes="Email notifications"
    elif command -v mail &>/dev/null; then
        mail_status="INSTALLED"
        mail_version=$(mail -V 2>&1 | head -1 | awk '{print $2}' || echo "unknown")
        mail_notes="Email notifications (mail)"
    else
        mail_notes="Not installed (email features disabled)"
    fi

    NFTBAN_SERVICE_STATUS["mailx"]="${mail_status}|${mail_version}|optional|${mail_notes}"

    # curl
    local curl_status="NOT_FOUND"
    local curl_version="n/a"
    local curl_notes=""

    if command -v curl &>/dev/null; then
        curl_status="INSTALLED"
        curl_version=$(curl --version 2>&1 | head -1 | awk '{print $2}' || echo "unknown")
        curl_notes="Feed downloads and API calls"
    else
        curl_notes="Not installed (feed features disabled)"
    fi

    NFTBAN_SERVICE_STATUS["curl"]="${curl_status}|${curl_version}|required|${curl_notes}"

    # jq
    local jq_status="NOT_FOUND"
    local jq_version="n/a"
    local jq_notes=""

    if command -v jq &>/dev/null; then
        jq_status="INSTALLED"
        jq_version=$(jq --version 2>&1 | sed 's/jq-//' || echo "unknown")
        jq_notes="JSON processing"
    else
        jq_notes="Not installed (some features limited)"
    fi

    NFTBAN_SERVICE_STATUS["jq"]="${jq_status}|${jq_version}|optional|${jq_notes}"
}

# =============================================================================
# OUTPUT FORMATTERS
# =============================================================================

#
# nftban_services_report_table - Terminal table output
#
nftban_services_report_table() {
    local timestamp="$1"

    echo "════════════════════════════════════════════════════════════════════════════════════"
    echo " Services Status Report — ${timestamp} "
    echo "════════════════════════════════════════════════════════════════════════════════════"

    # Header
    printf "%-20s %-15s %-12s %-10s %s\n" \
        "SERVICE" "STATUS" "VERSION" "REQUIRED" "NOTES"
    echo "------------------------------------------------------------------------------------"

    # Count statistics
    local running_services=0
    local stopped_services=0
    local missing_services=0
    local installed_bins=0
    local missing_bins=0

    # Sort services: systemd first, then binaries
    local sorted_keys=()

    # Add systemd services first
    for key in "${!NFTBAN_SERVICE_STATUS[@]}"; do
        if [[ "$key" == "nftables" || "$key" == "fail2ban" ]]; then
            sorted_keys+=("$key")
        fi
    done

    # Add binaries
    for key in "${!NFTBAN_SERVICE_STATUS[@]}"; do
        if [[ "$key" != "nftables" && "$key" != "fail2ban" ]]; then
            sorted_keys+=("$key")
        fi
    done

    # Print each service
    for service_name in "${sorted_keys[@]}"; do
        local info="${NFTBAN_SERVICE_STATUS[$service_name]}"
        IFS='|' read -r status version required notes <<< "$info"

        # Determine symbol and color
        local symbol=""
        local color=""

        case "$status" in
            RUNNING)
                symbol="$NFTBAN_SERVICE_SYM_OK"
                color="$C_GREEN"
                running_services=$((running_services + 1))
                ;;
            ENABLED)
                symbol="$NFTBAN_SERVICE_SYM_WARN"
                color="$C_YELLOW"
                stopped_services=$((stopped_services + 1))
                ;;
            STOPPED)
                symbol="$NFTBAN_SERVICE_SYM_KO"
                color="$C_RED"
                stopped_services=$((stopped_services + 1))
                ;;
            INSTALLED)
                symbol="$NFTBAN_SERVICE_SYM_OK"
                color="$C_GREEN"
                installed_bins=$((installed_bins + 1))
                ;;
            NOT_FOUND)
                symbol="$NFTBAN_SERVICE_SYM_KO"
                color="$C_RED"
                if [[ "$service_name" == "nftables" || "$service_name" == "fail2ban" ]]; then
                    missing_services=$((missing_services + 1))
                else
                    missing_bins=$((missing_bins + 1))
                fi
                ;;
            *)
                symbol="?"
                color="$C_RESET"
                ;;
        esac

        # Print row with color
        printf "${color}%-20s${C_RESET} %s %-13s %-12s %-10s %s\n" \
            "$service_name" \
            "$symbol" \
            "$status" \
            "$version" \
            "$required" \
            "$notes"
    done

    echo ""

    # Summary
    local total_services=$((running_services + stopped_services + missing_services))
    local total_bins=$((installed_bins + missing_bins))

    echo "Systemd Services: ${total_services} total | ${running_services} running | ${stopped_services} stopped | ${missing_services} missing"
    echo "Binary Tools: ${total_bins} total | ${installed_bins} installed | ${missing_bins} missing"
    echo ""

    # Status message
    if [[ $missing_services -gt 0 ]] || [[ $stopped_services -gt 0 ]]; then
        echo "⚠ Some required services are not running. Run 'nftban services fix' to auto-start."
    elif [[ $missing_bins -gt 0 ]]; then
        echo "⚠ Some optional tools are missing. Some features may be disabled."
    else
        echo "✅ All services operational!"
    fi
    echo ""
}

#
# nftban_services_report_compact - Compact one-line status
#
nftban_services_report_compact() {
    local running=0
    local total=0

    for service_name in "${!NFTBAN_SERVICE_STATUS[@]}"; do
        if [[ "$service_name" == "nftables" || "$service_name" == "fail2ban" ]]; then
            total=$((total + 1))
            local info="${NFTBAN_SERVICE_STATUS[$service_name]}"
            local status="${info%%|*}"
            [[ "$status" == "RUNNING" ]] && running=$((running + 1))
        fi
    done

    echo "Services: ${running}/${total} running"
}

# =============================================================================
# MAIN REPORT FUNCTION
# =============================================================================

#
# nftban_report_services - Main entry point
#
# Arguments:
#   $1 - Output format (table|compact|json|html)
#
nftban_report_services() {
    local output_format="${1:-table}"

    # Scan all services
    nftban_services_scan

    # Generate report based on format
    case "$output_format" in
        table|terminal|detailed)
            nftban_services_report_table "$NFTBAN_SERVICE_TIMESTAMP"
            ;;
        compact|summary)
            nftban_services_report_summary
            ;;
        json)
            nftban_services_report_json
            ;;
        *)
            nftban_services_report_table "$NFTBAN_SERVICE_TIMESTAMP"
            ;;
    esac
}

nftban_services_report_summary() {
    # Generate one-line summary of services status
    # Output: "Services: 2/2 running, 4/4 tools"
    # Returns: 0=OK, 1=Warning, 2=Error

    # Services already scanned by caller

    local total_systemd=0
    local running_systemd=0
    local total_binaries=0
    local installed_binaries=0
    local errors=0

    # Count systemd services
    for svc in "${NFTBAN_SERVICE_SYSTEMD[@]}"; do
        total_systemd=$((total_systemd + 1))
        local status_line="${NFTBAN_SERVICE_STATUS[$svc]:-}"
        local status="${status_line%%|*}"
        if [[ "$status" == "RUNNING" ]]; then
            running_systemd=$((running_systemd + 1))
        elif [[ "$status" =~ ERROR|MISSING ]]; then
            errors=$((errors + 1))
        fi
    done

    # Count binary tools
    for bin in "${NFTBAN_SERVICE_BINARIES[@]}"; do
        total_binaries=$((total_binaries + 1))
        local status_line="${NFTBAN_SERVICE_STATUS[$bin]:-}"
        local status="${status_line%%|*}"
        if [[ "$status" == "INSTALLED" ]]; then
            installed_binaries=$((installed_binaries + 1))
        fi
    done

    # Output summary
    if [[ $errors -eq 0 && $running_systemd -eq $total_systemd ]]; then
        echo "Services: $running_systemd/$total_systemd running, $installed_binaries/$total_binaries tools"
        return 0
    elif [[ $errors -eq 0 ]]; then
        echo "Services: $running_systemd/$total_systemd running ($(($total_systemd - $running_systemd)) stopped), $installed_binaries/$total_binaries tools"
        return 1  # Warning - services stopped
    else
        echo "Services: $errors errors, $running_systemd/$total_systemd running, $installed_binaries/$total_binaries tools"
        return 2  # Error - missing/broken services
    fi
}

nftban_services_report_json() {
    # Generate JSON output of services status
    # Output: JSON object with services data

    # Services already scanned by caller

    echo "{"
    echo "  \"timestamp\": \"$NFTBAN_SERVICE_TIMESTAMP\","
    echo "  \"systemd\": {"
    echo "    \"services\": ["

    # Output systemd services
    local first=true
    for svc in "${NFTBAN_SERVICE_SYSTEMD[@]}"; do
        local status_line="${NFTBAN_SERVICE_STATUS[$svc]:-}"
        IFS='|' read -r status version required notes <<< "$status_line"

        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo ","
        fi

        echo "      {"
        echo "        \"name\": \"$svc\","
        echo "        \"status\": \"$status\","
        echo "        \"version\": \"$version\","
        echo "        \"required\": \"$required\","
        echo "        \"notes\": \"$notes\""
        echo -n "      }"
    done

    echo ""
    echo "    ]"
    echo "  },"
    echo "  \"binaries\": {"
    echo "    \"tools\": ["

    # Output binary tools
    first=true
    for bin in "${NFTBAN_SERVICE_BINARIES[@]}"; do
        local status_line="${NFTBAN_SERVICE_STATUS[$bin]:-}"
        IFS='|' read -r status version required notes <<< "$status_line"

        if [[ "$first" == "true" ]]; then
            first=false
        else
            echo ","
        fi

        echo "      {"
        echo "        \"name\": \"$bin\","
        echo "        \"status\": \"$status\","
        echo "        \"version\": \"$version\","
        echo "        \"required\": \"$required\","
        echo "        \"notes\": \"$notes\""
        echo -n "      }"
    done

    echo ""
    echo "    ]"
    echo "  }"
    echo "}"

    return 0
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

# Make functions available to sourcing scripts
export -f nftban_services_scan
export -f nftban_services_report_table
export -f nftban_services_report_compact
export -f nftban_services_report_summary
export -f nftban_services_report_json
export -f nftban_report_services
