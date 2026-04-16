#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.95.0 - Smoke Command (Registry-Driven, Non-Destructive)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Pass-through to Go registry-driven smoke framework
#
# meta:name="cmd_smoke"
# meta:type="cli"
# meta:header="Smoke Test Command"
# meta:version="1.95.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Registry-driven non-destructive smoke tests for system integrity verification"
# meta:depends="bash,nftban-core"
#
# meta:inventory.files=""
# meta:inventory.binaries="nftban-core"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2025-12-04"
# meta:updated_date="2026-04-17"
#
# v1.95: Rewritten. Old destructive/lifecycle smoke moved to `nftban selftest`.
# `nftban smoke` is now exclusively the Go registry-driven non-destructive
# smoke framework. Safe for CI, fleet checks, and routine diagnostics.
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
    # v1.95 compatibility shim: old destructive subcommands moved to selftest
    case "${1:-}" in
        run|test|quick|all|detailed|lifecycle|verify|config|configs|check|orphans|stats|trace)
            echo "NOTE: 'nftban smoke $1' was moved to 'nftban selftest' in v1.95." >&2
            echo "" >&2
            echo "  nftban smoke    = non-destructive system verification (CI-safe)" >&2
            echo "  nftban selftest = extended validation with controlled state changes" >&2
            echo "" >&2
            echo "Run instead:  nftban selftest $*" >&2
            return 1
            ;;
    esac

    local core_bin="${NFTBAN_CORE_BIN:-${NFTBAN_LIB_DIR}/bin/nftban-core}"

    if [[ ! -x "$core_bin" ]]; then
        echo "ERROR: nftban-core binary not found at $core_bin" >&2
        echo "Install or rebuild to use smoke tests." >&2
        return 1
    fi

    # Pass all arguments through to Go smoke runner
    "$core_bin" smoke "$@"
    return $?
}

# =============================================================================
# EXPORTS
# =============================================================================
export -f nftban_cmd_smoke

# =============================================================================
# LICENSE
# =============================================================================
# Mozilla Public License 2.0 (MPL-2.0)
# Copyright (c) 2024-2026 NFTBAN Project / Antonios Voulvoulis
# Contact: contact@nftban.com | Website: https://nftban.com
# =============================================================================
