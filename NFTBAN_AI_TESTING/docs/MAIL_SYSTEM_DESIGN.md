# NFTBan Mail System Design - v0.30

**Purpose:** Send alert emails WITHOUT requiring a local MTA (mail server)
**Status:** 📝 Design Review
**Created:** 2025-11-03

---

## 🎯 Goals

1. **No MTA Required** - Works on minimal systems without postfix/sendmail
2. **Two Transport Options** - curl (zero deps) or msmtp (cleaner)
3. **MIME Support** - Text + HTML + Attachments
4. **Security** - TLS/STARTTLS, no password in code
5. **NFTBan Integration** - Library format, source-able

---

## 🏗️ Architecture

### Component Overview

```
┌─────────────────────────────────────────────────────────┐
│                NFTBan Mail Library                      │
│             /usr/lib/nftban/core/nftban_mail.sh         │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  Public API:                                            │
│  └─ mail_send(to, subject, body, html, attachments[])  │
│                                                          │
│  Private Functions:                                     │
│  ├─ _build_mime()     → Build RFC5322 message          │
│  ├─ _send_curl()      → Transport via curl              │
│  └─ _send_msmtp()     → Transport via msmtp             │
│                                                          │
│  Configuration (via environment):                       │
│  ├─ MAIL_TRANSPORT=curl|msmtp                          │
│  ├─ SMTP_SERVER, SMTP_PORT                             │
│  ├─ SMTP_USER, SMTP_PASS (optional)                    │
│  ├─ SMTP_REQUIRE_TLS=true|false                        │
│  └─ MAIL_FROM, MAIL_FROM_NAME                          │
└─────────────────────────────────────────────────────────┘
```

---

## 🔧 How It Works

### 1. Building MIME Messages

The library creates proper RFC5322-compliant email messages:

```
Date: Mon, 03 Nov 2025 18:30:00 +0000
Message-ID: <1699034400.nftban@lab1.example.com>
From: NFTBan Monitor <nftban@example.com>
To: undisclosed-recipients:;
Subject: NFTBan Alert - Suspicious Port Detected
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="b123456"

--b123456
Content-Type: multipart/alternative; boundary="a789012"

--a789012
Content-Type: text/plain; charset=UTF-8

Alert: Suspicious process listening on port 4444
...

--a789012
Content-Type: text/html; charset=UTF-8

<html><body><h1>Alert</h1>...</body></html>

--a789012--

--b123456
Content-Type: application/octet-stream; name="report.json"
Content-Transfer-Encoding: base64
Content-Disposition: attachment; filename="report.json"

eyJhbGVydCI6ICJzdXNwaWNpb3VzX3BvcnQiLCAicG9ydCI6IDQ0NDR9Cg==

--b123456--
```

**Key Features:**
- Text + HTML alternative (clients pick best)
- Base64-encoded attachments
- Privacy: `To: undisclosed-recipients:;` (actual recipients in SMTP RCPT)

---

### 2. Transport Options

#### Option A: curl (Default - Zero Dependencies)

**Pros:**
- ✅ No installation needed (curl is everywhere)
- ✅ Works on minimal systems
- ✅ Direct SMTP protocol

**Cons:**
- ⚠️ More verbose configuration
- ⚠️ No built-in retry logic

**How it works:**
```bash
curl --silent --show-error \
  --url smtp://mail.example.com:587 \
  --mail-from nftban@example.com \
  --mail-rcpt user1@example.com \
  --mail-rcpt user2@example.com \
  --mail-rcpt-allowfails \
  --ssl-reqd \
  --user "nftban@example.com:password" \
  --upload-file /tmp/message.eml
```

**Security:**
- `--ssl-reqd`: Forces STARTTLS (required for TLS)
- `--mail-rcpt-allowfails`: One bad address doesn't kill all
- Password from environment (never in code)

---

#### Option B: msmtp (Cleaner - Requires Package)

**Pros:**
- ✅ Cleaner interface (sendmail-compatible)
- ✅ Built-in retries
- ✅ Better logging
- ✅ OAuth2 support (Gmail/O365)

**Cons:**
- ⚠️ Requires installation: `dnf install msmtp` or `apt install msmtp`

**Configuration** (`/etc/msmtprc`):
```
defaults
auth on
tls on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile /var/log/msmtp.log

account default
host smtp.example.com
port 587
from nftban@example.com
user nftban@example.com
passwordeval "secret-tool lookup smtp example.com"
```

**How it works:**
```bash
msmtp --read-envelope-from \
  --from=nftban@example.com \
  -- user1@example.com user2@example.com \
  < /tmp/message.eml
```

---

## 🔐 Security Model

### 1. No Passwords in Code

**Bad:**
```bash
SMTP_PASS="hardcoded123"  # ❌ NEVER DO THIS
```

