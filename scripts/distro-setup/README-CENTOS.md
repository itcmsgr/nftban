# CentOS Stream Installation Guide

## Quick Install

```bash
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-x86_64.rpm
sudo dnf install -y nftban-x86_64.rpm
sudo nftban enable
```

## Prerequisites

CentOS Stream 9 requires EPEL repository:

```bash
sudo dnf install -y epel-release
sudo dnf config-manager --set-enabled crb
```

Then install dependencies:

```bash
sudo dnf install -y nftables fail2ban-server jq curl python3 git polkit newt
```

## Installation Steps

1. **Download package:**
   ```bash
   wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-x86_64.rpm
   ```

2. **Install:**
   ```bash
   sudo dnf install -y nftban-x86_64.rpm
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
sudo dnf remove nftban
# Config backed up to /var/lib/nftban/config-backup-*/
```
