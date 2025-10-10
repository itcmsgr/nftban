# Changelog

All notable changes to nftban will be documented in this file.

## [0.5.0-beta] - 2025-10-26

### Initial Beta Release

This is the first public beta release of nftban - a comprehensive Linux firewall management system combining nftables and Fail2Ban.

#### Core Features
- **Automated Installation**: One-command setup with GitHub integration
- **Control Panel Detection**: Automatic detection and configuration for DirectAdmin, cPanel/WHM, and Plesk
- **nftables Firewall**: Modern packet filtering with global table architecture
- **Fail2Ban Integration**: Automated intrusion prevention with nftables backend
- **Login Monitoring**: Real-time and periodic security monitoring with email alerts
- **User-Friendly CLI**: Simple commands for ban/unban operations and system management

#### Components Included
- `nftban_init.sh` - System preparation and package installation
- `nftban_init_nftables_conf.sh` - Firewall configuration and rule management
- `nftban_init_fail2ban_conf.sh` - Intrusion prevention setup
- `nftban` CLI - Daily operations tool

#### Supported Platforms
- Debian 10+
- Ubuntu 20.04+
- RHEL/CentOS/Rocky/AlmaLinux 8+
- Fedora 35+
- openSUSE Leap 15+
- Alpine Linux 3.15+

#### Security Features
- Multi-layer IP filtering (whitelist, blacklist, temporary bans)
- Automatic attacker detection and banning
- Rate limiting and DOS protection
- Email alert system
- Configuration validation and backup

**Note:** This is a beta release. Please report any issues on [GitHub Issues](https://github.com/itcmsgr/nftban/issues).

---

## Future Releases

### [Planned for 0.6.0-beta]
- GeoIP blocking rules

### [Planned for 1.0.0 - Stable]
- Production-ready release
- Complete documentation
- Extended control panel support

