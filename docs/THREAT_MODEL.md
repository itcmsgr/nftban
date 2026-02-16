# NFTBan Threat Model

**Version:** 1.0
**Last Updated:** 2026-02-16
**Authors:** NFTBan Security Team

---

## 1. Overview

NFTBan is an enterprise-grade Linux Intrusion Prevention System (IPS) and firewall manager built on nftables. It provides automated threat detection and response through:

- **Login monitoring** - Detects brute-force attacks against SSH, mail, FTP, and web services
- **Portscan detection** - Identifies network reconnaissance activity
- **DDoS protection** - Mitigates volumetric and application-layer attacks
- **Threat feed integration** - Blocks known malicious IPs from community and commercial feeds
- **Geographic blocking** - Country-based access control via GeoIP

The system follows a **single-writer architecture** where all nftables operations flow through a central daemon (`nftband`), which provides serialization, validation, and audit logging.

---

## 2. Assets

### 2.1 Firewall Rules (nftables)

| Asset | Location | Sensitivity |
|-------|----------|-------------|
| nftables ruleset | Kernel memory | **CRITICAL** - Controls all network access |
| Rule templates | `/var/lib/nftban/*.nft` | HIGH - Define firewall behavior |
| Port configurations | `/etc/nftban/ports.d/` | HIGH - Define allowed services |

**Impact if compromised:** Attacker could allow/block arbitrary traffic, bypass all firewall protections, or cause denial of service.

### 2.2 Configuration Files

| Asset | Location | Sensitivity |
|-------|----------|-------------|
| Main config | `/etc/nftban/nftban.conf` | HIGH - Defines all paths and behaviors |
| Module configs | `/etc/nftban/conf.d/*/` | MEDIUM - Per-module settings |
| Whitelist entries | `/etc/nftban/whitelist.d/` | HIGH - IPs that bypass all blocking |
| Blacklist entries | `/etc/nftban/blacklist.d/` | MEDIUM - Persistent bans |

**Impact if compromised:** Attacker could whitelist malicious IPs, disable protection modules, or alter detection thresholds.

### 2.3 Ban Lists

| Asset | Location | Sensitivity |
|-------|----------|-------------|
| Runtime bans | nftables sets (kernel) | HIGH - Active blocking |
| Persistent offenders | `/etc/nftban/blacklist.d/30-persistent-offenders.conf` | MEDIUM |
| Ban log | `/var/log/nftban/bans.log` | LOW - Audit trail |

**Impact if compromised:** Attacker could unban malicious IPs or ban legitimate users (denial of service).

### 2.4 Log Data

| Asset | Location | Sensitivity |
|-------|----------|-------------|
| Daemon logs | journald + `/var/log/nftban/` | MEDIUM - Contains IPs and usernames |
| Suricata EVE | `/var/log/nftban/suricata/eve-alerts.json` | MEDIUM - Detection events |
| Login monitor logs | `/var/log/nftban/login-monitor.log` | MEDIUM - Authentication failures |

**Impact if compromised:** Information disclosure of attack patterns, targeted IPs, and detection capabilities.

### 2.5 Unix Socket IPC

| Asset | Location | Sensitivity |
|-------|----------|-------------|
| Daemon socket | `/run/nftban/nftband.sock` | **CRITICAL** - All firewall operations |
| Socket permissions | `0660 root:nftban` | N/A |

**Impact if compromised:** Full control over firewall - ban/unban arbitrary IPs, modify rules.

### 2.6 Daemon Process

| Asset | Description | Sensitivity |
|-------|-------------|-------------|
| `nftband` daemon | PID in `/run/nftban/nftband.pid` | **CRITICAL** - Runs as root |
| Go runtime state | In-memory data structures | HIGH - Ban tracking, event bus |
| Netlink connection | Kernel communication channel | **CRITICAL** |

**Impact if compromised:** Complete control over firewall and potential kernel-level access via netlink.

---

## 3. Adversaries

### 3.1 External Attackers (Network)

