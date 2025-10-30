# NFTBan Quick Start Guide

Get NFTBan up and running in 5 minutes.

---

## What is NFTBan?

NFTBan is a modern, high-performance firewall management system for Linux servers that:

- **Prevents lockouts** with commit-confirm recovery (auto-rollback on SSH failure)
- **Blocks threats** using 8 security layers (DDoS, port scans, geo-blocking, threat feeds)
- **Processes feeds 10-60x faster** with optimized Go binaries
- **Self-heals** with automated health checks and auto-repair
- **Integrates with Fail2Ban** for automatic IP banning

**Perfect for:** VPS, dedicated servers, cloud instances running Rocky Linux, AlmaLinux, Fedora, Ubuntu, or Debian.

---

## System Requirements

**Supported Operating Systems:**
- Rocky Linux 9+
- AlmaLinux 9+
- Fedora 38+
- Ubuntu 22.04 LTS+
- Debian 12+

**Minimum Requirements:**
- 1 GB RAM
- 10 GB disk space
- nftables 1.0.0+
- systemd 250+
- Root access

---

## Installation

### Rocky Linux / AlmaLinux / Fedora

```bash
# Download latest release
wget https://github.com/nftban/nftban/releases/latest/download/nftban-0.10.0-1.el9.x86_64.rpm

# Install
sudo dnf install -y nftban-0.10.0-1.el9.x86_64.rpm

# Verify installation
nftban --version
```

### Ubuntu / Debian

```bash
# Download latest release
wget https://github.com/nftban/nftban/releases/latest/download/nftban_0.10.0-1_amd64.deb

# Install
sudo dpkg -i nftban_0.10.0-1_amd64.deb
sudo apt-get install -f  # Install any missing dependencies

# Verify installation
nftban --version
```

### From Source

```bash
# Clone repository
git clone https://github.com/nftban/nftban.git
cd nftban

# Run installer
sudo ./install.sh

# Verify installation
nftban --version
```

---

## First Run

### 1. Check System Health

```bash
sudo nftban health check
```

This verifies:
- ✓ Required commands installed (nft, systemctl, jq, etc.)
- ✓ Directories exist with correct permissions
- ✓ User/group configuration
- ✓ Systemd services available

**Expected output:** `✓ 0 issues found`

If issues found:
```bash
sudo nftban health fix all
```

### 2. Review Default Configuration

```bash
sudo cat /etc/nftban/nftban.conf
```

**Key settings to review:**
- `ENABLED=1` - Enable NFTBan
- `COMMIT_CONFIRM_TIMEOUT=300` - Rollback timeout (5 minutes)
- `DEFAULT_ACTION=drop` - Default action for blocked IPs
- `ALLOWED_PORTS="22 80 443"` - Ports to keep open

### 3. Customize Configuration (Optional)

```bash
# Create local override file (won't be overwritten on upgrades)
sudo vim /etc/nftban/nftban.conf.local
```

Example customizations:
```bash
# Allow additional ports
ALLOWED_PORTS="22 80 443 8080 3306"

# Enable geo-blocking for SSH (only allow specific countries)
GEOBLOCK_SSH_ENABLED=1
GEOBLOCK_SSH_ALLOW="US,CA,GB"

# Enable DDoS protection
DDOS_PROTECTION_ENABLED=1
DDOS_CONN_LIMIT=100
```

### 4. Apply Firewall Rules

```bash
sudo nftban apply
```

This:
1. Creates backup of current nftables config
2. Generates new nftables rules based on config
3. Applies rules with commit-confirm protection
4. Waits for confirmation (press Enter within 5 minutes)
5. Auto-rollsback if no confirmation (prevents lockout!)

**IMPORTANT:** Keep your SSH session open and press Enter when prompted to confirm the rules work.

### 5. Enable Automatic Updates

```bash
# Enable timers to run NFTBan and health checks
sudo systemctl enable --now nftban.timer
sudo systemctl enable --now nftban-health.timer

# Verify timers active
sudo systemctl status nftban.timer
```

**Timers:**
- `nftban.timer` - Runs every 5 minutes to update feeds and apply rules
- `nftban-health.timer` - Runs hourly to check system health

---

## Common Tasks

### View Current Bans

```bash
# Summary statistics
sudo nftban stats --summary

# Detailed statistics
sudo nftban stats --detailed

# View specific category
sudo nftban stats --category=ddos
```

### Manually Ban an IP

```bash
# Ban single IP
sudo nftban ban 192.0.2.100 "Manual ban - suspicious activity"

# Ban IP range (CIDR)
sudo nftban ban 192.0.2.0/24 "Ban entire subnet"

# Ban with expiration (seconds)
sudo nftban ban 192.0.2.100 "Temporary ban" --expires 3600
```

### Unban an IP

```bash
# Unban single IP
sudo nftban unban 192.0.2.100

# Unban range
sudo nftban unban 192.0.2.0/24
```

### Whitelist Trusted IPs

```bash
# Add to whitelist (never banned)
sudo nftban whitelist add 203.0.113.50 "Office IP"

# View whitelist
sudo nftban whitelist list

# Remove from whitelist
sudo nftban whitelist remove 203.0.113.50
```

### Update Threat Feeds

