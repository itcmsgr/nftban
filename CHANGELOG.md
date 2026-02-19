# NFTBan Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.1.0] - 2026-02-19

### BREAKING CHANGES (Major Schema Overhaul - "Directional Stateful Architecture")

- **UNIFIED BLACKLIST**: All bans now go to single `blacklist_ipv4/ipv6` set
  - No separate feeds_ipv4, geoban_ipv4, auto_ipv4, manual_ipv4 sets
  - CIDR aggregation prevents IP duplicates, reduces memory usage
  - Source tracking maintained in daemon database (not nftables)
  - Temp bans use nftables timeout flag (auto-expire)

- **MINIMAL SCHEMA**: Only 4 IP sets per table
  - `whitelist_ipv4/ipv6`: Trusted IPs/networks (interval flags)
  - `blacklist_ipv4/ipv6`: All bans (interval + timeout flags)
  - Port sets: `tcp_ports_in/out`, `udp_ports_in/out` (directional)
  - Tables: `ip nftban`, `ip6 nftban` (separate, not inet dual-stack)

- **IPC-ONLY WRITES**: All modifications go through Go daemon
  - Shell modules no longer write directly to nftables
  - Read-only `nft` commands used only for validation
  - Ensures CIDR aggregation and source tracking

- **FAIL2BAN REMOVED**: Use native login monitoring
  - `nftban login` module replaces fail2ban jails
  - Panel integrations updated to use native monitoring
  - Conflict detection retained for migration assistance

### Added
- CVE-2025-NFTBAN-001 protection: Blacklist BEFORE `ct state established`
- ICMPv6 full ND support (router/neighbor solicitation/advertisement)
- Module system: modules disabled by default (zero overhead when disabled)
- CT limits configurable via `ddos.conf` (SSH: 10, HTTP: 100)

### Changed
- Go daemon routes ALL sources to unified blacklist sets
- Shell modules verify IPC operations via read-only nft
- Metrics track source counts but all data in unified blacklist
- Panel files recommend native login monitoring over fail2ban

### Removed
- Separate `feeds_ipv4/ipv6` nftables sets (merged into blacklist)
- Separate `geoban_ipv4/ipv6` nftables sets (merged into blacklist)
- Separate `auto_ipv4/ipv6` nftables sets (merged into blacklist)
- Separate `manual_ipv4/ipv6` nftables sets (merged into blacklist)
- fail2ban as service dependency (use native login monitoring)
- fail2ban menu option and status command

---

## [1.18.0] - 2026-02-19

### BREAKING CHANGES (Major Schema Revision)

- **SCHEMA**: Consolidated NFT schema per Final_v1_18 specification
  - Tables: `ip nftban` (required), `ip6 nftban` (recommended)
  - Sets: `whitelist_ipv4/ipv6`, `blacklist_ipv4/ipv6`, `feeds_ipv4/ipv6`, `geoban_ipv4/ipv6`, `auto_ipv4/ipv6`, `manual_ipv4/ipv6`
  - Port sets: `tcp_ports_in/out`, `udp_ports_in/out` (directional)
  - Chain priority: 0 (standard filter priority)
  - Full ICMPv6 ND support (nd-router-solicit, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert)

- **IPC-ONLY**: All write operations now require Go daemon
  - Ban/unban operations via IPC only
  - Port add/remove via IPC only
  - Whitelist operations via IPC only
  - Direct `nft add/delete` commands removed from shell modules

- **RULE ORDER**: Security-critical order enforced
  - Blacklist BEFORE `ct state established` (CVE-2024-NFTBAN-001 prevention)
  - Validator checks rule order on every validation

### Added
- NFT schema validation documentation (`docs/NFT-Schema-Validation.md`)
- Enhanced metrics for all IPC operations
- ICMPv6 full ND support (nd-router-*, nd-neighbor-*)
- Auto/manual source-specific ban sets for lifecycle management

### Changed
- All shell modules migrated to IPC pattern
- Metrics collectors use schema functions (O(1) JSON counting)
- Exporters updated for consolidated schema
- Chain priorities standardized to 0 (from -100)
- Feeds module uses dedicated `feeds_ipv4/ipv6` sets (not legacy blacklist)

### Fixed
- **nftban_geoban_exporter.sh**: Wrong table reference (`inet filter` → `ip nftban`)
- **nftban_feeds.sh**: Now uses dedicated `feeds_ipv4` set (not legacy blacklist)
- **nftban_ddos_classic.sh**: Migrated from direct nft to IPC
- **nftban_system_ip.sh**: Migrated from direct nft to IPC
- **cmd_whitelist.sh**: Migrated from direct nft to IPC

---

## [1.16.4] - 2026-02-18

### Fixed
- **BUG-005**: Fedora update shows "Update failed" but succeeds - Fixed exit code capture in RPM pipeline
- **BUG-009**: Unified exporter fails on missing textfile_collector directory - Added directory creation to postinst

### Changed
- RPM update now uses PIPESTATUS[0] to capture actual package manager exit code
- DEB/RPM postinst now creates /var/lib/node_exporter/textfile_collector for Prometheus

---

## [1.16.0] - 2026-02-17

### Added
- Whitelist Safety Tests for smoke test suite (prevents self-lockout)
- Docker packaging with OpenSSF Scorecard compliance
- Distro configs for CentOS, CentOS 9, CentOS Stream 9, Fedora, Fedora 43

### Fixed
- Handle missing suricata user in permission scripts
- Secure config file permissions (root:nftban 0640)
- Docker Hadolint compliance, USER directive, Alpine package
- Accept 'force' without dashes as alias for --force in update command

### Security
- Pin all dependencies for supply chain compliance
- Pin all GitHub Actions to SHA hashes
- OpenSSF Scorecard 7+ rating achieved

---

## [1.15.0] - 2026-02-15

### Added
- **Directional Port Management**: Full IN/OUT direction support for port rules
  - New nftables sets: `tcp_ports_in`, `tcp_ports_out`, `udp_ports_in`, `udp_ports_out`
  - CLI: `nftban port add <port> <protocol> <direction>` (direction: in/out/inout)
  - IPv4 AND IPv6 applied automatically for all port operations
  - Backward compatible: legacy `tcp_ports`/`udp_ports` sets still populated

### Changed
- Port operations now apply to both IPv4 (`ip nftban`) and IPv6 (`ip6 nftban`) tables
- Go port loader accepts 2-part (`PORT/PROTO`) and 3-part (`PORT/PROTO/DIR`) formats
- Default direction for legacy 2-part format is `I` (INPUT)
- Updated CLI help with architecture documentation
- Updated validator to check all 6 port sets (4 directional + 2 legacy)

### Fixed
- cmd_port.sh was using non-existent set names (tcp_ports_in/out) - now schema defines them
- IPv6 ports were not being added - now all port operations include IPv6
- Go loader was rejecting 3-part config format - now accepts direction field

### Major Features

- **feat(portal)**: pro.nftban.com Portal Integration
  - New `export_portal()` function with REAL_ACK semantics (HTTP 2xx confirmation)
  - Server inventory push: CPU, RAM, disk, OS, network, modules to portal
  - Unique host identification via `/etc/machine-id` or SHA256(MAC + hostname)
  - Module status tracking per server
  - Portal config template: `setup/portal.conf`

- **feat(metrics)**: Phase 1 Reconciliation Metrics
  - Export tracking counters per target:
    - `nftban_export_attempts_total{target}`
    - `nftban_export_success_total{target}`
    - `nftban_export_failures_total{target}`
    - `nftban_export_duration_ms{target}`
    - `nftban_export_last_success_timestamp{target}`
  - Persistent state in `/var/cache/nftban/stats/export_tracking.dat`
  - All export functions now track success/failure with reason codes

### Schema Updates (Portal)

- **Server Inventory Tables** (metricsnftban/06-PORTAL-SCHEMA.md):
  - `nftban_host`: Server registry with hardware, OS, network info
  - `nftban_host_module`: Module status per server
  - `nftban_host_export_target`: Export target health per server
  - Upsert functions for real-time inventory updates
  - Fleet-wide queries for version management and health monitoring

### Enhancements

- **feat(export)**: Robust nc agent improvements
  - Configurable timeout via `NFTBAN_ZABBIX_TIMEOUT` (default: 10s)
  - Better error categorization for failure tracking
  - Phase 1 metrics track all export targets: prometheus, zabbix, portal, elasticsearch, kafka, file

### Documentation

- Updated `05-RECONCILIATION-METRICS.md` with Reality vs Spec section
- Added ACK semantics table per export target type
- New `07-PORTAL-PAGES.md` portal UI specification

---

## [1.14.1] - 2026-02-13

### Bug Fixes

- **fix(update)**: Use package managers for dependency resolution
  - DEB: apt-get install (not dpkg) ensures new deps like gawk install
  - RPM: dnf → yum → rpm fallback chain for updates
  - Fixes issue where dependencies weren't installed on updates

---

## [1.13.0] - 2026-02-12

### Major Features

- **feat(nft)**: v1.1 Async IPC Architecture with source-specific sets
  - New `pkg/opqueue/` package for async operation queue with coalescing
  - Source-specific sets: feeds, geoban, auto (login/portscan/ddos/suricata), manual
  - TTL=max coalescing policy - never shortens a ban
  - Barrier semantics for flush/replace operations
  - Atomic counters for O(1) queue depth checks

### New Components

- **OpQueue Package** (`pkg/opqueue/`)
  - `queue.go`: Main queue manager with per-set buffers
  - `buffer.go`: Per-set coalescing with generation tracking
  - `types.go`: Operation types and source routing configuration
  - `source_index.go`: Persistent source tracking for shared sets
  - `file_reader.go`: Secure file ingestion with TOCTOU protection
  - `nftbackend_wrapper.go`: Adapter for existing nftbackend

### Schema Changes

- **nft_schema.sh**: Added 8 new source-specific sets
  - `feeds_ipv4/ipv6`: Threat intelligence feeds (CIDRs, bulk replace)
  - `geoban_ipv4/ipv6`: Geographic blocking (CIDRs, bulk replace)
  - `auto_ipv4/ipv6`: Auto-detected threats (login, portscan, ddos, suricata)
  - `manual_ipv4/ipv6`: Manual CLI bans
  - Legacy `blacklist_ipv4/ipv6` deprecated but kept for migration

### New IPC Methods

- **nft_ipc.sh**: Added v1.1 async IPC functions
  - `nft_ipc_replace_set()`: Bulk set replacement via file path
  - `nft_ipc_flush_source()`: Remove all elements from a source
  - `nft_ipc_unban_source()`: Unban from specific source's sets
  - `nft_ipc_unban_any()`: Unban from ALL sets where IP exists
  - `nft_ipc_queue_status()`: Get async queue statistics

### Daemon Integration

- **nftband**: OpQueue integration
  - OpQueue and SourceIndex initialization on startup
  - Background saver for SourceIndex (30s interval)
  - Graceful shutdown with queue drain
  - New IPC handlers: `replace_set`, `flush_source`, `queue_status`

### Testing

- Validated on lab servers with Go 1.22+

---

## [1.12.5] - 2026-02-10

### Bug Fixes

- **fix(geoban)**: Add missing `refresh` subcommand to help documentation
  - Subcommand was implemented but not documented in help output

- **fix(ci)**: Resolve ShellCheck warnings SC2178, SC2313, SC2034
  - nftban_report_data.sh: Add SC2178 disable for nameref, quote array indices
  - nftban_health_render.sh: Remove unused conflicts_json variable

- **fix(docs)**: Correct CLI command count from 62 to 54
  - Updated README.md to reflect actual registered command count
  - Count based on commands.registry.yml (source of truth)

### Enhancements

- **feat(panel)**: Add DirectAdmin, cPanel, generic to _get_panel_info() helper
  - All 8 panel types now have consistent metadata entries

---

## [1.12.4] - 2026-02-10

### Bug Fixes (Cross-Distro Validation)

- **fix(login)**: Boolean normalization for login monitor config
  - Root cause: Only accepted `"true"`, not `"TRUE"`, `"yes"`, `"1"`, `"on"`
  - Fix: Added normalize function accepting true/TRUE/yes/YES/1/on/ON

- **fix(panel)**: Panel port detection now queries nft sets directly
  - Root cause: Old code checked `dport` rules, but NFTBan uses `tcp_ports`/`udp_ports` sets
  - Fix: Query `nft list set ip nftban tcp_ports` instead of grepping dport

- **fix(suricata)**: Enable tpacket-v3 by default to reduce memory usage
  - Root cause: TPACKET_V2 default uses 1.8GB; V3 uses ~400MB
  - Fix: Add `tpacket-v3: yes` to generated af-packet config

- **fix(suricata)**: EVE log permissions for RHEL-based distros
  - Root cause: Suricata runs as `suricata` user, couldn't write to nftban directory
  - Fix: Add suricata to nftban group, set directory to suricata:nftban 770
  - Files updated: cmd_suricata_setup.sh, nftban_permissions.sh, nftban_health_fixes.sh, install_suricata.sh

### Enhancements

- **feat(watchdog)**: Add `nftban watchdog run` command for systemd timer
  - Proper entry point with conditional report saving (only on issues)
  - Ensures trends directory exists before running

- **feat(watchdog)**: Improved trend directory creation with proper permissions
  - Handles permission issues gracefully with fallback to logger

### Cross-Distro Validation

Tested on Debian 12, Ubuntu 24.04, and AlmaLinux 9.7

---

## [1.12.2] - 2026-02-09

### Bug Fixes (Maintenance & Cleanup)

- **fix(maintenance)**: Remove double-locking bug causing "Maintenance already running"
  - Root cause: systemd `flock` creates lock file, then script's internal check sees it and exits
  - Fix: Remove script-side lock checking, let systemd flock handle it
  - Impact: All 5 lab servers had blocked maintenance for 19+ days

- **fix(logrotate)**: Add missing `/var/log/nftban/watchdog/` directory rotation
  - Added: alerts.log, stats.log, profiles.log rotation (weekly, 4 rotations)

- **feat(cleanup)**: Add comprehensive cleanup function `nftban_watchdog_cleanup_all()`
  - Cleans: reports (7d), stats/history (30d), profiles (7d), recorder (7d)
  - Called hourly during maintenance trend collection
  - Fixes 13,000-16,000 accumulated files on lab servers

### Cross-Distro Validation
- Tested on all 5 lab servers after fix deployment
- Maintenance now completes successfully on all servers

---

## [1.12.1] - 2026-02-09

### Bug Fixes (Cross-Distro Validation)

- **fix(watchdog)**: Resolve `head -""` error on AlmaLinux when `$count` is empty
  - Added validation: `[[ ! "$count" =~ ^[1-9][0-9]*$ ]] && count=10`
  - Affected: lab3 (828 errors), lab4 (4 errors)

- **fix(watchdog)**: Resolve `local` inside loop causing exit 1 with `set -e`
  - Moved variable declarations (`stat_line`, `cpu_time`, `vmrss`) outside for loops
  - Affected: All distros (Debian, Ubuntu, AlmaLinux)

### New Features

- **feat(watchdog)**: Add MODULE RESOURCES section to `nftban watchdog report`
  - Shows per-module CPU%, MEM%, and memory usage
  - Displays: login-monitor, feeds, maintenance, portscan, ddos, geoban, suricata
  - Wired up `nftban_watchdog_collect_module_resources()` which existed but was never called

### Technical Details

- Cross-distro validation across 5 lab servers:
  - lab (Debian 12), lab1/lab3/lab4 (AlmaLinux 9.7), lab2 (Ubuntu 24.04)
- All log formats verified against code: bans.log, login_alert.log
- Logrotate confirmed working on all servers

---

## [1.12.0] - 2026-02-09

### Suricata Interface Configuration Redesign

Major release implementing a fail-safe interface detection system for Suricata af-packet configuration. Core principle: **"If we are not sure, we protect"** - auto-enable only when single effective capture interface is unambiguous.

### Added

- **New command: `nftban suricata iface`** - Interface detection and configuration:
  - `iface list` - Show all interfaces with detection details, scoring, and reasons
  - `iface set X` - Manually set capture interface(s)
  - `iface auto` - Reset to auto-detection mode
  - `iface help` - Detailed help and examples

- **Hard gate decision logic** - Deterministic checks, not percentages:
  - Auto-enable: Exactly 1 effective capture interface, non-virtual, UP, with default route or public IP
  - Require selection: Multiple effective interfaces, multiple default routes, virtual top candidate

- **Master/slave resolution** - Automatically resolve bridge/bond relationships:
  - eth0 slave of br0 → capture on br0 (not eth0)
  - Warns and offers to switch when user selects slave interface
  - Prevents duplicate traffic capture

