# 6-Hour Stability Check Guide

**When to run:** 6 hours after deployment
**Purpose:** Verify system stability before production
**Duration:** ~5-10 minutes

---

## Quick Reference Commands

### Single Server Check
```bash
# CentOS 9
ssh root@lab.example.test "bash /etc/nftban/scripts/stability_check_6h.sh"

# Ubuntu 24.04
ssh root@lab1.example.test "bash /etc/nftban/scripts/stability_check_6h.sh"

# CentOS 10
ssh root@198.51.100.15 "bash /etc/nftban/scripts/stability_check_6h.sh"
```

### All Servers at Once
```bash
for server in root@lab.example.test root@lab1.example.test root@198.51.100.15; do
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Server: $server"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    ssh "$server" "bash /etc/nftban/scripts/stability_check_6h.sh"
    echo ""
done
```

---

## What the Script Checks

### ✅ Automated Checks (10 total)

1. **System Services** - nftables, fail2ban, login monitor status
2. **Error Analysis** - Counts errors in last 6 hours
3. **Memory Trend** - Detects memory leaks
4. **nftables Tables** - Verifies IPv4/IPv6 tables exist
5. **Ban Statistics** - Shows active bans and whitelist
6. **Monitoring Activity** - Confirms automated monitoring working
7. **Disk Space** - Checks log directory size
8. **CPU Load** - Shows performance trend
9. **Function Tests** - Runs full 80+ test suite
10. **Spot Checks** - Tests critical functions

---

## Expected Results

### ✅ GOOD (Ready for Production)
```
Critical Issues Found: 0

╔═══════════════════════════════════════════════════════╗
║      ✓ SYSTEM STABLE - READY FOR PRODUCTION          ║
╚═══════════════════════════════════════════════════════╝

Recommendations:
  • System is stable and functioning correctly
  • All critical functions operational
  • No significant issues detected
  • Safe to deploy to production
```

### ⚠️ MINOR ISSUES (Review Before Production)
```
Critical Issues Found: 1-2

╔═══════════════════════════════════════════════════════╗
║      ⚠ MINOR ISSUES DETECTED                          ║
╚═══════════════════════════════════════════════════════╝

Recommendations:
  • Review issues listed above
  • Most functions working correctly
  • Consider fixing minor issues before production
  • Monitor for another 6 hours if uncertain
```

### ✗ CRITICAL ISSUES (Fix Before Production)
```
Critical Issues Found: 3+

╔═══════════════════════════════════════════════════════╗
║      ✗ CRITICAL ISSUES DETECTED                       ║
╚═══════════════════════════════════════════════════════╝

Recommendations:
  • Review all errors listed above
  • Fix critical issues before production
  • Run comprehensive diagnostics
  • Consult documentation
```

---

## Manual Verification (Optional)

If you want to manually check specific things:

### Check Error Logs
```bash
# Count errors
grep -c "ERROR\|CRITICAL" /var/log/nftban/nftban.log

# View recent errors
grep "ERROR\|CRITICAL" /var/log/nftban/nftban.log | tail -20
```

### Check Memory Usage
```bash
# View memory trend
grep "Memory usage" /var/log/nftban/debug_monitor.log | tail -10

# Current memory
free -h
```

### Check Monitoring Activity
```bash
# Count monitoring runs (should be ~72 after 6 hours)
grep -c "========================================" /var/log/nftban/debug_monitor.log

# View last run
tail -15 /var/log/nftban/debug_monitor.log
```

### Test Critical Functions
```bash
# Test whitelist
nftban whitelist list

# Test DDoS
nftban ddos status

# Test safety
nftban check-safety

# Full verification
nftban verify
```

---

## Decision Tree

```
After 6 hours:
│
├─ Run stability_check_6h.sh on all servers
│
├─ Check results:
│  │
│  ├─ 0 issues found?
│  │  └─ ✅ DEPLOY TO PRODUCTION
│  │
│  ├─ 1-2 minor issues?
│  │  ├─ Issues acceptable?
│  │  │  └─ ✅ DEPLOY (with monitoring)
│  │  └─ Fix needed?
│  │     ├─ Fix issues
│  │     └─ Wait 2 more hours, check again
│  │
│  └─ 3+ critical issues?
│     ├─ Fix all critical issues
│     ├─ Re-deploy fixes
│     └─ Wait 6 more hours, check again
```

---

## What to Look For

### 🚩 Red Flags (Fix Immediately)
- nftables service inactive
- nftables tables missing (IPv4 or IPv6)
- High error count (>50 errors in 6 hours)
- Memory increase >1GB
- Disk space >90%
- Critical functions failing

### ⚠️ Yellow Flags (Monitor/Fix Soon)
- Moderate errors (10-50 in 6 hours)
- Memory increase 0.5-1GB
- Disk space 80-90%
- Some non-critical functions failing
- Monitoring runs lower than expected

### ✅ Green Flags (All Good)
- All services active
- Low error count (<10 in 6 hours)
- Memory stable
- All function tests passing
- Monitoring running as expected

---

## Quick Troubleshooting

### If nftables tables missing:
```bash
# Run bug fix script
bash /etc/nftban/scripts/fix_bugs_41_to_44.sh
```

### If high error count:
```bash
# Check what errors
grep "ERROR" /var/log/nftban/nftban.log | tail -20

# Check if bugs still present
nftban ddos status 2>&1 | grep -i "unbound"
nftban portscan status 2>&1 | grep -i "unbound"
```

### If memory increasing:
```bash
# Check for processes
ps aux | grep nftban

# Check nftables memory
nft -a list ruleset | wc -l

# Restart if needed
systemctl restart nftables
```

### If functions failing:
```bash
# Re-run comprehensive tests
bash /etc/nftban/scripts/comprehensive_function_test.sh

# Check specific module
nftban verify
```

---

## Timeline Summary

```
Hour 0:  Deploy fixes
         ↓
Hour 1:  Automated monitoring starts collecting data
         ↓
Hour 3:  ~36 monitoring cycles completed
         ↓
Hour 6:  RUN STABILITY CHECK ← YOU ARE HERE
         ↓
         Decision point:
         ├─ All good? → Production ready ✅
         ├─ Minor issues? → Fix or accept ⚠️
         └─ Critical? → Fix and wait 6 more hours 🔧
```

---

## Contact/Support

If issues found:
1. Review `/docs/BUG_FIX_SUMMARY_2025-10-21.md`
2. Check `/docs/DEBUG_STATUS_2025-10-21.md`
3. Review bug documentation in `/docs/BUG*` files
4. Run comprehensive diagnostics
5. Check monitoring logs for patterns

---

**Remember:** This is a 6-hour check, not a guarantee. For maximum confidence, monitor for 24-48 hours. However, 6 hours is usually sufficient to catch critical issues.

**Good luck!** 🚀
