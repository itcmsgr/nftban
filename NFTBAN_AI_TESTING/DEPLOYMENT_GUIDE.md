# NFTBan v0.30 - DEPLOYMENT GUIDE

**Status:** ✅ Ready for Testing
**Date:** 2025-11-03
**Location:** `/home/gituser/github/nftban/NFTBAN_AI_TESTING/`

---

## 🎯 **WHAT WE BUILT**

### ✅ **Complete Components:**

1. **Inventory Helpers** (4 files)
   - `helpers/nftban-procnet` - Process/socket tracking
   - `helpers/nftban-pkgs` - Package inventory (RPM/DEB)
   - `helpers/nftban-verify` - Tamper detection
   - `helpers/nftban-firewall` - Firewall status

2. **Health System** (3 files)
   - `health/nftban-health` - Enhanced health with --inventory, --alert, --diff, --sign
   - `health/nftban-baseline-save` - Baseline management
   - `health/nftban-verify-signature` - Crypto verification

3. **Smart Mail Adapter** (1 file)
   - `mail/nftban_mail_v030.sh` - Auto-detects: v0.10 mail → sendmail → msmtp → curl

4. **GeoIP** (3 files)
   - `geoip/main.go` - Go source (MaxMind + builtin fallback)
   - `geoip/go.mod` - Go module
   - `geoip/BUILD.sh` - Build script

5. **Configuration** (1 file)
   - `config/mail.conf` - Mail settings (integrates with v0.10)

6. **Documentation** (4 files)
   - `docs/README.md` - Main documentation
   - `docs/MODULAR_ARCHITECTURE.md` - **UNIQUE approach explained**
   - `docs/INTEGRATION_SUMMARY.md` - How v0.30 integrates
   - `docs/MAIL_SYSTEM_DESIGN.md` - Mail design decisions

7. **Tests** (1 file)
   - `tests/test_v030_complete.sh` - Comprehensive test suite

**Total:** 17 files, all ready for deployment!

---

## 🚀 **QUICK DEPLOYMENT**

### **Step 1: Install Helpers**

```bash
cd /home/gituser/github/nftban/NFTBAN_AI_TESTING

# Install inventory helpers
sudo install -m 0755 helpers/nftban-procnet /usr/libexec/nftban/
sudo install -m 0755 helpers/nftban-pkgs /usr/libexec/nftban/
sudo install -m 0755 helpers/nftban-verify /usr/libexec/nftban/
sudo install -m 0755 helpers/nftban-firewall /usr/libexec/nftban/
```

### **Step 2: Install Health Commands**

```bash
# Install health scripts
sudo install -m 0755 health/nftban-health /usr/local/lib/nftban/
sudo install -m 0755 health/nftban-baseline-save /usr/local/lib/nftban/
sudo install -m 0755 health/nftban-verify-signature /usr/local/lib/nftban/

# Create symlinks
sudo ln -sf /usr/local/lib/nftban/nftban-health /usr/local/bin/
sudo ln -sf /usr/local/lib/nftban/nftban-baseline-save /usr/local/bin/
sudo ln -sf /usr/local/lib/nftban/nftban-verify-signature /usr/local/bin/
```

### **Step 3: Install Mail Adapter**

```bash
# Install mail library
sudo install -m 0644 mail/nftban_mail_v030.sh /usr/lib/nftban/core/
```

### **Step 4: Build & Install GeoIP**

```bash
# Install Go (if not installed)
sudo dnf install golang -y  # Fedora/RHEL
# OR
sudo apt install golang -y  # Ubuntu/Debian

# Build GeoIP
cd geoip
./BUILD.sh

# Install binary
sudo install -m 0755 nftban-geoip /usr/lib/nftban/bin/
```

### **Step 5: Setup Polkit**

```bash
# Create Polkit rules
sudo tee /etc/polkit-1/rules.d/50-nftban-v030.rules <<'EOF'
polkit.addRule(function (action, subject) {
  if (action.id !== "org.freedesktop.policykit.exec") return;
  var prog = action.lookup("program");
  var ok = [
    "/usr/libexec/nftban/nftban-procnet",
    "/usr/libexec/nftban/nftban-pkgs",
    "/usr/libexec/nftban/nftban-verify",
    "/usr/libexec/nftban/nftban-firewall"
  ];
  if (ok.indexOf(prog) !== -1 && subject.isInGroup("auditors")) {
    return polkit.Result.YES;
  }
});
EOF

# Create auditors group
sudo groupadd -f auditors
sudo usermod -aG auditors $USER
```

### **Step 6: Test Installation**

```bash
# Run test suite
cd /home/gituser/github/nftban/NFTBAN_AI_TESTING/tests
./test_v030_complete.sh
```

---

## 📋 **VERIFICATION CHECKLIST**

```bash
# 1. Check helpers
ls -lh /usr/libexec/nftban/nftban-*

# 2. Check health commands
which nftban-health
which nftban-baseline-save

# 3. Check mail adapter
ls -lh /usr/lib/nftban/core/nftban_mail_v030.sh

# 4. Check GeoIP
/usr/lib/nftban/bin/nftban-geoip --version

# 5. Test inventory
nftban-health --inventory | jq .

# 6. Test alert
nftban-health --alert | jq .

# 7. Test mail detection
source /usr/lib/nftban/core/nftban_mail_v030.sh
nftban_v030_mail_info
```

