# nftban Development - Backup & Recovery Guide

**Purpose:** Easy recovery if PC crashes - continue work from any machine

---

## Quick Recovery Steps (If PC Crashes)

### 1. Install Claude Code on New PC
```bash
# Download from: https://claude.ai/code
```

### 2. Clone Repository
```bash
cd ~
mkdir -p github
cd github
git clone https://github.com/itcmsgr/nftban.git
cd nftban
```

### 3. Restore LOCAL_REPO_FILES
```bash
# LOCAL_REPO_FILES is inside the repository at:
# /home/gituser/github/nftban/LOCAL_REPO_FILES/

# Everything is already there after clone!
ls LOCAL_REPO_FILES/CLAUDEAI_BCKP/
```

### 4. Open in Claude Code
```bash
# Open the nftban directory in Claude Code
# Claude will read CLAUDE.md automatically
```

**You're ready to continue!** ✅

---

## What Gets Backed Up Automatically

### ✅ In GitHub Repository (Safe)

1. **All Code Changes**
   - Every commit preserved
   - Complete history
   - Location: https://github.com/itcmsgr/nftban

2. **Project Documentation**
   - `CLAUDE.md` - Instructions for Claude Code
   - `README.md` - User documentation
   - All public docs

3. **LOCAL_REPO_FILES/** (Inside repository)
   - `CLAUDEAI_BCKP/` - This folder!
   - `testreports/` - Test reports (private)
   - `archives/` - Old backups
   - All documentation files

**Everything is in git, safe on GitHub!** ✅

---

## Important Files Location

### Main Repository: `/home/gituser/github/nftban/`
```
nftban/
├── lib/                    # All 40+ module files
├── config/                 # Configuration files
├── templates/              # Control panel templates
├── CLAUDE.md              # ⭐ Project context for Claude
├── README.md              # User documentation
└── LOCAL_REPO_FILES/      # Private files (in .gitignore)
    ├── CLAUDEAI_BCKP/     # Recovery guides (this folder)
    ├── testreports/       # Test reports
    ├── archives/          # Module backups
    └── *.md               # Documentation
```

---

## Recovery Process (10 minutes)

### Step 1: New PC Setup
```bash
# Install git
sudo apt install git  # Debian/Ubuntu
sudo dnf install git  # Fedora/RHEL

# Install Claude Code from https://claude.ai/code

# Configure git
git config --global user.name "Your Name"
git config --global user.email "your@email.com"
```

### Step 2: Clone Repository
```bash
cd ~
mkdir -p github
cd github
git clone https://github.com/itcmsgr/nftban.git
cd nftban
```

### Step 3: Verify Everything is There
```bash
# Check main files
ls -la

# Check LOCAL_REPO_FILES
ls -la LOCAL_REPO_FILES/

# Check modules
ls lib/*.sh | wc -l  # Should be 40+

# Check this backup guide
cat LOCAL_REPO_FILES/CLAUDEAI_BCKP/BACKUP_AND_RECOVERY_GUIDE.md
```

### Step 4: Open in Claude Code
```bash
# Open Claude Code → Open Folder → Select nftban directory
# Claude Code reads CLAUDE.md and knows the project!
```

**Done! Ready to continue work.** ✅

---

## What Claude Code Knows

### When You Open the Project:

Claude Code automatically reads:
1. **`CLAUDE.md`** - Complete project instructions
   - Architecture overview
   - Common commands
   - Development guidelines
   - File locations

2. **All Files** - Can read any file you ask about

3. **Git History** - Can see all commits

### What Claude Does NOT Remember:
- Previous conversation history
- Verbal agreements/decisions
- Passwords (by design)

**Solution:** Important info is in `CLAUDE.md` and this guide!

---

## Daily Workflow

### Morning (Start Work)
```bash
cd ~/github/nftban
git pull                    # Get latest changes
git status                  # Check status
```

### During Work
```bash
# Make changes to files

# Commit frequently
git add -A
git commit -m "Clear description"
git push
```

### Evening (End Work)
```bash
# Push all changes
git add -A
git commit -m "End of day - description"
git push

# Everything is backed up to GitHub! ✅
```

---

## Important: What to Commit to Git

### ✅ DO Commit (Safe for Public)
- All code (`.sh` files)
- Configuration templates (`.conf` files)
- Documentation (`.md` files)
- `CLAUDE.md` (project context)
- `LOCAL_REPO_FILES/CLAUDEAI_BCKP/` (this folder)

### ❌ DON'T Commit (Keep Private)
- Test reports with server details
- Passwords or secrets
- Personal notes with sensitive info

**Check `.gitignore`** - Already configured correctly!

---

## Key Files to Keep Updated

### 1. CLAUDE.md (Most Important!)
Update when:
- Adding new features
- Changing architecture
- Important decisions
- New commands

This tells Claude about the project!

### 2. README.md
Update when:
- New version released
- Installation changes
- New features for users

### 3. This Guide (BACKUP_AND_RECOVERY_GUIDE.md)
Update when:
- Changing backup strategy
- New important locations
- Recovery process changes

---

## Testing Your Backup

**Test once a month:**

```bash
# Simulate crash recovery
cd /tmp
git clone https://github.com/itcmsgr/nftban.git test_recovery
cd test_recovery

# Verify everything is there
ls -la LOCAL_REPO_FILES/
ls lib/*.sh | wc -l

# Clean up
cd ..
rm -rf test_recovery
```

If clone works → your backup is safe! ✅

---

## Emergency Contact Info

### If Everything is Lost:

1. **GitHub:** https://github.com/itcmsgr/nftban
   - All code is here
   - Clone and continue

2. **Claude Code Docs:** https://docs.claude.com/en/docs/claude-code
   - How to use Claude Code

3. **This Guide:** Always in `LOCAL_REPO_FILES/CLAUDEAI_BCKP/`

---

## Quick Reference Commands

### Backup (Just Git Push!)
```bash
git add -A
git commit -m "Backup checkpoint"
git push
```

### Recovery (Just Git Clone!)
```bash
git clone https://github.com/itcmsgr/nftban.git
cd nftban
```

### Verify
```bash
# Check everything is there
ls -la
ls LOCAL_REPO_FILES/
ls lib/*.sh | wc -l  # 40+
git log --oneline -10
```

---

## Additional Backup (Optional)

### If You Want Extra Safety:

#### Option 1: Cloud Storage
```bash
# Create backup archive
cd /home/gituser/github
tar -czf nftban_backup_$(date +%Y%m%d).tar.gz nftban/

# Copy to cloud (Google Drive, Dropbox, etc.)
cp nftban_backup_*.tar.gz /path/to/cloud/
```

#### Option 2: USB Drive
```bash
# Copy entire directory to USB
cp -r /home/gituser/github/nftban /media/usb/backups/
```

#### Option 3: Private GitHub Repo
```bash
# Already done! Main repo has everything.
# But you can create a second private repo if you want.
```

---

## Checklist Before Important Work

- [ ] `git pull` - Get latest changes
- [ ] `git status` - Check for uncommitted work
- [ ] `CLAUDE.md` exists and is updated
- [ ] Can access GitHub (test: `git remote -v`)
- [ ] Recent backup exists (test: `git log -1`)

---

## Summary

### Your Backup Strategy:
1. **Everything in git** → Push to GitHub frequently
2. **GitHub is your backup** → Clone from anywhere
3. **LOCAL_REPO_FILES in repo** → Automatically backed up
4. **CLAUDE.md tells Claude** → No need to repeat instructions

### Recovery Process:
1. **Clone repository** → `git clone ...`
2. **Open in Claude Code** → Reads CLAUDE.md
3. **Continue working** → Everything preserved!

**Total time: 10 minutes** ✅

---

## What Makes This Easy

1. **Single Repository** - Everything in one place
2. **LOCAL_REPO_FILES in Git** - Private files included
3. **CLAUDE.md Context** - Claude knows the project
4. **GitHub Hosting** - Professional backup infrastructure

You can lose your PC and be working again in 10 minutes! 🎉

---

**Last Updated:** 2025-10-19
**Location:** `/home/gituser/github/nftban/LOCAL_REPO_FILES/CLAUDEAI_BCKP/`
**Version:** 1.0

---

## Quick Start Card (Print This!)

```
╔══════════════════════════════════════════╗
║   NFTBAN RECOVERY - EMERGENCY CARD       ║
╠══════════════════════════════════════════╣
║                                          ║
║  1. Install Claude Code                  ║
║     https://claude.ai/code               ║
║                                          ║
║  2. Clone Repository                     ║
║     git clone                            ║
║     https://github.com/itcmsgr/nftban    ║
║                                          ║
║  3. Open in Claude Code                  ║
║     File → Open nftban folder            ║
║                                          ║
║  4. Claude reads CLAUDE.md               ║
║     → Knows everything! ✅               ║
║                                          ║
║  Recovery Time: 10 minutes               ║
║                                          ║
╚══════════════════════════════════════════╝
```

**Save this card!** 📋

---

**END OF GUIDE**
