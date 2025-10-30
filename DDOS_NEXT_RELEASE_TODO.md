# DDOS Protection - Next Release TODO
**Date:** 2025-10-30
**Priority:** HIGH - For v0.10.2 or v0.10.3
**Status:** Planned

---

## ✅ COMPLETED (v0.10.0)

1. ✅ **Step 1: Documentation**
   - DDOS_PROTECTION_STRATEGY.md
   - DDOS_COMPLETE_GUIDE.md
   - DDOS_IMPLEMENTATION_PLAN.md
   - DDOS_STEP2_SAFE_CONFIG_PLAN.md
   - DDOS_STEP3_AUTOTUNE_PLAN.md
   - ddos.conf.REFERENCE

---

## 📋 TODO FOR NEXT RELEASE

### **Step 2: Safe Config Implementation** (Priority: HIGH)

**Estimated time:** 2.5 days

**Tasks:**
- [ ] Update `/etc/nftban/conf.d/ddos.conf`
  - [ ] Comment ALL aggressive defaults
  - [ ] Update values to safe ranges (150/10/25 instead of 20/5/5)
  - [ ] Add inline documentation
  - [ ] Add whitelist section with examples
  - [ ] Add quick start guide in comments

- [ ] Update module `/usr/lib/nftban/core/nftban_ddos.sh`
  - [ ] Add checks for unset variables
  - [ ] Handle commented values correctly
  - [ ] Graceful fallback when limits not set

- [ ] Enhance `nftban ddos reload` command
  - [ ] Show what changed (before/after)
  - [ ] Show which limits are active/inactive
  - [ ] Validate config before applying
  - [ ] Atomic reload with rollback on error
  - [ ] Clear success/error messages

- [ ] Add `nftban ddos status` command
  - [ ] Show current active limits
  - [ ] Show which limits are disabled
  - [ ] Show whitelist configuration

- [ ] Add `nftban ddos show` command
  - [ ] Display current configuration
  - [ ] Compare with available profiles
  - [ ] Suggest improvements

- [ ] Create migration script
  - [ ] Detect old aggressive defaults
  - [ ] Warn users on update
  - [ ] Offer to backup and migrate
  - [ ] `/usr/lib/nftban/scripts/migrate-ddos-config.sh`

- [ ] Testing
  - [ ] Fresh install (nothing enabled by default)
  - [ ] Enable single limit (works correctly)
  - [ ] Reload with changes (applies correctly)
  - [ ] Whitelist functionality
  - [ ] Backward compatibility (existing users)

---

### **Step 3: Auto-Tune Implementation** (Priority: MEDIUM)

**Estimated time:** 5 days

**Tasks:**

#### Phase 1: Detection Logic (2 days)
- [ ] Create `/usr/lib/nftban/core/nftban_ddos_autotune.sh`
- [ ] Implement hardware detection
  - [ ] RAM detection
  - [ ] CPU core count
  - [ ] Disk type (SSD vs HDD)
- [ ] Implement panel detection
  - [ ] cPanel detection
  - [ ] DirectAdmin detection
  - [ ] Plesk detection
  - [ ] Webmin/Virtualmin detection
  - [ ] ISPConfig detection
  - [ ] CloudLinux detection
- [ ] Implement website counting
  - [ ] nginx vhost counting
  - [ ] Apache vhost counting
  - [ ] Panel domain counting
  - [ ] PHP-FPM pool counting
- [ ] Implement service detection
  - [ ] Web servers (nginx, apache, haproxy)
  - [ ] Mail servers (postfix, dovecot, exim)
  - [ ] Databases (mysql, postgresql)
  - [ ] Mail domain counting

#### Phase 2: Traffic Analysis (1 day)
- [ ] HTTP log analysis
  - [ ] Parse nginx access.log
  - [ ] Parse apache access_log
  - [ ] Calculate 95th percentile connections/IP
  - [ ] Calculate peak connections
- [ ] SSH log analysis
  - [ ] Parse auth.log / secure
  - [ ] Count max concurrent connections
  - [ ] Detect automation patterns
- [ ] Mail log analysis
  - [ ] Parse maillog / mail.log
  - [ ] SMTP connections per IP
  - [ ] IMAP connections per IP
  - [ ] Calculate 95th percentiles

