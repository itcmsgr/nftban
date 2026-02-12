#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Interactive TUI Menu Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Interactive TUI menu system for NFTBan
#
# meta:name="cmd_menu"
# meta:type="cli"
# meta:header="NFTBan Interactive Menu"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Interactive TUI menu using whiptail/dialog for easier navigation"
# meta:inventory.files=""
# meta:inventory.binaries="whiptail"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="nftban"
#
# meta:created_date="2025-11-05"
# meta:updated_date="2025-11-24"

set -Eeuo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

TITLE="NFTBAN — Interactive Menu"
BACKTITLE="NFTBan — Open-source Linux IPS and nftables firewall manager"

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

have_cmd() {
    # Check if command exists
    command -v "$1" >/dev/null 2>&1
}

# Detect UI backend
detect_ui() {
    if have_cmd whiptail; then
        echo "whiptail"
    elif have_cmd dialog; then
        echo "dialog"
    else
        echo "select"
    fi
}

UI="$(detect_ui)"

# =============================================================================
# UI WRAPPER FUNCTIONS
# =============================================================================

ui_menu() {
    # Display menu and return choice
    # Args: title backtitle item1 desc1 item2 desc2 ...
    local title="$1"; local back="$2"; shift 2
    case "$UI" in
        whiptail)
            whiptail --title "$title" --backtitle "$back" --menu "" 20 70 12 "$@" 3>&1 1>&2 2>&3
            ;;
        dialog)
            dialog --title "$title" --backtitle "$back" --menu "" 20 70 12 "$@" 3>&1 1>&2 2>&3
            ;;
        select)
            local -a items=("$@")
            echo "$title"
            local i=0; for ((i=0; i<${#items[@]}; i+=2)); do
                printf "%2d) %-18s %s\n" $((i/2+1)) "${items[i]}" "${items[i+1]}"
            done
            printf "Choose [1-%d] (or empty to quit): " $(( ${#items[@]}/2 ))
            read -r choice || exit 1
            [[ -z "$choice" ]] && return 1
            local index
            index=$(( (choice-1)*2 ))
            if (( index >= 0 && index < ${#items[@]} )); then
                echo "${items[index]}"
            else
                return 1
            fi
            ;;
    esac
}

ui_msg() {
    # Display message box
    # Args: title message
    local title="$1"; local msg="$2"
    case "$UI" in
        whiptail) whiptail --title "$title" --msgbox "$msg" 16 72 ;;
        dialog) dialog --title "$title" --msgbox "$msg" 16 72 ;;
        select) echo -e "\n[$title]\n$msg\n" ;;
    esac
}

ui_yesno() {
    # Display yes/no dialog
    # Args: title message
    local title="$1"; local msg="$2"
    case "$UI" in
        whiptail) whiptail --title "$title" --yesno "$msg" 10 68 ;;
        dialog) dialog --title "$title" --yesno "$msg" 10 68 ;;
        select)
            read -r -p "$msg [y/N]: " ans
            [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
            ;;
    esac
}

ui_input() {
    # Get text input from user
    # Args: title prompt [default_value]
    local title="$1"; local prompt="$2"; local default="${3:-}"
    case "$UI" in
        whiptail)
            whiptail --title "$title" --inputbox "$prompt" 10 60 "$default" 3>&1 1>&2 2>&3
            ;;
        dialog)
            dialog --title "$title" --inputbox "$prompt" 10 60 "$default" 3>&1 1>&2 2>&3
            ;;
        select)
            echo ""
            echo "[$title]"
            if [[ -n "$default" ]]; then
                read -r -p "$prompt [$default]: " ans
                echo "${ans:-$default}"
            else
                read -r -p "$prompt: " ans
                echo "$ans"
            fi
            ;;
    esac
}

require_root() {
    # Check root permissions and show error if not root
    if [[ $EUID -ne 0 ]]; then
        ui_msg "Permission required" "This action needs root. Re-run: sudo nftban menu"
        return 1
    fi
}

