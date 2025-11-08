# NFTBan Installation Guide - AlmaLinux 9

> **Official Installation Guide for AlmaLinux 9.x**

## System Requirements

- AlmaLinux 9.0 or higher
- Minimum 2GB RAM
- 10GB free disk space
- Root or sudo access
- Internet connectivity

## Quick Install (Recommended)

```bash
# Download and install NFTBan
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-x86_64.rpm
sudo dnf install -y nftban-x86_64.rpm

# Enable protection
sudo nftban enable
```

## Step-by-Step Installation

### 1. Update System

```bash
sudo dnf update -y
```

### 2. Install Prerequisites

NFTBan requires the following packages:

```bash
sudo dnf install -y \
    nftables \
    fail2ban-server \
    jq \
    curl \
    python3 \
    git \
    polkit \
    newt \
    logrotate
```

### 3. Download NFTBan Package

```bash
cd /tmp
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-x86_64.rpm
```

### 4. Install NFTBan

```bash
sudo dnf install -y nftban-x86_64.rpm
```

### 5. Enable NFTBan Protection

```bash
sudo nftban enable
```

This will:
- Initialize the firewall
- Enable fail2ban SSH protection
- Start blocking malicious IPs
- Enable automatic updates

## Verification

Check NFTBan status:

```bash
nftban status
```

Check service status:

```bash
systemctl status nftban.timer
systemctl status fail2ban.service
```

View blocked IPs:

```bash
nftban list banned
```

## Configuration

Main configuration file:
```
/etc/nftban/nftban.conf
```

Additional features:
```
/etc/nftban/conf.d/geoip.conf    # GeoIP blocking
/etc/nftban/conf.d/feeds.conf    # Threat feeds (CloudFlare, etc.)
```

## Uninstall

To remove NFTBan while preserving configuration:

```bash
sudo dnf remove nftban
# Configuration backed up to /var/lib/nftban/config-backup-*/
```

To completely remove everything:

```bash
sudo dnf remove nftban
sudo rm -rf /etc/nftban /var/lib/nftban /var/log/nftban
```

## Troubleshooting

### Check logs
```bash
journalctl -u nftban.timer -n 50
journalctl -u fail2ban.service -n 50
```

### Health check
```bash
nftban health check
```

### Firewall status
```bash
nft list tables
nft list table inet nftban_main
```

## Support

- Documentation: `/usr/share/nftban/docs/`
- Issues: https://github.com/itcmsgr/nftban/issues
- Help: `nftban help`
