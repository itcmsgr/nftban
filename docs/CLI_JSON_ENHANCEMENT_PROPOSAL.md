# NFTBan CLI Enhancement Proposal: Universal --json Flag

## Problem Statement

Currently, the Web GUI acts as a wrapper around CLI commands, parsing text output meant for humans. This creates:
- Duplicate parsing logic in the GUI
- Fragile text parsing that breaks with formatting changes
- Inconsistent output between CLI and GUI
- Double maintenance burden

## Solution: Add --json Flag to ALL Commands

Every nftban command should support `--json` flag to return machine-readable JSON output.

### Current State

Only `nftban status --json` is implemented:
```bash
$ nftban status --json
{
  "version": "0.32.25",
  "firewall": {
    "nftables_active": true,
    "banned_ips": 0
  }
}
```

### Proposed Enhancement

Add `--json` to ALL commands:

#### 1. Search Command
```bash
# Current (text)
$ nftban search 1.1.1.1 --no-interactive
Searching for: 1.1.1.1
✓ Found in: inet nftban_main user_blacklist
  Added: 2025-11-11 08:00:00
  Reason: Manual ban

# Proposed (JSON)
$ nftban search 1.1.1.1 --json
{
  "ip": "1.1.1.1",
  "found": true,
  "locations": [
    {
      "table": "inet nftban_main",
      "set": "user_blacklist",
      "added": "2025-11-11T08:00:00Z",
      "reason": "Manual ban"
    }
  ]
}
```

#### 2. Ban/Unban Commands
```bash
# Ban with JSON response
$ nftban ban 1.1.1.1 --timeout 24h --reason "Test" --json
{
  "success": true,
  "ip": "1.1.1.1",
  "timeout": "24h",
  "reason": "Test",
  "added_to": ["inet nftban_main user_blacklist"],
  "timestamp": "2025-11-11T08:30:00Z"
}

# Unban with JSON response
$ nftban unban 1.1.1.1 --json
{
  "success": true,
  "ip": "1.1.1.1",
  "removed_from": ["inet nftban_main user_blacklist"],
  "timestamp": "2025-11-11T08:30:15Z"
}
```

#### 3. Stats Commands
```bash
# Stats dashboard
$ nftban stats dashboard --json
{
  "total_banned": 1234,
  "temp_bans": 56,
  "permanent_bans": 1178,
  "sets": {
    "user_blacklist": 100,
    "feeds": 1078,
    "temp_ban": 56
  }
}

# Top countries
$ nftban stats top countries 50 --json
{
  "countries": [
    {"code": "CN", "name": "China", "count": 456},
    {"code": "RU", "name": "Russia", "count": 234},
    {"code": "US", "name": "United States", "count": 123}
  ]
}
```

#### 4. Feeds Commands
```bash
$ nftban feeds status --json
{
  "feeds": [
    {
      "name": "SPAMHAUS_DROP",
      "enabled": true,
      "items": 1234,
      "last_sync": "2025-11-11T06:00:00Z",
      "status": "ok"
    }
  ]
}

$ nftban feeds update --json
{
  "success": true,
  "updated": ["SPAMHAUS_DROP", "ABUSE_CH"],
  "added": 45,
  "removed": 12,
  "timestamp": "2025-11-11T08:30:00Z"
}
```

#### 5. Firewall Commands
```bash
$ nftban firewall reload --json
{
  "success": true,
  "tables_reloaded": ["inet nftban_main"],
  "rules_loaded": 1532,
  "duration_ms": 245,
  "timestamp": "2025-11-11T08:30:00Z"
}
```

## Implementation Guidelines

### 1. Consistent JSON Structure

All JSON responses should follow this pattern:
```json
{
  "success": true|false,
  "timestamp": "ISO8601",
  "data": { ... },
  "error": "Error message if success=false"
}
```

### 2. Backward Compatibility

- Default output remains human-readable text
- `--json` flag is optional
- No breaking changes to existing CLI usage

### 3. Detection in Scripts

Commands can detect if output is being piped:
```bash
if [[ -t 1 ]]; then
    # Terminal: use colors and formatting
else
    # Pipe: plain text or check for --json
fi
```

### 4. Web GUI Integration

With `--json` implemented, the GUI becomes trivial:

**Before (text parsing):**
```go
output, _ := exec("nftban", "stats", "dashboard")
// Parse text output with regex...
```

**After (JSON parsing):**
```go
output, _ := exec("nftban", "stats", "dashboard", "--json")
json.Unmarshal(output, &stats)
```

## Benefits

1. **Single Source of Truth**: CLI is the only implementation
2. **No Duplicate Logic**: GUI just calls CLI with --json
3. **Consistent Behavior**: CLI and GUI identical
4. **Easy Testing**: Test CLI = test GUI
5. **API Ready**: JSON output suitable for any automation
6. **Future Proof**: Easy to add new fields without breaking GUI

## Migration Path

### Phase 1: Core Commands (Priority)
- ✅ `status --json` (already implemented)
- 🔄 `search --json`
- 🔄 `ban --json`
- 🔄 `unban --json`

### Phase 2: Stats & Monitoring
- 🔄 `stats dashboard --json`
- 🔄 `stats top --json`
- 🔄 `feeds status --json`

### Phase 3: Actions
- 🔄 `feeds update --json`
- 🔄 `firewall reload --json`

### Phase 4: Everything Else
- All remaining commands

## Example Implementation

```bash
#!/usr/bin/env bash

# Parse flags
JSON_OUTPUT=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json) JSON_OUTPUT=true; shift ;;
        *) break ;;
    esac
done

# Execute command
result=$(do_ban_operation "$@")

# Output format
if [[ "$JSON_OUTPUT" == "true" ]]; then
    jq -n \
        --arg success "true" \
        --arg ip "$IP" \
        --arg timestamp "$(date -Iseconds)" \
        '{success: $success, ip: $ip, timestamp: $timestamp}'
else
    echo "✓ Banned $IP successfully"
fi
```

## Conclusion

Adding universal `--json` support to the CLI eliminates the need for:
- GUI-specific logic
- Text parsing
- Duplicate implementations
- Complex error handling

The GUI becomes a simple REST API wrapper around `nftban <command> --json`.

**This is the correct architecture: GUI = CLI + JSON**