run_cmd() {
    # Execute command and display output
    # Args: title command args...
    local title="$1"; shift
    local cmd=( "$@" )

    if [[ "$UI" == "select" ]]; then
        echo -e "\n> ${cmd[*]}\n"
        "${cmd[@]}" || true
        read -r -p "Press Enter to continue..." _
    else
        local output
        output="$("${cmd[@]}" 2>&1 || true)"
        ui_msg "$title" "$output"
    fi
}

# =============================================================================
# MENU SCREENS
# =============================================================================

main_menu() {
    # Main menu entry point

    # Warn if using fallback select mode
    if [[ "$UI" == "select" ]]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "⚠️  WARNING: whiptail/dialog not found"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "Using basic text menu (no TUI interface)"
        echo ""
        echo "For better experience, install whiptail:"
        echo "  → dnf install newt        # RHEL/Rocky/Alma/Fedora"
        echo "  → apt install whiptail    # Debian/Ubuntu"
        echo ""
        read -r -p "Press Enter to continue with basic menu..." _
        echo ""
    fi

    while true; do
        local choice
        choice="$(ui_menu "$TITLE" "$BACKTITLE" \
            status "Global status overview" \
            firewall "Firewall & ban actions" \
            protect "Protection modules" \
            monitor "Monitoring & reporting" \
            tools "Utilities" \
            quit "Exit")" || exit 0

        case "$choice" in
            status) screen_status ;;
            firewall) screen_firewall ;;
            protect) screen_protect ;;
            monitor) screen_monitor ;;
            tools) screen_tools ;;
            quit|"") exit 0 ;;
        esac
    done
}

screen_status() {
    # Status overview screen
    local choice
    choice="$(ui_menu "Status" "$BACKTITLE" \
        global "Show global system status" \
        services "System services status" \
        fhs "Filesystem hierarchy checks" \
        health "Full diagnostics" \
        back "Back")" || return

    case "$choice" in
        global) run_cmd "Global Status" nftban status ;;
        services) run_cmd "Services" nftban services status ;;
        fhs) run_cmd "FHS" nftban fhs status ;;
        health) run_cmd "Health" nftban health check ;;
        back) ;;
    esac
}

screen_firewall() {
    # Firewall & Security screen
    local choice
    choice="$(ui_menu "Firewall & Security" "$BACKTITLE" \
        fw_status "Firewall status" \
        fw_init "Initialize firewall tables" \
        fw_reload "Reload firewall config" \
        search "Search IP (interactive)" \
        ban "Ban IP" \
        unban "Unban IP" \
        whitelist "Whitelist tools" \
        profile "Security profiles" \
        back "Back")" || return

    case "$choice" in
        fw_status) run_cmd "Firewall Status" nftban firewall status ;;
        fw_init) require_root && run_cmd "Firewall Init" nftban firewall init ;;
        fw_reload) require_root && run_cmd "Firewall Reload" nftban firewall reload ;;
        search)
            local ip
            ip="$(ui_input "IP Search" "Enter IP/CIDR to search:")" || return
            if [[ -n "${ip:-}" ]]; then
                run_cmd "Search $ip" nftban search "$ip"
            else
                ui_msg "Error" "No IP address entered"
            fi
            ;;
        ban)
            local ip
            ip="$(ui_input "Ban IP" "Enter IP to ban:")" || return
            if [[ -n "${ip:-}" ]]; then
                if require_root; then
                    run_cmd "Ban $ip" nftban ban "$ip"
                fi
            else
                ui_msg "Error" "No IP address entered"
            fi
            ;;
        unban)
            local ip
            ip="$(ui_input "Unban IP" "Enter IP to unban:")" || return
            if [[ -n "${ip:-}" ]]; then
                if require_root; then
                    run_cmd "Unban $ip" nftban unban "$ip"
                fi
            else
                ui_msg "Error" "No IP address entered"
            fi
            ;;
        whitelist) screen_whitelist ;;
        profile) screen_profile ;;
        back) ;;
    esac
}

