#!/usr/bin/env bash

# =============================================================================
# NFTBan CLI - DDoS Protection Command
# Version: 1.0.0
# Location: lib/cli/cmd_ddos.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Dependencies: nftban_ddos_module.sh
# Description: DDoS protection management (synflood, connlimit, portflood, icmp)
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
[[ -n "${NFTBAN_CMD_DDOS_LOADED:-}" ]] && return 0
readonly NFTBAN_CMD_DDOS_LOADED=1

# =============================================================================
# DDOS COMMAND HANDLER
# =============================================================================

cmd_ddos() {
    local action="${1:-status}"
    shift || true

    case "$action" in
        status)
            nftban_ddos_status
            ;;
        enable)
            nftban_check_root || exit 1
            nftban_ddos_enable_all
            ;;
        disable)
            nftban_check_root || exit 1
            nftban_ddos_disable_all
            ;;
        synflood)
            local subaction="${1:-status}"
            shift || true
            case "$subaction" in
                enable)
                    nftban_check_root || exit 1
                    nftban_ddos_synflood_enable
                    ;;
                disable)
                    nftban_check_root || exit 1
                    nftban_ddos_synflood_disable
                    ;;
                status)
                    nftban_ddos_synflood_status
                    ;;
                *)
                    nftban_log_error "Unknown synflood action: $subaction"
                    echo "Available: enable, disable, status"
                    exit 1
                    ;;
            esac
            ;;
        connlimit)
            local subaction="${1:-status}"
            shift || true
            case "$subaction" in
                enable)
                    nftban_check_root || exit 1
                    nftban_ddos_connlimit_enable
                    ;;
                disable)
                    nftban_check_root || exit 1
                    nftban_ddos_connlimit_disable
                    ;;
                status)
                    nftban_ddos_connlimit_status
                    ;;
                add)
                    nftban_check_root || exit 1
                    [[ $# -lt 2 ]] && { nftban_log_error "Usage: nftban ddos connlimit add <port> <limit>"; exit 1; }
                    nftban_ddos_connlimit_add_port "$1" "$2"
                    ;;
                *)
                    nftban_log_error "Unknown connlimit action: $subaction"
                    echo "Available: enable, disable, status, add"
                    exit 1
                    ;;
            esac
            ;;
        portflood)
            local subaction="${1:-status}"
            shift || true
            case "$subaction" in
                enable)
                    nftban_check_root || exit 1
                    nftban_ddos_portflood_enable
                    ;;
                disable)
                    nftban_check_root || exit 1
                    nftban_ddos_portflood_disable
                    ;;
                status)
                    nftban_ddos_portflood_status
                    ;;
                add)
                    nftban_check_root || exit 1
                    [[ $# -lt 2 ]] && { nftban_log_error "Usage: nftban ddos portflood add <port> <rate/time>"; exit 1; }
                    nftban_ddos_portflood_add_port "$1" "$2"
                    ;;
                *)
                    nftban_log_error "Unknown portflood action: $subaction"
                    echo "Available: enable, disable, status, add"
                    exit 1
                    ;;
            esac
            ;;
        icmp)
            local subaction="${1:-status}"
            shift || true
            case "$subaction" in
                enable)
                    nftban_check_root || exit 1
                    nftban_ddos_icmp_enable
                    ;;
                disable)
                    nftban_check_root || exit 1
                    nftban_ddos_icmp_disable
                    ;;
                status)
                    nftban_ddos_icmp_status
                    ;;
                *)
                    nftban_log_error "Unknown icmp action: $subaction"
                    echo "Available: enable, disable, status"
                    exit 1
                    ;;
            esac
            ;;
        *)
            nftban_log_error "Unknown ddos action: $action"
            echo ""
            echo "Available actions:"
            echo "  status                    Show DDoS protection status"
            echo "  enable                    Enable all DDoS protections"
            echo "  disable                   Disable all DDoS protections"
            echo "  synflood <action>         SYN flood protection (enable/disable/status)"
            echo "  connlimit <action>        Connection limit (enable/disable/status/add)"
            echo "  portflood <action>        Port flood protection (enable/disable/status/add)"
            echo "  icmp <action>             ICMP protection (enable/disable/status)"
            echo ""
            echo "Examples:"
            echo "  nftban ddos status"
            echo "  nftban ddos enable"
            echo "  nftban ddos synflood enable"
            echo "  nftban ddos connlimit add 22 5"
            echo "  nftban ddos portflood add 80 20/5"
            echo ""
            exit 1
            ;;
    esac
}

# Export function
export -f cmd_ddos

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
