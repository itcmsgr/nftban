# Ubuntu Installation Guide

## Quick Install

```bash
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-amd64.deb
sudo apt install -y ./nftban-amd64.deb
sudo nftban enable
```

## Prerequisites

Ubuntu 22.04/24.04 LTS requires these packages:

```bash
sudo apt update
sudo apt install -y nftables fail2ban jq curl python3 git policykit-1 whiptail
```

**IMPORTANT:** If UFW is enabled, disable it (conflicts with nftables):

```bash
sudo ufw disable
sudo systemctl disable ufw
```

## Installation Steps

1. **Download package:**
   ```bash
   wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-amd64.deb
   ```

2. **Install:**
   ```bash
   sudo apt install -y ./nftban-amd64.deb
   ```

3. **Enable protection:**
   ```bash
   sudo nftban enable
   ```

## Verify

```bash
nftban status
systemctl status nftban.timer
```

## Configuration

- Main config: `/etc/nftban/nftban.conf`
- Features: `/etc/nftban/conf.d/`
- Fail2ban: `/etc/fail2ban/jail.d/nftban-*.conf`

## Uninstall

```bash
sudo apt remove nftban
# Config backed up to /var/lib/nftban/config-backup-*/

# Complete removal (purge):
sudo apt purge nftban
```
