# NFTBan Groups Reference

## Overview

NFTBan uses system groups for access control and privilege management. All groups follow the `nftban-*` naming convention for clarity and traceability.

---

## Groups

### `nftban` (Primary Group)

**Purpose**: Primary group for the nftban system user

**Created**: Automatically during package installation
**Type**: System group
**Members**: `nftban` user only

**Used For**:
- File ownership (`/var/lib/nftban`, `/var/log/nftban`)
- Service execution
- Systemd service isolation

**Do Not**: Add regular users to this group

---

### `nftban-cli` (CLI Access Group)

**Purpose**: Grants non-root users permission to manage NFTBan via CLI

**Created**: Automatically during package installation
**Type**: System group
**Members**: Administrators who need full NFTBan management access

**Permissions Granted**:
- Execute all `nftban` commands
- Manage firewall rules (ban, unban, whitelist)
- Configure services
- View logs and statistics
- Run administrative commands

**Add Users**:
```bash
# Add user to nftban-cli group
sudo usermod -aG nftban-cli username

# Verify membership
id username | grep nftban-cli
```

**Authorization**: Via Polkit rules (`60-nftban-cli.rules`)

---

### `nftban-auditors` (Inventory Helpers Group)

**Purpose**: Grants non-root users permission to run v0.30.0 inventory helpers

**Created**: Automatically during package installation
**Type**: System group
**Members**: Security auditors, monitoring users who need read-only system inventory access

**Permissions Granted**:
- `/usr/libexec/nftban/nftban-procnet` - Process and network inventory
- `/usr/libexec/nftban/nftban-pkgs` - Package inventory
- `/usr/libexec/nftban/nftban-verify` - Tamper detection
- `/usr/libexec/nftban/nftban-firewall` - Firewall state export

**Add Users**:
```bash
# Add user to nftban-auditors group
sudo usermod -aG nftban-auditors username

# Test access
pkexec /usr/libexec/nftban/nftban-procnet
```

**Authorization**: Via Polkit rules (`50-nftban-v030.rules`)

**Use Cases**:
- Security auditing
- Compliance reporting
- System inventory collection
- Monitoring integrations

---

## Group Hierarchy

```
nftban (system)
  └─ Used by: nftban service

nftban-cli (admin)
  └─ Full management access
  └─ For: System administrators

nftban-auditors (read-only)
  └─ Inventory collection only
  └─ For: Security auditors, monitoring
```

---

## Implementation

### Package Installation

Groups are created automatically:

**RPM (Rocky/Alma/Fedora)**:
- Via `sysusers.d/nftban.conf`
- Processed by `%sysusers_create_compat` in %pre

**DEB (Ubuntu/Debian)**:
- Via `postinst` script
- Runs during `apt install`

### Configuration Files

| File | Purpose |
|------|---------|
| `/usr/lib/sysusers.d/nftban.conf` | System user/group definitions (RPM) |
| `/usr/share/polkit-1/rules.d/60-nftban-cli.rules` | nftban-cli authorization |
| `/usr/share/polkit-1/rules.d/50-nftban-v030.rules` | nftban-auditors authorization |

---

## Security Considerations

### Principle of Least Privilege

- **nftban**: Service account only, no login
- **nftban-cli**: Full access, use sparingly
- **nftban-auditors**: Read-only inventory, no write access

### Best Practices

1. **Limit nftban-cli membership**: Only trusted administrators
2. **Use nftban-auditors for monitoring**: Safer than root access
3. **Regular audit**: Review group membership periodically
4. **Logging**: All actions logged to `/var/log/nftban/`

### What NOT to Do

❌ Add service accounts to `nftban-cli`
❌ Use `nftban-auditors` for administrative tasks
❌ Grant both groups to same user (unless necessary)

---

## Troubleshooting

### Check Group Membership
```bash
# List all nftban groups
getent group | grep nftban

# Check specific group
getent group nftban-cli

# Check user's groups
groups username
```

### Test Permissions
```bash
# Test nftban-cli access
nftban health check

# Test nftban-auditors access
pkexec /usr/libexec/nftban/nftban-procnet
```

### Common Issues

**"Permission denied" errors**:
1. Verify group membership: `groups`
2. Log out and back in (group changes require new session)
3. Check Polkit rules: `pkaction | grep nftban`

**Group not created**:
1. Check package installation logs
2. Manually create: `sudo groupadd -r nftban-cli`
3. Reinstall package

---

## Version History

| Version | Groups | Notes |
|---------|--------|-------|
| v0.10.0 | `nftban`, `nftban-cli` | Initial groups |
| v0.30.0 | `nftban-auditors` added | Inventory helpers support |

---

## See Also

- [Security Documentation](SECURITY.md)
- [Polkit Configuration](architecture/polkit.md)
- [Installation Guide](guides/install.md)
- [User Management](guides/user-management.md)

---

**Last Updated**: 2025-11-04
**Version**: v0.30.0