#### Phase 3: Decision Algorithm (1 day)
- [ ] Profile matching logic
  - [ ] Multi-site hosting detection
  - [ ] Single business detection
  - [ ] API gateway detection
  - [ ] Office email detection
- [ ] Limit calculation
  - [ ] Combine profile + traffic data
  - [ ] Add safety buffers (50%)
  - [ ] Round to sensible values
- [ ] Confidence scoring
  - [ ] Calculate confidence percentage
  - [ ] Show reasoning
  - [ ] Provide recommendations

#### Phase 4: CLI Integration (1 day)
- [ ] Create `/usr/lib/nftban/cli/cmd_ddos_autotune.sh`
- [ ] Implement `nftban ddos autotune`
  - [ ] Progress indicator
  - [ ] Formatted output
  - [ ] Suggestion display
- [ ] Add options:
  - [ ] `--apply` - Apply suggestions
  - [ ] `--save FILE` - Save to file
  - [ ] `--detect-only` - Show detection only
  - [ ] `--verbose` - Show all steps
  - [ ] `--no-traffic` - Skip traffic analysis
  - [ ] `--force-profile NAME` - Force specific profile

#### Phase 5: Profile Templates
- [ ] Create `/usr/share/nftban/profiles/`
- [ ] Create profile templates:
  - [ ] `multisite-hosting.conf`
  - [ ] `multisite-hosting-large.conf`
  - [ ] `single-business.conf`
  - [ ] `api-gateway.conf`
  - [ ] `office-email.conf`
  - [ ] `disabled.conf`
- [ ] Add `nftban ddos profile` commands:
  - [ ] `list` - Show available profiles
  - [ ] `apply NAME` - Apply profile
  - [ ] `show` - Show current profile
  - [ ] `compare PROF1 PROF2` - Compare profiles

#### Phase 6: Testing (1 day)
- [ ] Test on cPanel server
- [ ] Test on DirectAdmin server
- [ ] Test on Plesk server
- [ ] Test on generic VPS
- [ ] Test with/without logs
- [ ] Test traffic analysis accuracy
- [ ] Test profile suggestions
- [ ] Test apply mechanism

---

## 📊 RELEASE PLANNING

### **v0.10.1 - Emergency DDOS Fix**
**Timeline:** ASAP (1 week)
**Focus:** Step 2 only

**Changes:**
- Comment all aggressive defaults
- Safe values when enabled
- Improved reload mechanism
- Migration script
- Documentation updates

**Goal:** Stop breaking production servers immediately

---

### **v0.10.2 - DDOS Auto-Tune**
**Timeline:** 2-3 weeks after v0.10.1
**Focus:** Step 3

**Changes:**
- Auto-tune detection and suggestions
- Profile templates
- Traffic analysis
- Smart recommendations

**Goal:** Make DDOS configuration easy and intelligent

---

### **v0.10.3 - DDOS Enhancements**
**Timeline:** Future
**Focus:** Advanced features

**Possible features:**
- Machine learning suggestions
- Historical trend analysis
- Automatic adaptive limits
- Cloud integration (detect CloudFlare, AWS, etc.)
- Kubernetes/Docker detection
- Advanced CloudLinux LVE integration
- Dashboard/web UI for DDOS stats

---

## 📝 NOTES

**Why separate releases?**
- v0.10.1: Emergency fix - current defaults BREAK servers
- v0.10.2: Enhancement - makes it easier to configure
- v0.10.3: Advanced - nice-to-have features

**Priority order:**
1. 🔴 **v0.10.1** - CRITICAL (fix production breaking defaults)
2. 🟡 **v0.10.2** - HIGH (improve user experience)
3. 🟢 **v0.10.3** - MEDIUM (advanced features)

---

## ✅ AGREEMENT

- ✅ Step 1 (Documentation): COMPLETE
- ⏳ Step 2 (Safe Config): Next release (v0.10.1)
- ⏳ Step 3 (Auto-Tune): Following release (v0.10.2)
- ⏳ Advanced features: Future (v0.10.3)

**Current Focus:** Move to NEW BUG investigation

---

**EOF**
