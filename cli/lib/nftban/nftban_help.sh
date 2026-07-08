#!/usr/bin/env bash
# =============================================================================
# NFTBan - Help System Wrapper
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Wrapper for generate-help.sh (single source of truth)
#
# This file delegates to scripts/generate-help.sh which reads from
# commands.registry.yml. ONE implementation, no duplication.
#
# meta:name="nftban_help"
# meta:type="module"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2025-11-05"
# meta:updated_date="2026-03-27"
#
# meta:description="Wrapper that calls generate-help.sh for CLI help"
# meta:input="None (called from main router)"
# meta:output="Formatted help text from generate-help.sh"
# meta:depends="bash,generate-help.sh"
#
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"

set -Eeuo pipefail

# =============================================================================
# HELP WRAPPER
# =============================================================================

nftban_print_help() {
    # v1.46.0: Tiered help — essential commands by default, --all for full listing
    local show_all=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all|-a) show_all=true; shift ;;
            *) shift ;;
        esac
    done

    # V127 UX-6 D-1: banner suppressed in help dispatch path. The no-args
    # dashboard (cli/sbin/nftban) still renders its own banner — this only
    # removes the duplicate banner that previously preceded `nftban help`
    # and `nftban help --all` text output (operator-facing pollution).
    # Reversible by restoring the nftban_banner call below.
    # (Scope: AUDIT_190_LIFECYCLE/V127_FULL_UX_CORRECTION_UMBRELLA_SCOPE.md UX-6 D-1)

    if [[ "$show_all" == "true" ]]; then
        # Full help — delegate to generate-help.sh
        local help_script=""
        if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/scripts/generate-help.sh" ]]; then
            help_script="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/scripts/generate-help.sh"
        elif [[ -f "${BASH_SOURCE[0]%/*}/../../../scripts/generate-help.sh" ]]; then
            help_script="$(cd "${BASH_SOURCE[0]%/*}/../../../scripts" && pwd)/generate-help.sh"
        elif [[ -f "/opt/nftban/scripts/generate-help.sh" ]]; then
            help_script="/opt/nftban/scripts/generate-help.sh"
        fi

        if [[ -n "$help_script" ]] && [[ -f "$help_script" ]]; then
            # V127 UX-4: de-surface Suricata from `nftban help --all` operator
            # output per Option A. The generate-help.sh + commands.registry.yml
            # truth source is NOT modified (kept reversible and out of scope);
            # only the operator-facing presentation here filters the single
            # row whose command name is exactly "suricata". Production
            # `nftban suricata <subcmd>` remains fully functional and the
            # registry entry is intact for auditor / panel profiles.
            # (Scope: AUDIT_190_LIFECYCLE/V127_FULL_UX_CORRECTION_UMBRELLA_SCOPE.md UX-4)
            bash "$help_script" --profile operator | grep -v -E '^[[:space:]]+suricata[[:space:]]'
        else
            _nftban_help_minimal
        fi
    else
        # Default: show essential commands only
        _nftban_help_essential
    fi
}

# =============================================================================
# ESSENTIAL HELP (v1.46.0 — default, concise)
# =============================================================================

_nftban_help_essential() {
    # v1.153 UX-A7: surface the same ⚡/⚠️ risk markers the `help --all` view
    # carries, so the short list flags state-changing verbs at a glance.
    #   ⚡ = state-changing (mutates kernel/config); ⚠️ = advanced / use with
    #   caution. Unmarked = read-only. Markers mirror the registry risk class
    #   (commands.registry.yml) and scripts/generate-help.sh RISK_ICONS, no
    #   behavior change.
    cat <<'EOF'
USAGE:
  nftban <command> [subcommand] [options]

ESSENTIAL COMMANDS:
     status        System status overview
     health        Diagnostics and auto-repair
  ⚡ ban           Ban an IP address
  ⚡ unban         Remove IP ban
     list          List banned/whitelisted IPs
     search        Search IP across all sets
  ⚡ blacklist     Blacklist management (add/remove/list/flush)
  ⚡ whitelist     Whitelist management (add/remove/list)
  ⚡ feeds         Threat intelligence feeds
  ⚠️ firewall      Firewall management (reload/rebuild/record)

PROTECTION MODULES:
  ⚡ ddos          DDoS protection (enable/disable/status)
  ⚡ portscan      Port scan detection (enable/disable/status)
  ⚡ login         Login monitor — SSH brute-force protection
  ⚡ botguard      HTTP Guard — live request-time HTTP bot guard (enable/disable/status/list)
  🔍 botscan       HTTP Exploit Scanner — periodic access-log exploit scanner (status/enable/disable)
                   NOTE: BotScan is independent of BotGuard — it can ban via the manual blacklist
                   even when BotGuard is disabled.
  ⚡ geoban        Geographic IP blocking (enable/disable/list)

SYSTEM:
  ⚡ config        Configuration management
     version       Version information
  ⚠️ update        Update NFTBan

LEGEND:
  ⚡ state-changing    ⚠️ advanced / use with caution    (unmarked = read-only)

EXIT CODES:
  0  Success    1  Error    2  Warning

Run 'nftban help --all' for all commands (60+)
Run 'nftban <command> help' for command-specific help
EOF
}

# =============================================================================
# MINIMAL FALLBACK (when generate-help.sh unavailable)
# =============================================================================

# v1.19.21 FIX: Document exit codes (E2)
_nftban_help_minimal() {
    cat <<'EOF'
USAGE:
  nftban <command> [subcommand] [options]

CORE COMMANDS:
  status      System status overview
  health      Diagnostics and auto-repair
  ban         Ban an IP address
  unban       Remove IP ban
  blacklist   Blacklist management (add/remove/list/files/flush)
  list        List banned/whitelisted IPs
  search      Search IP across all sets
  firewall    Firewall management
  feeds       Threat intelligence feeds
  help        Show full help

PROTECTION MODULES:
  ddos        DDoS protection management
  botguard    HTTP Guard — live request-time bot guard management
  botscan     HTTP Exploit Scanner — periodic access-log exploit scanner (independent of BotGuard)
  portscan    Port scan detection
  geoban      Geographic IP blocking
  geoip       GeoIP database management

EXIT CODES:
  0  Success   - Command completed without errors
  1  Error     - Command failed (check stderr for details)
  2  Warning   - Command completed with warnings (e.g., missing deps)

Run 'nftban <command> help' for command-specific help.

Documentation: https://github.com/itcmsgr/nftban/wiki
EOF
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_print_help
export -f _nftban_help_minimal
export -f _nftban_help_essential

# =============================================================================
# DIRECT EXECUTION
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    nftban_print_help "$@"
fi
