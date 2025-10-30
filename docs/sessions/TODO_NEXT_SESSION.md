# NFTBan v0.10.0 - TODO for Next Session

**Date:** 2025-10-28 (End of Evening Session)
**Progress:** 78% complete
**Remaining:** 33-37 hours (4-5 work days)
**Target:** v0.10.0 release

---

## ✅ COMPLETED (This Session)

- ✅ **SPDX Headers:** 100% complete - All source files now have MPL-2.0 identifier
- ✅ **Packaging Decisions:** All documented in PACKAGING_DECISIONS.md
- ✅ **CI/CD Planning:** Complete automation strategy in CI_CD_AUTOMATION_PLAN.md
- ✅ **Helper Scripts:** 5 scripts created and tested (checksums, manifest, SBOM, verify)
- ✅ **GPG Signing Reference:** Complete strategy documented for v0.10.1+
- ✅ **Lab Sync:** All docs and scripts synced to lab.example.test

---

## 🔴 CRITICAL (Must Complete Before Release)

### 1. ⏳ Stats & Metrics System (8-10 hours)
**Priority:** BLOCKING RELEASE
**Status:** NOT STARTED

**Why Critical:**
- Users need to see what NFTBan is doing
- Essential for monitoring and compliance
- Required for enterprise deployments

**Deliverables:**
```bash
# Real-time statistics
nftban stats
nftban stats --detailed

# Report generation
nftban report generate                    # HTML report
nftban report generate --format=json      # For monitoring tools
nftban report email admin@example.com     # Email report

# Output examples
nftban stats
═══════════════════════════════════════════════════════════
  NFTBan Statistics v0.10.0
═══════════════════════════════════════════════════════════

Summary (Last 24 Hours)
───────────────────────────────────────────────────────────
Total Bans: 127 IPs
  - Fail2Ban: 89 (70%)
  - Manual: 12 (9%)
  - Feeds: 26 (21%)

Currently Active: 43 IPs
  - Temporary: 31
  - Permanent: 12

Top Countries (GeoIP):
  1. China (CN): 34 IPs
  2. Russia (RU): 21 IPs
  3. USA (US): 15 IPs

Firewall Performance:
  - Rules loaded: 156
  - Packets dropped: 8,432
  - Last reload: 2 hours ago
```

**Files to create:**
- `/usr/lib/nftban/cli/cmd_stats.sh` - Stats CLI handler
- `/usr/lib/nftban/cli/cmd_report.sh` - Report CLI handler
- `/usr/lib/nftban/core/nftban_stats.sh` - Statistics core logic
- `/usr/lib/nftban/core/nftban_report.sh` - Report generation logic
- `/usr/share/nftban/templates/report.html` - HTML report template

**Implementation steps:**
1. Design stats data structure (JSON in /var/lib/nftban/stats/)
2. Create stats collection functions
3. Implement stats command
4. Create HTML report template
5. Implement report generation
6. Add email integration
7. Test on lab servers

---

### 2. ⏳ Go Binary Build System (4 hours)
**Priority:** BLOCKING PACKAGING
**Status:** NOT STARTED

**Why Critical:**
- RPM/DEB packages need Go binaries included
- Must be static for portability
- Need cross-compilation support

**Deliverables:**
```bash
# Build script
./scripts/build-go-binaries.sh

# Output:
dist/x86_64/nftban-feeds    # Static binary for x86_64
dist/x86_64/nftban-geoip    # Static binary for x86_64
dist/aarch64/nftban-feeds   # Static binary for ARM64
dist/aarch64/nftban-geoip   # Static binary for ARM64
```

**Build requirements:**
- CGO_ENABLED=0 (static linking, no glibc dependency)
- GOOS=linux
- GOARCH=amd64 or arm64
- -ldflags "-s -w" (strip debug info, reduce size)
- Version embedding in binary

**Implementation:**
```bash
#!/usr/bin/env bash
# scripts/build-go-binaries.sh

set -Eeuo pipefail

VERSION="${VERSION:-0.10.0}"

echo "Building nftban-feeds..."
cd go-binaries/nftban-feeds

# x86_64
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -ldflags "-s -w -X main.version=$VERSION" \
  -o ../../dist/x86_64/nftban-feeds

# aarch64
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
  go build -ldflags "-s -w -X main.version=$VERSION" \
  -o ../../dist/aarch64/nftban-feeds

echo "Building nftban-geoip..."
cd ../nftban-geoip

# x86_64
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -ldflags "-s -w -X main.version=$VERSION" \
  -o ../../dist/x86_64/nftban-geoip

# aarch64
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
  go build -ldflags "-s -w -X main.version=$VERSION" \
  -o ../../dist/aarch64/nftban-geoip

echo "✅ Done! Binaries in dist/"
```

