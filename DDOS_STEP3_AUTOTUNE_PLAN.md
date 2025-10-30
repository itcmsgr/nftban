# DDOS Step 3: Auto-Tune Script - Detailed Plan
**Date:** 2025-10-30
**Status:** Planning Phase
**Goal:** Intelligent detection and suggestion of DDOS limits per server

---

## 🎯 OBJECTIVES

1. **Detect server profile** (hosting type, resources, services)
2. **Analyze traffic patterns** (from logs if available)
3. **Suggest appropriate limits** based on detection
4. **Explain reasoning** behind suggestions
5. **Allow easy application** of suggestions

---

## 🔍 DETECTION PHASES

### Phase 1: Hardware Detection

**What to detect:**
```bash
1. RAM amount
   ├─ <4 GB     = Low resources → conservative limits
   ├─ 4-16 GB   = Medium resources → moderate limits
   └─ >16 GB    = High resources → can handle more

2. CPU cores
   ├─ 1-2 cores = Single/small workload
   ├─ 4-8 cores = Medium workload
   └─ 8+ cores  = Heavy workload or multi-tenant

3. Disk type (optional)
   ├─ HDD = Slower, fewer concurrent connections recommended
   └─ SSD = Faster, can handle more connections
```

**Implementation:**
```bash
# RAM detection
total_ram_gb=$(free -g | awk '/^Mem:/ {print $2}')

# CPU detection
cpu_cores=$(nproc)

# Disk type (for primary mount)
disk_type=$(lsblk -d -o name,rota | grep -v loop | awk 'NR==2 {if($2==0) print "SSD"; else print "HDD"}')
```

---

### Phase 2: Hosting Panel Detection

**What to detect:**
```bash
1. cPanel
   └─ Check: /usr/local/cpanel/version
   └─ Profile: multisite-hosting (conservative)

2. DirectAdmin
   └─ Check: /usr/local/directadmin/directadmin
   └─ Profile: multisite-hosting (conservative)

3. Plesk
   └─ Check: /usr/local/psa/version
   └─ Profile: multisite-hosting (conservative)

4. Webmin/Virtualmin
   └─ Check: /etc/webmin/miniserv.conf
   └─ Profile: multisite-hosting (conservative)

5. ISPConfig
   └─ Check: /usr/local/ispconfig
   └─ Profile: multisite-hosting (conservative)

6. CloudLinux
   └─ Check: /etc/redhat-release contains "CloudLinux"
   └─ Profile: multisite-hosting (extra conservative)

7. No Panel
   └─ Continue to website count detection
```

**Implementation:**
```bash
detect_panel() {
    local panel="none"

    if [[ -f /usr/local/cpanel/version ]]; then
        panel="cPanel"
    elif [[ -f /usr/local/directadmin/directadmin ]]; then
        panel="DirectAdmin"
    elif [[ -f /usr/local/psa/version ]]; then
        panel="Plesk"
    elif [[ -f /etc/webmin/miniserv.conf ]]; then
        panel="Webmin"
    elif [[ -d /usr/local/ispconfig ]]; then
        panel="ISPConfig"
    fi

    # Check for CloudLinux
    if grep -q "CloudLinux" /etc/redhat-release 2>/dev/null; then
        panel="${panel:-none} (CloudLinux)"
    fi

    echo "$panel"
}
```

---

### Phase 3: Website/Domain Count

**What to count:**
```bash
1. nginx vhosts
   └─ Count: /etc/nginx/sites-enabled/* or /etc/nginx/conf.d/*

2. Apache vhosts
   └─ Count: /etc/httpd/conf.d/* or /etc/apache2/sites-enabled/*

3. Domains (from panel)
   └─ cPanel: whmapi1 listaccts
   └─ DirectAdmin: cat /usr/local/directadmin/data/users/*/domains.list
   └─ Plesk: mysql -uadmin -p`cat /etc/psa/.psa.shadow` psa -Nse "SELECT COUNT(*) FROM domains"

4. PHP-FPM pools
   └─ Count: /etc/php-fpm.d/*.conf or /etc/php/*/fpm/pool.d/*.conf
```

