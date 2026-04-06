# G18: Rebuild Safety Simulation — Design Draft

**Gate:** G18
**Version:** v1.79.0
**Status:** DRAFT
**Author:** Claude Opus 4.5
**Date:** 2026-04-06

---

## Purpose

Validate that the NFTBan rebuild safety mechanism works correctly:
- Pre-rebuild validation catches problems before changes
- Post-rebuild validation confirms protection state
- Auto-rollback triggers when protection is lost

## Test Cases

### T1: Normal Rebuild (Success Path)

**Preconditions:**
- Server is PROTECTED before rebuild
- Go validator binary available
- Valid backup snapshot exists

**Steps:**
1. Capture pre-rebuild kernel state
2. Execute `nftban rebuild`
3. Verify post-rebuild state is PROTECTED

**Expected:**
- Exit code 0
- Kernel state unchanged or improved
- No rollback triggered

### T2: Rebuild with Degraded Pre-State

**Preconditions:**
- Server is DEGRADED (e.g., missing helper chain)
- Go validator detects degradation

**Steps:**
1. Capture pre-rebuild state (DEGRADED)
2. Execute `nftban rebuild`
3. Verify rebuild corrects the issue

**Expected:**
- Exit code 0
- Post-state is PROTECTED (rebuild fixed issue)
- Improvement logged

### T3: Rebuild Failure with Auto-Rollback

**Preconditions:**
- Server is PROTECTED
- Backup snapshot exists
- Inject failure mode (e.g., syntax error in ruleset)

**Steps:**
1. Capture pre-rebuild state (PROTECTED)
2. Inject invalid nft syntax into staging
3. Execute `nftban rebuild`
4. Verify rollback triggered

**Expected:**
- Exit code non-zero (rebuild failed)
- Rollback executed
- Post-state matches pre-state (PROTECTED restored)
- Warning/error logged

### T4: Rebuild with Protection Loss Detection

**Preconditions:**
- Server is PROTECTED
- Go validator detects protection state

**Steps:**
1. Capture pre-rebuild state (PROTECTED)
2. Execute rebuild that would remove required chain
3. Go validator detects DEGRADED post-state
4. Verify auto-rollback triggered

**Expected:**
- Exit code non-zero
- Auto-rollback restores previous state
- Post-state is PROTECTED

### T5: Rebuild Without Backup (No Rollback Available)

**Preconditions:**
- Server is PROTECTED
- No backup snapshot exists

**Steps:**
1. Remove backup directory
2. Execute `nftban rebuild`
3. Verify warning about missing rollback capability

**Expected:**
- Rebuild completes (if successful)
- Warning logged: "No rollback available"
- No crash if rebuild fails

## Failure Modes

| Mode | Detection | Response |
|------|-----------|----------|
| nft syntax error | nft returns non-zero | Abort before apply |
| Post-validate DEGRADED | Go validator exit 1 | Trigger rollback |
| Post-validate DOWN | Go validator exit 2 | Trigger rollback |
| Rollback fails | Rollback returns non-zero | Log CRITICAL, exit |
| No backup | Check before rebuild | Warn, continue |

## Pass Criteria

1. All T1-T5 test cases pass
2. Auto-rollback triggers when protection degrades
3. No false positives (rebuild blocked when safe)
4. No false negatives (bad rebuild allowed)

## Implementation Notes

### Test Harness

```bash
#!/bin/bash
# G18: Rebuild Safety Simulation Test Harness (pseudo-code)

capture_kernel_state() {
    nftban-validate --json > "$1"
}

inject_failure() {
    # Temporarily break nft syntax
    sed -i 's/accept/INVALID_KEYWORD/' /etc/nftban/rules.d/test.nft
}

restore_failure() {
    # Undo injected failure
    sed -i 's/INVALID_KEYWORD/accept/' /etc/nftban/rules.d/test.nft
}

test_rebuild_success() {
    capture_kernel_state /tmp/pre.json
    nftban rebuild
    capture_kernel_state /tmp/post.json
    # Compare states
}

test_rebuild_rollback() {
    capture_kernel_state /tmp/pre.json
    inject_failure
    nftban rebuild  # Should fail and rollback
    restore_failure
    capture_kernel_state /tmp/post.json
    # Post should match pre (rollback worked)
}
```

### CI Integration

- Requires mock nftables environment OR
- Runs on actual lab server OR
- Uses containerized nft binary

### Dependencies

- G16: Validator tests (validates the validator works)
- G17: Health schema (validates health output format)

---

## Questions for Implementation

1. **Mock vs Real:** Should G18 use mocked nft commands or real nftables?
   - Mock: Faster, more portable, runs in CI
   - Real: Higher confidence, requires privileged runner

2. **Failure injection:** How to safely inject failures?
   - Option A: Temporary rule file modification
   - Option B: Environment variable to force failure
   - Option C: Mock nft binary that fails on demand

3. **Rollback verification:** How to confirm rollback worked?
   - Compare kernel state before/after
   - Check backup was consumed
   - Verify no protection gap during rollback

---

## Next Steps

1. Review design with team
2. Decide mock vs real approach
3. Implement test harness
4. Wire to CI workflow
5. Validate on lab server

---

**Document Control:**
| Version | Date | Changes |
|---------|------|---------|
| 0.1 | 2026-04-06 | Initial draft |