---

### 3. ⏳ RPM Packaging (8 hours)
**Priority:** BLOCKING RELEASE
**Status:** NOT STARTED

**Why Critical:**
- Primary distribution method for RHEL-based systems
- Rocky 9, AlmaLinux 9, Fedora 39/40 support required

**Deliverables:**
```
packaging/rpm/nftban.spec       # RPM spec file
packaging/rpm/nftban.service    # systemd service
packaging/rpm/nftban.timer      # systemd timer
packaging/rpm/nftban-feeds.timer # Feed update timer
scripts/build-rpm.sh             # Docker-based build script
```

**RPM spec file structure:**
```spec
Name:           nftban
Version:        0.10.0
Release:        1%{?dist}
Summary:        Advanced nftables-based firewall manager
License:        MPL-2.0
URL:            https://github.com/nftban/nftban

BuildArch:      x86_64 aarch64
Requires:       nftables >= 1.0.0
Requires:       systemd >= 250
Requires:       bash >= 5.0
Requires:       jq >= 1.6
Requires:       curl
Recommends:     fail2ban >= 0.11

%description
NFTBan is an advanced nftables-based firewall manager with:
- Threat intelligence feed integration
- Fail2Ban integration
- GeoIP blocking
- Security profiles
- Comprehensive logging

%prep
# Extract source

%build
# Go binaries already built

%install
# Copy files to buildroot

%pre
# Pre-install checks

%post
# Post-install: create user, show instructions
# DO NOT auto-enable services!

%preun
# Pre-uninstall: stop services

%postun
# Post-uninstall: cleanup (optional)

%files
/usr/sbin/nftban
/usr/lib/nftban/
/usr/share/nftban/
%config(noreplace) /etc/nftban/nftban.conf
/etc/systemd/system/nftban.timer
/etc/systemd/system/nftban-feeds.timer
/var/lib/nftban/
/var/cache/nftban/
/var/log/nftban/

%changelog
* Mon Oct 28 2025 NFTBan <contact@nftban.com> - 0.10.0-1
- Initial release with package manager support
```

**Post-install script (CRITICAL - services DISABLED):**
```bash
%post
# Create nftban user/group
getent group nftban >/dev/null || groupadd -r nftban
getent passwd nftban >/dev/null || useradd -r -g nftban -s /sbin/nologin nftban

# Create directories
mkdir -p /var/lib/nftban/{feeds,state,data}
mkdir -p /var/cache/nftban
mkdir -p /var/log/nftban

# Set permissions
chown -R nftban:nftban /var/lib/nftban /var/cache/nftban /var/log/nftban
chmod 750 /etc/nftban
chmod 640 /etc/nftban/nftban.conf

# Reload systemd
systemctl daemon-reload

# IMPORTANT: DO NOT auto-enable services!
# Show post-install instructions instead
cat <<'EOF'
═══════════════════════════════════════════════════════════
  NFTBan v0.10.0 - Installation Complete
═══════════════════════════════════════════════════════════

⚠️  IMPORTANT: Services are DISABLED by default.

Configure NFTBan before enabling services:

  1. Check system health:
     sudo nftban health

  2. Select security profile:
     sudo nftban profile

  3. Enable automatic updates (recommended):
     sudo systemctl enable --now nftban.timer

  4. Verify:
     sudo nftban status

Documentation: /usr/share/doc/nftban/
═══════════════════════════════════════════════════════════
EOF
```

---

### 4. ⏳ DEB Packaging (6 hours)
**Priority:** BLOCKING RELEASE
**Status:** NOT STARTED

**Why Critical:**
- Primary distribution method for Debian-based systems
- Ubuntu 22.04/24.04, Debian 12 support required

**Deliverables:**
```
packaging/deb/control           # Package metadata
packaging/deb/rules             # Build rules
packaging/deb/postinst          # Post-install script
packaging/deb/prerm             # Pre-remove script
packaging/deb/postrm            # Post-remove script
packaging/deb/conffiles         # Config file list
scripts/build-deb.sh            # Docker-based build script
```

