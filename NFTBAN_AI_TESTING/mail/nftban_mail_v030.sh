#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.30.0 - Mail Adapter (Smart Integration)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Smart mail adapter - uses existing v0.10 mail OR provides fallback
#
# meta:name=nftban_mail_v030
# meta:type=core
# meta:header=Mail Adapter v0.30
# meta:version=0.30.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Smart adapter: uses existing mail system OR provides curl fallback
# meta:input=Email params (recipient, subject, body, attachment)
# meta:output=Sent email via best available method
#
# **Inventory & Requirements**
# meta:depends=bash (curl optional, sendmail optional)
#
# meta:created_date=2025-11-03
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${NFTBAN_MAIL_V030_LOADED:-}" ]] && return 0
readonly NFTBAN_MAIL_V030_LOADED=1

# =============================================================================
# SMART DETECTION
# =============================================================================

_v030_mail_detect_system() {
    # Smart detection: Try to use existing v0.10 mail module first

    # Option 1: Use existing NFTBan v0.10 mail module (BEST)
    if [[ -f /usr/lib/nftban/core/nftban_mail.sh ]]; then
        if ! declare -f nftban_mail_detect_mta >/dev/null 2>&1; then
            source /usr/lib/nftban/core/nftban_mail.sh 2>/dev/null || true
        fi
        if declare -f nftban_mail_detect_mta >/dev/null 2>&1; then
            echo "v010"  # Use existing v0.10 system
            return 0
        fi
    fi

    # Option 2: Check for system MTA (sendmail/postfix/exim)
    if command -v sendmail >/dev/null 2>&1; then
        echo "sendmail"
        return 0
    fi

    # Option 3: Check for msmtp
    if command -v msmtp >/dev/null 2>&1; then
        echo "msmtp"
        return 0
    fi

    # Option 4: Fallback to curl (if available)
    if command -v curl >/dev/null 2>&1; then
        echo "curl"
        return 0
    fi

    # No mail system available
    echo "none"
    return 1
}

# Detect mail system at load time
NFTBAN_V030_MAIL_SYSTEM=$(_v030_mail_detect_system)

# =============================================================================
# UNIFIED MAIL FUNCTION
# =============================================================================

nftban_v030_mail_send() {
    # Smart mail send - uses best available method
    # Args: recipient subject body [attachment_path]
    local recipient="$1"
    local subject="$2"
    local body="$3"
    local attachment="${4:-}"

    case "$NFTBAN_V030_MAIL_SYSTEM" in
        v010)
            # Use existing v0.10 mail module
            if [[ -n "$attachment" && -f "$attachment" ]]; then
                nftban_mail_send_with_attachment "$recipient" "$subject" "$body" "$attachment"
            else
                nftban_mail_send "$recipient" "$subject" "$body"
            fi
            ;;

        sendmail)
            # Use system sendmail
            _v030_mail_send_via_sendmail "$recipient" "$subject" "$body" "$attachment"
            ;;

        msmtp)
            # Use msmtp
            _v030_mail_send_via_msmtp "$recipient" "$subject" "$body" "$attachment"
            ;;

        curl)
            # Fallback to curl SMTP
            _v030_mail_send_via_curl "$recipient" "$subject" "$body" "$attachment"
            ;;

        none)
            echo "Error: No mail system available" >&2
            return 1
            ;;

        *)
            echo "Error: Unknown mail system: $NFTBAN_V030_MAIL_SYSTEM" >&2
            return 1
            ;;
    esac
}

# =============================================================================
# FALLBACK IMPLEMENTATIONS (only used if v0.10 not available)
# =============================================================================

_v030_mail_build_mime() {
    # Build simple MIME message
    local recipient="$1" subject="$2" body="$3" attachment="${4:-}"
    local tmpfile boundary

    tmpfile=$(mktemp -t nftban_mail.XXXXXX.eml)
    boundary="nftban_$(date +%s%N)"

    {
        printf 'From: nftban@%s\r\n' "$(hostname -f 2>/dev/null || hostname)"
        printf 'To: %s\r\n' "$recipient"
        printf 'Subject: %s\r\n' "$subject"
        printf 'Date: %s\r\n' "$(LC_ALL=C date -R)"
        echo "MIME-Version: 1.0"

        if [[ -n "$attachment" && -f "$attachment" ]]; then
            echo "Content-Type: multipart/mixed; boundary=\"$boundary\""
            printf '\r\n--%s\r\n' "$boundary"
            echo "Content-Type: text/plain; charset=UTF-8"
            printf '\r\n%s\r\n' "$body"
            printf '\r\n--%s\r\n' "$boundary"
            printf 'Content-Type: application/octet-stream; name="%s"\r\n' "$(basename "$attachment")"
            echo "Content-Transfer-Encoding: base64"
            printf '\r\n'
            base64 -w 76 "$attachment"
            printf '\r\n--%s--\r\n' "$boundary"
        else
            echo "Content-Type: text/plain; charset=UTF-8"
            printf '\r\n%s\r\n' "$body"
        fi
    } >"$tmpfile"

    echo "$tmpfile"
}

