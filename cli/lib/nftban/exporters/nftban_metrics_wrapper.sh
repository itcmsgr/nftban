#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_metrics_wrapper"
# meta:type="exporter"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Auto-detect and use best available metrics exporter"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# =============================================================================
# CONFIGURATION
# =============================================================================

readonly NFTBAN_LIB_DIR="${NFTBAN_LIB_DIR:-/usr/lib/nftban}"
readonly GO_EXPORTER="${GO_EXPORTER:-nftban-core}"
readonly BASH_EXPORTER="${NFTBAN_LIB_DIR}/exporters/nftban_unified_exporter.sh"
readonly LOG_TAG="nftban-metrics-wrapper"

# =============================================================================
# FUNCTIONS
# =============================================================================

log() {
    local level="$1"
    shift
    if command -v logger &>/dev/null; then
        logger -t "$LOG_TAG" -p "daemon.${level}" "$*"
    fi
    echo "[$level] $*" >&2
}

# Check if Go binary is available and functional
check_go_exporter() {
    # Check if command exists
    if ! command -v "$GO_EXPORTER" &>/dev/null; then
        return 1
    fi

    # Check if metrics command exists
    if ! "$GO_EXPORTER" metrics --help &>/dev/null; then
        return 1
    fi

    return 0
}

# Run Go-based exporter
run_go_exporter() {
    log info "Using Go-based exporter (high performance)"

    # Run with environment variables from systemd
    exec "$GO_EXPORTER" metrics export \
        ${NFTBAN_METRICS_FILE:+--output "$NFTBAN_METRICS_FILE"} \
        ${NFTBAN_DATA_DIR:+--state-dir "$NFTBAN_DATA_DIR"} \
        ${NFTBAN_LOG_DIR:+--log-dir "$NFTBAN_LOG_DIR"}
}

# Run bash-based exporter (fallback)
run_bash_exporter() {
    log info "Using bash-based exporter (compatibility mode)"

    if [[ ! -x "$BASH_EXPORTER" ]]; then
        log error "Bash exporter not found or not executable: $BASH_EXPORTER"
        exit 1
    fi

    exec "$BASH_EXPORTER" "$@"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    # Try Go exporter first (best performance)
    if check_go_exporter; then
        run_go_exporter
        # exec replaces process, so we only get here on error
        log error "Go exporter failed, falling back to bash"
    else
        log info "Go exporter not available (install nftban-core for better performance)"
    fi

    # Fallback to bash exporter
    run_bash_exporter "$@"
}

main "$@"

# =============================================================================
# LICENSE
# =============================================================================
# Mozilla Public License 2.0 (MPL-2.0)
# Copyright © 2024–2026 NFTBAN Project / Antonios Voulvoulis
# Contact: contact@nftban.com | Website: https://nftban.com
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