**control file:**
```
Package: nftban
Version: 0.10.0-1
Architecture: amd64 arm64
Maintainer: NFTBan <contact@nftban.com>
Section: admin
Priority: optional
Depends: nftables (>= 1.0.0), systemd (>= 250), bash (>= 5.0), jq (>= 1.6), curl
Recommends: fail2ban (>= 0.11)
Homepage: https://github.com/nftban/nftban
Description: Advanced nftables-based firewall manager
 NFTBan provides comprehensive firewall management with:
  - Threat intelligence feed integration
  - Fail2Ban integration for intrusion prevention
  - GeoIP-based blocking
  - Pre-configured security profiles
  - Comprehensive logging and reporting
```

**postinst script (CRITICAL - services DISABLED):**
```bash
#!/bin/bash
set -e

case "$1" in
    configure)
        # Create user/group
        if ! getent group nftban >/dev/null; then
            addgroup --system nftban
        fi
        if ! getent passwd nftban >/dev/null; then
            adduser --system --ingroup nftban --no-create-home nftban
        fi

        # Create directories
        mkdir -p /var/lib/nftban/{feeds,state,data}
        mkdir -p /var/cache/nftban
        mkdir -p /var/log/nftban

        # Set permissions
        chown -R nftban:nftban /var/lib/nftban /var/cache/nftban /var/log/nftban
        chmod 750 /etc/nftban
        chmod 640 /etc/nftban/nftban.conf

        # Reload systemd
        systemctl daemon-reload

        # Show post-install instructions
        cat <<'EOF'
═══════════════════════════════════════════════════════════
  NFTBan v0.10.0 - Installation Complete
═══════════════════════════════════════════════════════════

⚠️  IMPORTANT: Services are DISABLED by default.

Configure NFTBan before enabling services:

  1. Check system health:
     sudo nftban health

  2. Select security profile:
     sudo nftban profile

  3. Enable automatic updates (recommended):
     sudo systemctl enable --now nftban.timer

  4. Verify:
     sudo nftban status

Documentation: /usr/share/doc/nftban/
═══════════════════════════════════════════════════════════
EOF
        ;;
esac

exit 0
```

---

### 5. ⏳ GitHub Actions Workflow (4 hours)
**Priority:** BLOCKING AUTOMATION
**Status:** PLANNED (template in CI_CD_AUTOMATION_PLAN.md)

**Why Critical:**
- Automates entire release process
- Ensures reproducible builds
- Reduces human error

**Deliverables:**
```
.github/workflows/release.yml   # Main release workflow
```

**Implementation:** Use template from CI_CD_AUTOMATION_PLAN.md

**Workflow triggers on:**
- Tag push: `v*` (e.g., v0.10.0, v0.10.1, etc.)

**Workflow steps:**
1. Checkout code
2. Install build dependencies
3. Build Go binaries (x86_64, aarch64)
4. Build RPM packages (Rocky 9, Fedora 39/40)
5. Build DEB packages (Ubuntu 22.04/24.04, Debian 12)
6. Build tarball fallbacks
7. Generate SHA256SUMS
8. Generate MANIFEST.txt
9. Generate SBOM.spdx.json (optional)
10. Generate VERIFY.txt
11. Create source tarball
12. Verify all checksums
13. Create GitHub Release
14. Upload all artifacts

---

## 🟡 HIGH PRIORITY (Important)

### 6. ⏳ Critical Documentation (4 hours)
**Priority:** HIGH (user onboarding)
**Status:** PARTIAL

**Files needed:**

#### docs/installation.md
- Package installation methods (RPM, DEB, tarball)
- System requirements
- **CRITICAL:** Emphasize services DISABLED by default
- Step-by-step post-install configuration
- Manual service enable instructions

#### docs/services.md
- All systemd units explained
- `nftban.timer` - Main periodic tasks
- `nftban-feeds.timer` - Feed updates
- How to enable services (step-by-step)
- How to check status
- How to troubleshoot

#### docs/troubleshooting.md
- Common issues and fixes
- Health check failures
- Feed update failures
- Fail2Ban integration issues
- nftables errors
- Permission problems

---

### 7. ⏳ Tarball Fallback (3 hours)
**Priority:** MEDIUM (alternative install method)
**Status:** NOT STARTED

