# Wave 3: NFT Fragment Design

**Purpose**: Migrate chain/rule creation from direct `nft add` commands to rendered .nft fragments applied via IPC.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        FRAGMENT WORKFLOW                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   bash script                                                   │
│       │                                                         │
│       ├─1─▶ Render fragment from template                       │
│       │     /etc/nftban/rules.d/portscan-classic.nft       │
│       │                                                         │
│       ├─2─▶ IPC: apply_ruleset(path)                           │
│       │                                                         │
│       │         nftband daemon                                  │
│       │              │                                          │
│       │              └─3─▶ nft -f /etc/nftban/rules.d/...  │
│       │                                                         │
│   ✓ Transaction applied atomically                              │
└─────────────────────────────────────────────────────────────────┘
```

---

## Fragment Directory Structure

```
/etc/nftban/
└── rules.d/
    ├── 10-portscan-classic.nft   # Portscan detection chain + rules
    ├── 20-ddos-classic.nft       # DDoS protection chain + rules
    ├── 30-port-config.nft        # Port-based access rules
    └── 99-cleanup.nft            # Removal fragments (flush chains)
```

**Note**: Fragments are stored in `/etc/nftban/rules.d/` (not `/var/lib/nftban/`)
for SELinux compatibility. The `nft` binary (iptables_exec_t context) can read
files with `etc_t` context but not `var_lib_t` context.

---

## Fragment Format

### Example: portscan-classic.nft

```nft
#!/usr/sbin/nft -f
# NFTBan Portscan Classic Detection
# Generated: 2026-01-01T12:00:00Z
# Managed by nftband - DO NOT EDIT MANUALLY

# --- IPv4 ---
add chain ip nftban portscan_detection
flush chain ip nftban portscan_detection

add rule ip nftban portscan_detection \
    tcp flags syn / syn,ack,fin,rst \
    ct state new \
    limit rate 10/second burst 50 packets \
    log prefix "NFTBAN_PORTSCAN:SYN " level info

add rule ip nftban portscan_detection \
    udp dport != { 53, 123, 443 } \
    ct state new \
    limit rate 10/second burst 50 packets \
    log prefix "NFTBAN_PORTSCAN:UDP " level info

# Hook into input chain (idempotent via handle check)
add rule ip nftban input jump portscan_detection

# --- IPv6 ---
add chain ip6 nftban portscan_detection
flush chain ip6 nftban portscan_detection

add rule ip6 nftban portscan_detection \
    tcp flags syn / syn,ack,fin,rst \
    ct state new \
    limit rate 10/second burst 50 packets \
    log prefix "NFTBAN_PORTSCAN:SYN " level info

add rule ip6 nftban portscan_detection \
    udp dport != { 53, 123, 443 } \
    ct state new \
    limit rate 10/second burst 50 packets \
    log prefix "NFTBAN_PORTSCAN:UDP " level info

add rule ip6 nftban input jump portscan_detection
```

### Key Design Principles

1. **Idempotent**: Can be applied multiple times without side effects
   - `add chain` is idempotent in nftables (no error if exists)
   - `flush chain` ensures clean slate before adding rules

2. **Atomic**: Entire fragment applied in single transaction
   - nftables' `-f` flag applies atomically
   - All-or-nothing semantics

3. **Self-contained**: No shell variables or external state
   - All values baked in at render time
   - Pure nftables syntax

4. **Ordered**: Filename prefix determines load order
   - `10-*` before `20-*` before `30-*`
   - Lower numbers = earlier in chain

---

## Bash Fragment Renderer

### Location: `cli/lib/nftban/lib/nft_fragment.sh`

```bash
# Render portscan classic fragment
# Writes to: /etc/nftban/rules.d/10-portscan-classic.nft
nftban_fragment_render_portscan_classic() {
    local table_ipv4="${PORTSCAN_NFT_TABLE_IPV4:-ip nftban}"
    local table_ipv6="${PORTSCAN_NFT_TABLE_IPV6:-ip6 nftban}"
    local chain="${PORTSCAN_NFT_CHAIN:-portscan_detection}"
    local log_prefix="${PORTSCAN_CLASSIC_LOG_PREFIX:-NFTBAN_PORTSCAN:}"
    local log_rate="${PORTSCAN_CLASSIC_LOG_RATE:-10/second}"
    local log_burst="${PORTSCAN_CLASSIC_LOG_BURST:-50}"

    local fragment_path="/etc/nftban/rules.d/10-portscan-classic.nft"

    cat > "${fragment_path}.tmp" <<EOF
#!/usr/sbin/nft -f
# NFTBan Portscan Classic Detection
# Generated: $(date -Iseconds)
# Managed by nftband - DO NOT EDIT MANUALLY

# --- IPv4 ---
add chain ${table_ipv4} ${chain}
flush chain ${table_ipv4} ${chain}

add rule ${table_ipv4} ${chain} \\
    tcp flags syn / syn,ack,fin,rst \\
    ct state new \\
    limit rate ${log_rate} burst ${log_burst} packets \\
    log prefix "${log_prefix}SYN " level info

add rule ${table_ipv4} ${chain} \\
    udp dport != { 53, 123, 443 } \\
    ct state new \\
    limit rate ${log_rate} burst ${log_burst} packets \\
    log prefix "${log_prefix}UDP " level info

add rule ${table_ipv4} input jump ${chain}

# --- IPv6 ---
add chain ${table_ipv6} ${chain}
flush chain ${table_ipv6} ${chain}

add rule ${table_ipv6} ${chain} \\
    tcp flags syn / syn,ack,fin,rst \\
    ct state new \\
    limit rate ${log_rate} burst ${log_burst} packets \\
    log prefix "${log_prefix}SYN " level info

add rule ${table_ipv6} ${chain} \\
    udp dport != { 53, 123, 443 } \\
    ct state new \\
    limit rate ${log_rate} burst ${log_burst} packets \\
    log prefix "${log_prefix}UDP " level info

add rule ${table_ipv6} input jump ${chain}
EOF

    mv "${fragment_path}.tmp" "${fragment_path}"
    echo "${fragment_path}"
}

