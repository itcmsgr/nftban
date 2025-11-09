#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.32.24 - Mail Core Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Email sending mechanism for all NFTBan modules
#
# meta:name=nftban_mail
# meta:type=core
# meta:header=Mail Module
# meta:version=0.32.24
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Provides email sending capabilities for all modules
# meta:input=Email content (text or file path), recipient
# meta:output=Sent emails with HTML templates
#
# **Inventory & Requirements**
# meta:depends=bash,sendmail,nft,hostname
#
# meta:created_date=2025-11-05
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# MAIL SYSTEM DETECTION
# =============================================================================

nftban_mail_detect_mta() {
    # Detect available Mail Transfer Agent
    # Returns: "postfix", "sendmail", "exim", "msmtp", "mailx", or "none"

    # Check Postfix (highest priority)
    if [[ -x /usr/sbin/postfix ]]; then
        if systemctl is-active postfix &>/dev/null 2>&1 || pgrep -x master &>/dev/null; then
            echo "postfix"
            return 0
        fi
    fi

    # Check Sendmail
    if [[ -x /usr/sbin/sendmail ]]; then
        if pgrep -x sendmail &>/dev/null || [[ -f /var/run/sendmail.pid ]]; then
            echo "sendmail"
            return 0
        fi
        # Sendmail binary exists even if not running - check if it's actually sendmail or postfix wrapper
        if /usr/sbin/sendmail -bv root &>/dev/null; then
            echo "sendmail"
            return 0
        fi
    fi

    # Check Exim
    if [[ -x /usr/sbin/exim ]] || [[ -x /usr/sbin/exim4 ]]; then
        if pgrep -x exim &>/dev/null || systemctl is-active exim4 &>/dev/null 2>&1; then
            echo "exim"
            return 0
        fi
    fi

    # Check msmtp
    if [[ -x /usr/bin/msmtp ]] && [[ -f /etc/msmtprc || -f ~/.msmtprc ]]; then
        echo "msmtp"
        return 0
    fi

    # Check mailx (basic fallback)
    if [[ -x /usr/bin/mailx ]] || [[ -x /bin/mailx ]]; then
        echo "mailx"
        return 0
    fi

    # No mail system found
    echo "none"
    return 1
}

# =============================================================================
# MAIL STATUS CHECKING
# =============================================================================

nftban_mail_check_status() {
    # Check if mail system is available and working
    # Returns: Exit code 0=OK, 1=not found, 2=not running, 3=ports blocked

    local mta
    mta="$(nftban_mail_detect_mta)"

    if [[ "$mta" == "none" ]]; then
        echo "✗ Mail system not found"
        return 1
    fi

    # Check if mail daemon is running (for postfix/sendmail/exim)
    case "$mta" in
        postfix)
            if ! systemctl is-active postfix &>/dev/null && ! pgrep -x master &>/dev/null; then
                echo "✗ Postfix is installed but not running"
                return 2
            fi
            ;;
        sendmail)
            if ! pgrep -x sendmail &>/dev/null; then
                echo "⚠ Sendmail binary available but daemon may not be running"
                # Don't fail - sendmail can work without daemon for outbound
            fi
            ;;
        exim)
            if ! pgrep -x exim &>/dev/null && ! systemctl is-active exim4 &>/dev/null 2>&1; then
                echo "✗ Exim is installed but not running"
                return 2
            fi
            ;;
    esac

    # Check if mail ports are blocked (basic check for port 25 outbound)
    if command -v nft &>/dev/null; then
        local ruleset
        ruleset="$(nft list ruleset 2>/dev/null || true)"

        # Check if port 25 is explicitly blocked outbound
        if echo "$ruleset" | grep -qE "tcp dport 25.*drop|tcp dport 25.*reject"; then
            echo "⚠ Mail port 25 may be blocked in firewall"
            # Don't fail - other ports might work
        fi
    fi

    echo "✓ Mail System: $mta (ready)"
    return 0
}

# =============================================================================
# MAIL PORT CHECKING
# =============================================================================