screen_whitelist() {
    # Whitelist management screen
    local choice
    choice="$(ui_menu "Whitelist" "$BACKTITLE" \
        show "Show system whitelist" \
        sync "Sync system IPs to whitelist" \
        whitelistme "Whitelist my current IP" \
        back "Back")" || return

    case "$choice" in
        show) run_cmd "Whitelist Show" nftban whitelist show ;;
        sync) require_root && run_cmd "Whitelist Sync" nftban whitelist sync ;;
        whitelistme) require_root && run_cmd "Whitelist Me" nftban whitelist whitelistme ;;
        back) ;;
    esac
}

screen_profile() {
    # Security profile screen
    local choice
    choice="$(ui_menu "Profiles" "$BACKTITLE" \
        select "Interactive profile selection" \
        show "Show current profile" \
        list "List available profiles" \
        back "Back")" || return

    case "$choice" in
        select) require_root && run_cmd "Profile Select" nftban profile select ;;
        show) run_cmd "Profile Show" nftban profile show ;;
        list) run_cmd "Profile List" nftban profile list ;;
        back) ;;
    esac
}

screen_protect() {
    # Protection modules screen
    local choice
    choice="$(ui_menu "Protection Modules" "$BACKTITLE" \
        ddos "DDoS protection" \
        portscan "Port-scan detection" \
        login "Login monitoring" \
        fail2ban "Fail2ban integration" \
        cloudflare "Cloudflare integration" \
        feeds "Threat-intel feeds" \
        back "Back")" || return

    case "$choice" in
        ddos) screen_ddos ;;
        portscan) screen_portscan ;;
        login) screen_login ;;
        fail2ban) screen_fail2ban ;;
        cloudflare) screen_cloudflare ;;
        feeds) screen_feeds ;;
        back) ;;
    esac
}

screen_ddos() {
    # DDoS protection screen
    local choice
    choice="$(ui_menu "DDoS" "$BACKTITLE" \
        status "Status" \
        enable "Enable (all)" \
        disable "Disable (all)" \
        test "Test rules" \
        back "Back")" || return
    case "$choice" in
        status) run_cmd "DDoS Status" nftban ddos status ;;
        enable) require_root && run_cmd "DDoS Enable" nftban ddos enable all ;;
        disable) require_root && run_cmd "DDoS Disable" nftban ddos disable all ;;
        test) run_cmd "DDoS Test" nftban ddos test ;;
        back) ;;
    esac
}

screen_portscan() {
    # Port-scan detection screen
    local choice
    choice="$(ui_menu "Port-scan Detection" "$BACKTITLE" \
        status "Status" \
        enable "Enable" \
        disable "Disable" \
        check "Run check now" \
        history "Show last 24h" \
        test "Test rules" \
        back "Back")" || return
    case "$choice" in
        status) run_cmd "Portscan Status" nftban portscan status ;;
        enable) require_root && run_cmd "Portscan Enable" nftban portscan enable ;;
        disable) require_root && run_cmd "Portscan Disable" nftban portscan disable ;;
        check) require_root && run_cmd "Portscan Check" nftban portscan check ;;
        history) run_cmd "Portscan History" nftban portscan history ;;
        test) run_cmd "Portscan Test" nftban portscan test ;;
        back) ;;
    esac
}

screen_login() {
    # Login monitoring screen
    local choice
    choice="$(ui_menu "Login Monitoring" "$BACKTITLE" \
        status "Status" \
        enable "Enable service" \
        disable "Disable service" \
        logs "Recent logs" \
        test "Send test alert" \
        back "Back")" || return
    case "$choice" in
        status) run_cmd "Login Status" nftban login status ;;
        enable) require_root && run_cmd "Login Enable" nftban login enable ;;
        disable) require_root && run_cmd "Login Disable" nftban login disable ;;
        logs) run_cmd "Login Logs" nftban login logs 100 ;;
        test) run_cmd "Login Test" nftban login test ;;
        back) ;;
    esac
}