**Implementation:**
```bash
count_websites() {
    local count=0

    # nginx
    if [[ -d /etc/nginx/sites-enabled ]]; then
        count=$((count + $(ls -1 /etc/nginx/sites-enabled/ 2>/dev/null | wc -l)))
    fi
    if [[ -d /etc/nginx/conf.d ]]; then
        count=$((count + $(grep -l "server_name" /etc/nginx/conf.d/*.conf 2>/dev/null | wc -l)))
    fi

    # Apache
    if [[ -d /etc/httpd/conf.d ]]; then
        count=$((count + $(grep -l "ServerName" /etc/httpd/conf.d/*.conf 2>/dev/null | wc -l)))
    fi

    # cPanel
    if command -v whmapi1 &>/dev/null; then
        count=$(whmapi1 listaccts | grep -c "user:")
    fi

    # DirectAdmin
    if [[ -d /usr/local/directadmin/data/users ]]; then
        count=$(find /usr/local/directadmin/data/users -name "domains.list" -exec cat {} \; | wc -l)
    fi

    echo "$count"
}
```

**Interpretation:**
```bash
if [[ $website_count -gt 50 ]]; then
    profile="multisite-hosting-large"
    http_limit=400
elif [[ $website_count -gt 20 ]]; then
    profile="multisite-hosting"
    http_limit=300
elif [[ $website_count -gt 5 ]]; then
    profile="shared-hosting"
    http_limit=200
elif [[ $website_count -gt 0 ]]; then
    profile="single-business"
    http_limit=150
else
    profile="api-gateway"  # No traditional websites
    http_limit=100
fi
```

---

### Phase 4: Service Detection

**What to detect:**
```bash
1. Web servers
   ├─ nginx
   ├─ apache/httpd
   ├─ lighttpd
   └─ HAProxy (reverse proxy)

2. Mail servers
   ├─ postfix (SMTP)
   ├─ dovecot (IMAP/POP3)
   ├─ exim
   └─ count mail domains

3. Database servers
   ├─ mysql/mariadb
   ├─ postgresql
   └─ redis/memcached

4. Application servers
   ├─ php-fpm (count pools)
   ├─ nodejs (count processes)
   ├─ python (Django, Flask, etc.)
   └─ ruby (Rails)

5. Proxy/CDN
   ├─ HAProxy
   ├─ nginx as reverse proxy
   └─ Cloudflare detected via DNS
```

**Implementation:**
```bash
detect_services() {
    declare -A services

    # Web servers
    systemctl is-active nginx &>/dev/null && services[nginx]=1
    systemctl is-active httpd &>/dev/null && services[apache]=1
    systemctl is-active haproxy &>/dev/null && services[haproxy]=1

    # Mail
    systemctl is-active postfix &>/dev/null && services[postfix]=1
    systemctl is-active dovecot &>/dev/null && services[dovecot]=1

    # Database
    systemctl is-active mariadb &>/dev/null && services[mariadb]=1
    systemctl is-active postgresql &>/dev/null && services[postgresql]=1

    # Count mail domains
    if [[ ${services[postfix]} ]]; then
        local mail_domains=$(postconf virtual_alias_domains 2>/dev/null | wc -l)
        services[mail_domains]=$mail_domains
    fi

    # Output
    for service in "${!services[@]}"; do
        echo "$service"
    done
}
```

**Interpretation:**
```bash
# If heavy mail server
if [[ ${services[dovecot]} && ${mail_domains} -gt 20 ]]; then
    smtp_limit=100
    imap_limit=200
    profile_hint="office-email or shared-mail"
fi

# If reverse proxy only
if [[ ${services[haproxy]} && ! ${services[php-fpm]} ]]; then
    http_limit=100
    profile_hint="api-gateway or reverse-proxy"
fi
```

---

### Phase 5: Traffic Analysis (If Logs Available)

**What to analyze:**
```bash
1. HTTP access logs (last 24h)
   └─ Connections per IP (95th percentile)
   └─ Requests per second (peak)
   └─ Unique IPs accessing

2. SSH auth logs (last 24h)
   └─ Max concurrent connections per IP
   └─ Failed attempts pattern

3. Mail logs (last 24h)
   └─ SMTP connections per IP
   └─ IMAP sessions per IP
   └─ Peak connection count

4. Connection tracking (if available)
   └─ Current nftables counters
   └─ Historical connection patterns
```