**Why Needed:**
- Air-gapped environments
- Systems without package managers
- Custom installations
- Testing/development

**Deliverables:**
```bash
scripts/build-tarball.sh        # Build tarball
packaging/tarball/install.sh    # Installation script
packaging/tarball/uninstall.sh  # Removal script
packaging/tarball/README.txt    # Instructions
```

**Tarball contents:**
```
nftban-0.10.0-x86_64.tar.gz:
├── install.sh              # Checks arch, installs files
├── uninstall.sh            # Removes files
├── README.txt              # Installation instructions
├── usr/
│   ├── sbin/nftban
│   ├── lib/nftban/
│   │   ├── cli/
│   │   └── core/
│   └── share/nftban/
├── etc/nftban/
│   └── nftban.conf.example
├── systemd/
│   ├── nftban.timer
│   └── nftban-feeds.timer
├── LICENSE
└── SHA256SUMS
```

---

### 8. ⏳ Bug Fixes (3 hours)
**Priority:** HIGH (quality)
**Status:** NOT STARTED

**Known bugs:**

1. **Go binary path detection** (1 hour)
   - Issue: nftban-feeds/nftban-geoip not found if in non-standard location
   - Fix: Update path detection in `/usr/lib/nftban/core/nftban_*_go.sh`
   - Files: nftban_geoip_go.sh, nftban_feeds.sh

2. **Profile auto-reload** (30 minutes)
   - Issue: Changing profile doesn't auto-reload nftables
   - Fix: Add `nft -f /etc/nftables.conf` after profile change
   - File: /usr/lib/nftban/cli/cmd_profile.sh

3. **Feed timer behavior** (30 minutes)
   - Issue: Need clear documentation on enabling feed timer
   - Note: DO NOT auto-enable (conflicts with services DISABLED policy)
   - Fix: Update profile command to suggest enabling timer

4. **Fail2Ban action auto-install** (1 hour)
   - Issue: Fail2Ban action file not automatically copied
   - Fix: Add to health check or setup script
   - Copy: /usr/share/nftban/fail2ban/action.d/nftban.conf → /etc/fail2ban/action.d/

---

## 📊 PROGRESS TRACKING

### Overall Status: 78% Complete

| Component | Status | Hours Remaining |
|-----------|--------|-----------------|
| Stats/Metrics | ⏳ TODO | 8-10 |
| Go Binaries | ⏳ TODO | 4 |
| RPM Packaging | ⏳ TODO | 8 |
| DEB Packaging | ⏳ TODO | 6 |
| GitHub Actions | ⏳ TODO | 4 |
| Documentation | ⏳ TODO | 4 |
| Tarball | ⏳ TODO | 3 |
| Bug Fixes | ⏳ TODO | 3 |
| **TOTAL** | | **36-40 hours** |

---

## 📅 PROPOSED SCHEDULE

### Week 1 (Days 1-3): Core Features
- **Day 1 (8 hours):** Stats/Metrics system implementation
- **Day 2 (8 hours):** Stats/Metrics completion + Bug fixes
- **Day 3 (7 hours):** Go binary build system + Start RPM packaging

### Week 2 (Days 4-5): Packaging
- **Day 4 (8 hours):** Complete RPM packaging + Testing
- **Day 5 (8 hours):** DEB packaging + Tarball fallback

### Week 3 (Day 6): Automation & Final Testing
- **Day 6 (8 hours):** GitHub Actions + Documentation + Final testing

**Release Target:** End of Week 3 (6 work days from now)

---

## ✅ PRE-RELEASE CHECKLIST

Before tagging v0.10.0:

### Code Completion
- [ ] Stats/metrics system working
- [ ] All bugs fixed
- [ ] All SPDX headers present
- [ ] Code reviewed

### Packaging
- [ ] Go binaries build successfully
- [ ] RPM packages build for all distros
- [ ] DEB packages build for all distros
- [ ] Tarball fallback created
- [ ] SHA256SUMS generated
- [ ] MANIFEST.txt generated
- [ ] VERIFY.txt created

