# Suricata Integration

NFTBan integrates with Suricata IDS for deep packet inspection and threat detection.

---

## Table of Contents
- [Purpose](#purpose)
- [Prerequisites](#prerequisites)
- [CLI Commands](#cli-commands)
- [Performance Tuning](#performance-tuning)
- [Configuration](#configuration)
- [Troubleshooting](#troubleshooting)
- [References](#references)

---

## Purpose

Enable deep packet inspection using Suricata IDS to detect:
- Brute force attacks (SSH, FTP, HTTP)
- Web application attacks (SQL injection, XSS)
- Malware command & control traffic
- Port scans and reconnaissance
- Protocol anomalies

---

## Prerequisites

| Requirement | Details |
|-------------|---------|
| Suricata | Version 7.x recommended |
| nftban | Version 1.12.0+ |
| Privileges | Root for service control |
| Rules | ET Open or commercial ruleset |

Install Suricata:
```bash
# RHEL/AlmaLinux/Rocky
dnf install suricata

# Debian/Ubuntu
apt install suricata
```

---

## CLI Commands

### Status
```bash
nftban suricata status
```

### Enable/Disable Filters
```bash
nftban suricata enable SSH_BRUTE_FORCE
nftban suricata disable POLICY_VIOLATIONS
```

### List Detection Filters
```bash
nftban suricata filters
```

### Profile Management
```bash
nftban suricata profile-detect    # Auto-detect optimal profile
nftban suricata profile-apply standard
```

### Rule Management
```bash
nftban suricata rules-verify      # Verify rules are present
nftban suricata rules-ensure      # Auto-download if missing
nftban suricata sid-top           # Top triggered signatures
```

---

## Performance Tuning

### Critical: Enable tpacket-v3

On RHEL/AlmaLinux/Rocky Linux, Suricata defaults to `tpacket-v2` causing **5x higher memory usage**.

**Symptoms:**
- Suricata using 900-1800 MB instead of 150-400 MB
- Log warning: `AF_PACKET tpacket-v3 is recommended for non-inline operation`

**Fix:**
```bash
sed -i '/use-mmap: yes/a\    tpacket-v3: yes' /etc/suricata/suricata.yaml
systemctl restart suricata
```

**Verify:**
```bash
ps aux | grep suricata | grep -v grep | awk '{print $6/1024 " MB"}'
```

### Real-World Results

| Server | OS | Before | After | Savings |
|--------|-----|--------|-------|---------|
| lab1 | AlmaLinux 9.7 | 1,828 MB | 454 MB | 75% |
| lab3 | AlmaLinux 9.7 | ~900 MB | 168 MB | 81% |
| lab4 | AlmaLinux 9.7 | ~900 MB | 167 MB | 81% |
| lab2 | Ubuntu 24.04 | n/a | 358 MB | (default v3) |

### Distro Defaults

| Distribution | Default tpacket | Action Required |
|--------------|-----------------|-----------------|
| Ubuntu 24.04 | v3 | None |
| Debian 12 | varies | Check config |
| AlmaLinux 9 | v2 | Add `tpacket-v3: yes` |
| Rocky Linux 9 | v2 | Add `tpacket-v3: yes` |
| RHEL 9 | v2 | Add `tpacket-v3: yes` |

### Ring Size Tuning

Adjust based on traffic volume:

```yaml
af-packet:
  - interface: eth0
    ring-size: 100000    # Default
    # Low traffic (<100 Mbps): 50000
    # High traffic (>500 Mbps): 200000
```

---

## Configuration

### Suricata YAML Configuration

```yaml
# /etc/suricata/suricata.yaml
af-packet:
  - interface: eth0
    cluster-id: 99
    cluster-type: cluster_flow
    defrag: yes
    use-mmap: yes
    tpacket-v3: yes    # Required for memory efficiency
    ring-size: 100000
```

### NFTBan Suricata Config

Path: `/etc/nftban/conf.d/suricata.conf`

```bash
# Enable Suricata integration
SURICATA_ENABLED="true"

# EVE log path
SURICATA_EVE_LOG="/var/log/suricata/eve.json"

# Detection thresholds
SURICATA_SCORE_THRESHOLD="100"
```

---

## Troubleshooting

### Suricata Shows 0 Rules Loaded

**Cause:** Missing rule files or incorrect path

**Fix:**
```bash
# Update rules
suricata-update

# Verify rules exist
ls -la /var/lib/suricata/rules/

# Restart
systemctl restart suricata
```

### High Memory Despite tpacket-v3

**Check:**
- Large `ring-size` value
- High `flow.memcap` setting
- Many complex rules
- `detect.profile: high`

**Reduce memory:**
```yaml
detect:
  profile: low

flow:
  memcap: 128mb
```

### Parse Errors in Logs

**Cause:** Unused protocol parsers

**Fix:** Disable unused protocols:
```yaml
app-layer:
  protocols:
    ftp:
      enabled: no
    smb:
      enabled: no
```

### EVE Log Not Fresh

**Cause:** Suricata not writing to EVE log

**Check:**
```bash
stat /var/log/suricata/eve.json
tail -1 /var/log/suricata/eve.json | jq .timestamp
```

---

## References

- [Suricata AF_PACKET Documentation](https://docs.suricata.io/en/latest/configuration/af-packet.html)
- [Suricata Performance Guide](https://docs.suricata.io/en/latest/performance/tuning-considerations.html)
- Source: `/cli/lib/nftban/cli/cmd_suricata.sh`
- Config: `/etc/nftban/conf.d/suricata.conf`
