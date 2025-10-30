# NFTBan v0.10.0 - Package Manager Installation Order
**CRITICAL REFERENCE FOR RPM/DEB PACKAGE CREATION**

═══════════════════════════════════════════════════════════════════

## 🎯 INSTALLATION ORDER (MUST FOLLOW THIS EXACT SEQUENCE)

### Step 1: Create System User & Groups
```bash
# Create nftban system user (via sysusers.d/nftban.conf)
useradd -r -s /sbin/nologin -d /var/lib/nftban -c "nftban service user" nftban

# Create nftban-cli group (for CLI access control)
groupadd nftban-cli
```

**Package Manager Hook:** `%pre` (RPM) / `preinst` (DEB)

---

### Step 2: Create FHS Directory Hierarchy
```bash
# This is handled automatically by systemd-tmpfiles when:
# /usr/lib/tmpfiles.d/nftban.conf is installed

# OR manually create directories:
systemd-tmpfiles --create nftban.conf
```

**Package Manager Hook:** `%post` (RPM) / `postinst` (DEB)

**tmpfiles.d Configuration:** `/usr/lib/tmpfiles.d/nftban.conf`

---

### Step 3: Install Files

#### 3.1 Configuration Files (nftban:nftban)
```bash
# Main config directory
/etc/nftban/
  ├── nftban.conf                    (644, nftban:nftban)
  ├── nftban.conf.local.example      (644, nftban:nftban)
  ├── nftban.env.example             (644, nftban:nftban)
  ├── ai.conf.example                (644, nftban:nftban)
  ├── baseline.nft                   (644, nftban:nftban)
  │
  ├── conf.d/                        (755, nftban:nftban)
  │   ├── cloudflare.conf
  │   ├── ddos.conf
  │   ├── directadmin.conf
  │   ├── fail2ban.conf
  │   ├── login_alert.conf
  │   ├── mail.conf
  │   ├── portscan.conf
  │   └── stats.conf
  │
  ├── whitelist.d/                   (755, nftban:nftban)
  ├── blacklist.d/                   (755, nftban:nftban)
  ├── ports.d/                       (755, nftban:nftban)
  ├── feeds.d/                       (755, nftban:nftban)
  ├── rules.d/                       (755, nftban:nftban)
  └── secrets.d/                     (750, nftban:nftban)
```

**RPM Directive:** `%config(noreplace)` for *.conf files
**DEB Directive:** `conffiles` for config preservation

---

#### 3.2 Executables (root:root)
```bash
/usr/sbin/
  ├── nftban                         (755, root:root)
  ├── nftban-complete                (755, root:root)
  └── nftban-runtime                 (755, root:root)
```

---

#### 3.3 Libraries (root:root, executed as nftban)
```bash
/usr/lib/nftban/
  ├── cli/                           (755, root:root)
  │   ├── cmd_*.sh                   (755, root:root)
  │   └── ...
  │
  ├── core/                          (755, root:root)
  │   ├── nftban_*.sh                (755, root:root)
  │   └── ...
  │
  ├── cron/                          (755, root:root)
  │   └── nftban_*.sh                (755, root:root)
  │
  ├── exporters/                     (755, root:root)
  │   └── exporter_*.sh              (755, root:root)
  │
  ├── modules/                       (755, root:root)
  │   └── nftban_*_module.sh         (755, root:root)
  │
  └── tools/                         (755, root:root)
      └── *.sh                       (755, root:root)
```

---

#### 3.4 Shared Data (root:root)
```bash
/usr/share/nftban/
  ├── assets/                        (755, root:root)
  ├── completions/                   (755, root:root)
  ├── docs/                          (755, root:root)
  ├── examples/                      (755, root:root)
  ├── profiles/                      (755, root:root)
  └── templates/                     (755, root:root)
      ├── email/
      ├── fail2ban/
      ├── layouts/
      ├── mail/
      ├── partials/
      ├── reports/
      └── themes/
```

---

