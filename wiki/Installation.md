# Installation

NFTBan installation guide for supported Linux distributions.

---

## Table of Contents
- [Package Installation](#package-installation)
- [Post-Install](#post-install)
- [Verification](#verification)
- [Uninstallation](#uninstallation)

---

## Package Installation

### RHEL / AlmaLinux / Rocky / Fedora

```bash
# Download latest release
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-el9-x86_64.rpm

# Install
dnf install -y ./nftban-el9-x86_64.rpm
```

### Debian / Ubuntu

```bash
# Download latest release
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-amd64.deb

# Install
dpkg -i nftban-amd64.deb
apt-get install -f -y
```

### ARM64

Replace `x86_64` with `aarch64` (RPM) or `amd64` with `arm64` (DEB).

---

## Post-Install

The installer automatically:
- Creates FHS directories
- Sets up systemd services
- Configures Polkit rules
- Whitelists server IPs (lockout prevention)
- Downloads GeoIP database

### Enable Services

```bash
# Start the daemon
systemctl enable --now nftband

# Enable maintenance timers
nftban timers enable
```

---

## Verification

```bash
# Check status
nftban status

# Run health check
nftban health check

# Verify nftables structure
nftban nftables verify
```

Expected output shows daemon running and health status OK.

---

## Uninstallation

### RHEL / AlmaLinux / Rocky

```bash
dnf remove nftban-core
```

### Debian / Ubuntu

```bash
apt remove nftban-core
```

### Data Removal

Configuration and data are preserved by default. To remove completely:

```bash
rm -rf /etc/nftban
rm -rf /var/lib/nftban
rm -rf /var/log/nftban
```

---

## References

- Config: `/etc/nftban/`
- Data: `/var/lib/nftban/`
- Logs: `/var/log/nftban/`
- Binaries: `/usr/lib/nftban/`
