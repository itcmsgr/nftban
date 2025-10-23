#!/bin/bash
# =============================================================================
# Example structure for jail templates
# This script creates the directory structure and example templates
# =============================================================================

# Directory structure:
# /etc/nftban/templates/fail2ban/
# ├── DEBIAN/
# │   ├── jail.d/
# │   │   ├── nftban-ssh.conf
# │   │   ├── nftban-apache.conf
# │   │   └── nftban-directadmin.conf
# │   ├── filter.d/
# │   │   ├── nftban-ssh.conf
# │   │   ├── nftban-apache.conf
# │   │   └── nftban-directadmin.conf
# │   └── action.d/
# │       └── (optional custom actions)
# └── REDHAT/
#     └── (same structure as DEBIAN)

# =============================================================================
# Example: /etc/nftban/templates/fail2ban/DEBIAN/jail.d/nftban-ssh.conf
# =============================================================================
# Create secure temp file
temp_ssh_jail=$(mktemp /tmp/nftban-ssh-jail.XXXXXX.conf) || {
    echo "ERROR: Failed to create temp file for SSH jail config" >&2
    exit 1
}
chmod 600 "$temp_ssh_jail"
trap "rm -f '$temp_ssh_jail'" EXIT

cat > "$temp_ssh_jail" << 'EOF'
[sshd]
enabled = true
port = ssh
filter = nftban-ssh
logpath = /var/log/auth.log
backend = systemd
maxretry = 3
findtime = 600
bantime = 1800
action = nftban-action[name=SSH, bantime=1800]
EOF

# =============================================================================
# Example: /etc/nftban/templates/fail2ban/DEBIAN/filter.d/nftban-ssh.conf
# =============================================================================
# Create secure temp file
temp_ssh_filter=$(mktemp /tmp/nftban-ssh-filter.XXXXXX.conf) || {
    echo "ERROR: Failed to create temp file for SSH filter config" >&2
    exit 1
}
chmod 600 "$temp_ssh_filter"
trap "rm -f '$temp_ssh_jail' '$temp_ssh_filter'" EXIT

cat > "$temp_ssh_filter" << 'EOF'
# Fail2Ban filter for SSH
# Based on standard sshd filter with nftban naming

[INCLUDES]
before = common.conf

[Definition]
_daemon = sshd
failregex = ^%(__prefix_line)s(?:error: PAM: )?[aA]uthentication (?:failure|error) for .* from <HOST>( via \S+)?\s*$
            ^%(__prefix_line)s(?:error: PAM: )?User not known to the underlying authentication module for .* from <HOST>\s*$
            ^%(__prefix_line)sFailed (?:password|publickey) for .* from <HOST>(?: port \d*)?(?: ssh\d*)?$
            ^%(__prefix_line)sROOT LOGIN REFUSED.* FROM <HOST>\s*$
            ^%(__prefix_line)s[iI](?:llegal|nvalid) user .* from <HOST>(?: port \d+)?\s*$
            ^%(__prefix_line)sUser .+ from <HOST> not allowed because not listed in AllowUsers\s*$
            ^%(__prefix_line)sauthentication failure; logname=\S* uid=\S* euid=\S* tty=\S* ruser=\S* rhost=<HOST>(?:\s+user=.*)?\s*$
            ^%(__prefix_line)srefused connect from \S+ \(<HOST>\)\s*$
            ^%(__prefix_line)sReceived disconnect from <HOST>: 3: .*: Auth fail$
            ^%(__prefix_line)sUser .+ from <HOST> not allowed because none of user's groups are listed in AllowGroups\s*$

ignoreregex = 

[Init]
journalmatch = _SYSTEMD_UNIT=sshd.service + _COMM=sshd
EOF

# =============================================================================
# Example: /etc/nftban/templates/fail2ban/DEBIAN/jail.d/nftban-apache.conf
# =============================================================================
# Create secure temp file
temp_apache_jail=$(mktemp /tmp/nftban-apache-jail.XXXXXX.conf) || {
    echo "ERROR: Failed to create temp file for Apache jail config" >&2
    exit 1
}
chmod 600 "$temp_apache_jail"
trap "rm -f '$temp_ssh_jail' '$temp_ssh_filter' '$temp_apache_jail'" EXIT

cat > "$temp_apache_jail" << 'EOF'
[apache-auth]
enabled = true
port = http,https
filter = nftban-apache-auth
logpath = /var/log/apache*/*error.log
backend = auto
maxretry = 5
findtime = 600
bantime = 3600
action = nftban-action[name=APACHE, bantime=3600]

[apache-badbots]
enabled = true
port = http,https
filter = nftban-apache-badbots
logpath = /var/log/apache*/*access.log
backend = auto
maxretry = 2
findtime = 600
bantime = 7200
action = nftban-action[name=APACHE, bantime=7200]