#### 3.5 Systemd Units
```bash
/usr/lib/systemd/system/
  ├── nftban.service                 (644, root:root)
  ├── nftban.timer                   (644, root:root)
  ├── nftban-apply.service           (644, root:root)
  ├── nftban-rollback.service        (644, root:root)
  └── nftban-rollback.timer          (644, root:root)
```

---

#### 3.6 System Integration
```bash
/usr/lib/sysusers.d/nftban.conf    (644, root:root)
/usr/lib/tmpfiles.d/nftban.conf    (644, root:root)
/etc/bash_completion.d/nftban      (644, root:root)
/etc/cron.d/nftban                 (644, root:root)
/etc/logrotate.d/nftban            (644, root:root)
```

---

### Step 4: Set Ownership & Permissions

**CRITICAL:** This must happen AFTER file installation!

```bash
# Configuration directories (nftban:nftban)
chown -R nftban:nftban /etc/nftban
find /etc/nftban -type d -exec chmod 755 {} \;
find /etc/nftban -type f -exec chmod 644 {} \;
chmod 750 /etc/nftban/secrets.d

# State directories (nftban:nftban)
chown -R nftban:nftban /var/lib/nftban
chown -R nftban:nftban /var/cache/nftban
find /var/lib/nftban -type d -exec chmod 750 {} \;
find /var/cache/nftban -type d -exec chmod 750 {} \;

# Log directory (nftban:adm)
chown -R nftban:adm /var/log/nftban
chmod 750 /var/log/nftban

# Runtime directory (nftban:nftban)
chown -R nftban:nftban /run/nftban
chmod 755 /run/nftban

# Executables (root:root)
chown root:root /usr/sbin/nftban*
chmod 755 /usr/sbin/nftban*

# Libraries (root:root)
chown -R root:root /usr/lib/nftban
find /usr/lib/nftban -type d -exec chmod 755 {} \;
find /usr/lib/nftban -type f -name "*.sh" -exec chmod 755 {} \;
find /usr/lib/nftban -type f -name "*.nft" -exec chmod 644 {} \;

# Shared data (root:root)
chown -R root:root /usr/share/nftban
find /usr/share/nftban -type d -exec chmod 755 {} \;
find /usr/share/nftban -type f -exec chmod 644 {} \;
```

**Package Manager Hook:** `%post` (RPM) / `postinst` (DEB)

---

### Step 5: Reload Systemd & Enable Services

```bash
# Reload systemd daemon
systemctl daemon-reload

# Enable (but DO NOT start) services
systemctl enable nftban.timer
systemctl enable nftban-rollback.timer

# DO NOT auto-start the firewall on package install!
# User must manually run: nftban firewall init
```

**Package Manager Hook:** `%post` (RPM) / `postinst` (DEB)

---

### Step 6: Post-Installation Message

```bash
cat <<'EOF'
════════════════════════════════════════════════════════════
NFTBan v0.10.0 Installed Successfully
════════════════════════════════════════════════════════════

IMPORTANT: Firewall NOT auto-activated for safety!

Next Steps:
1. Review configuration:
   /etc/nftban/nftban.conf

2. Initialize firewall (WILL ACTIVATE FIREWALL):
   nftban firewall init

3. Enable and start timers:
   systemctl start nftban.timer
   systemctl start nftban-rollback.timer

4. Check firewall status:
   nftban status

Documentation: /usr/share/nftban/docs/
════════════════════════════════════════════════════════════
EOF
```

---

## 📁 COMPLETE FHS HIERARCHY

