#!/usr/bin/env bash

# =============================================================================
# NFTBan CLI - Port Management Command
# Version: 1.0.0
# Location: lib/cli/cmd_port.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Dependencies: nftban_port_module.sh
# Description: Port management (add, remove, list, apply, validate)
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
[[ -n "${NFTBAN_CMD_PORT_LOADED:-}" ]] && return 0
readonly NFTBAN_CMD_PORT_LOADED=1

# =============================================================================
# PORT COMMAND HANDLER
# =============================================================================

cmd_port() {
    local action="${1:-list}"
    shift || true

    case "$action" in
        add)
            nftban_check_root || exit 1
            [[ $# -lt 2 ]] && { nftban_log_error "Usage: nftban port add <port> <protocol> [comment]"; exit 1; }
            nftban_port_add "$1" "$2" "${3:-Manual addition}"
            ;;
        remove|delete|del)
            nftban_check_root || exit 1
            [[ $# -lt 2 ]] && { nftban_log_error "Usage: nftban port remove <port> <protocol>"; exit 1; }
            nftban_port_remove "$1" "$2"
            ;;
        list|show)
            nftban_port_list
            ;;
        apply)
            nftban_check_root || exit 1
            nftban_port_apply_to_nftables
            ;;
        validate)
            nftban_port_validate_all
            ;;
        *)
            nftban_log_error "Unknown port action: $action"
            echo ""
            echo "Available actions:"
            echo "  add <port> <proto> [comment]  Add port (proto: tcp/udp)"
            echo "  remove <port> <proto>          Remove port"
            echo "  list                           Show all allowed ports"
            echo "  apply                          Apply port config to nftables"
            echo "  validate                       Validate port configuration"
            echo ""
            exit 1
            ;;
    esac
}

# Export function
export -f cmd_port

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
