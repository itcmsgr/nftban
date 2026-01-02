# NFTBan Systemd Services - Privilege Classification

**Date:** 2026-01-02
**Security Finding:** [install/systemd/*.service] Unnecessary Root Privileges
**Status:** FIXING

---

## Classification Criteria

### Category A: Enforcement / Privileged
Services that **MUST** have elevated privileges:
- Direct nftables operations
- CAP_NET_ADMIN required
- Cannot delegate to daemon

### Category B: Non-Essential / Auxiliary
Services that **MUST NOT** run as root:
- Statistics collectors
- Log parsers
- Metrics exporters
- Cleanup jobs
- Web UI components
- All firewall changes via IPC

---

## Service Classification

### ✅ Category A: Legitimately Privileged

| Service | User | Justification | Status |
|---------|------|---------------|--------|
| **nftband.service** | root | AUTHORITATIVE nftables writer, requires CAP_NET_ADMIN | ✅ Correct |
| **nftban-health-fix.service** | root | Admin-triggered permission fixer, requires root to chown/chmod | ✅ Correct (oneshot, manual only) |

**Total: 2 services** (11% of services)

---

### ❌ Category B: Currently Root, MUST Be Fixed

| Service | Current User | Should Be | Firewall Writes | Action |
|---------|--------------|-----------|-----------------|--------|
| **nftban-maintenance.service** | root | nftban | Via IPC ✅ | **FIX** |
| **nftban-suricata-stats.service** | root | nftban | None | **FIX** |
| **nftban-health.service** | root | nftban | None (read-only checks) | **FIX** |
| **nftban-login-monitor.service** | root | nftban | Via IPC ✅ | **FIX** |
| **nftban-suricata.service** | root | nftban | None (wrapper) | **FIX** |
| **nftban-suricata-update.service** | root | nftban | None (downloads) | **FIX** |
| **nftban-ui-auth.service** | root | nftban | None (PAM auth) | **FIX** |

**Total: 7 services** (39% of services) - **SECURITY RISK**

---

### ✅ Category B: Already Correct

| Service | User | Type | Status |
|---------|------|------|--------|
| **nftban-metrics-exporter.service** | nftban | Metrics collector | ✅ Correct |
| **nftban-core-feeds.service** | (needs check) | Feed updates | ? |
| **nftban-core-geoip.service** | (needs check) | GeoIP updates | ? |
| **nftban-ui.service** | (needs check) | Web UI | ? |
| **nftban-queue.service** | (needs check) | Queue processor | ? |
| **nftban-watchdog.service** | (needs check) | Monitoring | ? |
| **nftban-snapshot.service** | (needs check) | Backup | ? |
| **nftban-rollback.service** | (needs check) | Restore | ? |
| **nftban-rbl-check.service** | (needs check) | RBL lookups | ? |

**Note:** Services without explicit User= inherit from parent (may default to root if started by root)

---

## Fix Strategy

### Phase 1: Update Service Files (Priority Services)

**1. nftban-maintenance.service**
- ✅ Already uses `nft_ipc_add_element()` (no direct nft calls)
- Change: `User=root` → `User=nftban`
- Add: `SupplementaryGroups=suricata` (for log reading)
- Add hardening directives

**2. nftban-suricata-stats.service**
- Reads: `/var/log/suricata/eve.json`
- Writes: `/var/lib/nftban/cache/`
- Change: `User=root` → `User=nftban`
- Filesystem: Add nftban to suricata group
- Add hardening directives

**3. nftban-login-monitor.service**
- Reads: `/var/log/auth.log`, `/var/log/secure`
- Writes: `/var/lib/nftban/login/`
- Change: `User=root` → `User=nftban`
- Filesystem: Add nftban to adm group (for log reading)
- Add hardening directives

**4. nftban-health.service**
- Reads: nftables status, configs
- Writes: `/var/lib/nftban/health/`
- Change: `User=root` → `User=nftban`
- Keep: `CAP_NET_ADMIN` for nft list operations
- Add hardening directives

### Phase 2: Filesystem Permissions

**Required Group Memberships:**
```bash
# Add nftban user to required groups
usermod -aG suricata nftban  # For eve.json reading
usermod -aG adm nftban       # For /var/log/* reading (Debian/Ubuntu)
usermod -aG systemd-journal nftban  # For journalctl reading
```

**File Permissions:**
```bash
# Suricata logs
chown root:suricata /var/log/suricata/eve.json
chmod 0640 /var/log/suricata/eve.json

# NFTBan state directories
chown root:nftban /var/lib/nftban/
chmod 0770 /var/lib/nftban/

chown root:nftban /var/log/nftban/
chmod 0770 /var/log/nftban/

chown root:nftban /var/cache/nftban/
chmod 0770 /var/cache/nftban/

chown root:nftban /run/nftban/
chmod 0770 /run/nftban/
```

### Phase 3: Hardening Directives

**Standard template for auxiliary services:**
```ini
[Service]
User=nftban
Group=nftban
SupplementaryGroups=suricata adm  # As needed

# Core hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true

# Minimal filesystem access
ReadWritePaths=/var/lib/nftban /var/log/nftban /var/cache/nftban /run/nftban

# Network restrictions (only if service doesn't need network)
# RestrictAddressFamilies=AF_UNIX

# Resource limits
MemoryMax=256M
TasksMax=20
```

---

## Verification Checklist

### Pre-Deployment Checks

- [ ] All auxiliary services changed to `User=nftban`
- [ ] No auxiliary service has CAP_NET_ADMIN (except health.service for read-only nft list)
- [ ] No auxiliary service calls `nft` directly for writes
- [ ] All firewall writes go through daemon IPC
- [ ] Required group memberships added (suricata, adm, systemd-journal)
- [ ] File permissions updated for /var/lib/nftban, /var/log/nftban, etc.

### Post-Deployment Checks

- [ ] Start each auxiliary service as nftban user
- [ ] Verify stats still collected (nftban-suricata-stats)
- [ ] Verify maintenance still works (nftban-maintenance)
- [ ] Verify health checks succeed (nftban-health)
- [ ] Verify login monitoring works (nftban-login-monitor)
- [ ] Check logs for permission-denied errors
- [ ] Verify no auxiliary service can write to /etc/nftban (except blacklist.d)
- [ ] Verify auxiliary services cannot run nft directly

### Security Validation

Test that auxiliary services are properly restricted:
```bash
# Test 1: Cannot run nft directly
sudo -u nftban nft list ruleset
# Expected: Permission denied OR capability denied

# Test 2: Cannot write to /etc/nftban
sudo -u nftban touch /etc/nftban/test.conf
# Expected: Permission denied

# Test 3: CAN write to /var/lib/nftban
sudo -u nftban touch /var/lib/nftban/test.txt
# Expected: Success

# Test 4: CAN read eve.json (via group)
sudo -u nftban cat /var/log/suricata/eve.json
# Expected: Success (if nftban in suricata group)

# Test 5: Firewall writes via IPC work
systemctl start nftban-maintenance.service
journalctl -u nftban-maintenance -n 50
# Expected: No permission errors, IPC calls succeed
```

---

## Risk Assessment

### Before Fix

| Risk | Severity | Likelihood | Impact |
|------|----------|------------|--------|
| **Auxiliary service compromise** | HIGH | Medium | Root escalation possible |
| **Statistics collector exploit** | HIGH | Low | Full root compromise |
| **Maintenance script vulnerability** | HIGH | Low | Root shell access |

**Overall Risk:** 🔴 **HIGH** - Violates principle of least privilege

### After Fix

| Risk | Severity | Likelihood | Impact |
|------|----------|------------|--------|
| **Auxiliary service compromise** | LOW | Medium | Limited to nftban group permissions |
| **Statistics collector exploit** | LOW | Low | Cannot escalate to root |
| **Maintenance script vulnerability** | LOW | Low | Cannot modify /etc/nftban configs |

**Overall Risk:** 🟢 **LOW** - Least privilege enforced

---

## Architectural Benefits

This fix is now **safe** because of prior IPC work:

1. ✅ **Single-writer architecture** - Only nftband.service touches nftables
2. ✅ **IPC mechanism** - All writes via /run/nftban/nftband.sock
3. ✅ **Maintenance script migrated** - Uses nft_ipc_add_element()
4. ✅ **No sudo workarounds** - Clean privilege separation

**This is exactly the architectural payoff we designed for.**

---

## Files to Modify

### Service Files (7 fixes)
1. install/systemd/nftban-maintenance.service
2. install/systemd/nftban-suricata-stats.service
3. install/systemd/nftban-health.service
4. install/systemd/nftban-login-monitor.service
5. install/systemd/nftban-suricata.service
6. install/systemd/nftban-suricata-update.service
7. install/systemd/nftban-ui-auth.service

### Documentation
- SYSTEMD-SERVICE-CLASSIFICATION.md (this file)
- ARCHITECTURE-NFT-POLICY.md (reference for justification)

---

## Closing Criteria

The security finding is **CLOSED** when:

✅ All auxiliary services run as `User=nftban`
✅ No auxiliary service has root privileges
✅ No auxiliary service calls nft directly for writes
✅ Required log files readable via group permissions
✅ Firewall writes only via daemon IPC
✅ All verification tests pass

**Status:** 🔴 IN PROGRESS (7 services to fix)

---

**Last Updated:** 2026-01-02
