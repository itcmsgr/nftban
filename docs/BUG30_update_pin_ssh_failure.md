# BUG30: `nftban update pin` Fails Silently When Called via SSH

**Date**: 2025-10-21
**Severity**: HIGH
**Category**: Security / Remote Management
**Status**: IDENTIFIED - Needs Fix

---

## Problem Description

The `nftban update pin <SHA>` command fails silently when executed via SSH without a terminal, blocking the security mechanism that protects against malicious updates.

### Expected Behavior
```bash
ssh root@server "nftban update pin 2bb494131f28a893f10775977219b6a10e401cda"
# Should: Update pin file and show success message
```

### Actual Behavior
```bash
ssh root@server "nftban update pin 2bb494131f28a893f10775977219b6a10e401cda"
# Shows: Warnings about pin update
# BUT: No success message, pin file NOT created
# Result: Silent failure
```

### Impact
- **Security System Broken**: Updates blocked indefinitely
- **Remote Management Broken**: Cannot update pins via automation/scripts
- **User Confusion**: Shows warnings but doesn't indicate failure
- **Manual Workaround Required**: Must manually create pin file

---

## Root Cause

**Location**: `lib/nftban_update_module.sh:320-326`

```bash
nftban_update_set_commit_pin() {
    # ... validation code ...

    if [[ -n "$current_pin" ]]; then
        nftban_log_warning "Updating commit pin:"
        nftban_log_warning "  From: $current_pin"
        nftban_log_warning "  To:   $new_sha"

        read -p "Are you sure? [y/N] " -n 1 -r  # ← BUG: Blocks on SSH
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            nftban_log_info "Pin update cancelled"
            return 1  # ← Silent failure when no input
        fi
    fi
}
```

**Problem**: The `read -p` command requires an interactive terminal. When called via SSH without `-t` flag or in scripts, there's no terminal, so:
1. `read` returns immediately with empty `$REPLY`
2. Condition `[[ ! $REPLY =~ ^[Yy]$ ]]` is TRUE
3. Function returns 1 (failure)
4. No error message shown to user
5. Pin file never created

---

## Actual vs Expected Pin File Location

During debugging, discovered the pin file location:

### Incorrect Location (used during debugging):
```bash
/etc/nftban/data/update_commit_pin.txt  # ✗ WRONG
```

### Correct Location:
```bash
/etc/nftban/config/update-pins.conf     # ✓ CORRECT
```

**Defined in**: `lib/nftban_update_module.sh:33`
```bash
readonly NFTBAN_PINNED_COMMIT_FILE="${NFTBAN_CONFIG_DIR}/update-pins.conf"
```

---

## Reproduction Steps

1. Push new commits to GitHub
2. Try to update pin via SSH:
   ```bash
   ssh root@lab.example.test "nftban update pin 2bb494131f28a893f10775977219b6a10e401cda"
   ```
3. Observe warnings but no success/failure message
4. Check pin file:
   ```bash
   ssh root@lab.example.test "cat /etc/nftban/config/update-pins.conf"
   # Output: File not found or old SHA
   ```
5. Try to update:
   ```bash
   ssh root@lab.example.test "nftban update perform"
   # Output: "Update DENIED: Commit SHA mismatch"
   ```

---

## Workaround (Current)

Manually create/update the pin file:

```bash
NEW_SHA="2bb494131f28a893f10775977219b6a10e401cda"

# CentOS 9
ssh root@lab.example.test "mkdir -p /etc/nftban/config && \
  echo '$NEW_SHA' > /etc/nftban/config/update-pins.conf && \
  chmod 600 /etc/nftban/config/update-pins.conf"

# Ubuntu 24.04
ssh root@lab1.example.test "mkdir -p /etc/nftban/config && \
  echo '$NEW_SHA' > /etc/nftban/config/update-pins.conf && \
  chmod 600 /etc/nftban/config/update-pins.conf"

# CentOS 10
ssh root@198.51.100.15 "mkdir -p /etc/nftban/config && \
  echo '$NEW_SHA' > /etc/nftban/config/update-pins.conf && \
  chmod 600 /etc/nftban/config/update-pins.conf"
```

---

## Proposed Fix

### Option 1: Add `--force` flag for non-interactive use (Recommended)

