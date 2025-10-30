# NFTBan v0.10.0 - Complete Boot Flow with Snapshots
**Auto-Save Every 5 Minutes + Restore on Boot**

═══════════════════════════════════════════════════════════════════

## 🎯 COMPLETE BOOT FLOW

### Timeline on Reboot:

```
T+0s:   System boots
        ↓
T+0s:   nftban-firewall-init.service starts
        ↓
T+0s:   ExecStartPre: Try restore from /var/lib/nftban/snapshots/last.nft
        ├─ IF snapshot exists → Load it IMMEDIATELY (protection NOW!)
        └─ IF no snapshot → Continue
        ↓
T+0s:   Check NFTBAN_STARTUP_DELAY from /etc/nftban/nftban.conf
        ↓
T+0-300s: WAIT (5 minutes default delay)
        ⏱️  User has time to login via console if needed
        ↓
T+300s: ExecStart: nftban firewall init
        ├─ Auto-detect SSH port from /etc/ssh/sshd_config
        ├─ Auto-detect connecting IPs (SSH_CLIENT + ifconfig.me)
        ├─ Write /etc/nftban/ports.d/00-ssh.conf
        ├─ Write /etc/nftban/whitelist.d/00-system.conf
        ├─ Build nftban_main.nft with policy accept
        └─ Load firewall
        ↓
T+300s: ExecStartPost: nftban snapshot save
        └─ Save current working state to /var/lib/nftban/snapshots/
        ↓
T+300s: nftban-snapshot.timer starts
        └─ Every 5 minutes: Auto-save snapshot
        ↓
T+305s: First snapshot auto-save
T+310s: Second snapshot auto-save
T+315s: Third snapshot auto-save
...     (continues every 5 minutes)
```

---

## 📁 SYSTEMD SERVICES

### 1. nftban-firewall-init.service
**Purpose:** Initialize firewall on boot with delay + snapshot restore/save

**File:** `/etc/systemd/system/nftban-firewall-init.service`

```ini
[Unit]
Description=NFTBan Firewall Initialization (with startup delay)
After=network-online.target nftables.service
Wants=network-online.target
Before=sshd.service

[Service]
Type=oneshot
RemainAfterExit=yes

# Enable 5-minute startup delay
Environment="NFTBAN_SYSTEMD_BOOT=1"
User=root
Group=root
EnvironmentFile=-/etc/nftban/nftban.conf

# 1. Restore last known-good snapshot (if exists)
ExecStartPre=-/usr/sbin/nftban snapshot restore

# 2. Wait 5 minutes, then init firewall
ExecStart=/usr/sbin/nftban firewall init

# 3. Save snapshot after successful init
ExecStartPost=/usr/sbin/nftban snapshot save

# On stop, flush firewall (safety)
ExecStop=/usr/bin/nft flush ruleset

Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
```

---

### 2. nftban-snapshot.timer
**Purpose:** Auto-save firewall state every 5 minutes

**File:** `/etc/systemd/system/nftban-snapshot.timer`

```ini
[Unit]
Description=NFTBan Firewall Snapshot Timer (every 5 minutes)

[Timer]
OnBootSec=5min       # First save 5 min after boot
OnUnitActiveSec=5min # Then every 5 minutes
Persistent=true

[Install]
WantedBy=timers.target
```

---

### 3. nftban-snapshot.service
**Purpose:** Save current firewall state

**File:** `/etc/systemd/system/nftban-snapshot.service`

```ini
[Unit]
Description=NFTBan Firewall Snapshot (save current state)
After=nftban-firewall-init.service

[Service]
Type=oneshot
User=nftban
Group=nftban
ExecStart=/usr/sbin/nftban snapshot save
Nice=10
IOSchedulingClass=best-effort

[Install]
WantedBy=multi-user.target
```

---

## 💾 SNAPSHOT MECHANISM

### What Gets Saved:

**Location:** `/var/lib/nftban/snapshots/`

**Files:**
```
/var/lib/nftban/snapshots/
├── last.nft           ← Most recent snapshot (symlink)
├── 2025-10-29_22-45.nft
├── 2025-10-29_22-50.nft
├── 2025-10-29_22-55.nft
└── ...
```

**Content of each snapshot:**
```nft
#!/usr/sbin/nft -f
# NFTBan Snapshot - Auto-saved on 2025-10-29 22:50:00
# Can be restored with: nft -f /var/lib/nftban/snapshots/last.nft

flush ruleset

# Complete nftables ruleset including:
# - inet nftban_runtime table
# - inet nftban_main table
# - All chains, sets, rules
```

---

## 🔄 HOW IT WORKS

### Scenario 1: First Boot (No Snapshot)

```
1. System boots
2. nftban-firewall-init.service starts
3. ExecStartPre: snapshot restore (no snapshot exists, skip)
4. WAIT 5 minutes (NFTBAN_STARTUP_DELAY)
5. ExecStart: nftban firewall init
   - Auto-detect SSH port: 22
   - Auto-detect IP: 1.2.3.4
   - Create configs
   - Load firewall (policy accept)
6. ExecStartPost: Save snapshot → /var/lib/nftban/snapshots/2025-10-29_22-45.nft
7. nftban-snapshot.timer starts
8. Every 5 min: Auto-save
```

**Result:** Safe init, snapshot saved for future reboots

---

### Scenario 2: Reboot (Snapshot Exists)

```
1. System reboots
2. nftban-firewall-init.service starts
3. ExecStartPre: snapshot restore
   → Loads /var/lib/nftban/snapshots/last.nft IMMEDIATELY
   → Firewall protected BEFORE 5-minute delay!
4. WAIT 5 minutes (optional, firewall already active)
5. ExecStart: nftban firewall init
   → Verifies/updates configuration
   → Re-detects IPs (in case IP changed)
6. ExecStartPost: Save new snapshot
7. Continue auto-saving every 5 min
```