**Capabilities:**
- Send arbitrary network traffic
- Perform port scans, brute-force attacks, DDoS
- Spoof source IP addresses (limited by ISP BCP38 compliance)

**Motivation:**
- Gain unauthorized access to systems
- Use compromised hosts for botnets/cryptomining
- Denial of service

**Attack vectors:**
- Brute-force SSH/mail/FTP credentials
- Exploit vulnerabilities in exposed services
- Evade detection via slow/distributed attacks

### 3.2 Local Unprivileged Users

**Capabilities:**
- Execute commands as unprivileged user
- Read world-readable files
- Connect to local Unix sockets (if permitted)

**Motivation:**
- Privilege escalation
- Disable firewall to allow external access
- Cover tracks after compromise

**Attack vectors:**
- Attempt to join `nftban` group
- Exploit vulnerabilities in CLI tools
- Race conditions in file handling

### 3.3 Malicious Log Injection

**Capabilities:**
- Generate crafted log entries (via failed logins, HTTP requests, etc.)
- Control portions of log messages (usernames, User-Agent strings)

**Motivation:**
- Cause false-positive bans (denial of service)
- Inject commands if log parsing is vulnerable
- Exhaust disk space

**Attack vectors:**
- Crafted SSH usernames with shell metacharacters
- HTTP requests with malicious headers
- Oversized/malformed log entries

### 3.4 Supply Chain Attackers

**Capabilities:**
- Modify upstream dependencies (Go modules, threat feeds)
- Compromise package repositories

**Motivation:**
- Backdoor firewall software
- Inject malicious IPs into "trusted" feeds

**Attack vectors:**
- Typosquatting on Go modules
- Compromise threat feed providers
- Man-in-the-middle on feed downloads

---

## 4. Trust Boundaries

### 4.1 Network to Host Boundary

```
┌─────────────────────────────────────────────────────────────────────┐
│                         UNTRUSTED NETWORK                           │
│    (Internet, attackers, malicious traffic)                         │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
                    ┌───────────▼───────────┐
                    │   nftables (kernel)    │  ← Trust Boundary
                    │   blacklist/whitelist  │
                    └───────────┬───────────┘
                                │
┌───────────────────────────────▼─────────────────────────────────────┐
│                         TRUSTED HOST                                 │
│    (Local services, users, NFTBan components)                        │
└─────────────────────────────────────────────────────────────────────┘
```

**Controls:**
- nftables rules process packets at kernel level before reaching userspace
- Blacklist checked before port allow rules (fixed in CVE-2024-NFTBAN-001)
- Atomic rule updates prevent bypass windows

### 4.2 User Space to Kernel Boundary

```
┌─────────────────────────────────────────────────────────────────────┐
│                         USER SPACE                                   │
│                                                                      │
│   ┌──────────┐    ┌──────────────┐    ┌─────────────────────────┐   │
│   │ nftban   │───▶│   nftband    │───▶│ google/nftables (netlink)│  │
│   │  CLI     │    │   daemon     │    │      library             │  │
│   └──────────┘    └──────────────┘    └────────────┬────────────┘   │
│                                                     │                │
└─────────────────────────────────────────────────────┼────────────────┘
                                                      │ netlink socket
                                          ┌───────────▼───────────┐
                                          │        KERNEL          │
                                          │   nftables subsystem   │
                                          └───────────────────────┘
```

**Controls:**
- Only `nftband` daemon has `CAP_NET_ADMIN` for nftables operations
- Netlink protocol enforces kernel-side validation
- All nft operations serialized through single daemon

### 4.3 CLI to Daemon Boundary (IPC)

