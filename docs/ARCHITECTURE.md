# NFTBan Architecture

This document describes the high-level architecture of NFTBan, an enterprise-grade
Linux Intrusion Prevention System (IPS) and firewall manager built on nftables.

---

## 1. System Overview

```
+==============================================================================+
|                            NFTBan System                                      |
+==============================================================================+
|                                                                              |
|  +-----------------+     Unix Socket IPC      +-------------------------+    |
|  |   nftban CLI    | -----------------------> |      nftband Daemon     |    |
|  |  (Bash scripts) |     /run/nftban/         |        (Go binary)      |    |
|  +-----------------+     nftband.sock         +-------------------------+    |
|         |                                               |                    |
|         | Reads                                         | Writes             |
|         v                                               v                    |
|  +-------------+                              +------------------+           |
|  |   Configs   |                              |    nftables      |           |
|  | /etc/nftban |                              |   (kernel)       |           |
|  +-------------+                              +------------------+           |
|                                                                              |
+==============================================================================+

Key Principle: Single Writer Architecture
  - Only nftband daemon writes to nftables (CAP_NET_ADMIN)
  - CLI and all other components communicate via Unix socket IPC
  - Ensures atomic rule updates and prevents race conditions
```

---

## 2. Component Diagram

```
+==============================================================================+
|                              NFTBan Components                                |
+==============================================================================+
|                                                                              |
|  BINARIES (Go)                                                               |
|  +-------------------------------------------------------------------------+ |
|  |                                                                         | |
|  |  +----------------+  +----------------+  +----------------+             | |
|  |  |    nftband     |  |  nftban-core   |  |   nftban-ui    |             | |
|  |  |    (daemon)    |  | (fast CLI ops) |  |  (web portal)  |             | |
|  |  +----------------+  +----------------+  +----------------+             | |
|  |         |                   |                    |                      | |
|  |         | Runs as root      | CAP_NET_ADMIN      | CAP_NET_ADMIN        | |
|  |         | (nftables ops)    | (geoip, feeds)     | (status views)       | |
|  |                                                                         | |
|  |  +----------------+                                                     | |
|  |  | nftban-ui-auth |                                                     | |
|  |  | (auth service) |                                                     | |
|  |  +----------------+                                                     | |
|  |                                                                         | |
|  +-------------------------------------------------------------------------+ |
|                                                                              |
|  CLI (Bash)                                                                  |
|  +-------------------------------------------------------------------------+ |
|  |                                                                         | |
|  |  /usr/sbin/nftban  --->  /usr/lib/nftban/cli/cmd_*.sh                   | |
|  |                                                                         | |
|  |  Commands: ban, unban, status, stats, health, feeds, geoban, portscan,  | |
|  |            ddos, login, firewall, config, update, report, suricata, ... | |
|  |                                                                         | |
|  +-------------------------------------------------------------------------+ |
|                                                                              |
|  SHARED LIBRARIES (Bash)                                                     |
|  +-------------------------------------------------------------------------+ |
|  |  /usr/lib/nftban/lib/         - Core libraries (IPC, schema, metrics)   | |
|  |  /usr/lib/nftban/core/        - Detection modules (login, ddos, scan)   | |
|  |  /usr/lib/nftban/helpers/     - Utility scripts (audit, trace, queue)   | |
|  |  /usr/lib/nftban/exporters/   - Metrics exporters (unified, prometheus) | |
|  |  /usr/lib/nftban/setup/       - Installation helpers                    | |
|  +-------------------------------------------------------------------------+ |
|                                                                              |
|  GO PACKAGES (pkg/)                                                          |
|  +-------------------------------------------------------------------------+ |
|  |  api/        - HTTP API handlers        nftables/   - nft operations    | |
|  |  analytics/  - Event analytics          nftbackend/ - Backend abstraction| |
|  |  auth/       - Authentication           nftbanconf/ - Config loading     | |
|  |  banlog/     - Ban logging              opqueue/    - Operation queue    | |
|  |  blacklist/  - Blacklist management     persistence/- State persistence  | |
|  |  config/     - Configuration parser     ports/      - Port management    | |
|  |  ddos/       - DDoS detection           portscan/   - Port scan detect   | |
|  |  eventbus/   - Inter-module events      safety/     - Safety checks      | |
|  |  exporters/  - Metrics export           state/      - Runtime state      | |
|  |  feeds/      - Threat feed sync         stats/      - Statistics         | |
|  |  geoban/     - Country blocking         suricata/   - Suricata IDS       | |
|  |  geoip/      - GeoIP lookups            sync/       - Cluster sync       | |
|  |  ipc/        - IPC client               watchdog/   - Self-monitoring    | |
|  |  loginmon/   - Login monitoring         whitelist/  - Whitelist mgmt     | |
|  |  metrics/    - Prometheus metrics       util/       - Shared utilities   | |
|  +-------------------------------------------------------------------------+ |
|                                                                              |
+==============================================================================+
```