```bash
# Update all feeds
sudo nftban feeds update --all

# Update specific feed
sudo nftban feeds update spamhaus

# List available feeds
sudo nftban feeds list

# Show feed statistics
sudo nftban feeds stats
```

### Generate Reports

```bash
# HTML report (opens in browser)
sudo nftban report generate --format html --output /tmp/report.html

# JSON report (for automation)
sudo nftban report generate --format json --output /tmp/report.json

# CSV report (for spreadsheets)
sudo nftban report generate --format csv --output /tmp/report.csv

# Email report
sudo nftban report email admin@example.com
```

### Check Logs

```bash
# View recent activity
sudo tail -f /var/log/nftban/nftban.log

# Search for specific IP
sudo grep "192.0.2.100" /var/log/nftban/nftban.log

# View systemd journal
sudo journalctl -u nftban.service -f
```

---

## Integration with Fail2Ban

NFTBan works seamlessly with Fail2Ban for automatic IP banning.

### Install Fail2Ban

```bash
# Rocky/AlmaLinux/Fedora
sudo dnf install -y fail2ban

# Ubuntu/Debian
sudo apt-get install -y fail2ban
```

### Configure Fail2Ban

Create `/etc/fail2ban/jail.local`:

```ini
[DEFAULT]
# Ban for 24 hours
bantime = 86400

# After 3 failures
maxretry = 3

# Within 10 minutes
findtime = 600

# Use NFTBan for banning
banaction = nftban

[sshd]
enabled = true
port = 22
logpath = /var/log/auth.log

[nginx-limit-req]
enabled = true
port = 80,443
logpath = /var/log/nginx/error.log
```

### Create NFTBan Action for Fail2Ban

Create `/etc/fail2ban/action.d/nftban.conf`:

```ini
[Definition]
actionstart =
actionstop =
actioncheck =
actionban = /usr/sbin/nftban ban <ip> "Fail2Ban: <name>" --expires <bantime>
actionunban = /usr/sbin/nftban unban <ip>
```

### Restart Fail2Ban

```bash
sudo systemctl restart fail2ban
sudo systemctl status fail2ban
```

Now Fail2Ban automatically adds bans to NFTBan!

---

## Troubleshooting

### Issue: Locked out of SSH

**Solution:** Wait 5 minutes for auto-rollback, or:

1. Access server via console (VNC/IPMI)
2. Run: `sudo nftban rollback`
3. Review rules before re-applying

### Issue: Health check fails

```bash
# View issues
sudo nftban health check

# Auto-fix
sudo nftban health fix all
```

### Issue: Feeds not updating

```bash
# Check feed status
sudo nftban feeds list

# Manually update
sudo nftban feeds update --all --force

# Check logs
sudo journalctl -u nftban.service -n 50
```

### Issue: Rules not applying

```bash
# Check configuration
sudo nftban config validate

# View nftables rules
sudo nft list table inet nftban

# Reapply rules
sudo nftban apply --force
```

### Issue: High memory usage

```bash
# Check stats
sudo nftban stats --summary

# Reduce feed imports
sudo vim /etc/nftban/feeds.d/custom.conf
# Disable unused feeds

# Restart service
sudo systemctl restart nftban.service
```

---

## Next Steps

- **[User Guide](user-guide.md)** - Complete feature documentation
- **[Configuration Reference](configuration.md)** - All config options explained
- **[CLI Reference](cli-reference.md)** - Complete command reference
- **[Security Best Practices](security-best-practices.md)** - Hardening tips
- **[FAQ](faq.md)** - Frequently asked questions

---

## Getting Help

- **Documentation**: https://docs.nftban.com
- **GitHub Issues**: https://github.com/nftban/nftban/issues
- **Discussions**: https://github.com/nftban/nftban/discussions
- **Email**: support@nftban.com

---

## Upgrading

### RPM (Rocky/AlmaLinux/Fedora)

```bash
# Download new version
wget https://github.com/nftban/nftban/releases/latest/download/nftban-0.11.0-1.el9.x86_64.rpm

# Upgrade
sudo dnf upgrade -y nftban-0.11.0-1.el9.x86_64.rpm

# Verify
nftban --version
nftban health check
```

### DEB (Ubuntu/Debian)

```bash
# Download new version
wget https://github.com/nftban/nftban/releases/latest/download/nftban_0.11.0-1_amd64.deb

# Upgrade
sudo dpkg -i nftban_0.11.0-1_amd64.deb

# Verify
nftban --version
nftban health check
```

Your configuration files are preserved during upgrades!

---

## Uninstallation

### Keep Configuration

```bash
# RPM
sudo dnf remove nftban

# DEB
sudo apt-get remove nftban
```

Config remains in `/etc/nftban/` for reinstallation.

### Complete Removal

```bash
# RPM
sudo systemctl stop nftban.timer nftban-health.timer
sudo dnf remove nftban
sudo nft delete table inet nftban
sudo rm -rf /etc/nftban /var/lib/nftban /var/cache/nftban /var/log/nftban

# DEB
sudo systemctl stop nftban.timer nftban-health.timer
sudo apt-get purge nftban
sudo nft delete table inet nftban
sudo rm -rf /var/lib/nftban /var/cache/nftban /var/log/nftban
```

---

## License

NFTBan is licensed under the Mozilla Public License 2.0 (MPL-2.0).

See [LICENSE](../../LICENSE) for details.