screen_fail2ban() {
    # Fail2ban integration screen
    local choice
    choice="$(ui_menu "Fail2ban" "$BACKTITLE" \
        status "Status summary" \
        jails "List enabled jails" \
        available "List available jails" \
        banned "List banned IPs" \
        health-fix "Health check & auto-fix" \
        back "Back")" || return
    case "$choice" in
        status) run_cmd "F2B Status" nftban fail2ban status ;;
        jails) run_cmd "F2B Jails" nftban fail2ban jails ;;
        available) run_cmd "F2B Available Jails" nftban fail2ban available ;;
        banned) run_cmd "F2B Banned" nftban fail2ban banned ;;
        health-fix) require_root && run_cmd "F2B Health Fix" nftban fail2ban health-fix ;;
        back) ;;
    esac
}

screen_cloudflare() {
    # Cloudflare integration screen (now via trust module)
    local choice
    choice="$(ui_menu "Cloudflare (Trust Module)" "$BACKTITLE" \
        status "Status" \
        enable "Enable" \
        disable "Disable" \
        update "Update IP ranges" \
        back "Back")" || return
    case "$choice" in
        status) run_cmd "Cloudflare Status" nftban trust status CLOUDFLARE ;;
        enable) require_root && run_cmd "Cloudflare Enable" nftban trust enable CLOUDFLARE ;;
        disable) require_root && run_cmd "Cloudflare Disable" nftban trust disable CLOUDFLARE ;;
        update) require_root && run_cmd "Cloudflare Update" nftban trust update CLOUDFLARE ;;
        back) ;;
    esac
}

screen_feeds() {
    # Threat feeds screen
    local choice
    choice="$(ui_menu "Threat Feeds" "$BACKTITLE" \
        status "Status" \
        select "Interactive selector" \
        list "List all feeds" \
        update "Update feeds" \
        back "Back")" || return
    case "$choice" in
        status) run_cmd "Feeds Status" nftban feeds status ;;
        select) require_root && run_cmd "Feeds Select" nftban feeds select ;;
        list) run_cmd "Feeds List" nftban feeds list ;;
        update) require_root && run_cmd "Feeds Update" nftban feeds update ;;
        back) ;;
    esac
}

screen_monitor() {
    # Monitoring & Reporting screen
    local choice
    choice="$(ui_menu "Monitoring & Reporting" "$BACKTITLE" \
        stats "Statistics" \
        report "Reports" \
        port "Port status" \
        module "Modules" \
        back "Back")" || return

    case "$choice" in
        stats) screen_stats ;;
        report) screen_report ;;
        port) screen_port ;;
        module) screen_module ;;
        back) ;;
    esac
}

screen_stats() {
    # Statistics screen
    local choice
    choice="$(ui_menu "Stats" "$BACKTITLE" \
        dashboard "Dashboard" \
        recent "Recent events (50)" \
        top "Top attackers" \
        monitor "Live monitor" \
        back "Back")" || return
    case "$choice" in
        dashboard) run_cmd "Stats Dashboard" nftban stats dashboard --last 24h ;;
        recent) run_cmd "Stats Recent" nftban stats recent 50 ;;
        top) run_cmd "Stats Top" nftban stats top ips 20 ;;
        monitor) run_cmd "Stats Monitor" nftban stats monitor --interval 2 ;;
        back) ;;
    esac
}

screen_report() {
    # Reports screen
    local choice
    choice="$(ui_menu "Reports" "$BACKTITLE" \
        generate "Generate HTML report" \
        email "Email report..." \
        schedule "Manage schedule" \
        list "List reports" \
        back "Back")" || return
    case "$choice" in
        generate) run_cmd "Generate Report" nftban report generate --format html ;;
        email)
            local rcpt
            rcpt="$(ui_input "Email Report" "Recipient email:")" || return
            [[ -z "${rcpt:-}" ]] || run_cmd "Email Report" nftban report email "$rcpt" --format html --attach-csv
            ;;
        schedule) screen_report_schedule ;;
        list) run_cmd "Report List" nftban report list ;;
        back) ;;
    esac
}

