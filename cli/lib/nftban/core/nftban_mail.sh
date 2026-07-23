#!/usr/bin/env bash
# =============================================================================
# NFTBan - Mail Core Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Email sending mechanism for all NFTBan modules
#
# meta:name="nftban_mail"
# meta:type="module"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2025-11-05"
#
# meta:description="Provides email sending capabilities for all modules"
# meta:input="Email content (text or file path), recipient"
# meta:output="Sent emails with HTML templates"
# meta:depends="bash,sendmail,hostname,curl"
#
# meta:inventory.files=""
# meta:inventory.binaries="sendmail,postfix,exim,msmtp,curl,mailx,hostname"
# meta:inventory.env_vars="NFTBAN_MAIL_METHOD,NFTBAN_MAIL_RECIPIENT,NFTBAN_MAIL_FROM,NFTBAN_MAIL_SMTP_HOST,NFTBAN_MAIL_SMTP_PORT,NFTBAN_MAIL_SMTP_USER,NFTBAN_MAIL_SMTP_PASS"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network="SMTP server (if configured)"
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail

# Guard against multiple sourcing
[[ -n "${NFTBAN_MAIL_LOADED:-}" ]] && return 0
readonly NFTBAN_MAIL_LOADED=1

# =============================================================================
# SOURCE SHARED LIBRARIES
# =============================================================================

# Source timestamp library for unified date/time formatting
# shellcheck source=/dev/null
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_timestamp.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_timestamp.sh" || return 1
fi

# =============================================================================
# CONFIGURABLE MAIL BINARY PATHS
# =============================================================================
# These can be overridden via environment variables for non-standard locations
: "${NFTBAN_SENDMAIL_BIN:=/usr/sbin/sendmail}"
: "${NFTBAN_POSTFIX_BIN:=/usr/sbin/postfix}"
: "${NFTBAN_EXIM_BIN:=/usr/sbin/exim}"
: "${NFTBAN_EXIM4_BIN:=/usr/sbin/exim4}"
: "${NFTBAN_MSMTP_BIN:=/usr/bin/msmtp}"
: "${NFTBAN_MAILX_BIN:=/usr/bin/mailx}"
: "${NFTBAN_MAILX_ALT_BIN:=/bin/mailx}"

# =============================================================================
# MAIL SYSTEM DETECTION
# =============================================================================

nftban_mail_detect_mta() {
    # Detect available Mail Transfer Agent
    # Returns: "postfix", "sendmail", "exim", "msmtp", "curl", "mailx", or "none"
    #
    # Priority order:
    #   1. postfix (local MTA, fastest)
    #   2. sendmail (local MTA)
    #   3. exim (local MTA)
    #   4. msmtp (lightweight relay)
    #   5. curl (direct SMTP - no local MTA needed)
    #   6. mailx (basic fallback)
    #
    # Force specific method via NFTBAN_MAIL_METHOD config

    # If user explicitly set a method, use it (after checking availability)
    if [[ -n "${NFTBAN_MAIL_METHOD:-}" ]]; then
        case "${NFTBAN_MAIL_METHOD}" in
            postfix|sendmail|exim|msmtp|curl|mailx|emulate)
                # Verify the requested method is available
                if _nftban_mail_method_available "${NFTBAN_MAIL_METHOD}"; then
                    echo "${NFTBAN_MAIL_METHOD}"
                    return 0
                else
                    [[ "${NFTBAN_MAIL_DEBUG:-false}" == "true" ]] && \
                        echo "[DEBUG] Requested method ${NFTBAN_MAIL_METHOD} not available, auto-detecting" >&2
                fi
                ;;
        esac
    fi

    # A1 central-comms (prefer-explicit-SMTP): if the operator configured an SMTP relay
    # (NFTBAN_SMTP_HOST) and did NOT force a method, prefer daemonless curl-SMTP over an
    # incidentally-present local MTA. This gives predictable delivery via the operator's
    # chosen relay instead of e.g. a panel's local postfix/greylisting. Explicit
    # NFTBAN_MAIL_METHOD still wins (handled above). Honors NO_LOCAL_MAIL_DAEMON_REQUIREMENT.
    if [[ -z "${NFTBAN_MAIL_METHOD:-}" && -n "${NFTBAN_SMTP_HOST:-}" ]] && command -v curl &>/dev/null; then
        echo "curl"
        return 0
    fi

    # Auto-detect: Check Postfix (highest priority - local MTA)
    if [[ -x "$NFTBAN_POSTFIX_BIN" ]]; then
        if systemctl is-active postfix &>/dev/null 2>&1 || pgrep -x master &>/dev/null; then
            echo "postfix"
            return 0
        fi
    fi

    # Check Sendmail
    if [[ -x "$NFTBAN_SENDMAIL_BIN" ]]; then
        if pgrep -x sendmail &>/dev/null || [[ -f /var/run/sendmail.pid ]]; then
            echo "sendmail"
            return 0
        fi
        # Sendmail binary exists even if not running - check if it's actually sendmail or postfix wrapper
        if "$NFTBAN_SENDMAIL_BIN" -bv root &>/dev/null; then
            echo "sendmail"
            return 0
        fi
    fi

    # Check Exim
    if [[ -x "$NFTBAN_EXIM_BIN" ]] || [[ -x "$NFTBAN_EXIM4_BIN" ]]; then
        if pgrep -x exim &>/dev/null || systemctl is-active exim4 &>/dev/null 2>&1; then
            echo "exim"
            return 0
        fi
    fi

    # Check msmtp (lightweight SMTP relay client)
    if [[ -x "$NFTBAN_MSMTP_BIN" ]] && [[ -f /etc/msmtprc || -f ~/.msmtprc ]]; then
        echo "msmtp"
        return 0
    fi

    # Check curl with SMTP config (direct SMTP - no local MTA required)
    if command -v curl &>/dev/null && [[ -n "${NFTBAN_SMTP_HOST:-}" ]]; then
        echo "curl"
        return 0
    fi

    # Check mailx (basic fallback)
    if [[ -x "$NFTBAN_MAILX_BIN" ]] || [[ -x "$NFTBAN_MAILX_ALT_BIN" ]]; then
        echo "mailx"
        return 0
    fi

    # No mail system found
    echo "none"
    return 1
}