```
/etc/
  └── nftban/                        (755, nftban:nftban)
      ├── conf.d/                    (755, nftban:nftban)
      ├── whitelist.d/               (755, nftban:nftban)
      ├── blacklist.d/               (755, nftban:nftban)
      ├── ports.d/                   (755, nftban:nftban)
      ├── feeds.d/                   (755, nftban:nftban)
      ├── rules.d/                   (755, nftban:nftban)
      └── secrets.d/                 (750, nftban:nftban)

/usr/
  ├── sbin/                          (755, root:root)
  │   ├── nftban
  │   ├── nftban-complete
  │   └── nftban-runtime
  │
  ├── lib/
  │   ├── nftban/                    (755, root:root)
  │   │   ├── cli/
  │   │   ├── core/
  │   │   ├── cron/
  │   │   ├── exporters/
  │   │   ├── modules/
  │   │   └── tools/
  │   │
  │   ├── systemd/system/            (755, root:root)
  │   │   ├── nftban.service
  │   │   ├── nftban.timer
  │   │   ├── nftban-apply.service
  │   │   ├── nftban-rollback.service
  │   │   └── nftban-rollback.timer
  │   │
  │   ├── sysusers.d/                (755, root:root)
  │   │   └── nftban.conf
  │   │
  │   └── tmpfiles.d/                (755, root:root)
  │       └── nftban.conf
  │
  └── share/nftban/                  (755, root:root)
      ├── assets/
      ├── completions/
      ├── docs/
      ├── examples/
      ├── profiles/
      └── templates/

/var/
  ├── lib/nftban/                    (750, nftban:nftban)
  │   ├── state/
  │   ├── snapshots/
  │   ├── feeds/
  │   ├── keyring/
  │   ├── backup/
  │   ├── metrics/
  │   └── reports/
  │
  ├── cache/nftban/                  (750, nftban:nftban)
  │   ├── tmp/
  │   ├── geoip/
  │   └── templates/
  │
  └── log/nftban/                    (750, nftban:adm)

/run/nftban/                         (755, nftban:nftban)
```

---

## 🔐 PERMISSION MATRIX

| Path | Owner | Group | Mode | Purpose |
|------|-------|-------|------|---------|
| `/etc/nftban` | nftban | nftban | 755 | Config root |
| `/etc/nftban/*.conf` | nftban | nftban | 644 | Config files |
| `/etc/nftban/conf.d/` | nftban | nftban | 755 | Module configs |
| `/etc/nftban/whitelist.d/` | nftban | nftban | 755 | Whitelist configs |
| `/etc/nftban/blacklist.d/` | nftban | nftban | 755 | Blacklist configs |
| `/etc/nftban/ports.d/` | nftban | nftban | 755 | Port configs |
| `/etc/nftban/secrets.d/` | nftban | nftban | 750 | Secrets (restricted) |
| `/usr/sbin/nftban*` | root | root | 755 | Executables |
| `/usr/lib/nftban/` | root | root | 755 | Libraries |
| `/usr/lib/nftban/**/*.sh` | root | root | 755 | Shell scripts |
| `/usr/share/nftban/` | root | root | 755 | Shared data |
| `/var/lib/nftban/` | nftban | nftban | 750 | State data |
| `/var/cache/nftban/` | nftban | nftban | 750 | Cache data |
| `/var/log/nftban/` | nftban | adm | 750 | Log files |
| `/run/nftban/` | nftban | nftban | 755 | Runtime data |

---

## 📦 RPM SPEC FILE DIRECTIVES

```spec
%pre
# Create nftban system user and nftban-cli group
getent group nftban >/dev/null || groupadd -r nftban
getent group nftban-cli >/dev/null || groupadd -r nftban-cli
getent passwd nftban >/dev/null || \
    useradd -r -g nftban -d /var/lib/nftban -s /sbin/nologin \
    -c "nftban service user" nftban
exit 0

%post
# Create directories via systemd-tmpfiles
systemd-tmpfiles --create nftban.conf

# Set ownership and permissions
chown -R nftban:nftban /etc/nftban /var/lib/nftban /var/cache/nftban /run/nftban
chown -R nftban:adm /var/log/nftban
chmod 750 /etc/nftban/secrets.d

# Reload systemd and enable services
systemctl daemon-reload
systemctl enable nftban.timer >/dev/null 2>&1 || :
systemctl enable nftban-rollback.timer >/dev/null 2>&1 || :

# Post-install message
cat <<'EOF'
════════════════════════════════════════════════════════════
NFTBan v0.10.0 installed. Run 'nftban firewall init' to start.
════════════════════════════════════════════════════════════
EOF

%preun
# Stop services before uninstall
if [ $1 -eq 0 ]; then
    systemctl --no-reload disable nftban.timer >/dev/null 2>&1 || :
    systemctl stop nftban.timer >/dev/null 2>&1 || :
    systemctl --no-reload disable nftban-rollback.timer >/dev/null 2>&1 || :
    systemctl stop nftban-rollback.timer >/dev/null 2>&1 || :
fi

%postun
# Reload systemd after uninstall
systemctl daemon-reload >/dev/null 2>&1 || :
```

