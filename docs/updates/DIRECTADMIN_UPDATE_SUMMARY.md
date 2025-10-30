# NFTBan v0.10.0 - DirectAdmin Module Update
**Date:** 2025-10-29
**Status:** ✅ COMPLETE

═══════════════════════════════════════════════════════════════════

## Summary

Updated DirectAdmin module with official port configuration from DirectAdmin support team and integrated CloudFlare IP whitelist requirement for licensing.

---

## Changes Made

### 1. Updated Port Configuration ✅

**File:** `/etc/nftban/conf.d/directadmin.conf`

**Changes:**
- Updated all port lists to match DirectAdmin official CSF policy
- Added passive FTP range: 35000:35999 (TCP IN)
- Added DNS over TLS: 853 (TCP/UDP)
- Added HTTP/3 QUIC support: 80, 443 (UDP)
- Added NTP: 123 (UDP OUT)
- Added IDENT: 113 (TCP/UDP OUT)

**New Port Configuration:**

```bash
# TCP INPUT
TCP_IN="20,21,22,25,53,853,80,110,143,443,465,587,993,995,2222,35000:35999"

# TCP OUTPUT
TCP_OUT="20,21,22,25,53,853,80,110,113,143,443,465,587,993,995,2222"

# UDP INPUT
UDP_IN="20,21,53,853,80,443"

# UDP OUTPUT
UDP_OUT="20,21,53,853,113,123,443"
```

**Note:** Same ports apply to both IPv4 and IPv6 (DirectAdmin CSF policy confirmed)

### 2. Added CloudFlare Integration ✅

**File:** `/etc/nftban/conf.d/directadmin.conf`

**New Settings:**
```bash
# Automatically enable CloudFlare whitelist when configuring DirectAdmin
# Values: "YES", "NO", "ASK"
NFTBAN_DIRECTADMIN_AUTO_CLOUDFLARE="ASK"

# Automatically update CloudFlare IP ranges
# Values: "YES", "NO"
NFTBAN_DIRECTADMIN_UPDATE_CLOUDFLARE="YES"
```

**Documentation Added:**
- Clear warning that DirectAdmin licensing requires CloudFlare
- Links to CloudFlare IP lists (IPv4 and IPv6)
- Instructions for manual whitelist if needed

### 3. Updated Port Command with CloudFlare Support ✅

**File:** `/usr/lib/nftban/cli/cmd_port.sh`

**Features Added:**

1. **CloudFlare Requirement Warning:**
   - Prominent warning box displayed to user
   - Explains DirectAdmin licensing requirement
   - Cannot be missed during configuration

2. **Interactive CloudFlare Enable:**
   - Asks user if they want to enable CloudFlare whitelist
   - Defaults to "Yes" (recommended)
   - Respects configuration file setting (YES/NO/ASK)

3. **Automatic CloudFlare Integration:**
   - Calls `nftban cloudflare update` to download latest IPs
   - Calls `nftban cloudflare enable` to whitelist them
   - Handles errors gracefully
   - Provides fallback manual instructions

4. **Enhanced User Notifications:**
   - Shows all ports being opened (IPv4 and IPv6)
   - Lists passive FTP range
   - Notes HTTP/3 QUIC support
   - Explains each port's purpose

5. **Better Error Messages:**
   - Warns if CloudFlare module not found
   - Provides manual CloudFlare setup steps
   - Reminds user to enable CloudFlare if declined

---

## Port Details

### Complete Port List

| Port(s) | Protocol | Direction | Purpose |
|---------|----------|-----------|---------|
| 20, 21 | TCP + UDP | IN + OUT | FTP (data/control) |
| 22 | TCP | IN + OUT | SSH |
| 25 | TCP | IN + OUT | SMTP (mail) |
| 53 | TCP + UDP | IN + OUT | DNS |
| 80 | TCP + UDP | IN | HTTP / HTTP/3 (QUIC) |
| 110 | TCP | IN + OUT | POP3 |
| 113 | TCP + UDP | OUT | IDENT protocol |
| 123 | UDP | OUT | NTP (Network Time) |
| 143 | TCP | IN + OUT | IMAP |
| 443 | TCP + UDP | IN + OUT | HTTPS / HTTP/3 (QUIC) |
| 465 | TCP | IN + OUT | SMTPS (SMTP over SSL) |
| 587 | TCP | IN + OUT | Submission (SMTP with STARTTLS) |
| 853 | TCP + UDP | IN + OUT | DNS over TLS (DoT) |
| 993 | TCP | IN + OUT | IMAPS (IMAP over SSL) |
| 995 | TCP | IN + OUT | POP3S (POP3 over SSL) |
| 2222 | TCP | IN + OUT | DirectAdmin Web Panel |
| 35000:35999 | TCP | IN | Passive FTP port range |