# Helper: Check if specific mail method is available
_nftban_mail_method_available() {
    local method="$1"
    case "$method" in
        postfix)
            [[ -x "$NFTBAN_POSTFIX_BIN" ]] && \
                (systemctl is-active postfix &>/dev/null 2>&1 || pgrep -x master &>/dev/null)
            ;;
        sendmail)
            [[ -x "$NFTBAN_SENDMAIL_BIN" ]]
            ;;
        exim)
            [[ -x "$NFTBAN_EXIM_BIN" ]] || [[ -x "$NFTBAN_EXIM4_BIN" ]]
            ;;
        msmtp)
            [[ -x "$NFTBAN_MSMTP_BIN" ]] && [[ -f /etc/msmtprc || -f ~/.msmtprc ]]
            ;;
        curl)
            command -v curl &>/dev/null && [[ -n "${NFTBAN_SMTP_HOST:-}" ]]
            ;;
        mailx)
            [[ -x "$NFTBAN_MAILX_BIN" ]] || [[ -x "$NFTBAN_MAILX_ALT_BIN" ]]
            ;;
        emulate)
            # A1b: the emulated transport is always available (no binary, no network) —
            # it records the delivery attempt to a sink for CI/lab validation.
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# A1b central-comms emulation: record a delivery ATTEMPT to a sink instead of sending.
# Same central flow, minus the real transport and the network. NEVER writes secrets.
# Sink: $NFTBAN_MAIL_EMULATE_SINK, else <data>/mail/test-delivery.jsonl.
_mail_emulate_record() {
    local recipient="${1:-}" subject="${2:-}" result="${3:-emulated}"
    local sink="${NFTBAN_MAIL_EMULATE_SINK:-${NFTBAN_DATA_DIR:-/var/lib/nftban}/mail/test-delivery.jsonl}"
    local dir; dir=$(dirname "$sink")
    mkdir -p "$dir" 2>/dev/null || true
    # JSON line — transport=emulate; explicitly NO SMTP password / secret fields.
    local esc_subj="${subject//\"/\\\"}"; esc_subj="${esc_subj//$'\n'/ }"
    printf '{"ts":"%s","transport":"emulate","module":"%s","recipient":"%s","subject":"%s","result":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" \
        "${NFTBAN_MAIL_MODULE:-unknown}" "$recipient" "$esc_subj" "$result" \
        >> "$sink" 2>/dev/null || true
    return 0
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
        echo "✗ No mail system found"
        echo ""
        echo "Options to enable mail:"
        echo "  1. Install local MTA: postfix, exim, or sendmail"
        echo "  2. Install msmtp (lightweight relay)"
        echo "  3. Configure direct SMTP in /etc/nftban/conf.d/mail.conf:"
        echo "       NFTBAN_SMTP_HOST=\"smtp.example.com\""
        echo "       NFTBAN_SMTP_USER=\"user@example.com\""
        echo "       NFTBAN_SMTP_PASS=\"password\""
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
        curl)
            # Verify SMTP settings
            if [[ -z "${NFTBAN_SMTP_HOST:-}" ]]; then
                echo "✗ curl SMTP selected but NFTBAN_SMTP_HOST not configured"
                return 2
            fi
            echo "  SMTP Host: ${NFTBAN_SMTP_HOST}:${NFTBAN_SMTP_PORT:-587}"
            [[ -n "${NFTBAN_SMTP_USER:-}" ]] && echo "  Auth User: ${NFTBAN_SMTP_USER}"
            ;;
        msmtp)
            echo "  Config: $(ls /etc/msmtprc ~/.msmtprc 2>/dev/null | head -1)"
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

    # A2a: communication truth summary (recipient / spool / last outcome).
    nftban_mail_status_summary
    return 0
}

