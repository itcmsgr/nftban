# Next Session TODO - FHS Auto-Heal Follow-Up
**Date Prepared:** 2025-10-30
**For Session:** Next session
**Status:** Ready to start

---

## 🎯 QUICK RECAP

**Last Session Completed:**
- ✅ FHS Auto-Heal implemented and deployed
- ✅ 100% FHS compliance (21/21 directories OK)
- ✅ Daily health timer active on all servers
- ✅ Comprehensive documentation (7 files)
- ✅ External review completed (5-star rating)

**Current State:**
- All 3 lab servers: Deployed and verified
- Documentation: Complete but needs minor improvements
- Code: Production ready, some files need update

---

## 📋 TODO FOR NEXT SESSION

### Priority 1: Documentation Improvements (ChatGPT Suggestions)

#### Task 1.1: Add Version Headers
**What:** Add version info to all documentation files

**Files to update:**
- `PERMISSION_ARCHITECTURE.md`
- `FHS_AUTO_HEAL_COMPLETE_SUMMARY.md`
- `FHS_AUTO_HEAL_ARCHITECTURE.md`
- `FHS_CONSOLIDATION_COMPLETE.md`
- `AUTO_HEAL_COMPLETE.md`
- `FHS_AUTO_HEAL_INDEX.md`

**Add at top:**
```markdown
**Version:** 1.0
**Last Updated:** 2025-10-30
**Status:** Production Ready
```

**Time Estimate:** 15 minutes

---

#### Task 1.2: Add Cross-Links
**What:** Add navigation links between documents

**Example to add at top of each file:**
```markdown
**Related Documentation:**
- [Index](FHS_AUTO_HEAL_INDEX.md) - Documentation index
- [Permission Architecture](PERMISSION_ARCHITECTURE.md) - Who owns what
- [Complete Summary](FHS_AUTO_HEAL_COMPLETE_SUMMARY.md) - Full guide
```

**Files to update:** All 7 documentation files

**Time Estimate:** 20 minutes

---

#### Task 1.3: Add Real Journal Log Samples
**What:** Add actual journalctl output examples

**Where:** `FHS_AUTO_HEAL_COMPLETE_SUMMARY.md` and `PERMISSION_ARCHITECTURE.md`

**Get samples from:**
```bash
ssh root@server2.example.com "journalctl -u nftban-health.service -n 50"
```

**Add sections like:**
```markdown
### Real Journal Output Example

**Success case:**
\```
Oct 30 03:00:00 lab1 nftban-health[12345]: Creating missing directories...
Oct 30 03:00:00 lab1 nftban-health[12345]:   ✓ All directories already exist
Oct 30 03:00:00 lab1 nftban-health[12345]: Fixing permissions and ownership...
Oct 30 03:00:00 lab1 nftban-health[12345]:   ✓ All permissions already correct
\```

**Root-needed case:**
\```
Oct 30 03:00:00 lab1 nftban-health[12345]:   ⚠️  Cannot create 1 directory (need root privileges):
Oct 30 03:00:00 lab1 nftban-health[12345]:      - /usr/lib/nftban/bin → 755 root:root
\```
```

**Time Estimate:** 30 minutes

---

### Priority 2: Fix Wrong URLs

#### Task 2.1: Find All nftables.org References
**What:** Correct nftables.org → nftables.com

**Command to find:**
```bash
grep -r "nftables.org\|wiki.nftables" /home/gituser/nftban-v0.10.0-dev --include="*.sh" --include="*.service" --include="*.md"
```

**Time Estimate:** 10 minutes

---

### Priority 3: Update Installation Scripts

#### Task 3.1: Update /deploy/install.sh
**What:** Use shared FHS spec instead of hardcoded paths

**Current problem:** Lines 48-66 have hardcoded directory creation

**Solution:** Source FHS spec and iterate

**Before:**
```bash
install -d -m 0755 /etc/nftban
install -d -m 0755 /etc/nftban/whitelist.d
install -d -m 0750 -o nftban -g nftban /var/lib/nftban
```

**After:**
```bash
source /usr/lib/nftban/core/nftban_fhs_spec.sh

for dir in "${!NFTBAN_FHS_DIRECTORIES[@]}"; do
    IFS='|' read -r perms owner group _ <<< "${NFTBAN_FHS_DIRECTORIES[$dir]}"
    install -d -m "$perms" -o "$owner" -g "$group" "$dir" 2>/dev/null || true
done
```

**File:** `/home/gituser/nftban-v0.10.0-dev/deploy/install.sh`

**Time Estimate:** 30 minutes

---

#### Task 3.2: Update /install.sh
**What:** Same as above but for root install script

**File:** `/home/gituser/nftban-v0.10.0-dev/install.sh`

**Lines to update:** 96-100 (chmod commands)

**Time Estimate:** 15 minutes

---

### Priority 4: Update Module Init Functions

#### Task 4.1: Update nftban_portscan.sh
**What:** Use FHS spec for directory creation

**Current problem:** Lines with `mkdir -p` hardcoded

**File:** `/home/gituser/nftban-v0.10.0-dev/src/usr/lib/nftban/core/nftban_portscan.sh`

**Look for:**
```bash
mkdir -p "$NFTBAN_PORTSCAN_DATA_DIR"
mkdir -p "$NFTBAN_PORTSCAN_CACHE_DIR"
```

**Solution:** Either:
1. Call `nftban health fix directories`
2. Or source FHS spec and use it