**Good:**
```bash
# Option 1: Environment variable (from secure source)
export SMTP_PASS=$(secret-tool lookup smtp example.com)

# Option 2: Config file with restricted permissions
# /etc/nftban/mail.conf (mode 0600, root:root)
SMTP_PASS="..."

# Option 3: msmtp with passwordeval
passwordeval "secret-tool lookup smtp example.com"
```

### 2. TLS Requirements

```bash
# For smtp:// (port 587 - STARTTLS)
SMTP_SCHEME=smtp
SMTP_PORT=587
SMTP_REQUIRE_TLS=true    # Forces STARTTLS

# For smtps:// (port 465 - Implicit TLS)
SMTP_SCHEME=smtps
SMTP_PORT=465
# TLS is implicit, no need to require
```

### 3. Recipient Privacy

```
# Header shows:
To: undisclosed-recipients:;

# Actual recipients in SMTP envelope (not visible to recipients):
RCPT TO:<user1@example.com>
RCPT TO:<user2@example.com>
RCPT TO:<user3@example.com>
```

This prevents recipient list leaking.

---

## 📝 Usage Examples

### Example 1: Simple Text Alert

```bash
#!/usr/bin/env bash
source /usr/lib/nftban/core/nftban_mail.sh

# Configuration
export MAIL_TRANSPORT=curl
export SMTP_SERVER=smtp.example.com
export SMTP_PORT=587
export SMTP_USER=nftban@example.com
export SMTP_PASS=$(cat /etc/nftban/mail_password)
export MAIL_FROM=nftban@example.com
export MAIL_FROM_NAME="NFTBan Monitor"

# Send alert
to_list="admin@example.com ops@example.com"
subject="NFTBan Alert: Suspicious Port 4444"
body="Warning: Unknown process listening on port 4444
Process: /tmp/suspicious_binary (PID 12345)
Action: Quarantined to nftban_quarantine chain

-- NFTBan v0.30"

attachments=()  # No attachments

mail_send "$to_list" "$subject" "$body" "" attachments[@]
```

### Example 2: Alert with JSON Report Attachment

```bash
#!/usr/bin/env bash
source /usr/lib/nftban/core/nftban_mail.sh

# Generate report
nftban-health --alert > /tmp/alert_$(date +%s).json

# Send with attachment
to_list="soc@example.com"
subject="NFTBan Alert - $(date +'%Y-%m-%d %H:%M')"
body="See attached JSON report for details."

attachments=(/tmp/alert_*.json)

mail_send "$to_list" "$subject" "$body" "" attachments[@]
```

### Example 3: HTML + Text + Attachment

```bash
#!/usr/bin/env bash
source /usr/lib/nftban/core/nftban_mail.sh

# Create HTML version
cat > /tmp/alert.html <<'HTML'
<!DOCTYPE html>
<html>
<head><style>
  body { font-family: Arial, sans-serif; }
  .alert { background: #fff3cd; padding: 20px; border-left: 4px solid #ff9800; }
  .critical { background: #f8d7da; border-left-color: #dc3545; }
</style></head>
<body>
  <div class="alert critical">
    <h1>🚨 Critical Alert</h1>
    <p><strong>Suspicious process detected:</strong></p>
    <ul>
      <li>Port: 4444</li>
      <li>Process: /tmp/suspicious_binary</li>
      <li>PID: 12345</li>
    </ul>
    <p><strong>Action taken:</strong> Quarantined</p>
  </div>
</body>
</html>
HTML

text_body="Critical Alert: Suspicious process on port 4444
Process: /tmp/suspicious_binary (PID 12345)
Action: Quarantined"

attachments=(/var/lib/nftban/reports/latest.json)

mail_send "admin@example.com" "🚨 Critical Alert" \
  "$text_body" "/tmp/alert.html" attachments[@]
```

---

## 🔄 Integration with NFTBan

### 1. Health Check Integration

```bash
# In nftban_health.sh
source /usr/lib/nftban/core/nftban_mail.sh

nftban_health_send_alert() {
    local alert_level="$1"  # warning|error|critical
    local alert_data="$2"   # JSON or text

    # Load mail config
    [[ -f /etc/nftban/conf.d/mail.conf ]] && source /etc/nftban/conf.d/mail.conf

    # Check if email enabled
    [[ "${MAIL_ALERTS_ENABLED:-false}" == "true" ]] || return 0

    # Generate report
    local report_file="/tmp/nftban_alert_$(date +%s).json"
    echo "$alert_data" > "$report_file"

    local to_list="${MAIL_ALERT_RECIPIENTS}"
    local subject="[NFTBan] ${alert_level^^} Alert - $(hostname)"
    local body="Alert generated at $(date -Iseconds)

Level: ${alert_level}
Host: $(hostname -f)

See attached JSON for details."

    local attachments=("$report_file")

    mail_send "$to_list" "$subject" "$body" "" attachments[@]
}
```

### 2. Monitor Daemon Integration

