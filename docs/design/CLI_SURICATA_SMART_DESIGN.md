# NFTBan SMART CLI Design: Suricata Management

**Author:** Senior CLI/UX Design
**Date:** 2026-02-02
**Status:** Production-Ready Design Specification

---

## Design Philosophy

The current approach requires users to edit `filters.conf`, `suricata.conf`, and various config files manually. This is error-prone and unfriendly. The SMART CLI follows these principles:

1. **NO manual file editing** for common operations
2. **Interactive prompts** for complex configurations
3. **Sensible defaults** with easy overrides
4. **Show/get commands** for every set command
5. **Consistent verb structure**: `list`, `show`, `get`, `set`, `enable`, `disable`, `add`, `remove`

---

## 1. Detection Mode Management

### 1.1 Portscan Mode

```
nftban portscan mode [COMMAND]
```

#### Commands

| Command | Description | Config Modified |
|---------|-------------|-----------------|
| `show` | Display current mode and settings | - |
| `set classic` | Use classic nftables-based detection | `/etc/nftban/nftban.conf.local` |
| `set suricata` | Use Suricata IDS detection | `/etc/nftban/nftban.conf.local` |
| `set hybrid` | Use both (belt and suspenders) | `/etc/nftban/nftban.conf.local` |

#### Example Usage

```bash
# View current portscan detection mode
$ nftban portscan mode show

Portscan Detection Mode
=======================

  Current Mode:   suricata
  Status:         ACTIVE

  Detection Source:
    EVE Log:      /var/log/nftban/suricata/eve-alerts.json
    Poll Rate:    500ms

  Thresholds:
    Observe:      0.25 score
    Short Ban:    0.45 score (15m)
    Long Ban:     0.65 score (1h)
    Permanent:    0.85 score (24h)

  Statistics (last 24h):
    Events:       1,247
    Bans:         23
    Score Decay:  30m

Available Modes:
  classic   - nftables rate limiting (lightweight, less accurate)
  suricata  - IDS analysis (deeper inspection, more CPU)
  hybrid    - Both modes (recommended for high-value servers)

Change mode: nftban portscan mode set <MODE>
```

```bash
# Switch to hybrid mode
$ nftban portscan mode set hybrid

Portscan Mode Configuration
===========================

  Previous Mode:  suricata
  New Mode:       hybrid

  [+] Updated: /etc/nftban/nftban.conf.local
      PORTSCAN_MODE=hybrid

  [+] Both detection engines will now run:
      - Classic: nftables rate limiting (Layer 0)
      - Suricata: Deep packet inspection (Layer 1)

  Restart required to apply:
    systemctl restart nftban
```

#### Get/Set Threshold Commands

```bash
# View specific thresholds
$ nftban portscan threshold show

Portscan Threshold Configuration
================================

  Source: /etc/nftban/conf.d/portscan/suricata.conf
  Override: /etc/nftban/conf.d/portscan/suricata.conf.local

  Observe Threshold:     0.25  (log only, no action)
  Short Ban Threshold:   0.45  -> 15m ban
  Long Ban Threshold:    0.65  -> 1h ban
  Permanent Threshold:   0.85  -> 24h ban

  Score Decay:           30m
  Alert Window:          5m (aggregation period)

Modify: nftban portscan threshold set --observe 0.30
```

```bash
# Adjust threshold
$ nftban portscan threshold set --short-ban 0.50 --short-duration 20m

Portscan Threshold Update
=========================

  Changes:
    Short Ban Threshold:  0.45 -> 0.50
    Short Ban Duration:   15m -> 20m

  [+] Updated: /etc/nftban/conf.d/portscan/suricata.conf.local

  Changes take effect immediately (no restart needed).

  Test with: nftban portscan test 192.168.1.100
```

### 1.2 DDoS Mode

```
nftban ddos mode [COMMAND]
```

#### Commands

| Command | Description | Config Modified |
|---------|-------------|-----------------|
| `show` | Display current mode and settings | - |
| `set classic` | Layer 4 rate limiting only | `/etc/nftban/nftban.conf.local` |
| `set suricata` | Suricata pattern detection | `/etc/nftban/nftban.conf.local` |
| `set hybrid` | Both layers (recommended) | `/etc/nftban/nftban.conf.local` |

#### Example Usage

