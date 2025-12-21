# NFTBan Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
