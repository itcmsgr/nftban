# NFTBan Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

**CVE-2024-NFTBAN-001** - Rule order vulnerability allowing blacklisted IPs to bypass firewall.

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
- lab.example.test (AlmaLinux 10)
- lab1.example.test (Rocky Linux 9)
- lab2.example.test (Ubuntu 24.04)
- lab3.example.test (CentOS Stream 10)
- lab4.example.test (Fedora 42)

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