```bash
$ nftban ddos mode show

DDoS Protection Mode
====================

  Current Mode:   hybrid
  Status:         ACTIVE (both layers)

  Layer 0 (Classic):
    SYN Flood Limit:    1000 pps/IP
    UDP Flood Limit:    500 pps/IP
    ICMP Limit:         100 pps/IP

  Layer 1 (Suricata):
    Patterns:     flood, amplification, reflection, slowloris
    Categories:   attempted-dos, successful-dos, denial-of-service
    Signatures:   2100366, 2100367, 2100368 (+6 more)

  Thresholds:
    Observe:      0.30 score
    Short Ban:    0.50 score (10m)
    Long Ban:     0.70 score (1h)
    Permanent:    0.90 score (24h)
```

```bash
$ nftban ddos mode set suricata --syn-flood --udp-flood --no-icmp

DDoS Mode Configuration
=======================

  New Mode: suricata

  Detection Types:
    [x] SYN Flood Detection     ENABLED
    [x] UDP Flood Detection     ENABLED
    [ ] ICMP Flood Detection    DISABLED
    [x] DNS Amplification       ENABLED (default)
    [x] NTP Amplification       ENABLED (default)
    [x] HTTP Flood              ENABLED (default)
    [x] Slowloris               ENABLED (default)

  [+] Updated: /etc/nftban/nftban.conf.local
  [+] Updated: /etc/nftban/conf.d/ddos/suricata.conf.local

  Restart required: systemctl restart nftban
```

---

## 2. Filter Management

The unified filter management interface for Suricata threat filters.

```
nftban suricata filter [COMMAND]
```

### 2.1 List Filters

```bash
$ nftban suricata filter list

Suricata Filters
================

  Config:   /etc/suricata/filters.conf
  Override: /etc/suricata/filters.conf.local

NAME         STATUS      THRESHOLD  BAN TIME  ACTION   TYPE           DESCRIPTION
----         ------      ---------  --------  ------   ----           -----------
ssh          ENABLED          80      30m     ban      escalate:3:24h SSH brute-force
http         ENABLED         100       1h     ban      escalate:3:24h Web exploits
mail         ENABLED          90      45m     ban      escalate:3:24h Mail abuse
dns          ENABLED         120       2h     observe  temporary      DNS anomalies
ftp          disabled         85       1h     log      temporary      FTP attacks
rdp          disabled         85       1h     log      temporary      RDP attacks
mysql        disabled         90       2h     log      temporary      MySQL attacks
postgresql   disabled         90       2h     log      temporary      PostgreSQL attacks
scan         ENABLED          70      15m     ban      escalate:2:1h  Port scans
exploit      ENABLED          60      24h     ban      permanent      Exploits (PERM)
ddos         ENABLED          50       6h     ban      escalate:2:24h DDoS attacks
malware      ENABLED          40      48h     ban      permanent      Malware (PERM)
botnet       ENABLED          50      48h     ban      permanent      Botnet (PERM)
wp_xmlrpc    ENABLED          90       2h     ban      escalate:5:24h WordPress XML-RPC
wp_login     ENABLED         120       1h     ban      escalate:5:24h WordPress login
joomla       ENABLED         120       1h     ban      escalate:5:24h Joomla admin
drupal       ENABLED         120       1h     ban      escalate:5:24h Drupal login
phpmyadmin   disabled         95       3h     log      temporary      phpMyAdmin
smb          disabled         80       6h     log      escalate:2:24h SMB/CIFS
ldap         disabled         85       4h     log      escalate:3:48h LDAP
voip         disabled         80       2h     log      temporary      VoIP/SIP

Total: 21 filters (13 enabled, 8 disabled)

Legend:
  Action: log (testing) | observe (tuning) | ban (production)
  Type:   temporary | permanent | escalate:N:T (perm after N bans in time T)
```

### 2.2 Show Filter Details

```bash
$ nftban suricata filter show ssh

Filter Details: ssh
===================

  Status:       ENABLED
  Description:  SSH brute-force (temp 30m, perm after 3x)

  Configuration:
    Threshold:    80 points (lower = more aggressive)
    Ban Time:     30m (first offense)
    Action:       ban
    Ban Type:     escalate:3:24h
                  -> Temporary 30m for first 2 bans
                  -> PERMANENT after 3rd ban within 24h

  Keywords (signature matching):
    - ssh
    - brute
    - bruteforce

  Statistics (last 24h):
    Triggers:     487
    IPs Scored:   124
    Bans Issued:  18
    Escalated:    3 (now permanent)

  Top Source IPs:
    1. 45.33.32.156    12 triggers (BANNED)
    2. 185.220.101.34   8 triggers (BANNED)
    3. 192.241.216.97   7 triggers (scored: 65)

  Source:
    Default:  /etc/suricata/filters.conf (line 37)
    Override: /etc/suricata/filters.conf.local (line 12)
```