# A2a: produce-side status summary — recipient state, transport, spool depth + oldest age,
# last send result / last failure (sanitized). Reads state written by the retry path; sends
# nothing. Safe to call from mail status and (later) nftban status.
nftban_mail_status_summary() {
    local recipient spool_dir spool_depth=0 oldest_age=0 last_succ last_fail_ts last_fail_reason
    recipient="$(nftban_mail_resolve_recipient "" 2>/dev/null || echo "")"
    if [[ -n "$recipient" ]]; then echo "  Recipient: ${recipient}"; else echo "  Recipient: (none configured)"; fi
    spool_dir="${NFTBAN_MAIL_SPOOL_DIR:-${NFTBAN_DATA_DIR:-/var/lib/nftban}/mailspool}"
    if [[ -d "$spool_dir" ]]; then
        spool_depth=$(find "$spool_dir" -name "*.mail" -type f 2>/dev/null | wc -l)
        local _m; _m=$(find "$spool_dir" -name "*.mail" -type f -printf '%T@\n' 2>/dev/null | sort -n | head -n1)
        [[ -n "$_m" ]] && oldest_age=$(( $(date +%s) - ${_m%.*} ))
    fi
    echo "  Spool: depth=${spool_depth} oldest_age_s=${oldest_age}"
    last_succ=$(cat "${MAIL_COUNTERS_DIR}/mail_last_success_ts" 2>/dev/null || echo "0")
    last_fail_ts=$(cat "${MAIL_COUNTERS_DIR}/mail_last_failure_ts" 2>/dev/null || echo "0")
    last_fail_reason=$(cat "${MAIL_COUNTERS_DIR}/mail_last_failure_reason" 2>/dev/null || echo "")
    echo "  Last success ts: ${last_succ}"
    if [[ "${last_fail_ts}" != "0" ]]; then
        echo "  Last failure: ts=${last_fail_ts} reason=$(_mail_sanitize "${last_fail_reason}")"
    fi
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
    if type nftban_timestamp_date &>/dev/null; then
        date_val="$(nftban_timestamp_date)"
    else
        date_val="$(date +%Y-%m-%d)"
    fi

    local time_val
    if type nftban_timestamp_time &>/dev/null; then
        time_val="$(nftban_timestamp_time)"
    else
        time_val="$(date +%H:%M:%S)"
    fi

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
        version_html="Version: ${NFTBAN_VERSION:-unknown}"
    fi

    # Replace variables
    content="${content//\{NFTBAN_VERSION\}/${NFTBAN_VERSION:-unknown}}"
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

# A1 central-comms: single recipient-resolution choke point. Model: module override →
# global NFTBAN_MAIL_RECIPIENT. Prints the resolved recipient (stdout) and returns 0, or
# returns 1 with no output when neither is set (missing recipient = explicit error, never a
# silent no-op). Every module send-path must terminate here.
nftban_mail_resolve_recipient() {
    local override="${1:-}"
    local recip="${override:-${NFTBAN_MAIL_RECIPIENT:-}}"
    [[ -z "$recip" ]] && return 1
    printf '%s' "$recip"
    return 0
}

# A1 central-comms: the ONLY entry a module should use to emit an alert. Modules submit a
# payload (subject + body [+ optional recipient override]); central owns recipient
# resolution, transport, retry, and spool. On a missing recipient or an unavailable central
# authority it returns non-zero WITHOUT any direct-send side channel (the caller logs a
# degraded event). Never invokes a transport primitive itself.
nftban_mail_alert() {
    local subject="${1:-NFTBan Alert}" body="${2:-}" override="${3:-}"
    local recipient
    recipient="$(nftban_mail_resolve_recipient "$override")" || {
        echo "Error: no mail recipient configured (set NFTBAN_MAIL_RECIPIENT)" >&2
        return 1
    }
    # Prepend a Subject header only if the body doesn't already carry one.
    local content="$body"
    [[ "$body" == Subject:* ]] || content=$(printf 'Subject: %s\n\n%s' "$subject" "$body")
    nftban_mail_send_with_retry "$content" "$recipient" "$subject"
}

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
            # shellcheck disable=SC2034  # Reserved for attachment handling
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
    # Subject: a caller may set NFTBAN_MAIL_SUBJECT_OVERRIDE (a dynamically-scoped
    # local, e.g. from nftban_mail_send_test) to label the message accurately;
    # otherwise the generic "Report" subject is used. NOTE: the subject is NOT a
    # positional arg — $3 is reserved by existing callers (e.g. attachment path in
    # cmd_support.sh), so it must not be repurposed.
    local subject
    subject="${NFTBAN_MAIL_SUBJECT_OVERRIDE:-${subject_prefix} Report from $(hostname -f)}"

    # C5 fix: Sanitize email headers to prevent CRLF injection
    sender="${sender//$'\r'/}"
    sender="${sender//$'\n'/}"
    from_name="${from_name//$'\r'/}"
    from_name="${from_name//$'\n'/}"
    subject="${subject//$'\r'/}"
    subject="${subject//$'\n'/}"
    recipient="${recipient//$'\r'/}"
    recipient="${recipient//$'\n'/}"

    # Detect mail command
    local mta
    mta="$(nftban_mail_detect_mta)"

    if [[ "$mta" == "none" ]]; then
        echo "Error: No mail system available" >&2
        return 1
    fi

    # Send email using detected MTA
    case "$mta" in
        emulate)
            # A1b: full central flow (recipient already resolved above) minus the real
            # transport — record the attempt to the sink, no sendmail/mailx/curl, no network.
            if [[ "${NFTBAN_MAIL_DEBUG:-false}" == "true" ]]; then
                echo "[DEBUG] EMULATE: would send to $recipient — Subject: $subject (no real transport)"
            fi
            _mail_emulate_record "$recipient" "$subject" "emulated"
            return 0
            ;;

        postfix|sendmail)
            # Use sendmail command
            if [[ "${NFTBAN_MAIL_DEBUG:-false}" == "true" ]]; then
                echo "[DEBUG] Sending via sendmail to: $recipient"
                echo "[DEBUG] Subject: $subject"
            fi

            "$NFTBAN_SENDMAIL_BIN" -t <<EOF
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

            "$NFTBAN_EXIM_BIN" -t <<EOF
From: ${from_name} <${sender}>
To: ${recipient}
Subject: ${subject}
Content-Type: text/html; charset=UTF-8