---

## 🎓 **USAGE EXAMPLES**

### **Example 1: Generate Inventory**

```bash
# Full system inventory
nftban-health --inventory > /tmp/inventory.json

# View summary
jq '.processes | length' /tmp/inventory.json  # Process count
jq '.packages.installed | length' /tmp/inventory.json  # Package count
```

### **Example 2: Create Baseline**

```bash
# Save baseline
sudo nftban-baseline-save \
  --dir /var/lib/nftban/reports \
  --rotate 10

# Baseline saved as:
# /var/lib/nftban/reports/hostname-20251103T190000Z.json
# Symlink: /var/lib/nftban/reports/baseline-latest.json
```

### **Example 3: Compare Against Baseline**

```bash
# Generate diff report
nftban-health --inventory \
  --diff /var/lib/nftban/reports/baseline-latest.json \
  | jq '.summary'

# Output:
# {
#   "processes": {"added": 2, "removed": 0, "changed": 1},
#   "sockets": {"added": 1, "removed": 0, "changed": 0},
#   "packages": {"added": 5, "removed": 0, "changed": 2}
# }
```

### **Example 4: Generate Alert**

```bash
# Alert mode (suspicious activity only)
nftban-health --alert

# Output: JSON with findings
# - suspicious_processes[] (non-standard ports)
# - tampered_packages[] (rpm -Va / dpkg -V results)
```

### **Example 5: Send Email Alert**

```bash
# Using smart mail adapter
source /usr/lib/nftban/core/nftban_mail_v030.sh

# Generate alert
alert_json=$(nftban-health --alert)
echo "$alert_json" > /tmp/alert.json

# Send email
nftban_v030_mail_send_alert \
  "warning" \
  "Suspicious Activity Detected" \
  "See attached report" \
  "/tmp/alert.json"
```

---

## 🔧 **CONFIGURATION**

### **Mail Configuration**

The smart mail adapter integrates with existing `/etc/nftban/conf.d/mail.conf`:

```bash
# v0.30 additions (add to existing config)
NFTBAN_MONITOR_ALERTS="YES"
NFTBAN_MONITOR_ALERT_LEVEL="warning"  # info|warning|error|critical
NFTBAN_MONITOR_ALERT_RECIPIENTS="admin@example.com ops@example.com"
```

---

## 🧪 **TESTING FOR AI TEAM**

### **ChatGPT Testing Tasks:**

1. Run on lab servers:
   ```bash
   ssh root@lab.mywebhost.gr
   cd /home/gituser/github/nftban/NFTBAN_AI_TESTING
   ./tests/test_v030_complete.sh
   ```

2. Report results:
   - ✓ Passed count
   - ✗ Failed tests
   - System info

### **Claude Testing Tasks:**

1. Fix any bugs reported
2. Improve error handling
3. Add missing features
4. Update documentation

---

## 📊 **FEATURES SUMMARY**

| Feature | Status | Notes |
|---------|--------|-------|
| Inventory Collection | ✅ Complete | Processes, packages, firewall |
| Baseline Management | ✅ Complete | Save, compare, rotate |
| Drift Detection | ✅ Complete | Add/remove/change tracking |
| Tamper Detection | ✅ Complete | rpm -Va / dpkg -V |
| Alert Generation | ✅ Complete | Suspicious activity detection |
| Email Integration | ✅ Complete | Smart adapter (4 backends) |
| Cryptographic Signing | ✅ Complete | OpenSSL-based |
| GeoIP Lookups | ✅ Source Ready | Needs Go compilation |
| Polkit Integration | ✅ Complete | Non-root execution |
| Documentation | ✅ Complete | 4 comprehensive docs |
| Tests | ✅ Complete | Automated test suite |

---

## 🎯 **NEXT STEPS**

### **Immediate (You)**
1. Deploy to lab servers
2. Run tests
3. Review results
4. Report any issues

### **Short Term (AI Team)**
1. Fix bugs from testing
2. Add monitoring daemon (nftban-mon)
3. Create systemd timer
4. Update RPM spec

### **Medium Term (v0.30 Release)**
1. Complete all testing
2. Update documentation
3. Package for RPM/DEB
4. Release announcement

---

## 🏆 **SUCCESS CRITERIA**

v0.30 is ready when:
- ✅ All helpers work on 5 distros
- ✅ Health checks complete successfully
- ✅ Mail sends alerts
- ✅ GeoIP binary built
- ✅ Tests pass on all lab servers
- ✅ Documentation complete
- ✅ No critical bugs

---

## 📞 **SUPPORT**

**Questions?** Check:
1. `docs/README.md` - Main documentation
2. `docs/MODULAR_ARCHITECTURE.md` - Design philosophy
3. `docs/INTEGRATION_SUMMARY.md` - Integration details

**Issues?** Test with:
```bash
cd NFTBAN_AI_TESTING/tests
./test_v030_complete.sh
```

---

**Status:** ✅ **READY FOR DEPLOYMENT & TESTING**
**Progress:** 85% Complete
**Remaining:** Timer + Monitor Daemon + Final Testing

