#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Services Report Core Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_report_services"
# meta:type="core"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Scans and reports status of all required system services"
# meta:inventory.files=""
# meta:inventory.binaries="systemctl"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Load main configuration (service names, paths)
if [[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" ]]; then
    source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" || true
fi
source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf.local" 2>/dev/null || true

# =============================================================================
# GLOBALS
# =============================================================================

declare -g -A NFTBAN_SERVICE_STATUS=()  # key: service_name -> "status|version|required|notes"
declare -g NFTBAN_SERVICE_TIMESTAMP
NFTBAN_SERVICE_TIMESTAMP="$(date --iso-8601=seconds)"
declare -g NFTBAN_SERVICE_OUTPUT_FORMAT="${NFTBAN_SERVICE_OUTPUT_FORMAT:-table}"

# Color symbols
# shellcheck disable=SC2034  # Symbols for UI rendering
NFTBAN_SERVICE_SYM_OK="✔"
# shellcheck disable=SC2034  # Symbols for UI rendering
NFTBAN_SERVICE_SYM_KO="✖"
# shellcheck disable=SC2034  # Symbols for UI rendering
NFTBAN_SERVICE_SYM_WARN="⚠"
C_RESET="\e[0m"
C_RED="\e[31m"
C_GREEN="\e[32m"
C_YELLOW="\e[33m"
# shellcheck disable=SC2034  # Color constants for future use
C_CYAN="\e[36m"
# shellcheck disable=SC2034  # Color constants for future use
C_BOLD="\e[1m"

# =============================================================================
# SERVICE SCANNING
# =============================================================================

#
# nftban_services_scan - Scan all required services
#
# Checks:
#   - nftables (systemd service)
#   - suricata (systemd service - IDS)
#   - nftban-suricata (systemd service - integration daemon)
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

    # suricata (IDS - replaces fail2ban in v1.0)
    local suricata_status="NOT_FOUND"
    local suricata_version="n/a"
    local suricata_notes=""

    if command -v systemctl &>/dev/null && systemctl list-unit-files suricata.service &>/dev/null 2>&1; then
        if systemctl is-active suricata.service &>/dev/null 2>&1; then
            suricata_status="RUNNING"
        elif systemctl is-enabled suricata.service &>/dev/null 2>&1; then
            suricata_status="ENABLED"
        else
            suricata_status="STOPPED"
        fi

        if command -v suricata &>/dev/null; then
            suricata_version=$(suricata --build-info 2>&1 | grep -oP 'This is Suricata version \K[0-9.]+' | head -1 || echo "unknown")
        fi
        suricata_notes="Suricata IDS (Network threat detection)"
    else
        suricata_notes="Service not found"
    fi

    NFTBAN_SERVICE_STATUS["suricata"]="${suricata_status}|${suricata_version}|required|${suricata_notes}"

    # nftban-suricata (NFTBan Suricata integration daemon)
    local nft_suricata_status="NOT_FOUND"
    local nft_suricata_version="n/a"
    local nft_suricata_notes=""

    local nftban_suricata_svc="${NFTBAN_SERVICE_SURICATA:-nftban-suricata.service}"
    if command -v systemctl &>/dev/null && systemctl list-unit-files "$nftban_suricata_svc" &>/dev/null 2>&1; then
        if systemctl is-active "$nftban_suricata_svc" &>/dev/null 2>&1; then
            nft_suricata_status="RUNNING"
        elif systemctl is-enabled "$nftban_suricata_svc" &>/dev/null 2>&1; then
            nft_suricata_status="ENABLED"
        else
            nft_suricata_status="STOPPED"
        fi
        nft_suricata_notes="NFTBan Suricata integration daemon"
    else
        nft_suricata_notes="Service not found"
    fi

    NFTBAN_SERVICE_STATUS["nftban-suricata"]="${nft_suricata_status}|${nft_suricata_version}|required|${nft_suricata_notes}"

    # ==========================================================================
    # BINARY DEPENDENCIES
    # ==========================================================================

    # GeoIP Database (required for country blocking and IP geolocation)
    local geoip_status="NOT_FOUND"
    local geoip_version="n/a"
    local geoip_notes=""
    local geoip_db=""
    local geoip_dir="${NFTBAN_DATA_DIR:-/var/lib/nftban}/geoip"

    # Check explicit config first, then auto-detect from supported databases
    if [[ -n "${NFTBAN_GEOIP_DATABASE:-}" ]] && [[ -f "${NFTBAN_GEOIP_DATABASE}" ]]; then
        geoip_db="${NFTBAN_GEOIP_DATABASE}"
    else
        # IFS-safe split: strict.sh sets IFS=$'\n\t', so space-separated vars need explicit splitting
        local _geoip_dbs
        IFS=' ' read -ra _geoip_dbs <<< "${NFTBAN_GEOIP_DATABASES:-dbip-country-lite.mmdb GeoLite2-City.mmdb GeoLite2-Country.mmdb}"
        for db_file in "${_geoip_dbs[@]}"; do
            [[ -f "${geoip_dir}/${db_file}" ]] && geoip_db="${geoip_dir}/${db_file}" && break
        done
    fi

    # Check if GeoIP database exists
    if [[ -n "$geoip_db" ]] && [[ -f "$geoip_db" ]]; then
        geoip_status="INSTALLED"
        # Get database modification date as version
        geoip_version=$(stat -c '%Y' "$geoip_db" 2>/dev/null | xargs -I{} date -d @{} '+%Y-%m-%d' 2>/dev/null || echo "unknown")
        local db_size db_name
        db_size=$(du -h "$geoip_db" 2>/dev/null | awk '{print $1}')
        db_name=$(basename "$geoip_db")
        geoip_notes="${db_name} database ($db_size)"
    else
        # Check for alternative database locations
        local alt_db=""
        for db_path in /usr/share/GeoIP/*.mmdb /var/lib/GeoIP/*.mmdb; do
            [[ -f "$db_path" ]] && alt_db="$db_path" && break
        done
        if [[ -n "$alt_db" ]]; then
            geoip_status="INSTALLED"
            geoip_notes="Found at $alt_db"
        else
            geoip_notes="Database not found - run: nftban geoip download"
        fi
    fi

    NFTBAN_SERVICE_STATUS["geoip-database"]="${geoip_status}|${geoip_version}|required|${geoip_notes}"

    # Email capability detection (check all supported mail methods)
    # Priority: postfix → sendmail → exim → msmtp → mailx/mail
    local mail_status="NOT_FOUND"
    local mail_version="n/a"
    local mail_notes=""
    local mail_label="email"

    if command -v postfix &>/dev/null || systemctl is-active postfix &>/dev/null 2>&1; then
        mail_status="INSTALLED"
        mail_version=$(postconf mail_version 2>/dev/null | awk -F= '{print $2}' | tr -d ' ' || echo "unknown")
        mail_notes="Postfix MTA"
        mail_label="email (postfix)"
    elif command -v exim &>/dev/null || command -v exim4 &>/dev/null || systemctl is-active exim &>/dev/null 2>&1; then
        mail_status="INSTALLED"
        mail_version=$(exim -bV 2>/dev/null | head -1 | awk '{print $3}' || exim4 -bV 2>/dev/null | head -1 | awk '{print $3}' || echo "unknown")
        mail_notes="Exim MTA"
        mail_label="email (exim)"
    elif [[ -x /usr/sbin/sendmail ]] && ! command -v postfix &>/dev/null; then
        mail_status="INSTALLED"
        mail_version=$(/usr/sbin/sendmail -d0.1 < /dev/null 2>&1 | head -1 | awk '{print $2}' || echo "unknown")
        mail_notes="Sendmail MTA"
        mail_label="email (sendmail)"
    elif command -v msmtp &>/dev/null; then
        mail_status="INSTALLED"
        mail_version=$(msmtp --version 2>&1 | head -1 | awk '{print $3}' || echo "unknown")
        mail_notes="msmtp relay"
        mail_label="email (msmtp)"
    elif command -v mailx &>/dev/null; then
        mail_status="INSTALLED"
        mail_version=$(mailx -V 2>&1 | head -1 | awk '{print $2}' || echo "unknown")
        mail_notes="mailx CLI"
        mail_label="email (mailx)"
    elif command -v mail &>/dev/null; then
        mail_status="INSTALLED"
        mail_version=$(mail -V 2>&1 | head -1 | awk '{print $2}' || echo "unknown")
        mail_notes="mail CLI"
        mail_label="email (mail)"
    else
        mail_notes="No MTA found (email alerts disabled)"
        mail_label="email"
    fi

    NFTBAN_SERVICE_STATUS["${mail_label}"]="${mail_status}|${mail_version}|optional|${mail_notes}"

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
    # shellcheck disable=SC2034  # Reserved for timestamp formatting
    local timestamp="$1"
    local short_ts
    short_ts=$(date +"%Y-%m-%d %H:%M")

    echo ""
    echo "╔════════════════════════════════════════════════════════╗"
    printf "║  NFTBan Services                %-12s    ║\n" "$short_ts"
    echo "╚════════════════════════════════════════════════════════╝"
    echo ""

    # Header
    printf "%-20s %-15s %-12s\n" \
        "SERVICE" "STATUS" "VERSION"
    echo "────────────────────────────────────────────────────────"

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
        if [[ "$key" == "nftables" || "$key" == "suricata" ]]; then
            sorted_keys+=("$key")
        fi
    done

    # Add binaries
    for key in "${!NFTBAN_SERVICE_STATUS[@]}"; do
        if [[ "$key" != "nftables" && "$key" != "suricata" && "$key" != "nftban-suricata" ]]; then
            sorted_keys+=("$key")
        fi
    done

    # Print each service
    for service_name in "${sorted_keys[@]}"; do
        local info="${NFTBAN_SERVICE_STATUS[$service_name]}"
        IFS='|' read -r status version required notes <<< "$info"

        # Determine status display with icon
        # shellcheck disable=SC2034  # Reserved for formatted status
        local status_display=""

        case "$status" in
            RUNNING)
                printf "%-20s ${C_GREEN}%-15s${C_RESET} %-12s\n" "$service_name" "✓ Running" "$version"
                running_services=$((running_services + 1))
                ;;
            ENABLED)
                printf "%-20s ${C_YELLOW}%-15s${C_RESET} %-12s\n" "$service_name" "⚠ Enabled" "$version"
                stopped_services=$((stopped_services + 1))
                ;;
            STOPPED)
                printf "%-20s ${C_RED}%-15s${C_RESET} %-12s\n" "$service_name" "− Stopped" "$version"
                stopped_services=$((stopped_services + 1))
                ;;
            INSTALLED)
                printf "%-20s ${C_GREEN}%-15s${C_RESET} %-12s\n" "$service_name" "✓ Installed" "$version"
                installed_bins=$((installed_bins + 1))
                ;;
            NOT_FOUND)
                printf "%-20s ${C_RED}%-15s${C_RESET} %-12s\n" "$service_name" "✖ Missing" "$version"
                if [[ "$service_name" == "nftables" || "$service_name" == "suricata" ]]; then
                    missing_services=$((missing_services + 1))
                else
                    missing_bins=$((missing_bins + 1))
                fi
                ;;
            *)
                printf "%-20s %-15s %-12s\n" "$service_name" "? Unknown" "$version"
                ;;
        esac
    done

    echo ""

    # Summary
    local total_services
    total_services=$((running_services + stopped_services + missing_services))
    local total_bins
    total_bins=$((installed_bins + missing_bins))

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
        if [[ "$service_name" == "nftables" || "$service_name" == "suricata" || "$service_name" == "nftban-suricata" ]]; then
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
