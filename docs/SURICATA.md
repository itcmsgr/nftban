# NFTBan + Suricata IDS Integration Guide

**Version:** 1.0.14+
**Last Updated:** 2025-12-28
**Status:** Production Ready

---

## 📋 Table of Contents

1. [Overview](#overview)
2. [Quick Start (2 Commands!)](#quick-start)
3. [Requirements](#requirements)
4. [Installation Methods](#installation-methods)
5. [Configuration](#configuration)
6. [DDoS & Portscan Integration](#ddos--portscan-integration)
7. [Monitoring & Maintenance](#monitoring--maintenance)
8. [Troubleshooting](#troubleshooting)
9. [Performance Tuning](#performance-tuning)
10. [FAQ](#faq)

---

## Overview

**What is Suricata?**
Suricata is a high-performance Network IDS/IPS (Intrusion Detection/Prevention System) engine. NFTBan integrates with Suricata to provide:

- **Intelligent threat detection** using signature-based rules (ET/Open ruleset)
- **SSH brute-force detection** beyond simple login monitoring
- **Web attack detection** (SQLi, XSS, scanners, bots)
- **DDoS protection** using IDS-assisted scoring
- **Port scan detection** with behavioral analysis

**How it works:**
```
Traffic → Suricata IDS → eve.json alerts → NFTBan → nftables ban
```

**Benefits:**
- ✅ Automated threat response (alert → block)
- ✅ Weekly rule updates (systemd timer)
- ✅ Low resource footprint (optimized for VPS)
- ✅ Compatible with DDoS/portscan modules

---

## Quick Start

### Two-Command Installation

```bash
# Step 1: Install Suricata (FULLY AUTOMATED)
sudo nftban suricata install

# Step 2: Enable and Start (FULLY AUTOMATED)
sudo nftban suricata enable
```

**That's it!** Suricata is now running and integrated with NFTBan.

### Verify Installation

```bash
# Check status
nftban suricata status

# View live alerts
tail -f /var/log/suricata/eve.json | jq 'select(.event_type=="alert")'
```

---

## Requirements

### Minimum System Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| **CPU** | 2 cores | 4 cores |
| **RAM** | 2 GB | 4 GB |
| **Disk** | 1 GB free | 2 GB free |
| **OS** | Rocky/RHEL/Debian 9+ | Rocky Linux 9 |

### Software Requirements

- **NFTBan:** v1.0.14 or higher
- **EPEL Repository:** (for RHEL/Rocky - installed automatically)
- **Python 3:** For suricata-update tool
- **pip3:** For installing suricata-update
- **jq:** (optional) For pretty JSON output

**Note:** All dependencies are installed automatically by `nftban suricata install`

---

## Installation Methods

### Method 1: Package Installation (Recommended)

If your distribution has Suricata packages (Rocky Linux 9 with EPEL):

```bash
# Automated (checks for packages automatically)
sudo nftban suricata install
```

**What it does:**
1. Checks for EPEL repository
2. Installs Suricata from dnf/apt
3. Installs suricata-update (pip3)
4. Downloads ET/Open rules
5. Configures systemd services
6. Enables weekly rule updates

### Method 2: Source Compilation (Automatic Fallback)

If no package is available, `nftban suricata install` automatically compiles from source:

```bash
# Same command - auto-detects and compiles if needed
sudo nftban suricata install
```

**Compilation process** (handled automatically):
1. Installs build dependencies
2. Downloads Suricata 7.0.x source
3. Compiles with NFTBan-optimized flags
4. Installs to /usr/bin/suricata
5. Sets up systemd services

**Time:** ~5-10 minutes on typical VPS

### Method 3: Manual Installation (Advanced)

```bash
# For RHEL/Rocky/Fedora
sudo dnf install -y epel-release
sudo dnf install -y suricata
sudo pip3 install --upgrade suricata-update

# For Debian/Ubuntu
sudo apt-get update
sudo apt-get install -y suricata
sudo pip3 install --upgrade suricata-update

# Download rules
sudo suricata-update enable-source et/open
sudo suricata-update

# Enable with NFTBan
sudo nftban suricata enable
```

---

## Configuration

### NFTBan Configuration

Suricata integration is controlled by `/etc/nftban/nftban.conf`:

```bash
# Enable IDS integration
ENABLE_IDS_INTEGRATION=1
NFTBAN_SURICATA_ENABLED=true
```

**Auto-configured by:** `nftban suricata install`

### Suricata Configuration

Main config: `/etc/suricata/suricata.yaml`

**NFTBan-optimized settings** (applied automatically):

```yaml
# af-packet interface capture
af-packet:
  - interface: default
    cluster-id: 99
    cluster-type: cluster_flow  # Flow-based load balancing
    defrag: yes
    use-mmap: yes
    mmap-locked: yes

# Performance tuning for VPS
threading:
  set-cpu-affinity: no
  cpu-affinity:
    - management-cpu-set:
        cpu: [ 0 ]
    - receive-cpu-set:
        cpu: [ 0-1 ]
    - worker-cpu-set:
        cpu: [ 0-3 ]

# Reduced timeouts (faster memory recycling)
flow:
  timeout:
    established: 60    # Down from 300s
    emergency-closed: 10
```

**EVE JSON output:**

```yaml
outputs:
  - eve-log:
      enabled: yes
      filetype: regular
      filename: /var/log/suricata/eve.json
      types:
        - alert
        - http
        - dns
        - tls
```

---

## DDoS & Portscan Integration

### DDoS Module Integration

NFTBan's DDoS module can use Suricata for intelligent detection:

```bash
# Enable DDoS protection
nftban ddos enable

# Configure for Suricata mode
echo "DDOS_MODE=suricata" >> /etc/nftban/conf.d/ddos.conf
```

**Benefits:**
- Signature-based SYN flood detection
- Protocol-aware rate limiting
- Behavioral anomaly detection

**Config:** `/etc/nftban/conf.d/ddos.conf`

```bash
DDOS_MODE=suricata                    # Use IDS integration
DDOS_SURICATA_EVE_FILE=/var/log/suricata/eve.json
DDOS_SURICATA_SERVICE_NAME=suricata
```

### Portscan Module Integration

```bash
# Enable portscan detection
nftban portscan enable

# Configure for Suricata mode
echo "PORTSCAN_MODE=suricata" >> /etc/nftban/conf.d/portscan.conf
```

**Benefits:**
- Detects stealthy scans (SYN, FIN, NULL, XMAS)
- Lower false-positive rate
- Tracks scan patterns over time

**Config:** `/etc/nftban/conf.d/portscan.conf`

```bash
PORTSCAN_MODE=suricata                # Use IDS alerts
PORTSCAN_SURICATA_EVE_FILE=/var/log/suricata/eve.json
PORTSCAN_AUTOBAN_ENABLED=1
PORTSCAN_BAN_DURATION_SECONDS=86400   # 24 hours
```

---

## Monitoring & Maintenance

### Status Checking

```bash
# Full status report
nftban suricata status

# Systemd service status
systemctl status suricata.service

# View logs
journalctl -u suricata -f
```

### Viewing Alerts

```bash
# Real-time alerts (pretty formatted)
tail -f /var/log/suricata/eve.json | jq 'select(.event_type=="alert")'

# Last 10 alerts
jq 'select(.event_type=="alert")' /var/log/suricata/eve.json | tail -10

# Alerts from specific IP
jq 'select(.event_type=="alert" and .src_ip=="1.2.3.4")' /var/log/suricata/eve.json
```

### Rule Management

```bash
# Update rules manually
sudo nftban suricata rules update

# List installed rules
nftban suricata rules list

# Check rule count
nftban suricata status | grep "Total alert rules"
```

### Automatic Updates

**Systemd Timer:** `nftban-suricata-update.timer`

- **Schedule:** Weekly, Sunday at 3:00 AM
- **Randomization:** ±1 hour (avoids thundering herd)
- **Persistent:** Runs missed updates after reboot

```bash
# Check timer status
systemctl status nftban-suricata-update.timer

# View next run time
systemctl list-timers | grep suricata

# Manual trigger
sudo systemctl start nftban-suricata-update.service
```

### Performance Monitoring

```bash
# CPU/Memory usage
top -p $(pgrep suricata)

# Packet stats
suricata-ctl dump-stats

# Packet drops
grep "capture.kernel_drops" /var/log/suricata/stats.log
```

---

## Troubleshooting

### Suricata Won't Start

**Symptoms:**
```bash
$ nftban suricata enable
✗ Suricata failed to start
```

**Common Causes & Fixes:**

1. **No rules installed**
   ```bash
   sudo nftban suricata rules update
   sudo systemctl restart suricata
   ```

2. **Invalid suricata.yaml**
   ```bash
   suricata -T -c /etc/suricata/suricata.yaml
   ```

3. **Permission issues**
   ```bash
   sudo nftban permissions enforce
   sudo systemctl restart suricata
   ```

4. **Port conflicts**
   ```bash
   # Check if another IDS is running
   ps aux | grep -E "suricata|snort|zeek"
   ```

### No Alerts Being Generated

**Check:**

1. **Suricata is running**
   ```bash
   systemctl is-active suricata
   ```

2. **Traffic is being captured**
   ```bash
   tail -100 /var/log/suricata/eve.json | jq '.event_type' | sort | uniq -c
   ```

3. **Rules are loaded**
   ```bash
   grep "rules loaded" /var/log/suricata/suricata.log
   ```

4. **Generate test traffic**
   ```bash
   # Trigger test alert (safe)
   curl http://testmyids.com
   ```

### High CPU Usage

**Causes & Solutions:**

1. **Too many workers**
   - Edit `/etc/suricata/suricata.yaml`
   - Reduce `runmode: workers` count
   - Match your CPU cores (e.g., 2 workers for 2-core VPS)

2. **Unnecessary protocol parsers**
   - Disable unused parsers in suricata.yaml:
   ```yaml
   app-layer:
     protocols:
       smb: { enabled: no }
       dcerpc: { enabled: no }
       smtp: { enabled: no }
   ```

3. **HTTP body inspection**
   - Disable if not needed:
   ```yaml
   http:
     request-body-limit: 0
     response-body-limit: 0
   ```

### Rules Update Fails

**Error:** `suricata-update` command not found

**Fix:**
```bash
sudo pip3 install --upgrade suricata-update
```

**Error:** Network timeout downloading rules

**Fix:**
```bash
# Use alternative mirror
sudo suricata-update --no-test
```

---

## Performance Tuning

### VPS-Optimized Settings

For 2-4 core VPS with 2-8 GB RAM:

**1. Reduced flow timeouts** (faster memory recycling)
```yaml
flow:
  timeout:
    established: 60      # Default: 300
    emergency-closed: 10
```

**2. Disable HTTP body inspection** (CPU reduction)
```yaml
http:
  request-body-limit: 0
  response-body-limit: 0
```

**3. Strip unused protocols**
```yaml
app-layer:
  protocols:
    smb: { enabled: no }
    dcerpc: { enabled: no }
    smtp: { enabled: no }
    dns: { enabled: yes }  # Keep for DNS monitoring
    http: { enabled: yes } # Keep for web attacks
    tls: { enabled: yes }  # Keep for encrypted traffic
```

**4. AF_PACKET tuning**
```yaml
af-packet:
  - interface: default
    ring-size: 16384     # Packet buffer
    block-size: 32768    # Memory block size
```

**5. NIC offload (disable for accurate packet capture)**
```bash
ethtool -K eth0 gro off lro off tso off gso off
```

### Expected Performance

| Environment | CPU Usage | RAM Usage | Packet Processing |
|-------------|-----------|-----------|-------------------|
| **Small VPS** (2 cores, 2 GB) | 10-20% | 300-500 MB | ~10k pps |
| **Medium VPS** (4 cores, 4 GB) | 15-30% | 500-800 MB | ~50k pps |
| **Large VPS** (8 cores, 8 GB) | 20-40% | 800-1200 MB | ~100k pps |

**Latency:** Alert → Block: 300-500ms typical

---

## FAQ

### Q: Do I need Suricata if I already have fail2ban?

**A:** Suricata provides broader coverage:
- **fail2ban:** Log-based detection (SSH, web server logs)
- **Suricata:** Network-level detection (all traffic, any protocol)

**Recommendation:** Use both! They complement each other.

### Q: Will Suricata slow down my server?

**A:** With NFTBan's optimized config:
- **CPU:** 10-30% of 1 core
- **RAM:** 300-800 MB
- **Latency:** <1ms added

**Impact:** Negligible on typical VPS workloads.

### Q: How often are rules updated?

**A:** Automatically weekly (Sunday 3 AM) via systemd timer.

**Manual update:** `nftban suricata rules update`

### Q: Can I use custom rules?

**A:** Yes! Add to `/etc/suricata/rules/local.rules`:

```
alert http any any -> $HOME_NET any (msg:"SQL Injection Attempt"; content:"SELECT"; content:"FROM"; sid:1000001;)
```

Then reload: `systemctl restart suricata`

### Q: Does Suricata replace NFTBan's built-in modules?

**A:** No, it **enhances** them:
- DDoS module: Can use IDS-assisted scoring
- Portscan module: Can use Suricata alerts
- Login module: Works independently

All modules work with or without Suricata.

### Q: What happens if Suricata crashes?

**A:** NFTBan continues working:
- DDoS/portscan fall back to kernel log mode
- Threat feeds still active
- Login monitoring unaffected

**Restart:** `systemctl restart suricata`

### Q: Can I run Suricata on multiple interfaces?

**A:** Yes! Edit `/etc/suricata/suricata.yaml`:

```yaml
af-packet:
  - interface: eth0
    cluster-id: 99
  - interface: eth1
    cluster-id: 98
```

### Q: How do I disable Suricata temporarily?

```bash
# Disable and stop
sudo nftban suricata disable

# Later, re-enable
sudo nftban suricata enable
```

---

## Advanced Topics

### Custom Alert Actions

Create `/usr/local/bin/nftban-suricata-handler.sh`:

```bash
#!/bin/bash
# Custom handler for Suricata alerts

tail -f /var/log/suricata/eve.json | jq -r 'select(.event_type=="alert") | .src_ip' | while read ip; do
    # Custom action (e.g., temporary ban)
    nftban ban "$ip" --timeout 1h --comment "Suricata IDS alert"
done
```

### Integration with SIEM

Forward eve.json to your SIEM:

```bash
# Logstash
sudo apt-get install filebeat
# Configure filebeat to ship eve.json

# Elastic Stack
# Use Suricata module for Filebeat
```

### High-Availability Setup

For multiple servers:

```bash
# Server 1, 2, 3 all run Suricata
# Central nftban-core aggregates alerts
# Shared nftables ruleset via sync

# See: docs/HA-SETUP.md
```

---

## Reference Links

- **Suricata Official:** https://suricata.io/
- **ET/Open Rules:** https://rules.emergingthreats.net/
- **suricata-update:** https://suricata-update.readthedocs.io/
- **NFTBan Project:** https://github.com/itcmsgr/nftban
- **NFTBan Docs:** https://github.com/itcmsgr/nftban/tree/main/docs

---

## Support

**Community:**
- GitHub Issues: https://github.com/itcmsgr/nftban/issues
- Suricata Forum: https://forum.suricata.io/

**Commercial Support:**
- Email: contact@nftban.com

---

**Last Updated:** 2025-12-28
**Document Version:** 1.0
**Maintainer:** NFTBan Team
