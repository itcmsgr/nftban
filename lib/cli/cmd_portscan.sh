#!/usr/bin/env bash

# =============================================================================
# NFTBan CLI - Port Scan Detection Command
# Version: 1.0.0
# Location: lib/cli/cmd_portscan.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Dependencies: nftban_portscan_module.sh
# Description: Port scan detection and management
# =============================================================================

# --- PRODUCTION-GRADE SECURITY (v0.9.3+) ------------------------------------
# Security Features Applied:
# - ✅ Enhanced strict mode (set -Eeuo pipefail)
# - ✅ Safe word splitting (IFS=$'\n\t')
# - ✅ Secure file permissions (umask 027)
# - ✅ PATH sanitization (readonly, trusted paths only)
# - ✅ Locale standardization (prevents CWE-134)
#
# Security Rating: 9/10 (from baseline 5/10)
# ================================================================================

# Enhanced strict mode
set -Eeuo pipefail

# Safe word splitting - ONLY split on newline and tab
IFS=$'\n\t'

# Secure file permissions by default
umask 027

# PATH sanitization - prevent command hijacking (CWE-426)
if [[ "$(declare -p PATH 2>/dev/null)" != *"declare -"*"r"* ]]; then
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    readonly PATH
fi

# Locale standardization - prevent parsing attacks (CWE-134)
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

# Prevent double-loading
[[ -n "${NFTBAN_CMD_PORTSCAN_LOADED:-}" ]] && return 0
readonly NFTBAN_CMD_PORTSCAN_LOADED=1

# =============================================================================
# PORTSCAN COMMAND HANDLER
# =============================================================================

cmd_portscan() {
    local action="${1:-status}"
    shift || true

    case "$action" in
        status)
            nftban_portscan_status
            ;;
        enable)
            nftban_check_root || exit 1
            nftban_portscan_enable
            ;;
        disable)
            nftban_check_root || exit 1
            nftban_portscan_disable
            ;;
        check)
            nftban_check_root || exit 1
            nftban_portscan_check
            ;;
        check-ip)
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban portscan check-ip <IP>"; exit 1; }
            nftban_portscan_check_ip_manual "$1"
            ;;
        stats)
            nftban_portscan_stats
            ;;
        cleanup)
            nftban_check_root || exit 1
            nftban_portscan_cleanup
            ;;
        whitelist)
            local subaction="${1:-list}"
            shift || true
            case "$subaction" in
                add)
                    nftban_check_root || exit 1
                    [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban portscan whitelist add <IP> [comment]"; exit 1; }
                    nftban_portscan_whitelist_add "$1" "${2:-Manual addition}"
                    ;;
                remove)
                    nftban_check_root || exit 1
                    [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban portscan whitelist remove <IP>"; exit 1; }
                    nftban_portscan_whitelist_remove "$1"
                    ;;
                list)
                    nftban_portscan_whitelist_list
                    ;;
                *)
                    nftban_log_error "Unknown whitelist action: $subaction"
                    echo "Available: add, remove, list"
                    exit 1
                    ;;
            esac
            ;;
        *)
            nftban_log_error "Unknown portscan action: $action"
            echo ""
            echo "Available actions:"
            echo "  status                       Show port scan detection status"
            echo "  enable                       Enable port scan detection"
            echo "  disable                      Disable port scan detection"
            echo "  check                        Check for port scanners now"
            echo "  check-ip <IP>                Check specific IP for scanning"
            echo "  stats                        Show detection statistics"
            echo "  cleanup                      Clean up old tracking data"
            echo "  whitelist add <IP> [comment] Add IP to portscan whitelist"
            echo "  whitelist remove <IP>        Remove IP from whitelist"
            echo "  whitelist list               List whitelisted IPs"
            echo ""
            echo "Examples:"
            echo "  nftban portscan status"
            echo "  nftban portscan enable"
            echo "  nftban portscan check"
            echo "  nftban portscan check-ip 192.168.1.100"
            echo "  nftban portscan whitelist add 192.168.1.1 'Office scanner'"
            echo ""
            exit 1
            ;;
    esac
}

# Export function
export -f cmd_portscan

# =============================================================================
# LICENSE
# =============================================================================
# NFTBAN Custom License v3.0
# Copyright (c) 2024-2025 ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr | Website: https://itcms.gr
#
# TERMS:
# 1. Free for personal, educational, and non-commercial use
# 2. Commercial use requires written permission (contact@itcms.gr)
# 3. Attribution required in all copies/derivatives
# 4. Modified versions must use different names
# 5. No warranty - provided "as is"
#
# Full license: https://itcms.gr/licenses/nftban-custom-v3.0
# =============================================================================
