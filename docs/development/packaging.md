# NFTBan Packaging Guide

## Overview

NFTBan uses native package formats (RPM and DEB) for distribution on Enterprise Linux and Debian-based systems.

### Supported Distributions

**RPM Packages:**
- Rocky Linux 9+
- AlmaLinux 9+
- Fedora 38+
- RHEL 9+ (compatible)

**DEB Packages:**
- Ubuntu 22.04 LTS+
- Debian 12+

---

## Package Architecture

### Dependencies

All packages include comprehensive dependencies:

**Core Requirements:**
- `nftables >= 1.0.0` - Firewall backend
- `systemd >= 250` - Service management
- `bash >= 5.0` - Script interpreter
- `jq >= 1.6` - JSON processing
- `curl` or `wget` - HTTP downloads
- `coreutils`, `gzip`, `tar` - File operations
- `grep`, `sed`, `gawk` - Text processing
- `findutils`, `util-linux` - System utilities
- `iproute2` - Network configuration
- `ipset` - IP set management
- `git` - Version control (for feeds)
- `shadow-utils`/`adduser` - User management

**Recommended:**
- `fail2ban >= 0.11` - Automatic banning
- `logrotate` - Log rotation

**Conflicts:**
- `firewalld` - Incompatible firewall manager
- `iptables` / `iptables-services` / `iptables-persistent` - Legacy firewall

### File Layout

NFTBan follows FHS (Filesystem Hierarchy Standard):

```
/usr/sbin/nftban                        # Main CLI binary
/usr/lib/nftban/                        # Application libraries
  ├── bin/                              # Go binaries
  │   ├── nftban-feeds                  # Feed processor
  │   └── nftban-geoip                  # GeoIP processor
  ├── core/                             # Core modules
  └── cli/                              # CLI commands

/etc/nftban/                            # Configuration
  ├── nftban.conf                       # Main config (noreplace)
  ├── nftban.conf.local                 # Local overrides
  ├── conf.d/                           # Module configs
  ├── feeds.d/                          # Feed definitions
  ├── rules.d/                          # Custom rules
  └── secrets.d/                        # API keys (0700)

/var/lib/nftban/                        # Variable state data
  ├── state/                            # Runtime state
  ├── snapshots/                        # nftables backups
  ├── feeds/                            # Downloaded feeds
  ├── keyring/                          # GPG keyring
  ├── backup/                           # System backups
  ├── reports/                          # Generated reports
  ├── metrics/                          # Historical metrics
  └── config/                           # System config
      └── system.conf                   # UID/GID tracking

/var/cache/nftban/                      # Cache data
  ├── geoip/                            # GeoIP database
  └── tmp/                              # Temporary files

/var/log/nftban/                        # Log files
  └── nftban.log                        # Main log (rotated)

/run/nftban/                            # Runtime tmpfs
  ├── locks/                            # Lock files
  └── commit-confirm/                   # Recovery system
```

### User/Group Management

NFTBan uses **dynamic UID/GID assignment** (no static IDs):

- `nftban` system user (no login) - runs services
- `nftban-cli` group - CLI access control

**Created by:**
- `sysusers.d/nftban.conf` (systemd-sysusers)
- Package postinst scripts (fallback)

**UID/GID Tracking:**
- Saved to `/var/lib/nftban/config/system.conf`
- Health check monitors alignment
- Auto-heal regenerates if needed

---

## Building Packages

### Build RPM Packages

**Prerequisites:**
```bash
# Rocky/AlmaLinux/Fedora
sudo dnf install -y rpm-build rpmdevtools systemd-rpm-macros
```

**Build:**
```bash
cd /home/gituser/github/nftban
./scripts/build-rpm.sh
```

**Output:**
```
dist/packages/nftban-0.10.0-1.el9.x86_64.rpm
dist/packages/nftban-0.10.0-1.el9.aarch64.rpm
```

### Build DEB Packages

**Prerequisites:**
```bash
# Ubuntu/Debian
sudo apt-get install -y dpkg-dev debhelper dh-systemd fakeroot
```

