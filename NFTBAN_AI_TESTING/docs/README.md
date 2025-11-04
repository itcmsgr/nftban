# NFTBan v0.30 - Self-Healing Monitoring System

**Status:** 🚧 Development
**Target Release:** November 21, 2025
**Location:** `/home/gituser/github/nftban/NFTBAN_AI_TESTING/`

---

## 📋 Overview

NFTBan v0.30 introduces **self-healing, drift-aware guardrails** through:

1. **Inventory System** - Track processes, sockets, packages
2. **Monitoring Daemon** - Real-time drift detection
3. **Email Alerting** - Notifications without MTA
4. **Auto-Healing** - Automatic issue resolution
5. **Baseline Comparison** - Detect changes over time
6. **Signed Reports** - Cryptographic verification

---

## 🗂️ Directory Structure

```
NFTBAN_AI_TESTING/
├── helpers/              # Inventory collection helpers
│   ├── nftban-procnet    # Process/socket inventory (Python)
│   ├── nftban-pkgs       # Package inventory (Bash, RPM/DEB)
│   ├── nftban-verify     # Package verification (rpm -Va / dpkg -V)
│   └── nftban-firewall   # Firewall status (nftables JSON)
│
├── health/               # Enhanced health checking
│   ├── nftban-health     # Main health command (--inventory, --alert, --diff, --sign)
│   ├── nftban-baseline-save       # Save baselines with rotation
│   └── nftban-verify-signature    # Verify signed envelopes
│
├── mail/                 # Email subsystem
│   └── nftban-mail.sh    # Email library (curl SMTP / msmtp)
│
├── geoip/                # GeoIP Go binary source
│   └── main.go           # GeoIP lookup binary
│
├── tests/                # Test suite
│   ├── test_v030.sh      # Integration tests
│   ├── test_helpers.sh   # Helper unit tests
│   └── test_mail.sh      # Email tests
│
├── config/               # Configuration files
│   ├── monitor.yml       # Monitor daemon config
│   └── health.conf       # Auto-heal config
│
└── docs/                 # Documentation
    ├── README.md         # This file
    ├── INSTALLATION.md   # Installation guide
    ├── TESTING.md        # Testing guide for AI helpers
    └── API.md            # API reference
```

---

## 🚀 Quick Start

### 1. Install Helpers (as root)

```bash
cd /home/gituser/github/nftban/NFTBAN_AI_TESTING

# Install inventory helpers
sudo install -m 0755 helpers/nftban-procnet /usr/libexec/nftban/
sudo install -m 0755 helpers/nftban-pkgs /usr/libexec/nftban/
sudo install -m 0755 helpers/nftban-verify /usr/libexec/nftban/
sudo install -m 0755 helpers/nftban-firewall /usr/libexec/nftban/

# Install health commands
sudo install -m 0755 health/nftban-health /usr/local/lib/nftban/
sudo install -m 0755 health/nftban-baseline-save /usr/local/lib/nftban/
sudo install -m 0755 health/nftban-verify-signature /usr/local/lib/nftban/

# Create symlinks
sudo ln -sf /usr/local/lib/nftban/nftban-health /usr/local/bin/
sudo ln -sf /usr/local/lib/nftban/nftban-baseline-save /usr/local/bin/
sudo ln -sf /usr/local/lib/nftban/nftban-verify-signature /usr/local/bin/

# Install mail library
sudo install -m 0644 mail/nftban-mail.sh /usr/lib/nftban/core/

# Create directories
sudo mkdir -p /var/lib/nftban/reports
sudo mkdir -p /etc/nftban/keys
sudo chown root:nftban-auditors /var/lib/nftban/reports
sudo chmod 0750 /var/lib/nftban/reports
```

### 2. Setup Polkit (for non-root execution)

Create `/etc/polkit-1/rules.d/50-nftban-v030.rules`:

```javascript
polkit.addRule(function (action, subject) {
  if (action.id !== "org.freedesktop.policykit.exec") return;
  var prog = action.lookup("program");
  var ok = [
    "/usr/libexec/nftban/nftban-procnet",
    "/usr/libexec/nftban/nftban-pkgs",
    "/usr/libexec/nftban/nftban-verify",
    "/usr/libexec/nftban/nftban-firewall"
  ];
  if (ok.indexOf(prog) !== -1 && subject.isInGroup("nftban-auditors")) {
    return polkit.Result.YES;
  }
});
```

```bash
# Create nftban-auditors group and add user
sudo groupadd -f nftban-auditors
sudo usermod -aG nftban-auditors $USER
# Log out and back in for group membership
```

### 3. Test Installation

```bash
# Test inventory collection
nftban-health --inventory | jq .

# Test alert generation
nftban-health --alert | jq .

# Save baseline
sudo nftban-baseline-save --dir /var/lib/nftban/reports --rotate 10

# Compare with baseline
nftban-health --inventory --diff /var/lib/nftban/reports/baseline-latest.json | jq '.summary'

# Test signing (generate test key first)
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out /tmp/test.key
nftban-health --alert --sign /tmp/test.key | jq .
nftban-verify-signature /tmp/signed.json
```