${content_html}
EOF
            ;;

        msmtp)
            # Use msmtp
            if [[ "${NFTBAN_MAIL_DEBUG:-false}" == "true" ]]; then
                echo "[DEBUG] Sending via msmtp to: $recipient"
            fi

            "$NFTBAN_MSMTP_BIN" -t <<EOF
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

        curl)
            # Use curl for direct SMTP (no local MTA required)
            # Requires: NFTBAN_SMTP_HOST, optionally NFTBAN_SMTP_PORT, NFTBAN_SMTP_USER, NFTBAN_SMTP_PASS
            if [[ "${NFTBAN_MAIL_DEBUG:-false}" == "true" ]]; then
                echo "[DEBUG] Sending via curl SMTP to: $recipient"
                echo "[DEBUG] SMTP Host: ${NFTBAN_SMTP_HOST:-not set}"
            fi

            # Validate SMTP settings
            if [[ -z "${NFTBAN_SMTP_HOST:-}" ]]; then
                echo "Error: NFTBAN_SMTP_HOST not configured for curl SMTP" >&2
                return 1
            fi

            # Build SMTP URL
            local smtp_port="${NFTBAN_SMTP_PORT:-587}"
            local smtp_proto="smtp"
            local smtp_ssl_opts=""

            # Determine protocol and SSL options based on port
            case "$smtp_port" in
                465)
                    # SMTPS (implicit TLS)
                    smtp_proto="smtps"
                    ;;
                587|25)
                    # STARTTLS
                    smtp_ssl_opts="--ssl-reqd"
                    ;;
            esac

            local smtp_url="${smtp_proto}://${NFTBAN_SMTP_HOST}:${smtp_port}"

            # Build curl command arguments with timeouts
            # SMTP-centric naming preferred, CURL fallback for compatibility
            local connect_timeout="${NFTBAN_SMTP_CONNECT_TIMEOUT:-${NFTBAN_CURL_CONNECT_TIMEOUT:-10}}"
            local max_time="${NFTBAN_SMTP_MAX_TIME:-${NFTBAN_CURL_MAX_TIME:-30}}"
            local curl_args=(
                --url "$smtp_url"
                --mail-from "$sender"
                --mail-rcpt "$recipient"
                --connect-timeout "$connect_timeout"
                --max-time "$max_time"
            )

            # Add SSL options
            # shellcheck disable=SC2206  # Word splitting intentional for SSL options
            [[ -n "$smtp_ssl_opts" ]] && curl_args+=($smtp_ssl_opts)

            # v1.19.0: Add SMTP auth via netrc file to avoid credential exposure in process args (R23)
            local _smtp_netrc=""
            if [[ -n "${NFTBAN_SMTP_USER:-}" ]]; then
                # A1: SMTP password lands in a temp netrc (never argv). Harden the lifecycle —
                # umask 077 so it is created 0600 even before chmod, and a signal-safe trap so
                # the credential file is removed on EXIT/INT/TERM/HUP/QUIT, not only after curl.
                local _old_umask; _old_umask=$(umask); umask 077
                _smtp_netrc=$(mktemp "${NFTBAN_RUN_DIR:-/run/nftban}/nftban-smtp-netrc.XXXXXX")
                umask "$_old_umask"
                chmod 600 "$_smtp_netrc"
                # shellcheck disable=SC2064  # expand path now so the trap cleans this exact file
                trap "rm -f '$_smtp_netrc' 2>/dev/null || true" EXIT INT TERM HUP QUIT
                local _smtp_host
                # v1.227 MAIL-F1: the netrc "machine" MUST equal the host curl actually connects
                # to (NFTBAN_SMTP_HOST, used by smtp_url above and guarded non-empty by the curl-SMTP
                # dispatch). The prior code read NFTBAN_SMTP_SERVER — a variable set NOWHERE — so it
                # defaulted to "localhost"; curl matches netrc creds by machine=host, so localhost
                # never matched the real host and curl sent NO credentials while status showed "(ready)".
                _smtp_host=$(echo "${NFTBAN_SMTP_HOST}" | cut -d: -f1)
                echo "machine $_smtp_host login ${NFTBAN_SMTP_USER} password ${NFTBAN_SMTP_PASS:-}" > "$_smtp_netrc"
                curl_args+=(--netrc-file "$_smtp_netrc")
            fi

            # Create temporary email file with headers
            local tmp_email
            tmp_email="$(mktemp)"
            cat > "$tmp_email" <<CURLEOF
From: ${from_name} <${sender}>
To: ${recipient}
Subject: ${subject}
Content-Type: text/html; charset=UTF-8
MIME-Version: 1.0
Date: $(date -R)
Message-ID: <$(type nftban_timestamp_unix &>/dev/null && nftban_timestamp_unix || date +%s).nftban@$(hostname -f)>

${content_html}
CURLEOF

            # Send email
            if [[ "${NFTBAN_MAIL_DEBUG:-false}" == "true" ]]; then
                echo "[DEBUG] curl ${curl_args[*]} -T $tmp_email"
            fi

            curl "${curl_args[@]}" -T "$tmp_email" 2>/dev/null
            local curl_result=$?

            # Cleanup
            rm -f "$tmp_email"
            [[ -n "${_smtp_netrc:-}" ]] && rm -f "$_smtp_netrc"

            # Return curl result
            (( curl_result != 0 )) && return 1
            ;;
    esac

    local send_result=$?

    if (( send_result == 0 )); then
        echo "✓ Email submitted to transport for: $recipient (delivery not confirmed)"

        # Save sent email if debugging
        if [[ -n "${NFTBAN_MAIL_SAVE_SENT:-}" ]] && [[ -d "${NFTBAN_MAIL_SAVE_SENT}" ]]; then
            local save_file save_timestamp
            if type nftban_timestamp_file &>/dev/null; then
                save_timestamp="$(nftban_timestamp_file)"
            else
                save_timestamp="$(date +%Y%m%d_%H%M%S)"
            fi
            save_file="${NFTBAN_MAIL_SAVE_SENT}/sent_${save_timestamp}.html"
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

