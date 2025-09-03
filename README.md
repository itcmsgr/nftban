
# nftban Modular firewall management for Linux using nftables and Fail2Ban

🔒 nftban is an open-source firewall management tool built around nftables and Fail2Ban, providing a modern, efficient, and modular approach to system security. 
It supports major Linux distributions, including Red Hat-based systems (RHEL 8+, CentOS Stream, Fedora) as well as Debian and Ubuntu.

Designed for clarity and maintainability, nftban simplifies firewall management, intrusion prevention, and monitoring with a unified, script-driven architecture.

Author / Company:
Developed and maintained by ITCMS — IT Consulting Managed Services ( https://itcms.gr ) .
 
Credits: 
Created by Antonios Voulvoulis. Contributions are welcome under the terms of the MIT License.

## 🔧 Features
- Uses `nftables` for high-performance packet filtering
- Integrates `Fail2Ban` for dynamic banning of malicious IPs
- Full configuration files included for easy setup
- Modular folder structure under `/etc/nftban`
- It supports major Linux distributions
- Lightweight and extensible
- IPv4 & IPv6 bans are managed separately via configuration lists

## 📦 Installation
UNDER Development 

## 📁 Folder Structure
```
/etc/nftban/
├── config/           # Configuration files (Fail2Ban jails, nftables rules)
├── scripts/          # Main scripts and helpers
├── logs/             # Custom logs or log parsing
├── backups/          # Backup of rules or configs
├── templates/        # Initial nfttables rule templates and fail2ban jail templates
└── README.md         # Documentation
```

## ⚙️ Configuration Overview
- `config/nftables.conf`: Main nftables ruleset
- `config/jail.local`: Fail2Ban jail configuration
- `scripts/firewall.sh`: Main control script

## 🤝 Contributing
We welcome contributions! Please fork the repo and submit a pull request. For major changes, open an issue first to discuss what you would like to change.

## 📄 License
This project is licensed under the **MIT License**. 
You are free to use, modify, and distribute this software with proper attribution.