**Time Estimate:** 20 minutes

---

### Priority 5: Documentation Polish

#### Task 5.1: Grammar Review
**What:** Minor grammar improvements suggested by ChatGPT

**Examples:**
- "Check timer health" → "Check timer status"
- "Root-needed" → "Requires root privileges"

**Files:** All documentation

**Time Estimate:** 15 minutes

---

## 🔍 VERIFICATION CHECKLIST

After completing tasks, verify:

```bash
# 1. Documentation has version headers
[ ] grep "Version:" PERMISSION_ARCHITECTURE.md

# 2. Documentation has cross-links
[ ] grep "Related Documentation" FHS_AUTO_HEAL_INDEX.md

# 3. No wrong URLs
[ ] ! grep -r "nftables.org" /home/gituser/nftban-v0.10.0-dev/src

# 4. Install scripts use FHS spec
[ ] grep "nftban_fhs_spec.sh" /home/gituser/nftban-v0.10.0-dev/deploy/install.sh

# 5. All servers still compliant
[ ] ssh root@server2.example.com 'nftban fhs' | grep "21 | OK: 21"
```

---

## 📂 KEY FILES FOR NEXT SESSION

### Documentation to Update
```
/home/gituser/nftban-v0.10.0-dev/PERMISSION_ARCHITECTURE.md
/home/gituser/nftban-v0.10.0-dev/FHS_AUTO_HEAL_COMPLETE_SUMMARY.md
/home/gituser/nftban-v0.10.0-dev/FHS_AUTO_HEAL_ARCHITECTURE.md
/home/gituser/nftban-v0.10.0-dev/FHS_CONSOLIDATION_COMPLETE.md
/home/gituser/nftban-v0.10.0-dev/AUTO_HEAL_COMPLETE.md
/home/gituser/nftban-v0.10.0-dev/FHS_AUTO_HEAL_INDEX.md
```

### Scripts to Update
```
/home/gituser/nftban-v0.10.0-dev/deploy/install.sh
/home/gituser/nftban-v0.10.0-dev/install.sh
/home/gituser/nftban-v0.10.0-dev/src/usr/lib/nftban/core/nftban_portscan.sh
```

### Reference Files
```
/home/gituser/nftban-v0.10.0-dev/src/usr/lib/nftban/core/nftban_fhs_spec.sh  ← FHS spec
/home/gituser/nftban-v0.10.0-dev/SESSION_COMPLETE_2025-10-30_FHS_AUTO_HEAL.md  ← Session summary
/home/gituser/nftban-v0.10.0-dev/NEXT_SESSION_TODO.md  ← This file
```

---

## 🎯 SESSION GOALS

**Primary Goal:** Complete documentation improvements

**Secondary Goal:** Update installation scripts to use FHS spec

**Stretch Goal:** Update all module init functions

**Time Estimate:** 2-3 hours for all tasks

---

## 🚀 QUICK START NEXT SESSION

**Step 1:** Read session summary
```bash
cat /home/gituser/nftban-v0.10.0-dev/SESSION_COMPLETE_2025-10-30_FHS_AUTO_HEAL.md
```

**Step 2:** Verify current state
```bash
# Check all servers
ssh root@server2.example.com 'nftban fhs'
systemctl status nftban-health.timer
```

**Step 3:** Start with Priority 1
- Begin with version headers (easiest)
- Then cross-links
- Then journal samples

**Step 4:** Test as you go
- Deploy changes to lab1 first
- Verify before deploying to all servers

---

## 📊 CURRENT STATUS SUMMARY

| Component | Status | Notes |
|-----------|--------|-------|
| FHS Spec | ✅ Complete | In production on all servers |
| Auto-Fix | ✅ Complete | Smart, privilege-aware |
| Health Timer | ✅ Active | Running daily at 03:00 AM |
| FHS Compliance | ✅ 100% | 21/21 OK on all servers |
| Documentation | ⚠️ Good | Needs minor improvements |
| Install Scripts | ⚠️ Works | Should use shared FHS spec |
| Module Inits | ⚠️ Works | Should use shared FHS spec |

**Overall:** Production ready, polish remaining

---

## 💡 TIPS FOR NEXT SESSION

1. **Start with easy wins** - Version headers and cross-links are quick

2. **Test incrementally** - Don't change everything at once

3. **Keep backups** - Before updating install scripts

4. **Use lab1 as test** - Deploy there first, verify, then roll out

5. **Check journal logs** - Get real examples for documentation

6. **Update this file** - Mark tasks complete as you go

---

## 📝 NOTES FROM THIS SESSION

**What went well:**
- Clear architecture established
- Smart auto-fix implementation
- Comprehensive documentation
- External validation (5-star review)

**What to improve:**
- Installation scripts should use shared spec
- Add more cross-references in docs
- Include real log examples

**Lessons learned:**
- Single source of truth is crucial
- Privilege awareness prevents issues
- Clear reporting > silent fixes
- External review catches polish opportunities

---

## ✅ CHECKLIST: READY FOR NEXT SESSION

- [x] Session summary created
- [x] TODO list prepared
- [x] Files identified
- [x] Priority order established
- [x] Time estimates provided
- [x] Verification checklist ready
- [x] Current state documented
- [x] Quick start guide included

**Status:** ✅ READY TO START NEXT SESSION

---

**Last Updated:** 2025-10-30
**Created By:** Session 2025-10-30
**Purpose:** Continuation planning

**EOF**
