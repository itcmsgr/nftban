#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Grouped Help System
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Grouped help output for NFTBan CLI
#
# IMPORTANT: Global options are defined in commands.registry.yml (single source
# of truth). This file uses hardcoded values for runtime performance (no yq
# dependency). When updating global options, update BOTH:
#   1. commands.registry.yml - canonical definition
#   2. This file - runtime display
#
# Use scripts/generate-help.sh to auto-generate from registry for docs.
#
# meta:name="nftban_help"
# meta:type="module"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2025-11-05"
#
# meta:description="Provides grouped, categorized help output for main CLI"
# meta:input="None (called from main router)"
# meta:output="Formatted help text with categories (CORE, FIREWALL, PROTECTION, MONITORING)"
# meta:depends="bash,tput"
#
# meta:inventory.files=""
# meta:inventory.binaries="tput"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"

set -Eeuo pipefail

# =============================================================================
# GROUPED HELP RENDERER
# =============================================================================

nftban_print_help() {
  # Renders grouped help menu with 5 categories
  # Categories: CORE, FIREWALL & SECURITY, PROTECTION MODULES, MONITORING & REPORTING, DEBUG & TESTING
  # Uses tput for bold formatting if available (graceful fallback)

  local have_tput=0; command -v tput >/dev/null 2>&1 && have_tput=1
  local bold='' reset=''
  # shellcheck disable=SC2034  # dim reserved for future use
  local dim=''
  if [[ $have_tput -eq 1 ]] && [[ -t 1 ]]; then
    bold="$(tput bold)"
    reset="$(tput sgr0)"
    # shellcheck disable=SC2034  # dim reserved for future use
    dim="$(tput dim)"
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
  configtest       Validate config against schema (alias: config test)
  configaudit      Audit config for drift and changes (alias: config audit)
  modes            Show all module modes in table view
  sync             Atomic reload of nftables rules
  system           System service management (enable/disable/restart)
  update           Update nftban to latest version
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
  panel            Web hosting panel integration (DA, cPanel, CWP, etc.)
  permissions      Audit & enforce file permissions
  polkit           Polkit authorization (validate, groups, rules)
  firewall-logs    Firewall logging utilities
  rbl              RBL (Real-time Blackhole List) monitoring
EOF
  echo

  printf "%sPROTECTION MODULES:%s\n" "$bold" "$reset"
  cat <<'EOF'
  botscan          Bot and crawler detection/protection
  ddos             DDoS protection (SYN flood, rate limiting)
  portscan         Port-scan detection (Suricata or kernel logs)
  suricata         Suricata IDS/IPS integration and management
  login            SSH login monitor (alerts, auto-ban)
  feeds            Threat feeds (list, enable, disable, update)
  trust            Trust feeds - whitelist CDN/cloud (Cloudflare, AWS)
  country          Country blocking (enable/disable by ISO code)
  geoip            IP geolocation lookup (MaxMind GeoIP2)
  geoban           Geographic IP blocking (ban/unban by country)
EOF
  echo

  printf "%sMONITORING & REPORTING:%s\n" "$bold" "$reset"
  cat <<'EOF'
  gui              Web GUI (nftban-ui on port 8443)
  metrics          Prometheus exporter (port 9100)
  zabbix           Zabbix monitoring exporter
  connector        Data connectors (Elasticsearch, Kafka, syslog)
  pro              NFTBan Pro subscription management
  snapshot         Data snapshot functionality
  stats            Statistics (top IPs, recent bans, trends)
  watchdog         System resource monitoring (load, memory, I/O)
  report           Security reports (HTML, email)
  queue            Task queue management (status, DLQ retry/purge)
  port             Port scan and service discovery
  fhs              Filesystem hierarchy compliance
  module           Module inventory (list, status)
  services         System services status
  timers           Systemd timer management
  mail             Email notifications (test, spool status)
EOF
  echo

  printf "%sDEBUG & TESTING:%s\n" "$bold" "$reset"
  cat <<'EOF'
  debug            Debug mode (verbose logging)
  smoke            Run smoke tests (quick validation)
  test             Run test suite (validation tests)
  emulate          Simulate packet decision (test rules)
  setup            Initial system setup
  support          Generate support bundle for troubleshooting
  wizard           Interactive setup wizard
  menu             Interactive TUI menu
EOF
  echo

  printf "%sMEMORY & BAN MANAGEMENT:%s\n" "$bold" "$reset"
  cat <<'EOF'
  protect          Mark permanent ban as protected (never auto-evict)
  unprotect        Remove protection from a ban (allow auto-eviction)
  cleanup          Evict old unprotected bans (--stats, --dry-run, --execute)
EOF
  echo

  printf "%sEMERGENCY & RECOVERY:%s\n" "$bold" "$reset"
  cat <<'EOF'
  flush            Flush IPs from nftables (blacklist, feeds, geoban, all)
                   SOS mode: flush all + restore system whitelist
EOF
  echo

  printf "%sBANNER & HEALTH INDICATOR:%s\n" "$bold" "$reset"
  cat <<'EOF'
  The CLI banner displays a health indicator showing system status:
    🟢 OK        All features installed (including optional)
    🟠 WARNING   Optional features not installed (protection working)
    🔴 ERROR     Critical issues found, action required
    ⚪ UNKNOWN   Health check not run yet

  Health status is updated by nftban-health.timer (runs daily).
  To manually update: nftban health check --cache-status
  To disable banner:  export NFTBAN_BANNER_MODE=none
EOF
  echo

  printf "%sOPTIONAL FEATURES:%s\n" "$bold" "$reset"
  cat <<'EOF'
  Some systemd timers are OPTIONAL and only needed for specific use cases.
  Your firewall protection works fully without them.

  TIMER                      PURPOSE                    WHEN NEEDED
  ─────────────────────────────────────────────────────────────────────
  nftban-queue.timer         Async ban queue processing High-volume DDoS
  nftban-core-geoip.timer    GeoIP database updates     Country blocking
  nftban-metrics.timer       Prometheus metrics export  Grafana monitoring

  Enable optional timer:   systemctl enable --now nftban-queue.timer
  Disable optional timer:  systemctl disable --now nftban-queue.timer
  Check timer status:      nftban timers

  NOTE: 🟠 WARNING in health check means optional features are missing,
        NOT that your firewall has problems. Core protection is working.
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