**Build:**
```bash
cd /home/gituser/github/nftban
./scripts/build-deb.sh
```

**Output:**
```
dist/packages/nftban_0.10.0-1_amd64.deb
dist/packages/nftban_0.10.0-1_arm64.deb
```

---

## Testing Packages

### Test RPM Installation

**Option 1: Docker Container (Clean Environment)**
```bash
# Rocky Linux 9
docker run -it --rm --privileged \
  -v $(pwd)/dist/packages:/packages \
  rockylinux:9

# Inside container:
dnf install -y /packages/nftban-0.10.0-1.el9.x86_64.rpm
nftban health check
nftban --version
```

**Option 2: Test on Lab Server**
```bash
# Copy package to lab
scp dist/packages/nftban-0.10.0-1.el9.x86_64.rpm root@lab.example.test:/tmp/

# SSH to lab
ssh root@lab.example.test

# Install
sudo dnf install -y /tmp/nftban-0.10.0-1.el9.x86_64.rpm

# Verify
sudo nftban health check
sudo systemctl status nftban.timer
```

### Test DEB Installation

**Option 1: Docker Container (Clean Environment)**
```bash
# Ubuntu 22.04
docker run -it --rm --privileged \
  -v $(pwd)/dist/packages:/packages \
  ubuntu:22.04

# Inside container:
apt-get update
apt-get install -y /packages/nftban_0.10.0-1_amd64.deb
nftban health check
nftban --version
```

**Option 2: Test on Lab Server**
```bash
# Copy package to lab
scp dist/packages/nftban_0.10.0-1_amd64.deb user@ubuntu-lab:/tmp/

# SSH to lab
ssh user@ubuntu-lab

# Install
sudo dpkg -i /tmp/nftban_0.10.0-1_amd64.deb
sudo apt-get install -f  # Fix dependencies if needed

# Verify
sudo nftban health check
sudo systemctl status nftban.timer
```

### Package Testing Checklist

After installation, verify:

1. **Files Installed**
   ```bash
   ls -la /usr/sbin/nftban
   ls -la /etc/nftban/
   ls -la /var/lib/nftban/
   ```

2. **Users/Groups Created**
   ```bash
   id nftban
   getent group nftban-cli
   cat /var/lib/nftban/config/system.conf
   ```

3. **Permissions Correct**
   ```bash
   sudo nftban health check
   # Should show: ✓ 0 issues found
   ```

4. **Systemd Units**
   ```bash
   systemctl list-units 'nftban*'
   systemctl status nftban.timer
   systemctl status nftban-health.timer
   ```

5. **CLI Works**
   ```bash
   nftban --version
   nftban health check
   nftban stats --summary
   ```

6. **Conflicts Prevented**
   ```bash
   # RPM
   sudo dnf install firewalld  # Should fail with conflict

   # DEB
   sudo apt-get install firewalld  # Should fail with conflict
   ```

---

## Package Removal

### Remove RPM Package

```bash
# Stop services
sudo systemctl stop nftban.timer nftban-health.timer

# Remove package (keeps config)
sudo dnf remove nftban

# Purge everything (including nftables rules)
sudo dnf remove nftban
sudo nft delete table inet nftban
sudo rm -rf /var/lib/nftban /var/cache/nftban /var/log/nftban /etc/nftban
```

### Remove DEB Package

```bash
# Stop services
sudo systemctl stop nftban.timer nftban-health.timer

# Remove package (keeps config)
sudo apt-get remove nftban

# Purge everything (including config and data)
sudo apt-get purge nftban

# Manual cleanup if needed
sudo nft delete table inet nftban
sudo rm -rf /var/lib/nftban /var/cache/nftban /var/log/nftban
```

---

## Package Upgrades

### Upgrade Behavior

**Preserved during upgrade:**
- `/etc/nftban/*.conf` (noreplace)
- `/var/lib/nftban/` (state, feeds, backups)
- `nftban` user/group (UID/GID unchanged)
- `system.conf` (auto-updated if UID/GID changed)
- nftables rules (not removed)

