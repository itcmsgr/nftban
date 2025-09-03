# 🔒 nftban – Modular Linux Firewall Management with nftables & Fail2Ban

**nftban** is an open-source, modular firewall management tool for Linux, built on **nftables** and **Fail2Ban**.

It provides:
- IPv4 & IPv6 support
- TCP/UDP port filtering
- Stateful Packet Inspection (SPI)
- Dynamic whitelisting/blacklisting  
All through a script-driven, maintainable architecture.

Compatible with major Linux distributions, **nftban** simplifies firewall configuration, intrusion prevention, and monitoring.

---

## 👤 Author / Company

Developed and maintained by **ITCMS — IT Consulting Managed Services**  
🌐 https://itcms.gr

Created by **Antonios Voulvoulis**  
Contributions are welcome under the **MIT License**.

---

## 🔧 Features

- High-performance packet filtering using **nftables**
- Integrates **Fail2Ban** for dynamic banning of malicious IPs
- Supports **IPv4 & IPv6** with separate ban management
- **TCP/UDP** port filtering, including custom ranges
- **Stateful Packet Inspection (SPI)** with connection tracking (`ct`)
- Interface-specific rules for granular control
- Blacklists & whitelists (system, user-defined, dynamic)
- Full configuration files included for easy setup
- Modular folder structure under `/etc/nftban` for clarity and maintainability
- Lightweight, extensible, and script-driven
- Compatible with major Linux distributions:
  - RHEL 8+
  - CentOS Stream
  - Fedora
  - Debian
  - Ubuntu
- Safe defaults with automatic local IP whitelisting
- Logging and auditing of applied rules
---

## 🚀 Quick Start

Download, inspect, and run the nftban installer:

```bash
# Download the installer
curl -fsSL https://raw.githubusercontent.com/itcmsgr/nftban/main/install_nftban.sh -o install_nftban.sh

# Optional: Preview before execution
less install_nftban.sh

# Run the installer (requires root)
sudo bash install_nftban.sh



🗑️ Uninstall

Pending implementation

📁 Folder Structure
/etc/nftban/
├── config/           # Configuration files (Fail2Ban jails, nftables rules)
├── scripts/          # Main scripts and helpers
├── logs/             # Custom logs or log parsing
├── backups/          # Backup of rules or configs
├── templates/        # Initial nftables & Fail2Ban templates
└── README.md         # Documentation

⚙️ Configuration Overview
config/nftables.conf: Main nftables ruleset
config/jail.local: Fail2Ban jail configuration
scripts/firewall.sh: Main control script

🤝 Contributing
We welcome contributions!
Please fork the repo and submit a pull request.
For major changes, open an issue first to discuss your proposed modifications.