- **Interface type detection** - Identifies interface types:
  - Physical (phy), Bridge, Bond, VLAN, Virtual
  - Virtual patterns: docker*, cni*, flannel, virbr*, veth*, br-*, zt, tailscale*, wg*, tun*, tap*, podman*, cali*, lxc*

- **Capture health check** - `nftban_health_check_suricata_capture()`:
  - Checks configured interface exists and is UP
  - Parses Suricata stats for `capture.kernel_packets` and `capture.kernel_drops`
  - Alerts on zero packets captured or high drop rates
  - Provides actionable fix commands

- **New configuration file** - `/etc/nftban/conf.d/suricata/interfaces.conf`:
  - `SURICATA_IFACE_MODE` - auto or manual
  - `SURICATA_IFACES` - comma-separated interfaces for manual mode
  - `SURICATA_ALLOW_MULTI` - allow auto-detection of multiple interfaces
  - `SURICATA_INCLUDE_VIRTUAL` - include virtual interfaces in detection
  - `SURICATA_CLUSTER_ID_BASE` - af-packet cluster ID base

- **Multi-interface support** - Configure multiple capture interfaces:
  - Each interface gets unique cluster-id (base + offset)
  - Requires explicit opt-in: `SURICATA_ALLOW_MULTI=true`

### Changed

- **Interface detection in enable flow** - Replaced simple default-route detection with hard gate system:
  - Actionable error messages when selection required
  - Shows available candidates and commands to fix
  - No silent failures or guessing

- **Docker handling** - Docker presence alone does NOT force selection:
  - Only blocks if top candidate IS virtual
  - docker0 excluded by default (virtual pattern)
  - Servers with docker + eth0 auto-enable on eth0

### Technical Details

- New module: `cli/lib/nftban/cli/cmd_suricata_iface.sh` (650+ lines)
- Added 3 new DISTRO_PATHS entries: `suricata_stats_log`, `suricata_iface_config`, `suricata_socket`
- Updated all 12 distro config files with new paths
- Added to DEB conffiles and RPM %files sections

### Documentation

- Detailed help text in `nftban suricata iface help`
- Examples for common scenarios (simple server, docker, multi-homed, bridge)

---

## [1.11.0] - 2026-02-08

### Suricata Alert Routing & Module Deduplication

Major performance and accuracy release focused on eliminating duplicate processing and score inflation across Suricata-integrated modules.

### Added

- **Per-module resource metrics** - Track CPU/RAM impact per module:
  - Timer modules (feeds, rbl): Last run duration, peak memory, exit status
  - Embedded modules (portscan, ddos, geoban): Estimated CPU/RAM based on ban ratios
  - Available in both watchdog reports and Prometheus/Zabbix exports
  - New metrics: `nftban_module_*_cpu_percent_estimated`, `nftban_module_*_last_run_duration_seconds`

- **Watchdog timer in health display** - Now shows in Optional Features section

- **Login monitor crash fix** - Ban command failure no longer crashes the service

- **Health auto-fix for sbin binaries** - Queue processor permissions (755) now auto-fixed

- **Deterministic alert routing** - New `routing.conf` with priority-based module assignment:
  - SID overrides → Category mapping → Service/port context → Keywords → Priority arbitration
  - Priority order: ddos (100) > portscan (50) > login (25) > other (1)
  - Single owner per alert - eliminates double/triple scoring

- **Category normalization** - EVE categories normalized before matching:
  - "Attempted Administrator Privilege Gain" → "attempted-administrator-privilege-gain"
  - Uses contains/prefix matching (not exact equals)
  - Works across all ruleset vendors (ET Open, ET Pro, custom)

- **Event deduplication** - Global dedup cache with LRU eviction:
  - EventID = hash(timestamp + src_ip + dest_ip + ports + SID + proto)
  - TTL-based expiry (default 1 hour)
  - 100K event capacity with automatic cleanup

- **Rate gate for DDoS** - Volume threshold before classification:
  - Single slow-loris probe no longer classified as DDoS
  - Requires 10+ events from same IP in 10 seconds
  - Prevents false positives from reconnaissance probes

- **Tiebreak rules** - Explicit conflict resolution:
  - SSH port 22 + brute indicators = login wins (not portscan)
  - Brute + scan keywords = login wins
  - DDoS category but no rate gate = downgraded to "other"

- **Score caps per module** - Prevents score inflation:
  - Max 500 points per module per IP per 5-minute window
  - DDoS: 1000 points per 60 seconds

### Changed

- **Login patterns refined** - Removed Nmap|Scan overlap:
  - Now: `brute|auth|password|login|credential|failed|invalid user|dictionary`
  - SSH tool detection: `paramiko|libssh|hydra|medusa|ncrack` (not nmap)

- **Portscan patterns refined** - Category-first matching:
  - Primary: categories (attempted-recon, network-scan)
  - Secondary: keywords (portscan|nmap|masscan|zmap|shodan|censys)

- **DDoS rate gate required** - No longer classifies single events as DDoS

### Fixed

- **Module overlap eliminated** - SSH brute-force no longer triggers both Login and Portscan
- **Score inflation fixed** - Same alert no longer scored by multiple modules
- **Duplicate bans prevented** - Same IP not banned twice for one event

### Performance

- Estimated 40-60% reduction in redundant processing
- LRU-bounded memory for dedup and rate gate tracking
- Thread-safe with minimal lock contention

---

## [1.10.0] - 2026-02-08

### Code Consolidation & Security Hardening

Major refactoring release focused on code quality, security fixes, and FHS compliance.

### Added

- **4 new shared libraries** - Consolidated 1000+ lines of duplicate code:
  - `nftban_timestamp.sh` - 12 timestamp functions (ISO 8601, Unix, relative)
  - `nftban_file_utils.sh` - 6 file age/freshness functions (cross-platform)
  - `nftban_service_control.sh` - 9 systemctl wrapper functions
  - `nftban_alert_throttle.sh` - 3 alert rate-limiting functions

