# Changelog

All notable changes to nftban will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [0.8.5-beta] - 2025-01-17

### 🎉 Major Features Added

#### DDoS Protection Module
Complete DDoS protection system with four protection types:

- **SYN Flood Protection**
  - Rate limiting for TCP SYN packets to prevent SYN flood attacks
  - Configurable rate and burst parameters per port
  - Can be enabled/disabled globally or per-port
  - Default: Disabled (can be resource intensive)

- **Connection Limit Protection**
  - Limits concurrent connections per IP per port
  - Prevents resource exhaustion attacks
  - Pre-configured for common services (SSH: 5, HTTP: 20, HTTPS: 20)
  - Supports custom port configurations
  - Default: Enabled

- **Port Flood Protection**
  - Rate limits new connection attempts over time windows
  - Prevents rapid-fire connection attacks
  - Example: SSH limited to 5 connections per 300 seconds
  - Configurable per-port with custom time windows
  - Default: Enabled

- **ICMP Rate Limiting**
  - Controls inbound and outbound ping requests
  - Prevents ICMP flood attacks
  - PCI DSS compliance mode (block all ICMP)
  - Separate inbound/outbound rate configuration
  - Default: Enabled (1 ping/second inbound)

**New CLI Commands:**
```bash
nftban ddos enable/disable/status
nftban ddos synflood enable/disable/status
nftban ddos connlimit enable/disable/status/add-port/remove-port
nftban ddos portflood enable/disable/status/add-port/remove-port
nftban ddos icmp enable/disable/status/pci-mode
```

**New Configuration File:** `config/ddos_protection.conf` (with `.conf.local` override support)

---

#### Port Scan Detection Module
Intelligent port scanner detection and automatic banning:

- **Pattern Detection**
  - Tracks IPs accessing multiple ports within time windows
  - Configurable threshold (default: 10 ports in 300 seconds)
  - Time-window based tracking with automatic cleanup

- **Port Diversity Analysis**
  - Differentiates between legitimate services and scanners
  - FTP passive mode (low diversity) vs actual scanners (high diversity)
  - Prevents false positives from legitimate multi-port services

- **Automatic Response**
  - Auto-ban detected scanners (temporary or permanent)
  - Configurable ban duration and type
  - Email alerts on detection (if configured)
  - Separate whitelist for security tools

- **Comprehensive Logging**
  - Detection events logged to `/var/log/nftban/portscan.log`
  - Scanner confirmations in `/var/log/nftban/portscan_detections.log`
  - Statistics tracking for analysis

**New CLI Commands:**
```bash
nftban portscan enable/disable/status/stats
nftban portscan check/check-ip/cleanup
nftban portscan whitelist add/remove/list
```

**New Configuration File:** `config/portscan.conf` (with `.conf.local` override support)

---

### 📄 License Update

**License Updated to v2.0: "ITCMS Protective Free-Use License v2.0"**

- **New Catchphrase:** "Free forever. Use anywhere. Sell services, not the software."
- **Enhanced Clarity:** Clear distinction between allowed services vs prohibited product sales
- **Service-Friendly:** Explicitly allows managed service providers (MSPs) and consultants
- **Better Examples:** Comprehensive FAQ with real-world scenarios
- **Commercial Pathway:** Clear path for businesses needing special licensing
- **SPDX Identifier:** `SPDX-License-Identifier: NFTBAN-Custom-License`

**What Changed:**
- Clearer service vs product distinction with examples
- Explicit allowances for commercial services
- Better protection against unauthorized resale
- Simplified language while maintaining legal strength
- Added comprehensive FAQ section

**Quick Reference:**
- ✅ Use commercially without paying
- ✅ Charge for installation, setup, support services
- ✅ Offer paid managed services
- ❌ Sell the software itself as a product
- ❌ Rebrand and resell

---

### 📚 Documentation Overhaul

