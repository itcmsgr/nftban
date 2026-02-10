# Troubleshooting

Common issues and solutions for NFTBan.

---

## Table of Contents
- [Diagnostic Commands](#diagnostic-commands)
- [Daemon Issues](#daemon-issues)
- [nftables Issues](#nftables-issues)
- [Permission Issues](#permission-issues)
- [Detection Issues](#detection-issues)
- [Update Issues](#update-issues)

---

## Diagnostic Commands

```bash
# Full system status
nftban status

# Health check with details
nftban health check

# Debug information
nftban debug

# Smoke tests
nftban smoke
```

---

## Daemon Issues

### Daemon Not Starting

**Check status:**
```bash
systemctl status nftband
journalctl -u nftband -n 50
```

**Common causes:**
- Socket conflict: Another process using socket
- Permission issue: Wrong ownership on socket directory
- Config error: Invalid configuration

**Fix:**
```bash
# Reset socket directory
rm -rf /run/nftban
systemd-tmpfiles --create /usr/lib/tmpfiles.d/nftban.conf

# Restart
systemctl restart nftband
```

### Daemon Crashes

**Check logs:**
```bash
journalctl -u nftband --since "1 hour ago"
tail -100 /var/log/nftban/nftban.log
```

**Auto-heal:**
```bash
nftban health check --auto-heal
```

---

## nftables Issues

### Tables Not Created

**Check:**
```bash
nft list tables
nftban nftables verify
```

**Fix:**
```bash
nftban nftables init
```

### Rules Not Loading

**Check:**
```bash
nft list ruleset | grep -i nftban
```

**Fix:**
```bash
# Reinitialize
nftban nftables flush
nftban nftables init
nftban whitelist sync
```

### Conflict with Other Firewalls

**Symptoms:** Rules disappear, unexpected blocks

**Check for conflicts:**
```bash
systemctl status firewalld
systemctl status ufw
```

**Resolution:** NFTBan coexists with other firewalls but uses separate tables. Ensure no overlap in chain priorities.

---

## Permission Issues

### Polkit Denials

**Check:**
```bash
journalctl -u polkit --since "10 minutes ago"
```

**User not in group:**
```bash
# Add user to nftban-cli group
usermod -aG nftban-cli username

# Log out and back in
```

### File Permission Errors

**Fix:**
```bash
nftban permissions enforce
# or
nftban health check --auto-heal
```

---

## Detection Issues

### Bans Not Applied

**Check:**
```bash
nftban list
nft list set inet nftban blacklist_ipv4
```

**Verify IP not whitelisted:**
```bash
nftban check <IP>
```

### False Positives

**Add to whitelist:**
```bash
nftban whitelist add <IP> --comment "Legitimate traffic"
```

**Adjust thresholds:**
```bash
# Edit module config
vi /etc/nftban/conf.d/portscan.conf.local
```

### Feeds Not Updating

**Check:**
```bash
nftban feeds status
```

**Manual update:**
```bash
nftban feeds update
```

**Check connectivity:**
```bash
curl -I https://www.spamhaus.org/drop/drop.txt
```

---

## Update Issues

### Update Fails

**Check logs:**
```bash
tail -50 /var/log/nftban/update.log
```

**Force update:**
```bash
nftban update force
```

### Rollback

**If update caused issues:**
```bash
nftban update list          # List backups
nftban update rollback      # Restore previous version
```

### DEB/RPM Lock Issues

**DEB:**
```bash
# Fix dpkg state
dpkg --configure -a
apt-get install -f
```

**RPM:**
```bash
# Clear lock
rm -f /var/run/yum.pid
dnf clean all
```

---

## GeoIP Issues

### Database Missing

**Download:**
```bash
nftban geoip update
```

### Lookup Returns Unknown

**Check database:**
```bash
ls -la /var/lib/nftban/geoip/
nftban geoip lookup 8.8.8.8   # Should return US
```

---

## Log Locations

| Log | Path |
|-----|------|
| Main log | `/var/log/nftban/nftban.log` |
| Update log | `/var/log/nftban/update.log` |
| Daemon journal | `journalctl -u nftband` |
| Health reports | `/var/lib/nftban/reports/` |

---

## Getting Help

If issues persist:

1. Run `nftban debug` and save output
2. Check `/var/log/nftban/` logs
3. Open issue at [GitHub](https://github.com/itcmsgr/nftban/issues)