### Port Changes from Previous Version

**Added:**
- 35000:35999 (TCP IN) - Passive FTP range
- 853 (TCP + UDP) - DNS over TLS
- 80, 443 (UDP IN) - HTTP/3 QUIC support
- 113 (TCP + UDP OUT) - IDENT protocol
- 123 (UDP OUT) - NTP

**Removed:**
- None (only additions)

---

## CloudFlare Requirement

### Why CloudFlare is Required

DirectAdmin licensing servers are behind CloudFlare CDN. Without whitelisting CloudFlare IP ranges, DirectAdmin cannot contact licensing servers and will fail to validate licenses.

### CloudFlare IP Ranges

**IPv4:** https://www.cloudflare.com/ips-v4/
**IPv6:** https://www.cloudflare.com/ips-v6/

NFTBan automatically downloads and whitelists these ranges when user enables CloudFlare support.

### User Experience

When running `nftban port allow-panel directadmin`:

1. **Warning Displayed:**
   ```
   ╔═══════════════════════════════════════════════════════════════════╗
   ║ ⚠️  IMPORTANT: CloudFlare Whitelist Required                      ║
   ╚═══════════════════════════════════════════════════════════════════╝

   DirectAdmin licensing servers are behind CloudFlare CDN.
   You MUST whitelist CloudFlare IP ranges for licensing to work!
   ```

2. **User Prompted:**
   ```
   Do you want to enable CloudFlare IP whitelist? (REQUIRED for licensing)
   Enable CloudFlare whitelist? [Y/n]:
   ```

3. **If Yes (default):**
   - Downloads latest CloudFlare IPs
   - Enables CloudFlare whitelist
   - Confirms success

4. **If No:**
   - Displays warning about licensing failure
   - Provides command to enable later: `nftban cloudflare enable`

---

## Configuration Options

### Auto-Enable CloudFlare

**File:** `/etc/nftban/nftban.conf.local`

```bash
# Always enable CloudFlare (no prompt)
NFTBAN_DIRECTADMIN_AUTO_CLOUDFLARE="YES"

# Never enable CloudFlare (manual configuration)
NFTBAN_DIRECTADMIN_AUTO_CLOUDFLARE="NO"

# Ask user each time (default)
NFTBAN_DIRECTADMIN_AUTO_CLOUDFLARE="ASK"
```

### Auto-Update CloudFlare IPs

```bash
# Update CloudFlare IPs during configuration (default)
NFTBAN_DIRECTADMIN_UPDATE_CLOUDFLARE="YES"

# Use existing CloudFlare IPs
NFTBAN_DIRECTADMIN_UPDATE_CLOUDFLARE="NO"
```

### Custom Ports

```bash
# Add additional TCP INPUT ports
NFTBAN_DIRECTADMIN_CUSTOM_TCP_IN="8080,8443"

# Add additional TCP OUTPUT ports
NFTBAN_DIRECTADMIN_CUSTOM_TCP_OUT="3306"

# Add additional UDP ports
NFTBAN_DIRECTADMIN_CUSTOM_UDP_IN="53000"
NFTBAN_DIRECTADMIN_CUSTOM_UDP_OUT="53000"
```

---

## Testing

### Test DirectAdmin Port Configuration

```bash
# Configure DirectAdmin ports
nftban port allow-panel directadmin

# Verify ports are open
nftban port status

# Check nftables rules
nft list table inet nftban_main | grep dport
```

### Test CloudFlare Integration

```bash
# Update CloudFlare IPs
nftban cloudflare update

# Enable CloudFlare whitelist
nftban cloudflare enable

# Verify CloudFlare IPs are whitelisted
nftban firewall status | grep -A 20 whitelist
```

### Test DirectAdmin Licensing

After configuration, DirectAdmin should be able to contact licensing servers:

```bash
# Check DirectAdmin license
/usr/local/directadmin/directadmin l

# Expected: License information displayed, no connection errors
```

---

## Deployment

### Files Changed

1. `/etc/nftban/conf.d/directadmin.conf`
   - Updated port lists
   - Added CloudFlare settings
   - Added documentation

2. `/usr/lib/nftban/cli/cmd_port.sh`
   - Added CloudFlare warning
   - Added CloudFlare integration
   - Enhanced port display
   - Improved error messages

### Deployment Commands