nftban_mail_check_ports() {
    # Check mail ports in nftables
    # Shows which ports are allowed/blocked

    if ! command -v nft &>/dev/null; then
        echo "⚠ nft command not found - cannot check firewall ports"
        return 1
    fi

    local ruleset
    ruleset="$(nft list ruleset 2>/dev/null || true)"

    if [[ -z "$ruleset" ]]; then
        echo "⚠ No nftables rules found"
        return 1
    fi

    # Define mail ports to check
    declare -A MAIL_PORTS=(
        [25]="SMTP (outbound)"
        [587]="Submission (outbound)"
        [465]="SMTPS (outbound)"
        [143]="IMAP (inbound)"
        [993]="IMAPS (inbound)"
        [110]="POP3 (inbound)"
        [995]="POP3S (inbound)"
    )

    echo "Mail Port Firewall Status:"

    for port in 25 587 465 143 993 110 995; do
        local status="unknown"
        local desc="${MAIL_PORTS[$port]}"

        # Check for explicit accept
        if echo "$ruleset" | grep -qE "tcp dport $port.*accept"; then
            status="${NFTBAN_COLOR_GREEN}✓${NFTBAN_COLOR_RESET} Allowed"
        # Check for explicit drop/reject
        elif echo "$ruleset" | grep -qE "tcp dport $port.*(drop|reject)"; then
            status="${NFTBAN_COLOR_RED}✗${NFTBAN_COLOR_RESET} Blocked"
        else
            status="${NFTBAN_COLOR_YELLOW}?${NFTBAN_COLOR_RESET} No-rule"
        fi

        printf "  Port %-4s %-25s %s\n" "$port" "($desc)" "$status"
    done

    echo ""
    echo "Legend: ✓ allowed   ✗ blocked   ? no-rule (default policy applies)"
}

# =============================================================================
# EMAIL VALIDATION
# =============================================================================