### 2.3 Enable/Disable Filter

```bash
$ nftban suricata filter enable ftp

Filter Enabled: ftp
===================

  [+] Filter 'ftp' is now ENABLED

  Configuration:
    Threshold:  85 points
    Ban Time:   1h
    Action:     log (testing mode - will not ban yet)

  [+] Updated: /etc/suricata/filters.conf.local

  NOTE: Filter action is 'log' - events will be logged but no bans issued.
        To enable banning: nftban suricata filter set ftp --action ban

  Changes take effect immediately (daemon hot-reload).
```

```bash
$ nftban suricata filter disable dns --reason "Too many false positives"

Filter Disabled: dns
====================

  [+] Filter 'dns' is now DISABLED

  Reason recorded: "Too many false positives"

  [+] Updated: /etc/suricata/filters.conf.local

  Statistics before disable:
    Total triggers:  2,341
    False positives: ~67% (estimated from unique IPs)

  Recommendation: Consider tuning instead of disabling:
    nftban suricata filter set dns --threshold 150 --action observe
```

### 2.4 Set Filter Parameters

```bash
$ nftban suricata filter set ssh --threshold 70 --ban-time 20m

Filter Updated: ssh
===================

  Changes Applied:
    Threshold:  80 -> 70 points (more aggressive)
    Ban Time:   30m -> 20m

  [+] Updated: /etc/suricata/filters.conf.local

  Preview (new configuration):
    ssh = true | ssh,brute,bruteforce | 70 | 20m | ban | escalate:3:24h | SSH brute-force

  Changes take effect immediately.
```

```bash
$ nftban suricata filter set exploit --action observe --reason "Testing new rules"

Filter Updated: exploit
=======================

  Changes Applied:
    Action:  ban -> observe
    Reason:  "Testing new rules"

  WARNING: Exploit filter is now in OBSERVE mode.
           Threats will be logged but NOT banned.

  [+] Updated: /etc/suricata/filters.conf.local

  To re-enable banning:
    nftban suricata filter set exploit --action ban
```

### 2.5 Set Filter Options (Full)

```bash
nftban suricata filter set <NAME> [OPTIONS]

Options:
  --threshold N        Score threshold for triggering (default: 100)
  --ban-time DURATION  Ban duration (e.g., 30m, 1h, 24h)
  --action ACTION      log | observe | ban
  --type TYPE          temporary | permanent | escalate:N:T
  --keywords KEYWORDS  Comma-separated signature keywords
  --description TEXT   Filter description
  --reason TEXT        Reason for change (logged)

Examples:
  # Make SSH more aggressive
  nftban suricata filter set ssh --threshold 60 --type escalate:2:12h

  # Put mail filter in observe mode
  nftban suricata filter set mail --action observe

  # Add keywords to existing filter
  nftban suricata filter set http --keywords "api,graphql,rest"

  # Change to permanent ban immediately
  nftban suricata filter set exploit --type permanent --ban-time 0
```

### 2.6 Add New Filter

```bash
$ nftban suricata filter add myapi --keywords "api,graphql,abuse" --threshold 90 --ban-time 1h

Add New Filter
==============

  Name:         myapi
  Keywords:     api, graphql, abuse
  Threshold:    90 points
  Ban Time:     1h
  Action:       ban (default)
  Type:         temporary (default)
  Description:  Custom filter: myapi

  Would you like to customize further? [y/N]: y

  Enter description [Custom filter: myapi]: API abuse protection

  Select action mode:
    1) log      - Log events only (testing)
    2) observe  - Track scores, no banning (tuning)
    3) ban      - Ban IPs exceeding threshold (production)
  Choice [3]: 3

  Select ban type:
    1) temporary       - Always ban for specified duration
    2) permanent       - Always ban permanently
    3) escalate:N:T    - Temporary first, permanent after N bans in time T
  Choice [1]: 3

  Escalation settings:
    Max bans before permanent [3]: 3
    Time window [24h]: 12h

  [+] Filter 'myapi' created successfully!

  Configuration:
    myapi = true | api,graphql,abuse | 90 | 1h | ban | escalate:3:12h | API abuse protection

  [+] Written to: /etc/suricata/filters.conf.local

  Test with: nftban suricata filter test myapi "ET API Abuse Detected"
```

### 2.7 Remove Filter