```
┌────────────────────────────────────────────────────────────────┐
│                    CLI/EXTERNAL PROCESSES                       │
│                                                                 │
│   ┌─────────────┐  ┌─────────────────┐  ┌──────────────────┐   │
│   │ nftban CLI  │  │ nftban-health   │  │ nftban-exporter  │   │
│   │ (any user   │  │ (nftban user)   │  │ (nftban user)    │   │
│   │ in nftban   │  └────────┬────────┘  └────────┬─────────┘   │
│   │ group)      │           │                    │              │
│   └──────┬──────┘           │                    │              │
│          │                  │                    │              │
└──────────┼──────────────────┼────────────────────┼──────────────┘
           │                  │                    │
           └──────────────────┼────────────────────┘
                              │
              ┌───────────────▼───────────────┐
              │     Unix Socket (0660)        │  ← Trust Boundary
              │  /run/nftban/nftband.sock     │
              │  + SO_PEERCRED validation     │
              └───────────────┬───────────────┘
                              │
              ┌───────────────▼───────────────┐
              │        nftband daemon         │
              │  (root, validates all ops)    │
              └───────────────────────────────┘
```

**Controls:**
- Socket permissions: `0660 root:nftban`
- `SO_PEERCRED` validates caller UID/GID
- Only root or `nftban` group members can connect
- JSON schema validation on all requests
- Rate limiting: max 100 concurrent connections

### 4.4 External Logs to Parser Boundary

```
┌─────────────────────────────────────────────────────────────────────┐
│                      EXTERNAL LOG SOURCES                           │
│                                                                      │
│   ┌───────────┐  ┌───────────┐  ┌───────────┐  ┌──────────────────┐│
│   │  sshd     │  │  dovecot  │  │  postfix  │  │  suricata EVE    ││
│   └─────┬─────┘  └─────┬─────┘  └─────┬─────┘  └────────┬─────────┘│
└─────────┼──────────────┼──────────────┼─────────────────┼──────────┘
          │              │              │                 │
          └──────────────┼──────────────┘                 │
                         │                                │
          ┌──────────────▼──────────────┐  ┌─────────────▼───────────┐
          │     journalctl -f            │  │   JSON line parser      │
          │   (systemd journal API)      │  │   (jq validation)       │
          └──────────────┬───────────────┘  └─────────────┬───────────┘
                         │                                │
                         └────────────────┬───────────────┘
                                          │  ← Trust Boundary
                         ┌────────────────▼────────────────┐
                         │        Log Parser Module        │
                         │   - Regex-based IP extraction   │
                         │   - net.ParseIP validation      │
                         │   - Whitelist pre-check         │
                         └─────────────────────────────────┘
```

**Controls:**
- IP addresses validated via Go's `net.ParseIP()` before any action
- Usernames are not passed to shell commands
- Regex patterns extract only IP portions, ignoring other log content
- Whitelist checked before banning

---

## 5. Attack Surfaces

### 5.1 Log Parsing (Injection Attacks)

**Surface:** Log monitor parses sshd, mail server, FTP server, and web server logs.

**Code location:** `cli/lib/nftban/core/nftban_login_classic.sh`, `pkg/loginmon/`

**Potential attacks:**
- Inject shell metacharacters in SSH usernames
- Craft log entries to match ban patterns with legitimate IPs
- Cause regex catastrophic backtracking (ReDoS)

**Mitigations in place:**
1. **IP validation:** All IPs parsed via `net.ParseIP()` or validated regex before use
2. **No shell interpolation:** Ban commands use parameterized execution, not string concatenation
3. **Regex design:** Patterns extract IPs first, usernames are informational only
4. **Whitelist protection:** Whitelisted IPs cannot be banned regardless of log content

**Residual risk:** LOW - Parsers extract IPs via strict regex, validate with standard library.

### 5.2 Config File Parsing

**Surface:** Bash config files sourced via `source` command; INI files parsed.

**Code location:** `cli/lib/nftban/core/nftban_config.sh`

**Potential attacks:**
- Inject shell commands in config values (if config files are writable)
- Path traversal in config-specified paths

**Mitigations in place:**
1. **File permissions:** Config files owned by `root:root` with `0644`/`0755`
2. **ProtectSystem=strict:** Daemon cannot modify `/etc/nftban/` except `blacklist.d/` and `rules.d/`
3. **Config validation:** Schema validation for critical settings
4. **No user input in paths:** Paths hardcoded or from trusted config