# A1b: validate the comms config WITHOUT sending or recording (dry-run = validate only).
# Reports recipient resolution, selected transport, and transport prerequisites. Returns
# 0 if the config could deliver, 1 otherwise. Never invokes a transport, never writes a sink.
nftban_mail_test_dryrun() {
    local override="${1:-}" rc=0 recipient mta
    echo "Mail config dry-run (validate only — NOT sent):"
    if recipient="$(nftban_mail_resolve_recipient "$override")"; then
        echo "  Recipient: ${recipient} (resolved)"
    else
        echo "  Recipient: MISSING — set NFTBAN_MAIL_RECIPIENT or pass a recipient"; rc=1
    fi
    mta="$(nftban_mail_detect_mta)"
    echo "  Transport: ${mta}"
    if [[ "$mta" == "none" ]]; then
        echo "  ERROR: no usable transport (no local MTA and no curl + NFTBAN_SMTP_HOST)"; rc=1
    elif [[ "$mta" == "curl" ]]; then
        [[ -n "${NFTBAN_SMTP_HOST:-}" ]] || { echo "  ERROR: curl-SMTP selected but NFTBAN_SMTP_HOST is unset"; rc=1; }
        command -v curl >/dev/null 2>&1 || { echo "  ERROR: curl-SMTP selected but curl is not installed"; rc=1; }
        # SMTP completeness: an SMTP user without a password cannot authenticate.
        if [[ -n "${NFTBAN_SMTP_USER:-}" && -z "${NFTBAN_SMTP_PASS:-}" ]]; then
            echo "  ERROR: SMTP incomplete — NFTBAN_SMTP_USER set but NFTBAN_SMTP_PASS is empty"; rc=1
        fi
        [[ -n "${NFTBAN_MAIL_FROM:-${NFTBAN_SENDER:-}}" ]] || echo "  WARN: no NFTBAN_MAIL_FROM/NFTBAN_SENDER set (a default will be derived)"
    fi
    # A2a: a forced method that is not actually available (detect fell back).
    if [[ -n "${NFTBAN_MAIL_METHOD:-}" ]] && ! _nftban_mail_method_available "${NFTBAN_MAIL_METHOD}"; then
        echo "  WARN: NFTBAN_MAIL_METHOD='${NFTBAN_MAIL_METHOD}' is not available — auto-detected '${mta}' instead"
    fi
    # A2a: fragmented/legacy recipient keys that diverge from the central recipient.
    local _rk
    for _rk in NFTBAN_ALERT_EMAIL NFTBAN_TUNNEL_ALERT_EMAIL; do
        local _v="${!_rk:-}"
        if [[ -n "$_v" && -n "${NFTBAN_MAIL_RECIPIENT:-}" && "$_v" != "${NFTBAN_MAIL_RECIPIENT}" ]]; then
            echo "  WARN: legacy recipient key ${_rk} diverges from NFTBAN_MAIL_RECIPIENT (fragmentation)"
        fi
    done
    if [[ $rc -eq 0 ]]; then echo "  Result: OK (config valid; nothing was sent)"; else echo "  Result: INVALID (see errors; nothing was sent)"; fi
    return $rc
}

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

    # Send using main send function. Set the subject override so the DELIVERED
    # message is labeled "Test Email" (matching the subject we printed above) rather
    # than the generic "Report" subject nftban_mail_send uses by default. (Bug fix:
    # the on-screen subject said "Test Email" but the sent subject was "Report".)
    local NFTBAN_MAIL_SUBJECT_OVERRIDE
    NFTBAN_MAIL_SUBJECT_OVERRIDE="${NFTBAN_MAIL_SUBJECT_PREFIX:-[NFTBan]} Test Email from $(hostname -f)"
    nftban_mail_send "$test_content" "$recipient"
}

# =============================================================================
# SHOW HELP
# =============================================================================

nftban_mail_show_help() {
    # Show mail module help

    # Load output module for standard banner
    if [[ $(type -t nftban_banner) != "function" ]]; then
        source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_output.sh" || return 1
    fi
    nftban_banner

    local mta
    mta="$(nftban_mail_detect_mta)"

    # Precompute the status' first line WITHOUT a pipe. A `... | head -1` inside the
    # heredoc below makes nftban_mail_check_status receive SIGPIPE under
    # `set -o pipefail` (exit 141), which the ERR trap reports as a failure and aborts
    # `nftban mail` help. Slice the first line via parameter expansion instead.
    local mail_status_line
    mail_status_line="$(nftban_mail_check_status 2>&1)"
    mail_status_line="${mail_status_line%%$'\n'*}"

    cat <<EOF

Smart Mail Adapter - Auto-detects best available method
========================================================

Current Method: $mta
Status: ${mail_status_line}

Supported Methods (auto-detected in priority order):
  postfix   - Local Postfix MTA (fastest)
  sendmail  - Local Sendmail MTA
  exim      - Local Exim MTA
  msmtp     - Lightweight SMTP relay
  curl      - Direct SMTP (no local MTA needed)
  mailx     - Basic mail command (fallback)

Usage:
  nftban mail setup <email> [opts]  # Quick email configuration
  nftban mail status                # Check mail system status
  nftban mail port-status           # Check firewall ports
  nftban mail test [email]          # Send test email
  nftban mail {content} {email}     # Send email with content

Setup Options:
  --all       Enable all notification triggers
  --test      Send test email after setup
  --dry-run   Show what would be written
  --show      Show current email configuration

Quick Start:
  # One command to enable all email notifications:
  nftban mail setup admin@example.com --all --test

  # Minimal setup (set recipient only):
  nftban mail setup admin@example.com

  # View current configuration:
  nftban mail setup --show

Examples:
  # Send test to default recipient
  nftban mail test

  # Send test to custom email
  nftban mail test admin@example.com

  # Send text message
  nftban mail "Server restarted at \$(date)" admin@example.com

  # Send file content (wrapped with HTML template)
  nftban mail /var/lib/nftban/reports/daily.html admin@example.com

Direct SMTP Setup (if no local MTA):
  Edit /etc/nftban/conf.d/mail.conf.local:
    NFTBAN_SMTP_HOST="smtp.example.com"
    NFTBAN_SMTP_PORT="587"
    NFTBAN_SMTP_USER="user@example.com"
    NFTBAN_SMTP_PASS="password"

Email Recipient Priority:
  1. Module-specific override (e.g., PORTSCAN_NOTIFY_EMAIL_TO)
  2. Global recipient: NFTBAN_MAIL_RECIPIENT
  All modules fall back to global if module-specific is empty.

Configuration: /etc/nftban/conf.d/mail.conf
Local Override: /etc/nftban/conf.d/mail.conf.local
Default Recipient: ${NFTBAN_MAIL_RECIPIENT:-not configured}
Force Method: ${NFTBAN_MAIL_METHOD:-auto-detect}

EOF
}

