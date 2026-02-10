# Suricata Performance Tuning for NFTBan

## Overview

NFTBan integrates with Suricata IDS for deep packet inspection. This guide covers performance optimizations, particularly the critical `tpacket-v3` setting for AF_PACKET mode.

---

## Critical: Enable tpacket-v3

### The Problem

On RHEL/AlmaLinux/Rocky Linux systems, Suricata may default to `tpacket-v2` for AF_PACKET capture, causing **5x higher memory usage** than necessary.

**Symptoms:**
- Suricata using 900-1800 MB RAM instead of 150-400 MB
- Log warning: `AF_PACKET tpacket-v3 is recommended for non-inline operation`
- Swap pressure on low-memory VPS instances

### The Solution

Add `tpacket-v3: yes` to your Suricata configuration:

```yaml
# /etc/suricata/suricata.yaml
af-packet:
  - interface: eth0
    cluster-id: 99
    cluster-type: cluster_flow
    defrag: yes
    use-mmap: yes
    tpacket-v3: yes    # <-- ADD THIS LINE
    ring-size: 100000
```

### Quick Fix (one-liner)

```bash
sed -i '/use-mmap: yes/a\    tpacket-v3: yes' /etc/suricata/suricata.yaml
systemctl restart suricata
```

### Verify

```bash
# Check memory usage (should be 150-450 MB, not 900-1800 MB)
ps aux | grep suricata | grep -v grep | awk '{print $6/1024 " MB"}'

# Check logs - warning should be gone
grep -i "tpacket-v3 is recommended" /var/log/suricata/suricata.log
```

---

## Real-World Results

Data from NFTBan production deployments (February 2026):

| Server | OS | Before tpacket-v3 | After tpacket-v3 | Savings |
|--------|-----|-------------------|------------------|---------|
| lab1 | AlmaLinux 9.7 | 1,828 MB | 454 MB | **75%** |
| lab3 | AlmaLinux 9.7 | ~900 MB | 168 MB | **81%** |
| lab4 | AlmaLinux 9.7 | ~900 MB | 167 MB | **81%** |
| lab2 | Ubuntu 24.04 | n/a | 358 MB | (already v3) |

All servers running ~48,000 ET Open rules.

---

## Why tpacket-v3 Matters

### tpacket-v2 (Legacy)
- Uses **fixed-size ring buffers** allocated at startup
- Each block sized for maximum MTU regardless of actual packet sizes
- Memory formula: `ring-size × block_size × threads`
- Wastes memory on small packets

### tpacket-v3 (Recommended)
- Uses **variable-size blocks** that adapt to actual packet sizes
- More efficient memory utilization
- Same detection capability, lower resource usage
- Default in Suricata 7.x on some distros (Ubuntu), but NOT on RHEL-based

---

## Distro Defaults

| Distribution | Suricata Source | Default tpacket |
|--------------|-----------------|-----------------|
| Ubuntu 24.04 | apt | **v3** (good) |
| Debian 12 | apt | varies |
| AlmaLinux 9 | EPEL | **v2** (needs fix) |
| Rocky Linux 9 | EPEL | **v2** (needs fix) |
| RHEL 9 | EPEL | **v2** (needs fix) |

**Recommendation:** Always explicitly set `tpacket-v3: yes` regardless of distro.

---

## Other Tuning Options

### Ring Size

Adjust based on traffic volume:

```yaml
af-packet:
  - interface: eth0
    ring-size: 100000    # Default, good for most cases
    # Low traffic (<100 Mbps): 50000
    # High traffic (>500 Mbps): 200000
```

### Thread Count

Let Suricata auto-detect or set explicitly:

```yaml
threading:
  set-cpu-affinity: yes
  cpu-affinity:
    - management-cpu-set:
        cpu: [ 0 ]
    - receive-cpu-set:
        cpu: [ 0, 1 ]
    - worker-cpu-set:
        cpu: [ "all" ]
```

### Memory Limits

For constrained environments:

```yaml
# Reduce pattern matcher memory
detect:
  profile: low           # Options: low, medium, high, custom

# Limit flow table
flow:
  memcap: 128mb          # Default 256mb
  hash-size: 65536       # Default 65536
```

---

## Monitoring Suricata with NFTBan

### Check Status
```bash
nftban suricata status
```

### View Rules Loaded
```bash
nftban suricata rules
```

### Check Integration Health
```bash
nftban health check | grep -i suricata
```

---

## Troubleshooting

### Suricata Shows 0 Rules Loaded

1. Check rule path configuration:
   ```bash
   grep -A5 "rule-files:" /etc/suricata/suricata.yaml
   ```

2. Verify rules exist:
   ```bash
   ls -la /var/lib/suricata/rules/
   ```

3. Run suricata-update:
   ```bash
   suricata-update
   systemctl restart suricata
   ```

### High Memory Despite tpacket-v3

Check for other causes:
- Large `ring-size` value
- High `flow.memcap`
- Many rules with complex patterns
- `detect.profile: high`

### Parse Errors in Logs

Disable unused protocols:
```yaml
# /etc/suricata/suricata.yaml
app-layer:
  protocols:
    ftp:
      enabled: no        # If not using FTP
    smb:
      enabled: no        # If not using SMB
```

---

## References

- [Suricata AF_PACKET Documentation](https://docs.suricata.io/en/latest/configuration/af-packet.html)
- [Suricata Performance Guide](https://docs.suricata.io/en/latest/performance/tuning-considerations.html)
- [NFTBan Suricata Integration](https://github.com/itcmsgr/nftban/wiki)

---

*Last updated: 2026-02-10*
