#!/usr/bin/env bash
# =============================================================================
# NFTBan - Centralized Logging Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2025 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="nftban_logging"
# meta:type="bash"
# meta:description="Centralized logging functions for all NFTBan modules"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_LOG_VERBOSE, NFTBAN_LOG_TIMESTAMP, DEBUG"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_NFTBAN_LOGGING_LOADED:-}" ]] && return 0
_NFTBAN_LOGGING_LOADED=1

# Colors (if not already defined)
: "${RED:=\033[0;31m}"
: "${GREEN:=\033[0;32m}"
: "${YELLOW:=\033[0;33m}"
: "${BLUE:=\033[0;34m}"
: "${NC:=\033[0m}"

# Logging configuration
: "${NFTBAN_LOG_VERBOSE:=false}"
: "${NFTBAN_LOG_TIMESTAMP:=false}"

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

# log_info - Info level logging (only shows when verbose)
# Usage: log_info "message"
log_info() {
    if [[ "$NFTBAN_LOG_VERBOSE" == "true" ]] || [[ "${VERBOSE:-}" == "true" ]]; then
        if [[ "$NFTBAN_LOG_TIMESTAMP" == "true" ]]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*"
        else
            echo -e "${BLUE}[INFO]${NC} $*"
        fi
    fi
}

# log_warn - Warning level logging (always shows)
# Usage: log_warn "message"
log_warn() {
    if [[ "$NFTBAN_LOG_TIMESTAMP" == "true" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $*" >&2
    else
        echo -e "${YELLOW}[WARN]${NC} $*" >&2
    fi
}

# log_error - Error level logging (always shows, to stderr)
# Usage: log_error "message"
log_error() {
    if [[ "$NFTBAN_LOG_TIMESTAMP" == "true" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2
    else
        echo -e "${RED}[ERROR]${NC} $*" >&2
    fi
}

# log_debug - Debug level logging (only when DEBUG=true)
# Usage: log_debug "message"
log_debug() {
    if [[ "${DEBUG:-}" == "true" ]]; then
        if [[ "$NFTBAN_LOG_TIMESTAMP" == "true" ]]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $*" >&2
        else
            echo -e "${BLUE}[DEBUG]${NC} $*" >&2
        fi
    fi
}

# log_success - Success level logging (always shows)
# Usage: log_success "message"
log_success() {
    if [[ "$NFTBAN_LOG_TIMESTAMP" == "true" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [OK] $*"
    else
        echo -e "${GREEN}[OK]${NC} $*"
    fi
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

export -f log_info 2>/dev/null || true
export -f log_warn 2>/dev/null || true
export -f log_error 2>/dev/null || true
export -f log_debug 2>/dev/null || true
export -f log_success 2>/dev/null || true