# =============================================================================
# MAIL METRICS
# =============================================================================

# Metrics file and counters
readonly MAIL_METRICS_FILE="${NFTBAN_MAIL_METRICS_FILE:-${NFTBAN_DATA_DIR}/metrics/mail.prom}"
readonly MAIL_COUNTERS_DIR="${NFTBAN_DATA_DIR}/metrics/counters"

_mail_counter_inc() {
    local counter_name="$1"
    local transport="${2:-unknown}"
    local counter_file="${MAIL_COUNTERS_DIR}/mail_${counter_name}_${transport}"

    mkdir -p "$MAIL_COUNTERS_DIR" 2>/dev/null || true

    (
        flock -x 200
        local current
        current=$(cat "$counter_file" 2>/dev/null || echo "0")
        echo "$((current + 1))" > "$counter_file"
    ) 200>"${counter_file}.lock"
}

_mail_write_metrics() {
    mkdir -p "$(dirname "$MAIL_METRICS_FILE")" 2>/dev/null || true

    # Use associative arrays instead of eval for safer variable assignment
    declare -A attempts success failures

    # Read counters for each transport
    for transport in sendmail postfix curl msmtp mailx exim; do
        attempts[$transport]=$(cat "${MAIL_COUNTERS_DIR}/mail_attempts_${transport}" 2>/dev/null || echo "0")
        success[$transport]=$(cat "${MAIL_COUNTERS_DIR}/mail_success_${transport}" 2>/dev/null || echo "0")
        failures[$transport]=$(cat "${MAIL_COUNTERS_DIR}/mail_failures_${transport}" 2>/dev/null || echo "0")
    done

    # Count spooled mails (failed mails awaiting retry)
    local spool_dir="${NFTBAN_MAIL_SPOOL_DIR:-${NFTBAN_DATA_DIR}/mailspool}"
    local spool_depth=0
    if [[ -d "$spool_dir" ]]; then
        spool_depth=$(find "$spool_dir" -name "*.mail" -type f 2>/dev/null | wc -l)
    fi

    # A2a: age (seconds) of the oldest spooled mail, and the currently selected transport.
    local spool_oldest_age=0
    if [[ -d "$spool_dir" ]]; then
        local _oldest_mtime _now
        _oldest_mtime=$(find "$spool_dir" -name "*.mail" -type f -printf '%T@\n' 2>/dev/null | sort -n | head -n1)
        if [[ -n "$_oldest_mtime" ]]; then
            _now=$(date +%s 2>/dev/null || echo 0)
            spool_oldest_age=$(( _now - ${_oldest_mtime%.*} ))
            [[ "$spool_oldest_age" -lt 0 ]] && spool_oldest_age=0
        fi
    fi
    local transport_selected; transport_selected="$(nftban_mail_detect_mta 2>/dev/null || echo none)"

    cat > "${MAIL_METRICS_FILE}.tmp" <<EOF
# HELP nftban_mail_send_attempts_total Total mail send attempts
# TYPE nftban_mail_send_attempts_total counter
nftban_mail_send_attempts_total{transport="sendmail"} ${attempts[sendmail]}
nftban_mail_send_attempts_total{transport="postfix"} ${attempts[postfix]}
nftban_mail_send_attempts_total{transport="curl"} ${attempts[curl]}
nftban_mail_send_attempts_total{transport="msmtp"} ${attempts[msmtp]}
nftban_mail_send_attempts_total{transport="mailx"} ${attempts[mailx]}
nftban_mail_send_attempts_total{transport="exim"} ${attempts[exim]}

# HELP nftban_mail_send_success_total Total successful mail sends
# TYPE nftban_mail_send_success_total counter
nftban_mail_send_success_total{transport="sendmail"} ${success[sendmail]}
nftban_mail_send_success_total{transport="postfix"} ${success[postfix]}
nftban_mail_send_success_total{transport="curl"} ${success[curl]}
nftban_mail_send_success_total{transport="msmtp"} ${success[msmtp]}
nftban_mail_send_success_total{transport="mailx"} ${success[mailx]}
nftban_mail_send_success_total{transport="exim"} ${success[exim]}

# HELP nftban_mail_send_failures_total Total failed mail sends
# TYPE nftban_mail_send_failures_total counter
nftban_mail_send_failures_total{transport="sendmail"} ${failures[sendmail]}
nftban_mail_send_failures_total{transport="postfix"} ${failures[postfix]}
nftban_mail_send_failures_total{transport="curl"} ${failures[curl]}
nftban_mail_send_failures_total{transport="msmtp"} ${failures[msmtp]}
nftban_mail_send_failures_total{transport="mailx"} ${failures[mailx]}
nftban_mail_send_failures_total{transport="exim"} ${failures[exim]}

# HELP nftban_mail_spool_depth Number of mails in retry spool
# TYPE nftban_mail_spool_depth gauge
nftban_mail_spool_depth $spool_depth

# HELP nftban_mail_last_success_timestamp Unix timestamp of last successful send
# TYPE nftban_mail_last_success_timestamp gauge
nftban_mail_last_success_timestamp $(cat "${MAIL_COUNTERS_DIR}/mail_last_success_ts" 2>/dev/null || echo "0")

# HELP nftban_mail_last_failure_timestamp Unix timestamp of last failed send (A2a)
# TYPE nftban_mail_last_failure_timestamp gauge
nftban_mail_last_failure_timestamp $(cat "${MAIL_COUNTERS_DIR}/mail_last_failure_ts" 2>/dev/null || echo "0")

# HELP nftban_mail_spool_oldest_age_seconds Age of the oldest spooled mail in seconds (A2a)
# TYPE nftban_mail_spool_oldest_age_seconds gauge
nftban_mail_spool_oldest_age_seconds ${spool_oldest_age}

# HELP nftban_mail_transport_selected Currently selected mail transport (1=selected) (A2a)
# TYPE nftban_mail_transport_selected gauge
nftban_mail_transport_selected{transport="${transport_selected}"} 1
EOF

    mv "${MAIL_METRICS_FILE}.tmp" "$MAIL_METRICS_FILE" 2>/dev/null || true
    chmod 644 "$MAIL_METRICS_FILE" 2>/dev/null || true
}