```bash
$ nftban suricata filter remove myapi

Remove Filter: myapi
====================

  Current Configuration:
    myapi = true | api,graphql,abuse | 90 | 1h | ban | escalate:3:12h | API abuse protection

  Statistics:
    Total triggers:  234
    Bans issued:     12

  WARNING: This will remove the filter and all associated statistics.

  Are you sure? [y/N]: y

  [+] Filter 'myapi' removed from /etc/suricata/filters.conf.local
  [+] Statistics cleared

  NOTE: Default filters from filters.conf cannot be removed, only disabled.
```

### 2.8 Test Filter

```bash
$ nftban suricata filter test ssh "ET SCAN SSH Brute Force Attempt"

Filter Test: ssh
================

  Test Signature: "ET SCAN SSH Brute Force Attempt"

  [MATCH] Filter 'ssh' matches this signature

  Matched Keywords:
    - "ssh" found at position 8
    - "brute" found at position 18

  If this event occurred:
    Severity 2 alert -> +30 points
    Keyword match    -> filter 'ssh' triggered

  Current threshold: 80 points

  This single event: Would add 30 points to IP score
  Needs 3 similar events within 2 minutes to trigger ban
```

---

## 3. Rule Category Management

Manage which Suricata rule categories are loaded (affects memory and CPU usage).

```
nftban suricata category [COMMAND]
```

### 3.1 List Categories

```bash
$ nftban suricata category list

Suricata Rule Categories
========================

  Source: /etc/nftban/suricata/config/suricata.effective.conf
  Rules:  /var/lib/suricata/rules/

CATEGORY                         STATUS      RULES     DESCRIPTION
--------                         ------      -----     -----------
emerging-attack_response         ENABLED      142      Attack response signatures
emerging-current_events          ENABLED       89      Current threat campaigns
emerging-dns                     ENABLED      234      DNS protocol rules
emerging-dos                     ENABLED      156      Denial of service patterns
emerging-exploit                 ENABLED    1,247      CVE exploits and vulns
emerging-malware                 ENABLED    3,892      Malware signatures
emerging-misc                    disabled     567      Miscellaneous rules
emerging-mobile_malware          disabled     234      Mobile threats
emerging-netbios                 disabled     189      NetBIOS/SMB rules
emerging-policy                  disabled     456      Policy violations
emerging-scan                    ENABLED      312      Port scanning patterns
emerging-smtp                    disabled     167      SMTP rules
emerging-sql                     ENABLED      289      SQL injection patterns
emerging-telnet                  disabled      78      Telnet rules
emerging-trojan                  ENABLED    5,234      Trojan signatures
emerging-web_client              ENABLED      892      Web client attacks
emerging-web_server              ENABLED    1,456      Web server attacks
emerging-worm                    ENABLED      234      Worm signatures

Total: 18 categories (12 enabled, 6 disabled)
Enabled Rules: ~14,177 | Disabled Rules: ~1,691
Memory Savings: ~11% by disabling unused categories

Tip: Disable categories for services you don't run:
     nftban suricata category disable emerging-smtp
```

### 3.2 Enable/Disable Category

```bash
$ nftban suricata category enable emerging-smtp

Category Enabled: emerging-smtp
===============================

  [+] Category 'emerging-smtp' is now ENABLED

  Rules Added: 167 signatures
  Memory Impact: +2.3 MB (estimated)

  [+] Updated: /etc/nftban/suricata/config/suricata.local.conf

  Restart required to load new rules:
    systemctl restart suricata

  Or reload without restart (may take 30-60s):
    suricatasc -c reload-rules
```

```bash
$ nftban suricata category disable emerging-mobile_malware --no-restart

Category Disabled: emerging-mobile_malware
==========================================

  [+] Category 'emerging-mobile_malware' is now DISABLED

  Rules Removed: 234 signatures
  Memory Savings: ~3.1 MB (estimated)

  [+] Updated: /etc/nftban/suricata/config/suricata.local.conf

  NOTE: --no-restart specified. Rules will unload on next restart.
        To apply immediately: systemctl restart suricata
```

### 3.3 Auto-Configure Categories