nftban_mail_validate_address() {
    # Validate email address format
    # Args: $1 = email address
    # Returns: 0 if valid, 1 if invalid

    local email="$1"

    # RFC 5322 simplified regex
    if [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 0
    else
        return 1
    fi
}

# =============================================================================
# FILE PATH VALIDATION
# =============================================================================

nftban_mail_validate_path() {
    # Validate file path is allowed to be sent
    # Args: $1 = file path
    # Returns: 0 if allowed, 1 if not allowed

    local file="$1"
    local allowed_paths="${NFTBAN_MAIL_ALLOWED_PATHS:-/var/lib/nftban}"

    # Must be absolute path
    if [[ ! "$file" =~ ^/ ]]; then
        [[ "${NFTBAN_MAIL_DEBUG:-false}" == "true" ]] && echo "[DEBUG] Not an absolute path: $file" >&2
        return 1
    fi

    # File must exist and be readable
    if [[ ! -f "$file" ]] || [[ ! -r "$file" ]]; then
        [[ "${NFTBAN_MAIL_DEBUG:-false}" == "true" ]] && echo "[DEBUG] File not found or not readable: $file" >&2
        return 1
    fi

    # Check file size
    local max_size="${NFTBAN_MAIL_MAX_FILE_SIZE:-10240}"  # KB
    local file_size
    file_size="$(du -k "$file" | cut -f1)"

    if (( file_size > max_size )); then
        [[ "${NFTBAN_MAIL_DEBUG:-false}" == "true" ]] && echo "[DEBUG] File too large: ${file_size}KB > ${max_size}KB" >&2
        return 1
    fi

    # Check against allowed paths
    local path_allowed=0
    IFS=':' read -ra PATHS <<< "$allowed_paths"
    for path in "${PATHS[@]}"; do
        if [[ "$file" == "$path"* ]]; then
            path_allowed=1
            break
        fi
    done

    if (( path_allowed == 0 )); then
        [[ "${NFTBAN_MAIL_DEBUG:-false}" == "true" ]] && echo "[DEBUG] File not in allowed paths: $file" >&2
        return 1
    fi

    return 0
}

# =============================================================================
# TEMPLATE LOADING
# =============================================================================

nftban_mail_load_template() {
    # Load HTML email template
    # Args: $1 = template name (header/footer/test)
    # Returns: template content via stdout

    local template_name="$1"
    local template_dir="${NFTBAN_SHARE_DIR:-/usr/share/nftban}/templates/mail"
    local template_file="${template_dir}/${template_name}.html"

    # Check if custom template exists
    if [[ -f "$template_file" ]] && [[ -r "$template_file" ]]; then
        cat "$template_file"
        return 0
    fi

    # Fallback to inline templates if file not found
    case "$template_name" in
        header_default)
            cat <<'EOF'
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>NFTBan - {SUBJECT}</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 0; padding: 20px; background-color: #f5f5f5; }
        .container { max-width: 800px; margin: 0 auto; background-color: white; padding: 30px; border-radius: 5px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .header { text-align: center; margin-bottom: 30px; border-bottom: 2px solid #0066cc; padding-bottom: 20px; }
        .logo { max-width: 200px; margin-bottom: 10px; }
        h1 { color: #333; margin: 10px 0; }
        .server-info { color: #666; font-size: 14px; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            {LOGO_HTML}
            <h1>🛡️ NFTBan Security System</h1>
            <div class="server-info">
                {COMPANY_NAME}<br>
                Server: {HOSTNAME}<br>
                {VERSION_HTML}
            </div>
        </div>
        <div class="content">
EOF
            ;;

        footer_default)
            cat <<'EOF'
        </div>
        <div style="margin-top: 40px; padding-top: 20px; border-top: 1px solid #ddd; text-align: center; color: #666; font-size: 12px;">
            <p>Generated by NFTBan {NFTBAN_VERSION} on {DATE} at {TIME}</p>
            <p>{COMPANY_NAME}</p>
            <p style="font-style: italic;">This is an automated email from your NFTBan security system.</p>
            <p>Server: {HOSTNAME} | IP: {SERVER_IP}</p>
        </div>
    </div>
</body>
</html>
EOF
            ;;

        *)
            echo "<!-- Template not found: $template_name -->"
            return 1
            ;;
    esac
}

# =============================================================================
# TEMPLATE VARIABLE REPLACEMENT
# =============================================================================

nftban_mail_template_replace() {
    # Replace template variables in content
    # Args: $1 = content (via stdin or arg)
    # Returns: content with variables replaced via stdout

    local content
    if [[ -n "${1:-}" ]]; then
        content="$1"
    else
        content="$(cat)"
    fi

    # Get values
    local hostname_val
    hostname_val="$(hostname -f 2>/dev/null || hostname)"

    local server_ip
    server_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")"

    local date_val
    date_val="$(date +%Y-%m-%d)"

    local time_val
    time_val="$(date +%H:%M:%S)"

    local company_name="${NFTBAN_COMPANY_NAME:-}"
    local logo_location="${NFTBAN_LOGO_LOCATION:-}"

    # Build logo HTML
    local logo_html=""
    if [[ -n "$logo_location" ]]; then
        logo_html="<img src=\"${logo_location}\" alt=\"Logo\" class=\"logo\">"
    fi

    # Build version HTML
    local version_html=""
    if [[ "${NFTBAN_VERSION_INCLUDE:-YES}" == "YES" ]]; then
        version_html="Version: ${NFTBAN_VERSION:-0.32.1}"
    fi

    # Replace variables
    content="${content//\{NFTBAN_VERSION\}/${NFTBAN_VERSION:-0.32.1}}"
    content="${content//\{HOSTNAME\}/$hostname_val}"
    content="${content//\{SERVER_IP\}/$server_ip}"
    content="${content//\{DATE\}/$date_val}"
    content="${content//\{TIME\}/$time_val}"
    content="${content//\{COMPANY_NAME\}/$company_name}"
    content="${content//\{LOGO_HTML\}/$logo_html}"
    content="${content//\{VERSION_HTML\}/$version_html}"
    content="${content//\{SENDER\}/${NFTBAN_SENDER:-nftban@$hostname_val}}"
    content="${content//\{MAIL_RECIPIENT\}/${NFTBAN_MAIL_RECIPIENT:-}}"

    # Detect MTA for template
    local mta
    mta="$(nftban_mail_detect_mta)"
    content="${content//\{MAIL_SYSTEM\}/$mta}"

    echo "$content"
}

# =============================================================================
# SEND EMAIL (MAIN FUNCTION)
# =============================================================================

nftban_mail_send() {
    # Send email with content
    # Args: $1 = content (text or file path)
    #       $2 = recipient (optional, uses default if omitted)

    local content_arg="${1:-}"
    local recipient="${2:-${NFTBAN_MAIL_RECIPIENT:-}}"

    # Validate recipient
    if [[ -z "$recipient" ]]; then
        echo "Error: No recipient specified and no default recipient configured" >&2
        return 1
    fi

    if [[ "${NFTBAN_MAIL_VALIDATE_RECIPIENTS:-YES}" == "YES" ]]; then
        if ! nftban_mail_validate_address "$recipient"; then
            echo "Error: Invalid email address: $recipient" >&2
            return 1
        fi
    fi

    # Determine if content is a file or text
    local is_file=0
    local content_text=""
    local content_html=""

    if [[ -f "$content_arg" ]]; then
        # It's a file
        if nftban_mail_validate_path "$content_arg"; then
            is_file=1
            content_text="$(cat "$content_arg")"
        else
            echo "Error: File not allowed to be sent: $content_arg" >&2
            return 1
        fi
    else
        # It's text
        content_text="$content_arg"
    fi

    # Build HTML email if enabled
    if [[ "${NFTBAN_MAIL_USE_HTML:-YES}" == "YES" ]]; then
        local header footer
        header="$(nftban_mail_load_template "header_default")"
        footer="$(nftban_mail_load_template "footer_default")"

        # Combine and replace variables
        content_html="${header}${content_text}${footer}"
        content_html="$(nftban_mail_template_replace "$content_html")"
    else
        content_html="$content_text"
    fi

    # Prepare email
    local sender="${NFTBAN_SENDER:-nftban@$(hostname -f)}"
    local from_name="${NFTBAN_FROM_NAME:-NFTBan Security System}"
    local subject_prefix="${NFTBAN_MAIL_SUBJECT_PREFIX:-[NFTBan]}"
    local subject="${subject_prefix} Report from $(hostname -f)"

    # Detect mail command
    local mta
    mta="$(nftban_mail_detect_mta)"

    if [[ "$mta" == "none" ]]; then
        echo "Error: No mail system available" >&2
        return 1
    fi

    # Send email using detected MTA
    case "$mta" in
        postfix|sendmail)
            # Use sendmail command
            if [[ "${NFTBAN_MAIL_DEBUG:-false}" == "true" ]]; then
                echo "[DEBUG] Sending via sendmail to: $recipient"
                echo "[DEBUG] Subject: $subject"
            fi

            /usr/sbin/sendmail -t <<EOF
From: ${from_name} <${sender}>
To: ${recipient}
Subject: ${subject}
Content-Type: text/html; charset=UTF-8
MIME-Version: 1.0

${content_html}
EOF
            ;;

        exim)
            # Use exim
            if [[ "${NFTBAN_MAIL_DEBUG:-false}" == "true" ]]; then
                echo "[DEBUG] Sending via exim to: $recipient"
            fi

            echo "$content_html" | /usr/sbin/exim -t <<EOF
From: ${from_name} <${sender}>
To: ${recipient}
Subject: ${subject}
Content-Type: text/html; charset=UTF-8

EOF
            ;;

        msmtp)
            # Use msmtp
            if [[ "${NFTBAN_MAIL_DEBUG:-false}" == "true" ]]; then
                echo "[DEBUG] Sending via msmtp to: $recipient"
            fi

            /usr/bin/msmtp -t <<EOF
