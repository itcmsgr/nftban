# NFTBan Suricata Configuration Files

## File Organization

This directory contains Suricata IDS configuration files optimized for NFTBan v1.0.

### Configuration Files Structure

```
etc/suricata/
├── filters.conf                    # NFTBan filter config (DEFAULT - don't edit)
├── filters.conf.local.example      # Example user overrides for filters
├── enable.conf                     # Suricata rules to enable (DEFAULT - don't edit)
├── enable.conf.local.example       # Example user additions for enabled rules
├── disable.conf                    # Suricata rules to disable (DEFAULT - don't edit)
├── disable.conf.local.example      # Example user additions for disabled rules
└── rules/
    └── local.rules                 # Custom Suricata rules (user-editable)
```

---

## Configuration Pattern

### ⚠️ **DEFAULT files (.conf)**
- Managed by NFTBan
- **Will be overwritten on updates**
- **DO NOT EDIT these files**

### ✅ **LOCAL files (.conf.local)**
- User customizations
- **Never overwritten**
- **Safe to edit**

### 📋 **EXAMPLE files (.conf.local.example)**
- Templates showing usage examples
- Copy to `.conf.local` to activate

---

## Files Explained

### 1. **filters.conf** (NFTBan Filter Configuration)
**Purpose:** Controls how NFTBan processes Suricata alerts

**Features:**
- Score thresholds for banning
- Ban durations (30m, 1h, 24h, etc.)
- Escalation policies (temporary → permanent)
- Action modes (log, observe, ban)
- Keywords for matching alerts

**Default Status:** Ships with balanced defaults for SSH, web, malware, botnet detection

**User Customization:**
```bash
# Copy example to create your local config
cp filters.conf.local.example filters.conf.local

# Edit with your custom thresholds, ban times, etc.
nano filters.conf.local
```

**Example Override:**
```ini
[filters]
# Make SSH protection more aggressive
ssh = true | ssh,brute | 70 | 20m | ban | escalate:2:12h | SSH (stricter)

# Enable FTP protection (disabled by default)
ftp = true | ftp,vsftpd | 85 | 1h | ban | escalate:3:24h | FTP attacks
```

---

### 2. **enable.conf** (Suricata Rule Enablement)
**Purpose:** Defines which Suricata detection rules to enable

**Default Configuration:**
- ✅ SSH protection (brute-force, attacks)
- ✅ Web exploits (SQLi, XSS, RFI, LFI)
- ✅ WordPress attacks
- ✅ Port scanning
- ✅ Botnet detection (Mirai, Gafgyt, XORDDoS, etc.)
- ✅ Cryptominers
- ✅ DNS attacks
- ✅ TLS monitoring
- ✅ Exploit detection
- ❌ Mail (SMTP/IMAP/POP3) - DISABLED by default
- ❌ FTP - DISABLED by default
- ❌ Database (MySQL/PostgreSQL) - DISABLED by default

**Resource Impact:** ~5-15% CPU, ~300-500 MB RAM (minimal profile)

**User Customization:**
```bash
# Copy example to create your local config
cp enable.conf.local.example enable.conf.local

# Edit to add services you run
nano enable.conf.local
```

**Example Additions:**
```bash
# Enable mail protection (if you run Postfix/Dovecot)
re:smtp
re:SMTP
re:imap
re:IMAP

# Enable FTP protection
re:ftp
re:FTP

# Enable database protection
re:mysql
re:MySQL
```

---

### 3. **disable.conf** (Suricata Rule Disablement)
**Purpose:** Defines which Suricata detection rules to disable (reduce noise)

**Default Disabled:**
- ❌ Windows protocols (SMB, DCERPC, RDP)
- ❌ Database protocols (MySQL, PostgreSQL, etc.)
- ❌ VoIP/SIP
- ❌ SCADA/ICS
- ❌ Chat/P2P/Gaming
- ❌ Streaming media
- ❌ Policy rules (corporate monitoring)
- ❌ Informational alerts

**Resource Savings:** ~20-40% CPU reduction by disabling unused protocols

**User Customization:**
```bash
# Copy example to create your local config
cp disable.conf.local.example disable.conf.local

# Edit to disable additional noisy rules
nano disable.conf.local
```

**Example Additions:**
```bash
# Disable DNS query noise (if too many alerts)
re:ET DNS query
re:DNS query for

# Disable scan alerts (if you run Nmap internally)
re:ET SCAN
re:port scan

# Disable specific noisy rule by SID
2001219  # ET SCAN SSH BruteForce Tool
```

---

### 4. **local.rules** (Custom Suricata Rules)
**Purpose:** Your custom Suricata detection signatures

**Location:** `/etc/suricata/rules/local.rules`

**Example Rules:**
```
# Detect outbound SSH brute-forcing (kthreadadd64-style malware)
alert tcp $HOME_NET any -> any 22 (msg:"LOCAL BOTNET Outbound SSH Brute Force"; \
  flow:to_server,established; content:"SSH-"; depth:4; \
  threshold:type threshold, track by_src, count 10, seconds 60; \
  sid:9000001; rev:1;)

# Detect WordPress wp-login.php brute-force
alert http any any -> $HOME_NET any (msg:"LOCAL WEB WordPress Login Brute Force"; \
  flow:to_server,established; http.uri; content:"/wp-login.php"; \
  threshold:type threshold, track by_src, count 10, seconds 60; \
  sid:9000002; rev:1;)
```