---

## 3. Data Flow

### 3.1 Ban Request Flow

```
+==============================================================================+
|                          Ban Request Data Flow                                |
+==============================================================================+

  User/Automation                CLI                     Daemon              nftables
       |                          |                         |                    |
       |  nftban ban 1.2.3.4      |                         |                    |
       |------------------------->|                         |                    |
       |                          |                         |                    |
       |                          |  IPC: {"method":"ban",  |                    |
       |                          |        "params":{       |                    |
       |                          |          "ip":"1.2.3.4" |                    |
       |                          |        }}               |                    |
       |                          |------------------------>|                    |
       |                          |                         |                    |
       |                          |                         |  nft add element   |
       |                          |                         |  inet nftban       |
       |                          |                         |  blacklist_v4      |
       |                          |                         |  { 1.2.3.4 }       |
       |                          |                         |------------------->|
       |                          |                         |                    |
       |                          |                         |<--- OK ------------|
       |                          |                         |                    |
       |                          |  IPC: {"success":true}  |                    |
       |                          |<------------------------|                    |
       |                          |                         |                    |
       |  "1.2.3.4 banned"        |                         |                    |
       |<-------------------------|                         |                    |
       |                          |                         |                    |
```

### 3.2 Detection to Ban Flow

```
+==============================================================================+
|                     Automatic Detection and Ban Flow                          |
+==============================================================================+

  Log Source           Detection Module          Event Bus           nftband
       |                      |                      |                   |
       |  Failed SSH login    |                      |                   |
       |  from 5.6.7.8        |                      |                   |
       |--------------------->|                      |                   |
       |                      |                      |                   |
       |                      |  Threshold exceeded  |                   |
       |                      |  (5 failures/5min)   |                   |
       |                      |--------------------->|                   |
       |                      |                      |                   |
       |                      |                      |  BanEvent{        |
       |                      |                      |    IP: 5.6.7.8    |
       |                      |                      |    Reason: login  |
       |                      |                      |    Duration: 1h   |
       |                      |                      |  }                |
       |                      |                      |------------------>|
       |                      |                      |                   |
       |                      |                      |                   | nft add
       |                      |                      |                   | element
       |                      |                      |                   |
       |                      |                      |  Logged to        |
       |                      |                      |  /var/log/nftban/ |
       |                      |                      |<------------------|
       |                      |                      |                   |

Detection Modules:
  - Login Monitor    : Tracks SSH/auth failures from journal/logs
  - Port Scan        : Detects port scanning (classic or Suricata)
  - DDoS             : Detects flood attacks (classic or Suricata)
  - Bot Scan         : Detects automated bot behavior patterns
  - Suricata         : IDS/IPS integration for advanced detection
```

### 3.3 Metrics Collection Flow

```
+==============================================================================+
|                         Metrics Collection Flow                               |
+==============================================================================+

                     +--------------------+
                     |  Unified Exporter  |
                     | (collect-once)     |
                     +--------------------+
                              |
              +---------------+---------------+
              |               |               |
              v               v               v
     +-------------+  +-------------+  +---------------+
     |   Zabbix    |  | Prometheus  |  |  Connectors   |
     |  (default)  |  | (optional)  |  | (ES/Kafka/..) |
     +-------------+  +-------------+  +---------------+

Exporters (cli/lib/nftban/exporters/):
  - nftban_unified_exporter.sh      - Main collector/exporter
  - nftban_prometheus_exporter.sh   - Prometheus textfile format
  - nftban_metrics_collector.sh     - Metrics gathering logic
  - nftban_*_exporter.sh            - Module-specific exporters
```

---

## 4. Trust Boundaries

