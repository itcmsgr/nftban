# NFTBan v0.10.0 - Quick Win Ideas for Current Release

Based on ChatGPT's architectural review and current implementation status.

## 🎯 EASY WINS (Can Implement Now)

### 1. **Add Dry-Run Mode** ⭐ HIGH VALUE
**Complexity**: Low
**Time**: 1-2 hours
**Value**: Prevents lockout accidents

```bash
# Add to all major commands
nftban reload --dry-run      # Show what WOULD change
nftban ban IP --dry-run       # Show what WOULD be banned
nftban feeds enable X --dry-run
```

**Implementation**:
- Add `--dry-run` flag parsing
- Print proposed changes instead of executing
- Use `nft -c` for validation (already validates syntax)
- Show diff of before/after

**Files to modify**:
- `src/usr/lib/nftban/cli/cmd_*.sh` - Add dry-run flag support
- Create `src/usr/lib/nftban/core/nftban_dry_run.sh` helper module

---

### 2. **Config Doctor Command** ⭐ HIGH VALUE
**Complexity**: Low
**Time**: 2-3 hours
**Value**: Self-diagnostic tool for users

```bash
nftban doctor
# or
nftban health check --doctor
```

**Checks**:
- ✅ All required binaries exist (nft, jq, curl, etc.)
- ✅ File permissions correct (root:nftban, 0640, etc.)
- ✅ GeoIP database present and readable
- ✅ Config file syntax valid (can parse)
- ✅ No CIDR overlaps in whitelist/blacklist
- ✅ Feed URLs are reachable (curl -I test)
- ✅ nftables kernel module loaded
- ✅ Polkit rules installed
- ✅ bash-completion installed

**Implementation**:
- Add new command: `src/usr/lib/nftban/cli/cmd_doctor.sh`
- Reuse existing health check functions
- Add new validation functions
- Output colored report with ✅/⚠️/❌

---

### 3. **Pre-Reload Snapshot** ⭐ MEDIUM VALUE
**Complexity**: Very Low
**Time**: 30 minutes
**Value**: Safety net for failed reloads

**Implementation**:
- Add to existing reload function in `nftban_nftables.sh`
- Before reload: `nft list ruleset > /var/backups/nftban/pre-reload-$(date +%s).nft`
- Keep last 10 snapshots
- Add `nftban rollback` command to restore last snapshot

---

### 4. **Enhanced Stats - Feed Hit Counters** ⭐ MEDIUM VALUE
**Complexity**: Medium
**Time**: 2-3 hours
**Value**: Shows which feeds are actually blocking traffic

**Add to stats dashboard**:
```
[FEEDS EFFECTIVENESS]
  • GREENSNOW              1,234 blocks (15% of total)
  • SPAMHAUS_DROP            456 blocks (5% of total)
  • TOR_EXITS                 89 blocks (1% of total)
```

**Implementation**:
- Use nftables set counters: `counter name @feed_hits`
- Query with `nft list set ... | grep counter`
- Add to `nftban_stats.sh`

---

### 5. **Feed Categories in Interactive Select** ⭐ LOW VALUE
**Complexity**: Low
**Time**: 1 hour
**Value**: Better UX

**Enhancement to `nftban feeds select`**:
```
┌─ Quick Presets ─────────────────────────────┐
│ [1] Basic Protection (SPAMHAUS + GREENSNOW) │
│ [2] SSH Hardening (SSH feeds)                │
│ [3] Anonymous Blocking (TOR + Proxies)       │
│ [4] Full Protection (All feeds)              │
│ [5] Custom Selection                         │
└──────────────────────────────────────────────┘
```

**Implementation**:
- Add preset selection menu to `cmd_feeds.sh`
- Enable multiple feeds with one command

---

### 6. **Backup Retention Policy** ⭐ LOW VALUE
**Complexity**: Very Low
**Time**: 30 minutes
**Value**: Prevent /var/backups/ from filling up

**Implementation**:
- Add to existing backup function
- Keep last 7 days of daily backups
- Keep last 4 weeks of weekly backups
- Add `nftban backup cleanup --older-than 7d`

---

### 7. **Ban Comment Enhancement** ⭐ MEDIUM VALUE
**Complexity**: Low
**Time**: 1 hour
**Value**: Better audit trail

**Current**: Ban comment logged but not searchable
**Enhancement**: Add `nftban search comment "keyword"` to search ban logs by comment

```bash
nftban ban 1.2.3.4 -m "Brute force attempt from China"
nftban search comment "China"
# Returns all bans with "China" in comment
```