```bash
$ nftban suricata category auto

Auto-Configure Categories
=========================

  Scanning localhost for running services...

  Detected Services:
    [+] SSH (22/tcp)        -> Enable: emerging-scan, emerging-exploit
    [+] HTTP (80/tcp)       -> Enable: emerging-web_server, emerging-web_client
    [+] HTTPS (443/tcp)     -> Enable: emerging-web_server, emerging-web_client
    [+] MySQL (3306/tcp)    -> Enable: emerging-sql
    [ ] SMTP (25/tcp)       -> Not detected, disable: emerging-smtp
    [ ] FTP (21/tcp)        -> Not detected, disable: emerging-ftp (already disabled)

  Recommendation:
    Enable:  emerging-scan, emerging-exploit, emerging-web_server,
             emerging-web_client, emerging-sql, emerging-malware,
             emerging-trojan, emerging-dos
    Disable: emerging-smtp, emerging-telnet, emerging-netbios,
             emerging-mobile_malware

  Estimated Impact:
    Current:    15,868 rules loaded (~245 MB)
    After:      12,456 rules loaded (~198 MB)
    Savings:    ~47 MB memory, ~22% fewer rules

  Apply this configuration? [Y/n]: y

  [+] Updated: /etc/nftban/suricata/config/suricata.local.conf
  [+] Restarting Suricata...
  [+] Done! New configuration active.
```

---

## 4. Threshold/Scoring Tuning

Global scoring configuration that affects all filters.

```
nftban suricata tune [COMMAND]
```

### 4.1 Show Current Tuning

```bash
$ nftban suricata tune show

Suricata Scoring Configuration
==============================

  Config: /etc/suricata/filters.conf
  Override: /etc/suricata/filters.conf.local

  Global Settings:
    Enabled:            true
    Default Threshold:  100 points
    Default Ban Time:   30m
    Default Action:     ban
    Score Decay:        1h

  Severity Scoring (base points per alert):
    Severity 1 (High):     40 points
    Severity 2 (Medium):   30 points
    Severity 3 (Low):      20 points
    Severity 4 (Info):     10 points

  Repetition Bonuses (same IP, within 2 min):
    5-9 events:            +20 points
    10-19 events:          +30 points
    20+ events:            +50 points

  Integration Bonuses:
    IP in Threat Feeds:    +30 points (not yet implemented)
    High-Risk GeoIP:       +10 points (not yet implemented)
    DDoS Counter > 1k pps: +40 points (not yet implemented)

  Memory Limits:
    Max Tracked IPs:       10,000
    Max Events per IP:     100

Modify: nftban suricata tune set --threshold 80 --decay 30m
```

### 4.2 Set Tuning Parameters

```bash
$ nftban suricata tune set --threshold 80 --decay 30m

Scoring Configuration Update
============================

  Changes:
    Default Threshold:  100 -> 80 (more aggressive)
    Score Decay:        1h -> 30m (faster reset)

  Impact Analysis:
    - 25% more IPs will reach ban threshold
    - Scores reset 2x faster (forgiveness)
    - Recommended for high-attack environments

  [+] Updated: /etc/suricata/filters.conf.local

  Changes take effect immediately.
```

### 4.3 Interactive Tuning

```bash
$ nftban suricata tune interactive

Interactive Scoring Tuner
=========================

  This wizard helps you find optimal scoring settings based on your traffic.

  Analyzing last 24h of Suricata events...

  Statistics:
    Total Events:        12,456
    Unique Source IPs:   2,341
    Current Bans:        156
    False Positive Est.: ~8% (based on whitelisted IPs hit)

  Current threshold (100) analysis:
    IPs that would be banned:  156 (6.7% of sources)

  [1/3] Threshold Tuning
  ----------------------

  Simulate different thresholds:

    Threshold 60:   312 bans (13.3%)  <- Very aggressive
    Threshold 80:   234 bans (10.0%)  <- Aggressive
    Threshold 100:  156 bans (6.7%)   <- Current (balanced)
    Threshold 120:  98 bans (4.2%)    <- Conservative
    Threshold 150:  45 bans (1.9%)    <- Very conservative

  Select threshold [100]: 80

  [2/3] Score Decay
  -----------------

  How long should threat scores persist?

    15m:  Fast reset, good for testing
    30m:  Quick forgiveness, fewer repeat bans
    1h:   Balanced (current)
    2h:   Remember threats longer
    4h:   Very long memory

  Select decay period [1h]: 30m

  [3/3] Severity Weighting
  ------------------------

  Adjust base points per severity?

  Current:
    High (sev 1):   40 pts
    Medium (sev 2): 30 pts
    Low (sev 3):    20 pts
    Info (sev 4):   10 pts

  Use defaults? [Y/n]: y

  Configuration Summary
  ---------------------

    Threshold:       100 -> 80
    Score Decay:     1h -> 30m
    Severity Weights: unchanged

  Estimated Impact:
    Bans expected:   +50% more IPs banned
    False Positives: +2% estimated increase

  Apply configuration? [Y/n]: y

  [+] Updated: /etc/suricata/filters.conf.local
  [+] Configuration applied immediately.

  Monitor results: nftban suricata stats --watch
```

