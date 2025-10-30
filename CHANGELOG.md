# Changelog

All notable changes to NFTBan will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
- **User-friendly error messages** - Clear fix suggestions for issues
- **CLI commands**: init, reload, status, check, reset, help
- **DirectAdmin support** - Auto-configuration for DirectAdmin control panel ports
- **Critical bug fixes**:
  - Fixed IPv4/IPv6 separation (comments with colons caused misclassification)
  - Fixed nftables syntax error (shell redirection in nft template)
- **Performance verified** - Handles millions of IPs without system freeze

#### 🛡️ Threat Intelligence Feeds System (NEW!)
- **Dynamic feed discovery** - No hardcoded arrays, feeds auto-discovered from config
- **14 pre-configured threat feeds** from trusted sources:
  - Protection category: 6 feeds (Spamhaus DROP/EDROP, Abuse.ch Feodo/SSL, FireHOL Level1/Level2)
  - SSH category: 3 feeds (blocklist.de SSH, GreenSnow, FireHOL SSH)
  - Web category: 3 feeds (blocklist.de Apache/Nginx, FireHOL Webcam)
  - Email category: 2 feeds (blocklist.de Mail, StopForumSpam)
- **Beautiful numbered selection interface** - Easy feed selection: `1 3 6` or `ssh` or `all`
- **Go binary integration** for 10-60x faster feed parsing (parse 50K IPs in 1-2 seconds)
- **All feeds disabled by default** for safety
- **Category-based management** - Enable entire categories at once
- **Automatic updates** - Configurable auto-update intervals
- **Dedicated logging** at `/var/log/nftban/feeds.log`
- **Interactive menu**: `nftban feeds select`
- **CLI commands**: list, enable, disable, enable-category, update, status

#### 🔧 Fail2ban Integration (NEW!)
- **Dynamic jail discovery** - Auto-discovers all fail2ban jails
- **Comprehensive status reporting** - Show all jails with ban counts
- **Banned IP management** - List, ban, and unban IPs
- **Cloudflare sync** - Sync fail2ban bans to Cloudflare (if enabled)
- **Service control** - Start, stop, restart, reload fail2ban
- **Jail management** - Enable/disable individual jails
- **Interactive interface** - Beautiful formatted output
- **CLI commands**: status, jails, banned, ban, unban, reload, enable, disable

#### 🎨 User Interface Improvements
- **Numbered selection menus** - Easy interaction for feeds and other features
- **Categorized displays** - Logical grouping of feeds, jails, modules
- **Status indicators** - Visual [✓] [✗] indicators throughout
- **Color-coded output** - Enhanced readability (when supported)
- **Progress indicators** - Real-time feedback for operations
- **Comprehensive help** - Built-in help for all commands

#### 📊 Core Features & Modules
- **DDoS Protection** - 4 protection types (SYN, UDP, ICMP floods, connection limits)
- **Port Scan Detection** - Real-time detection and automatic blocking
- **Security Profiles** - 7 profiles (paranoid, strict, balanced, web, minimal, dev, disabled)
- **Cloudflare Integration** - Automatic Cloudflare IP whitelisting and updates
- **Login Monitoring** - Real-time SSH/system login alerts via email
- **Auto-Whitelist System** - Automatic system IP whitelisting
- **Port Management** - Comprehensive port status and reporting
- **Module Inventory** - Complete module listing with metadata
- **FHS Compliance Checker** - Verify filesystem hierarchy compliance
- **Health Diagnostics** - System health checks with auto-fix capabilities
- **Mail Notifications** - Configurable SMTP/sendmail email alerts

#### 🚀 Performance & Architecture
- **Go binary for GeoIP** - Ultra-fast IP geolocation lookups
- **Go binary for feeds** - Fast parsing, validation, and deduplication
- **FHS-compliant structure** - Full Linux Filesystem Hierarchy Standard compliance
- **Layered configuration** - Proper precedence with conf.d/ drop-ins
- **Dynamic discovery** - All feeds, jails, and modules discovered at runtime
- **Modular CLI** - Auto-loading command modules from cli/ directory
- **Bash completion** - Full tab completion for all commands

#### 📚 Documentation
- **FEEDS_USER_GUIDE.md** - Comprehensive threat feeds guide
- **Session documentation** - Complete implementation notes for feeds and fail2ban
- **Inline help** - Built-in help for every command
- **Updated README** - Current feature list and quick start guide

### Changed

#### Architecture & Structure
- **Complete refactoring** - Modern, maintainable codebase
- **FHS compliance** - All files in proper Linux filesystem locations:
  - `/usr/sbin/nftban` - Main CLI
  - `/usr/lib/nftban/` - Code libraries
  - `/etc/nftban/` - Configuration
  - `/var/lib/nftban/` - State data
  - `/var/log/nftban/` - Logs
  - `/var/cache/nftban/` - Cache
- **Modular design** - Separated core, CLI, and module layers
- **Configuration precedence** - Proper layering: defaults → conf.d → local → env → CLI
- **Dynamic loading** - Runtime discovery instead of hardcoded arrays

#### Configuration Management
- **Layered configs** - Drop-in configs in `/etc/nftban/conf.d/`
- **User overrides** - Safe user customization via `nftban.conf.local`
- **Module configs** - Separate config files per module
- **Environment support** - Environment variable overrides
- **No hardcoding** - All configuration in files, not code