_v030_mail_send_via_sendmail() {
    local recipient="$1" subject="$2" body="$3" attachment="${4:-}"
    local eml

    eml=$(_v030_mail_build_mime "$recipient" "$subject" "$body" "$attachment")

    if sendmail -t < "$eml" 2>/dev/null; then
        rm -f "$eml"
        return 0
    else
        rm -f "$eml"
        return 1
    fi
}

_v030_mail_send_via_msmtp() {
    local recipient="$1" subject="$2" body="$3" attachment="${4:-}"
    local eml

    eml=$(_v030_mail_build_mime "$recipient" "$subject" "$body" "$attachment")

    if msmtp --read-envelope-from -- "$recipient" < "$eml" 2>/dev/null; then
        rm -f "$eml"
        return 0
    else
        rm -f "$eml"
        return 1
    fi
}

_v030_mail_send_via_curl() {
    local recipient="$1" subject="$2" body="$3" attachment="${4:-}"
    local eml

    # Load SMTP config if available
    [[ -f /etc/nftban/conf.d/mail.conf ]] && source /etc/nftban/conf.d/mail.conf

    : "${SMTP_SERVER:=localhost}"
    : "${SMTP_PORT:=587}"
    : "${SMTP_SCHEME:=smtp}"
    : "${SMTP_USER:=}"
    : "${SMTP_PASS:=}"
    : "${SMTP_REQUIRE_TLS:=true}"

    eml=$(_v030_mail_build_mime "$recipient" "$subject" "$body" "$attachment")

    local curl_args=(
        --silent --show-error
        --url "${SMTP_SCHEME}://${SMTP_SERVER}:${SMTP_PORT}"
        --mail-from "nftban@$(hostname -f 2>/dev/null || hostname)"
        --mail-rcpt "$recipient"
        --upload-file "$eml"
    )

    [[ -n "$SMTP_USER" ]] && curl_args+=(--user "${SMTP_USER}:${SMTP_PASS}")
    [[ "$SMTP_SCHEME" == "smtp" && "${SMTP_REQUIRE_TLS,,}" == "true" ]] && curl_args+=(--ssl-reqd)

    if curl "${curl_args[@]}" 2>/dev/null; then
        rm -f "$eml"
        return 0
    else
        rm -f "$eml"
        return 1
    fi
}

# =============================================================================
# CONVENIENCE FUNCTIONS
# =============================================================================

nftban_v030_mail_send_alert() {
    # Send alert with standard format
    # Args: alert_level title message [json_file]
    local alert_level="$1"  # info|warning|error|critical
    local title="$2"
    local message="$3"
    local json_file="${4:-}"

    local subject="[NFTBan] ${alert_level^^}: $title"
    local body="NFTBan Security Alert

Level: ${alert_level}
Time: $(date -Iseconds)
Host: $(hostname -f 2>/dev/null || hostname)

$message

---
NFTBan v0.30 Monitoring System"

    # Load recipient from config
    local recipient="admin@localhost"
    if [[ -f /etc/nftban/conf.d/mail.conf ]]; then
        source /etc/nftban/conf.d/mail.conf
        recipient="${NFTBAN_MAIL_RECIPIENT:-$recipient}"
    fi

    nftban_v030_mail_send "$recipient" "$subject" "$body" "$json_file"
}

# =============================================================================
# INFO FUNCTION
# =============================================================================

nftban_v030_mail_info() {
    # Show detected mail system
    echo "NFTBan v0.30 Mail Adapter"
    echo "========================="
    echo "Detected system: $NFTBAN_V030_MAIL_SYSTEM"
    echo

    case "$NFTBAN_V030_MAIL_SYSTEM" in
        v010)
            echo "✓ Using existing NFTBan v0.10 mail module (optimal)"
            echo "  Location: /usr/lib/nftban/core/nftban_mail.sh"
            if declare -f nftban_mail_detect_mta >/dev/null 2>&1; then
                echo "  MTA: $(nftban_mail_detect_mta)"
            fi
            ;;
        sendmail)
            echo "✓ Using system sendmail"
            ;;
        msmtp)
            echo "✓ Using msmtp"
            ;;
        curl)
            echo "⚠ Using curl fallback (configure SMTP in /etc/nftban/conf.d/mail.conf)"
            ;;
        none)
            echo "✗ No mail system available"
            ;;
    esac
}

# Self-test
if [[ "${NFTBAN_MAIL_V030_SELFTEST:-0}" == "1" ]]; then
    nftban_v030_mail_info
fi
