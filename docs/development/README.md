# NFTBan Development Documentation

This directory contains development-related documentation for NFTBan contributors and maintainers.

## 📁 Directory Structure

### **Public Documentation** (included in repository)

#### Core Development Guides
- **`coding-standards.md`** - Code style, headers, and best practices
- **`packaging.md`** - RPM/DEB package creation and distribution
- **`GPG_SIGNING_STRATEGY.md`** - Release signing and verification
- **`GO-BINARIES.md`** - Building Go binaries (nftban-feeds, nftban-geoip)
- **`spdx-headers.md`** - SPDX license header format

#### Implementation Documentation
- **`AUTO_HEAL_FINAL_SUMMARY.md`** - Auto-heal system overview
- **`AUTO_HEAL_IMPLEMENTATION_COMPLETE.md`** - Auto-heal completion report
- **`AUTO_HEAL_IMPLEMENTATION_PLAN.md`** - Auto-heal technical plan
- **`BUG-PORT-REPORT-SET-BASED-RULES.md`** - Bug fix documentation

---

### **Internal Documentation** (protected by .gitignore)

#### Lab Testing (Internal)
- **`LAB-TESTING.md`** - Lab server testing procedures ⚠️
- **`LAB-DEPLOYMENT-CHECKLIST.md`** - Deployment checklist ⚠️
- **`CLEAN-LAB-TESTING.md`** - Clean install testing ⚠️
- **`24H-MONITORING-PLAN.md`** - Monitoring procedures ⚠️

**Note:** These contain internal lab server names (lab.mywebhost.gr, etc.) and are NOT published to GitHub.

#### Internal Working Directories

##### **`cli-reference/`** (Internal)
CLI command reference and validation documentation.
- `NFTBAN_CLI_COMPLETE_REFERENCE.md` - Complete CLI command catalog
- `NFTBAN_CLI_EXPORT_FIXES_SUMMARY.md` - Export function fixes

##### **`menu-redesign/`** (Internal)
Menu redesign planning and reference implementations.
- `NFTBAN_v0.10.1_MENU_REDESIGN_PLAN.md` - Redesign plan
- `NFTBAN_CLI_HELP_SPEC.md` - Help menu specification
- `NFTBAN_CLI_COMPLETE_REFERENCE_before_redesign.md` - Pre-redesign state
- `nftban_help.sh` - Reference implementation
- `nftban_menu.sh` - Reference TUI menu
- `nftban_completion.bash` - Reference completion
- `INSTALL_NOTES.md` - Installation instructions
- `quick_fixes.sh` - Helper scripts

##### **`validation/`** (Internal)
Validation reports and analysis.
- `NFTBAN_MENU_VALIDATION_EXPORT.md` - Menu validation and bug detection

---

## 🔒 Protected Documentation

The following are **NOT published** to public GitHub repository (protected by `.gitignore`):

```
# Internal lab testing
development/LAB-*.md
development/CLEAN-LAB-*.md
development/*-LAB-*.md
development/24H-MONITORING-PLAN.md
development/*MONITORING*.md

# Internal working docs
development/validation/
development/menu-redesign/
development/cli-reference/
```

These files remain available **locally** for the development team but are excluded from public repository to protect:
- Internal lab server infrastructure details
- Development planning and strategy
- Validation reports and internal analysis

---

## 📚 How to Use

### For Contributors (Public Docs)
1. Read **`coding-standards.md`** before contributing code
2. Follow **`spdx-headers.md`** for proper file headers
3. Use **`packaging.md`** for building packages
4. Reference **`GO-BINARIES.md`** for Go module builds

### For Maintainers (Internal Docs)
1. Use **`LAB-TESTING.md`** for testing procedures (local only)
2. Reference **`cli-reference/`** for command validation
3. Use **`menu-redesign/`** for UX planning
4. Check **`validation/`** for quality reports

---

## 🔐 Security Note

**Internal documentation** containing sensitive information (lab server names, internal procedures, validation reports) is protected by `.gitignore` and will **NOT** be pushed to GitHub.

If you're working on internal docs:
- Keep them in the designated internal directories
- Don't manually add them to git (`git add -f` is dangerous!)
- They're available locally but protected from public exposure

---

## 📖 Related Documentation

- **User Guides:** `docs/guides/`
- **Architecture:** `docs/architecture/`
- **Reference:** `docs/reference/`
- **Concepts:** `docs/concepts/`

---

**Last Updated:** 2025-11-01
**NFTBan Version:** 0.10.0