screen_report_schedule() {
    # Report schedule screen
    local choice
    choice="$(ui_menu "Report Schedule" "$BACKTITLE" \
        daily "Set daily at 09:00" \
        weekly "Set weekly Monday 09:00" \
        monthly "Set monthly day 1 at 09:00" \
        view "View current schedule" \
        remove "Remove schedule" \
        back "Back")" || return
    case "$choice" in
        daily) require_root && run_cmd "Schedule Daily" nftban report schedule daily --time 09:00 --email ;;
        weekly) require_root && run_cmd "Schedule Weekly" nftban report schedule weekly --day Mon --time 09:00 --email ;;
        monthly) require_root && run_cmd "Schedule Monthly" nftban report schedule monthly --day 1 --time 09:00 --email ;;
        view) run_cmd "Schedule" nftban report schedule list ;;
        remove) require_root && run_cmd "Remove Schedule" nftban report schedule remove ;;
        back) ;;
    esac
}

screen_port() {
    # Ports screen
    local choice
    choice="$(ui_menu "Ports" "$BACKTITLE" \
        status "Port status" \
        detailed "Detailed port status" \
        html "Generate HTML report" \
        back "Back")" || return
    case "$choice" in
        status) run_cmd "Ports Status" nftban port status ;;
        detailed) run_cmd "Ports Detailed" nftban port detailed ;;
        html) run_cmd "Ports HTML" nftban port html-report ;;
        back) ;;
    esac
}

screen_module() {
    # Modules screen
    local choice
    choice="$(ui_menu "Modules" "$BACKTITLE" \
        status "Module inventory" \
        summary "Summary" \
        json "JSON" \
        back "Back")" || return
    case "$choice" in
        status) run_cmd "Modules" nftban module status ;;
        summary) run_cmd "Modules Summary" nftban module summary ;;
        json) run_cmd "Modules JSON" nftban module json ;;
        back) ;;
    esac
}

screen_tools() {
    # Utilities screen
    local choice
    choice="$(ui_menu "Utilities" "$BACKTITLE" \
        geoip "GeoIP lookup" \
        services_fix "Fix services" \
        permissions "Enforce file permissions" \
        health_fix "Auto-heal system issues" \
        back "Back")" || return

    case "$choice" in
        geoip)
            local ip
            ip="$(ui_input "GeoIP Lookup" "Enter IP to lookup:")" || return
            [[ -z "${ip:-}" ]] || run_cmd "GeoIP $ip" nftban geoip lookup "$ip" compact
            ;;
        services_fix) require_root && run_cmd "Services Fix" nftban services fix ;;
        permissions) require_root && run_cmd "Permissions Enforce" nftban permissions enforce ;;
        health_fix) require_root && run_cmd "Health Auto-Heal" nftban health check --auto-heal ;;
        back) ;;
    esac
}

# =============================================================================
# COMMAND HANDLER
# =============================================================================

cmd_menu_help() {
    echo "Usage: nftban menu"
    echo ""
    echo "Launch interactive TUI menu for NFTBan management."
    echo ""
    echo "Requires: whiptail or dialog (fallback to text menu)"
}

nftban_cmd_menu() {
    # Main command entry point
    # Args: none

    # Show banner
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"
        if [[ $(type -t nftban_banner) == "function" ]]; then
            nftban_banner
        fi
    fi
    echo ""

    # Show welcome message
    if [[ "$UI" == "select" ]]; then
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "$TITLE"
        echo "$BACKTITLE"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
    fi

    # Launch menu
    main_menu
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_cmd_menu

# =============================================================================
# DIRECT EXECUTION SUPPORT
# =============================================================================

# If executed directly (not sourced), run the command handler
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_menu "$@"
fi