**Implementation:**
```bash
analyze_http_traffic() {
    local log_file="/var/log/nginx/access.log"
    [[ ! -f "$log_file" ]] && log_file="/var/log/httpd/access_log"
    [[ ! -f "$log_file" ]] && echo "0" && return

    # Get last 24 hours
    local yesterday=$(date -d '24 hours ago' +%d/%b/%Y)

    # Count connections per IP, get 95th percentile
    local p95=$(awk -v date="$yesterday" '$4 ~ date {print $1}' "$log_file" | \
                sort | uniq -c | sort -rn | \
                awk '{print $1}' | \
                awk '{a[NR]=$1} END {print a[int(NR*0.95)]}')

    echo "${p95:-0}"
}

analyze_ssh_traffic() {
    local log_file="/var/log/auth.log"
    [[ ! -f "$log_file" ]] && log_file="/var/log/secure"
    [[ ! -f "$log_file" ]] && echo "0" && return

    # Count max concurrent SSH connections per IP
    local max_conns=$(grep "sshd.*Accepted" "$log_file" | \
                      awk '{print $(NF-3)}' | \
                      sort | uniq -c | sort -rn | head -1 | awk '{print $1}')

    echo "${max_conns:-0}"
}

analyze_mail_traffic() {
    local log_file="/var/log/maillog"
    [[ ! -f "$log_file" ]] && log_file="/var/log/mail.log"
    [[ ! -f "$log_file" ]] && echo "0 0" && return

    # SMTP connections per IP (95th percentile)
    local smtp_p95=$(grep "postfix.*connect from" "$log_file" | \
                     awk '{print $(NF-1)}' | tr -d '[]' | \
                     sort | uniq -c | sort -rn | \
                     awk '{print $1}' | \
                     awk '{a[NR]=$1} END {print a[int(NR*0.95)]}')

    # IMAP connections per IP (95th percentile)
    local imap_p95=$(grep "dovecot.*imap-login.*Login" "$log_file" | \
                     awk '{print $NF}' | \
                     sort | uniq -c | sort -rn | \
                     awk '{print $1}' | \
                     awk '{a[NR]=$1} END {print a[int(NR*0.95)]}')

    echo "${smtp_p95:-0} ${imap_p95:-0}"
}
```

**Calculation:**
```bash
# Add 50% buffer to observed peak
http_observed=87
http_suggested=$((http_observed + http_observed / 2))  # 87 + 43 = 130
# Round up to nearest 10
http_suggested=$(( (http_suggested + 9) / 10 * 10 ))  # 130 → 130
```

---

## 🧮 DECISION ALGORITHM

```
START
  │
  ├─→ Detect Panel?
  │   ├─ YES: cPanel/DA/Plesk found
  │   │   └─→ RECOMMENDATION: multisite-hosting profile
  │   │       HTTP=300, SSH=20, SMTP=40, IMAP=120
  │   │       CONFIDENCE: HIGH (panel = multi-tenant)
  │   │
  │   └─ NO: Continue
  │
  ├─→ Count Websites
  │   ├─ >50 sites
  │   │   └─→ RECOMMENDATION: multisite-hosting-large
  │   │       HTTP=400, SSH=20, SMTP=60, IMAP=150
  │   │       CONFIDENCE: HIGH
  │   │
  │   ├─ 20-50 sites
  │   │   └─→ RECOMMENDATION: multisite-hosting
  │   │       HTTP=300, SSH=15, SMTP=40, IMAP=120
  │   │       CONFIDENCE: HIGH
  │   │
  │   ├─ 5-20 sites
  │   │   └─→ RECOMMENDATION: shared-hosting
  │   │       HTTP=200, SSH=12, SMTP=30, IMAP=80
  │   │       CONFIDENCE: MEDIUM
  │   │
  │   ├─ 1-5 sites
  │   │   └─→ RECOMMENDATION: single-business
  │   │       HTTP=150, SSH=10, SMTP=25, IMAP=60
  │   │       CONFIDENCE: MEDIUM
  │   │
  │   └─ 0 sites (no vhosts)
  │       └─→ Check services
  │           ├─ HAProxy or reverse proxy
  │           │   └─→ RECOMMENDATION: api-gateway
  │           │       HTTP=100, SSH=8, SMTP=15, IMAP=30
  │           │
  │           └─ Heavy mail (20+ domains)
  │               └─→ RECOMMENDATION: office-email
  │                   HTTP=80, SSH=8, SMTP=100, IMAP=200
  │
  ├─→ Analyze Traffic (if logs available)
  │   ├─ HTTP 95th percentile: 87 conns/IP
  │   │   └─→ Suggest: 130 (87 + 50% buffer)
  │   │       CONFIDENCE: VERY HIGH (based on real data)
  │   │
  │   └─ Override profile suggestion if traffic data available
  │
  └─→ Final Recommendation
      ├─ Show profile match
      ├─ Show reasoning
      ├─ Show confidence level
      └─ Allow user to apply or customize
```