**Residual risk:** MEDIUM - Config injection possible if root is compromised, but root already has full control.

### 5.3 IPC Socket (Local Privilege Escalation)

**Surface:** Unix socket accepts JSON commands for firewall operations.

**Code location:** `cmd/nftband/main.go` (socket handling), `pkg/ipc/client.go`

**Potential attacks:**
- Join `nftban` group to send malicious commands
- Race condition between credential check and operation
- JSON parsing vulnerabilities
- Command injection via parameters

**Mitigations in place:**
1. **Group membership:** Only `root` and `nftban` group members can connect
2. **SO_PEERCRED:** Peer credentials verified via kernel mechanism (not spoofable)
3. **IP validation:** All IP parameters validated via `net.ParseIP()`
4. **Method whitelist:** Only known methods accepted (unknown rejected)
5. **Rate limiting:** Max 100 concurrent connections with semaphore
6. **Timeout:** 300-second socket timeout prevents resource exhaustion

**Residual risk:** LOW - Multiple layers of validation; main risk is `nftban` group membership policy.

### 5.4 nftables Rule Manipulation

**Surface:** Daemon generates and applies nftables rules via netlink.

**Code location:** `pkg/nftbackend/backend.go`, `pkg/sync/`

**Potential attacks:**
- Bypass blacklist via rule ordering manipulation
- Inject malicious rules via crafted IPs/CIDRs
- Cause nftables syntax errors leading to no protection

**Mitigations in place:**
1. **IP validation:** All IPs/CIDRs validated before rule generation
2. **Netlink API:** Uses typed Go library, not string concatenation
3. **Atomic transactions:** Rules applied atomically via nftables transactions
4. **Fail-secure:** Invalid operations leave existing rules in place
5. **Single writer:** All operations serialized through daemon mutex

**Residual risk:** LOW - Go library handles escaping; validation prevents malformed rules.

### 5.5 Threat Feed Loading

**Surface:** External threat feeds parsed and loaded into nftables sets.

**Code location:** `pkg/feeds/parser.go`, `pkg/feeds/loader.go`

**Potential attacks:**
- Malicious feed provider injects whitelist IPs as blacklist (blocks legitimate services)
- Compromised feed injects attacker IP into whitelist
- Oversized feeds cause memory exhaustion

**Mitigations in place:**
1. **Separate sets:** Feeds go to `blacklist_ipv4/ipv6`, not whitelist
2. **IP validation:** Each entry parsed via `net.ParseIP()`/`net.ParseCIDR()`
3. **Memory limits:** Daemon has GOMEMLIMIT and systemd MemoryMax
4. **Feed review:** Administrators choose which feeds to enable

**Residual risk:** MEDIUM - Malicious feed could cause over-blocking (DoS) but not under-blocking.

---

## 6. Abuse Cases

### AC-1: SSH Brute Force False Positive Attack

**Scenario:** Attacker crafts SSH login attempts with victim's IP in username field.

**Attack:**
1. Attacker connects to target SSH server
2. Uses username: `Failed password for admin from 8.8.8.8 port 22`
3. Login monitor regex incorrectly extracts `8.8.8.8` as attacker IP

**Impact:** Legitimate IP (Google DNS) banned.

**Mitigations:**
- Login monitor extracts IP from message structure, not content
- Regex patterns match specific sshd log formats
- Whitelist includes common infrastructure IPs

**Status:** MITIGATED - Current regex: `Failed\ password\ for\ ([^[:space:]]+)\ from\ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)` extracts IP from correct position.

### AC-2: Local User Firewall Manipulation

**Scenario:** Compromised web application user attempts to modify firewall.

**Attack:**
1. Attacker compromises `www-data` user via web vulnerability
2. Attempts to connect to `/run/nftban/nftband.sock`
3. Sends `ban` command for administrator's IP

**Impact:** Admin locked out of server.

**Mitigations:**
- Socket permissions `0660 root:nftban` block non-group users
- `SO_PEERCRED` validates UID/GID match requirement
- `www-data` not in `nftban` group by default