- **FHS specification expanded** - 102 directories now defined:
  - Added 27 missing directories for complete coverage
  - Suricata integration directories (/etc/nftban/suricata/*)
  - Module state directories (login, portscan, geoban tracking)
  - Cache directories for all modules

### Fixed

- **Security: Directory permissions** - Fixed 0775 → 0750 in install.sh
- **Socket ownership enforcement** - nftband.sock now explicitly root:nftban 660
- **Legacy /var/run paths** - Replaced with ${NFTBAN_RUN_DIR:-/run/nftban}
- **Hardcoded textfile collector** - Now uses NFTBAN_METRICS_TEXTFILE_DIR config
- **GeoIP mkdir bypass** - Now uses FHS spec for directory creation
- **Version sync** - All package specs updated to 1.10.0

### Changed

- **29 modules refactored** to use shared libraries with graceful fallbacks
- **Health fix mechanism** now uses FHS spec as single source of truth
- **Portscan stealth detection** - New pattern matching for stealth scans

---

## [1.9.7] - 2026-02-06

### GUI Dashboard & Metrics Overhaul

Major UI/UX improvements with real data integration, Chart.js visualizations, and professional UX patterns.

### Added

- **Chart.js dashboard integration** - 5 interactive charts:
  - Traffic Trend (24h line chart)
  - Ban Distribution (doughnut chart)
  - Top Blocked Countries (horizontal bar)
  - Port Scan Activity (vertical bar)
  - Bans Over Time (timeline)

- **Chart API endpoints** - New REST endpoints for chart data:
  - `GET /ui/api/chart/traffic` - Traffic history
  - `GET /ui/api/chart/bans` - Ban distribution
  - `GET /ui/api/chart/countries` - Top blocked countries
  - `GET /ui/api/chart/portscan` - Port scan activity
  - `GET /ui/api/chart/bans-timeline` - Bans over time

- **Metrics cache generator** - Unified exporter now generates GUI cache files:
  - `traffic_history.json` - Rolling 24-sample bandwidth history
  - `dropped_by_country.json` - Aggregated geoban blocks by country
  - `dropped_by_port.json` - Aggregated portscan blocks by port

- **UX improvements** - Professional UI patterns:
  - Loading spinners during HTMX updates
  - Empty state displays with icons and helpful messages
  - Error state handling with retry buttons
  - Tooltips for complex metrics (hover for explanation)

### Fixed

- **getTrafficHistory()** - Was returning empty array (TODO stub), now reads from cache or generates history
- **getDroppedByCountry()** - Was returning empty array, now parses geoban logs and aggregates by country
- **getDroppedByPort()** - Was returning empty array, now parses portscan logs and aggregates by port

### Changed

- Dashboard now displays real-time charts instead of placeholder data
- Metrics page shows loading indicators during data refresh
- Health page has improved empty/error state handling

---

## [1.9.6] - 2026-02-05

### Packaging Fixes (Lab Server Diagnostics)

This maintenance release fixes critical packaging bugs discovered during lab server diagnostics
across Debian 12, Ubuntu 24.04, and AlmaLinux 9 environments.

### Fixed

- **sbin scripts permissions** - Scripts in `/usr/lib/nftban/sbin/` now correctly installed with
  755 permissions. Previously `nftban-queue-processor` and `nftban-service-alert` were installed
  with 644, causing `nftban-queue.service` to fail with "Permission denied"

- **nftban-suricata.service CAP_NET_ADMIN** - Added `AmbientCapabilities=CAP_NET_ADMIN` to service
  file. Service was crash-looping on some systems with "must run as root or with CAP_NET_ADMIN"

- **suricata group creation** - DEB/RPM packages now create `suricata` group if missing. Previously
  `nftban-suricata-update.service` failed with "Failed to determine group credentials"

- **nftban-suricata-update.service group** - Changed `Group=suricata` to `Group=root` since service
  runs as root and suricata group may not exist on all systems

### Changed

- Build script now logs sbin script installation count for verification
- Added missing group creation to both DEB postinst and RPM %pre scripts

---

## [1.9.5] - 2026-02-04

### Security Posture Integration

This release adds smart, low-noise security posture checks integrated into
existing commands - not an audit replacement, just essential hardening status.

### Added

- **Security posture checks** - Limited scope hardening status (not audit replacement):
  - `nftban health posture` - Check SSH config, sudoers, systemd hardening, config integrity
  - One-line posture summary in `nftban status` under Health section
  - Posture row in daily email report template

- **Posture data collection** - New `nftban_posture_oneline()` function in
  `nftban_report_data.sh` for SSOT posture status

### Fixed

- **Shellcheck warnings** - Removed unused variables:
  - `nftban_report_email.sh` - Removed unused `sender` and `subject` variables
  - `nftban_report_engine.sh` - Removed unused `subject` variable
  - `nftban_rbl.sh` - Integrated subject into body content
  - `nftban_report_data.sh` - Added shellcheck disable for reserved cache variables

### Notes

- Security posture is intentionally limited scope - for full audits use lynis or oscap
- Checks are advisory, not blocking - no false positives from strict rules
- Integrates into existing UX (status, health, reports) - no new top-level commands

---

## [1.9.4] - 2026-02-04

### Unified Mail & Reporting System

This release consolidates all email sending through the unified NFTBan mail mechanism
and modernizes all email templates for consistent, professional reporting.

### Added

- **New email templates** - Professional HTML templates for all alert types:
  - `login_alert.html` - Login/SSH/su/sudo security alerts
  - `rbl_alert.html` - RBL blacklist detection alerts with severity levels
  - Modernized `stats_email.html` with KPI cards, module status, and recommendations
  - Modernized `alert.html` with severity-based styling
  - Modernized `service_failure.html` with system context

- **Health timer boot execution** - `nftban-health.timer` now runs 15 minutes after
  boot to catch startup issues (previously only ran at scheduled 03:00 AM time)

### Fixed

- **Unified mail mechanism** - All modules now use `nftban_mail_send()`:
  - `nftban_rbl.sh` - RBL alerts (was direct `mail` command)
  - `nftban_portscan_classic.sh` - Portscan alerts (was direct `mail` command)
  - `nftban_portscan_suricata.sh` - Suricata alerts (was direct `mail` command)
  - `nftban_report_engine.sh` - Report emails (was direct `mail` command)
  - `nftban_report_email.sh` - Email reports (was direct `sendmail -t`)
  - `nftban_login_alert.sh` - Login alerts (removed fallback bypass)
  - `maintenance.sh` - SSH port change alerts (was direct `mail` command)

- **Template file permissions** - All mail templates now have correct 644 permissions

### Improved

- **Consistent template styling** - All email templates now share:
  - Common color palette and typography
  - Responsive design for mobile clients
  - Severity-based header colors (critical/warning/info/success)
  - Current system state context sections
  - Professional footer with version and server info

- **RBL alert clarity** - Template clearly shows which RBL list detected the blacklisting
  with `{RBL_NAME}` and `{RBL_DOMAIN}` variables

---

## [1.9.3] - 2026-02-04

### RBL Monitoring & Performance Enhancements

This release enhances RBL monitoring, improves ban performance with async enrichment,
and adds atomic writes for Suricata rule management.

### Added

- **RBL enabled by default** - Server IP blacklist monitoring now enabled out-of-the-box
  (monitoring only, no firewall changes - safe to enable)

- **12-hour RBL check schedule** - Changed from daily to twice-daily checks (02:00 + 14:00)
  for faster detection of blacklisting events

- **RBL in `nftban status`** - RBL monitoring status now displayed in protection modules
  section showing enabled state and last check time

- **`nftban health rbl`** - New health check subcommand for RBL monitoring:
  - Checks RBL enabled status
  - Verifies timer is active
  - Validates last check within 48 hours
  - Confirms cache directory is writable

- **RBL timer in status** - Added `nftban-rbl-check.timer` to timer description array

- **`.local` override info** - `nftban rbl status` now shows override file path
  with [Active]/[Not created] status

- **RBL in main health output** - `nftban health` now shows RBL status in
  SYSTEM CHECKS section (alongside GeoIP and GeoBan)

### Improved

- **Async GeoIP enrichment** - Ban-first, enrich-after pattern for faster ban execution:
  - GeoIP lookup now runs in goroutine AFTER IP is blocked
  - Ban latency no longer includes GeoIP lookup time
  - Thread-safe implementation with proper variable capture

- **Atomic rule file writes** - Suricata SID/category config changes now atomic:
  - Uses temp file + rename pattern to prevent partial writes
  - `enable.conf` and `disable.conf` are sorted numerically after each change
  - Sources `nftban_file_ops.sh` for `nftban_atomic_write()` function

### Changed

- **CLI completion** - Added 7 missing commands to bash completion
- **Help documentation** - Added 12 missing commands to `nftban help` output

### Fixed

- **Whitelist centralization** - Removed per-module `whitelist.txt` files (use central `whitelist.d/` instead):
  - Removed `/etc/nftban/conf.d/ddos/whitelist.txt`
  - Removed `/etc/nftban/conf.d/login/whitelist.txt`
  - Removed `/etc/nftban/conf.d/portscan/whitelist.txt`
  - Use `nftban whitelist add <ip>` for central whitelist management

## [1.9.2] - 2026-02-03

### Concurrency Protection & Portscan Logging

This release adds critical concurrency protection mechanisms and fixes portscan module logging.

### Added

- **Update command locking** - Prevents concurrent `nftban update` commands from corrupting package state:
  - Lock file: `/run/nftban/update.lock` with flock
  - Logs lock acquisition/release to update.log
  - `nftban update force` cleans stale locks
  - `nftban update repair` cleans stale locks as part of recovery

- **Daemon sync mutex** - Prevents concurrent sync operations from racing:
  - Added `syncMutex` to `handleSyncRequest()` in daemon
  - Ensures atomic sync operations when multiple IPC requests arrive

- **Portscan module logging** - Created dedicated log files (matching DDoS pattern):
  - `_nftban_portscan_log()` → `/var/log/nftban/portscan.log`
  - `_nftban_portscan_classic_log()` → `/var/log/nftban/portscan-classic.log`
  - `_nftban_portscan_suricata_log()` → `/var/log/nftban/portscan-suricata.log`

- **Status display improvements** - Added `.local` override file info:
  - `nftban ddos status` shows `/etc/nftban/conf.d/ddos/main.conf.local` with active/not created status
  - `nftban portscan status` shows `/etc/nftban/conf.d/portscan/main.conf.local` with active/not created status
  - Added note explaining that `.local` files survive package upgrades

### Fixed

- **ShellCheck warnings** - Fixed SC2155, SC2034, SC2076 in cmd_suricata.sh, nftban_mode.sh, suricata_rules.sh

## [1.9.1] - 2026-02-02

### Suricata Smart Management (Phase 2 - Rules UX)

This release introduces a complete CLI-based rule management system for Suricata,
eliminating the need for manual config file editing.

### Added

- **Suricata rules management** - New CLI commands for ruleset control:
  - `nftban suricata rules status` - Show ruleset version, counts, sources, last update
  - `nftban suricata rules rollback <backup>` - Restore from automatic backup
  - `nftban suricata rules list-backups` - List available rule backups
  - `nftban suricata rules apply` - Apply pending changes (suricata-update + reload)

- **Suricata category management** - Enable/disable rule categories via CLI:
  - `nftban suricata category list` - Show all categories with status
  - `nftban suricata category enable <cat>` - Enable a category (e.g., emerging-malware)
  - `nftban suricata category disable <cat>` - Disable a category (e.g., emerging-policy)

- **Suricata SID management** - Control individual rules:
  - `nftban suricata sid enable <SID>` - Force-enable a specific rule
  - `nftban suricata sid disable <SID>` - Disable a noisy/false-positive rule
  - `nftban suricata sid list [type]` - List SID overrides (enabled/disabled/all)

- **Suricata local rules** - User-defined rules (SID 1000000-1999999):
  - `nftban suricata local list` - List local user rules
  - `nftban suricata local add '<rule>'` - Add a new local rule
  - `nftban suricata local remove <SID>` - Remove a local rule
  - `nftban suricata local edit` - Open local.rules in editor

- **Shared helper library** - New `suricata_rules.sh` helper module with 16 functions
  for backup, rollback, category, SID, and local rule management.

- **Shared mode handler** - New `nftban_mode.sh` helper module (~450 lines) eliminating
  duplicate mode management code across portscan/ddos modules.

- **Unified modes command** - New `nftban modes` command showing all module modes
  in a single table view.

### Fixed

- **DDoS mode argument passing** - Aligned `_nftban_ddos_mode()` to match portscan
  pattern with explicit argument passing and error handling for missing helper.

- **Duplicate _check_root()** - cmd_suricata.sh now uses shared helper when available,
  eliminating code duplication with suricata_rules.sh.

- **Duplicate code in cmd_suricata.sh** - Removed ~400 lines of duplicate router/help
  functions that were accidentally duplicated.

### Changed

- **Package manager inclusions** - Added all new Suricata config files to:
  - RPM spec: state directories, rule configs, yaml overlay
  - DEB postinst: suricata directories and permissions
  - install.sh: suricata rule files and state directory

### Config Files Added

- `/etc/nftban/suricata/rules/disable.conf` - SID disable list (suricata-update)
- `/etc/nftban/suricata/rules/enable.conf` - SID enable list (suricata-update)
- `/etc/nftban/suricata/rules/categories.enabled` - Category toggles
- `/etc/nftban/suricata/rules/local.rules` - User-defined rules
- `/etc/nftban/suricata/suricata.yaml.overlay` - YAML config overlay
- `/etc/nftban/suricata/state/` - Backup state directory

## [1.9.0] - 2026-02-02

### Major Refactoring Release

Comprehensive code audit and bug fix release addressing critical race conditions,
performance optimizations, and code quality improvements across the codebase.

### Fixed - Critical (P0)

- **Race condition in ban escalation** - Added mutex synchronization to prevent
  concurrent goroutines from racing when escalating temporary bans to permanent.
  (`cmd/nftband/main.go:banMutex`)

- **Non-atomic file writer operations** - Fixed unchecked `bufio.Writer.Flush()`
  errors that could cause silent data loss when writing feed and trust files.
  (`cmd/nftban-core/cmd_feeds.go`, `cmd/nftban-core/cmd_trust.go`)

- **IP range parsing** - Added support for IP ranges like "1.2.3.4-1.2.3.10" in
  threat feeds. New `ParseFeedLineMulti()` function expands ranges to individual IPs.
  (`pkg/feeds/parser.go:expandIPRange()`)

- **Nil pointer dereferences** - Added nil receiver checks to all Status methods
  preventing panics when modules are disabled.
  (`pkg/module/module.go:GetStatus()`)

### Fixed - Performance (P1)

- **Pre-allocation optimizations** - Added capacity hints to slice allocations
  reducing memory pressure and GC overhead during CIDR processing:
  - `GetSetElements()` - pre-allocates based on element count
  - `parseSetElements()` - estimates capacity from comma count
  - CIDR merge functions - pre-allocates 2x merged interval count
  - `rangeToCIDRsIPv4()` - pre-allocates 32 slots (IPv4 max)
  (`pkg/sync/nft.go`, `pkg/sync/cidr.go`)

- **Smoke test JSON output** - Fixed cleanup --stats and --dry-run tests to use
  --json flag and check correct data structure.
  (`cli/lib/nftban/tests/smoke_test.sh`)

### Changed - Code Quality (P2/P3)

- **Removed duplicate ValidateIP wrappers** - Consolidated to use
  `netutil.ValidateAndNormalizeIP()` directly.
  (`pkg/blacklist/loader.go`, `pkg/whitelist/loader.go`)

- **Centralized Bash logging** - Created shared logging module to eliminate
  duplicate `log_info/warn/error` functions across scripts.
  (`cli/lib/nftban/helpers/nftban_logging.sh`)

### Added - Observability

- **CIDR filter metrics** - Export filter statistics to both Prometheus and Zabbix:
  - `nftban_cidr_filter_total` - Total CIDRs processed
  - `nftban_cidr_filter_filtered` - CIDRs removed by filtering
  - `nftban_cidr_filter_bogon` - Bogon/reserved CIDRs removed
  - `nftban_cidr_filter_oversize` - Oversized CIDRs removed (< /9)
  - `nftban_cidr_filter_kept` - CIDRs that passed filtering
  (`pkg/watchdog/metrics.go`, `pkg/exporters/zabbix/collector.go`)

- **Filter state persistence** - Filter statistics saved to
  `/var/lib/nftban/state/filter.json` for metrics export.
  (`pkg/safety/limits.go:RecordFilterState()`)

## [1.8.16] - 2026-02-01

### Smart Memory Protection & Ban Management

Major release introducing intelligent memory protection that automatically adapts to server
resources, prevents OOM conditions, and provides tools to manage permanent ban lifecycle.

### Added

- **Dynamic CIDR limits by server tier** - CIDR limits now scale based on available RAM:
  - Small servers (≤4GB): 75,000 CIDRs
  - Medium servers (4-8GB): 100,000 CIDRs
  - Large servers (>8GB): 150,000 CIDRs
  (`pkg/safety/limits.go:GetMaxCIDRsHard()`)

- **Memory pressure detection** - Four-level system monitors memory usage in real-time:
  - Normal (<70%): All features enabled
  - Warning (70-85%): Logged, no action
  - High (85-95%): Geoban loading skipped
  - Critical (>95%): Both feeds and geoban skipped
  (`pkg/safety/limits.go:GetMemoryPressureLevel()`)

- **Automatic protection under pressure** - Sync operations now check memory pressure and
  automatically skip heavy CIDR loading (feeds/geoban) when server is under memory stress.
  Prevents OOM kills while maintaining core firewall functionality
  (`cmd/nftband/main.go:handleSyncRequest()`)

- **Permanent ban tracking** - Track permanent bans with metadata including timestamp,
  reason, source, and protected flag. Stored in `/var/lib/nftban/permanent_bans.json`
  (`pkg/safety/limits.go:PermanentBan{}`, `TrackPermanentBan()`)

- **Protected ban flag** - Mark important bans as protected to prevent automatic eviction.
  Protected bans are never removed by cleanup operations regardless of age
  (`pkg/safety/limits.go:SetBanProtected()`)

- **Age-based eviction** - Unprotected permanent bans older than 30 days become eligible
  for eviction. Helps prevent memory exhaustion from accumulated bans over time
  (`pkg/safety/limits.go:GetEvictableBans()`)

- **New CLI command: `nftban protect <ip>`** - Mark a permanent ban as protected (never
  auto-evict). Use for critical IPs that must remain banned indefinitely
  (`cli/lib/nftban/cli/cmd_protect.sh`)

- **New CLI command: `nftban unprotect <ip>`** - Remove protection from a ban, allowing
  it to be evicted after 30 days of age
  (`cli/lib/nftban/cli/cmd_unprotect.sh`)

- **New CLI command: `nftban cleanup`** - Manage permanent ban eviction:
  - `--stats`: Show permanent ban statistics (total/protected/evictable)
  - `--dry-run`: Preview what would be evicted (default, safe mode)
  - `--execute`: Actually evict old bans (requires confirmation)
  - `--count N`: Limit eviction to N IPs
  (`cli/lib/nftban/cli/cmd_cleanup.sh`)

- **Memory protection health check** - New health check section shows:
  - Current memory pressure level
  - Protection activation state
  - Permanent ban statistics
  - CIDR limits and current usage
  (`cli/lib/nftban/core/nftban_health_checks.sh:nftban_health_check_memory_protection()`)

- **Protection info in status** - `nftban status` now shows memory pressure level (if not
  normal), protection activation state, and permanent ban count
  (`cli/lib/nftban/cli/cmd_status.sh`)

- **New Prometheus metrics** - Comprehensive metrics for monitoring protection state:
  - `nftban_protection_active` - Whether protection is currently active
  - `nftban_protection_feeds_skipped` - Feeds skipped due to memory pressure
  - `nftban_protection_geoban_skipped` - Geoban skipped due to memory pressure
  - `nftban_memory_pressure_level` - Current pressure level (0-3)
  - `nftban_memory_budget_bytes` - Calculated memory budget for CIDRs
  - `nftban_memory_used_percent` - Current memory utilization percentage
  - `nftban_permanent_bans_total` - Total tracked permanent bans
  - `nftban_permanent_bans_protected` - Bans marked as protected
  - `nftban_permanent_bans_evictable` - Bans eligible for eviction (>30d, unprotected)
  - `nftban_cidr_limit_hard` - Current CIDR limit for this server tier
  - `nftban_cidr_current_total` - Current total CIDRs across all sets
  (`pkg/metrics/nftban.go`)

- **Smoke tests for protection commands** - New test suite validates protect/unprotect/cleanup
  commands work correctly with proper --stats and --dry-run behavior
  (`cli/lib/nftban/tests/smoke_test.sh:run_protection_tests()`)

- **Bash completion for new commands** - Tab completion for protect, unprotect, and cleanup
  with all their options (`install/bash-completion/nftban`)

- **Help section for ban management** - New "MEMORY & BAN MANAGEMENT" section in help output
  (`cli/lib/nftban/nftban_help.sh`)

### Changed

- **Sync --quick flag** - Added `--quick` flag to skip feeds and geoban loading during sync.
  Used by postinst to avoid loading heavy data during package installation
  (`cmd/nftband/main.go`)

- **Pre-allocated CIDR slices** - CIDR loading now pre-allocates slices based on expected
  counts, reducing memory allocations and GC pressure during large loads
  (`cmd/nftband/main.go`)

### Fixed

- **Immutable flag detection** - Fixed `lsattr` output parsing to correctly detect immutable
  flag position. Now uses position 5 instead of pattern matching, with proper error logging
  (`cli/lib/nftban/cli/cmd_update.sh:_remove_immutable_flags()`)

- **Sync field names** - Fixed geoban struct field names (IPv4 not IPv4CIDRs) causing empty
  geoban sets after sync (`cmd/nftband/main.go`)

### IPC Methods Added

New daemon IPC methods for permanent ban management:
- `protect_ban` - Mark IP as protected
- `unprotect_ban` - Remove protection from IP
- `get_evictable_bans` - List IPs eligible for eviction
- `evict_old_bans` - Remove old unprotected bans from nftables
- `permanent_ban_stats` - Get total/protected/evictable counts

### Memory Protection Design

The memory protection system follows a conservative approach:
1. Server profile detected at startup (RAM size determines tier)
2. Memory pressure checked before heavy operations
3. Geoban skipped first (largest CIDR count, often 20K+ entries)
4. Feeds skipped only under critical pressure
5. All decisions logged with clear pressure level indication
6. Metrics exposed for external monitoring

This prevents OOM kills while maintaining core firewall protection.

---

## [1.8.15] - 2026-02-01

### Critical Memory Leak Fix & Design Gap Corrections

Comprehensive audit identified and fixed critical memory leak in login monitor
and several design gaps causing service failures on fresh installations.

### Fixed

- **CRITICAL: Memory leak in loginmon** - `runJournalWatcher()` did not close stdout pipe
  on context cancellation, causing FD leak and kernel buffer accumulation. Labs showed
  439MB RAM usage (20x normal) after extended runtime. Added `defer stdout.Close()` to
  properly release resources (`pkg/loginmon/module.go:569`)
- **Whitelist.conf false warning** - Go code logged WARNING for optional `whitelist.conf`
  file that doesn't exist by design. Changed to only warn if file exists but has errors,
  silent for `os.IsNotExist` (`pkg/whitelist/loader.go:51`)
- **Rollback timer auto-enable** - `nftban-rollback.timer` had `WantedBy=timers.target`
  causing it to start on boot before `backup.rules` exists. Disabled auto-enable; timer
  is now only started by `nftban-apply` (`install/systemd/nftban-rollback.timer:39`)

### Added

- **Snapshot command** - Created `cmd_snapshot.sh` to implement `nftban snapshot` command.
  Previously only existed as `nftban stats snapshot` but systemd service called
  `nftban snapshot create`. New command wraps snapshot functionality with create/list
  subcommands (`cli/lib/nftban/cli/cmd_snapshot.sh`)

### Packaging - DEB Fixes (Debian/Ubuntu)

- **Immutable flag protection** - DEB postinst now sets immutable flag on security-critical
  files (`nftban.conf`, `nft_schema.sh`) after install, matching RPM behavior. prerm removes
  flags before upgrade (`packaging/deb/postinst`, `packaging/deb/prerm`)
- **python3-pip dependency** - Added `python3-pip` to Recommends for yq installation during
  documentation generation (`packaging/deb/control`)

### Packaging - RPM Fixes (EL9/Rocky/AlmaLinux)

- **%posttrans scriptlet** - Added post-transaction scriptlet that runs after all RPM operations
  complete, re-applies immutable flag and runs health check for safety
  (`install/packaging/rpm/nftban.spec`)
- **Service restart on upgrade** - RPM now restarts running services after upgrade using
  `try-restart`, matching DEB behavior (`install/packaging/rpm/nftban.spec %postun`)

### Panel - cPanel Integration

- **cPHulk conflict detection** - `nftban panel cpanel enable` now checks if cPHulk brute-force
  protection is enabled and warns about potential conflicts with NFTBan login monitoring.
  Provides recommendations to disable either cPHulk or NFTBan login monitor
  (`cli/lib/nftban/lib/nftban_panel_cpanel.sh`)

### Feeds/Geoban - Timeout Fix

- **IPC timeout increased** - Default IPC client timeout increased from 30s to 90s to handle
  larger operations including feeds loading and geoban CIDR loading. Feeds loading formula
  changed from `30+entries/100` to `90+entries/30` seconds, giving 243s for 4600 CIDRs
  instead of 76s. Cap increased from 5 to 10 minutes. Fixes "i/o timeout" errors during
  feeds and geoban loading on all labs (`pkg/ipc/client.go`, `cmd/nftban-core/cmd_feeds.go`)
- **Sync timeout extended** - `nftban sync` command now sets 5-minute timeout for full sync
  operations that include geoban CIDRs (20,000+ entries for CN,RU,UA). Previously used
  default 90s timeout which was insufficient for large CIDR sets requiring merge operations
  (`cmd/nftban-core/cmd_sync.go`)

### Testing - Smoke Test Enhancement

- **Feeds/Geoban nft validation** - `nftban smoke` now validates that feeds and geoban CIDRs
  are actually loaded in nftables blacklist sets, not just that config files exist. Tests
  IPv4 and IPv6 sets with element count verification. Included in `--full` and `--all` modes.
  (`cli/lib/nftban/tests/smoke_test.sh`)

### Critical Fix - Sync Now Loads Feeds and Geoban

- **Sync includes feeds and geoban** - `nftban sync` now loads threat feeds and geoban CIDRs
  into nftables blacklist sets if enabled. Previously only synced whitelist.d/blacklist.d
  config files. Output shows feeds/geoban counts loaded.
  (`cmd/nftband/main.go`, `cmd/nftban-core/cmd_sync.go`)

### Root Cause Analysis

| Issue | Labs Affected | Root Cause |
|-------|---------------|------------|
| Memory leak (439MB) | lab4 | Unclosed journalctl stdout pipe |
| OOM kill | lab2 | Same leak + low memory + Plesk |
| Rollback loop | lab3, lab4 | Timer auto-enabled, no backup.rules |
| Snapshot failure | ALL | Missing cmd_snapshot.sh |
| Whitelist warning | lab1 | WARNING on optional missing file |
| DEB immutable missing | lab, lab2 | postinst lacked chattr +i (RPM had it) |
| RPM no restart on upgrade | lab1, lab3, lab4 | %postun lacked try-restart |
| cPHulk conflict | lab4 (cPanel) | No detection of competing brute-force protection |

---

## [1.8.14] - 2026-01-31

### GeoIP Database Detection Fix

Fixed metrics collectors reporting incorrect GeoIP database age when using DBIP databases.

### Fixed

- **GeoIP database lookup** - Metrics collector and unified exporter only searched for
  `GeoLite2-Country.mmdb`, causing "GeoIP database outdated" false alarms when using
  DBIP databases (`dbip-country-lite.mmdb`). Both database types now searched in order:
  - `dbip-country-lite.mmdb` (preferred - free, no registration)
  - `GeoLite2-Country.mmdb` (legacy - requires MaxMind registration)
- **Unified exporter GeoIP check** - Component detection and metrics collection now
  search for both DBIP and GeoLite2 databases in multiple paths

### Files Changed

- `cli/lib/nftban/exporters/nftban_metrics_collector.sh` - Added DBIP to search paths
- `cli/lib/nftban/exporters/nftban_unified_exporter.sh` - Added DBIP to component check and metrics

---

## [1.8.13] - 2026-01-31

### Packaging & Path Alignment Release

Comprehensive audit and fixes for path inconsistencies between install.sh, DEB, and RPM packaging.
All CLI and helper script paths now aligned across all installation methods.

### Fixed

- **DEB CLI path** - DEB packaging installed CLI to `/usr/bin/nftban` instead of `/usr/sbin/nftban`.
  Now consistent with RPM, install.sh, and systemd services (`packaging/build_nftban.sh`)
- **Missing helper scripts in packages** - DEB and RPM builds were missing helper scripts in
  `/usr/lib/nftban/sbin/` (queue-processor, rollback, service-alert, etc.). Services like
  `nftban-queue.service` and `nftban-rollback.service` failed on package installs
- **Rollback service path** - `nftban-rollback.service` referenced `/usr/sbin/nftban-rollback`
  but script is at `/usr/lib/nftban/sbin/nftban-rollback`
- **Config readonly conflict** - Scripts setting `readonly NFTBAN_LIB_DIR` before sourcing config
  caused "readonly variable" errors. Config now uses `:=` conditional assignment pattern
- **Queue processor readonly** - `nftban-queue-processor` unconditionally set readonly variables,
  conflicting with config. Changed to conditional `[[ -z "${VAR:-}" ]] && readonly VAR=` pattern
- **panelctl default path** - `nftban-panelctl` had wrong default `/usr/bin/nftban`, fixed to
  `/usr/sbin/nftban`

### Added

- **Boot delay mechanism** - `nftban-firewall-init.service` now deployed via install.sh with
  `NFTBAN_STARTUP_DELAY` config option. Set to 300 for 5-minute troubleshooting window at boot
- **Emergency disable documentation** - Config now documents emergency options:
  - `NFTBAN_STARTUP_DELAY=300` for boot delay
  - `nftban disable all` for complete disable
  - `nftban=disabled` kernel parameter for single-boot disable

### Path Alignment Summary

| Component | Path | install.sh | DEB | RPM |
|-----------|------|------------|-----|-----|
| CLI | `/usr/sbin/nftban` | ✓ | ✓ | ✓ |
| nftban-core | `/usr/lib/nftban/bin/` | ✓ | ✓ | ✓ |
| nftband | `/usr/lib/nftban/bin/` | ✓ | ✓ | ✓ |
| Helper scripts | `/usr/lib/nftban/sbin/` | ✓ | ✓ | ✓ |

---

## [1.8.2] - 2026-01-29

### Update System Stability Release

Comprehensive fixes for `nftban update` across all install types (RPM, DEB, Git).
Tested on Debian 12, Ubuntu 24.04, AlmaLinux 9, Rocky 9.

### Fixed

- **DEB install IFS bug** - `dpkg -i` command failed because `IFS=$'\n\t'` (no space) prevented
  word splitting. Fixed by using bash array: `local -a dpkg_cmd=(dpkg -i)` with `"${dpkg_cmd[@]}"`
  expansion (`cmd_update.sh`)
- **SHA256 verification pipefail** - `grep` returning exit code 1 on "no match" triggered `set -o pipefail`
  exit. Fixed with `|| true` pattern (`download-binaries.sh`)
- **Verify function early exit** - `set -e` caused script exit on non-zero verify return. Fixed with
  `|| result=$?` pattern to capture return codes (`download-binaries.sh`)
- **INI config parse error** - Bash tried to source `[section]` headers from INI-style configs in
  `conf.d/`. Fixed by skipping files containing `^\[` pattern (`cli/sbin/nftban`)
- **Path inconsistency** - 31 files had hardcoded `/usr/bin/nftban` instead of `/usr/sbin/nftban`.
  Migrated all to consistent `/usr/sbin` path
- **Cleanup on SKIP_INSTALL** - Download script deleted binaries even when `SKIP_INSTALL=1`.
  Fixed to skip cleanup when flag set (`download-binaries.sh`)

### Added

- **Distro config at CLI startup** - Main CLI now loads distro config via `nftban_distro_init()`
  for path resolution (`cli/sbin/nftban`)
- **nftban_cli path in distro configs** - All 12 distro configs now include `nftban_cli = /usr/sbin/nftban`
- **Enhanced support bundle** - `nftban support` now collects 8 additional diagnostic categories:
  - `install/` - Install type detection (rpm/deb/git)
  - `binaries/` - Binary locations, versions, CAP_NET_ADMIN capabilities
  - `distro/` - OS detection, distro config matching
  - `fhs/` - FHS directory structure verification
  - `lists/` - Whitelist/blacklist file contents
  - `geoip/` - GeoIP database info and age
  - `daemon/` - nftband socket and service status
  - `activity/` - Recent bans, feed status

### Tested

| OS | Install Type | Result |
|-----|--------------|--------|
| Debian 12 | DEB | ✓ |
| Ubuntu 24.04 | Git | ✓ |
| AlmaLinux 9 | RPM | ✓ |
| Rocky 9 | Git | ✓ |

---

## [1.8.0] - 2026-01-28

### Netlink Architecture Consolidation

Major architectural change: nftables operations consolidated from CLI shelling (`exec.Command("nft")`)
to netlink protocol (`google/nftables`) for ~50x performance improvement and single point of truth.

### Architecture

- **nftbackend netlink refactor** - `pkg/nftbackend/backend.go` now uses `pkg/sync/NFTManager` netlink
  connection instead of forking `nft` CLI for each operation. Ban/unban operations drop from 5-10ms to <1ms
- **Shared NFTManager** - Single netlink connection reused across all operations (ban, unban, add, delete, flush)
- **Cached tables/sets** - Pre-cached nftables objects on daemon startup for zero-lookup hot path
- **ApplyRuleset CLI fallback** - Ruleset file loading (`nft -f`) still uses CLI as netlink doesn't support .nft files

### Performance

| Operation | Before (CLI) | After (Netlink) | Improvement |
|-----------|--------------|-----------------|-------------|
| Single ban | 5-10ms | <1ms | ~50x |
| Batch 1000 bans | 5-10 seconds | <100ms | ~100x |
| Memory per op | Fork overhead | Zero | - |

### Security

- **Command injection eliminated** - No string concatenation for nft commands; binary netlink protocol
- **Single write authority** - All nftables writes still serialized through `Backend.mu` mutex
- **Graceful fallback** - If netlink fails, `CheckIP()` and `HealthCheck()` fall back to CLI

### Changed

- **pkg/nftbackend/backend.go** - Complete rewrite to use `nftsync.NFTManager`
- **New methods**: `GetNFTManager()` exposes underlying manager for advanced sync operations,
  `InvalidateCache()` clears cached objects after external nftables modifications

### Fixed

- **Health check FHS detection** - Added runtime directory ownership checks (`/run/nftban`, `/var/log/nftban`, `/var/cache/nftban`)
- **Health auto-heal tmpfiles** - Uses `systemd-tmpfiles --create` as PRIMARY fix method (FHS-correct)
- **Exporter nft syntax** - Fixed `nft list sets` command syntax error in extended metrics collection
- **Exporter awk mktime** - Replaced date fork with pure awk `mktime()` for ban log parsing (was causing 60s timeout)
- **Exporter TasksMax** - Increased from 10 to 32 to prevent deadlock under systemd sandbox
- **Zabbix gate logic** - Unified exporter now checks all 4 export targets independently (was blocking Zabbix when `NFTBAN_METRICS_ENABLED=false`)

---

## [1.7.0] - 2026-01-28

### Dependency Architecture Redesign

Minimal core install with feature-gated prerequisites. Install no longer silently pulls optional
packages (suricata, prometheus, node_exporter, ncat). Feature dependencies are checked and reported
at enable time via distro-aware hints.

### Architecture

- **Shared prereq library** (`nftban_prereq.sh`) - Capability-based prerequisite checker with
  distro-aware package suggestions via `nftban_distro_get_package()`. Checks binaries not packages.
  Functions: `nftban_prereq_require_cmd()`, `nftban_prereq_require_any_cmd()`,
  `nftban_prereq_require_file()`, plus feature-specific convenience checks for suricata, zabbix,
  rbl, mail, and geoban
- **CORE dependency contract** - Only 6 packages required at install: `nftables`, `jq`, `socat`,
  `curl`, `wget`, `git`. Everything else is feature-gated
- **Feature-gated enable checks** - `nftban geoban enable` checks for `nftban-core` binary,
  `nftban rbl enable` checks for DNS tool (`host`/`dig`/`nslookup`),
  `nftban login enable` warns if no mail transport agent

### Changed

- **install.sh** - `required_packages` trimmed to core only (nftables, jq, socat, curl, wget, git).
  Removed `suricata`, `suricata_update` from required. Removed entire `optional_packages` array
  (was silently installing prometheus, node_exporter, ncat)
- **RPM spec** - Removed `python3-pip`, `python3`, `ipset` from Requires. Removed `nmap-ncat`
  from Recommends. Added `wget` to Requires
- **DEB control** - Removed `python3-pip`, `python3`, `ipset` from Depends. Removed `ncat`
  from Recommends. Added `wget` to Depends
- **Health check binaries** - Added `socat` and `git` to required binary check array to match
  core contract
- **6 feature commands** - All source `nftban_prereq.sh` for consistent pattern:
  `cmd_ddos.sh`, `cmd_portscan.sh`, `cmd_login.sh`, `cmd_geoban.sh`, `cmd_feeds.sh`, `cmd_rbl.sh`

### Fixed

- **Go vet: nftban-ui version shadowing** - Local variable `version` in `cmd/nftban-ui/main.go`
  shadowed the `pkg/version` import, causing `version.Version` to resolve to `(*bool).Version`.
  Renamed to `showVersion`
- **shellcheck SC2034: cmd_status.sh** - Removed unused `ncat_pkg` variable in Zabbix transport
  check (status display only needs `[NO TRANSPORT]` flag)

---

## [1.6.1] - 2026-01-27

### Security Maintenance Release

Comprehensive system-wide audit using 13 parallel AI agents. All findings validated against code.
Covers security fixes, daemon hardening, configuration consistency, packaging, and operational improvements.

### Security Fixes (CRITICAL)

- **Daemon whitelist bypass** - `handleBanRequest()` and EventBan subscriber now check whitelist
  before banning (defense-in-depth: whitelisted IPs can no longer be banned via daemon IPC or modules)
- **JSON injection in IPC client** - All `printf`-based JSON construction in `nft_ipc.sh` replaced
  with `jq -nc` for proper escaping (prevents parameter injection via ban reason/source fields)
- **X-Forwarded-For IP spoofing** - `GetClientIP()` now only trusts proxy headers from
  loopback/private networks (prevents whitelist bypass via forged headers)
- **NFTBAN_METRICS_MODE corruption** - `nftban metrics disable` now sets `NFTBAN_METRICS_ENABLED="false"`
  instead of corrupting `NFTBAN_METRICS_MODE` to `"false"` (mode should only be "unified" or "legacy")

### Security Fixes (HIGH)

- **GeoIP lookup in daemon** - Ban logging now performs `geoip.LookupIP()` instead of hardcoding
  `"UNK"` as country code in both EventBan subscriber and IPC handler
- **Update mechanism** - Added `--fail` flag to curl calls (detect HTTP 404/500 errors),
  fixed health check exit status bug (`|| true` was overwriting `$?`),
  added service restart after successful package update
- **Systemd references** - Fixed exporter service referencing non-existent `nftban.service`
  (changed to `nftband.service`), synced geoip service `Requires=` directive

### Bug Fixes (CRITICAL)

- **Persistent offender escalation dead code** - `cmd_ban.go` line 127 gated escalation behind
  `source == "fail2ban"` which was removed in v1.0. ALL temp ban sources (loginmon, portscan,
  ddos, suricata, manual) now trigger persistent offender escalation check
- **Daemon EventBan missing escalation** - Module-initiated bans (via EventBan event bus)
  had zero escalation logic. Added `checkAndEscalate()` to daemon: after each temp ban,
  counts recent bans per IP from bans.log against conf.d/persistent.conf thresholds,
  auto-escalates to permanent ban with blacklist.d persistence when threshold exceeded
- **Persistent config path wrong** - `pkg/persistent/config.go` looked for
  `/etc/nftban/persistent.conf` instead of `/etc/nftban/conf.d/persistent.conf`
  (inconsistent with all other conf.d/*.conf files). Fixed to use `conf.d/` path
- **Missing persistent.conf template** - Created `install/config/conf.d/persistent.conf`
  with documented defaults (threshold=10, period=24h) and per-filter override sections.
  User customizations go in `persistent.conf.local` (survives upgrades)

### Bug Fixes

- **CLI login restart service path** - `nftban login restart` only checked `/etc/systemd/system/`
  for service file, but packages install to `/lib/systemd/system/`. Now checks all 3 systemd
  paths matching the pattern used by enable/disable/health-fix commands
- **Health: FHS module missing severity** - `nftban_health_check_fhs()` returned WARNING when
  the FHS report module was missing/unloadable, now correctly returns ERROR (validation skipped)
- **Health: Polkit auto-heal parameter** - Polkit check used `NFTBAN_HEALTH_AUTO_HEAL` env var
  (never set) instead of the `auto_heal` function parameter passed through the health chain
- **Health: Metrics config error handling** - Consistent error suppression for both
  `metrics.conf` and `metrics.conf.local` loading (prevents health check from failing on
  syntax errors in optional config)
- **CI: Go version mismatch** - All GitHub Actions workflows used Go 1.21/1.22 but `go.mod`
  declares `go 1.23.0` and `templ v0.3.977` requires >= 1.23. Auto-toolchain switch to
  go1.24.12 failed with "no such tool compile". Updated all workflows to Go 1.23
- **Bans.log field parsing** - Fixed field positions across stats, UI handler, and email reports
  (`ip=$2` → `ip=$4` to match canonical `DATE|TIME|SOURCE|IP|COUNTRY|STATUS|REASON` format)
- **Login bans.log integration** - Added `nftban_login_write_bans_log()` function for central logging
- **Stats temp count** - Fixed "IPv4: 2 (perm: 0, temp: 3)" inconsistency
  (`grep -c "timeout"` → `grep -oP 'timeout \d+[smhd]' | wc -l`)
- **Triple logging** - Removed duplicate `banlog.LogBan()` call in `cmd_ban.go` and
  duplicate `EventBan` publish in `nftband/main.go`
- **Config naming** - Fixed `NFTBAN_BANS_LOG` → `NFTBAN_BAN_LOG` in `nftban_login_alert.sh`
- **DEB postinst** - Fixed version detection loop using hardcoded path instead of loop variable
- **DEB upgrade fails on immutable nft_schema.sh** - `nft_schema.sh` is protected with `chattr +i`
  for security, but dpkg cannot create backup links of immutable files. Fixed: `_remove_immutable_flags()`
  now called for ALL update paths (DEB, RPM, git, local), not just force mode. DEB preinst now
  verifies the flag was actually removed and aborts with clear instructions if not. `install.sh`
  also removes the flag before overwriting files during upgrade
- **Zabbix types.go rune conversion** - `StringValue()` used `string(rune(v.(int)))` which produces
  Unicode characters instead of numeric strings (e.g., 123 becomes `{`). Fixed to use `fmt.Sprintf`
- **CI health check false positive** - `go vet` check captured `go: downloading` module messages
  via `2>&1` and treated non-empty output as failure. Now filters download messages and checks exit code
- **VERSION file out of sync** - VERSION said 1.4.0 while CHANGELOG was at 1.6.1 and latest release
  was v1.5.0. Bumped to 1.6.1. Fixed hardcoded versions in packaging specs and build scripts
- **version.go hardcoded Major/Minor/Patch** - Functions returned hardcoded 1/0/5 instead of
  parsing from the Version variable. Now dynamically parses the ldflags-injected version string

### Features

- **Health auto-heal** - Added `nftband.service` and `nftband.socket` to health check mechanism
  with auto-start capability
- **Feed timer conditional** - Feed and GeoIP timers now only enabled when their feature
  is enabled (`NFTBAN_FEEDS_ENABLED=true` / `NFTBAN_GEOIP_ENABLED=true`)
- **Search GeoIP** - Search command now shows country, geoban status, and CIDR range matches
- **Search CIDR containment** - `nftban search` finds IPs within CIDR ranges in feeds
- **SSH port auto-cleanup** - Tracks old SSH port in state file, auto-removes from whitelist on change
- **Feed CIDR merging** - Added `_feeds_merge_cidrs()` to resolve "conflicting intervals" nftables errors
- **Update repair command** - `nftban update repair` fixes broken dpkg + immutable flags
- **Update force mode** - `nftban update force` with `--force-overwrite`
- **iptables detection** - Differentiates iptables-legacy (cPHulk, safe) from iptables-nft (conflicts)
- **Health: FHS compliance check** - `nftban_health_check_fhs()` now integrated into main health flow,
  validates all 75 FHS directories for permissions, ownership, and existence
- **Health: NFT schema validation** - `nftban_health_check_nft_schema()` validates nftables tables,
  sets, chains, set types/flags, and security-critical rule order (blacklist before established)
- **Health: Polkit validation** - `nftban_health_check_polkit()` now called in main health flow,
  validates all 3 polkit rule files (operator/auditor/panel) plus service status
- **Health: nftables auto-heal** - `nftban_health_fix_nftables()` auto-creates missing tables,
  sets, and chains from canonical schema (nft_schema.sh), reports deprecated tables
- **Health: Polkit auto-fix** - `nftban_health_fix_polkit()` installs/repairs missing polkit
  rule files (10-nftban-systemd, 20-nftban-auditor, 30-nftban-panel), fixes permissions,
  removes obsolete pre-v1.0.19 rules, restarts polkit service. Available via
  `nftban health fix polkit` and `nftban health fix all`
- **Health: nftables fix target** - `nftban health fix nftables` now available as standalone
  fix target (previously only ran via `fix all` or auto-heal)

### Packaging

- **DEB conffiles** - Created `nftban.conffiles` listing all 58 configuration files for proper
  dpkg config file preservation across upgrades (was completely missing)
- **DEB dirs** - Added missing directories to `nftban.dirs`: geoban, geoip, rbl, and all 8
  panel subdirectories
- **RPM spec** - Added missing `%config(noreplace) /etc/nftban/update.conf`
- **Config registry** - Added 7 missing entries: `nftban.conf`, `update.conf`, `feeds.conf`,
  `watchdog.conf`, `rbl/rbls.conf`, `rbl/custom.conf`, `rbl/watchlist.conf` (schema v1.0.32)

### Maintenance

- **Metrics: Pro integration docs** - Added Pro mode documentation to `metrics.conf` remote
  submission section, clarifying that Pro module reads local data files independently
- **Metrics: Registry clarification** - Corrected `bans_total` duplicate report (they use different
  subsystems: operations, analytics, loginmon, portscan - NOT duplicates), reclassified 68
  "unspecified" metrics as "planned" (phase 3-5)
- **Config: Pro API endpoints** - Added `NFTBAN_PRO_INGEST_URL` and `NFTBAN_PRO_ANALYSIS_URL`
  endpoints, submission interval, and IP hashing privacy control to `nftban.conf`
- **Config: Pro registry** - Added all 12 `NFTBAN_PRO_*` variables to `config-registry.json`
  under new "pro" category

### Audit Findings (Documented for Future)

**Packaging Drift** (3 paths: install.sh/DEB/RPM):
- Group model inconsistency (1/2/3 groups depending on path)
- Binary path divergence (`/usr/local/bin/` vs `/usr/lib/nftban/bin/`)
- install.sh lacks auto-whitelist (lockout risk), uses 0775 permissions
- Polkit rules file names differ between install.sh and packages

**Configuration Registry**:
- Schema covers only 15/307+ defined variables
- Module-specific config loading patterns inconsistent
- Safe config parser exists but not enabled by default

**Operational**:
- No IPC rate limiting on daemon socket
- HTTP API (port 8080) binds to all interfaces
- Emergency nft calls use variable interpolation
- Self-ban protection only at install time

## [1.6.0] - 2026-01-25

### Architecture Cleanup Release

This release simplifies the metrics architecture by removing unused components and establishing a clear backend model.

### Removed
- **VictoriaMetrics support** - Framework was 0% operational, added unnecessary complexity
  - Removed 15+ VM-specific config variables
  - Removed 804 lines from cmd_metrics.sh (VM options, modes, commands)
  - Removed agent/storage model complexity
- **Legacy systemd exporter units** - Replaced by unified exporter
  - Deleted: nftban-metrics-exporter.service/.timer
  - Deleted: nftban-zabbix-exporter.service/.timer
  - Deleted: nftban-connector-exporter.service/.timer
- **Legacy Zabbix exporter** - nftban_zabbix_exporter_legacy.sh (39KB dead code)
- **Legacy Web UI** - /web/ directory replaced by GOTH GUI v1.1.0

### Changed
- **Unified Exporter** is now the ONLY metrics exporter
  - Single collection pass, multiple export targets
  - 66% reduction in collection overhead
- **Prometheus export** is now OFF by default
  - Auto-enables only when node_exporter textfile collector detected
  - Our backend (stats.json + bans.log) is the default
- **JSON cache** expanded with memory and network metrics
- **Stats functions** optimized with cache-first pattern
- **Health checks** updated to reference only unified exporter

### Fixed
- install.sh no longer installs conflicting timer systems
- Fresh install now works correctly with unified exporter only
- 34+ shell scripts updated to use unified exporter references

### Documentation
- Clarified: NFTBan does NOT require Prometheus
- Clarified: Prometheus export is an optional compatibility adapter
- Our backend: stats.json (cache) + bans.log (history)

## [1.5.0] - 2026-01-25

### Added

#### Unified Metrics Architecture (SINGLE SOURCE OF TRUTH)
- **Complete metrics redesign**: One collector, one cache, multiple exporters
  - `nftban_unified_exporter.sh` - Single collector for all metrics
  - JSON cache at `/var/cache/nftban/metrics/stats.json` (schema v2.0)
  - No database required - simple file-based storage
  - Collection groups: live (60s), extended (5min), inventory (1hr)

- **Dedicated metrics configuration**: `conf.d/metrics.conf`
  - 40+ configuration variables for metrics tuning
  - Component auto-detection (auto/enabled/disabled)
  - Backend architecture settings (Prometheus, VictoriaMetrics)
  - Collection intervals and performance tuning

- **IPv4/IPv6 separation throughout**:
  - Blacklist: `ipv4.total`, `ipv4.permanent`, `ipv4.temporary` (same for IPv6)
  - Feeds: `ipv4_total`, `ipv6_total`, `ips_total`
  - Whitelist: `ipv4`, `ipv6`, `total`
  - Consolidated totals computed from separate counts

- **Ban audit trail with reason field**:
  - New log format: `DATE|TIME|SOURCE|IP|COUNTRY|STATUS|REASON`
  - `LogBanWithReason()` and `LogUnbanWithReason()` in banlog.go
  - Reason field sanitized (pipes replaced with dashes)

- **Suricata source tracking**: Added to all ban source breakdowns

### Changed

#### nftban_stats.sh - Unified Cache Integration
- All stats functions now read from unified cache first:
  - `nftban_stats_count_active_bans()` → `.blacklist.total`
  - `nftban_stats_count_whitelist()` → `.whitelist.total`
  - `nftban_stats_ban_sources()` → `.bans_by_source.*`
  - `nftban_stats_count_bans()` → `.activity.bans_*`
  - `nftban_stats_count_unique_ips()` → `.activity.unique_ips*`
- Dashboard uses cache for blacklist, feeds, geoban, modules
- Fallback to direct queries only when cache unavailable/stale

#### Log Rotation
- Added `bans.log` to logrotate configuration
- Uses `copytruncate` (safe for processes with open file handles)
- Weekly rotation, 12 weeks retention, 10MB size trigger
- Prevents race conditions between rotation and metrics collection

### Fixed
- **banlog.go**: `LogBanWithReason()` now actually stores the reason (was ignored)
- **Config cleanup**: Removed 90 duplicate lines from nftban.conf
- **Race condition**: Metrics collection no longer affected by log rotation

### Architecture Benefits
- **No database**: JSON file cache eliminates SQLite/external DB dependency
- **No separate agents**: Single unified exporter replaces multiple collectors
- **66% overhead reduction**: Collect once, export to all targets
- **Consistent timestamps**: All exporters use same collection data
- **Full audit trail**: Every ban/unban with timestamp, source, country, reason

## [1.4.0] - 2026-01-24

### Added

#### Central Metrics Collector Architecture (MAJOR REDESIGN)
- **New architecture**: Collect once, export to many backends
  - `nftban_metrics_collector.sh` - Central collector with smart caching
  - Dynamic metrics collected every run (bans, status, memory, load)
  - Inventory metrics collected hourly (OS, IPs, hardware - static data)
  - Output: `/var/cache/nftban/metrics/{dynamic,inventory,combined}.json`

- **New Zabbix exporter v2**: Reads from central collector
  - Slim, efficient - no duplicate collection code
  - 76+ metrics including new watchdog/runtime metrics
  - Same Zabbix protocol, better architecture

- **New watchdog integration** via IPC:
  - Runtime: `goroutines`, `heap_mb`, `alloc_mb`, `sys_mb`, `gc_cycles`, `gc_pause_ms`
  - Throughput: `bans_total`, `unbans_total`, `events_total`, `bans_per_min`
  - IPC: `requests_total`, `avg_latency_ms`, `errors_total`
  - System: `mem_used_percent`, `iowait_percent`, `disk_used_percent`

- **Extended network metrics**:
  - Per-interface: `rx_bytes`, `tx_bytes`, `rx_packets`, `tx_packets`
  - Connections: `active`, `established`, `time_wait`, `close_wait`

- **Extended inventory for Zabbix**:
  - IPv6 address, MAC address, subnet mask, gateway
  - Full networks JSON with all IPs
  - Zabbix inventory auto-population

### Changed
- **Zabbix exporter**: Unified v2.0.0 exporter (legacy removed)
- **Metrics collection**: Smart separation - dynamic vs static/inventory
- **Performance**: Inventory collected hourly, not every minute

### Benefits
- **No duplicate code**: Central collector is the single source of truth
- **Easy backend addition**: Just read JSON, format for your backend
- **Consistent metrics**: Same data across Zabbix, Prometheus, InfluxDB
- **Reduced overhead**: Static data collected hourly, not every minute

## [1.3.0] - 2026-01-22

### Added

#### Zabbix Exporter
- **Full Zabbix integration**: Native trapper protocol support for metrics export
  - Multi-target support with failover modes (all, primary, failover)
  - TLS/PSK encryption for secure communication
  - Low-Level Discovery (LLD) for dynamic entities (modules, interfaces, countries, feeds, timers)
  - 85+ metrics covering daemon, runtime, bans, events, feeds, geoban, nftables
  - Batch sending with configurable intervals and retry logic

- **Zabbix templates**:
  - `nftban_template_5x.xml` - Zabbix 5.x compatible XML template
  - `nftban_template_6x.yaml` - Zabbix 6.x+ native YAML template
  - Pre-configured items, triggers, graphs, and discovery rules

- **CLI command** `nftban zabbix`:
  - `setup` - Interactive setup wizard with auto-firewall
  - `status` - Show exporter status and target health
  - `test` - Test connectivity to Zabbix server
  - `push` - Manual metric push
  - `discover` - Trigger LLD data send
  - `config` - Show/enable/disable configuration
  - `template` - Export Zabbix templates (XML/YAML)
  - `targets` - Manage multiple Zabbix targets

- **Auto-firewall configuration**:
  - `NFTBAN_ZABBIX_FIREWALL_AUTO=true` - Automatically opens outbound port 10051
  - Firewall rule added on `nftban zabbix setup`, removed on disable
  - Uses nft rules with "zabbix-export" comment for tracking

#### Generic Connectors Framework
- **Elasticsearch connector**: Bulk API support, index templates, ILM policies
  - Configurable index patterns with date-based naming
  - Basic auth and API key authentication
  - TLS support with custom CA certificates

- **Kafka connector**: Pure Go implementation (no cgo dependencies)
  - SASL authentication (PLAIN, SCRAM-SHA-256, SCRAM-SHA-512)
  - Configurable partitioning and batching
  - TLS encryption support

- **NDJSON file connector**: Local file export with rotation
  - Daily and size-based rotation
  - Gzip compression support
  - Configurable retention (days/count)

- **Syslog connector**: RFC 5424 compliant
  - UDP/TCP transport options
  - Configurable facility and severity

- **Webhook connector**: HTTP POST to any endpoint
  - Custom headers support
  - Configurable timeout

- **CLI command** `nftban connector`:
  - `list` - Show configured connectors
  - `add/remove` - Manage connector configurations
  - `enable/disable` - Toggle connectors
  - `status` - Connector health and statistics
  - `test` - Test connector connectivity
  - `push` - Manual data push

#### Unified Exporter
- **Single metric collection**: Collects once, exports to all targets
  - 66% less timer overhead (replaces 3 separate timers)
  - Consistent timestamps across Prometheus, Zabbix, and connectors
  - Smart scheduling with jitter to prevent thundering herd

- **Systemd units**:
  - `nftban-unified-exporter.service` - Oneshot service
  - `nftban-unified-exporter.timer` - 60s interval with 30s jitter
  - Resource limits: 10% CPU, 64MB memory, 30s timeout

#### Health Checks
- **`nftban_health_check_zabbix()`**: Validates Zabbix exporter
  - Checks enabled status, server configuration
  - Tests TCP connectivity to Zabbix server
  - Verifies timer status and TLS/PSK configuration

- **`nftban_health_check_connectors()`**: Validates connector framework
  - Checks enabled connectors (ES, Kafka, File, Syslog, Webhook)
  - Tests Elasticsearch connectivity
  - Verifies output directory permissions

- **Status command integration**: `nftban status` now shows:
  - Zabbix Exporter status with server address
  - Connectors status with enabled count
  - Unified exporter timer in TIMERS section

#### Grafana Dashboard
- **nftban-overview.json**: Pre-built Grafana dashboard
  - System overview panels (uptime, version, health)
  - Ban statistics and trends
  - Module status visualization
  - Event processing metrics

### Changed

- **Configuration pattern**: Standardized `.conf`/`.conf.local` across all modules
  - `.conf` = defaults (overwritten on package update)
  - `.conf.local` = user values (preserved on update)
  - Zabbix now uses central `nftban_config_set()` library
  - Config load order: `zabbix.conf` → `zabbix.conf.local` → bash defaults

- **New config files**:
  - `conf.d/zabbix.conf` - Zabbix exporter defaults (19 settings)
  - `conf.d/connectors.conf` - Connector framework defaults (36 settings)
  - Both installed with 640 permissions (root:nftban)

- **Packaging**: Updated RPM spec and install.sh
  - New directories: `/etc/nftban/connectors`, `/usr/share/nftban/templates/zabbix`
  - Config files: `zabbix.conf`, `connectors.conf` with proper permissions
  - Systemd units: unified-exporter service and timer
  - Version aligned: VERSION file, RPM spec, DEB changelog, FHS spec, README badge

- **Commands registry**: Added zabbix and connector commands
  - Category: `intelligence_reporting`
  - Subcommands properly documented

### Fixed

- **Shellcheck warnings**: Removed unused variables
  - `timer_active` in health checks
  - `mode` now exported as `nftban_mode_info` metric

### Infrastructure

- **Go packages**: 13 new files (~6,400 lines)
  - `pkg/exporters/zabbix/` - 9 files (types, config, protocol, sender, multi, collector, discovery, exporter, http)
  - `pkg/exporters/connectors/` - 4 files (connector interface, ndjson, elasticsearch, kafka)

- **CLI modules**: 3 new files (~2,300 lines)
  - `cmd_zabbix.sh` - Zabbix CLI commands with firewall helpers
  - `cmd_connector.sh` - Connector CLI commands
  - `nftban_unified_exporter.sh` - Unified bash exporter

- **Systemd**: 6 new unit files
  - `nftban-zabbix-exporter.service/.timer`
  - `nftban-connector-exporter.service/.timer`
  - `nftban-unified-exporter.service/.timer`

## [1.2.3] - 2026-01-22

### Added

#### GUI: New Tools/Diagnostics Page
- **Tools page** (`/ui/tools`): New diagnostic tools for firewall management
  - **IP Check/Emulate**: Test if IP would be blocked and see which rule matches
  - **GeoIP Lookup**: Get country, city, ASN information for any IP address
  - **Search All Sets**: Find IP across blacklist, whitelist, feeds, and geoban
  - **Live Log Viewer**: Real-time ban/unban logs with level filtering (BAN, UNBAN, ERROR, WARN)
  - **Quick Actions**: Flush temp bans, reload feeds, sync rules, export bans
  - **CLI Reference**: Quick help for common nftban commands

#### GUI: New Bans and Whitelist Management Pages
- **Bans page** (`/ui/bans`): Full ban management with search, filter, pagination
  - Filter by: All, Temporary, Permanent, From Feeds, GeoBan
  - Add new bans with modal dialog (IP, duration, reason)
  - Unban IPs directly from table
- **Whitelist page** (`/ui/whitelist`): Whitelist management with sources sidebar
  - Add/remove whitelisted IPs and networks
  - Shows whitelist sources (files) with entry counts

#### Performance: Stats Command 14x Faster
- **nftban stats**: Reduced from 28 seconds to 2 seconds
  - Fixed O(n*m) loop in BANS BY MODULE section
  - Now uses O(n+m) awk-based single-pass algorithm
  - Added fast counting functions using nft JSON API

### Changed

#### Architecture: NFTBan Chain Priority Changed to -100
- **Priority before panel firewalls**: Changed NFTBan input/forward chain priority from 0 to -100
  - Ensures NFTBan DROP decisions happen BEFORE any panel firewalls (CSF, Plesk, DirectAdmin)
  - Panel firewalls use priority 0, NFTBan now runs at priority -100 (earlier)
  - Output chain remains at priority 0 (outbound traffic less critical)
  - Updated: `nft_schema.sh`, `nftables.conf`, `structure_default.json`

#### Validation: Priority-Based Safety Instead of Forbidden Tables
- **Smarter panel coexistence**: Replaced "forbidden tables" validation with priority-based check
  - Old: ERROR if `ip filter` / `ip6 filter` tables exist (broke panel servers)
  - New: WARNING if other chains exist, CRITICAL only if they could bypass NFTBan
  - Validation now checks: NFTBan priority < other chain priority on same hook
  - Panels detected: CSF, Plesk, DirectAdmin can coexist safely

### Fixed

#### Spec: Updated to Match Deployed Architecture
- **Deprecated inet tables removed**: Spec now matches actual ip/ip6 nftban deployment
  - Changed from deprecated `inet nftban_main` / `inet nftban_runtime` to `ip nftban` / `ip6 nftban`
  - Set names updated: `whitelist_v4` -> `whitelist_ipv4`, etc.
  - Version bumped to 2.1 with architecture documentation

#### Registry: Fixed Command Discrepancies
- **CLI commands match registry**: Updated `commands.registry.yml`
  - `firewall status` -> `firewall stats` (actual CLI)
  - `permissions audit` -> `permissions check` (actual CLI)

### Infrastructure

#### Lab Servers: Watchdog Timer Fixed
- **lab4 watchdog**: Reset failed systemd timer unit
  - `nftban-watchdog.timer` was in failed state, now active

## [1.2.2] - 2026-01-17

### Fixed

#### Health Check: Timers Not Displayed
- **Timers check hidden**: Timer health check was running but not displayed
  - Added `timers` to render output list in `nftban_health_render.sh`
  - Caused yellow status with no visible warnings

#### Health Check: Feature Timers Incorrectly Required
- **Optional timers as required**: Moved feature-dependent timers to optional list
  - `watchdog`, `feeds`, `metrics-exporter` are now optional
  - Only core timers required: `maintenance`, `health`, `geoip`, `queue`

#### DirectAdmin Panel: Login Monitor Syslog Access
- **logger permission denied**: DirectAdmin uses `mysyslog` group for `/dev/log` socket
  - Added `nftban` user to `mysyslog` group when DirectAdmin detected
  - Fixes: `logger: socket /dev/log: Permission denied`
  - Updated: `install.sh`, `nftban.spec`, `nftban.postinst`

#### RPM Upgrade: Immutable File Handling
- **%pretrans section**: Added Lua script to remove immutable flag before upgrade
  - Fixes upgrade from old versions that don't have `chattr -i` in `%preun`
  - Error was: `cpio: rename failed - No data available`
  - The `nft_schema.sh` file is protected with `chattr +i` for security

#### Missing Dependency: socat
- **IPC communication**: Added `socat` as required dependency
  - Required for CLI communication with `nftband` daemon via Unix socket
  - Updated: RPM spec, install.sh, all 12 distro config files

#### Critical: GeoIP Binary Missing from Installation
- **nftban-geoip binary**: Added to `download-binaries.sh` download, verification, and installation
  - Binary now downloaded alongside nftban-core and nftban-ui
  - Installed to `/usr/lib/nftban/bin/nftban-geoip`
  - Enables full geoban functionality (country-based IP blocking)

#### Metrics Exporter: Arithmetic Syntax Error
- **Non-numeric values in arithmetic**: Fixed bash arithmetic error in Prometheus exporter
  - `get_ban_breakdown()` function failed with: `syntax error in expression`
  - Cause: `wc -l` and `grep -c` outputs may contain newlines/whitespace
  - Added sanitization: `${var//[^0-9]/}` to strip non-numeric characters
  - Affected: IPv4/IPv6 ban counting, feed IP counting

#### Health Check: False Warning for Unconfigured Metrics Backend
- **Prometheus warning with VictoriaMetrics**: Fixed false warning about inactive backend
  - Was warning "Prometheus installed but not running" even when VictoriaMetrics configured
  - Now only warns about backends matching `NFTBAN_METRICS_BACKEND` config
  - Applies to both Prometheus and VictoriaMetrics detection

#### Critical: Arithmetic Bug in GeoBan Module
- **Exit code 1 on first success**: Fixed `((success++))` pattern in `nftban_geoban.sh`
  - Changed to `((++success))` (prefix increment) to avoid exit code 1 when var=0
  - Affected 12 instances across ban/unban/whitelist operations
  - **Root cause**: `((0++))` evaluates to 0, returns exit 1 under `set -e`

#### Version Display Hardcoded
- **API version fallback**: `pkg/api/system_handlers.go` now reads from VERSION file
  - Added `readVersionFromFile()` to read `/usr/lib/nftban/VERSION`
  - Falls back gracefully if file not found
- **UI version fallback**: Changed from hardcoded "v1.0.0" to "Unknown"
- **Install script**: Added VERSION file installation to `/usr/lib/nftban/VERSION`

### Changed

- **Package managers**: Ensured all installation methods (binary, rpm, deb) include VERSION file

---

## [1.2.1] - 2026-01-16

### Added

#### Support Bundle Command (`nftban support`)
- **Automated Diagnostics Collection**: New command to collect all troubleshooting information
  - `nftban support` - Generate full support bundle tarball
  - `nftban support --quick` - Quick terminal diagnostics (no file)
  - `nftban support --network` - Include network info (ip addr, routes, ports)
  - `nftban support-bundle` - Alias for `nftban support`

#### Collected Information
- **Version**: NFTBan version, git commit, VERSION file
- **System**: OS release, kernel, hostname, uptime, memory, SELinux/AppArmor status
- **Virtualization**: Container/VM detection (Docker, KVM, etc.)
- **nftables**: Full ruleset, tables, sets, counters
- **Config**: All config files with automatic secret redaction
- **Logs**: Last 24h journalctl + last 500 lines of log files
- **Health**: `nftban health check` output
- **Status**: `nftban status` output
- **Update**: Update check, backup list, git status
- **Services**: Systemd service status for nftban-* units
- **Network**: IP addresses, routes, listening ports (optional)

#### Security Features
- **Secret Redaction**: API keys, tokens, passwords, auth headers automatically masked
- **Network Exclusion**: Network info excluded by default (use --network to include)
- **Review Reminder**: Warning to review bundle before sharing

#### Documentation Updates
- Updated bug report template with support bundle reference
- Updated SUPPORT.md with support bundle documentation
- Added CLI completions for support/support-bundle commands

### Fixed
- **Shellcheck SC2045**: Replaced `ls` iteration with `find -print0` in `cmd_update.sh`

---

## [1.2.0] - 2026-01-16

### Added

#### Update Command (`nftban update`)
- **Automated Git Updates**: New command to update NFTBan from git repository
  - `nftban update` - Pull latest code, install, run health check
  - `nftban update --check` - Check for available updates (no changes)
  - `nftban update --force` - Force reinstall even if current
  - `nftban update --dry-run` - Preview what would happen
  - `nftban update --rollback` - Revert to previous backup
  - `nftban update --list` - List available backups

#### Update Features
- **Pre-Update Backup**: Automatic tarball backup before updates
- **Backup Rotation**: Configurable backup count (default: 3)
- **Health Check**: Automatic health check after update
- **Rollback Support**: One-command rollback to previous state
- **Dry-Run Mode**: Preview changes without applying

#### Configuration
- New config file: `/etc/nftban/update.conf`
  - `NFTBAN_GIT_REPO` - Git repository path (default: /opt/nftban)
  - `NFTBAN_GIT_REMOTE` - Git remote name (default: origin)
  - `NFTBAN_GIT_BRANCH` - Git branch to track (default: main)
  - `NFTBAN_UPDATE_BACKUP_COUNT` - Backups to keep (default: 3)

---

## [1.1.1] - 2026-01-16

### Fixed

#### Security: Recursive Permission Operations
- **Replaced all `chmod -R` and `chown -R`** with safe alternatives
- Uses `install -d -o -g -m` for directory creation
- Uses `find -maxdepth 1 -exec` for targeted file operations
- Prevents TOCTOU race conditions and symlink attacks
- Files fixed: install_prometheus.sh, install_suricata.sh, install_vmagent.sh,
  install_victoriametrics.sh, provision_grafana_dashboards.sh, nftban_health_fixes.sh,
  nftban_metrics.sh, cmd/nftban-core/install.sh, install-webapi.sh

#### CI/CD
- Added `check_recursive_permissions()` to health check
- Pre-commit hook now blocks recursive chmod/chown

---

## [1.1.0] - 2026-01-15

### Added

#### GOTH GUI - New Web Interface (Phase 1)
- **GOTH Stack**: Go + Templ + HTMX server-side rendering
  - No JavaScript framework complexity
  - Type-safe templates with compile-time checking
  - Progressive enhancement via HTMX
- **Login Page**: PAM-based authentication
  - System user credentials
  - Session-based auth (cookies, not JWT)
  - Secure cookie settings (HttpOnly, Secure, SameSite)
- **Dashboard Page**: Live statistics overview
  - Active bans count
  - Events in last hour
  - Active modules count
  - Whitelisted IPs count
- **Auto-Refresh**: HTMX updates every 5 seconds
- **Dark Theme UI**: Modern responsive design
- **Sidebar Navigation**: Quick access to all sections

#### New Routes
- `GET /ui/login` - Login page
- `POST /ui/action/login` - Login form handler
- `GET /ui/` - Dashboard (requires session)
- `POST /ui/action/logout` - Logout handler
- `GET /ui/frag/summary` - Summary cards fragment (HTMX)

#### New Files
- `internal/ui/layout.templ` - Base HTML layout
- `internal/ui/pages/login.templ` - Login page template
- `internal/ui/pages/dashboard.templ` - Dashboard template
- `internal/ui/pages/inventory.templ` - Inventory page template
- `internal/ui/pages/health.templ` - Health check page template
- `internal/ui/types.go` - Data types for templates
- `cmd/nftban-ui/handlers/goth.go` - GOTH route handlers

#### Build Prerequisites
- `github.com/a-h/templ v0.3.977` - Templ template engine

### Notes
- Legacy SPA GUI still available at `/` (deprecated)
- GOTH GUI accessible at `/ui/`
- API routes unchanged at `/api/v1/`
- Tracking: [GitHub Issue #51](https://github.com/itcmsgr/nftban/issues/51)

---

## [1.0.33] - 2026-01-15

### Deprecated

#### Web GUI (nftban-ui)
- **GUI Marked for Rewrite**: Current SPA-based GUI deprecated
  - Multiple issues: JWT config, TLS setup, broken endpoints, missing configs
  - Will be replaced with GOTH stack (Go + Templ + HTMX) in v1.1.0+
  - Current GUI continues to be shipped but is not production-ready
- **Migration Plan**: Phase-based rewrite starting with v1.1.0
  - v1.1.0: Login + Dashboard (Templ/HTMX foundation)
  - v1.2.0: Ban/Unban/Search functionality
  - v1.3.0: Events/Whitelist management
  - v1.4.0: Modules/Ports management
  - v1.5.0: Panel integration
  - v1.6.0: Advanced features, old GUI removal
- **Tracking**: See [GitHub Issue #51](https://github.com/itcmsgr/nftban/issues/51) for progress updates
- **CLI Unaffected**: Command-line interface remains fully functional

---

## [1.0.32] - 2026-01-13

### Added

#### Panel Auto-Detection and Auto-Enable
- **Installation Panel Detection**: Automatically detects web hosting panels during install
  - cPanel/WHM (`/usr/local/cpanel`)
  - DirectAdmin (`/usr/local/directadmin`)
  - Plesk (`/usr/local/psa`)
  - CentOS Web Panel (`/usr/local/cwpsrv`)
  - CyberPanel (`/usr/local/CyberCP`)
- **Auto-Enable**: Panel ports enabled automatically (no prompt)
- **Panel State File**: Creates `/var/lib/nftban/panels/enabled.conf`
- **Completion Message**: Shows panel-specific commands after installation

#### xtables Compatibility Fix (cPanel/Exim)
- **`check_xtables_compat()`**: Detects xtables compat expressions in nftables.conf
- **Auto-Remove**: Removes `xt target`/`xt match` lines that block native nftables
- **Backup**: Saves original config to `/var/backups/nftban/firewall-migration/`
- **Skip Option**: `--skip-xtables-fix` or `NFTBAN_SKIP_XTABLES_FIX=1` to bypass
- **Resolves**: cPanel mail routing rules using `xt target "REDIRECT"` that break nftables.service

#### Panel-Aware Health Checks
- **Removed `go` from optional binaries**: Not needed (prebuilt packages shipped)
- **Panel-aware mail check**: Don't warn about mail/sendmail on panel servers
  - Panels manage their own mail (Exim via cPanel, etc.)
- **Panel detection in health**: Checks `/usr/local/cpanel`, `/usr/local/directadmin`, `/usr/local/psa`

---

## [1.0.31] - 2026-01-13

### Added

#### Registry Architecture Redesign
- **Unified Registry System**: 4 interconnected registries for complete system metadata
  - `commands.registry.yml` - 51 CLI commands with RBAC, capabilities, audiences
  - `config-registry.json` - 24 config files with mode-aware activation rules
  - `config-schema.json` - 960 config keys with types, defaults, validation
  - `reports-registry.json` - 18 report types with metrics, delivery, API endpoints

#### RBL Module Enhancements (P1)
- **Watchlist Feature** (`nftban rbl watchlist`):
  - Monitor external IPs of interest (customers, partners, infrastructure)
  - Config file: `/etc/nftban/conf.d/rbl/watchlist.conf`
  - Format: `IP|description|tags|notify_email`
  - Per-IP email notification override support
  - Tags: customer, partner, mail, web, critical
- **Parallel DNS Queries**:
  - 10 concurrent DNS queries by default (~15 sec vs 2-3 min)
  - 10-12x faster RBL checks against 41 providers
  - `--sequential` option for old behavior
- **RBL Reports Registry**: Added 4 RBL report types to reports-registry.json
  - `rbl_status` - Monitoring status
  - `rbl_check` - Server IP check results
  - `rbl_watchlist` - Watchlist check report
  - `rbl_alerts` - Alert notifications

#### Health Check - Registry Validation
- **`nftban health registries`**: Validate all registry files
  - JSON/YAML syntax validation
  - File existence checks
  - `--json` output for monitoring integration
- **`cli/lib/nftban/health/check_registries.sh`**: Standalone registry validator

#### Commands Registry Updates
- Added `rbl watchlist` subcommands (list, add, remove, check)
- Added `health registries` and `health install` subcommands
- Added `--sequential` option documentation for RBL commands
- Total commands: 51

### Technical Notes
- Registry validation integrated into nftban-validator (REG-001 through REG-006)
- Deep analysis: `nftban-validator/scripts/validate_registries.sh`
- Production health check: `nftban health registries`

---

## [1.0.30] - 2026-01-12

### Added

#### High-Performance Go Login Detection Engine (Phase 1)
- **New Binary**: `nftban-login-detect` - Go-based auth log stream processor
- **Signal-Based Detection**: `bytes.Contains` prefilter before expensive parsing (SIMD-accelerated)
- **Zero-Copy Processing**: `[]byte` slicing, no string allocation on non-match lines
- **SSH Detector**: First detector implementation with production-proven patterns
  - `Failed password for` - Standard failed login
  - `Invalid user` - Unknown user attempts
  - `Disconnected from ... preauth` - Scanner detection
  - `Too many authentication failures` - Brute force detection
- **Modern IP Handling**: `netip.Addr` for IPv4/IPv6 support (including IPv4-mapped IPv6)
- **Batched Enforcement**: 50-250ms action batching to reduce nftables syscalls
- **Unified Scoring Engine**: Native Go float64 (replaces `bc` subprocess)
- **Integration**: Uses existing `nftban ban` mechanism via IPC

#### Architecture Improvements
- **Detector Interface**: Modular `Detector` interface for easy service extension
- **Cross-Source Correlation Ready**: Foundation for Phase 2 Suricata integration
- **Performance Target**: 100,000+ lines/sec (100x improvement over Bash)

### Unchanged (Scope Validation)
The following modules remain **100% unaffected** by this release:
- **Botscan**: HTTP access log analysis (`cmd_botscan.sh`, `nftban_botscan.sh`)
- **Portscan**: Network port scan detection (`cmd_portscan.sh`)
- **DDoS**: Rate limiting/flood protection (`nftban_ddos.sh`)
- **Panel**: Port management (`cmd_panel.sh`)
- **Pattern files**: All `patterns.d/botscan/` patterns unchanged
- **Suricata mode**: Login Suricata detection deferred to Phase 2

### Technical Notes
- Phase 1 focuses on Classic mode (journalctl-based) login detection only
- Suricata EVE JSON integration planned for Phase 2
- Full architectural review documented in `/home/commonfolder/log_management_nftban/SENIOR_DEVOPS_REVIEW.md`

---

## [1.0.29] - 2026-01-11

### Added

#### New Bot Scanner Module (`nftban botscan`)
- **Webshell Detection**: Detect and block webshell scanner bots (shell.php, c99.php, r57.php)
- **Exploit Probe Detection**: Block CVE exploit probes (Log4j, PHPUnit, CGI-bin)
- **404 Flood Detection**: Track excessive 404 requests as scanner behavior
- **Pattern-Based System**: Simple text file patterns with flexible matching
- **Pattern Categories**:
  - `webshell.patterns` - Backdoor/shell scanners
  - `exploit.patterns` - CVE and vulnerability probes
  - `scanner.patterns` - Directory and file scanners
  - `custom.patterns` - User-defined patterns

#### Bad Bot Detection (User-Agent Based)
- **`badbots.patterns`** - Block aggressive/malicious bots by User-Agent:
  - PetalBot, AwarioBot, MauiBot, DotBot (aggressive crawlers)
  - GPTBot, Bytespider, CCBot (AI training scrapers)
  - masscan, zgrab, sqlmap, nikto, nuclei (security scanners)
  - XRumer, ScrapeBox (spam bots)

#### Pattern Management CLI
- `nftban botscan patterns list` - List all patterns
- `nftban botscan patterns add NAME PATTERN [MATCH_TYPE] [THRESHOLD]` - Add custom pattern
- `nftban botscan patterns enable/disable NAME` - Toggle patterns
- `nftban botscan patterns remove NAME` - Remove custom pattern

#### Bot Scanner Commands
- `nftban botscan enable/disable` - Enable or disable module
- `nftban botscan status` - Show module status and configuration
- `nftban botscan check` - Run manual log analysis
- `nftban botscan history` - Show detection history
- `nftban botscan test [URL|UA] [ua]` - Test pattern matching

#### Match Types
- `url-404` - Match only 404 responses (webshell probes)
- `url-any` - Match any HTTP response
- `url-post` - Match POST requests only
- `url-get` - Match GET requests only
- `useragent` - Match User-Agent header (bad bot detection)

### Fixed
- **Stats BANS BY MODULE**: Use dynamic table name `${NFTBAN_TABLE_IPV4}`
- **Stats arithmetic**: Safe increment for strict mode compatibility

---

## [1.0.28] - 2026-01-11

### Added

#### Prometheus Metrics Integration
- **`/metrics` Endpoint**: Native Prometheus metrics endpoint on nftband HTTP server
- **Ban/Unban Counters**: `nftban_bans_total` and `nftban_unbans_total` with labels:
  - `source`: portscan-classic, loginmon, ddos, manual, etc.
  - `family`: ipv4, ipv6
- **IPC Metrics**: Request counts, latency histograms for daemon communication

#### Journalctl Support for Portscan Detection
- **Systemd-Only Systems**: Full support for Debian 12, Fedora 39+, and other systems without `/var/log/kern.log`
- **Auto-Detection**: Automatically falls back to journalctl when traditional log files don't exist
- **New Config Option**: `PORTSCAN_CLASSIC_USE_JOURNALCTL` (auto/true/false)
- **CLI Commands**: `nftban portscan check` and `nftban portscan sync` for manual log processing

#### Statistics and Tracking
- **Daemon Stats Recording**: All ban events now properly logged to `/var/log/nftban/bans.log`
- **Real-time Metrics**: `current.json` updated with accurate ban/unban counts
- **IPC Request Tracking**: Latency and success rate metrics for daemon communication

#### Security Enhancements
- **Service Security Contract**: Comprehensive capability and permission documentation
- **Security Validator**: `tools/validate-service-security.sh` for compliance checking
- **Gitleaks CI**: Automated secret scanning in CI pipeline

### Fixed

#### Portscan Module
- **Progressive Ban Persistence**: State now saved after each detection cycle, not just on disable
- **Journalctl Silent Failures**: Fixed detection failing silently on systemd-only distributions
- **Empty Array Checks**: Use `declare -p` instead of `-v` for associative array validation

#### Statistics System
- **Daemon Ban Logging**: Fixed `handleBanRequest` and EventBan subscriber missing `banlog.LogBan()` calls
- **Metrics Recording**: Added `RecordBan()`, `RecordUnban()`, `RecordIPCRequest()` calls to daemon handlers
- **Cache Staleness**: Stats cache now properly invalidated (300s TTL)

#### Code Quality
- **Shellcheck Warnings**: Fixed SC1090 (dynamic source) and SC2034 (unused variables) across modules
- **Unused Variables**: Removed `audit_result`, `effective_json`, `cond_code` from config schema module

### Changed
- **Config Schema**: Expanded to 910+ configuration keys with improved validation
- **Whitelist Commands**: Added `nftban whitelist add/remove/list` CLI commands

---

## [1.0.27] - 2026-01-11

### Added

#### Smart Configuration Validation System
- **Schema-Driven Validation**: JSON schema at `/usr/lib/nftban/data/config-schema.json` defines all configuration keys with types, defaults, and constraints
- **Mode-Aware Validation**: Validates only ACTIVE config files based on module MODE settings (classic/suricata/hybrid/auto)
- **New CLI Commands**:
  - `nftban configtest [--verbose] [--json]` - Validate config against schema
  - `nftban configaudit [--json]` - Audit config for drift, deprecated keys, new options
  - `nftban config show` - Display effective merged configuration
  - `nftban config diff` - Show differences from defaults
- **Upgrade Drift Detection**: Tracks new keys added in upgrades, renamed keys, deprecated keys
- **Conditional Requirements**: Keys can be marked required only when other keys have specific values
- **Key Extraction Tool**: `tools/extract-nftban-keys.sh` for automated registry building

#### Configuration Registry Architecture
- **Zero-Registry Discovery**: Filesystem-based config discovery (matches CLI pattern)
- **918 Configuration Keys**: Full inventory across 22 config files
- **Module-Specific Configs**: Proper handling of portscan/ddos/login with classic/suricata variants
- **Panel Integrations**: 8 hosting panels (DirectAdmin, cPanel, CWP, CyberPanel, InterWorx, Vesta, Plesk, Generic)

### Changed
- **Help System**: Added configtest/configaudit to CORE commands section
- **Man Page**: Expanded config command documentation with examples
- **README**: Updated CLI Overview with new config commands (49 total commands)

### Configuration
New validation infrastructure:
```bash
# Validate all configuration
nftban configtest --verbose

# Audit for drift and changes
nftban configaudit

# Show effective merged config
nftban config show
```

Exit codes for configtest:
- 0 = OK (no issues)
- 1 = Warnings present
- 2 = Errors present
- 3 = Critical errors

---

## [1.0.26] - 2026-01-10

### Added

#### FHS Single Source of Truth Architecture
- **Canonical YAML Spec**: `build/fhs-spec.yaml` is now the single source of truth for all FHS paths, permissions, and ownership
- **Deterministic Generator**: `build/generate-fhs-outputs.sh` produces all packaging artifacts from the YAML spec
- **Generated Outputs**:
  - `install/systemd/tmpfiles.d/nftban.conf` - Runtime directory creation
  - `install/systemd/sysusers.d/nftban.conf` - User/group creation with memberships
  - `install/packaging/deb/nftban.dirs` - Debian package directories
  - `install/packaging/rpm/nftban-files.inc` - RPM %files include
  - `cli/lib/nftban/data/fhs_directories.json` - JSON for receipt consumption
  - `cli/lib/nftban/core/nftban_fhs_spec.sh` - Generated shell helper
- **CI Guard**: `tools/check-recursive-permissions.sh` blocks `chmod -R` and `chown -R` in commits
- **Debian 13 (Trixie) Support**: Added distro configuration for Debian 13

### Changed
- **Packaging Refactor**: postinst/spec now use `systemd-sysusers` and `systemd-tmpfiles` instead of hardcoded `install -d`
- **Security Boundary**: `/var/lib/nftban` is now `root:nftban` (not `nftban:nftban`) - subdirs remain daemon-writable
- **Conditional Directories**: External/feature directories (metrics, node_exporter, gui) are condition-gated, not in base tmpfiles

### Fixed
- Permission drift between packaging scripts and FHS spec
- Recursive permission changes that could affect user config files

## [Unreleased]

### Added

#### Task Queue System (Reliability Improvements)
- **Dead-Letter Queue (DLQ)**: Failed tasks now preserved for manual review instead of being deleted
- **Exponential Backoff**: Configurable retry delays (default: 30s base, 900s max)
- **Atomic Task Claiming**: Tasks moved to work/ directory during processing (prevents duplicate execution)
- **Stuck Lock Recovery**: Auto-kills processors stuck >20 minutes, recovers orphaned tasks
- **Queue Metrics**: Prometheus metrics for pending/working/DLQ counts and processing totals
- **CLI Commands**: `nftban queue status|list|dlq list|dlq retry|dlq retry-all|dlq purge|metrics`

#### Mail Delivery System (Reliability Improvements)
- **Retry Wrapper**: `nftban_mail_send_with_retry()` with configurable attempts and backoff
- **Mail Spooling**: Failed emails spooled to queue system for later retry
- **Transport Metrics**: Prometheus counters per transport (postfix, sendmail, curl, etc.)
- **Spool Status**: `nftban mail spool status` command

#### Service Alerting
- **OnFailure Units**: `nftban-alert@.service` template for systemd service failures
- **Alert Throttling**: Prevents spam (default: 1 hour between same-service alerts)
- **Service Alert Script**: Collects diagnostics (journal, status, resources) on failure

#### Timer Improvements
- **Jitter**: `RandomizedDelaySec=30s` on timers to prevent thundering herd

#### Module Safety
- **Loading Guards**: Modules check for function availability before calling queue/mail APIs

#### Security (CWE-400 Mitigation)
- **Queue Capacity Limit**: Rejects tasks when queue exceeds `NFTBAN_QUEUE_MAX_PENDING` (default: 10000)
- **DLQ Auto-Purge**: Automatically removes DLQ entries older than `NFTBAN_QUEUE_DLQ_AUTO_RETENTION_DAYS` (default: 7)

### Changed

- **Queue Architecture**: Tasks now flow through `pending/ → work/ → success|retry|DLQ`
- **Queue Processor**: Returns proper exit codes (0=success, 1=empty, 2=locked, 3=error)
- **Timer OnFailure**: Queue and other timers now trigger alerts on failure

### Configuration

New variables in `/etc/nftban/nftban.conf`:

```bash
# Task Queue
NFTBAN_QUEUE_MAX_RETRIES="3"
NFTBAN_QUEUE_BACKOFF_BASE_SECONDS="30"
NFTBAN_QUEUE_BACKOFF_MAX_SECONDS="900"
NFTBAN_QUEUE_PENDING_DIR="${NFTBAN_DATA_DIR}/queue/pending"
NFTBAN_QUEUE_WORK_DIR="${NFTBAN_DATA_DIR}/queue/work"
NFTBAN_QUEUE_DLQ_DIR="${NFTBAN_DATA_DIR}/queue/dlq"
NFTBAN_QUEUE_LOCK_STUCK_THRESHOLD="1200"
NFTBAN_QUEUE_MAX_PENDING="10000"           # CWE-400: Queue capacity limit
NFTBAN_QUEUE_DLQ_AUTO_RETENTION_DAYS="7"   # CWE-400: DLQ auto-purge
NFTBAN_QUEUE_METRICS_FILE="${NFTBAN_DATA_DIR}/metrics/queue.prom"

# Mail Delivery
NFTBAN_MAIL_RETRY_ATTEMPTS="3"
NFTBAN_MAIL_RETRY_BACKOFF="5,15,45"
NFTBAN_MAIL_SPOOL_DIR="${NFTBAN_DATA_DIR}/mailspool"
NFTBAN_MAIL_METRICS_FILE="${NFTBAN_DATA_DIR}/metrics/mail.prom"

# SMTP Timeouts (curl direct SMTP transport)
NFTBAN_SMTP_CONNECT_TIMEOUT="10"   # Preferred naming
NFTBAN_SMTP_MAX_TIME="30"          # Legacy: NFTBAN_CURL_* still works

# Service Alerts
NFTBAN_ALERT_THROTTLE_SECONDS="3600"
```

### New Prometheus Metrics

**Queue Metrics** (`/var/lib/nftban/metrics/queue.prom`):
- `nftban_queue_tasks_pending` - Tasks waiting to be processed
- `nftban_queue_tasks_working` - Tasks currently processing
- `nftban_queue_tasks_dlq` - Tasks in dead-letter queue
- `nftban_queue_oldest_pending_age_seconds` - Age of oldest pending task
- `nftban_queue_tasks_processed_total` - Total successful tasks
- `nftban_queue_tasks_failed_total` - Total failed tasks
- `nftban_queue_task_retries_total` - Total retry attempts
- `nftban_queue_dlq_total` - Total tasks moved to DLQ

**Mail Metrics** (`/var/lib/nftban/metrics/mail.prom`):
- `nftban_mail_send_attempts_total{transport="..."}` - Send attempts by transport
- `nftban_mail_send_success_total{transport="..."}` - Successful sends
- `nftban_mail_send_failures_total{transport="..."}` - Failed sends
- `nftban_mail_spool_depth` - Number of mails in retry spool
- `nftban_mail_last_success_timestamp` - Unix timestamp of last success

### Logrotate Changes

- **mail.log, queue.log**: Changed from `create` to `copytruncate` (safer for bash appenders)

### Upgrade Notes

**From 1.0.0-beta:**

1. **New directories created automatically**: `queue/work/`, `queue/dlq/`, `mailspool/`
2. **Existing queue tasks**: Continue processing normally
3. **Configuration**: New variables have sensible defaults - no action required
4. **Timers**: Reload systemd to pick up OnFailure units:
   ```bash
   systemctl daemon-reload
   ```
5. **Metrics**: New Prometheus metrics available at:
   - `/var/lib/nftban/metrics/queue.prom`
   - `/var/lib/nftban/metrics/mail.prom`

**Breaking Changes:** None

---

## [1.0.0-beta] - 2025-12-11

### Major Release - Beta Testing

NFTBan v1.0.0-beta is the first major release, featuring a complete architecture redesign with unified Go backend, modular Bash CLI, and modern web interface. Production-tested on multiple servers - community feedback welcome!

> **Beta Status:** Core functionality stable. Active bug fixes and improvements based on community testing.

### Highlights

- **Unified Go Architecture**: Single `nftban-core` binary replaces separate go-feeds/go-geoip
- **Dual-Table NFTables**: Separate `ip nftban` and `ip6 nftban` tables for IPv4/IPv6
- **Suricata IDS Integration**: Network-based intrusion detection with automatic banning
- **FHS Compliance**: Full Filesystem Hierarchy Standard compliance
- **Modern Web UI**: Responsive dashboard with real-time monitoring
- **REST API**: Complete API for automation and integration
- **Production Tested**: Deployed on live servers

### Architecture

#### Go Components
- `cmd/nftban-core` - Unified binary for feeds, geoip, sync operations
- `cmd/nftban-api-server` - REST API server
- `cmd/nftban-ui` - Web interface server
- `pkg/` - Shared packages (api, config, feeds, geoip, sync, util)

#### Bash CLI
- 43 commands organized in modular structure
- `cli/lib/nftban/core/` - Core functionality
- `cli/lib/nftban/cli/` - Command handlers
- `cli/lib/nftban/helpers/` - Utility functions
- `cli/lib/nftban/setup/` - Installation helpers

### Added

#### Beta Improvements (Dec 2025)
- **Comprehensive Smoke Testing**: `nftban smoke all` tests ALL 43 CLI commands
- **CLI Documentation Tools**: Export CLI inventory, validate help functions, update man pages
- **Banner Health Indicator**: Shows system health status (green/yellow/red) in CLI banner
- **Update Notification**: Optional banner shows when new version available
- **Simplified 2-Group Model**: Single `nftban` group for CLI + Web GUI operators
- **DEB/RPM Safe Install Flow**: Non-destructive package installation
- **System Watchdog Module**: Resource monitoring (load, memory, I/O, disk)
  - Prometheus metrics export to `/var/lib/nftban/metrics/watchdog.prom`
  - Configurable thresholds via `/etc/nftban/conf.d/watchdog.conf`
  - `nftban watchdog status/check/report/history` commands

#### Core Features
- **nftban-core binary**: Unified Go backend for all operations
  - Threat feed aggregation (Spamhaus, AbuseIPDB, Firehol, etc.)
  - GeoIP lookups with MaxMind GeoLite2
  - Profile-based synchronization
  - CIDR aggregation for optimal performance

- **Suricata IDS Integration**: `nftban setup suricata`
  - Automatic compilation from source (latest stable)
  - Optimized configuration for server environments
  - Integration with NFTBan banning system
  - EVE JSON logging for threat analysis

- **Dual-Table Architecture**: Clean IPv4/IPv6 separation
  - `ip nftban` table for IPv4 rules
  - `ip6 nftban` table for IPv6 rules
  - No interference with system tables
  - Easy to audit and debug

- **Security Profiles**: Pre-configured security levels
  - `basic` - Essential protection
  - `standard` - Recommended for most servers
  - `advanced` - Maximum security with rate limiting

#### CLI Commands
- `nftban status` - Quick system overview
- `nftban health` - System diagnostics (binaries, services, permissions)
- `nftban validate` - Firewall structure validation
- `nftban ban/unban` - IP management with timeout support
- `nftban search` - Search across all sets and feeds
- `nftban feeds` - Threat feed management
- `nftban geoban` - Country blocking by ISO code
- `nftban geoip` - IP geolocation lookup
- `nftban portscan` - Port scan detection
- `nftban login` - SSH login monitoring
- `nftban ddos` - DDoS protection controls
- `nftban stats` - Statistics and reporting
- `nftban profile` - Security profile management
- `nftban sync` - Atomic nftables reload
- `nftban menu` - Interactive TUI mode
- `nftban watchdog` - System resource monitoring

#### Web Interface
- Dashboard with real-time statistics
- IP/Port management interface
- Threat feed monitoring
- GeoBan country controls
- Log viewer with filtering
- Configuration editor
- System health monitoring

#### GitHub Actions CI/CD
- `ci.yml` - PR validation (ShellCheck, Go build/test, security)
- `shellcheck.yml` - Bash linting
- `secure-go.yml` - Go security (staticcheck, gosec, govulncheck)
- `build-packages.yml` - RPM/DEB package building
- `release.yml` - Full release automation
- `release-binaries.yml` - Go binary releases

### Changed

- **Project Structure**: Complete reorganization for FHS compliance
- **Binary Names**: `nftban-feeds`/`nftban-geoip` merged into `nftban-core`
- **Table Names**: Changed from `inet nftban` to `ip nftban`/`ip6 nftban`
- **Version Scheme**: Moved from 0.7.x to 1.0.0 semantic versioning

### Removed

- Legacy `go-feeds/` and `go-geoip/` directories (merged into `cmd/nftban-core`)
- Deprecated `inet nftban` single-table architecture
- Old v0.3.x compatibility code
- Development scripts and notes (moved to separate dev folder)

### Security

- Socket-based PAM authentication (no setuid binaries)
- Systemd hardening (NoNewPrivileges, ProtectSystem, etc.)
- Input validation on all CLI commands
- Rate limiting for API endpoints
- Automatic IP whitelisting for critical services

### Documentation

- `README.md` - Project overview and quick start
- `SECURITY.md` - Security policy and reporting
- `docs/` - User documentation
- `.github/` - Issue templates, PR templates, support guide

### Migration from v0.7.x

1. Backup existing configuration: `cp -r /etc/nftban /etc/nftban.backup`
2. Stop services: `systemctl stop nftban nftban-ui`
3. Run installer: `./install.sh`
4. Migrate tables: `nftban sync --migrate`
5. Verify: `nftban health && nftban validate`

---

## Previous Versions (v0.x)

### Version Summary

| Version | Date | Description |
|---------|------|-------------|
| 1.0.0-beta | 2025-12-11 | First major release, beta testing |
| 0.32.6 | 2025-11-07 | Fail2ban health-fix system |
| 0.32.3 | 2025-11-07 | RPM installation fixes |
| 0.31.0 | 2025-11-05 | Critical security fix (rule order) |
| 0.31.0 | 2025-11-03 | Self-healing inventory monitoring |
| 0.10.0 | 2025-10-29 | Complete architectural refactoring |

---

## [0.32.6] - 2025-11-07

### Added
- **Fail2ban Health-Fix System:** Comprehensive jail health checking and auto-fix
  - `nftban fail2ban health-fix` command with full diagnostics
  - Service detection before enabling jails (checks for 12 different services)
  - Requirements checking: service installed, log file exists, configuration valid
  - Automatic disabling of problematic jails (never auto-enables)
  - Report generation with `--save-report` option (saves to `/var/log/nftban/reports/`)
  - Email reporting with `--mail` option (HTML-formatted reports)
  - Support for 12 NFTBan jail types: sshd, directadmin, exim, dovecot, postfix, proftpd, vsftpd, apache, nginx, wordpress, named, asterisk

- **Health Check Integration:** Daily monitoring for fail2ban jails
  - `nftban_health_check_fail2ban_jails()` function in health module
  - Reports problematic jails without modifying configs
  - Integrates with existing health check system
  - Provides warnings for missing services or log files

- **Autoheal Integration:** Automatic jail problem detection
  - Runs during installation and system maintenance
  - Automatically disables jails that crash fail2ban
  - Protects fail2ban service from problematic configurations
  - Silent mode with detailed logging

- **Interactive Menu:** Fail2ban health-fix in TUI menu
  - Added to `nftban menu` interactive interface
  - Requires root privileges with automatic checking
  - Integrated into fail2ban management screen

### Changed
- **Report Location:** Standardized diagnostic reports to `/var/log/nftban/reports/`
  - FHS-compliant location for operational/diagnostic reports
  - Separate from HTML state reports in `/var/lib/nftban/reports/`
  - Proper permissions for nftban-auditors group access

### Fixed
- **Report Output:** Fixed SSH session compatibility
  - Changed from `/dev/tty` redirection to temporary file approach
  - Prevents "No such device or address" errors in SSH sessions
  - Proper output capture for --save-report and --mail options

- **Argument Passing:** Fixed CLI wrapper argument forwarding
  - Added `"$@"` to pass all arguments through CLI handlers
  - Ensures --save-report and --mail options work correctly

- **Shell Options:** Protected health-fix from `set -e` early exit
  - Wrapped function with option saving/restoring
  - Prevents function exit when checks return non-zero
  - Maintains proper error handling without breaking parent scripts

- **Awk Exit Codes:** Fixed autoheal awk command compatibility
  - Changed from conditional exit to output capture
  - Prevents script termination with `set -e` enabled
  - More robust jail status checking

### Documentation
- **Man Page:** Complete fail2ban section added to nftban.1
  - health-fix command documentation
  - --save-report and --mail options explained
  - Examples and usage patterns

- **Bash Completion:** Updated for all fail2ban commands
  - Added health-fix command completion
  - Added --save-report and --mail option completion
  - Integrated with existing completion system

---

## [0.32.3] - 2025-11-07

### Fixed
- **RPM Installation:** Fixed %pre script hanging on Rocky/AlmaLinux systems
  - Changed from auto-enabling repos to checking if repos are enabled
  - Prevents dnf commands from hanging during installation
  - Shows clear error with instructions if EPEL/CRB not enabled
- **Menu System:** Added whiptail (newt) dependency for interactive TUI
  - Fixed fallback text mode input validation
  - Added warning if whiptail missing with install instructions
- **Status Command:** Added system requirements checks (DNS, Email, SMTP ports, Reports)
- **Version Management:** Created single VERSION file to eliminate build mismatches
- **Rocky/Alma Builds:** Fixed glibc version mismatch in Rocky Linux 9 containers
  - Targeted fix using --nobest flag only for Rocky/AlmaLinux
- **Documentation:** Updated all docs to v0.32.3

---

## [0.31.0] - 2025-11-05

### 🚨 CRITICAL SECURITY RELEASE

**NFTBan-SA-2024-001** - Rule order vulnerability allowing blacklisted IPs to bypass firewall. (No CVE assigned)

### Fixed

#### Security - Rule Processing Order (CRITICAL)
- **CRITICAL:** Fixed nftables rule order - blacklist checks now run BEFORE port checks
  - **Issue:** In v0.31.0, port allow rules executed before blacklist drops
  - **Impact:** Blacklisted IPs could access SSH (port 22) and all allowed services
  - **Root Cause:** Port checks (`tcp dport @tcp_ports accept`) ran before blacklist checks
  - **Fix:** Reordered rules so blacklist drops execute first, then port allows
  - **Testing:** Verified on 5 lab servers - blacklist now properly blocks all traffic

```nft
# v0.31.0 (VULNERABLE):
tcp dport @tcp_ports accept    ← Port 22 accepted FIRST
ip saddr @blacklist_v4 drop    ← NEVER REACHED!

# v0.31.0 (SECURE):
ip saddr @blacklist_v4 counter drop    ← Check blacklist FIRST
tcp dport @tcp_ports counter accept    ← Then allow ports
```

#### nftables Architecture Fixes
- **Fixed:** Chain naming consistency (`input_main` → `input`)
- **Fixed:** Numeric priorities (now `-5` and `0` instead of `-310` and `-300`)
- **Fixed:** Default policy set to `drop` (secure by default)
- **Fixed:** Set name typo (`whitelist_ipv4` → `whitelist_v4`)
- **Fixed:** nftables syntax (counter must come before accept/drop)

#### CLI Improvements
- **Fixed:** `ban` command now checks whitelist BEFORE banning
  - Prevents accidental lockout by refusing to ban whitelisted IPs
  - Shows clear error message with which whitelist file contains the IP
  - Provides step-by-step instructions if override needed
- **Fixed:** `ban` and `unban` commands no longer crash with no arguments
  - Added validation: `ip="${1:-}"` with `shift || true`
  - Shows usage message instead of "unbound variable" error
- **Fixed:** `nftban ban help` now shows help instead of trying to ban "help"
- **Added:** `nftban unban help` command for usage information

#### Performance Improvements
- **Fixed:** `feeds enable` command no longer blocks CLI
  - Feed download now runs in background with `disown`
  - Returns immediately with status message
  - User can check progress with `nftban feeds status`
  - Logs available at `/var/log/nftban/feeds.log`

### Added

#### Monitoring & Observability
- **Added:** Packet counters to all nftables rules for traffic analysis
- **Added:** Comprehensive security warning when attempting to ban whitelisted IPs

### Security

**Security Score:** v0.31.0 = 10/10 (reference-grade implementation)

- ✅ **CRITICAL:** Blacklist now properly blocks all traffic (rule order fixed)
- ✅ Whitelist protection prevents accidental lockout
- ✅ Ban command validates against whitelist before execution
- ✅ Default policy is drop (secure by default)
- ✅ All rules have packet counters for monitoring

### Testing

**Verified on 5 Lab Servers:**
- lab.mywebhost.gr (AlmaLinux 10)
- lab1.mywebhost.gr (Rocky Linux 9)
- lab2.mywebhost.gr (Ubuntu 24.04)
- lab3.mywebhost.gr (CentOS Stream 10)
- lab4.mywebhost.gr (Fedora 42)

---

## [0.31.0] - 2025-11-03

### 🎉 Major Release - Self-Healing Inventory Monitoring

This is a major upgrade adding comprehensive inventory monitoring, baseline management, and system resource tracking to NFTBan.

### Added

#### 🔍 Advanced Inventory System (NEW!)
- **Process inventory tracking** - nftban-procnet helper
- **Package inventory tracking** - nftban-pkgs helper
- **Tamper detection** - nftban-verify helper
- **Firewall state export** - nftban-firewall helper

#### 📊 System Resource Monitoring (NEW!)
- **Disk usage monitoring** - Configurable warn/critical thresholds
- **RAM usage monitoring** - Memory utilization tracking
- **CPU load monitoring** - System load average tracking
- **Swap usage monitoring** - Swap utilization alerts
- **Inode usage monitoring** - Filesystem inode tracking
- **Configurable thresholds** via health.conf
- **Alert integration** - Triggers on threshold breaches

#### 🔔 Alert Throttling System (NEW!)
- **State-based throttling** - Prevents alert spam
- **Configurable intervals** - Default: 1 hour between same alerts
- **Automatic cleanup** - Removes old throttle entries
- **Per-issue tracking** - Independent throttling for each alert type

#### 🔐 Baseline Management (NEW!)
- **nftban-baseline-save** - Create system baselines
- **Cryptographic signing** - GPG signing for baseline integrity
- **nftban-verify-signature** - Verify baseline authenticity
- **Drift detection** - Compare current state vs. baseline
- **Baseline storage** - /var/lib/nftban/reports/baseline

#### 📧 Smart Mail Adapter (NEW!)
- **Auto-detection** - Detects best available mail transport
- **Multiple transports** - sendmail, msmtp, curl support
- **Graceful fallback** - Degrades to logger if no mail available

### Security
- **Reduced attack surface** - Inventory helpers run as nftban user via Polkit
- **Cryptographic verification** - Baseline signing and verification
- **SHA256 hashing** - Executable tamper detection
- **File integrity** - Package database verification

### Testing
- **100% success rate** - Tested across 5 distributions:
  - CentOS Stream 9, 10
  - Ubuntu 24.04
  - AlmaLinux 10.0
  - Rocky Linux 10

---

## [0.10.0] - 2025-10-29

### 🎉 Major Release - Complete Architectural Refactoring

This is a major release representing a complete rewrite of NFTBan with new architecture, features, and performance improvements.

### Added

#### 🔥 Firewall Management System (NEW!)
- **Complete nftables architecture** - Two-table design (runtime + main)
- **Firewall initialization command** - `nftban firewall init` creates complete architecture
- **Health check system** - 10-point comprehensive diagnostics
- **Atomic table reload** - `nftban firewall reload` rebuilds main table safely
- **Architecture verification** - Automatic detection of missing components
- **CLI commands**: init, reload, status, check, reset, help
- **DirectAdmin support** - Auto-configuration for DirectAdmin control panel ports

#### 🛡️ Threat Intelligence Feeds System (NEW!)
- **Dynamic feed discovery** - No hardcoded arrays, feeds auto-discovered from config
- **14 pre-configured threat feeds** from trusted sources
- **Beautiful numbered selection interface** - Easy feed selection
- **Go binary integration** for 10-60x faster feed parsing
- **All feeds disabled by default** for safety
- **Category-based management** - Enable entire categories at once

#### 🔧 Fail2ban Integration (NEW!)
- **Dynamic jail discovery** - Auto-discovers all fail2ban jails
- **Comprehensive status reporting** - Show all jails with ban counts
- **Cloudflare sync** - Sync fail2ban bans to Cloudflare (if enabled)

### Changed

#### Architecture & Structure
- **Complete refactoring** - Modern, maintainable codebase
- **FHS compliance** - All files in proper Linux filesystem locations
- **Modular design** - Separated core, CLI, and module layers
- **Configuration precedence** - Proper layering: defaults → conf.d → local → env → CLI
- **Dynamic loading** - Runtime discovery instead of hardcoded arrays

### Improved

#### Performance
- **10-60x faster feed parsing** - Go binary vs pure bash
- **Fast GeoIP lookups** - Go binary with embedded database
- **Efficient nftables operations** - Optimized set management

---

## Support & Resources

### Getting Help
```bash
nftban help              # General help
nftban <command> help    # Command-specific help
nftban health check      # System diagnostics
```

---

**NFTBan** — Simplifying Linux Firewall Management

For more information, visit: https://nftban.com