---

## 📊 OUTPUT FORMAT

```bash
$ nftban ddos autotune

═══════════════════════════════════════════════════════════════
  NFTBan DDOS Auto-Tune - Intelligent Server Analysis
═══════════════════════════════════════════════════════════════

[1/5] Analyzing hardware...
  RAM: 16 GB
  CPU: 8 cores
  Disk: SSD

[2/5] Detecting hosting environment...
  Panel: DirectAdmin detected
  Type: Multi-tenant hosting server

[3/5] Counting websites and domains...
  nginx vhosts: 38
  Apache vhosts: 4
  Total websites: 42

[4/5] Analyzing services...
  ✓ nginx (web server)
  ✓ php-fpm (25 pools detected)
  ✓ postfix (mail server)
  ✓ dovecot (IMAP/POP3)
  ✓ mariadb (database)

[5/5] Analyzing traffic patterns (last 24h)...
  HTTP connections per IP:
    Average: 45
    95th percentile: 87
    Peak observed: 156

  SSH connections:
    Peak concurrent: 6

  SMTP connections per IP:
    95th percentile: 18
    Peak: 25

  IMAP connections per IP:
    95th percentile: 45
    Peak: 67

═══════════════════════════════════════════════════════════════
  ANALYSIS COMPLETE
═══════════════════════════════════════════════════════════════

SERVER PROFILE DETECTED: Multi-Site Hosting Server

CONFIDENCE: ██████████████████░░ 90% (VERY HIGH)

Reasoning:
  ✓ DirectAdmin panel detected (multi-tenant indicator)
  ✓ 42 websites hosted (multi-site confirmed)
  ✓ 25 PHP-FPM pools (many applications)
  ✓ Traffic analysis supports high connection needs
  ✓ Mail server with moderate usage

═══════════════════════════════════════════════════════════════
  RECOMMENDED LIMITS
═══════════════════════════════════════════════════════════════

Based on: multisite-hosting profile + traffic analysis

┌─────────────────────────────────────────────────────────────┐
│ Service │ Profile │ Traffic │ Recommended │ Reason         │
├─────────────────────────────────────────────────────────────┤
│ HTTP    │  300    │   234   │     250     │ Traffic-based  │
│ SSH     │   20    │    12   │      15     │ Team size      │
│ SMTP    │   40    │    36   │      40     │ Profile-based  │
│ IMAP    │  120    │   101   │     120     │ Profile-based  │
│ POP3    │   60    │   N/A   │      60     │ Profile-based  │
└─────────────────────────────────────────────────────────────┘

Traffic-based: Calculated from real traffic (95th %ile + 50% buffer)
Profile-based: Based on server profile and best practices

═══════════════════════════════════════════════════════════════
  CONFIGURATION TO APPLY
═══════════════════════════════════════════════════════════════

# Whitelist (CONFIGURE FIRST!)
DDOS_WHITELIST="127.0.0.1,::1,10.0.0.0/8,192.168.0.0/16"
DDOS_OFFICE_IPS="YOUR_OFFICE_IP"      # ← ADD YOUR OFFICE IP!

# Connection Limits
DDOS_CONNLIMIT_SSH="15"
DDOS_CONNLIMIT_HTTP="250"
DDOS_CONNLIMIT_HTTPS="250"
DDOS_CONNLIMIT_SMTP="40"
DDOS_CONNLIMIT_IMAP="120"
DDOS_CONNLIMIT_POP3="60"

═══════════════════════════════════════════════════════════════
  NEXT STEPS
═══════════════════════════════════════════════════════════════

Option 1: Apply Recommended Settings
  nftban ddos autotune --apply

  This will:
    1. Backup current config
    2. Update /etc/nftban/conf.d/ddos.conf
    3. Reload DDOS protection
    4. Start monitoring

Option 2: Save to File for Review
  nftban ddos autotune --save /tmp/ddos-suggested.conf

  Then manually review and copy values you want

Option 3: Use Profile Template
  nftban ddos profile apply multisite-hosting

  Applies standard profile without traffic-based tuning

═══════════════════════════════════════════════════════════════
  IMPORTANT WARNINGS
═══════════════════════════════════════════════════════════════

⚠️  BEFORE APPLYING:
  1. Configure whitelist with YOUR_OFFICE_IP
  2. Test on non-production first if possible
  3. Monitor logs after applying:
     tail -f /var/log/nftban/ddos-blocks.log
  4. Check stats regularly:
     nftban ddos stats

⚠️  IF LEGITIMATE TRAFFIC IS BLOCKED:
  - Whitelist the IP: nftban whitelist add <IP>
  - Or increase limits: vi /etc/nftban/conf.d/ddos.conf
  - Then reload: nftban ddos reload

═══════════════════════════════════════════════════════════════

Full guide: /usr/share/doc/nftban/DDOS_COMPLETE_GUIDE.md
```