---

## 📦 DEB CONTROL FILE DIRECTIVES

```debian/control
Package: nftban
Pre-Depends: systemd
Depends: nftables, bash (>= 4.0), coreutils

debian/preinst:
#!/bin/bash
# Create nftban system user and nftban-cli group
if ! getent group nftban >/dev/null; then
    groupadd -r nftban
fi
if ! getent group nftban-cli >/dev/null; then
    groupadd -r nftban-cli
fi
if ! getent passwd nftban >/dev/null; then
    useradd -r -g nftban -d /var/lib/nftban -s /sbin/nologin \
        -c "nftban service user" nftban
fi

debian/postinst:
#!/bin/bash
# Create directories via systemd-tmpfiles
systemd-tmpfiles --create nftban.conf

# Set ownership and permissions
chown -R nftban:nftban /etc/nftban /var/lib/nftban /var/cache/nftban /run/nftban
chown -R nftban:adm /var/log/nftban
chmod 750 /etc/nftban/secrets.d

# Reload systemd and enable services
systemctl daemon-reload
systemctl enable nftban.timer >/dev/null 2>&1 || true
systemctl enable nftban-rollback.timer >/dev/null 2>&1 || true

# Post-install message
cat <<'EOF'
════════════════════════════════════════════════════════════
NFTBan v0.10.0 installed. Run 'nftban firewall init' to start.
════════════════════════════════════════════════════════════
EOF

debian/prerm:
#!/bin/bash
# Stop services before uninstall
systemctl stop nftban.timer >/dev/null 2>&1 || true
systemctl disable nftban.timer >/dev/null 2>&1 || true
systemctl stop nftban-rollback.timer >/dev/null 2>&1 || true
systemctl disable nftban-rollback.timer >/dev/null 2>&1 || true

debian/postrm:
#!/bin/bash
# Reload systemd after uninstall
systemctl daemon-reload >/dev/null 2>&1 || true
```

---

## ✅ VERIFICATION CHECKLIST

After package installation:

```bash
# 1. Check user exists
id nftban
# Expected: uid=995(nftban) gid=992(nftban) groups=992(nftban)

# 2. Check group exists
getent group nftban-cli
# Expected: nftban-cli:x:993:

# 3. Check FHS structure
tree -L 2 /etc/nftban /var/lib/nftban /var/log/nftban /run/nftban

# 4. Check ownership
ls -ld /etc/nftban /var/lib/nftban /var/log/nftban
# Expected: drwxr-xr-x nftban nftban /etc/nftban
# Expected: drwxr-x--- nftban nftban /var/lib/nftban
# Expected: drwxr-x--- nftban adm /var/log/nftban

# 5. Check executables
ls -l /usr/sbin/nftban*
# Expected: -rwxr-xr-x root root ...

# 6. Check systemd services
systemctl list-unit-files | grep nftban
# Expected: nftban.timer enabled
# Expected: nftban-rollback.timer enabled

# 7. Check tmpfiles.d
cat /usr/lib/tmpfiles.d/nftban.conf

# 8. Check sysusers.d
cat /usr/lib/sysusers.d/nftban.conf
```

---

**Document Version:** 1.0
**Created:** 2025-10-29
**Status:** ✅ COMPLETE - READY FOR PACKAGE CREATION

═══════════════════════════════════════════════════════════════════