[apache-noscript]
enabled = true
port = http,https
filter = nftban-apache-noscript
logpath = /var/log/apache*/*access.log
backend = auto
maxretry = 3
findtime = 600
bantime = 3600
action = nftban-action[name=APACHE, bantime=3600]
EOF

# =============================================================================
# Example: /etc/nftban/templates/fail2ban/DEBIAN/filter.d/nftban-apache.conf
# =============================================================================
# Create secure temp file
temp_apache_filter=$(mktemp /tmp/nftban-apache-filter.XXXXXX.conf) || {
    echo "ERROR: Failed to create temp file for Apache filter config" >&2
    exit 1
}
chmod 600 "$temp_apache_filter"
trap "rm -f '$temp_ssh_jail' '$temp_ssh_filter' '$temp_apache_jail' '$temp_apache_filter'" EXIT

cat > "$temp_apache_filter" << 'EOF'
# Combined Apache filters for nftban

[nftban-apache-auth]
[INCLUDES]
before = common.conf

[Definition]
failregex = ^%(_apache_error_client)s (AH01617: )?user .* authentication failure for ".*": Password Mismatch$
            ^%(_apache_error_client)s (AH01618: )?user .* not found(: )?
            ^%(_apache_error_client)s (AH01614: )?client denied by server configuration:
            ^%(_apache_error_client)s (AH\d+: )?Authorization of user .* to access .* failed, reason: .*$

ignoreregex = 

[nftban-apache-badbots]
[INCLUDES]
before = botsearch-common.conf

[Definition]
failregex = ^<HOST> -.*"(GET|POST|HEAD).*HTTP.*"(?:%(badbotscombined)s|%(badbots)s)"$

ignoreregex = 

[nftban-apache-noscript]
[INCLUDES]
before = common.conf

[Definition]
failregex = ^<HOST> -.*"(GET|POST).*\.(php|asp|exe|pl|cgi|scgi)\??\s+HTTP/.*"$

ignoreregex =
EOF

# =============================================================================
# Example: /etc/nftban/templates/fail2ban/DEBIAN/jail.d/nftban-directadmin.conf
# =============================================================================
# Create secure temp file
temp_da_jail=$(mktemp /tmp/nftban-directadmin-jail.XXXXXX.conf) || {
    echo "ERROR: Failed to create temp file for DirectAdmin jail config" >&2
    exit 1
}
chmod 600 "$temp_da_jail"
trap "rm -f '$temp_ssh_jail' '$temp_ssh_filter' '$temp_apache_jail' '$temp_apache_filter' '$temp_da_jail'" EXIT

cat > "$temp_da_jail" << 'EOF'
[directadmin-login]
enabled = true
port = 2222
filter = nftban-directadmin
logpath = /var/log/directadmin/error.log
          /var/log/directadmin/system.log
backend = auto
maxretry = 5
findtime = 600
bantime = 3600
action = nftban-action[name=DIRECTADMIN, bantime=3600]
EOF

# =============================================================================
# Example: /etc/nftban/templates/fail2ban/DEBIAN/filter.d/nftban-directadmin.conf
# =============================================================================
# Create secure temp file
temp_da_filter=$(mktemp /tmp/nftban-directadmin-filter.XXXXXX.conf) || {
    echo "ERROR: Failed to create temp file for DirectAdmin filter config" >&2
    exit 1
}
chmod 600 "$temp_da_filter"
trap "rm -f '$temp_ssh_jail' '$temp_ssh_filter' '$temp_apache_jail' '$temp_apache_filter' '$temp_da_jail' '$temp_da_filter'" EXIT

cat > "$temp_da_filter" << 'EOF'
# Fail2Ban filter for DirectAdmin

[INCLUDES]
before = common.conf

[Definition]
failregex = ^.*: Incorrect password for .* from <HOST>\s*$
            ^.*: Failed authentication for .* from <HOST>\s*$
            ^.*: Login attempt from <HOST> .* failed\s*$
            ^.*brute_force_log.*<HOST>\s*$

ignoreregex = 

[Init]
datepattern = ^%%Y:%%m:%%d-%%H:%%M:%%S
EOF

# =============================================================================
# REDHAT versions (usually same as Debian, different log paths)
# =============================================================================
# Create secure temp file
temp_ssh_jail_redhat=$(mktemp /tmp/nftban-ssh-jail-redhat.XXXXXX.conf) || {
    echo "ERROR: Failed to create temp file for SSH jail RedHat config" >&2
    exit 1
}
chmod 600 "$temp_ssh_jail_redhat"
trap "rm -f '$temp_ssh_jail' '$temp_ssh_filter' '$temp_apache_jail' '$temp_apache_filter' '$temp_da_jail' '$temp_da_filter' '$temp_ssh_jail_redhat'" EXIT

cat > "$temp_ssh_jail_redhat" << 'EOF'
[sshd]
enabled = true
port = ssh
filter = nftban-ssh
logpath = /var/log/secure
backend = systemd
maxretry = 3
findtime = 600
bantime = 1800
action = nftban-action[name=SSH, bantime=1800]
EOF

echo "Example template files created in /tmp/"
echo "Files created:"
echo "  - nftban-ssh-jail.conf"
echo "  - nftban-ssh-filter.conf"
echo "  - nftban-apache-jail.conf"
echo "  - nftban-apache-filter.conf"
echo "  - nftban-directadmin-jail.conf"
echo "  - nftban-directadmin-filter.conf"
echo "  - nftban-ssh-jail-redhat.conf"
echo ""
echo "Copy these to the appropriate directories under:"
echo "/etc/nftban/templates/fail2ban/{DEBIAN|REDHAT}/{jail.d|filter.d}/"
