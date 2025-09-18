<p align="center">
  <img src="https://itcms.gr/wp-content/uploads/2022/08/ITCMSA_smalv1.png" alt="ITCMS Logo" width="200"/>
</p>

# 🛡️ nftban – Modular Linux Firewall Management with nftables & Fail2Ban

![Platform](https://img.shields.io/badge/platform-Linux-blue)
![Status](https://img.shields.io/badge/status-active-brightgreen)
![Compatibility](https://img.shields.io/badge/compatibility-Debian%2FUbuntu%20%7C%20RHEL%2FCentOS%2FFedora-orange)
![License](https://img.shields.io/badge/license-ITCMS%20Non--Resale%20License-blue)

---

## 🔍 Overview

**nftban** is a script-driven tool that simplifies and secures firewall management on Linux.  
It combines the power of **nftables** and **Fail2Ban** to deliver high-performance packet filtering alongside dynamic IP blocking.

---

## ✨ Features

- 🌐 **Dual-stack support**: IPv4 & IPv6  
- 🎯 **Customizable filtering**: TCP/UDP port rules, including custom ranges  
- 🔍 **Stateful Packet Inspection (SPI)** through `conntrack`  
- 🚫 **Dynamic IP blocking & whitelisting** using Fail2Ban integration  
- 🧩 **Granular control**: interface-specific rules and modular configuration  
- 📁 **Modular structure** under `/etc/nftban`, including:  
  - `config/`: nftables and Fail2Ban rule files  
  - `scripts/`: installation and management helpers  
  - `logs/`: audit trails and parsing  
  - `backups/`: rule backups  
  - `templates/`: baseline configurations  
- 🛡️ **Safe defaults** with automatic whitelisting of local IPs  
- 📄 **Logging** of applied rules and auditing actions  
- 🖥️ **Compatibility**: RHEL 8+, CentOS Stream, Fedora, Debian, Ubuntu  

---

## 🚀 Quick Start

```bash
# Download the installer
curl -fsSL https://raw.githubusercontent.com/itcmsgr/nftban/scripts/nftban_init.sh -o install_nftban.sh

# Preview installer before execution
less install_nftban.sh

# Run the installer (requires root)
sudo bash install_nftban.sh
```

---

## 🧪 Compatibility Matrix

| Distribution      | Status       |
|-------------------|--------------|
| Debian / Ubuntu   | ✅ Supported |
| RHEL / CentOS     | ✅ Supported |
| Fedora            | ✅ Supported |
| AlmaLinux / Rocky | ✅ Compatible |
| Arch Linux        | ⚠️ Not tested |

---

## 🛠️ Manual Setup Steps

```bash
# Initialize nftables configuration
/etc/nftban/scripts/nftban_init_nftables_conf.sh

# Initialize fail2ban configuration
/etc/nftban/scripts/nftban_init_fail2ban_conf.sh

# Start using nftban
nftban
```

---

## 📂 Directory Structure

```
/etc/nftban/
├── config/
├── scripts/
├── logs/
├── backups/
├── templates/
│   └── control-panels/
│   └── fail2ban/
├── bin/
```

---

## 📌 To-Do / Suggestions

- [ ] Add nftables rule templates per service (SSH, Mail, etc.)  
- [ ] Add logging and monitoring integration  
- [ ] Add support for Arch Linux (`pacman`)  
- [ ] Add interactive CLI tool for managing rules  

---

## 🤝 Contributing

Pull requests are welcome! Feel free to open issues for bugs, ideas, or improvements.

---

## 🧾 Credits

Developed by [Antonios Voulvoulis](https://github.com/itcmsgr) and the **ITCMS Team**  
🔗 [https://itcms.gr](https://itcms.gr)

---

## 📄 License

This project is licensed under the **ITCMS Non-Resale License**.  

- ✅ Free for personal, educational, research, and company use.  
- ✅ You may build services or your own modules on top of it.  
- ❌ You may **not** copy, clone, or resell this software itself as a standalone product.  
- 📩 For redistribution or commercial licensing, please contact [ITCMS](https://itcms.gr).  

© 2025 [ITCMS](https://itcms.gr). All rights reserved.
