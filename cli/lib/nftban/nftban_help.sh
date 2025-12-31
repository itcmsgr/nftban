#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Grouped Help System
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Grouped help output for NFTBan CLI
#
# meta:name=nftban_help
# meta:type=core
# meta:header=NFTBan Help System
# meta:version=1.0.0
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
# meta:created_date=2025-11-05

set -Eeuo pipefail

# =============================================================================
# GROUPED HELP RENDERER
# =============================================================================

nftban_print_help() {
  # Renders grouped help menu with 5 categories
  # Categories: CORE, FIREWALL & SECURITY, PROTECTION MODULES, MONITORING & REPORTING, DEBUG & TESTING
  # Uses tput for bold formatting if available (graceful fallback)

  local have_tput=0; command -v tput >/dev/null 2>&1 && have_tput=1
  local bold='' reset='' dim=''
  if [[ $have_tput -eq 1 ]] && [[ -t 1 ]]; then
    bold="$(tput bold)"; reset="$(tput sgr0)"; dim="$(tput dim)"  # shellcheck disable=SC2034
  fi

  # Show unified banner if function available
  if type -t nftban_banner >/dev/null 2>&1; then
    nftban_banner "help"
    echo ""
  fi

  echo "USAGE:"
  echo "  nftban <command> [subcommand] [options]"
  echo

  printf "%sCORE:%s\n" "$bold" "$reset"
  cat <<'EOF'
  status           Show global system status (quick overview)
  health           System diagnostics (binaries, services, permissions)
  validate         Firewall validation (tables, sets, chain policies)
  config           Manage configuration settings
  sync             Atomic reload of nftables rules
  version          Show version and component info
  help             Show this help
EOF
  echo

  printf "%sFIREWALL & SECURITY:%s\n" "$bold" "$reset"
  cat <<'EOF'
  firewall         Manage nftables (init, reload, status, reset)
  nftables         Direct nftables control (start, stop, reload)
  ban              Ban IP address (--timeout 1h for temporary)
  unban            Unban IP address
  list             List banned/whitelisted IPs
  check            Check if IP/port is allowed or blocked
  search           Search IP across sets, feeds, geoban
  whitelist        Manage whitelists (add, remove, list)
  whitelist-system Auto-whitelist essential IPs (gateway, DNS)
  profile          Apply security profile (basic, standard, advanced)
  panel            Web hosting panel integration (DirectAdmin)
  permissions      Audit & enforce file permissions
EOF
  echo

  printf "%sPROTECTION MODULES:%s\n" "$bold" "$reset"
  cat <<'EOF'
  ddos             DDoS protection (SYN flood, rate limiting)
  portscan         Port-scan detection (Suricata or kernel logs)
  suricata         Suricata IDS/IPS (install, enable, rules update)
  login            SSH login monitor (alerts, auto-ban)
  feeds            Threat feeds (list, enable, disable, update)
  trust            Trust feeds - whitelist CDN/cloud (Cloudflare, AWS)
  country          Country blocking (enable/disable by ISO code)
  geoip            IP geolocation lookup (MaxMind GeoIP2)
  geoban           Geographic IP blocking (ban/unban by country)
  cloudflare       Cloudflare IP whitelist (deprecated: use trust)
EOF
  echo

  printf "%sMONITORING & REPORTING:%s\n" "$bold" "$reset"
  cat <<'EOF'
  gui              Web GUI (nftban-ui on port 8443)
  metrics          Prometheus exporter (port 9100)
  stats            Statistics (top IPs, recent bans, trends)
  watchdog         System resource monitoring (load, memory, I/O)
  report           Security reports (HTML, email)
  port             Port scan and service discovery
  fhs              Filesystem hierarchy compliance
  module           Module inventory (list, status)
  services         System services status
  timers           Systemd timer management
  mail             Email notifications
EOF
  echo

  printf "%sDEBUG & TESTING:%s\n" "$bold" "$reset"
  cat <<'EOF'
  debug            Debug mode (verbose logging)
  smoke            Run smoke tests (quick validation)
  test             Run test suite (validation tests)
  emulate          Simulate packet decision (test rules)
  setup            Initial system setup
  wizard           Interactive setup wizard
  menu             Interactive TUI menu
EOF
  echo

  printf "%sBANNER & HEALTH INDICATOR:%s\n" "$bold" "$reset"
  cat <<'EOF'
  The CLI banner displays a health indicator showing system status:
    🟢 OK        System healthy, all checks passed
    🟠 WARNING   Minor issues detected, review recommended
    🔴 ERROR     Critical issues found, action required
    ⚪ UNKNOWN   Health check not run yet

  Health status is updated by nftban-health.timer (runs daily).
  To manually update: nftban health check --cache-status
  To disable banner:  export NFTBAN_BANNER_MODE=none
EOF
  echo

  printf "%sTIPS:%s\n" "$bold" "$reset"
  cat <<'EOF'
  • Quick start:    nftban status && nftban health
  • Interactive:    nftban menu (TUI mode)
  • Tab-complete:   Use TAB to auto-complete commands
  • JSON output:    Add --json for machine-readable output
  • Per-command:    nftban <command> help
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
