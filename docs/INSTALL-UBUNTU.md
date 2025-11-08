# NFTBan Installation Guide - Ubuntu

> **Official Installation Guide for Ubuntu 22.04 LTS / 24.04 LTS**

## System Requirements

- Ubuntu 22.04 LTS (Jammy) or Ubuntu 24.04 LTS (Noble)
- Minimum 2GB RAM
- 10GB free disk space
- Root or sudo access
- Internet connectivity

## Quick Install (Recommended)

```bash
# Download and install NFTBan
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-amd64.deb
sudo apt install -y ./nftban-amd64.deb

# Enable protection
sudo nftban enable
```

## Step-by-Step Installation

### 1. Update System

```bash
sudo apt update
sudo apt upgrade -y
```

### 2. Install Prerequisites

NFTBan requires the following packages:

```bash
sudo apt install -y \
    nftables \
    fail2ban \
    jq \
    curl \
    python3 \
    git \
    policykit-1 \
    whiptail \
    logrotate \
    wget
```

### 3. Download NFTBan Package

```bash
cd /tmp
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-amd64.deb
```

### 4. Install NFTBan

```bash
sudo apt install -y ./nftban-amd64.deb
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

## Ubuntu-Specific Notes

### UFW Conflict
If you have UFW enabled, it will conflict with NFTBan. You must disable UFW:

```bash
sudo ufw disable
sudo systemctl disable ufw
```

### AppArmor
NFTBan works with AppArmor enabled. No special configuration required.

## Uninstall

To remove NFTBan while preserving configuration:

```bash
sudo apt remove nftban
# Configuration backed up to /var/lib/nftban/config-backup-*/
```

To completely remove everything (purge):

```bash
sudo apt purge nftban
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