# Apply fragment via IPC
nftban_fragment_apply() {
    local fragment_path="$1"

    nftban_ipc_call "apply_ruleset" "{\"path\": \"${fragment_path}\"}"
}
```

---

## IPC Protocol Extension

### apply_ruleset

Already defined in ARCHITECTURE-NFT-POLICY.md:

```json
{
  "method": "apply_ruleset",
  "params": {
    "path": "/etc/nftban/rules.d/10-portscan-classic.nft"
  }
}
```

**Daemon implementation**:
```go
func (d *Daemon) handleApplyRuleset(params map[string]any) SocketResponse {
    path, _ := params["path"].(string)

    // Validate path is in allowed directory
    if !strings.HasPrefix(path, "/etc/nftban/rules.d/") {
        return SocketResponse{Success: false, Error: "path not in allowed directory"}
    }

    // Apply via nft -f
    cmd := exec.Command("nft", "-f", path)
    output, err := cmd.CombinedOutput()
    if err != nil {
        return SocketResponse{Success: false, Error: string(output)}
    }

    return SocketResponse{Success: true, Data: map[string]any{"applied": path}}
}
```

---

## Migration Steps

### 1. Create fragment renderer library

```bash
# cli/lib/nftban/lib/nft_fragment.sh
# Functions to render .nft fragments from configuration
```

### 2. Add apply_ruleset handler to daemon

Already exists in design, just needs implementation.

### 3. Migrate portscan_classic.sh

**Before**:
```bash
nftban_portscan_classic_create_chain() {
    nft add chain ${table_ipv4} ${chain} 2>/dev/null || true
    # ...
}

nftban_portscan_classic_add_rules() {
    nft flush chain ${table_ipv4} ${chain} 2>/dev/null || true
    nft add rule ${table_ipv4} ${chain} ...
    # ...
}
```

**After**:
```bash
nftban_portscan_classic_enable() {
    # ... load config, init state ...

    # Render fragment
    local fragment_path
    fragment_path=$(nftban_fragment_render_portscan_classic)

    # Apply via IPC
    nftban_fragment_apply "$fragment_path"
}
```

### 4. Handle disable/remove

For disabling, render a "cleanup" fragment:

```nft
#!/usr/sbin/nft -f
# NFTBan Portscan Classic - CLEANUP
flush chain ip nftban portscan_detection
flush chain ip6 nftban portscan_detection
# Note: don't delete chain as other rules may reference it
```

---

## Jump Rule Deduplication

**Problem**: `add rule ... jump` creates duplicates on each apply.

**Solution**: Use rule handles or idempotent patterns:

```nft
# Option 1: Flush input and re-add jump (if we own the chain)
# Not ideal - loses other rules

# Option 2: Check before adding (bash side)
# nft list chain ip nftban input | grep -q "jump portscan_detection" || \
#   nft add rule ip nftban input jump portscan_detection

# Option 3: Use position/index (complex)

# Option 4: Separate jump management
# Keep jump rules in a dedicated fragment applied once at init
```

**Recommended**: Option 2 - check before adding. This keeps the fragment simple and handles the jump separately in bash.

---

## CI Enforcement Update

The `check-nft-writes.sh` script should allow:
- Fragment files in `/etc/nftban/rules.d/*.nft`
- These are data files, not scripts

The nft WRITE check only applies to bash scripts (`.sh`) and Go files (`.go`).

---

## Testing

```bash
# 1. Render fragment
nftban_fragment_render_portscan_classic

# 2. Verify fragment syntax
nft -c -f /etc/nftban/rules.d/10-portscan-classic.nft

# 3. Apply via IPC
echo '{"method":"apply_ruleset","params":{"path":"/etc/nftban/rules.d/10-portscan-classic.nft"}}' | \
  socat - /run/nftban/nftband.sock

# 4. Verify rules applied
nft list chain ip nftban portscan_detection
```

---

*Document version: 1.0*
*Created: 2026-01-01*
