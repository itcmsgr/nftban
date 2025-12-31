# JSON Implementation Plan - v1.0.16

## Commands Needing --json Support

Based on `commands.registry.yml`, these 11 commands need `--json` added:

### Priority 1: Service Control (Critical for Panels)

#### 1. **gui** (`cmd_gui.sh`)
```bash
# Add to nftban_cmd_gui()
local json_mode=false
for arg in "$@"; do
    [[ "$arg" == "--json" ]] && json_mode=true
done

# In status subcommand:
if [[ "$json_mode" == "true" ]]; then
    source "${NFTBAN_LIB_DIR}/helpers/json_output.sh"
    local status=$(systemctl is-active nftban-ui.service || echo "inactive")
    local enabled=$(systemctl is-enabled nftban-ui.service || echo "disabled")
    json_success "{\"service\":\"nftban-ui\",\"status\":\"$status\",\"enabled\":\"$enabled\"}"
else
    # existing text output
fi
```

#### 2. **metrics** (`cmd_metrics.sh`)
```bash
# Add JSON mode detection and output for:
# - status subcommand (show backend, enabled state)
# - enable subcommand (confirm action)
# - disable subcommand (confirm action)
json_success "{\"backend\":\"prometheus\",\"enabled\":true,\"port\":9090}"
```

#### 3. **timers** (`cmd_timers.sh`)
```bash
# Add JSON for:
# - status (list all timers + state)
# - enable/disable (confirm action)
timers_json=$(systemctl list-timers nftban*.timer --no-pager --output=json)
json_success "$timers_json"
```

### Priority 2: Configuration Commands

#### 4. **profile** (`cmd_profile.sh`)
```bash
# Add JSON for:
# - list (show available profiles)
# - status (show current profile)
# - apply (confirm profile change)
json_success "{\"current\":\"standard\",\"available\":[\"basic\",\"standard\",\"advanced\"]}"
```

#### 5. **system** (`cmd_system.sh`)
```bash
# Add JSON for system-level status
json_success "{\"nftban_enabled\":true,\"version\":\"1.0.16\"}"
```

### Priority 3: Interactive/Setup Commands

#### 6. **wizard** (`cmd_wizard.sh`)
**ACTION:** Mark as `output_modes: [text]` only - wizards don't need JSON

#### 7. **menu** (`cmd_menu.sh`)
**ACTION:** Mark as `output_modes: [text]` only - TUI doesn't need JSON

### Priority 4: Advanced Commands

#### 8. **sync** (`cmd_sync.sh`)
```bash
# Already supports --dry-run
# Add JSON to show sync result:
json_success "{\"action\":\"sync\",\"dry_run\":$dry_run,\"rules_updated\":42}"
```

#### 9. **debug** (`cmd_debug.sh`)
```bash
# Add JSON for status subcommand:
json_success "{
  \"trace_enabled\":$trace_enabled,
  \"trace_log\":\"$trace_log\",
  \"log_level\":\"$log_level\",
  \"orphans\":$orphan_count
}"
```

#### 10. **smoke** (`cmd_smoke.sh`)
```bash
# Add JSON for test results:
json_success "{\"tests_run\":44,\"passed\":42,\"failed\":2,\"skipped\":0}"
```

#### 11. **suricata** (`cmd_suricata.sh`)
```bash
# Add JSON for status:
json_success "{
  \"installed\":true,
  \"version\":\"7.0.2\",
  \"running\":true,
  \"rules_updated\":\"2025-12-30\"
}"
```

#### 12. **trust** (not in original list - also needs JSON)
```bash
# Add JSON for provider status:
json_success "{\"providers\":[\"CLOUDFLARE\",\"AWS\"],\"total_ips\":15234}"
```

---

## Implementation Pattern (Standard Template)

For each command, follow this pattern:

### Step 1: Add JSON Mode Detection
```bash
nftban_cmd_<command>() {
    local json_mode=false

    # Detect --json flag
    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && json_mode=true
    done

    # Load JSON helper if needed
    if [[ "$json_mode" == "true" ]] && [[ -f "${NFTBAN_LIB_DIR}/helpers/json_output.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/helpers/json_output.sh"
    fi

    # ... rest of command logic
}
```

### Step 2: Add JSON Output Branch
```bash
if [[ "$json_mode" == "true" ]]; then
    # Build JSON data object
    local data="{\"key\":\"value\",\"status\":\"active\"}"

    # Output using helper
    json_success "$data"
else
    # Existing text output
    echo "Status: active"
fi
```

### Step 3: Update Help/Usage
```bash
nftban_cmd_<command>_usage() {
    cat <<EOF
Usage: nftban <command> [OPTIONS]

Options:
  --json    Output in JSON format
  --help    Show this help

Examples:
  nftban <command>
  nftban <command> --json
EOF
}
```

---

## Testing Checklist

After adding JSON to each command:

```bash
# Test text mode (default)
nftban <command>

# Test JSON mode
nftban <command> --json | jq .

# Verify JSON structure
nftban <command> --json | jq '.success, .timestamp, .data'

# Test error cases
nftban <command> invalid-arg --json | jq '.error'
```

---

## Update Registry After Implementation

After implementing JSON for a command, update `commands.registry.yml`:

```yaml
<command>:
  has_json: false  # Change to true
  output_modes: [text]  # Change to [json, text]
```

---

## Estimated Implementation Time

- **Priority 1 (gui, metrics, timers)**: 30 minutes
- **Priority 2 (profile, system)**: 20 minutes
- **Priority 3 (wizard, menu)**: N/A (mark text-only)
- **Priority 4 (sync, debug, smoke, suricata, trust)**: 45 minutes

**Total**: ~2 hours of focused development

---

## Notes

- **Wizard and Menu**: These are interactive TUI commands - JSON output not applicable
- **All JSON must include**: `success`, `timestamp`, `data` fields (per json_output.sh standard)
- **Error handling**: Use `json_error()` for error cases
- **Backward compatibility**: Text output remains default, --json is opt-in

---

**Next Steps for v1.0.16:**
1. Implement Priority 1 commands (service control for panels)
2. Update registry metadata as implemented
3. Test with `jq` validation
4. Document in Wiki (auto-generated from registry)