### 4.4 Presets

```bash
$ nftban suricata tune preset

Scoring Presets
===============

  Available presets:

  1) paranoid    - Zero tolerance, ban aggressively
                   Threshold: 50, Decay: 2h
                   Best for: Under active attack

  2) aggressive  - Catch threats quickly, some false positives OK
                   Threshold: 70, Decay: 1h
                   Best for: Public-facing servers

  3) balanced    - Standard protection (DEFAULT)
                   Threshold: 100, Decay: 1h
                   Best for: Most servers

  4) conservative - Minimize false positives
                    Threshold: 130, Decay: 30m
                    Best for: Business-critical servers

  5) permissive  - Only ban obvious attacks
                   Threshold: 180, Decay: 15m
                   Best for: Development, testing

  Select preset [3]: 2

  Applying 'aggressive' preset...

  [+] Threshold: 100 -> 70
  [+] Decay: 1h -> 1h (unchanged)
  [+] Updated: /etc/suricata/filters.conf.local

  Preset applied successfully.
```

---

## 5. Interactive Wizard

Full guided setup for users new to Suricata integration.

```
nftban suricata wizard
```

### 5.1 Full Wizard Flow

```bash
$ nftban suricata wizard

======================================================================
       NFTBan Suricata Integration Wizard
======================================================================

  This wizard will help you configure Suricata IDS integration
  with NFTBan for intelligent threat detection and automatic banning.

  Steps:
    1. System Check      - Verify Suricata installation
    2. Profile Selection - Choose performance profile
    3. Service Detection - Auto-detect your services
    4. Filter Setup      - Enable relevant threat filters
    5. Threshold Tuning  - Set detection sensitivity
    6. Activation        - Enable and start services

  Estimated time: 5-10 minutes

  Continue? [Y/n]: y

======================================================================
  Step 1/6: System Check
======================================================================

  Checking prerequisites...

  [+] Suricata installed:     7.0.3 (/usr/bin/suricata)
  [+] suricata-update:        1.3.2 (/usr/bin/suricata-update)
  [+] EVE log configured:     /var/log/nftban/suricata/eve-alerts.json
  [+] Rules installed:        /var/lib/suricata/rules/ (15,234 rules)
  [+] Service exists:         suricata.service (inactive)
  [+] NFTBan daemon:          nftban-suricata.service (inactive)

  All prerequisites met!

  Press ENTER to continue...

======================================================================
  Step 2/6: Performance Profile
======================================================================

  Auto-detecting system resources...

  System Resources:
    CPU Cores:   4
    Total RAM:   8 GB
    Available:   6.2 GB

  Recommended Profile: standard

  Available Profiles:

  1) minimal   - 2 cores / 2 GB RAM
                 Ring: 50k, Flow timeout: 60s, Detection: low
                 Best for: Small VPS, containers

  2) standard  - 4 cores / 4-8 GB RAM (RECOMMENDED)
                 Ring: 100k, Flow timeout: 120s, Detection: medium
                 Best for: Most servers

  3) maximum   - 8+ cores / 8+ GB RAM
                 Ring: 300k, Flow timeout: 300s, Detection: high
                 Best for: Dedicated security appliances

  Select profile [2]: 2

  [+] Profile 'standard' selected
  [+] Config: /etc/suricata/suricata.yaml -> /etc/nftban/suricata/profiles/standard.yaml

======================================================================
  Step 3/6: Service Detection
======================================================================

  Scanning localhost for running services...

  Detected Services:
    [+] SSH         22/tcp     ENABLED
    [+] HTTP        80/tcp     ENABLED
    [+] HTTPS       443/tcp    ENABLED
    [+] MySQL       3306/tcp   ENABLED (local only)
    [ ] FTP         21/tcp     NOT RUNNING
    [ ] SMTP        25/tcp     NOT RUNNING
    [ ] DNS         53/udp     NOT RUNNING
    [ ] PostgreSQL  5432/tcp   NOT RUNNING

  Based on detected services, we recommend enabling these rule categories:
    - emerging-web_server (1,456 rules)
    - emerging-web_client (892 rules)
    - emerging-sql (289 rules)
    - emerging-scan (312 rules)
    - emerging-exploit (1,247 rules)
    - emerging-malware (3,892 rules)
    - emerging-trojan (5,234 rules)
    - emerging-dos (156 rules)

  Disable these unused categories:
    - emerging-smtp (167 rules)
    - emerging-dns (234 rules)
    - emerging-ftp (89 rules)

  Accept recommendations? [Y/n]: y

  [+] Categories configured
  [+] Estimated memory: 198 MB (saved 47 MB)

======================================================================
  Step 4/6: Filter Setup
======================================================================

  Configuring threat filters based on your services...

  Recommended Filter Configuration:

  FILTER      ENABLE?   THRESHOLD  ACTION     REASON
  ------      -------   ---------  ------     ------
  ssh         Yes       80         ban        You have SSH
  http        Yes       100        ban        You have HTTP/HTTPS
  scan        Yes       70         ban        Protect against recon
  exploit     Yes       60         ban        Critical protection
  ddos        Yes       50         ban        DDoS protection
  malware     Yes       40         ban        Always recommended
  botnet      Yes       50         ban        Always recommended
  mail        No        -          -          No mail services
  ftp         No        -          -          No FTP service
  dns         No        -          -          No DNS service

  Accept filter configuration? [Y/n]: y

  Would you like to customize any filter? [y/N]: y

  Select filter to customize (or ENTER to continue):
    1) ssh       6) malware
    2) http      7) botnet
    3) scan      8) mail
    4) exploit   9) ftp
    5) ddos     10) dns

  Choice: 1

  Customizing 'ssh' filter:
    Current threshold [80]: 70
    Ban time [30m]: 20m
    Action (log/observe/ban) [ban]: ban
    Ban type (temporary/permanent/escalate) [escalate:3:24h]: escalate:2:12h

  [+] Filter 'ssh' customized

  Customize another? [y/N]: n

======================================================================
  Step 5/6: Threshold Tuning
======================================================================

  Select overall detection sensitivity:

  1) Paranoid     - Ban aggressively (may have false positives)
  2) Aggressive   - Catch threats quickly
  3) Balanced     - Standard protection (RECOMMENDED)
  4) Conservative - Minimize false positives
  5) Custom       - Set values manually

  Choice [3]: 3

  [+] Using 'balanced' preset:
      - Global threshold: 100
      - Score decay: 1h

======================================================================
  Step 6/6: Activation
======================================================================

  Ready to activate Suricata integration!

  Summary:
    Profile:            standard
    Enabled Categories: 8 (12,478 rules)
    Enabled Filters:    7
    Detection Mode:     balanced

  The following services will be enabled:
    - suricata.service (Suricata IDS)
    - nftban-suricata.service (NFTBan integration daemon)
    - nftban-suricata-stats.service (Statistics collector)
    - nftban-suricata-update.timer (Weekly rule updates)

  Activate now? [Y/n]: y

  [+] Enabling suricata.service...
  [+] Starting suricata.service... (may take 30-60s)
  [+] Enabling nftban-suricata.service...
  [+] Starting nftban-suricata.service...
  [+] Enabling nftban-suricata-stats.service...
  [+] Starting nftban-suricata-stats.service...
  [+] Enabling nftban-suricata-update.timer...
  [+] Starting nftban-suricata-update.timer...

  Verifying...
  [+] Suricata:              RUNNING (PID 12345)
  [+] NFTBan Suricata:       RUNNING (PID 12346)
  [+] Stats Collector:       RUNNING (PID 12347)
  [+] Update Timer:          ENABLED (next: Sun 03:00)

======================================================================
       Setup Complete!
======================================================================

  Suricata IDS integration is now ACTIVE.

  What's next:

    1. Monitor real-time alerts:
       nftban suricata watch

    2. View statistics:
       nftban suricata stats

    3. Check filter status:
       nftban suricata filter list

    4. Get recommendations:
       nftban suricata recommend

  Documentation:
    https://github.com/itcmsgr/nftban/wiki/Suricata-Integration

  Need help? Join our Discord or open a GitHub issue.

======================================================================
```