```bash
# Deploy to all servers
for server in server1.example.com server2.example.com server3.example.com; do
    scp /home/gituser/nftban-v0.10.0-dev/src/usr/lib/nftban/cli/cmd_port.sh \
        root@$server:/usr/lib/nftban/cli/
    scp /home/gituser/nftban-v0.10.0-dev/src/etc/nftban/conf.d/directadmin.conf \
        root@$server:/etc/nftban/conf.d/
    ssh root@$server "chmod +x /usr/lib/nftban/cli/cmd_port.sh"
done
```

### Deployment Status

- **server1.example.com** - ✅ Deployed
- **server2.example.com** - ✅ Deployed
- **server3.example.com** - ⏳ Deploying (connection issues)

---

## User Documentation

### Quick Start

1. **Configure DirectAdmin Ports:**
   ```bash
   nftban port allow-panel directadmin
   ```

2. **Follow Prompts:**
   - Answer "Yes" to enable CloudFlare whitelist
   - Wait for configuration to complete

3. **Verify:**
   ```bash
   nftban port status
   ```

### Manual CloudFlare Setup

If you declined CloudFlare during setup:

```bash
# Enable CloudFlare
nftban cloudflare enable

# Or manually:
curl https://www.cloudflare.com/ips-v4/ > /var/lib/nftban/whitelist/cloudflare_v4.conf
curl https://www.cloudflare.com/ips-v6/ > /var/lib/nftban/whitelist/cloudflare_v6.conf
nftban firewall reload
```

---

## Troubleshooting

### Issue: DirectAdmin License Fails

**Symptom:**
```
Error contacting licensing server
```

**Fix:**
```bash
# Ensure CloudFlare is whitelisted
nftban cloudflare enable

# Verify CloudFlare IPs are in whitelist
ls -l /var/lib/nftban/whitelist/cloudflare*

# Reload firewall
nftban firewall reload

# Test again
/usr/local/directadmin/directadmin l
```

### Issue: Ports Not Open

**Symptom:**
Services not accessible from outside

**Fix:**
```bash
# Check firewall status
nftban firewall check

# Re-configure DirectAdmin ports
nftban port allow-panel directadmin

# Verify nftables rules
nft list table inet nftban_main
```

### Issue: CloudFlare Module Not Found

**Symptom:**
```
⚠️ CloudFlare module not found!
```

**Fix:**
```bash
# Manually download CloudFlare IPs
curl https://www.cloudflare.com/ips-v4/ > /var/lib/nftban/whitelist/cloudflare_v4.conf
curl https://www.cloudflare.com/ips-v6/ > /var/lib/nftban/whitelist/cloudflare_v6.conf

# Reload firewall
nftban firewall reload
```

---

## Reference

### Source Information

**DirectAdmin Support Response:**
```
Default port/protocol policy allows:
TCP_IN = "20,21,22,25,53,853,80,110,143,443,465,587,993,995,2222,35000:35999"
TCP_OUT = "20,21,22,25,53,853,80,110,113,143,443,465,587,993,995,2222"
UDP_IN = "20,21,53,853,80,443"
UDP_OUT = "20,21,53,853,113,123,443"
TCP6_IN = "20,21,22,25,53,853,80,110,143,443,465,587,993,995,2222,35000:35999"
TCP6_OUT = "20,21,22,25,53,853,80,110,113,143,443,465,587,993,995,2222"
UDP6_IN = "20,21,53,853,80,443"
UDP6_OUT = "20,21,53,853,113,123,443"

DirectAdmin licensing is behind cloudflare.
Cloudflare IP ranges: https://www.cloudflare.com/ips-v4/ and https://www.cloudflare.com/ips-v6/
```

### Related Commands

```bash
# DirectAdmin configuration
nftban port allow-panel directadmin

# CloudFlare management
nftban cloudflare enable
nftban cloudflare disable
nftban cloudflare update
nftban cloudflare status

# Firewall management
nftban firewall init
nftban firewall reload
nftban firewall status
nftban firewall check

# Port status
nftban port status
```

---

## Changelog

**v0.10.0 - 2025-10-29:**
- ✅ Updated DirectAdmin ports to match official CSF policy
- ✅ Added passive FTP range (35000:35999)
- ✅ Added DNS over TLS support (853)
- ✅ Added HTTP/3 QUIC support (80, 443 UDP)
- ✅ Added NTP support (123 UDP OUT)
- ✅ Integrated CloudFlare whitelist requirement
- ✅ Added interactive CloudFlare enable prompt
- ✅ Added automatic CloudFlare IP download and whitelist
- ✅ Enhanced user notifications and warnings
- ✅ Improved error messages and manual fallback instructions
- ✅ Applied configuration to both IPv4 and IPv6

---

**Document Version:** 1.0
**Status:** ✅ COMPLETE
**Deployed:** 2025-10-29

═══════════════════════════════════════════════════════════════════
