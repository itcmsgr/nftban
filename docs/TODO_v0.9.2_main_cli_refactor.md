# TODO: Refactor main_cli Module (v0.9.2)

**Planned for:** v0.9.2
**Priority:** Medium
**Complexity:** High
**Estimated Effort:** 8-12 hours

---

## Objective

Refactor `lib/nftban_main_cli.sh` to reduce file size and improve maintainability by splitting it into smaller, focused modules similar to what was done with the security module.

---

## Problem Statement

**Current Status:**
- File: `lib/nftban_main_cli.sh`
- Size: ~2,500+ lines (exact count TBD)
- Contains: All CLI command routing and implementation
- Maintainability: Becoming difficult to manage as features grow

**Issues:**
1. Single monolithic file handles all commands
2. Hard to locate specific command implementations
3. Merge conflicts more likely in large file
4. Testing individual commands requires loading entire module
5. Violates single responsibility principle

---

## Proposed Solution

Split `nftban_main_cli.sh` into category-specific command modules:

### New Module Structure

```
lib/
├── nftban_main_cli.sh          (routing only, ~500 lines)
├── commands/
│   ├── nftban_cmd_whitelist.sh     (whitelist commands)
│   ├── nftban_cmd_blacklist.sh     (blacklist commands)
│   ├── nftban_cmd_ban.sh           (ban/unban commands)
│   ├── nftban_cmd_stats.sh         (statistics commands)
│   ├── nftban_cmd_maintenance.sh   (maintenance commands)
│   ├── nftban_cmd_update.sh        (update commands)
│   ├── nftban_cmd_feeds.sh         (feeds commands)
│   ├── nftban_cmd_geo.sh           (geo commands)
│   ├── nftban_cmd_ddos.sh          (ddos commands)
│   ├── nftban_cmd_portscan.sh      (portscan commands)
│   ├── nftban_cmd_login.sh         (login monitor commands)
│   └── nftban_cmd_misc.sh          (verify, version, help, etc.)
```

### Benefits

1. **Smaller files:** Each command module ~150-300 lines
2. **Clear organization:** Easy to find specific commands
3. **Better testing:** Can test individual command groups
4. **Easier collaboration:** Fewer merge conflicts
5. **Faster loading:** Can lazy-load command modules as needed

---

## Implementation Plan

### Phase 1: Preparation
- [ ] Count current lines in main_cli.sh
- [ ] Categorize all existing commands
- [ ] Create command category mapping document
- [ ] Design module loading mechanism

### Phase 2: Create Command Modules
- [ ] Create `lib/commands/` directory
- [ ] Extract whitelist commands to `nftban_cmd_whitelist.sh`
- [ ] Extract blacklist commands to `nftban_cmd_blacklist.sh`
- [ ] Extract ban commands to `nftban_cmd_ban.sh`
- [ ] Extract stats commands to `nftban_cmd_stats.sh`
- [ ] Extract maintenance commands to `nftban_cmd_maintenance.sh`
- [ ] Extract update commands to `nftban_cmd_update.sh`
- [ ] Extract feeds commands to `nftban_cmd_feeds.sh`
- [ ] Extract geo commands to `nftban_cmd_geo.sh`
- [ ] Extract ddos commands to `nftban_cmd_ddos.sh`
- [ ] Extract portscan commands to `nftban_cmd_portscan.sh`
- [ ] Extract login commands to `nftban_cmd_login.sh`
- [ ] Extract misc commands to `nftban_cmd_misc.sh`

### Phase 3: Update Core
- [ ] Update `nftban_core.sh` to load command modules
- [ ] Simplify `nftban_main_cli.sh` to routing only
- [ ] Add double-loading guards to all command modules
- [ ] Export all command functions

### Phase 4: Testing
- [ ] Test all commands after refactoring
- [ ] Verify no regressions
- [ ] Update smoke tests if needed
- [ ] Test on all 3 lab servers

### Phase 5: Documentation
- [ ] Update module architecture documentation
- [ ] Document command module pattern
- [ ] Update CHANGELOG.md
- [ ] Create migration notes if needed

---

## Design Pattern (Based on Security Module)

### Command Module Template

```bash
#!/usr/bin/env bash
# =============================================================================
# nftban Command Module: <Category>
# =============================================================================
# Command implementations for <category> operations
#
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Version: 0.9.2
# =============================================================================

# Double-loading guard
[[ -n "${NFTBAN_CMD_<CATEGORY>_LOADED:-}" ]] && return 0
declare -gr NFTBAN_CMD_<CATEGORY>_LOADED=1

# Function implementations
cmd_<category>_<action>() {
    # Implementation
}

# Exports
export -f cmd_<category>_<action>
```

### Routing in main_cli.sh

```bash
case "$command" in
    whitelist)
        # Lazy load command module if needed
        [[ -z "${NFTBAN_CMD_WHITELIST_LOADED:-}" ]] && source "${NFTBAN_LIB_DIR}/commands/nftban_cmd_whitelist.sh"
        cmd_whitelist "$@"
        ;;
    # ... other commands
esac
```

---

## Success Criteria

- [ ] main_cli.sh reduced to <500 lines (routing only)
- [ ] All commands split into logical category modules
- [ ] Each command module <300 lines
- [ ] Zero syntax errors (bash -n validation)
- [ ] All existing commands work identically
- [ ] No performance degradation
- [ ] All tests pass on all lab servers

---

## Rollback Plan

If issues arise:
1. Keep backup of original main_cli.sh (`.v091.backup`)
2. Can revert entire refactoring in single restore
3. Tag commit before refactoring starts for easy revert

---

## Related Work

- ✅ Security module refactoring (v0.9.1) - Used as reference pattern
- [ ] This refactoring (v0.9.2)
- [ ] Future: Consider refactoring other large modules

---

**Status:** PLANNED (Not started)
**Target Version:** v0.9.2
**Assigned To:** TBD