---

## 🛠️ COMMAND OPTIONS

```bash
# Basic auto-tune (show suggestions)
nftban ddos autotune

# Apply suggestions automatically
nftban ddos autotune --apply

# Save suggestions to file
nftban ddos autotune --save /path/to/file.conf

# Show only (no recommendations, just detection)
nftban ddos autotune --detect-only

# Verbose mode (show all detection steps)
nftban ddos autotune --verbose

# Skip traffic analysis (faster, less accurate)
nftban ddos autotune --no-traffic

# Force specific profile
nftban ddos autotune --force-profile multisite-hosting
```

---

## 📝 IMPLEMENTATION FILES

### New Files to Create:

```
/usr/lib/nftban/core/nftban_ddos_autotune.sh
├── detect_hardware()
├── detect_panel()
├── count_websites()
├── detect_services()
├── analyze_traffic()
├── calculate_limits()
├── suggest_profile()
└── generate_config()

/usr/lib/nftban/cli/cmd_ddos_autotune.sh
└── Command handler for 'nftban ddos autotune'

/usr/share/nftban/profiles/
├── multisite-hosting.conf
├── single-business.conf
├── api-gateway.conf
├── office-email.conf
└── disabled.conf
```

---

## ⏱️ ESTIMATED TIME

- Hardware detection: 1 hour
- Panel detection: 1 hour
- Website/service counting: 2 hours
- Traffic analysis: 2 hours
- Decision algorithm: 2 hours
- Output formatting: 1 hour
- CLI integration: 1 hour
- Testing: 3 hours

**Total: ~13 hours (2 days)**

---

## 🎯 PRIORITIES

**Must Have (MVP):**
- ✅ Hardware detection (RAM/CPU)
- ✅ Panel detection (cPanel, DA, Plesk)
- ✅ Website count
- ✅ Basic service detection
- ✅ Profile suggestion
- ✅ Config generation

**Nice to Have (v2):**
- ⏳ Traffic analysis from logs
- ⏳ Historical pattern detection
- ⏳ Machine learning suggestions
- ⏳ Continuous monitoring and auto-adjust

---

## 🤔 DISCUSSION POINTS

1. **Should autotune apply automatically or just suggest?**
   - Suggest only (safer) ✅
   - Apply with confirmation
   - Apply automatically (dangerous)

2. **How much weight to give traffic analysis vs profile?**
   - Traffic analysis 70% (if available)
   - Profile 30% (fallback)

3. **Handle CloudLinux LVE limits?**
   - Detect CloudLinux
   - Warn if LVE limits conflict
   - Adjust suggestions accordingly

4. **Store autotune history?**
   - Save detection results to /var/lib/nftban/autotune/
   - Allow comparison over time
   - Trending analysis

---

**Ready for discussion and refinement!**

**EOF**
