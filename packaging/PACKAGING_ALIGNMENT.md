# NFTBan UI v0.5.0 - Package Alignment Verification

**Date**: 2025-11-14
**Purpose**: Ensure consistency between RPM and DEB packaging to avoid distribution-specific naming conflicts

---

## Critical Naming Conventions

### Package Name
- **RPM**: `nftban-ui`
- **DEB**: `nftban-ui`
- ✅ **ALIGNED**

### Binary Names
| Binary | RPM Path | DEB Path | Status |
|--------|----------|----------|--------|
| GUI Server | `/usr/sbin/nftban-ui` | `/usr/sbin/nftban-ui` | ✅ ALIGNED |
| Auth Service | `/usr/libexec/nftban-ui-auth` | `/usr/libexec/nftban-ui-auth` | ✅ ALIGNED |

### Systemd Unit Names
| Unit | RPM | DEB | Status |
|------|-----|-----|--------|
| GUI Service | `nftban-ui.service` | `nftban-ui.service` | ✅ ALIGNED |
| Auth Service | `nftban-ui-auth.service` | `nftban-ui-auth.service` | ✅ ALIGNED |
| Auth Socket | `nftban-ui-auth.socket` | `nftban-ui-auth.socket` | ✅ ALIGNED |

---

## File Paths Comparison

### Configuration Files

| File | RPM Path | DEB Path | Status |
|------|----------|----------|--------|
| Main Config | `/etc/nftban/ui.conf` | `/etc/nftban/ui.conf` | ✅ ALIGNED |
| IP Whitelist | `/etc/nftban/ui-whitelist.conf` | `/etc/nftban/ui-whitelist.conf` | ✅ ALIGNED |
| PAM Config | `/etc/pam.d/nftban-ui` | `/etc/pam.d/nftban-ui` | ✅ ALIGNED |
| Allowed Groups | `/etc/nftban/allowed-gui-groups` | `/etc/nftban/allowed-gui-groups` | ✅ ALIGNED |

### Runtime Paths

| Path | RPM | DEB | Status |
|------|-----|-----|--------|
| Socket | `/run/nftban-ui/auth.sock` | `/run/nftban-ui/auth.sock` | ✅ ALIGNED |
| Runtime Dir | `/run/nftban-ui/` | `/run/nftban-ui/` | ✅ ALIGNED |

### Log Files

| File | RPM Path | DEB Path | Status |
|------|----------|----------|--------|
| Access Log | `/var/log/nftban/ui-access.log` | `/var/log/nftban/ui-access.log` | ✅ ALIGNED |
| Error Log | `/var/log/nftban/ui-error.log` | `/var/log/nftban/ui-error.log` | ✅ ALIGNED |
| Auth Log | `/var/log/nftban/ui-auth.log` | `/var/log/nftban/ui-auth.log` | ✅ ALIGNED |
| Log Directory | `/var/log/nftban/` | `/var/log/nftban/` | ✅ ALIGNED |

### Data Files

| File | RPM Path | DEB Path | Status |
|------|----------|----------|--------|
| Web Files | `/usr/share/nftban-ui/web/` | `/usr/share/nftban-ui/web/` | ✅ ALIGNED |
| State Dir | `/var/lib/nftban/` | `/var/lib/nftban/` | ✅ ALIGNED |

---

## User and Group Names

### System Users

| User | UID Type | RPM | DEB | Status |
|------|----------|-----|-----|--------|
| Service User | System | `nftban` | `nftban` | ✅ ALIGNED |

### System Groups

| Group | GID Type | RPM | DEB | Purpose | Status |
|-------|----------|-----|-----|---------|--------|
| Daemon | System | `nftban` | `nftban` | System daemon group (no human users) | ✅ ALIGNED |
| CLI/GUI | System | `nftban-cli` | `nftban-cli` | CLI and Web GUI access | ✅ ALIGNED |
| Auditors | System | `nftban-auditors` | `nftban-auditors` | Read-only audit access | ✅ ALIGNED |