**User Customization:**
- Fully user-editable
- Never overwritten
- Use SID range 9000000-9999999 for local rules

---

## Usage Examples

### Scenario 1: VPS/Cloud Server (Minimal)
**Services:** SSH + Nginx

**Configuration:**
1. Use default `filters.conf` (no changes needed)
2. Use default `enable.conf` (covers SSH + web)
3. Use default `disable.conf` (disables unused services)

**Result:** 5-15% CPU, 300-500 MB RAM

---

### Scenario 2: cPanel/DirectAdmin Hosting
**Services:** SSH, Nginx, Apache, Postfix, Dovecot, FTP

**Configuration:**
1. Keep default `filters.conf`
2. Create `enable.conf.local`:
   ```bash
   # Enable mail protection
   re:smtp
   re:SMTP
   re:imap
   re:IMAP

   # Enable FTP protection
   re:ftp
   re:FTP
   ```
3. Create `filters.conf.local`:
   ```ini
   [filters]
   mail = true | smtp,imap,pop3 | 90 | 45m | ban | escalate:3:24h | Mail abuse
   ftp  = true | ftp,vsftpd | 85 | 1h | ban | escalate:3:24h | FTP attacks
   ```

**Result:** 15-30% CPU, 500-800 MB RAM

---

### Scenario 3: High-Security Server
**Services:** All protections enabled

**Configuration:**
1. Keep default `filters.conf`
2. Create `enable.conf.local`:
   ```bash
   # Enable everything
   re:smtp
   re:ftp
   re:mysql
   re:ET TROJAN
   re:ransomware
   re:exploit.*kit
   ```
3. Tune `filters.conf.local` for aggressive banning

**Result:** 30-50% CPU, 800MB-1.2GB RAM

---

## Applying Configuration Changes

### Step 1: Update Suricata Rules
```bash
# If you have .local files, include them:
suricata-update \
  --enable-conf /etc/suricata/enable.conf \
  --enable-conf /etc/suricata/enable.conf.local \
  --disable-conf /etc/suricata/disable.conf \
  --disable-conf /etc/suricata/disable.conf.local

# If you only use defaults:
suricata-update \
  --enable-conf /etc/suricata/enable.conf \
  --disable-conf /etc/suricata/disable.conf
```

### Step 2: Test Configuration
```bash
# Validate suricata.yaml syntax
suricata -T -c /etc/suricata/suricata.yaml

# Check how many rules loaded
grep "rule reload complete" /var/log/suricata/suricata.log
```

### Step 3: Restart Suricata
```bash
# Apply changes
systemctl restart suricata

# Verify running
systemctl status suricata
```

### Step 4: Monitor Resource Usage
```bash
# CPU and RAM usage
systemd-cgtop | grep suricata
ps aux | grep suricata

# Check alerts
tail -f /var/log/suricata/eve.json | jq 'select(.event_type=="alert")'
```

---

## Troubleshooting

### Too Many Alerts?
1. Add noisy patterns to `disable.conf.local`
2. Increase thresholds in `filters.conf.local`
3. Switch action from `ban` to `observe` temporarily

### Too Few Alerts?
1. Lower thresholds in `filters.conf.local`
2. Add more patterns to `enable.conf.local`
3. Check Suricata is actually running and processing traffic

### High CPU Usage?
1. Disable unused protocols in `disable.conf.local`
2. Reduce enabled rules in `enable.conf.local`
3. Check `/install/templates/suricata.yaml.optimized` for tuning

### False Positives?
1. Identify rule SID causing false positive
2. Add SID to `disable.conf.local`
3. Or adjust threshold in `filters.conf.local`

---

## Performance Profiles

| Profile | CPU | RAM | Rules Enabled | Use Case |
|---------|-----|-----|---------------|----------|
| **Minimal** | 5-15% | 300-500 MB | SSH, Web, Scan, Botnet, Miner | VPS/Cloud |
| **Standard** | 15-30% | 500-800 MB | + Mail, FTP, DNS | cPanel/DA |
| **Maximum** | 30-50% | 800MB-1.2GB | + Trojan, Exploit kits, All | High-security |

---

## Best Practices

1. **Start Minimal:** Use defaults, only add what you need
2. **Test in Stages:**
   - `action=log` (testing)
   - `action=observe` (tuning)
   - `action=ban` (production)
3. **Use Escalation:** `escalate:3:24h` instead of permanent immediately
4. **Monitor Regularly:** Check `eve.json` for alert patterns
5. **Keep .local Files:** Never edit default configs directly
6. **Document Changes:** Comment your .local files explaining why

---

## See Also

- **Suricata YAML Optimization:** `/install/templates/suricata.yaml.optimized`
- **Installation Script:** `/cli/lib/nftban/setup/install_suricata.sh`
- **Migration Guide:** `/docs/migration/FAIL2BAN_TO_SURICATA_MIGRATION.md`
- **NFTBan Filters:** `/etc/suricata/filters.conf`

---

**Last Updated:** 2025-11-29
**NFTBan Version:** 1.0.0