#### README.md - Complete Rewrite
- **Simplified Structure:** Basic overview, detailed features moved to `docs/`
- **Catchy Introduction:** "What Does nftban Do?" section
- **30-Second Quick Start:** Single command installation example
- **New Sections:**
  - Beta warning with SPDX identifier
  - Clear feature highlights with links to detailed docs
  - Enhanced acknowledgments (includes Claude AI)
  - Professional footer with proper attribution

#### SECURITY.md - Enhanced with Diagrams
- **Architecture Overview:** Component diagrams showing system structure
- **Packet Flow Diagram:** Visual representation of packet evaluation
- **DDoS Protection Diagrams:** Flow charts for each protection type
- **Port Scan Detection Flow:** Algorithm visualization
- **Fail2Ban Integration:** Step-by-step process diagram
- **Security Layers:** Multi-layer defense model visualization
- **All existing content preserved** with new diagrams prepended

#### New Documentation Files
- `CHANGELOG.md` - This comprehensive changelog
- Coming: `docs/DDOS_PROTECTION.md` - Detailed DDoS guide
- Coming: `docs/PORT_SCAN_DETECTION.md` - Scanner detection guide

---

### 🔧 Technical Changes

#### New Modules
- `lib/nftban_ddos_module.sh` (860+ lines) - Complete DDoS protection implementation
- `lib/nftban_portscan_module.sh` (650+ lines) - Port scan detection system

#### Configuration Files
- `config/ddos_protection.conf` (321 lines) - DDoS protection settings
- `config/portscan.conf` (265 lines) - Port scan detection configuration
- Both support `.conf.local` overrides (user changes preserved during updates)

#### CLI Enhancements
- Added `ddos` command with 12+ subcommands
- Added `portscan` command with 10+ subcommands
- Updated help text with new feature sections
- All commands integrate with existing safety mechanisms

#### Module Loading
- DDoS module added to core module loading sequence
- Port scan module added to core module loading sequence
- Both modules follow standard double-loading guard pattern
- Dependencies properly ordered in `lib/nftban_core.sh`

#### Version Management
- Updated `.version` file: v0.8.0 → v0.8.5
- Updated CLI version display
- Updated all module headers

---

### 🐛 Bug Fixes

- **Regex Escaping:** Fixed bash regex patterns in DDoS module (semicolons properly escaped)
- **Module Loading:** Ensured proper module order to avoid dependency issues

---

### 🏗️ Architecture Improvements

#### In-Memory Tracking
- Port scan detection uses bash associative arrays for fast pattern matching
- Automatic cleanup of old tracking data
- Memory-efficient time-window-based tracking

#### nftables Integration
- DDoS protections use native nftables rate limiting (`limit rate`)
- Connection tracking leverages nftables `ct count`
- Port scan detection uses nftables logging with custom prefix
- All features integrate with existing whitelist/blacklist infrastructure

#### Safety Mechanisms
- Whitelist protection extended to new features
- All auto-ban actions respect safety checks
- Dry-run validation for configuration changes
- Automatic rollback on configuration errors

---

### 📊 Statistics & Monitoring

#### DDoS Protection
- Real-time status display for all protection types
- Per-port protection status
- Rate limit and connection limit visibility
- Drop/reject counter tracking

#### Port Scan Detection
- Detection statistics with IP counts
- Port diversity calculations
- Time-window tracking
- Historical detection logs

---

### 🎯 Compatibility

- **Operating Systems:** All previously supported distributions (Debian 10+, Ubuntu 20.04+, CentOS 8+, AlmaLinux 8+, Rocky Linux 8+, RHEL 8+, Fedora 35+)
- **Kernel Requirements:** Linux kernel 4.14+ (for nftables timeout support)
- **Dependencies:** No new dependencies added
- **Backward Compatibility:** All existing configurations remain valid

---

### 📝 Configuration Migration

**No action required for existing users.** New features are:
- Disabled by default (SYN flood) or
- Enabled with conservative defaults (connection limits, ICMP)
- Configuration files use standard `.conf` + `.conf.local` pattern
- Existing firewall rules unchanged

**To enable new features:**
```bash
# Enable DDoS protection
sudo nftban ddos enable

# Enable port scan detection
sudo nftban portscan enable

# Check status
sudo nftban ddos status
sudo nftban portscan status
```