_mail_log() {
    local level="$1"
    shift
    local timestamp
    if type nftban_timestamp_date &>/dev/null && type nftban_timestamp_time &>/dev/null; then
        timestamp="$(nftban_timestamp_date) $(nftban_timestamp_time)"
    else
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    fi
    local log_file="${NFTBAN_LOG_DIR}/mail.log"

    mkdir -p "$(dirname "$log_file")" 2>/dev/null || true
    echo "[$timestamp] [$level] $*" >> "$log_file"
}

# =============================================================================
# A2a — DELIVERY TRUTH (produce): delivery-log + last-failure state
# =============================================================================

# Sanitize a short reason/label for a log line: collapse whitespace, strip quotes, bound
# length. We only ever pass our own short reason codes here; this is defence-in-depth so a
# secret can never ride into the delivery-log.
_mail_sanitize() {
    local s="${1:-}"
    s="${s//$'\n'/ }"; s="${s//$'\t'/ }"; s="${s//\"/}"; s="${s//\\/}"
    printf '%s' "${s:0:200}"
}

# Central delivery-log — ONE JSONL line per send OUTCOME (success|failed|spooled), reusing the
# A1b sink shape. Recipient is REDACTED to local-part@…; reason is sanitized; NEVER a secret /
# NFTBAN_SMTP_PASS. Bounded to NFTBAN_MAIL_DELIVERY_LOG_MAX lines (default 500).
_mail_delivery_log() {
    local result="${1:-unknown}" transport="${2:-unknown}" recipient="${3:-}" reason="${4:-}"
    local logf="${NFTBAN_MAIL_DELIVERY_LOG:-${NFTBAN_DATA_DIR:-/var/lib/nftban}/mail/delivery.jsonl}"
    local maxl="${NFTBAN_MAIL_DELIVERY_LOG_MAX:-500}"
    mkdir -p "$(dirname "$logf")" 2>/dev/null || true
    local red=""; [[ -n "$recipient" ]] && red="${recipient%%@*}@…"
    printf '{"ts":"%s","transport":"%s","recipient":"%s","result":"%s","reason":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" \
        "$(_mail_sanitize "$transport")" "$red" "$(_mail_sanitize "$result")" "$(_mail_sanitize "$reason")" \
        >> "$logf" 2>/dev/null || true
    local lines; lines=$(wc -l < "$logf" 2>/dev/null || echo 0)
    if [[ "${lines:-0}" -gt "$maxl" ]]; then
        tail -n "$maxl" "$logf" > "${logf}.tmp" 2>/dev/null && mv -f "${logf}.tmp" "$logf" 2>/dev/null || true
    fi
    return 0
}

# Persist last-failure {ts, reason(sanitized)} alongside the existing mail_last_success_ts.
_mail_record_last_failure() {
    local reason="${1:-}"
    mkdir -p "$MAIL_COUNTERS_DIR" 2>/dev/null || true
    { if type nftban_timestamp_unix &>/dev/null; then nftban_timestamp_unix; else date +%s; fi; } \
        > "${MAIL_COUNTERS_DIR}/mail_last_failure_ts" 2>/dev/null || true
    _mail_sanitize "$reason" > "${MAIL_COUNTERS_DIR}/mail_last_failure_reason" 2>/dev/null || true
}

# =============================================================================
# SEND WITH RETRY (Wrapper with exponential backoff)
# =============================================================================