**Restarted during upgrade:**
- `nftban.timer`
- `nftban-health.timer`

### Upgrade Testing

```bash
# RPM
sudo dnf upgrade /path/to/nftban-0.11.0-1.el9.x86_64.rpm

# DEB
sudo dpkg -i /path/to/nftban_0.11.0-1_amd64.deb
```

**Verify after upgrade:**
```bash
nftban --version           # Should show new version
nftban health check        # Should pass
nftban health fix all      # Repair any issues
systemctl status nftban.timer
```

---

## Automated Release Process

### GitHub Actions Workflow

Triggered on version tags (e.g., `v0.10.0`):

1. **Build Go Binaries**
   - x86_64 and aarch64
   - Static builds (`CGO_ENABLED=0`)

2. **Build Packages**
   - RPM for Rocky/AlmaLinux/Fedora
   - DEB for Ubuntu/Debian

3. **Generate Checksums**
   - `SHA256SUMS` file
   - `VERIFY.txt` instructions

4. **Create Release**
   - Upload packages to GitHub Releases
   - Include `MANIFEST.txt`
   - Extract release notes from `CHANGELOG.md`

5. **Future: GPG Signing** (v0.10.1+)
   - Sign packages with GPG key
   - Include `SHA256SUMS.asc`

---

## Distribution-Specific Notes

### Rocky Linux / AlmaLinux

- EPEL not required (all deps in base repos)
- Requires systemd 250+ (default in EL9+)
- Compatible with RHEL 9+ clones

### Fedora

- Rolling release, latest packages
- May require newer nftables features

### Ubuntu

- LTS versions recommended (22.04+)
- Universe repo required for some packages
- Check `nftables` version: `nft --version`

### Debian

- Stable (12+) recommended
- May need backports for newer packages
- Check systemd version: `systemd --version`

---

## Troubleshooting

### Build Failures

**RPM: "rpmbuild not found"**
```bash
sudo dnf install -y rpm-build rpmdevtools
```

**DEB: "debhelper not found"**
```bash
sudo apt-get install -y dpkg-dev debhelper dh-systemd fakeroot
```

### Installation Failures

**Dependency conflicts:**
```bash
# RPM
sudo dnf remove firewalld iptables-services

# DEB
sudo apt-get remove firewalld iptables-persistent
```

**Permission denied:**
```bash
# Check SELinux (RPM)
sudo getenforce
sudo ausearch -m avc -ts recent

# Fix with health command
sudo nftban health fix all
```

### Runtime Issues

**Services not starting:**
```bash
sudo journalctl -xeu nftban.service
sudo nftban health check
sudo nftban health fix all
```

**UID/GID mismatch:**
```bash
sudo nftban health fix config
# Regenerates /var/lib/nftban/config/system.conf
```

---

## Developer Notes

### Creating New Package Releases

1. **Update version numbers:**
   - `packaging/rpm/nftban.spec` (Version, Release, changelog)
   - `packaging/deb/changelog` (version, date)
   - `scripts/build-rpm.sh` (VERSION, RELEASE)
   - `scripts/build-deb.sh` (VERSION, RELEASE)

2. **Build and test locally:**
   ```bash
   ./scripts/build-rpm.sh
   ./scripts/build-deb.sh
   ```

3. **Tag release:**
   ```bash
   git tag -a v0.10.0 -m "Release v0.10.0"
   git push origin v0.10.0
   ```

4. **GitHub Actions builds automatically**

5. **Test packages on clean labs**

### Package Maintenance

- Keep dependencies minimal
- Use FHS-compliant paths
- Avoid static UID/GID (use dynamic)
- Test upgrade path from previous versions
- Document breaking changes in changelog

---

## References

- **FHS**: https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html
- **RPM Packaging**: https://rpm-packaging-guide.github.io/
- **DEB Packaging**: https://www.debian.org/doc/manuals/maint-guide/
- **systemd**: https://systemd.io/
- **nftables**: https://wiki.nftables.org/