---

### 🙏 Credits

- **CSF Analysis:** Features inspired by ConfigServer Security & Firewall (CSF)
- **nftables Translation:** iptables rules professionally translated to modern nftables syntax
- **Claude AI:** Development assistance, code review, and documentation
- **Community:** Feature requests and testing feedback

---

## [0.8.0] - 2025-01-11

### Added
- Complete update system with version detection and staging workflow
- SHA256 checksum validation for updates
- Atomic updates with automatic rollback on failure
- Comprehensive maintenance panel showing version, integrity, health, statistics
- Git workflow automation script for releases
- Full CLI coverage with 50+ commands for all modules
- IP management commands (16+ whitelist/blacklist commands)
- Statistics and monitoring commands (12+ commands)
- Port management commands (5+ commands)
- Email notifications for updates
- Archive management with automatic cleanup

### Changed
- Standardized version numbering across entire project
- Consistent author and contact information in all modules
- Module audit showing 95% compliance
- Professional code quality with zero syntax errors

### Fixed
- Various syntax errors across modules
- Module loading order issues
- Configuration file parsing edge cases

---

## [0.5.0-beta] - 2025-01-05

### Added
- Initial beta release
- Modular architecture with 20+ modules
- nftables-based packet filtering
- Fail2Ban integration
- Whitelist/blacklist management
- Control panel auto-detection (DirectAdmin, cPanel, Plesk)
- Safety mechanisms to prevent lockouts
- Comprehensive logging
- Backup and restore functionality

### Features
- Automatic firewall configuration
- Intrusion prevention with Fail2Ban
- IP whitelisting and blacklisting
- Temporary and permanent bans
- Port configuration management
- Email notifications
- Statistics and reporting
- Dry-run mode for safe testing

---

## Version Numbering Scheme

nftban follows [Semantic Versioning](https://semver.org/):

- **Major (X.0.0):** Breaking changes, major architecture overhauls
- **Minor (0.X.0):** New features, non-breaking changes
- **Patch (0.0.X):** Bug fixes, small improvements
- **Beta:** `-beta` suffix indicates active development/testing

**Current Status:** Beta (v0.8.5-beta)
**Stability:** Production-ready, actively seeking user feedback

---

## Upgrade Path

### From 0.8.0 to 0.8.5
```bash
# Standard upgrade (if auto-update configured)
sudo nftban update perform

# Manual upgrade
cd /etc/nftban
sudo git pull origin main
sudo systemctl restart nftables
sudo systemctl restart fail2ban
```

**Post-upgrade:**
```bash
# Verify installation
sudo nftban --version  # Should show v0.8.5

# Check new features
sudo nftban ddos status
sudo nftban portscan status

# Enable new features (optional)
sudo nftban ddos enable
sudo nftban portscan enable
```

### From 0.5.0 to 0.8.5
Recommended: Fresh installation due to major architectural changes.

---

## Future Roadmap

### Planned for 0.9.0
- GeoIP blocking integration
- Web-based management interface
- Advanced rate limiting profiles
- IPv6 feature parity
- Container/Docker support

### Planned for 1.0.0
- Stable release (exit beta)
- Full test coverage
- Performance benchmarks
- Security audit certification
- Enterprise support options

---

## Links

- **Repository:** https://github.com/itcmsgr/nftban
- **Issues:** https://github.com/itcmsgr/nftban/issues
- **Discussions:** https://github.com/itcmsgr/nftban/discussions
- **Documentation:** https://github.com/itcmsgr/nftban/tree/main/docs
- **Website:** https://itcms.gr
- **License:** LICENSE.md

---

## Support

- **Community Support:** GitHub Issues and Discussions
- **Professional Support:** contact@itcms.gr
- **Author:** Antonios Voulvoulis (ITCMS Team)

---

<p align="center">
  <sub>Copyright © 2025 Antonios Voulvoulis – ITCMS. All rights reserved.</sub><br>
  <sub>SPDX-License-Identifier: NFTBAN-Custom-License</sub>
</p>