```bash
# In nftban_monitor.sh (future)
source /usr/lib/nftban/core/nftban_mail.sh

nftban_monitor_alert() {
    local event_type="$1"   # listener_added|package_tampered|drift_detected
    local event_data="$2"

    # Format email
    local subject="[NFTBan Monitor] ${event_type}"
    local body=$(cat <<EOF
NFTBan Monitor detected a security event:

Type: ${event_type}
Time: $(date -Iseconds)
Host: $(hostname -f)

Details:
${event_data}

-- NFTBan v0.30 Monitor
EOF
)

    mail_send "${MONITOR_ALERT_EMAIL}" "$subject" "$body" "" attachments[@]
}
```

---

## ⚙️ Configuration

### /etc/nftban/conf.d/mail.conf

```bash
# NFTBan Mail Configuration
# SPDX-License-Identifier: MPL-2.0

# Transport: curl or msmtp
MAIL_TRANSPORT="curl"

# SMTP Settings (for curl transport)
SMTP_SCHEME="smtp"              # smtp or smtps
SMTP_SERVER="smtp.example.com"
SMTP_PORT="587"
SMTP_USER="nftban@example.com"
SMTP_PASS_FILE="/etc/nftban/keys/mail_password"  # File containing password
SMTP_REQUIRE_TLS="true"

# Email Addressing
MAIL_FROM="nftban@example.com"
MAIL_FROM_NAME="NFTBan Security Monitor"

# Alert Settings
MAIL_ALERTS_ENABLED="true"
MAIL_ALERT_RECIPIENTS="admin@example.com ops@example.com"
MAIL_ALERT_MIN_LEVEL="warning"  # info|warning|error|critical

# Rate Limiting
MAIL_RATE_LIMIT_COUNT="10"       # Max emails per hour
MAIL_RATE_LIMIT_WINDOW="3600"    # Window in seconds
```

**Load in scripts:**
```bash
[[ -f /etc/nftban/conf.d/mail.conf ]] && source /etc/nftban/conf.d/mail.conf

# Override password from file
if [[ -n "${SMTP_PASS_FILE:-}" && -r "$SMTP_PASS_FILE" ]]; then
    SMTP_PASS=$(cat "$SMTP_PASS_FILE")
fi
```

---

## 🧪 Testing

### Self-Test Mode

```bash
# Test with environment variables
MAIL_SELFTEST=1 \
MAIL_RCPT=your@email.com \
MAIL_TRANSPORT=curl \
SMTP_SERVER=smtp.gmail.com \
SMTP_PORT=587 \
SMTP_USER=test@gmail.com \
SMTP_PASS="app_password" \
bash /usr/lib/nftban/core/nftban_mail.sh
```

Expected output:
```
✓ Test email sent to your@email.com
```

### Manual Test

```bash
source /usr/lib/nftban/core/nftban_mail.sh

attachments=()
mail_send "test@example.com" "Test Subject" "Test body text" "" attachments[@]
```

---

## ❓ Questions for Review

### 1. Transport Choice
**Q:** Should curl be default, or msmtp?
**Recommendation:** curl (zero deps), but document msmtp as "recommended for production"

### 2. Password Storage
**Q:** Where should SMTP password be stored?
**Options:**
- A) `/etc/nftban/keys/mail_password` (file, mode 0600)
- B) Environment variable from secret manager
- C) msmtp with `passwordeval`

**Recommendation:** Support all three, document in order B > C > A

### 3. HTML Support
**Q:** Always include HTML part, or make it optional?
**Recommendation:** Optional (pass html_path parameter), most alerts are text-only

### 4. Rate Limiting
**Q:** Should mail library do rate limiting, or leave to caller?
**Recommendation:** Library provides simple tracking, caller enforces policy

### 5. Retry Logic
**Q:** Should curl transport retry on failure?
**Recommendation:** Yes, 3 retries with exponential backoff (1s, 2s, 4s)

---

## ✅ Next Steps

1. **Review this design** - Confirm approach is correct
2. **Answer questions** - Clarify any uncertainties
3. **Finalize implementation** - Add retry logic, rate limiting
4. **Create tests** - Self-test mode + integration tests
5. **Document** - Man page, examples, troubleshooting

---

## 📊 Design Decisions Summary

| Feature | Decision | Rationale |
|---------|----------|-----------|
| Transport | curl (default), msmtp (option) | Zero deps, but msmtp is cleaner |
| MIME | RFC5322 compliant | Proper standard support |
| TLS | STARTTLS required by default | Security first |
| Passwords | File + env + passwordeval | Flexibility, never in code |
| Recipients | Hidden (undisclosed-recipients) | Privacy |
| HTML | Optional parameter | Most alerts don't need it |
| Attachments | Array parameter | Support multiple files |
| Retry | 3 attempts with backoff | Reliability |

---

**Status:** 📝 Awaiting Review & Approval
**Next:** Finalize implementation after review