**Implementation**:
- Add to `cmd_search.sh`
- Search `/var/log/nftban/ban.log` for comment field
- Display results with timestamps

---

### 8. **Feed Update Status in `nftban status`** ⭐ LOW VALUE
**Complexity**: Very Low
**Time**: 15 minutes
**Value**: Quick visibility

**Add to `nftban status` output**:
```
[FEEDS STATUS]
  Enabled: 3/16 feeds
  Last Update: 2 hours ago
  Next Update: in 1 hour
```

**Implementation**:
- Add section to `cmd_status.sh`
- Read feed update timestamps from `/var/lib/nftban/feeds/`

---

### 9. **IP Whois Integration** ⭐ MEDIUM VALUE
**Complexity**: Low
**Time**: 1 hour
**Value**: Better incident response

```bash
nftban whois 1.2.3.4
# Shows:
#   IP: 1.2.3.4
#   Country: CN (China)
#   ASN: AS4134 (Chinanet)
#   Organization: China Telecom
#   GeoIP: Beijing, China
#   Currently: BANNED (since 2025-11-02 19:35)
#   Reason: SSH brute force
```

**Implementation**:
- Use existing GeoIP data
- Add `whois` command lookup (optional, if whois installed)
- Combine with ban log search

---

### 10. **Systemd Service Hardening** ⭐ HIGH VALUE (Security)
**Complexity**: Low
**Time**: 1 hour
**Value**: Security best practices

**Add to existing systemd units**:
- `PrivateTmp=yes`
- `ProtectSystem=full`
- `ProtectHome=yes`
- `NoNewPrivileges=yes`
- `ReadOnlyPaths=/usr /boot /etc` (except /etc/nftban)

**Implementation**:
- Update existing `.service` files
- Test on lab servers
- Document in installation guide

---

## 🔮 FUTURE RELEASES (Not Now, But Good Ideas)

### Future v0.11.0+:
- **Atomic reload with table swap** (needs careful testing)
- **Central list sync** (master/slave architecture)
- **Web API** (REST API for remote management)
- **Prometheus metrics export**
- **IPv6 full parity** (currently IPv4-focused)

---

## 📊 PRIORITY MATRIX

| Feature | Value | Complexity | Time | Priority |
|---------|-------|------------|------|----------|
| Dry-Run Mode | High | Low | 2h | **NOW** |
| Config Doctor | High | Low | 3h | **NOW** |
| Pre-Reload Snapshot | Medium | Very Low | 30m | **NOW** |
| Feed Hit Counters | Medium | Medium | 3h | **NEXT** |
| Systemd Hardening | High | Low | 1h | **NEXT** |
| Ban Comment Search | Medium | Low | 1h | **NEXT** |
| Feed Presets | Low | Low | 1h | **LATER** |
| IP Whois | Medium | Low | 1h | **LATER** |
| Backup Retention | Low | Very Low | 30m | **LATER** |
| Feed Status | Low | Very Low | 15m | **LATER** |

---

## 🎯 RECOMMENDED IMPLEMENTATION ORDER

### Phase 1 (Today/This Week):
1. ✅ TOR and Proxy feeds (DONE - commit 986cfcb)
2. ✅ Pre-Reload Snapshot (DONE - commit f86f763)
3. ⏭️ Systemd Service Hardening (1 hour) - NEXT

### Phase 2 (Next Week):
4. Dry-Run Mode (2 hours)
5. Config Doctor (3 hours)

### Phase 3 (When Energy):
6. Feed Hit Counters (3 hours)
7. Ban Comment Search (1 hour)
8. IP Whois (1 hour)

---

## 💡 EASIEST TO START WITH

If you want **one quick win right now** (15-30 minutes):

### **Pre-Reload Snapshot**
Add this to `nftban_nftables.sh` before the reload function:

```bash
# Backup before reload
BACKUP_DIR="/var/backups/nftban"
mkdir -p "$BACKUP_DIR"
nft list ruleset > "$BACKUP_DIR/pre-reload-$(date +%s).nft"

# Keep only last 10 backups
ls -t "$BACKUP_DIR"/pre-reload-*.nft | tail -n +11 | xargs rm -f
```

This gives you instant rollback capability with zero risk.

---

## ❓ QUESTIONS

1. **Which quick wins interest you most?**
2. **Do you want me to implement Dry-Run Mode or Config Doctor first?**
3. **Should we add Pre-Reload Snapshot to the current code?**

All of these are **small, safe additions** that don't require architectural changes.
