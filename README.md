
# nftban

**nftban** is an open-source firewall management tool designed to replace legacy solutions like CSF/LFD. 
It leverages the power of **nftables** and **Fail2Ban** to provide a modern, efficient, and modular firewall system for Red Hat-based distributions.

## 🔧 Features
- Uses `nftables` for high-performance packet filtering
- Integrates `Fail2Ban` for dynamic banning of malicious IPs
- Full configuration files included for easy setup
- Modular folder structure under `/etc/itcmsgr`
- Designed for Red Hat 8+, CentOS Stream, and Fedora
- Lightweight and extensible

## 📦 Installation
UNDER Development 

## 📁 Folder Structure
```
/etc/nftban/
├── config/           # Configuration files (Fail2Ban jails, nftables rules)
├── scripts/          # Main scripts and helpers
├── logs/             # Custom logs or log parsing
├── backups/          # Backup of rules or configs
├── templates/        # Rule templates or jail templates
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