```
+==============================================================================+
|                            Security Trust Boundaries                          |
+==============================================================================+

 +---------------------------------------------------------------------------+
 |                         KERNEL SPACE (Trusted)                             |
 |                                                                            |
 |   +------------------+                                                     |
 |   |    nftables      |  <-- Firewall rules persist here                    |
 |   |    ruleset       |      Survives daemon restart                        |
 |   +------------------+                                                     |
 |           ^                                                                |
 +-----------|-----------------------------------------------------------------+
             | CAP_NET_ADMIN (only nftband has this)
             |
 +-----------|-----------------------------------------------------------------+
 |           |              USER SPACE - ROOT BOUNDARY                        |
 |           |                                                                |
 |   +-------+--------+                                                       |
 |   |    nftband     |  User: root                                           |
 |   |    daemon      |  Caps: CAP_NET_ADMIN, CAP_DAC_OVERRIDE                |
 |   +----------------+  Socket: /run/nftban/nftband.sock (0660 root:nftban)  |
 |           ^                                                                |
 +-----------|-----------------------------------------------------------------+
             | Unix Socket IPC (SO_PEERCRED validation)
             | Only root or nftban group members
             |
 +-----------|-----------------------------------------------------------------+
 |           |           USER SPACE - NFTBAN GROUP BOUNDARY                   |
 |           |                                                                |
 |   +-------+--------+    +----------------+    +------------------+         |
 |   |   nftban CLI   |    |  nftban-core   |    |  nftban-health   |         |
 |   | (bash scripts) |    |  (Go binary)   |    |  nftban-ui       |         |
 |   +----------------+    +----------------+    +------------------+         |
 |                                                                            |
 |   Capabilities: CAP_NET_ADMIN (ambient)                                    |
 |   User: nftban (system user)                                               |
 |   Group membership required for socket access                              |
 |                                                                            |
 +---------------------------------------------------------------------------+

 +---------------------------------------------------------------------------+
 |                    USER SPACE - UNPRIVILEGED BOUNDARY                      |
 |                                                                            |
 |   +----------------+    +----------------+                                 |
 |   | nftban-auditor |    |  Regular Users |                                 |
 |   |    (group)     |    |                |                                 |
 |   +----------------+    +----------------+                                 |
 |                                                                            |
 |   Read-only access to logs and status only                                 |
 |   Cannot modify firewall rules                                             |
 |                                                                            |
 +---------------------------------------------------------------------------+

Socket Access Control:
  - Path:        /run/nftban/nftband.sock
  - Permissions: 0660 (owner + group read/write)
  - Ownership:   root:nftban
  - Validation:  SO_PEERCRED checks client UID/GID
```

### 4.1 Privilege Model

| Component | User | Capabilities | Purpose |
|-----------|------|--------------|---------|
| `nftband` | root | CAP_NET_ADMIN, CAP_DAC_OVERRIDE | nftables rule management |
| `nftban-health` | nftban | CAP_NET_ADMIN | Health monitoring |
| `nftban-unified-exporter` | nftban | CAP_NET_ADMIN | Metrics collection |
| `nftban-ui` | nftban | CAP_NET_ADMIN | Web interface |
| `nftban CLI` | varies | via IPC | User commands |

---

## 5. Directory Structure