#### CLI Interface
- **Auto-loading commands** - Commands automatically loaded from `/usr/lib/nftban/cli/`
- **Consistent interface** - All commands follow same pattern
- **Better error handling** - Clear error messages with suggestions
- **Bash completion endpoint** - Built-in completion via `__complete`
- **Help system** - Consistent help across all commands

### Improved

#### Performance
- **10-60x faster feed parsing** - Go binary vs pure bash
- **Fast GeoIP lookups** - Go binary with embedded database
- **Efficient nftables operations** - Optimized set management
- **Reduced disk I/O** - Caching and smart updates
- **Faster command loading** - Modular lazy loading

#### Reliability
- **Better error handling** - Comprehensive error checking
- **Safer defaults** - All feeds disabled, minimal attack surface
- **Atomic operations** - Config updates are atomic
- **Logging improvements** - Detailed logs for troubleshooting
- **Health checks** - Auto-detection and fixes for common issues

#### User Experience
- **Interactive menus** - Numbered selection for complex operations
- **Visual feedback** - Progress indicators and status symbols
- **Better organization** - Logical categorization of features
- **Clear documentation** - Comprehensive guides and help
- **Tab completion** - Full bash completion support

### Fixed

#### From v0.9.5
- **Configuration conflicts** - Proper precedence now implemented
- **Hardcoded arrays** - Replaced with dynamic discovery
- **Slow feed parsing** - Now 10-60x faster with Go
- **Unclear feed status** - Now clear categorized display
- **Missing fail2ban features** - Full integration now included

### Security

#### Improvements
- **All feeds disabled by default** - Prevents accidental lockouts
- **Whitelist system** - Protect important IPs before enabling feeds
- **Fail2ban integration** - Better coordination with fail2ban bans
- **Cloudflare sync** - Keep Cloudflare firewall in sync
- **Health diagnostics** - Detect and fix security misconfigurations

### Deployment

#### Lab Testing
- **3 lab servers** - Tested on CentOS 9, Ubuntu 24.04, CentOS 10
- **Full deployment** - All modules deployed and tested
- **Integration testing** - All features working together
- **Performance verified** - Go binaries tested on all platforms

#### Files Changed
- **New files**: 50+ new modules and scripts
- **Go binaries**: 2 (feeds parser, GeoIP lookup)
- **Configuration**: 10+ new config files
- **Documentation**: 5+ comprehensive guides

---

## [0.9.5] - 2025-10-XX (Previous Release)

### Features from v0.9.5
- Basic firewall management
- Manual feed configuration
- Limited fail2ban integration
- Shell-only implementation

### Migration Notes
- v0.10.0 is a complete rewrite
- Configuration files need migration
- New FHS-compliant paths
- Enhanced features and performance

---

## Version History

### Release Timeline
- **v0.10.0** (2025-10-28) - Complete architectural refactoring ← **Current**
- **v0.9.5** (2025-10-XX) - Previous stable release

### Development Timeline (v0.10.0)
- **Day 1** (2025-10-27) - Fail2ban integration with dynamic jail discovery
- **Day 2** (2025-10-28) - Feeds system with Go binary and dynamic discovery
- **Day 3** (2025-10-28) - CLI integration, bash completion, and documentation

---

## Upgrade Guide

### From v0.9.5 to v0.10.0

#### Breaking Changes
1. **Directory structure changed** - Now FHS-compliant
   - Old: `/opt/nftban/` → New: `/usr/lib/nftban/`
   - Old: `/etc/nftban.conf` → New: `/etc/nftban/nftban.conf`
   - Old: `/var/nftban/` → New: `/var/lib/nftban/`

2. **Configuration format changed** - Feed configs now dynamic
   - Old: Hardcoded feed arrays in code
   - New: `FEED_*` pattern in `/etc/nftban/conf.d/feeds.conf`

3. **CLI commands changed** - New modular structure
   - Old: Limited commands
   - New: 20+ commands with subcommands

#### Migration Steps
1. **Backup v0.9.5 configuration**:
   ```bash
   cp -r /opt/nftban /opt/nftban.backup
   ```

2. **Install v0.10.0** via deployment script

3. **Migrate configurations manually**:
   - Review old configs
   - Update to new format
   - Test on lab server first

4. **Enable desired features**:
   ```bash
   sudo nftban feeds select    # Enable feeds
   nftban profile select       # Choose security profile
   nftban fail2ban status      # Verify fail2ban
   ```

5. **Verify and monitor**:
   ```bash
   nftban health check
   tail -f /var/log/nftban/feeds.log
   ```

#### New Features to Explore
- **Feeds system**: `nftban feeds help`
- **Fail2ban**: `nftban fail2ban help`
- **Health checks**: `nftban health help`
- **All commands**: `nftban help`

---

## Support & Resources

### Documentation
- **README.md** - Project overview and features
- **FEEDS_USER_GUIDE.md** - Complete feeds guide
- **Session docs** - Implementation details

### Lab Servers
- **your-server.example.com** - CentOS 9
- **server1.example.com** - Ubuntu 24.04
- **server2.example.com** - CentOS 10

### Getting Help
```bash
nftban help              # General help
nftban <command> help    # Command-specific help
nftban health check      # System diagnostics
```

---

**NFTBan v0.10.0** — Simplifying Linux Firewall Management

For more information, visit: https://nftban.com