From: ${from_name} <${sender}>
To: ${recipient}
Subject: ${subject}
Content-Type: text/html; charset=UTF-8

${content_html}
EOF
            ;;

        mailx)
            # Use mailx (basic, may not support HTML well)
            if [[ "${NFTBAN_MAIL_DEBUG:-false}" == "true" ]]; then
                echo "[DEBUG] Sending via mailx to: $recipient"
                echo "[DEBUG] Warning: mailx may not support HTML emails properly"
            fi

            echo "$content_html" | mailx -s "$subject" -r "$sender" "$recipient"
            ;;
    esac

    local send_result=$?

    if (( send_result == 0 )); then
        echo "✓ Email sent successfully to: $recipient"

        # Save sent email if debugging
        if [[ -n "${NFTBAN_MAIL_SAVE_SENT:-}" ]] && [[ -d "${NFTBAN_MAIL_SAVE_SENT}" ]]; then
            local save_file="${NFTBAN_MAIL_SAVE_SENT}/sent_$(date +%Y%m%d_%H%M%S).html"
            echo "$content_html" > "$save_file"
            echo "  (Saved to: $save_file)"
        fi

        return 0
    else
        echo "✗ Failed to send email" >&2
        return 1
    fi
}

# =============================================================================
# SEND TEST EMAIL
# =============================================================================