---

## 🧪 Testing Guide

### For AI Testing Team (ChatGPT & Claude)

Run the comprehensive test suite:

```bash
cd /home/gituser/github/nftban/NFTBAN_AI_TESTING
./tests/test_v030.sh
```

Expected output:
```
═══════════════════════════════════════════════════════════
  NFTBan v0.30 Integration Tests
═══════════════════════════════════════════════════════════

📦 Phase 1: Core Functionality Tests
✅ Health Check: PASS
✅ Module List: PASS
✅ Stats Command: PASS
...

🎉 ALL TESTS PASSED!
✅ Passed: 42
❌ Failed: 0
```

See `docs/TESTING.md` for detailed testing procedures.

---

## 📧 Email Configuration

### Using curl (No MTA Required)

Set environment variables:

```bash
export MAIL_TRANSPORT=curl
export SMTP_SERVER=smtp.example.com
export SMTP_PORT=587
export SMTP_USER=nftban@example.com
export SMTP_PASS=your_password
export SMTP_REQUIRE_TLS=true
export MAIL_FROM=nftban@example.com
export MAIL_FROM_NAME="NFTBan Monitor"
```

### Using msmtp

Install msmtp:
```bash
# Fedora/RHEL
sudo dnf install msmtp

# Ubuntu/Debian
sudo apt install msmtp
```

Configure `/etc/msmtprc`:
```
defaults
auth on
tls on
logfile /var/log/msmtp.log

account default
host smtp.example.com
port 587
from nftban@example.com
user nftban@example.com
passwordeval "secret-tool lookup smtp example.com user nftban"
```

Set transport:
```bash
export MAIL_TRANSPORT=msmtp
```

---

## 🔐 Security

### Polkit Authorization

Non-root users in the `nftban-auditors` group can run inventory helpers via pkexec.

**Why Polkit?**
- Granular permission control
- Audit logging
- No sudo password prompts
- Exact path matching

### Signing Keys

Generate signing key:
```bash
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
  -out /etc/nftban/keys/signing.key
chmod 0600 /etc/nftban/keys/signing.key
chown root:root /etc/nftban/keys/signing.key
```

Extract public key:
```bash
openssl pkey -in /etc/nftban/keys/signing.key \
  -pubout -out /etc/nftban/keys/signing.pub
```

---

## 📊 Architecture

### Data Flow

```
┌─────────────────────────────────────────────┐
│         nftban-health --inventory           │
├─────────────────────────────────────────────┤
│                                              │
│  pkexec nftban-procnet    → Process List    │
│  pkexec nftban-pkgs       → Package List    │
│  pkexec nftban-verify     → Integrity Check │
│  pkexec nftban-firewall   → Firewall Rules  │
│                                              │
│  ↓ Combine all data                         │
│                                              │
│  JSON Output                                 │
│    ├─ time, host, kernel                    │
│    ├─ processes[] (pid, exe, sha256)        │
│    ├─ sockets[] (proto, port, state)        │
│    ├─ packages[] (name, version, arch)      │
│    └─ firewall (nftables JSON)              │
│                                              │
│  ↓ Optional: --diff BASELINE.json           │
│                                              │
│  Diff Report                                 │
│    ├─ summary (added/removed/changed)       │
│    └─ details (per category)                │
│                                              │
│  ↓ Optional: --sign KEY.pem                 │
│                                              │
│  Signed Envelope                             │
│    ├─ type: nftban.signed+json              │
│    ├─ signature_b64 (SHA-256)               │
│    ├─ key_fingerprint_b64                   │
│    └─ payload (original JSON)               │
└─────────────────────────────────────────────┘
```

---

## 🐛 Known Issues

1. **GeoIP Binary Not Yet Built**
   - Status: Source ready in `geoip/main.go`
   - Action: Need to build with Go 1.21+
   - Impact: `nftban health geoip` shows WARNING

2. **Monitor Daemon Not Implemented**
   - Status: Planned for next phase
   - Files: Need `nftban_monitor.sh` and systemd units

---

## 📝 Todo

- [ ] Build GeoIP Go binary
- [ ] Implement monitor daemon
- [ ] Create systemd timers
- [ ] Add auto-heal logic to health check
- [ ] Write comprehensive tests
- [ ] Update RPM spec with new files

---

## 🤝 For AI Testing Team

### ChatGPT Tasks
1. Run integration tests on lab servers
2. Report any failures with full output
3. Test email functionality
4. Verify Polkit permissions

### Claude Tasks
1. Implement remaining features
2. Fix any bugs reported
3. Create additional tests
4. Update documentation

---

## 📧 Contact

**Project:** NFTBan
**Version:** 0.30.0-dev
**Owner:** Antonios Voulvoulis <contact@nftban.com>
**Homepage:** https://nftban.com

---

**Last Updated:** 2025-11-03
**Status:** Active Development