nftban_mail_send_with_retry() {
    # Send email with retry logic and queue fallback
    # Args: $1 = content (text or file path)
    #       $2 = recipient (optional)
    #       $3 = subject (optional, for reporting)
    #
    # On transient failure: retries with backoff
    # On persistent failure: enqueues to mail spool for later delivery

    local content_arg="${1:-}"
    local recipient="${2:-${NFTBAN_MAIL_RECIPIENT:-}}"
    local subject="${3:-NFTBan Alert}"

    # Config
    local max_retries="${NFTBAN_MAIL_RETRY_ATTEMPTS:-3}"
    local backoff_list="${NFTBAN_MAIL_RETRY_BACKOFF:-5,15,45}"
    IFS=',' read -ra backoffs <<< "$backoff_list"

    # Detect transport
    local mta
    mta="$(nftban_mail_detect_mta)"

    if [[ "$mta" == "none" ]]; then
        _mail_log "ERROR" "No mail system available, spooling for later"
        _mail_record_last_failure "no_transport_available"
        _mail_delivery_log "spooled" "none" "$recipient" "no_transport_available"
        _mail_spool_enqueue "$content_arg" "$recipient" "$subject"
        return 1
    fi

    local attempt=0
    local send_result=1
    local last_error=""

    while [[ $attempt -lt $max_retries ]]; do
        # v1.19.20 FIX
        ((attempt++)) || true

        _mail_counter_inc "attempts" "$mta"
        _mail_log "INFO" "MAIL_SEND_ATTEMPT task_id=inline attempt=$attempt transport=$mta to=${recipient%%@*}@..."

        # Try to send
        if nftban_mail_send "$content_arg" "$recipient" 2>/dev/null; then
            send_result=0
            _mail_counter_inc "success" "$mta"
            if type nftban_timestamp_unix &>/dev/null; then
                nftban_timestamp_unix > "${MAIL_COUNTERS_DIR}/mail_last_success_ts"
            else
                echo "$(date +%s)" > "${MAIL_COUNTERS_DIR}/mail_last_success_ts"
            fi
            _mail_log "INFO" "MAIL_SEND_RESULT task_id=inline status=success transport=$mta attempt=$attempt"
            _mail_delivery_log "success" "$mta" "$recipient" ""
            _mail_write_metrics
            return 0
        else
            last_error="send_failed_rc_$?"
        fi

        _mail_log "WARN" "MAIL_SEND_ATTEMPT failed attempt=$attempt/$max_retries error=$last_error"

        # Calculate backoff
        local backoff_idx=$((attempt - 1))
        if [[ $backoff_idx -lt ${#backoffs[@]} ]]; then
            local sleep_time="${backoffs[$backoff_idx]}"
            _mail_log "DEBUG" "Retrying in ${sleep_time}s..."
            sleep "$sleep_time"
        fi
    done

    # All retries exhausted - spool for later
    _mail_counter_inc "failures" "$mta"
    _mail_log "ERROR" "MAIL_SEND_RESULT task_id=inline status=failed transport=$mta retries=$max_retries last_error=$last_error"
    _mail_record_last_failure "$last_error"
    _mail_delivery_log "failed" "$mta" "$recipient" "$last_error"
    _mail_write_metrics

    # Enqueue to mail spool (uses queue system) — record the spooled outcome too
    _mail_delivery_log "spooled" "$mta" "$recipient" "after_${max_retries}_retries"
    _mail_spool_enqueue "$content_arg" "$recipient" "$subject"

    return 1
}

# =============================================================================
# MAIL SPOOL INTEGRATION (Uses task queue)
# =============================================================================

_mail_spool_enqueue() {
    # Enqueue failed mail to task queue for later delivery
    local content_arg="$1"
    local recipient="$2"
    local subject="$3"

    local spool_dir="${NFTBAN_MAIL_SPOOL_DIR:-${NFTBAN_DATA_DIR}/mailspool}"
    mkdir -p "$spool_dir" 2>/dev/null || true

    # Generate unique ID
    local mail_id mail_timestamp
    if type nftban_timestamp &>/dev/null; then
        mail_timestamp="$(nftban_timestamp)"
    else
        mail_timestamp="$(date +%Y%m%dT%H%M%SZ)"
    fi
    mail_id="mail-${mail_timestamp}-$(head -c 4 /dev/urandom | xxd -p 2>/dev/null || echo $$)"

    # Save mail content to spool
    local payload_dir="${spool_dir}/${mail_id}"
    mkdir -p "$payload_dir" || return 1

    # Determine if content is file or text
    if [[ -f "$content_arg" ]]; then
        cp "$content_arg" "${payload_dir}/body.html"
    else
        echo "$content_arg" > "${payload_dir}/body.txt"
    fi

    # Save metadata
    local created_epoch
    if type nftban_timestamp_unix &>/dev/null; then
        created_epoch="$(nftban_timestamp_unix)"
    else
        created_epoch="$(date +%s)"
    fi
    cat > "${payload_dir}/meta.sh" <<EOF
MAIL_TO="$recipient"
MAIL_SUBJECT="$subject"
MAIL_BODY_FILE="${payload_dir}/body.html"
MAIL_CREATED_EPOCH="${created_epoch}"
EOF

    # Check if queue functions available
    if type nftban_queue_add &>/dev/null; then
        local task_id
        task_id=$(nftban_queue_add "mail_send" "Spooled mail to ${recipient%%@*}@..." "${payload_dir}/meta.sh")
        _mail_log "INFO" "Mail spooled to queue: $task_id (recipient: ${recipient%%@*}@...)"
        echo "Mail spooled for later delivery: $task_id"
    else
        # Queue not available - just leave in spool directory
        _mail_log "WARN" "Queue not available, mail saved to spool: ${payload_dir}"
        echo "Mail saved to spool (queue unavailable): ${payload_dir}"
    fi
}

nftban_mail_spool_status() {
    # Show mail spool status
    local spool_dir="${NFTBAN_MAIL_SPOOL_DIR:-${NFTBAN_DATA_DIR}/mailspool}"

    if [[ ! -d "$spool_dir" ]]; then
        echo "Mail spool directory not found: $spool_dir"
        return 0
    fi

    local count
    count=$(find "$spool_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)

    echo "Mail Spool Status"
    echo "================="
    echo "Directory: $spool_dir"
    echo "Spooled mails: $count"
    echo ""

    if [[ $count -gt 0 ]]; then
        echo "Pending mails:"
        for mail_dir in "$spool_dir"/mail-*; do
            [[ ! -d "$mail_dir" ]] && continue

            if [[ -f "${mail_dir}/meta.sh" ]]; then
                # H10 fix: Validate meta.sh contains only safe variable assignments before sourcing
                if grep -qE '^[^#]*[;|&`$\(]' "${mail_dir}/meta.sh" 2>/dev/null; then
                    echo "  WARNING: Skipping suspicious meta.sh in $(basename "$mail_dir")" >&2
                    continue
                fi
                # shellcheck source=/dev/null
                source "${mail_dir}/meta.sh" || true
                local created_date
                created_date=$(date -d "@${MAIL_CREATED_EPOCH:-0}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "unknown")
                printf "  %s | To: %s | Created: %s\n" "$(basename "$mail_dir")" "${MAIL_TO%%@*}@..." "$created_date"
            fi
        done
    fi
}

# =============================================================================
# MODULE FOOTER
# =============================================================================

# Module loaded notification (only in debug mode)
if [[ "${NFTBAN_DEBUG_MODE:-false}" == "true" ]]; then
    nftban_module_loaded "nftban_mail" "1.0.0" "Mail Module" "core" "bash,sendmail,nft"
fi