**Note:** NFTBan v1.0 uses a 3-group model:
- `nftban` - Daemon only (file ownership, no human users)
- `nftban-cli` - CLI and Web GUI access (human operators)
- `nftban-auditors` - Read-only log access (auditors)
- `nftban-web` - **RETIRED** (merged into nftban-cli)

---

## Systemd Unit Installation Paths

### RPM (Red Hat, Fedora, CentOS, Rocky, Alma)
```
%{_unitdir} = /usr/lib/systemd/system/
```

### DEB (Debian, Ubuntu)
```
/lib/systemd/system/
```

**Note**: Both resolve to systemd unit directory, paths may differ but systemd finds them correctly.

---

## Build Dependencies Comparison

### RPM BuildRequires
```spec
BuildRequires:  golang >= 1.21
BuildRequires:  pam-devel
BuildRequires:  systemd-rpm-macros
BuildRequires:  git
```

### DEB Build-Depends
```control
Build-Depends: debhelper-compat (= 13),
               golang-go (>= 2:1.21~),
               libpam0g-dev,
               dh-systemd
```

### Package Name Differences
| Dependency | RPM | DEB |
|------------|-----|-----|
| Go Compiler | `golang` | `golang-go` |
| PAM Development | `pam-devel` | `libpam0g-dev` |
| Systemd Macros | `systemd-rpm-macros` | `dh-systemd` |

✅ **Functionally equivalent** - Different package managers, same functionality

---

## Runtime Dependencies Comparison

### RPM Requires
```spec
Requires:       systemd
Requires:       pam
Requires:       nftables
Requires(pre):  shadow-utils
```

### DEB Depends
```control
Depends: ${shlibs:Depends},
         ${misc:Depends},
         systemd,
         libpam0g,
         nftables,
         adduser
```

### Package Name Differences
| Dependency | RPM | DEB |
|------------|-----|-----|
| PAM Runtime | `pam` | `libpam0g` |
| User Management | `shadow-utils` | `adduser` |

✅ **Functionally equivalent**

---

## Service Management Commands

### Enable and Start (Fresh Install)

**RPM (systemctl)**:
```bash
systemctl enable nftban-ui-auth.socket
systemctl start nftban-ui-auth.socket
```

**DEB (deb-systemd-helper + deb-systemd-invoke)**:
```bash
deb-systemd-helper enable nftban-ui-auth.socket
deb-systemd-invoke start nftban-ui-auth.socket
```

### Restart on Upgrade

**RPM**:
```bash
systemctl try-restart nftban-ui-auth.socket
systemctl try-restart nftban-ui.service
```

**DEB**:
```bash
deb-systemd-invoke try-restart nftban-ui-auth.socket
deb-systemd-invoke try-restart nftban-ui.service
```

✅ **Behavior aligned** - Both use try-restart to avoid interrupting stopped services

---

## Installation Script Comparison

### User/Group Creation

**RPM (%pre)**:
```bash
getent group nftban >/dev/null || groupadd -r nftban
getent passwd nftban >/dev/null || \
    useradd -r -g nftban -d /var/lib/nftban -s /sbin/nologin \
    -c "NFTBan system user" nftban
```

**DEB (postinst)**:
```bash
if ! getent group nftban > /dev/null 2>&1; then
    addgroup --system nftban
fi
if ! getent passwd nftban > /dev/null 2>&1; then
    adduser --system --group --home /var/lib/nftban \
        --no-create-home --disabled-login \
        --gecos "NFTBan system user" nftban
fi
```

✅ **Behavior aligned** - Different commands, same result

### Permission Setting

**Both RPM and DEB**:
```bash
chown nftban:nftban /var/log/nftban
chmod 0750 /var/log/nftban

mkdir -p /run/nftban-ui
chown root:nftban /run/nftban-ui
chmod 0755 /run/nftban-ui
```

✅ **Identical**

---

## Socket Permissions

### Socket File