```bash
nftban_update_set_commit_pin() {
    local new_sha="$1"
    local force="${2:-false}"

    # ... validation code ...

    if [[ -n "$current_pin" && "$force" != "true" ]]; then
        # Only prompt if NOT forced
        if [[ -t 0 ]]; then  # Check if stdin is a terminal
            nftban_log_warning "Updating commit pin:"
            nftban_log_warning "  From: $current_pin"
            nftban_log_warning "  To:   $new_sha"

            read -p "Are you sure? [y/N] " -n 1 -r
            echo ""
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                nftban_log_info "Pin update cancelled"
                return 1
            fi
        else
            # No terminal, require --force flag
            nftban_log_error "Non-interactive session detected"
            nftban_log_error "Use: nftban update pin <SHA> --force"
            return 1
        fi
    fi

    # ... write pin file ...
}
```

**CLI Usage**:
```bash
# Interactive (local or ssh -t)
sudo nftban update pin <SHA>

# Non-interactive (scripts, remote)
sudo nftban update pin <SHA> --force

# OR via main CLI
sudo nftban update pin <SHA> --force
```

### Option 2: Auto-detect terminal and skip prompt

```bash
if [[ -n "$current_pin" ]]; then
    if [[ -t 0 ]]; then
        # Interactive: Ask for confirmation
        read -p "Are you sure? [y/N] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return 1
        fi
    else
        # Non-interactive: Log and proceed
        nftban_log_warning "Non-interactive mode: Updating pin without confirmation"
        nftban_log_warning "  From: $current_pin"
        nftban_log_warning "  To:   $new_sha"
    fi
fi
```

### Option 3: Better error handling

```bash
if [[ -n "$current_pin" ]]; then
    nftban_log_warning "Updating commit pin:"
    nftban_log_warning "  From: $current_pin"
    nftban_log_warning "  To:   $new_sha"

    if read -t 5 -p "Are you sure? [y/N] " -n 1 -r 2>/dev/null; then
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            nftban_log_error "Pin update CANCELLED by user"
            return 1
        fi
    else
        # Timeout or no terminal
        nftban_log_error "Cannot get user confirmation (no terminal or timeout)"
        nftban_log_error "To update pin remotely, manually edit:"
        nftban_log_error "  ${NFTBAN_PINNED_COMMIT_FILE}"
        return 1
    fi
fi
```

---

## Recommendation

**Implement Option 1** (--force flag):

**Pros**:
- ✅ Explicit user intent required for non-interactive use
- ✅ Maintains security (won't auto-update pins in scripts)
- ✅ Clear error messages
- ✅ Backward compatible (existing interactive use unchanged)
- ✅ Works with automation tools

**Usage Examples**:
```bash
# Manual update (interactive)
sudo nftban update pin abc123...

# Automation/SSH (explicit)
ssh root@server "nftban update pin abc123... --force"

# Update helper script
LOCAL_REPO_FILES/update_pins_to_latest.sh --force
```

---

## Security Considerations

### Why the prompt exists:
1. **Prevents accidental pin updates** (could break updates)
2. **Forces admin verification** (must check GitHub commit)
3. **Protects against automation errors** (won't blindly update)

### Fix must maintain security:
- ✅ Still require manual action (--force flag)
- ✅ Still log all pin changes
- ✅ Still validate SHA format
- ✅ Still verify commit exists on GitHub
- ✅ Clear audit trail of who/when/why

---

## Related Files

- `lib/nftban_update_module.sh` - Contains `nftban_update_set_commit_pin()`
- `lib/nftban_main_cli.sh` - CLI routing for `nftban update pin`
- `/etc/nftban/config/update-pins.conf` - Pin file location

---

## Testing Checklist

After fix:
- [ ] Interactive pin update works (local terminal)
- [ ] Non-interactive pin update works with `--force` (SSH)
- [ ] Non-interactive without `--force` shows clear error
- [ ] Pin file created at correct location
- [ ] Pin file has correct permissions (600)
- [ ] Update system reads new pin correctly
- [ ] Update proceeds with correct pin
- [ ] Update blocked with wrong/missing pin
- [ ] Audit trail logged properly

---

## Priority

**HIGH** - This bug blocks the entire update security mechanism for remote servers.

**Impact**:
- All 3 lab servers affected
- Production deployments would be affected
- Requires manual workaround for every commit
- Defeats purpose of secure update system

**Fix Timeline**: Include in next commit (v0.9.2)

---

## Discovered During

Testing modular CLI architecture POC (security command).
Attempted to update all 3 lab servers via SSH to test new functionality.