---

## 6. Quick Reference Card

### Detection Modes

```bash
# Portscan detection
nftban portscan mode show                           # View current mode
nftban portscan mode set suricata                   # Use Suricata
nftban portscan mode set hybrid                     # Use both engines
nftban portscan threshold set --short-ban 0.50     # Adjust threshold

# DDoS detection
nftban ddos mode show                               # View current mode
nftban ddos mode set hybrid                         # Use both engines
```

### Filter Management

```bash
# List and show
nftban suricata filter list                        # List all filters
nftban suricata filter show ssh                    # Show filter details

# Enable/disable
nftban suricata filter enable ftp                  # Enable a filter
nftban suricata filter disable dns                 # Disable a filter

# Configure
nftban suricata filter set ssh --threshold 70     # Set threshold
nftban suricata filter set ssh --action observe   # Set action mode
nftban suricata filter set ssh --type permanent   # Set ban type

# Add/remove
nftban suricata filter add myfilter --keywords "a,b,c" --threshold 90
nftban suricata filter remove myfilter
```

### Category Management

```bash
nftban suricata category list                      # List all categories
nftban suricata category enable emerging-smtp     # Enable category
nftban suricata category disable emerging-mobile  # Disable category
nftban suricata category auto                      # Auto-configure
```

### Scoring Tuning

