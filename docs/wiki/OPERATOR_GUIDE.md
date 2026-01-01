# NFTBan CLI Commands Reference

**Complete reference for all NFTBan command-line operations**

> **Auto-generated from `commands.registry.yml`** - Do not edit manually

---

## Quick Navigation

- [Quick Start](#quick-start)
- [Global Options](#global-options)
- [Task Groups](#task-groups)
  - [Setup & Discovery](#setup--discovery)
  - [Immediate Action](#immediate-action)
  - [Active Protection](#active-protection)
  - [Infrastructure](#infrastructure)
  - [Intelligence & Reporting](#intelligence--reporting)
  - [Developer / SysAdmin](#developer--sysadmin)
- [Risk Levels](#risk-levels)

---

## Quick Start

### Most Common Tasks

```bash
# I'm under attack
nftban ban 1.2.3.4
nftban ddos enable
nftban status

# Block an entire country
nftban geoban ban CN

# Check if an IP or port is blocked
nftban check 1.2.3.4
nftban check port 22

# Verify system health and auto-fix
nftban health check
nftban health fix

# Update feeds and synchronize rules
nftban feeds update
nftban sync --dry-run
```

---

## Global Options

These options work across all commands (where applicable):

| Option | Description |
|--------|-------------|
| `--json` | Output machine-readable JSON |
| `--dry-run` | Preview changes without applying (for mutating commands) |
| `--quiet` | Suppress non-essential output |
| `--verbose` | Show detailed diagnostic output |
| `--help`, `-h` | Command-specific help |

**JSON Output Contract:**
```json
{
  "success": true|false,
  "timestamp": "2025-12-31T12:34:56Z",
  "data": { ... }
}
```

---


## 🛠️  Setup & Discovery

**First-run configuration and system diagnostics**

| Command | Description | Risk | JSON | Dry-Run |
|---------|-------------|------|------|---------|
| `health` | System health check and auto-repair diagnostics | ⚡ Core | ✅ | — |
| `menu` | Interactive TUI menu for system management | ⚡ Core | ❌ | — |
| `setup` | Initial system setup and configuration | 🛠️ Setup | ✅ | — |
| `status` | Global system status overview | ⚡ Core | ✅ | — |
| `sync` | Synchronize and apply firewall rules | ⚠️ Advanced | ❌ | ✅ |
| `validate` | Validate firewall structure and configuration | ⚡ Core | ✅ | — |
| `version` | Display NFTBan version information | ⚡ Core | ✅ | — |
| `wizard` | Interactive setup wizard for first-time configuration | 🛠️ Setup | ❌ | — |

### Command Details


#### `nftban health`

**Description:** System health check and auto-repair diagnostics

**Properties:**
- **Risk Level:** core
- **Mutates State:** conditional
- **JSON Support:** true

**Examples:**
```bash
nftban health check
nftban health fix
nftban health summary
nftban health --json
```

**Subcommands:**
- `check`
- `fix`
- `permissions`
- `services`
- `summary`


#### `nftban menu`

**Description:** Interactive TUI menu for system management

**Properties:**
- **Risk Level:** core
- **Mutates State:** false
- **JSON Support:** false

**Examples:**
```bash
nftban menu
```


#### `nftban setup`

**Description:** Initial system setup and configuration

**Properties:**
- **Risk Level:** setup
- **Mutates State:** true
- **JSON Support:** true

**Examples:**
```bash
nftban setup
nftban setup --auto
```

**Subcommands:**
- `install`
- `configure`
- `wizard`


#### `nftban status`

**Description:** Global system status overview

**Properties:**
- **Risk Level:** core
- **Mutates State:** false
- **JSON Support:** true

**Examples:**
```bash
nftban status
nftban status --json
nftban status --quiet
```


#### `nftban sync`

**Description:** Synchronize and apply firewall rules

**Properties:**
- **Risk Level:** advanced
- **Mutates State:** true
- **JSON Support:** false

**Examples:**
```bash
nftban sync
nftban sync --dry-run
```


#### `nftban validate`

**Description:** Validate firewall structure and configuration

**Properties:**
- **Risk Level:** core
- **Mutates State:** false
- **JSON Support:** true

**Examples:**
```bash
nftban validate
nftban validate all
nftban validate firewall
nftban validate --json
```

**Subcommands:**
- `all`
- `firewall`
- `config`
- `permissions`


#### `nftban version`

**Description:** Display NFTBan version information

**Properties:**
- **Risk Level:** core
- **Mutates State:** false
- **JSON Support:** true

**Examples:**
```bash
nftban version
nftban version --json
```


#### `nftban wizard`

**Description:** Interactive setup wizard for first-time configuration

**Properties:**
- **Risk Level:** setup
- **Mutates State:** true
- **JSON Support:** false

**Examples:**
```bash
nftban wizard
```


## ⚡  Immediate Action

**Reactive security - Firefighter mode**

| Command | Description | Risk | JSON | Dry-Run |
|---------|-------------|------|------|---------|
| `ban` | Ban an IP address immediately | ⚡ Core | ✅ | ✅ |
| `check` | Check if IP or port is blocked | ⚡ Core | ✅ | — |
| `list` | List banned/whitelisted IPs | ⚡ Core | ✅ | — |
| `search` | Search for IP across all sets and logs | ⚡ Core | ✅ | — |
| `unban` | Remove IP ban | ⚡ Core | ✅ | ✅ |
| `whitelist` | Manage IP whitelist (never block) | ⚡ Core | ✅ | ✅ |
| `whitelist-system` | Auto-whitelist system infrastructure IPs | ⚠️ Advanced | ✅ | ✅ |

### Command Details


#### `nftban ban`

**Description:** Ban an IP address immediately

**Properties:**
- **Risk Level:** core
- **Mutates State:** true
- **JSON Support:** true

**Examples:**
```bash
nftban ban 1.2.3.4
nftban ban 1.2.3.4 --timeout 3600
nftban ban 1.2.3.4 --reason 'brute force attack'
nftban ban 1.2.3.4 --source manual --json
```


#### `nftban check`

**Description:** Check if IP or port is blocked

**Properties:**
- **Risk Level:** core
- **Mutates State:** false
- **JSON Support:** true

**Examples:**
```bash
nftban check 1.2.3.4
nftban check port 22
nftban check 1.2.3.4 --json
```


#### `nftban list`

**Description:** List banned/whitelisted IPs

**Properties:**
- **Risk Level:** core
- **Mutates State:** false
- **JSON Support:** true

**Examples:**
```bash
nftban list banned
nftban list whitelist
nftban list all
nftban list --json
```


#### `nftban search`

**Description:** Search for IP across all sets and logs

**Properties:**
- **Risk Level:** core
- **Mutates State:** false
- **JSON Support:** true

**Examples:**
```bash
nftban search 1.2.3.4
nftban search 1.2.3.4 --json
```


#### `nftban unban`

**Description:** Remove IP ban

**Properties:**
- **Risk Level:** core
- **Mutates State:** true
- **JSON Support:** true

**Examples:**
```bash
nftban unban 1.2.3.4
nftban unban 1.2.3.4 --json
```


#### `nftban whitelist`

**Description:** Manage IP whitelist (never block)

**Properties:**
- **Risk Level:** core
- **Mutates State:** true
- **JSON Support:** true

**Examples:**
```bash
nftban whitelist add 10.0.0.1
nftban whitelist remove 10.0.0.1
nftban whitelist list
nftban whitelist show --json
```


#### `nftban whitelist-system`

**Description:** Auto-whitelist system infrastructure IPs

**Properties:**
- **Risk Level:** advanced
- **Mutates State:** true
- **JSON Support:** true

**Examples:**
```bash
nftban whitelist-system
nftban whitelist-system --dry-run
nftban whitelist-system --json
```


## 🧱  Active Protection

**Proactive hardening - Builder mode**

| Command | Description | Risk | JSON | Dry-Run |
|---------|-------------|------|------|---------|
| `cloudflare` | Cloudflare IP ranges management | ⚡ Core | ✅ | — |
| `country` | Geographic blocking by country code (alias for geoban) | ⚠️ Advanced | ❌ | ✅ |
| `ddos` | DDoS protection and rate limiting | ⚠️ Advanced | ✅ | ✅ |
| `feeds` | Threat intelligence feeds management | ⚠️ Advanced | ✅ | ✅ |
| `geoban` | Geographic IP blocking and whitelisting | ⚠️ Advanced | ✅ | ✅ |
| `login` | Login abuse monitoring (SSH/su/sudo) | ⚠️ Advanced | ✅ | — |
| `portscan` | Port scan detection and blocking | ⚠️ Advanced | ✅ | ✅ |
| `trust` | Trusted provider IP ranges (CDN, cloud) | ⚠️ Advanced | ❌ | ✅ |

### Command Details


#### `nftban cloudflare`

**Description:** Cloudflare IP ranges management

**Properties:**
- **Risk Level:** core
- **Mutates State:** conditional
- **JSON Support:** true

**Examples:**
```bash
nftban cloudflare status
nftban cloudflare update
nftban cloudflare --json
```


#### `nftban country`

**Description:** Geographic blocking by country code (alias for geoban)

**Properties:**
- **Risk Level:** advanced
- **Mutates State:** conditional
- **JSON Support:** false

**Examples:**
```bash
nftban country list
nftban country enable CN
nftban country disable RU
nftban country mode blacklist
```


#### `nftban ddos`

**Description:** DDoS protection and rate limiting

**Properties:**
- **Risk Level:** advanced
- **Mutates State:** conditional
- **JSON Support:** true

**Examples:**
```bash
nftban ddos status
nftban ddos enable
nftban ddos disable
nftban ddos test
nftban ddos config --json
```


#### `nftban feeds`

**Description:** Threat intelligence feeds management

**Properties:**
- **Risk Level:** advanced
- **Mutates State:** conditional
- **JSON Support:** true

**Examples:**
```bash
nftban feeds list
nftban feeds enable spamhaus
nftban feeds disable firehol
nftban feeds update
nftban feeds status --json
```


#### `nftban geoban`

**Description:** Geographic IP blocking and whitelisting

**Properties:**
- **Risk Level:** advanced
- **Mutates State:** conditional
- **JSON Support:** true

**Examples:**
```bash
nftban geoban status
nftban geoban ban CN
nftban geoban unban RU
nftban geoban whitelist US
nftban geoban list --json
```


#### `nftban login`

**Description:** Login abuse monitoring (SSH/su/sudo)

**Properties:**
- **Risk Level:** advanced
- **Mutates State:** conditional
- **JSON Support:** true

**Examples:**
```bash
nftban login status
nftban login enable ssh
nftban login disable ssh
nftban login stats
nftban login logs 50
```


#### `nftban portscan`

**Description:** Port scan detection and blocking

**Properties:**
- **Risk Level:** advanced
- **Mutates State:** conditional
- **JSON Support:** true

**Examples:**
```bash
nftban portscan status
nftban portscan enable
nftban portscan disable
nftban portscan history
nftban portscan test --json
```


#### `nftban trust`

**Description:** Trusted provider IP ranges (CDN, cloud)

**Properties:**
- **Risk Level:** advanced
- **Mutates State:** conditional
- **JSON Support:** false

**Examples:**
```bash
nftban trust list
nftban trust enable CLOUDFLARE
nftban trust disable AWS
nftban trust update
nftban trust status
```


## ⚙️  Infrastructure

**Low-level firewall and policy management**

| Command | Description | Risk | JSON | Dry-Run |
|---------|-------------|------|------|---------|
| `config` | Configuration file management | ⚠️ Advanced | ✅ | — |
| `firewall` | Firewall initialization and control | ⚠️ Advanced | ✅ | — |
| `nftables` | nftables service management | ⚠️ Advanced | ✅ | — |
| `panel` | Hosting panel firewall integration (port management) | 🛠️ Setup | ❌ | — |
| `permissions` | File and directory permissions audit and fix | ⚠️ Advanced | ✅ | ✅ |
| `port` | Port allow/block management | ⚠️ Advanced | ✅ | ✅ |
| `profile` | Security profile management (basic/standard/advanced) | ⚠️ Advanced | ❌ | — |

### Command Details


#### `nftban config`

**Description:** Configuration file management

**Properties:**
- **Risk Level:** advanced
- **Mutates State:** conditional
- **JSON Support:** true

**Examples:**
```bash
nftban config show
nftban config edit
nftban config validate
nftban config reload
nftban config get log_level
nftban config set log_level debug
```


#### `nftban firewall`

**Description:** Firewall initialization and control

**Properties:**
- **Risk Level:** advanced
- **Mutates State:** true
- **JSON Support:** true

**Examples:**
```bash
nftban firewall status
nftban firewall init
nftban firewall reload
nftban firewall reset
```


#### `nftban nftables`

**Description:** nftables service management

**Properties:**
- **Risk Level:** advanced
- **Mutates State:** conditional
- **JSON Support:** true

**Examples:**
```bash
nftban nftables status
nftban nftables reload
nftban nftables restart
nftban nftables backup
nftban nftables restore
```


#### `nftban panel`

**Description:** Hosting panel firewall integration (port management)

**Properties:**
- **Risk Level:** setup
- **Mutates State:** conditional
- **JSON Support:** false

**Examples:**
```bash
nftban panel directadmin enable
nftban panel cpanel enable
nftban panel cwp enable
nftban panel cyberpanel enable
nftban panel interworx enable
nftban panel vesta enable
nftban panel directadmin status
```

**Subcommands:**
- `cpanel`
- `cwp`
- `cyberpanel`
- `directadmin`
- `interworx`
- `vesta`


#### `nftban permissions`

**Description:** File and directory permissions audit and fix

**Properties:**
- **Risk Level:** advanced
- **Mutates State:** conditional
- **JSON Support:** true

**Examples:**
```bash
nftban permissions audit
nftban permissions fix
nftban permissions status --json
```


#### `nftban port`

**Description:** Port allow/block management

**Properties:**
- **Risk Level:** advanced
- **Mutates State:** conditional
- **JSON Support:** true

**Examples:**
```bash
nftban port list
nftban port add 8080
nftban port remove 8080
nftban port check 443
nftban port status --json
```


#### `nftban profile`

**Description:** Security profile management (basic/standard/advanced)

**Properties:**
- **Risk Level:** advanced
- **Mutates State:** conditional
- **JSON Support:** false

**Examples:**
```bash
nftban profile list
nftban profile apply basic
nftban profile apply standard
nftban profile apply advanced
nftban profile status
```


## 📊  Intelligence & Reporting

**Visibility and observability**

| Command | Description | Risk | JSON | Dry-Run |
|---------|-------------|------|------|---------|
| `geoip` | GeoIP database and lookup utilities | ⚡ Core | ✅ | — |
| `gui` | Web GUI management | 🛠️ Setup | ❌ | — |
| `mail` | Email notification configuration and testing | 🛠️ Setup | ✅ | — |
| `metrics` | Prometheus/VictoriaMetrics exporter management | 🛠️ Setup | ❌ | — |
| `report` | Generate security reports | ⚡ Core | ✅ | — |
| `services` | Systemd services status overview | ⚡ Core | ✅ | — |
| `stats` | Traffic and ban statistics | ⚡ Core | ✅ | — |
| `suricata` | Suricata IDS integration (intrusion detection sensor) | ⚠️ Advanced | ❌ | — |
| `watchdog` | System resource monitoring and alerting | ⚡ Core | ✅ | — |

### Command Details


#### `nftban geoip`

**Description:** GeoIP database and lookup utilities

**Properties:**
- **Risk Level:** core
- **Mutates State:** conditional
- **JSON Support:** true

**Examples:**
```bash
nftban geoip status
nftban geoip lookup 1.2.3.4
nftban geoip update
nftban geoip config --json
```


#### `nftban gui`

**Description:** Web GUI management

**Properties:**
- **Risk Level:** setup
- **Mutates State:** conditional
- **JSON Support:** false

**Examples:**
```bash
nftban gui status
nftban gui enable
nftban gui disable
```


#### `nftban mail`

**Description:** Email notification configuration and testing

**Properties:**
- **Risk Level:** setup
- **Mutates State:** conditional
- **JSON Support:** true

**Examples:**
```bash
nftban mail status
nftban mail port-status
nftban mail test
nftban mail config
```


#### `nftban metrics`

**Description:** Prometheus/VictoriaMetrics exporter management

**Properties:**
- **Risk Level:** setup
- **Mutates State:** conditional
- **JSON Support:** false

**Examples:**
```bash
nftban metrics status
nftban metrics enable
nftban metrics enable --backend prometheus
nftban metrics enable --backend victoria
nftban metrics disable
```


#### `nftban report`

**Description:** Generate security reports

**Properties:**
- **Risk Level:** core
- **Mutates State:** false
- **JSON Support:** true

**Examples:**
```bash
nftban report generate
nftban report schedule weekly
nftban report email admin@example.com
nftban report --json
```


#### `nftban services`

**Description:** Systemd services status overview

**Properties:**
- **Risk Level:** core
- **Mutates State:** false
- **JSON Support:** true

**Examples:**
```bash
nftban services status
nftban services list
nftban services detailed
nftban services summary --json
```


#### `nftban stats`

**Description:** Traffic and ban statistics

**Properties:**
- **Risk Level:** core
- **Mutates State:** false
- **JSON Support:** true

**Examples:**
```bash
nftban stats top
nftban stats ip 1.2.3.4
nftban stats recent
nftban stats monitor
nftban stats export --json
```


#### `nftban suricata`

**Description:** Suricata IDS integration (intrusion detection sensor)

**Properties:**
- **Risk Level:** advanced
- **Mutates State:** conditional
- **JSON Support:** false

**Examples:**
```bash
nftban suricata status
nftban suricata install
nftban suricata enable
nftban suricata disable
nftban suricata alerts
nftban suricata rules update
```


#### `nftban watchdog`

**Description:** System resource monitoring and alerting

**Properties:**
- **Risk Level:** core
- **Mutates State:** false
- **JSON Support:** true

**Examples:**
```bash
nftban watchdog status
nftban watchdog check
nftban watchdog report
nftban watchdog history
nftban watchdog --json
```


## 🧪  Developer / SysAdmin

**Advanced debugging and testing**

| Command | Description | Risk | JSON | Dry-Run |
|---------|-------------|------|------|---------|
| `debug` | Debug mode and verbose logging control | ⚠️ Advanced | ❌ | — |
| `emulate` | Simulate firewall rule evaluation (test packets) | ⚠️ Advanced | ✅ | — |
| `fhs` | Filesystem Hierarchy Standard compliance check | ⚡ Core | ✅ | — |
| `module` | Module inspection and diagnostics | ⚠️ Advanced | ✅ | — |
| `smoke` | Smoke tests for system validation | ⚡ Core | ❌ | — |
| `system` | System-level operations and diagnostics | ⚠️ Advanced | ❌ | — |
| `test` | Test harness for components | ⚠️ Advanced | ✅ | — |
| `timers` | Systemd timer management | ⚠️ Advanced | ❌ | — |

### Command Details


#### `nftban debug`

**Description:** Debug mode and verbose logging control

**Properties:**
- **Risk Level:** advanced
- **Mutates State:** conditional
- **JSON Support:** false

**Examples:**
```bash
nftban debug enable
nftban debug disable
nftban debug trace
```


#### `nftban emulate`

**Description:** Simulate firewall rule evaluation (test packets)

**Properties:**
- **Risk Level:** advanced
- **Mutates State:** false
- **JSON Support:** true

**Examples:**
```bash
nftban emulate 1.2.3.4
nftban emulate 1.2.3.4 --proto tcp --port 22
nftban emulate 1.2.3.4 --direction in --json
```


#### `nftban fhs`

**Description:** Filesystem Hierarchy Standard compliance check

**Properties:**
- **Risk Level:** core
- **Mutates State:** false
- **JSON Support:** true

**Examples:**
```bash
nftban fhs check
nftban fhs status --json
```


#### `nftban module`

**Description:** Module inspection and diagnostics

**Properties:**
- **Risk Level:** advanced
- **Mutates State:** false
- **JSON Support:** true

**Examples:**
```bash
nftban module list
nftban module status
nftban module --json
```


#### `nftban smoke`

**Description:** Smoke tests for system validation

**Properties:**
- **Risk Level:** core
- **Mutates State:** false
- **JSON Support:** false

**Examples:**
```bash
nftban smoke run
nftban smoke all
nftban smoke --verbose
```


#### `nftban system`

**Description:** System-level operations and diagnostics

**Properties:**
- **Risk Level:** advanced
- **Mutates State:** conditional
- **JSON Support:** false

**Examples:**
```bash
nftban system status
nftban system enable
nftban system disable
nftban system install
nftban system uninstall
```


#### `nftban test`

**Description:** Test harness for components

**Properties:**
- **Risk Level:** advanced
- **Mutates State:** false
- **JSON Support:** true

**Examples:**
```bash
nftban test run
nftban test all
nftban test --verbose --json
```


#### `nftban timers`

**Description:** Systemd timer management

**Properties:**
- **Risk Level:** advanced
- **Mutates State:** conditional
- **JSON Support:** false

**Examples:**
```bash
nftban timers status
nftban timers enable nftban-health.timer
nftban timers disable nftban-queue.timer
```


---

## Risk Levels

| Icon | Level | Description |
|------|-------|-------------|
| ⚡ | **Core** | Essential, safe operations - recommended for all users |
| 🛠️ | **Setup** | One-time configuration - typically run during installation |
| ⚠️ | **Advanced** | Use with caution - may significantly affect system state |

---

## Common Workflows

### Initial Setup → Production

```bash
# 1. Install and verify
nftban health check
nftban validate all

# 2. Enable protection modules
nftban login enable ssh
nftban feeds enable
nftban portscan enable

# 3. Apply security profile
nftban profile apply standard

# 4. Sync and verify
nftban sync --dry-run
nftban sync
nftban status
```

### Incident Response

```bash
# 1. Check current state
nftban health check

# 2. Search for suspicious IP
nftban search 1.2.3.4

# 3. Ban if confirmed malicious
nftban ban 1.2.3.4 --reason "incident-response"

# 4. Generate incident report
nftban report generate
```

### Panel Integration

```bash
# 1. Detect hosting panel
nftban panel detect

# 2. Auto-whitelist panel infrastructure
nftban whitelist-system --dry-run
nftban whitelist-system

# 3. Open required ports
nftban port add 2087  # cPanel/WHM
nftban port add 2222  # DirectAdmin
```

---

## Troubleshooting

### Top 10 Common Errors

1. **nftables service not running**
   ```bash
   Fix: nftban health fix
   ```

2. **Permissions denied**
   ```bash
   Fix: nftban permissions fix
   ```

3. **GeoIP database missing**
   ```bash
   Fix: nftban geoip update
   ```

4. **Firewall validation failed**
   ```bash
   Fix: nftban validate firewall
   Fix: nftban firewall reload
   ```

5. **Service not enabled**
   ```bash
   Fix: nftban services status
   Fix: sudo systemctl enable --now nftban-*.service
   ```

---

## Documentation Links

- **[Installation Guide](https://github.com/itcmsgr/nftban#quick-install)**
- **[Security Architecture](https://github.com/itcmsgr/nftban/wiki/Security-Architecture)**
- **[Suricata IDS Integration](https://github.com/itcmsgr/nftban/wiki/Suricata-Integration)**
- **[Security Operations Guide](https://github.com/itcmsgr/nftban/wiki/Security-Operations-Guide)**

---

**Auto-generated:** $(date -u '+%Y-%m-%d %H:%M:%S UTC')
**Source:** `commands.registry.yml`
**Profile:** Operator (full access)