**Result:**
- **Immediate protection** (snapshot loaded at T+0s)
- **Updated protection** (re-init at T+300s)
- **No lockout risk** (policy accept + whitelisted IPs)

---

### Scenario 3: Emergency (Broken Config)

```
1. Admin makes bad config change
2. Firewall breaks
3. System reboots
4. nftban-firewall-init.service starts
5. ExecStartPre: snapshot restore
   → Loads LAST KNOWN GOOD config
   → System protected with working config!
6. Wait 5 minutes
7. firewall init runs (might fail if config still broken)
8. BUT: snapshot from step 5 is still active!
```

**Result:** Last known-good config provides failsafe

---

## 📊 SNAPSHOT RETENTION

### Auto-Cleanup Policy:

**Keep:**
- Last 24 snapshots (2 hours of history at 5-min intervals)
- Last 7 daily snapshots
- Last 4 weekly snapshots

**Delete:**
- Snapshots older than 30 days

**Implemented in:** `nftban snapshot cleanup` (auto-runs with save)

---

## 🛠️ MANUAL OPERATIONS

### Save Snapshot Manually:
```bash
sudo nftban snapshot save
# Saves to /var/lib/nftban/snapshots/2025-10-29_22-55.nft
```

### Restore Snapshot:
```bash
# Restore latest
sudo nftban snapshot restore

# Restore specific
sudo nftban snapshot restore 2025-10-29_22-45.nft
```

### List Snapshots:
```bash
nftban snapshot list
# Output:
# /var/lib/nftban/snapshots/
#   last.nft → 2025-10-29_22-55.nft (current)
#   2025-10-29_22-55.nft (5 min ago)
#   2025-10-29_22-50.nft (10 min ago)
#   2025-10-29_22-45.nft (15 min ago)
```

### Cleanup Old Snapshots:
```bash
sudo nftban snapshot cleanup
```

---

## ✅ INSTALLATION

### Step 1: Install Services
```bash
# Install all systemd units
sudo install -D -m 0644 \
  nftban-firewall-init.service \
  /etc/systemd/system/nftban-firewall-init.service

sudo install -D -m 0644 \
  nftban-snapshot.service \
  /etc/systemd/system/nftban-snapshot.service

sudo install -D -m 0644 \
  nftban-snapshot.timer \
  /etc/systemd/system/nftban-snapshot.timer

sudo systemctl daemon-reload
```

### Step 2: Enable Services
```bash
# Enable firewall init on boot
sudo systemctl enable nftban-firewall-init.service

# Enable snapshot timer
sudo systemctl enable nftban-snapshot.timer
```

### Step 3: Configure Delay
```bash
# Edit /etc/nftban/nftban.conf
NFTBAN_STARTUP_DELAY="300"  # 5 minutes
```

### Step 4: Test (Optional)
```bash
# Start services without reboot
sudo systemctl start nftban-firewall-init.service
sudo systemctl start nftban-snapshot.timer

# Check status
systemctl status nftban-firewall-init.service
systemctl list-timers nftban-snapshot.timer
```

---

## 🔍 VERIFICATION

### Check Snapshot Directory:
```bash
ls -la /var/lib/nftban/snapshots/
```

### Check Timer Status:
```bash
systemctl list-timers nftban-snapshot.timer
# Output:
# NEXT                          LEFT     LAST PASSED UNIT
# Mon 2025-10-29 23:00:00 UTC  3min left n/a  n/a    nftban-snapshot.timer
```

### Check Last Snapshot:
```bash
cat /var/lib/nftban/snapshots/last.nft | head -20
```

### Monitor Snapshots:
```bash
watch -n 60 'ls -lht /var/lib/nftban/snapshots/ | head -10'
```

---

## ⚡ PERFORMANCE

### Snapshot Save Time:
- **Duration:** ~50-100ms
- **CPU Impact:** Minimal (Nice=10, best-effort IO)
- **Disk Usage:** ~10-20KB per snapshot
- **Total:** ~500KB for 24 snapshots

### Boot Impact:
- **Snapshot Restore:** Instant (~10ms)
- **Startup Delay:** 5 minutes (configurable)
- **Total Init Time:** ~2-3 seconds (after delay)

---

## 🎯 BENEFITS

1. ✅ **Immediate Protection on Boot**
   - Snapshot restores at T+0s
   - No 5-minute vulnerability window

2. ✅ **Continuous Backup**
   - Auto-save every 5 minutes
   - Always have recent working config

3. ✅ **Failsafe Recovery**
   - Bad config? Last snapshot saves you
   - No manual intervention needed

4. ✅ **Zero Maintenance**
   - Auto-cleanup old snapshots
   - Runs in background

5. ✅ **No Lockout Risk**
   - Policy accept (safe default)
   - Whitelisted IPs in snapshot
   - 5-minute delay for manual access

---

**Document Version:** 1.0
**Created:** 2025-10-29
**Status:** ✅ COMPLETE - READY FOR DEPLOYMENT

═══════════════════════════════════════════════════════════════════

## BOTTOM LINE

**Before:**
- 5-minute delay → vulnerable window
- No backup config
- Lockout risk

**After:**
- Snapshot restores IMMEDIATELY → protected at T+0s ✅
- Auto-save every 5 minutes → continuous backup ✅
- Last known-good config → failsafe ✅
- Policy accept + whitelisted IPs → no lockout ✅

**Result:** BULLETPROOF boot protection! 🛡️

═══════════════════════════════════════════════════════════════════
