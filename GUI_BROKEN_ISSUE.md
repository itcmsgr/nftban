# ⚠️ GUI Component Under Redesign - Do Not Install

**Labels:** `status: in-progress`, `component: ui`, `priority: high`, `documentation`

---

## ⚠️ Important Notice: GUI Component Status

### Current Status
The NFTBan Web GUI (`nftban-ui`) is currently **BROKEN** and undergoing a **major redesign**.

### What This Means
- 🚫 **Do NOT install the GUI component** (`nftban-ui` package)
- ❌ The web interface is **non-functional** in v1.0.21+
- 🏗️ We are in the **active redesign phase**
- ⏳ Timeline: TBD (significant architectural changes required)

### What Still Works
✅ **CLI is fully functional** - All features available via `nftban` command-line interface
✅ **Core daemon** - All backend functionality working perfectly
✅ **All integrations** - Suricata, RBL monitoring, threat feeds, etc.

### Why the GUI is Broken
The GUI was built for an older architecture and hasn't been updated to support:
- v1.0 dual-table nftables architecture (ip nftban + ip6 nftban)
- New FHS-compliant directory structure
- Distro-aware path management
- New Suricata integration features
- RBL monitoring capabilities
- Enhanced security model (Polkit integration)

### Redesign Scope
The new GUI will be:
- 🎨 Modern responsive design
- 🔐 Secure authentication (nftban-ui-auth integration)
- 📊 Real-time metrics and dashboards
- 🌐 Multi-distro compatible
- ⚡ Built with modern web framework
- 📱 Mobile-friendly interface

### Recommended Workaround
**Use the CLI instead:**
```bash
# All GUI features are available via CLI
nftban status           # System status
nftban list            # View banned IPs
nftban ban <ip>        # Manual ban
nftban config show     # View configuration
nftban health          # Health checks
nftban suricata ...    # Suricata management
nftban rbl check       # RBL monitoring

# For help
nftban help
nftban <command> help
```

### For Package Maintainers
**Installation:**
- ✅ Install `nftban-core` package (fully supported)
- ❌ **Skip** `nftban-ui` package (broken)
- ✅ Install `nftban-all` if you want all components (GUI will be inactive)

**Systemd Services:**
```bash
# Safe to enable/start:
systemctl enable nftban-core-feeds.timer
systemctl enable nftban-maintenance.timer
systemctl enable nftban-health.timer
systemctl enable nftban-suricata-stats.service

# DO NOT enable (GUI-related):
systemctl disable nftban-ui.service
systemctl disable nftban-ui-auth.service
```

### Tracking Progress
- This issue will be updated as redesign progresses
- Subscribe to this issue for updates
- Expected completion: Q1-Q2 2026 (tentative)

### Questions?
- **CLI help:** `nftban help` or check the [wiki](https://github.com/itcmsgr/nftban/wiki)
- **Report CLI bugs:** Open separate issue with `component: cli` label
- **GUI redesign suggestions:** Comment on this issue

---

**Status Last Updated:** 2025-12-31
**Affected Versions:** v1.0.0+
**Workaround:** Use CLI (fully functional)
