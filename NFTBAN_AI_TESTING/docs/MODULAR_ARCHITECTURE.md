# NFTBan v0.30 - UNIQUE MODULAR ARCHITECTURE

**Date:** 2025-11-03
**Philosophy:** Smart, Adaptive, Expandable, Zero-Dependency Core

---

## 🧠 **THE UNIQUE APPROACH**

### **Problem with Traditional Systems:**
```
❌ Traditional: "Install our dependencies or it won't work"
❌ Rigid:       "Use our mail system only"
❌ Replace:     "Remove your existing tools"
```

### **NFTBan v0.30 Approach:**
```
✅ Adaptive:    "We'll use what you have"
✅ Fallback:    "If not, we'll provide alternatives"
✅ Integrate:   "We enhance, never replace"
✅ Expand:      "Easy to add new modules"
```

---

## 🏗️ **LAYERED ARCHITECTURE**

```
┌─────────────────────────────────────────────────────────────┐
│                    Layer 4: User Interface                  │
│              (CLI commands, timers, alerts)                 │
├─────────────────────────────────────────────────────────────┤
│                   Layer 3: Smart Adapters                   │
│         (Auto-detect best method, provide fallbacks)        │
│                                                              │
│  Mail Adapter:                                              │
│  Priority 1: Use v0.10 mail module (if exists)             │
│  Priority 2: Use system MTA (sendmail/postfix)             │
│  Priority 3: Use msmtp                                      │
│  Priority 4: Use curl SMTP                                  │
│  Priority 5: Disable gracefully                             │
│                                                              │
│  GeoIP Adapter:                                             │
│  Priority 1: Use Go binary (fast)                          │
│  Priority 2: Use Python geoip2 (if installed)              │
│  Priority 3: Use curl to ipinfo.io API                     │
│  Priority 4: Skip GeoIP features                           │
├─────────────────────────────────────────────────────────────┤
│                   Layer 2: Core Modules                     │
│         (Health, Inventory, Baseline, Verification)         │
│                                                              │
│  Each module:                                               │
│  - Standalone operation                                     │
│  - JSON output (machine-readable)                           │
│  - Human-readable fallback                                  │
│  - No hard dependencies                                     │
├─────────────────────────────────────────────────────────────┤
│                   Layer 1: Collectors                       │
│              (Process, Package, Firewall data)              │
│                                                              │
│  Design:                                                    │
│  - Python/Bash choice (Python for speed, Bash for compat)  │
│  - Read-only operations (safe)                              │
│  - Polkit-aware (privilege separation)                      │
│  - Cross-distro (RPM, DEB, others)                          │
└─────────────────────────────────────────────────────────────┘
```

---

## 🔌 **MODULAR EXPANSION PATTERN**

### **Adding a New Feature:**

```bash
# 1. Create collector (Layer 1)
/usr/libexec/nftban/nftban-FEATURE
# - Outputs JSON
# - No dependencies
# - Works standalone

# 2. Add to health checks (Layer 2)
# nftban-health calls the collector
# Validates output
# Adds to report

# 3. Create smart adapter (Layer 3) - IF NEEDED
# Detects best method
# Provides fallbacks
# Fails gracefully

# 4. Expose via CLI (Layer 4)
nftban health FEATURE
nftban FEATURE status
```

---

## 🎯 **EXAMPLE: Mail System**

### **Traditional Approach:**
```bash
# Install our dependencies
apt install postfix mailutils
systemctl start postfix

# Configure our way
cat > /etc/postfix/main.cf << EOF
...
EOF

# Use our functions
nftban_send_mail() {
    echo "$body" | mail -s "$subject" "$recipient"
}
```

**Problems:**
- ❌ Requires postfix
- ❌ Overwrites config
- ❌ Breaks if postfix not running
- ❌ No alternatives

---

### **NFTBan v0.30 Approach:**
```bash
# Smart detection
nftban_v030_mail_send() {
    case "$(_detect_mail_system)" in
        v010)      # Use existing NFTBan v0.10 module
            nftban_mail_send "$@"
            ;;
        postfix)   # Use system postfix
            sendmail -t < "$eml"
            ;;
        msmtp)     # Use msmtp
            msmtp -- "$recipient" < "$eml"
            ;;
        curl)      # Fallback to curl SMTP
            curl --upload-file "$eml" smtp://...
            ;;
        none)      # Disable mail features
            echo "Mail disabled (no MTA)" >&2
            return 0  # Don't break other features!
            ;;
    esac
}
```

**Benefits:**
- ✅ Works with ANY mail system
- ✅ No configuration changes
- ✅ Automatic fallback
- ✅ Never breaks
- ✅ Easy to extend

---

## 🚀 **EXPANSION EXAMPLES**

### **Example 1: Add Docker Monitoring**

```bash
# Step 1: Create collector
cat > /usr/libexec/nftban/nftban-docker <<'EOF'
#!/usr/bin/env python3
import json, subprocess

result = subprocess.run(['docker', 'ps', '-a', '--format', '{{json .}}'],
                       capture_output=True, text=True)
containers = [json.loads(line) for line in result.stdout.splitlines()]
print(json.dumps({"time": "...", "containers": containers}))
EOF

# Step 2: Add to health
# nftban-health --inventory calls nftban-docker
# Output included in JSON

# Step 3: Smart adapter (if needed)
# Detect: docker, podman, containerd
# Fallback: skip container checks

# Step 4: CLI
# nftban health containers
# nftban containers list
```

