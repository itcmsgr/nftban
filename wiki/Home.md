# NFTBan

NFTBan is an open-source Linux Intrusion Prevention System (IPS) and firewall manager built on nftables, designed to integrate cleanly with modern Linux security stacks.

---

## Quick Start

```bash
# RHEL/AlmaLinux/Rocky/Fedora
dnf install ./nftban-*.rpm

# Debian/Ubuntu
dpkg -i nftban-*.deb

# Verify installation
nftban status
nftban health check
```

---

## Documentation

| Page | Description |
|------|-------------|
| [Installation](Installation) | Package installation and initial setup |
| [Configuration](Configuration) | Configuration files and options |
| [CLI Reference](CLI-Reference) | Command-line interface overview |
| [Metrics](Metrics) | Prometheus/OpenMetrics integration |
| [Suricata Integration](Suricata-Integration) | IDS integration for deep packet inspection |
| [Troubleshooting](Troubleshooting) | Common issues and solutions |

---

## Features

- **Automated threat response** - Ban malicious IPs based on detection rules
- **Geographic blocking** - Block or allow traffic by country
- **Threat intelligence feeds** - Integrate external blocklists
- **Commit-confirm safety** - Auto-rollback prevents lockouts
- **Polkit privilege separation** - Group-based access without sudo
- **Metrics export** - Prometheus, Zabbix, OpenMetrics support
- **IDS integration** - Works alongside Suricata for deep inspection

---

## System Requirements

| Component | Requirement |
|-----------|-------------|
| OS | Linux with nftables support |
| Kernel | 4.10+ (nftables) |
| Distributions | RHEL 8+, AlmaLinux 8+, Rocky 8+, Fedora 38+, Debian 11+, Ubuntu 22.04+ |
| Dependencies | nftables, systemd, curl, jq |

---

## Support

- [GitHub Issues](https://github.com/itcmsgr/nftban/issues)
- [Discussions](https://github.com/itcmsgr/nftban/discussions)