```bash
nftban suricata tune show                          # View scoring config
nftban suricata tune set --threshold 80           # Set global threshold
nftban suricata tune set --decay 30m              # Set score decay
nftban suricata tune preset                        # Use preset
nftban suricata tune interactive                   # Interactive tuning
```

### Setup

```bash
nftban suricata wizard                             # Full interactive setup
nftban suricata install                            # Install Suricata
nftban suricata enable                             # Enable services
nftban suricata disable                            # Disable services
nftban suricata status                             # Check status
```

---

## 7. Configuration Files Modified

| Command | Config File Modified |
|---------|---------------------|
| `nftban portscan mode set` | `/etc/nftban/nftban.conf.local` |
| `nftban portscan threshold set` | `/etc/nftban/conf.d/portscan/suricata.conf.local` |
| `nftban ddos mode set` | `/etc/nftban/nftban.conf.local` |
| `nftban ddos threshold set` | `/etc/nftban/conf.d/ddos/suricata.conf.local` |
| `nftban suricata filter enable/disable/set` | `/etc/suricata/filters.conf.local` |
| `nftban suricata filter add` | `/etc/suricata/filters.conf.local` |
| `nftban suricata category enable/disable` | `/etc/nftban/suricata/config/suricata.local.conf` |
| `nftban suricata tune set` | `/etc/suricata/filters.conf.local` |
| `nftban suricata profile set` | Symlink: `/etc/suricata/suricata.yaml` |

---

## 8. Implementation Priority

### Phase 1 (MVP)
1. `nftban suricata filter list/show/enable/disable`
2. `nftban suricata filter set` (basic options)
3. `nftban suricata tune show/set`

### Phase 2 (Enhanced)
4. `nftban suricata filter add/remove`
5. `nftban suricata category list/enable/disable`
6. `nftban portscan mode` commands
7. `nftban ddos mode` commands

### Phase 3 (Advanced)
8. `nftban suricata tune interactive`
9. `nftban suricata tune preset`
10. `nftban suricata category auto`
11. `nftban suricata wizard`

---

## 9. Error Handling

All commands should:

1. Validate inputs before making changes
2. Create backups before modifying config files
3. Show clear error messages with remediation steps
4. Support `--dry-run` flag to preview changes
5. Log all changes to `/var/log/nftban/config-changes.log`

Example error handling:

```bash
$ nftban suricata filter set nonexistent --threshold 50

Error: Filter 'nonexistent' not found

Available filters:
  ssh, http, mail, dns, ftp, rdp, mysql, postgresql, scan,
  exploit, ddos, malware, botnet, wp_xmlrpc, wp_login,
  joomla, drupal, phpmyadmin, smb, ldap, voip

Create a new filter:
  nftban suricata filter add nonexistent --keywords "..." --threshold 50
```

```bash
$ nftban suricata filter set ssh --threshold -5

Error: Invalid threshold value: -5

Threshold must be a positive integer (typically 40-200).
  Low values (40-70):   Very aggressive, more bans
  Medium (80-120):      Balanced detection
  High values (130+):   Conservative, fewer false positives

Current threshold for 'ssh': 80
```

---

## 10. Backward Compatibility

Users who prefer manual config editing can continue doing so. The CLI:

1. Never modifies `filters.conf` (package defaults)
2. Only writes to `.local` override files
3. Preserves comments in existing config files
4. Supports `--no-backup` flag for advanced users
5. Respects `EDITOR` environment variable for `--edit` flag

```bash
# Open config in editor (respects $EDITOR)
nftban suricata filter edit ssh

# Show raw config line
nftban suricata filter show ssh --raw
# Output: ssh = true | ssh,brute,bruteforce | 80 | 30m | ban | escalate:3:24h | SSH brute-force

# Export all settings
nftban suricata config export > my-config.txt

# Import settings
nftban suricata config import my-config.txt
```