**Result:** Docker monitoring without breaking systems without Docker!

---

### **Example 2: Add Database Monitoring**

```bash
# Layer 1: Collector
/usr/libexec/nftban/nftban-dbcheck
# - Detects: MySQL, PostgreSQL, MongoDB
# - Checks: connections, slow queries, locks
# - Output: JSON

# Layer 3: Smart Adapter
nftban_v030_db_check() {
    for db in mysql postgres mongo; do
        if detect_$db; then
            check_$db
            return 0
        fi
    done
    echo "No database detected" >&2
    return 0  # Don't fail!
}

# Layer 4: CLI
nftban health db
nftban db status
```

---

## 📊 **COMPARISON**

| Feature | Traditional | NFTBan v0.30 |
|---------|------------|--------------|
| Dependencies | Required | Optional |
| Failure Mode | Breaks entire system | Disables feature only |
| Integration | Replaces existing | Uses existing |
| Expansion | Requires rewrite | Add new module |
| Cross-platform | Single distro | All distros |
| User choice | One way only | Multiple options |

---

## 🎓 **PRINCIPLES**

### 1. **Progressive Enhancement**
```
Basic → Good → Better → Best
  ↓       ↓      ↓        ↓
Works   Works  Works   Works
```

### 2. **Graceful Degradation**
```
Best → Good → Basic → Disabled
 ↓       ↓      ↓        ↓
Try → Fallback → Skip → Continue
```

### 3. **Zero Breaking Changes**
```
v0.10 works → Install v0.30 → v0.10 STILL works
                                       ↓
                               v0.30 adds features
```

### 4. **Adapter Pattern**
```
User Code → Adapter → [Best Available Method]
              ↓
         Auto-detect
              ↓
      Multiple backends
              ↓
     Always works!
```

---

## 🔧 **TECHNICAL IMPLEMENTATION**

### **Detection Pattern:**
```bash
_detect_backend() {
    # Priority 1: Existing system
    if [[ -f /usr/lib/nftban/core/FEATURE.sh ]]; then
        echo "existing"
        return 0
    fi

    # Priority 2: Native tool
    if command -v TOOL >/dev/null 2>&1; then
        echo "native"
        return 0
    fi

    # Priority 3: Alternative
    if command -v ALT_TOOL >/dev/null 2>&1; then
        echo "alternative"
        return 0
    fi

    # Priority 4: Fallback
    if [[ minimal_requirements_met ]]; then
        echo "fallback"
        return 0
    fi

    # Priority 5: Disabled
    echo "disabled"
    return 1
}
```

### **Adapter Pattern:**
```bash
feature_adapter() {
    local backend=$(_detect_backend)

    case "$backend" in
        existing)     existing_implementation "$@" ;;
        native)       native_implementation "$@" ;;
        alternative)  alternative_implementation "$@" ;;
        fallback)     minimal_implementation "$@" ;;
        disabled)     echo "Feature disabled" >&2; return 0 ;;
    esac
}
```

### **Module Template:**
```bash
#!/usr/bin/env bash
# Standalone module template

set -Eeuo pipefail

# Can work alone
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Standalone mode
    main "$@"
    exit $?
fi

# Can be sourced
export MODULE_LOADED=1

# Provides functions
module_function() {
    # Implementation
}
```

---

## 🌟 **UNIQUE ADVANTAGES**

### 1. **Installation Flexibility**
```
Minimal Install:
- Core scripts only
- No dependencies
- Basic features work

Full Install:
- All modules
- All backends
- Maximum features
```

### 2. **Deployment Flexibility**
```
Bare Metal:   Full features
Container:    Lightweight mode
Minimal VPS:  Essential only
Air-gapped:   No external deps
```

### 3. **User Flexibility**
```
Existing mail? We use it
No mail?       We adapt
Want curl?     We support
Need msmtp?    We handle
```

---

## 🎯 **EXPANSION ROADMAP**

### **v0.30 (Current)**
- ✅ Inventory system
- ✅ Health monitoring
- ✅ Smart mail adapter
- ⏳ GeoIP (Go + fallbacks)

### **v0.40 (Future)**
- 🔄 Container monitoring (Docker/Podman)
- 🔄 Database monitoring (MySQL/Postgres)
- 🔄 Web server monitoring (Apache/Nginx)
- 🔄 Log aggregation

### **v0.50+**
- 🔄 Cloud provider integration (AWS/Azure/GCP)
- 🔄 Kubernetes monitoring
- 🔄 Application performance
- 🔄 Custom module API

**Each addition follows the modular pattern!**

---

## 📝 **SUMMARY**

NFTBan v0.30 introduces a **UNIQUE architecture** that:

1. ✅ **Never breaks existing systems**
2. ✅ **Works on ANY Linux distro**
3. ✅ **Adapts to available tools**
4. ✅ **Easy to expand**
5. ✅ **Fails gracefully**
6. ✅ **User has control**

**This approach doesn't exist in other monitoring/security tools!**

---

**Philosophy:** "Meet users where they are, adapt to their environment, provide value immediately, expand gracefully."