```
+==============================================================================+
|                           Directory Layout                                    |
+==============================================================================+

CONFIGURATION (/etc/nftban/)
+-----------------------------------------------------------------------------+
|  /etc/nftban/                                                                |
|  +-- nftban.conf              # Main configuration file                      |
|  +-- nftban.conf.local        # Local overrides (user customization)         |
|  +-- conf.d/                  # Module configurations                        |
|  |   +-- banner.conf          # CLI banner settings                          |
|  |   +-- connectors.conf      # External connector settings                  |
|  |   +-- mail.conf            # Email notification settings                  |
|  |   +-- stats.conf           # Statistics settings                          |
|  |   +-- trust.conf           # Trust/whitelist settings                     |
|  |   +-- update.conf          # Auto-update settings                         |
|  |   +-- zabbix.conf          # Zabbix monitoring settings                   |
|  |   +-- botscan/             # Bot scan module configs                      |
|  |   +-- ddos/                # DDoS detection configs                       |
|  |   +-- geoban/              # Country blocking configs                     |
|  |   +-- geoip/               # GeoIP database settings                      |
|  |   +-- login/               # Login monitoring configs                     |
|  |   +-- panels/              # Control panel integration (cPanel, etc)      |
|  |   +-- portscan/            # Port scan detection configs                  |
|  |   +-- rbl/                 # RBL (blocklist) settings                     |
|  |   +-- suricata/            # Suricata IDS settings                        |
|  +-- blacklist.d/             # Blacklisted IPs (daemon-writable)            |
|  +-- whitelist.d/             # Whitelisted IPs (admin-managed)              |
|  +-- feeds.d/                 # Threat feed definitions                      |
|  +-- ports.d/                 # Port allow/deny rules                        |
|  +-- patterns.d/              # Detection patterns                           |
|  +-- connectors/              # External connector configs                   |
|  +-- distros/                 # Distribution-specific configs                |
|  +-- suricata/                # Suricata rule files                          |
+-----------------------------------------------------------------------------+

RUNTIME DATA (/var/lib/nftban/)
+-----------------------------------------------------------------------------+
|  /var/lib/nftban/                                                            |
|  +-- state/                   # Persistent state (bans, counters)            |
|  +-- snapshots/               # Firewall snapshots for rollback              |
|  +-- feeds/                   # Downloaded threat feed data                  |
|  +-- geoip/                   # GeoIP database files                         |
|  +-- rulesets/                # Generated .nft rulesets                      |
|  +-- install-receipt.json     # Installation manifest for drift detection    |
+-----------------------------------------------------------------------------+

RUNTIME (/run/nftban/)
+-----------------------------------------------------------------------------+
|  /run/nftban/                                                                |
|  +-- nftband.sock             # IPC Unix socket (0660 root:nftban)           |
|  +-- nftband.pid              # Daemon PID file                              |
|  +-- metrics/                 # Runtime metrics                              |
+-----------------------------------------------------------------------------+

LOGS (/var/log/nftban/)
+-----------------------------------------------------------------------------+
|  /var/log/nftban/                                                            |
|  +-- nftban.log               # Main application log                         |
|  +-- ban.log                  # Ban/unban actions                            |
|  +-- health.log               # Health check results                         |
|  +-- sync.log                 # Cluster sync operations                      |
+-----------------------------------------------------------------------------+

LIBRARIES (/usr/lib/nftban/)
+-----------------------------------------------------------------------------+
|  /usr/lib/nftban/                                                            |
|  +-- bin/                     # Go binaries (nftban-core, nftban-feeds)      |
|  +-- cli/                     # CLI command modules (cmd_*.sh)               |
|  +-- lib/                     # Shared Bash libraries                        |
|  +-- core/                    # Core detection modules                       |
|  +-- exporters/               # Metrics exporters                            |
|  +-- helpers/                 # Utility scripts                              |
|  +-- setup/                   # Installation helpers                         |
|  +-- cron/                    # Cron job scripts                             |
|  +-- data/                    # Static data files                            |
|  +-- health/                  # Health check scripts                         |
|  +-- tests/                   # Test suites                                  |
+-----------------------------------------------------------------------------+

SYSTEMD UNITS (/etc/systemd/system/ or /lib/systemd/system/)
+-----------------------------------------------------------------------------+
|  Core Services:                                                              |
|  +-- nftband.service          # Main daemon                                  |
|  +-- nftband.socket           # Socket activation unit                       |
|  +-- nftban-firewall-init     # Firewall initialization                      |
|                                                                              |
|  Detection Services:                                                         |
|  +-- nftban-login-monitor     # Login failure detection                      |
|  +-- nftban-suricata          # Suricata integration                         |
|                                                                              |
|  Maintenance Timers:                                                         |
|  +-- nftban-health.timer      # Periodic health checks                       |
|  +-- nftban-maintenance.timer # Cleanup and maintenance                      |
|  +-- nftban-core-feeds.timer  # Threat feed updates                          |
|  +-- nftban-core-geoip.timer  # GeoIP database updates                       |
|  +-- nftban-snapshot.timer    # Periodic snapshots                           |
|  +-- nftban-unified-exporter  # Metrics export                               |
|  +-- nftban-watchdog.timer    # Self-monitoring                              |
|                                                                              |
|  Optional Services:                                                          |
|  +-- nftban-ui.service        # Web interface                                |
|  +-- nftban-ui-auth.service   # Authentication service                       |
|  +-- nftban-api.service       # REST API                                     |
+-----------------------------------------------------------------------------+
```

---

## 6. IPC Protocol

The daemon communicates via a JSON-based protocol over Unix socket:

### Request Format
```json
{
  "method": "ban",
  "params": {
    "ip": "1.2.3.4",
    "duration": "1h",
    "reason": "port scan"
  }
}
```

### Response Format
```json
{
  "success": true,
  "data": {
    "ip": "1.2.3.4",
    "banned_at": "2025-02-16T12:00:00Z",
    "expires_at": "2025-02-16T13:00:00Z"
  }
}
```

### Available Methods
| Method | Description |
|--------|-------------|
| `ping` | Health check |
| `ban` | Ban an IP address |
| `unban` | Remove a ban |
| `status` | Get current status |
| `stats` | Get statistics |
| `list` | List banned IPs |
| `flush` | Flush all bans |
| `sync` | Sync state from cluster |

---

## 7. Fail-Safe Design