nftban_mail_send_test() {
    # Send test email
    # Args: $1 = recipient (optional, uses default if omitted)

    local recipient="${1:-${NFTBAN_MAIL_RECIPIENT:-}}"

    if [[ -z "$recipient" ]]; then
        echo "Error: No recipient specified and no default recipient configured" >&2
        return 1
    fi

    echo "Sending test email..."
    echo "  From: ${NFTBAN_SENDER:-nftban@$(hostname -f)}"
    echo "  To: $recipient"
    echo "  Subject: ${NFTBAN_MAIL_SUBJECT_PREFIX:-[NFTBan]} Test Email from $(hostname -f)"
    echo ""

    # Build test email content
    local mta
    mta="$(nftban_mail_detect_mta)"

    local test_content
    test_content=$(cat <<EOF
<h2 style="color: #0066cc;">✅ Test Email Successful</h2>
<p>This is a test email from your NFTBan security system.</p>
<p><strong>If you received this email, your mail configuration is working correctly.</strong></p>

<h3>System Information:</h3>
<ul>
    <li>Server: {HOSTNAME}</li>
    <li>Mail System: ${mta}</li>
    <li>NFTBan Version: {NFTBAN_VERSION}</li>
    <li>Test Time: {DATE} {TIME}</li>
</ul>

<h3>Mail Configuration:</h3>
<ul>
    <li>From: {SENDER}</li>
    <li>Default Recipient: {MAIL_RECIPIENT}</li>
    <li>Template: Default HTML</li>
</ul>

<p style="margin-top: 20px;">You can customize email templates at:</p>
<code>/usr/share/nftban/templates/mail/</code>
EOF
)

    # Send using main send function
    nftban_mail_send "$test_content" "$recipient"
}

# =============================================================================
# SHOW HELP
# =============================================================================

nftban_mail_show_help() {
    # Show mail module help

    # Load output module for standard banner
    if [[ $(type -t nftban_banner) != "function" ]]; then
        source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_output.sh"
    fi
    nftban_banner

    local mta
    mta="$(nftban_mail_detect_mta)"

    cat <<EOF

Available Mail System:
  MTA: $mta
  Command: $(command -v sendmail 2>/dev/null || echo "not found")
  Status: $(nftban_mail_check_status 2>&1 | head -1)

Usage:
  nftban mail status              # Check mail system status
  nftban mail port-status         # Check firewall ports
  nftban mail test [email]        # Send test email
  nftban mail {content} {email}   # Send email with content

Examples:
  # Send test to default recipient
  nftban mail test

  # Send test to custom email
  nftban mail test admin@example.com

  # Send text message
  nftban mail "Server restarted at \$(date)" admin@example.com

  # Send file content (wrapped with HTML template)
  nftban mail /var/lib/nftban/reports/daily.html admin@example.com

Configuration: /etc/nftban/conf.d/mail.conf
Default Recipient: ${NFTBAN_MAIL_RECIPIENT:-not configured}

EOF
}

# =============================================================================
# MODULE FOOTER
# =============================================================================

# Module loaded notification (only in debug mode)
if [[ "${NFTBAN_DEBUG_MODE:-false}" == "true" ]]; then
    nftban_module_loaded "nftban_mail" "1.0.0" "Mail Module" "core" "bash,sendmail,nft"
fi