**Both RPM and DEB (systemd unit)**:
```ini
[Socket]
ListenStream=/run/nftban-ui/auth.sock
SocketMode=0770
SocketUser=root
SocketGroup=nftban
DirectoryMode=0755
```

✅ **Identical** - Same systemd configuration

---

## Build Flags Alignment

### RPM Build Flags
```bash
CGO_ENABLED=1 go build -buildmode=pie -mod=readonly -modcacherw \
    -ldflags="-linkmode=external -s -w -X main.version=%{version}"
```

### DEB Build Flags
```bash
export CGO_ENABLED=1
export GOFLAGS="-buildmode=pie -mod=readonly -modcacherw"

go build -ldflags="-linkmode=external -s -w -X main.version=$(version)"
```

✅ **Identical flags** - Same build options

---

## Key Differences (Platform-Specific, Not Bugs)

### 1. Package Manager Syntax
- RPM: Uses `%` macros (e.g., `%{buildroot}`, `%{_sbindir}`)
- DEB: Uses shell variables and dh_* helpers

### 2. Systemd Helper Commands
- RPM: Direct `systemctl` commands
- DEB: `deb-systemd-helper` and `deb-systemd-invoke` wrappers

### 3. Build Dependencies Package Names
- Different across distros (e.g., `pam-devel` vs `libpam0g-dev`)
- **Functionally equivalent**

---

## Potential Issues from Past (Now Resolved)

### ❌ Past Issue 1: Inconsistent Binary Names
**Problem**: Binary was called `nftban-gui` on RPM, `nftban-ui` on DEB
**Solution**: ✅ Now both use `nftban-ui`

### ❌ Past Issue 2: Different Service Names
**Problem**: Service was `nftban-gui.service` vs `nftban-ui.service`
**Solution**: ✅ Now both use `nftban-ui.service`

### ❌ Past Issue 3: Socket Path Mismatch
**Problem**: Socket was in `/var/run/nftban/` vs `/run/nftban-ui/`
**Solution**: ✅ Now both use `/run/nftban-ui/auth.sock`

### ❌ Past Issue 4: Config File Locations
**Problem**: Config was `/etc/nftban/gui.conf` vs `/etc/nftban-ui/config`
**Solution**: ✅ Now both use `/etc/nftban/ui.conf`

---

## Verification Checklist

Use this checklist to verify alignment:

- [ ] Package name identical: `nftban-ui`
- [ ] Binary paths identical: `/usr/sbin/nftban-ui`, `/usr/libexec/nftban-ui-auth`
- [ ] Systemd unit names identical
- [ ] Socket path identical: `/run/nftban-ui/auth.sock`
- [ ] Config paths identical: `/etc/nftban/ui.conf`
- [ ] PAM config identical: `/etc/pam.d/nftban-ui`
- [ ] Log directory identical: `/var/log/nftban/`
- [ ] User/group names identical: `nftban`, `nftban-auditors`
- [ ] Socket permissions identical: 0770, root:nftban
- [ ] Build flags identical
- [ ] Service restart behavior identical (try-restart on upgrade)

---

## Testing Commands

### Test RPM Package
```bash
# Build
rpmbuild -ba packaging/rpm/nftban-ui.spec

# Install
sudo rpm -ivh nftban-ui-0.5.0-1.el9.x86_64.rpm

# Verify paths
rpm -ql nftban-ui

# Verify services
systemctl list-units | grep nftban-ui
```

### Test DEB Package
```bash
# Build
dpkg-buildpackage -us -uc

# Install
sudo dpkg -i ../nftban-ui_0.5.0-1_amd64.deb

# Verify paths
dpkg -L nftban-ui

# Verify services
systemctl list-units | grep nftban-ui
```

---

## Conclusion

✅ **All critical paths, names, and behaviors are ALIGNED between RPM and DEB packaging.**

The only differences are platform-specific package manager syntax and dependency package names, which is expected and correct.

---

**Last Verified**: 2025-11-14
**Verified By**: Claude Code Assistant
**Version**: v0.5.0