**Status:** MITIGATED - Requires `nftban` group membership or root.

### AC-3: Feed Provider Compromise

**Scenario:** Threat feed provider is compromised or malicious.

**Attack:**
1. Attacker compromises popular threat feed
2. Injects CIDR `0.0.0.0/0` (all IPv4) into feed
3. NFTBan loads feed and blocks all traffic

**Impact:** Complete denial of service.

**Mitigations:**
- Feeds loaded into blacklist sets, subject to whitelist override
- System IPs auto-whitelisted during install
- Administrator review of enabled feeds
- Memory limits prevent loading absurdly large feeds

**Status:** PARTIALLY MITIGATED - `0.0.0.0/0` would be blocked by memory limits but smaller malicious ranges could cause partial DoS.

**Recommendation:** Add feed entry validation to reject RFC1918 ranges and overly broad CIDRs.

### AC-4: Race Condition in Ban/Unban

**Scenario:** Attacker exploits timing between ban persistence and nftables update.

**Attack:**
1. Attacker is temp-banned
2. Simultaneously requests unban while persistence module writes to file
3. File shows banned but nftables shows unbanned (or vice versa)

**Impact:** Inconsistent state allowing bypass.

**Mitigations:**
- Single daemon with mutex serializes all operations
- Persistence and nftables update in same atomic operation
- State reconciliation on daemon restart

**Status:** MITIGATED - Single-writer architecture prevents race conditions.

### AC-5: Suricata EVE Log Injection

**Scenario:** Attacker crafts traffic to inject false EVE JSON events.

**Attack:**
1. Attacker sends packets that trigger Suricata alert
2. Alert contains attacker-controlled data (e.g., HTTP User-Agent)
3. Malformed JSON or injected fields parsed by NFTBan

**Impact:** False alerts or parser crashes.

**Mitigations:**
- Suricata generates EVE JSON, not raw packet content
- NFTBan uses `jq` for JSON parsing with strict mode
- Only specific fields (`src_ip`, `dest_ip`) extracted
- IP fields validated via `net.ParseIP()`

**Status:** MITIGATED - Attacker cannot inject arbitrary JSON structure.

---

## 7. Assumptions

NFTBan's security model assumes:

### 7.1 System Assumptions

| Assumption | Impact if False |
|------------|-----------------|
| Kernel is not compromised | Attacker could bypass all userspace protections |
| systemd enforces service sandboxing correctly | Security directives ignored |
| nftables subsystem is secure | Rule bypass or kernel exploitation possible |
| Go runtime is secure | Memory corruption, RCE in daemon |

### 7.2 Configuration Assumptions

| Assumption | Impact if False |
|------------|-----------------|
| `/etc/nftban/` is not writable by attackers | Config injection, security bypass |
| `nftban` group membership is restricted | Unauthorized firewall manipulation |
| Root access is secure | Full system compromise |
| Administrators review enabled threat feeds | Malicious feed loading |

### 7.3 Operational Assumptions

| Assumption | Impact if False |
|------------|-----------------|
| Log sources (sshd, etc.) produce valid log formats | Parser failures, missed detections |
| System time is accurate | Ban duration issues, log correlation problems |
| Disk space available for logs | Detection gaps during disk full |
| Network connectivity for feed updates | Stale threat intelligence |

---

## 8. Out of Scope

NFTBan does **NOT** protect against:

### 8.1 Physical Security

- Physical access to server
- Hardware-level attacks (cold boot, DMA)
- Datacenter compromise

### 8.2 Kernel-Level Attacks

- Kernel exploits (after attacker has root)
- Malicious kernel modules
- Hypervisor/container escape

### 8.3 Pre-Authentication Vulnerabilities

- Zero-day exploits in SSH/web servers before NFTBan can detect patterns
- Single-packet exploits (no failed login to detect)
- Credential stuffing with valid credentials

### 8.4 Encrypted Traffic Analysis

- Detection of attacks within TLS/encrypted tunnels
- VPN traffic inspection
- Application-layer attacks in encrypted protocols