```
+==============================================================================+
|                          Fail-Safe Architecture                               |
+==============================================================================+

  Scenario                       Behavior
  --------                       --------

  Daemon Crash                   nftables rules persist in kernel
      |                          Firewall remains ACTIVE
      +------>  systemd          Restart=on-failure restarts daemon
                                 No gap in protection

  Config Error                   Daemon refuses to start
      |                          Existing rules remain in place
      +------>  CLI              Warns user of config issue

  Socket Failure                 CLI operations fail gracefully
      |                          Firewall rules unaffected
      +------>  Fallback         Emergency mode available (manual nft)

  Rule Update Fail               nftables transaction rolls back
      |                          Previous ruleset remains active
      +------>  Atomic           All-or-nothing guarantee

Key Guarantees:
  1. Rules persist in kernel - survive daemon restart
  2. Atomic transactions - no partial rule updates
  3. Automatic recovery - systemd restarts failed services
  4. No privilege escalation - NoNewPrivileges=true enforced
```

---

## 8. Module Architecture

### Detection Modules

Each detection module follows a consistent pattern:

```
+==============================================================================+
|                        Detection Module Structure                             |
+==============================================================================+

  +------------------+     +------------------+     +------------------+
  |   Log Source     | --> |  Detection Logic | --> |   Ban Decision   |
  +------------------+     +------------------+     +------------------+
         |                        |                        |
         v                        v                        v
  - systemd journal        - Threshold checks        - Duration rules
  - /var/log/*             - Pattern matching        - Severity levels
  - Suricata EVE           - Rate limiting           - Escalation
  - Application logs       - Anomaly detection       - IPC to daemon

Modules:
  +----------------+----------------------------------------+------------------+
  | Module         | Source                                 | Detection Type   |
  +----------------+----------------------------------------+------------------+
  | login          | journal/auth.log                       | Failed logins    |
  | portscan       | kernel logs / Suricata                 | Port scanning    |
  | ddos           | conntrack / Suricata                   | Flood attacks    |
  | botscan        | web logs                               | Bot behavior     |
  | suricata       | EVE JSON logs                          | IDS alerts       |
  +----------------+----------------------------------------+------------------+
```

### Suricata Integration

```
  +----------------+     +------------------+     +------------------+
  |   Suricata     | --> |  EVE JSON Logs   | --> |   NFTBan Parse   |
  |     IDS        |     | /var/log/suricata|     |   (Go/Bash)      |
  +----------------+     +------------------+     +------------------+
                                                          |
                                                          v
                                                  +------------------+
                                                  |   Ban via IPC    |
                                                  +------------------+

Detection Tiers:
  1. Binary check    : command -v suricata
  2. Service check   : systemctl is-active suricata
  3. EVE freshness   : Log file < 60s old (configurable)
```

---

## 9. Build and Installation

### Repository Structure

```
nftban/
+-- cmd/                    # Go main packages (binaries)
|   +-- nftband/            # Main daemon
|   +-- nftban-core/        # Fast CLI operations (Go)
|   +-- nftban-ui/          # Web portal
|   +-- nftban-ui-auth/     # Auth service
|   +-- nftban-loginmon/    # Login monitor (placeholder)
+-- pkg/                    # Go packages (libraries)
+-- cli/                    # Bash CLI components
|   +-- sbin/               # Main nftban script
|   +-- lib/nftban/         # Install-mirror layout (see README.md)
|   +-- etc/nftban/         # Config templates
+-- etc/nftban/             # Default configs
+-- install/                # Installation resources
|   +-- systemd/            # Unit files
|   +-- polkit/             # Polkit rules
|   +-- bash-completion/    # Shell completion
+-- packaging/              # DEB/RPM packaging
+-- build/                  # Build artifacts
+-- docs/                   # Documentation
```

### Installation Mapping

| Source | Installed To |
|--------|--------------|
| `cmd/nftband/` | `/usr/lib/nftban/bin/nftband` |
| `cmd/nftban-core/` | `/usr/lib/nftban/bin/nftban-core` |
| `cmd/nftban-ui/` | `/usr/lib/nftban/bin/nftban-ui` |
| `cli/sbin/nftban` | `/usr/sbin/nftban` |
| `cli/lib/nftban/` | `/usr/lib/nftban/` |
| `etc/nftban/` | `/etc/nftban/` |
| `install/systemd/` | `/etc/systemd/system/` |

---

## 10. Version Information

- **Current Version**: See `/VERSION` file
- **Config Schema**: Module configs in `/etc/nftban/conf.d/`
- **API Version**: v1 (HTTP API and IPC)

---

## Document History

| Date | Version | Author | Changes |
|------|---------|--------|---------|
| 2025-02-16 | 1.0.0 | Generated | Initial architecture document |