### Testing
- [ ] RPM install tested on Rocky 9 lab server
- [ ] DEB install tested on Ubuntu 22.04 lab server
- [ ] Tarball install tested on clean system
- [ ] Services are DISABLED after install (verified)
- [ ] Post-install instructions displayed
- [ ] All commands functional
- [ ] Health check passes
- [ ] Profile selection works
- [ ] Feed update works
- [ ] Fail2Ban integration works
- [ ] Search command works
- [ ] Stats command works
- [ ] Report generation works

### Documentation
- [ ] installation.md complete
- [ ] services.md complete
- [ ] troubleshooting.md complete
- [ ] CHANGELOG.md updated
- [ ] README.md updated
- [ ] All docs spell-checked

### GitHub Actions
- [ ] release.yml workflow created
- [ ] Test tag (v0.10.0-test) successful
- [ ] Artifacts uploaded correctly
- [ ] Checksums verified
- [ ] VERIFY.txt instructions work

### Legal & Compliance
- [x] SPDX headers applied (DONE)
- [x] LICENSE in place (DONE)
- [x] NOTICE.md in place (DONE)
- [x] CONTRIBUTING.md in place (DONE)
- [x] TRADEMARK.md in place (DONE)

### Final Steps
- [ ] Tag v0.10.0
- [ ] GitHub Actions runs successfully
- [ ] GitHub Release created automatically
- [ ] All artifacts present
- [ ] Announcement prepared
- [ ] Social media posts ready

---

## 🎯 IMMEDIATE NEXT STEPS (Order of Execution)

When starting next session:

1. **Review this TODO** (5 minutes)
2. **Start Stats/Metrics** (Day 1 priority)
   - Design data structure
   - Implement collection
   - Create commands
   - Test on lab servers
3. **Fix Bugs** (As you encounter them)
4. **Go Binary Build System** (Before packaging)
5. **RPM Packaging** (Rocky 9 first)
6. **DEB Packaging** (Ubuntu 22.04 first)
7. **GitHub Actions** (Automate everything)
8. **Documentation** (Throughout)
9. **Final Testing** (Last 2 days)

---

## 📚 REFERENCE DOCUMENTS

**Planning & Strategy:**
- `PACKAGING_DECISIONS.md` - All packaging decisions
- `CI_CD_AUTOMATION_PLAN.md` - Complete automation strategy
- `PACKAGING_PLAN_FINAL.md` - Detailed packaging plan
- `docs/development/GPG_SIGNING_STRATEGY.md` - Future signing reference

**Implementation Guides:**
- Helper scripts in `scripts/` directory (READY TO USE)
- GitHub Actions template in CI_CD_AUTOMATION_PLAN.md
- RPM spec template in this document
- DEB control template in this document

**Session Summaries:**
- `SESSION_SUMMARY_2025-10-28_FEATURES.md` - Search implementation
- `SESSION_SUMMARY_2025-10-28_CI_CD.md` - This session summary

---

## 🔥 CRITICAL REMINDERS

### Services MUST Be Disabled
- ⚠️  **NEVER auto-enable services in post-install scripts**
- ⚠️  **Always show post-install configuration instructions**
- ⚠️  **User must manually enable after configuration**
- ⚠️  **This is BY DESIGN for security**

### Package Signing
- ✅ **v0.10.0:** SHA256 checksums ONLY
- ⏳ **v0.10.1+:** Add GPG signing (reference: GPG_SIGNING_STRATEGY.md)

### Architecture Support
- ✅ **Supported:** x86_64 (amd64), aarch64 (arm64)
- ❌ **NOT Supported:** armhf, i686, CentOS 7

### Testing Requirements
- **MUST test on actual lab servers before release**
- **MUST verify services disabled after install**
- **MUST verify checksums work**

---

## 💬 QUESTIONS FOR USER (If Any)

Before starting implementation:

1. **Stats collection frequency?**
   - Real-time (expensive) vs hourly snapshots?
   - Recommendation: Hourly snapshots + real-time on-demand

2. **Report email format?**
   - HTML + Plain text, or HTML only?
   - Recommendation: Both formats

3. **SBOM generation?**
   - Include syft in CI/CD (adds time)?
   - Recommendation: Yes, optional failure

4. **Test tag naming?**
   - Use v0.10.0-test for GitHub Actions testing?
   - Recommendation: Yes

---

**Document Status:** Complete and ready for implementation
**Last Updated:** 2025-10-28 23:20
**Next Session:** Start with Stats/Metrics system
**Estimated Completion:** 6 work days from start

---

**Ready to code!** 🚀
