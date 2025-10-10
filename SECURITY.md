# Security Best Practices

**Complete Security Hardening Guide for nftban**

This guide covers security best practices, hardening techniques, and optimization strategies to maximize your server's security posture using nftban.

---

## Table of Contents

- [Initial Security Setup](#initial-security-setup)
- [SSH Hardening](#ssh-hardening)
- [Firewall Hardening](#firewall-hardening)
- [Fail2Ban Optimization](#fail2ban-optimization)
- [Monitoring and Alerting](#monitoring-and-alerting)
- [Rate Limiting and DDoS Protection](#rate-limiting-and-ddos-protection)
- [Advanced Security Configurations](#advanced-security-configurations)
- [Regular Maintenance](#regular-maintenance)
- [Backup and Recovery](#backup-and-recovery)
- [Common Security Mistakes](#common-security-mistakes)
- [Emergency Procedures](#emergency-procedures)
- [Compliance and Auditing](#compliance-and-auditing)

---

## Initial Security Setup

### First Steps After Installation

**Always whitelist your IP immediately:**

```bash
# Add your current IP
sudo nftban --add-ip

# Verify it's added
sudo nftban --verify-ip $(curl -s ifconfig.me)

# Check whitelist file
cat /etc/nftban/config/nftban-configuration-user-whitelist_ips.conf.local
```

**Test firewall rules before finalizing:**

```bash
# Use dry-run mode first
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-dry-run

# Review the generated rules
less /tmp/nftban_nftables.conf.tmp

# Apply when satisfied
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final
```

**Keep emergency access available:**

```bash
# Always have console/VNC access
# Document your hosting provider's console access method

# Consider a backup SSH port (advanced)
echo "2222T    # Backup SSH port" >> /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local
sudo nftban --sync

# Configure SSH to listen on multiple ports
sudo nano /etc/ssh/sshd_config
# Add: Port 2222
sudo systemctl restart sshd
```

### Defense in Depth Strategy

Never rely on a single security layer:

```
Layer 1: Network Firewall (nftables)
    ↓
Layer 2: Intrusion Prevention (Fail2Ban)
    ↓
Layer 3: SSH Hardening (keys, port changes)
    ↓
Layer 4: Service Hardening (minimal services)
    ↓
Layer 5: Monitoring & Alerting
    ↓
Layer 6: Regular Updates & Patches
```

---

## SSH Hardening

### Disable Password Authentication

**Use SSH keys only:**

```bash
# Generate SSH key on your local machine (if you don't have one)
ssh-keygen -t ed25519 -C "your_email@example.com"

# Copy to server
ssh-copy-id -i ~/.ssh/id_ed25519.pub user@server

# Test key login before disabling passwords!
ssh -i ~/.ssh/id_ed25519 user@server

# Disable password authentication
sudo nano /etc/ssh/sshd_config
```

**Recommended SSH settings:**

```bash
# /etc/ssh/sshd_config

# Disable password authentication
PasswordAuthentication no
ChallengeResponseAuthentication no

# Disable root login
PermitRootLogin no

# Allow only specific users (optional)
AllowUsers yourusername adminuser

# Use only strong key exchange algorithms
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org

# Use only strong ciphers
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com

# Use only strong MACs
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com

# Limit login grace time
LoginGraceTime 30s

# Maximum authentication attempts
MaxAuthTries 3

# Session timeouts
ClientAliveInterval 300
ClientAliveCountMax 2

# Disable unused features
X11Forwarding no
PermitTunnel no
AllowAgentForwarding no
AllowTcpForwarding no
```

**Apply changes:**

```bash
# Test configuration
sudo sshd -t

# Restart SSH (keep current session open!)
sudo systemctl restart sshd
```

### Change Default SSH Port

**Important:** Always whitelist your IP first!

```bash
# Choose a non-standard port (1024-65535)
NEW_PORT=2222

# Update nftban configuration
echo "${NEW_PORT}T    # Custom SSH port" >> /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local

# Apply firewall rules
sudo nftban --sync

# Verify port is open
sudo nft list ruleset | grep $NEW_PORT

# Update SSH configuration
sudo nano /etc/ssh/sshd_config
# Change: Port 2222

# Restart SSH
sudo systemctl restart sshd

# Test new port (in another terminal!)
ssh -p 2222 user@server

# Update Fail2Ban SSH jail
sudo nano /etc/fail2ban/jail.d/sshd.local
# Add: port = 2222
sudo systemctl restart fail2ban
```

### Enable Two-Factor Authentication (2FA)

```bash
# Install Google Authenticator
sudo apt-get install libpam-google-authenticator  # Debian/Ubuntu
sudo dnf install google-authenticator             # RHEL/CentOS

# Setup for your user
google-authenticator

# Answer:
# Time-based tokens: y
# Update .google_authenticator: y
# Disallow reuse: y
# Rate limiting: y
# Window of 3 codes: y

# Configure PAM
sudo nano /etc/pam.d/sshd
# Add at the top:
# auth required pam_google_authenticator.so

# Configure SSH
sudo nano /etc/ssh/sshd_config
# Set:
# ChallengeResponseAuthentication yes
# AuthenticationMethods publickey,keyboard-interactive

# Restart SSH
sudo systemctl restart sshd
```

---

## Firewall Hardening

### Strict Default Policy

nftban uses a **deny-by-default** policy. Verify this:

```bash
# Check default policy
sudo nft list ruleset | grep "policy drop"

# Should see:
# chain input { type filter hook input priority filter; policy drop; }
# chain forward { type filter hook forward priority filter; policy drop; }
```

### Minimize Open Ports

**Audit currently open ports:**

```bash
# List all allowed ports
cat /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf
cat /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local

# Check what's actually listening
sudo ss -tlnp
sudo netstat -tlnp
```

**Close unnecessary ports:**

```bash
# Example: Close MySQL to external access
# Remove or comment out in .conf.local:
sudo nano /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local

# If you need MySQL but only locally, use localhost binding
sudo nano /etc/mysql/my.cnf
# Set: bind-address = 127.0.0.1

# Apply changes
sudo nftban --sync
```

### Rate Limiting on Critical Services

Add rate limiting to prevent brute-force attacks:

```bash
# Create custom rate limit rules
sudo nano /etc/nftban/config/nftban-custom-rules.conf
```

```nft
# Rate limit SSH connections (example)
table inet filter {
    chain input {
        # Allow established connections
        ct state established,related accept
        
        # Rate limit new SSH connections
        tcp dport 22 ct state new limit rate 3/minute burst 5 packets accept
        tcp dport 22 reject with tcp reset
        
        # Rate limit HTTP/HTTPS
        tcp dport { 80, 443 } ct state new limit rate 100/second burst 200 packets accept
        
        # Rate limit DNS queries
        udp dport 53 limit rate 50/second burst 100 packets accept
    }
}
```

### Connection Tracking Optimization

```bash
# Increase connection tracking table size for busy servers
sudo nano /etc/sysctl.conf
```

```conf
# Connection tracking
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 1800

# Protection against SYN floods
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2

# Ignore ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0

# Ignore source routed packets
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# Ignore ICMP ping requests (optional)
# net.ipv4.icmp_echo_ignore_all = 1
```

**Apply sysctl changes:**

```bash
sudo sysctl -p
```

### Logging Strategy

**Enable comprehensive logging:**

```bash
# Add logging rules
sudo nano /etc/nftban/config/nftban-logging-rules.conf
```

```nft
# Log dropped packets (be careful, can generate lots of logs)
table inet filter {
    chain input {
        # Log dropped SSH attempts
        tcp dport 22 ct state new limit rate 1/second burst 3 packets log prefix "DROPPED SSH: "
        
        # Log all other drops (rate limited)
        limit rate 5/minute burst 5 packets log prefix "DROPPED: "
    }
}
```

**Monitor logs:**

```bash
# Watch firewall logs
sudo tail -f /var/log/syslog | grep "DROPPED"

# Analyze most common attackers
sudo grep "DROPPED SSH" /var/log/syslog | awk '{print $(NF-3)}' | sort | uniq -c | sort -rn | head -20
```

---

## Fail2Ban Optimization

### Fine-Tune Ban Times

```bash
# Edit Fail2Ban configuration
sudo nano /etc/nftban/config/nftban.conf.local
```

```bash
# Aggressive banning
NFTBAN_F2B_BANTIME="86400"        # 24 hours
NFTBAN_F2B_FINDTIME="600"         # 10 minutes
NFTBAN_F2B_MAXRETRY="3"           # 3 attempts

# For high-security environments
# NFTBAN_F2B_BANTIME="604800"     # 7 days
# NFTBAN_F2B_MAXRETRY="2"         # 2 attempts

# Recidive jail (repeat offenders)
NFTBAN_F2B_RECIDIVE_BANTIME="2592000"  # 30 days
NFTBAN_F2B_RECIDIVE_FINDTIME="86400"   # 24 hours
NFTBAN_F2B_RECIDIVE_MAXRETRY="3"
```

### Enable Important Jails

```bash
# Enable all security jails
sudo nano /etc/nftban/config/nftban.conf.local
```

```bash
NFTBAN_F2B_SSH_JAIL="true"
NFTBAN_F2B_SSH_DDOS_JAIL="true"
NFTBAN_F2B_RECIDIVE_JAIL="true"
NFTBAN_F2B_WORDPRESS_JAIL="true"      # If using WordPress
NFTBAN_F2B_POSTFIX_JAIL="true"        # If using mail server
NFTBAN_F2B_DOVECOT_JAIL="true"        # If using mail server
```

**Apply changes:**

```bash
sudo systemctl restart fail2ban

# Verify jails are active
sudo fail2ban-client status
```

### Create Custom Jails

**Example: Protect custom web application:**

```bash
# Create custom jail
sudo nano /etc/fail2ban/jail.d/custom-app.local
```

```ini
[custom-app-auth]
enabled = true
port = 8080
filter = custom-app-auth
logpath = /var/log/custom-app/access.log
maxretry = 5
findtime = 300
bantime = 3600
action = nftables-multiport[name=custom-app, port="8080"]
```

**Create filter:**

```bash
sudo nano /etc/fail2ban/filter.d/custom-app-auth.conf
```

```ini
[Definition]
failregex = ^<HOST> .* "POST /login HTTP.*" 401
            ^<HOST> .* "POST /api/auth HTTP.*" 403
ignoreregex =
```

**Test and reload:**

```bash
# Test filter
sudo fail2ban-regex /var/log/custom-app/access.log /etc/fail2ban/filter.d/custom-app-auth.conf

# Reload Fail2Ban
sudo systemctl reload fail2ban
```

### Whitelist Legitimate Services

```bash
# Whitelist monitoring services, APIs, etc.
sudo nano /etc/fail2ban/jail.local
```

```ini
[DEFAULT]
ignoreip = 127.0.0.1/8 
           ::1
           192.168.1.0/24
           203.0.113.10      # Your monitoring server
           198.51.100.20     # Your API gateway
```

---

## Monitoring and Alerting

### Email Alerts Configuration

```bash
# Configure email alerts
sudo nano /etc/nftban/config/nftban.conf.local
```

```bash
# Email configuration
NFTBAN_F2B_DESTEMAIL="security@yourdomain.com"
NFTBAN_F2B_SENDER="nftban@$(hostname -f)"
NFTBAN_F2B_ACTION="%(action_mwl)s"  # Mail with logs

# Enable email notifications
NFTBAN_F2B_ENABLE_EMAIL="true"
```

**Test email delivery:**

```bash
# Test mail system
echo "Test email from nftban" | mail -s "Test Email" security@yourdomain.com

# Test Fail2Ban email
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh test-mail security@yourdomain.com
```

### Enable Login Monitoring

```bash
# Enable comprehensive login monitoring
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh login-monitor enable hybrid

# This monitors:
# - SSH logins
# - sudo usage
# - root access
# - Failed login attempts
```

**Monitor login logs:**

```bash
# View recent login activity
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh login-monitor status

# Check specific log
sudo tail -f /var/log/nftban/nftban_login_monitor.log

# View failed SSH attempts
sudo grep "Failed password" /var/log/auth.log | tail -20
```

### Set Up Centralized Logging (Optional)

```bash
# Install rsyslog (usually pre-installed)
sudo apt-get install rsyslog

# Configure remote logging
sudo nano /etc/rsyslog.d/50-nftban.conf
```

```conf
# Send nftban logs to remote server
if $programname == 'nftban' then @@logserver.example.com:514
& stop

# Send firewall logs
if $msg contains 'DROPPED' then @@logserver.example.com:514
& stop
```

### Daily Security Reports

**Create automated daily report:**

```bash
# Create report script
sudo nano /usr/local/bin/nftban-daily-report.sh
```

```bash
#!/bin/bash

REPORT_EMAIL="security@yourdomain.com"
REPORT_FILE="/tmp/nftban-report-$(date +%Y%m%d).txt"

{
    echo "=== nftban Daily Security Report - $(date) ==="
    echo ""
    
    echo "=== Currently Banned IPs ==="
    sudo nftban --view-banned
    echo ""
    
    echo "=== Fail2Ban Statistics ==="
    sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh stats
    echo ""
    
    echo "=== Top 10 Attacking IPs (Today) ==="
    sudo grep "Ban " /var/log/fail2ban.log | grep "$(date +%Y-%m-%d)" | awk '{print $NF}' | sort | uniq -c | sort -rn | head -10
    echo ""
    
    echo "=== New SSH Logins (Last 24h) ==="
    sudo grep "Accepted" /var/log/auth.log | grep "$(date +%Y-%m-%d)" | tail -20
    echo ""
    
    echo "=== Failed SSH Attempts (Last 24h) ==="
    sudo grep "Failed password" /var/log/auth.log | grep "$(date +%Y-%m-%d)" | wc -l
    echo ""
    
    echo "=== System Status ==="
    sudo nftban status
    
} > "$REPORT_FILE"

# Email report
mail -s "nftban Daily Report - $(hostname)" "$REPORT_EMAIL" < "$REPORT_FILE"

# Clean up old reports (keep 30 days)
find /tmp -name "nftban-report-*.txt" -mtime +30 -delete
```

**Make executable and schedule:**

```bash
sudo chmod +x /usr/local/bin/nftban-daily-report.sh

# Add to crontab
sudo crontab -e
# Add: 0 8 * * * /usr/local/bin/nftban-daily-report.sh
```

---

## Rate Limiting and DDoS Protection

### Basic DDoS Protection

```bash
# Enable SSH DDoS jail
sudo nano /etc/nftban/config/nftban.conf.local
```

```bash
NFTBAN_F2B_SSH_DDOS_JAIL="true"
NFTBAN_F2B_SSH_DDOS_MAXRETRY="10"
NFTBAN_F2B_SSH_DDOS_FINDTIME="60"
```

### Advanced Rate Limiting

**Create advanced rate limit rules:**

```bash
sudo nano /etc/nftban/config/nftban-ratelimit.conf
```

```nft
table inet filter {
    # Create sets for rate limiting
    set ratelimit_v4 {
        type ipv4_addr
        size 65535
        flags dynamic,timeout
        timeout 1m
    }
    
    set ratelimit_v6 {
        type ipv6_addr
        size 65535
        flags dynamic,timeout
        timeout 1m
    }
    
    chain input {
        # HTTP/HTTPS rate limiting (100 req/sec per IP)
        tcp dport { 80, 443 } add @ratelimit_v4 { ip saddr limit rate over 100/second } drop
        tcp dport { 80, 443 } add @ratelimit_v6 { ip6 saddr limit rate over 100/second } drop
        
        # DNS rate limiting (50 queries/sec per IP)
        udp dport 53 add @ratelimit_v4 { ip saddr limit rate over 50/second } drop
        udp dport 53 add @ratelimit_v6 { ip6 saddr limit rate over 50/second } drop
    }
}
```

### SYN Flood Protection

```bash
# Kernel-level protection
sudo nano /etc/sysctl.d/99-ddos-protection.conf
```

```conf
# SYN flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_max_syn_backlog = 4096

# Reduce TIME_WAIT connections
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1

# Protect against IP spoofing
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Disable ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
```

**Apply:**

```bash
sudo sysctl -p /etc/sysctl.d/99-ddos-protection.conf
```

---

## Advanced Security Configurations

### GeoIP Blocking (Preparation)

*Note: Full GeoIP blocking is planned for future nftban versions. Here's manual setup:*

```bash
# Install GeoIP utilities
sudo apt-get install geoip-bin geoip-database  # Debian/Ubuntu
sudo dnf install GeoIP GeoIP-data              # RHEL/CentOS

# Test GeoIP lookup
geoiplookup 8.8.8.8

# Manual country blocking (example: block China and Russia)
sudo nano /etc/nftban/config/nftban-geoip-block.sh
```

```bash
#!/bin/bash
# Block countries by downloading their IP ranges

COUNTRIES="cn ru"  # ISO country codes

for country in $COUNTRIES; do
    # Download IP list (example source)
    wget -qO- "https://www.ipdeny.com/ipblocks/data/countries/${country}.zone" | \
    while read ip; do
        sudo nftban --perm-ban "$ip" "GeoIP block: $country"
    done
done
```

### Application-Specific Protection

**WordPress hardening:**

```bash
# Enable WordPress jails
sudo nano /etc/nftban/config/nftban.conf.local
```

```bash
NFTBAN_F2B_WORDPRESS_JAIL="true"
NFTBAN_F2B_WORDPRESS_MAXRETRY="3"
NFTBAN_F2B_WORDPRESS_BANTIME="86400"
```

**Protect wp-login.php:**

```bash
# Create custom WordPress filter
sudo nano /etc/fail2ban/filter.d/wordpress-extra.conf
```

```ini
[Definition]
failregex = ^<HOST> .* "POST /wp-login\.php
            ^<HOST> .* "POST /xmlrpc\.php
ignoreregex =
```

### Honeypot Ports

**Set up honeypot to identify scanners:**

```bash
# Create honeypot jail
sudo nano /etc/fail2ban/jail.d/honeypot.local
```

```ini
[honeypot]
enabled = true
port = 23,3389,5900,8888
filter = honeypot
logpath = /var/log/syslog
maxretry = 1
findtime = 3600
bantime = 604800
action = nftables-multiport[name=honeypot, port="23,3389,5900,8888"]
```

**Create filter:**

```bash
sudo nano /etc/fail2ban/filter.d/honeypot.conf
```

```ini
[Definition]
failregex = kernel:.*SRC=<HOST>.*DPT=(23|3389|5900|8888)
ignoreregex =
```

---

## Regular Maintenance

### Weekly Security Checklist

```bash
#!/bin/bash
# Save as /usr/local/bin/nftban-weekly-check.sh

echo "=== Weekly nftban Security Check ==="

# 1. Validate configuration sync
echo "[1/7] Checking configuration sync..."
sudo nftban --validate-sync

# 2. Check for banned IPs count
echo "[2/7] Checking banned IP count..."
BANNED_COUNT=$(sudo nftban --view-banned | grep -c ".")
echo "Currently banned IPs: $BANNED_COUNT"

# 3. Verify Fail2Ban status
echo "[3/7] Checking Fail2Ban status..."
sudo systemctl is-active fail2ban

# 4. Check for failed login attempts
echo "[4/7] Failed login attempts (last 7 days)..."
sudo grep "Failed password" /var/log/auth.log | wc -l

# 5. Review whitelist
echo "[5/7] Current whitelist..."
cat /etc/nftban/config/nftban-configuration-user-whitelist_ips.conf.local

# 6. Check disk space for logs
echo "[6/7] Log disk usage..."
du -sh /var/log/nftban/

# 7. System updates available
echo "[7/7] System updates..."
apt list --upgradable 2>/dev/null || dnf check-update

echo "=== Check Complete ==="
```

### Update Schedule

```bash
# Weekly system updates
sudo apt-get update && sudo apt-get upgrade -y  # Debian/Ubuntu
sudo dnf update -y                               # RHEL/CentOS

# Monthly full upgrade
sudo apt-get dist-upgrade -y     # Debian/Ubuntu
sudo dnf upgrade --refresh -y    # RHEL/CentOS

# Update nftban (if auto-update not enabled)
sudo /etc/nftban/scripts/nftban_init.sh --github --upgrade
```

### Log Rotation

```bash
# Configure log rotation
sudo nano /etc/logrotate.d/nftban
```

```conf
/var/log/nftban/*.log {
    daily
    rotate 30
    compress
    delaycompress
    notifempty
    create 0640 root root
    sharedscripts
    postrotate
        systemctl reload rsyslog > /dev/null 2>&1 || true
    endscript
}

/var/log/fail2ban.log {
    daily
    rotate 30
    compress
    delaycompress
    notifempty
    create 0640 root adm
    postrotate
        fail2ban-client flushlogs >/dev/null || true
    endscript
}
```

---

## Backup and Recovery

### Automated Backup Script

```bash
#!/bin/bash
# Save as /usr/local/bin/nftban-backup.sh

BACKUP_DIR="/var/backups/nftban"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/nftban-backup-$DATE.tar.gz"

# Create backup directory
mkdir -p "$BACKUP_DIR"

# Backup all nftban configurations
tar -czf "$BACKUP_FILE" \
    /etc/nftban/ \
    /etc/fail2ban/jail.d/ \
    /etc/fail2ban/filter.d/ \
    /etc/systemd/system/nftables.service

# Keep only last 30 backups
find "$BACKUP_DIR" -name "nftban-backup-*.tar.gz" -mtime +30 -delete

echo "Backup saved: $BACKUP_FILE"
```

**Schedule daily backups:**

```bash
sudo chmod +x /usr/local/bin/nftban-backup.sh

# Add to crontab
sudo crontab -e
# Add: 0 2 * * * /usr/local/bin/nftban-backup.sh
```

### Restore from Backup

```bash
# List available backups
ls -lh /var/backups/nftban/

# Restore from specific backup
BACKUP_FILE="/var/backups/nftban/nftban-backup-20250111_020000.tar.gz"
sudo tar -xzf "$BACKUP_FILE" -C /

# Reload services
sudo nftban --sync
sudo systemctl restart fail2ban
```

### Disaster Recovery Plan

**Create recovery documentation:**

```bash
# Save this information in a secure, offline location

# 1. Emergency access credentials
# - Console access URL: https://your-provider.com/console
# - Root password location: [secure location]
# - SSH key backup: [secure location]

# 2. Emergency firewall flush
sudo nft flush ruleset
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final

# 3. Reset Fail2Ban
sudo systemctl stop fail2ban
sudo fail2ban-client unban --all
sudo systemctl start fail2ban

# 4. Emergency whitelist
sudo nftban --add-ip YOUR.IP.ADDRESS.HERE

# 5. Restore from backup
sudo tar -xzf /var/backups/nftban/latest.tar.gz -C /
sudo nftban --sync
```

---

## Common Security Mistakes

### ❌ Mistake 1: Not Whitelisting Your Own IP

**Problem:** Locking yourself out after enabling strict rules.

**Solution:**
```bash
# Always whitelist first!
sudo nftban --add-ip
```

### ❌ Mistake 2: Closing All Ports

**Problem:** Accidentally blocking legitimate traffic.

**Solution:**
```bash
# Review before applying
sudo nftban --validate-sync

# Test with dry-run
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-dry-run
```

### ❌ Mistake 3: Too Aggressive Ban Times

**Problem:** Banning legitimate users for minor issues.

**Solution:**
```bash
# Start with moderate settings
NFTBAN_F2B_BANTIME="3600"      # 1 hour
NFTBAN_F2B_MAXRETRY="5"        # 5 attempts

# Increase gradually based on monitoring
```

### ❌ Mistake 4: Not Monitoring Logs

**Problem:** Missing security incidents.

**Solution:**
```bash
# Set up daily reports
sudo /usr/local/bin/nftban-daily-report.sh

# Enable email alerts
NFTBAN_F2B_ENABLE_EMAIL="true"
```

### ❌ Mistake 5: Ignoring Updates

**Problem:** Running outdated, vulnerable software.

**Solution:**
```bash
# Enable automatic updates (use with caution)
sudo apt-get install unattended-upgrades  # Debian/Ubuntu
sudo dnf install dnf-automatic             # RHEL/CentOS

# Or schedule manual updates
# Weekly: sudo apt-get update && sudo apt-get upgrade -y
```

### ❌ Mistake 6: Single Point of Failure

**Problem:** Relying only on firewall.

**Solution:**
- Use SSH keys + 2FA
- Regular backups
- Monitoring and alerting
- Update all software regularly
- Minimize attack surface

---

## Emergency Procedures

### Lockout Recovery

**If locked out via SSH:**

```bash
# Option 1: Use console access (best)
# Log in via your hosting provider's console
# Then whitelist your IP:
sudo nftban --add-ip

# Option 2: Temporary firewall flush (dangerous!)
# Only use if absolutely necessary
sudo nft flush ruleset
# Fix issue quickly, then reapply:
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final
```

### Under Active Attack

**Immediate response to active attack:**

```bash
# 1. Identify attacking IPs
sudo tail -f /var/log/auth.log | grep "Failed password"

# 2. Ban attacker immediately
sudo nftban --perm-ban ATTACKER.IP.ADDRESS "Active attack"

# 3. Check Fail2Ban statistics
sudo fail2ban-client status sshd

# 4. Review all current bans
sudo nftban --view-banned

# 5. Temporarily block entire country (if needed)
# Use GeoIP blocking or contact your hosting provider
```

### Service Recovery

**If services become unreachable:**

```bash
# 1. Check service status
sudo systemctl status nftables
sudo systemctl status fail2ban

# 2. Validate configuration
sudo nftban --validate-sync

# 3. Review firewall rules
sudo nft list ruleset | less

# 4. Check for errors
sudo journalctl -u nftables -n 50
sudo journalctl -u fail2ban -n 50

# 5. Restart services
sudo systemctl restart nftables
sudo systemctl restart fail2ban
```

---

## Compliance and Auditing

### Logging for Compliance

**Enable comprehensive logging:**

```bash
# Configure auditd (if required for compliance)
sudo apt-get install auditd
sudo systemctl enable --now auditd

# Add firewall audit rules
sudo nano /etc/audit/rules.d/nftban.rules
```

```conf
# Monitor nftban configuration changes
-w /etc/nftban/ -p wa -k nftban_config
-w /etc/fail2ban/ -p wa -k fail2ban_config

# Monitor firewall changes
-w /usr/sbin/nft -p x -k nftables_exec
-w /etc/nftables.conf -p wa -k nftables_config
```

### Audit Trail

**Generate audit report:**

```bash
#!/bin/bash
# Save as /usr/local/bin/nftban-audit-report.sh

echo "=== nftban Security Audit Report ==="
echo "Generated: $(date)"
echo ""

echo "=== Configuration Changes (Last 30 days) ==="
sudo ausearch -k nftban_config -ts recent | grep -v "type=CONFIG_CHANGE"

echo ""
echo "=== Ban Statistics (Last 30 days) ==="
sudo grep "Ban " /var/log/fail2ban.log | wc -l

echo ""
echo "=== Most Banned IPs ==="
sudo grep "Ban " /var/log/fail2ban.log | awk '{print $NF}' | sort | uniq -c | sort -rn | head -20

echo ""
echo "=== Current Security Status ==="
sudo nftban status
```

### Retention Policies

```bash
# Configure log retention
sudo nano /etc/logrotate.d/nftban
```

```conf
# Retain logs based on compliance requirements
# Example: PCI DSS requires 1 year
/var/log/nftban/*.log {
    daily
    rotate 365
    compress
    delaycompress
    notifempty
    create 0640 root root
}
```

---

## Security Hardening Checklist

Use this checklist to verify your security posture:

### Initial Setup
- [ ] Whitelist your IP address
- [ ] Test firewall rules with dry-run
- [ ] Keep console access available
- [ ] Document emergency procedures

### SSH Security
- [ ] Disable password authentication
- [ ] Use SSH keys only
- [ ] Disable root login
- [ ] Change default SSH port
- [ ] Enable 2FA (recommended)
- [ ] Set login grace timeout
- [ ] Limit authentication attempts

### Firewall Configuration
- [ ] Verify deny-by-default policy
- [ ] Minimize open ports
- [ ] Enable rate limiting
- [ ] Configure connection tracking
- [ ] Enable logging (with limits)
- [ ] Review rules regularly

### Fail2Ban Setup
- [ ] Enable SSH jail
- [ ] Enable SSH DDoS jail
- [ ] Enable recidive jail
- [ ] Configure appropriate ban times
- [ ] Set up email alerts
- [ ] Create custom jails as needed
- [ ] Whitelist legitimate services

### Monitoring
- [ ] Enable login monitoring
- [ ] Configure email alerts
- [ ] Set up daily reports
- [ ] Review logs regularly
- [ ] Monitor disk space
- [ ] Check ban statistics

### Maintenance
- [ ] Schedule regular updates
- [ ] Configure log rotation
- [ ] Set up automated backups
- [ ] Test restore procedures
- [ ] Document changes
- [ ] Review security weekly

### Advanced
- [ ] Implement rate limiting
- [ ] Configure DDoS protection
- [ ] Set up honeypot ports (optional)
- [ ] Plan GeoIP blocking (optional)
- [ ] Integrate with SIEM (optional)
- [ ] Enable audit logging (if required)

---

## Additional Resources

### Official Documentation
- [nftables Wiki](https://wiki.nftables.org/)
- [Fail2ban Manual](https://fail2ban.readthedocs.io/)
- [SSH Hardening Guide](https://www.ssh.com/academy/ssh/security-hardening)

### Security Standards
- [CIS Benchmarks](https://www.cisecurity.org/cis-benchmarks/)
- [NIST Cybersecurity Framework](https://www.nist.gov/cyberframework)
- [OWASP Guidelines](https://owasp.org/)

### Testing Tools
- `nmap` - Port scanning and security auditing
- `fail2ban-regex` - Test Fail2Ban filters
- `nft` - View and test firewall rules
- `ss` / `netstat` - Check open ports

---

## Need Help?

**Community Support:**
- [GitHub Issues](https://github.com/itcmsgr/nftban/issues)
- [GitHub Discussions](https://github.com/itcmsgr/nftban/discussions)

**Professional Support:**
- Email: support@itcms.gr
- Website: [https://itcms.gr](https://itcms.gr)

---

<p align="center">
  <b>Stay Secure! 🛡️</b><br>
  <sub>Remember: Security is a process, not a product.</sub>
</p>

<p align="center">
  <sub>Copyright © 2025 Antonios Voulvoulis – ITCMS. All rights reserved.</sub>
</p>
