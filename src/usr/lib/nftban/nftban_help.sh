#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.10.0 - Grouped Help System
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Grouped help output for NFTBan CLI
#
# meta:name=nftban_help
# meta:type=core
# meta:header=NFTBan Help System
# meta:version=0.10.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Provides grouped, categorized help output for main CLI
# meta:input=None (called from main router)
# meta:output=Formatted help text with categories (CORE, FIREWALL, PROTECTION, MONITORING)
#
# **Inventory & Requirements**
# meta:depends=bash,tput
#
# meta:created_date=2025-11-01

set -Eeuo pipefail

# =============================================================================
# GROUPED HELP RENDERER
# =============================================================================

nftban_print_help() {
  # Renders grouped help menu with 4 categories
  # Categories: CORE, FIREWALL & SECURITY, PROTECTION MODULES, MONITORING & REPORTING
  # Uses tput for bold formatting if available (graceful fallback)

  local have_tput=0; command -v tput >/dev/null 2>&1 && have_tput=1
  local bold='' reset='' dim=''
  if [[ $have_tput -eq 1 ]] && [[ -t 1 ]]; then
    bold="$(tput bold)"; reset="$(tput sgr0)"; dim="$(tput dim)"
  fi

  echo "nftban — Adaptive firewall & ban management"
  echo
  echo "USAGE:"
  echo "  nftban <command> [subcommand] [options]"
  echo

  printf "%sCORE:%s\n" "$bold" "$reset"
  cat <<'EOF'
  status           Show global system status
  check            Quick environment check
  health           Full diagnostics (add --auto-heal to fix common issues)
  version          Show version
  help             Show this help
EOF
  echo

  printf "%sFIREWALL & SECURITY:%s\n" "$bold" "$reset"
  cat <<'EOF'
  firewall         Manage nftables (init, reload, status, reset)
  ban              Ban an IP address
  unban            Unban an IP address
  search           Search IP across sets, feeds, and jails (interactive)
  whitelist        Manage system and custom whitelists
  profile          Apply security profile (web-server, mail-server, ...)
  permissions      Audit & enforce secure file permissions
EOF
  echo

  printf "%sPROTECTION MODULES:%s\n" "$bold" "$reset"
  cat <<'EOF'
  ddos             DDoS protections (enable, disable, status, test)
  portscan         Port-scan detection (enable, disable, status, check, history, test)
  login            SSH login monitoring & alerts
  fail2ban         Manage Fail2ban integration and jails
  feeds            Threat-intel feeds (select/list/enable/disable/update/status)
  cloudflare       Cloudflare IP ranges integration
EOF
  echo

  printf "%sMONITORING & REPORTING:%s\n" "$bold" "$reset"
  cat <<'EOF'
  stats            Statistics dashboard (top, ip, recent, monitor, export, ...)
  report           Generate/schedule/email reports
  port             Port status and reporting
  module           Module inventory
  services         System services status
  fhs              Filesystem hierarchy checks
  nftables         nftables service management
EOF
  echo

  printf "%sTIPS:%s\n" "$bold" "$reset"
  cat <<'EOF'
  • Try: nftban status
  • Use TAB to auto-complete commands, subcommands, and options.
  • Add --json to supported commands for machine-readable output.
EOF
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_print_help

# =============================================================================
# DIRECT EXECUTION SUPPORT
# =============================================================================

# If executed standalone (for testing)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  nftban_print_help
fi