### 8.5 Social Engineering

- Phishing attacks against administrators
- Social engineering to add attacker to `nftban` group
- Compromised administrator credentials

### 8.6 Insider Threats

- Malicious root user actions
- Authorized `nftban` group members acting maliciously
- Compromised configuration management systems

### 8.7 Availability Attacks

- DDoS attacks that exceed network capacity
- Attacks that overwhelm before detection triggers
- Distributed slow attacks below thresholds

---

## 9. Mitigations

### 9.1 Authentication and Authorization

| Control | Implementation |
|---------|----------------|
| Socket permissions | `0660 root:nftban` via systemd socket unit |
| Peer credential validation | `SO_PEERCRED` syscall verifies UID/GID |
| Group-based access | Only `nftban` group members can operate |
| No network listeners | Daemon only listens on Unix socket |

### 9.2 Input Validation

| Control | Implementation |
|---------|----------------|
| IP address validation | `net.ParseIP()` / `net.ParseCIDR()` |
| JSON schema validation | Unknown fields rejected |
| Method whitelist | Only known IPC methods accepted |
| Timeout enforcement | 300s socket timeout, 90s request timeout |

### 9.3 Privilege Separation

| Control | Implementation |
|---------|----------------|
| Single root daemon | Only `nftband` runs as root |
| Capability dropping | Only `CAP_NET_ADMIN` and `CAP_DAC_OVERRIDE` |
| Filesystem restrictions | `ProtectSystem=strict`, explicit `ReadWritePaths` |
| No privilege escalation | `NoNewPrivileges=true` |

### 9.4 Defense in Depth

| Control | Implementation |
|---------|----------------|
| Whitelist priority | Whitelisted IPs never banned |
| Atomic transactions | nftables rules applied atomically |
| Fail-secure design | Invalid operations preserve existing rules |
| Crash recovery | systemd auto-restart, rules persist in kernel |

### 9.5 Monitoring and Audit

| Control | Implementation |
|---------|----------------|
| Structured logging | JSON logs to journald |
| Ban audit trail | `/var/log/nftban/bans.log` |
| IPC metrics | Prometheus metrics for request latency, errors |
| Health checks | `nftban-health` validates system state |

### 9.6 Resource Protection

| Control | Implementation |
|---------|----------------|
| Memory limits | GOMEMLIMIT + systemd MemoryMax |
| Connection limits | Max 100 concurrent IPC connections |
| Rate limiting | Semaphore-based connection throttling |
| Watchdog | Dynamic resource adjustment under pressure |

---

## Appendix A: Security-Relevant Files

```
/etc/nftban/
├── nftban.conf              # Main config (root:root 0644)
├── whitelist.d/             # Whitelisted IPs (root:root 0755)
├── blacklist.d/             # Persistent bans (root:nftban 0750)
├── conf.d/                  # Module configs (root:root 0755)
│   ├── portscan/
│   ├── ddos/
│   └── login/
└── ports.d/                 # Port configs (root:root 0755)

/var/lib/nftban/
├── install-receipt.json     # Installation manifest
├── source_index.jsonl       # Element source tracking
└── *.nft                    # Rule templates

/run/nftban/
├── nftband.sock             # IPC socket (root:nftban 0660)
└── nftband.pid              # Daemon PID

/var/log/nftban/
├── bans.log                 # Ban audit log
└── *.log                    # Module logs
```

---

## Appendix B: References

- [SECURITY.md](/SECURITY.md) - Vulnerability reporting and security policy
- [ARCHITECTURE-NFT-POLICY.md](/ARCHITECTURE-NFT-POLICY.md) - Single-writer architecture
- [systemd.exec(5)](https://www.freedesktop.org/software/systemd/man/systemd.exec.html) - Service hardening
- [nftables wiki](https://wiki.nftables.org/) - nftables internals
- [SO_PEERCRED](https://man7.org/linux/man-pages/man7/unix.7.html) - Unix socket credentials

---

## Document History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-02-16 | Initial threat model based on v1.15.x codebase |
