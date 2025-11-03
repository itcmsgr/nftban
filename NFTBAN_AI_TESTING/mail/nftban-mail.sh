#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# nftban-mail.sh - Email library for NFTBan (no MTA required)
# Part of NFTBan v0.30 - Self-healing monitoring system
#
# Supports two transports:
# - curl: Direct SMTP via curl (no packages needed)
# - msmtp: via msmtp client (cleaner, more robust)
#
# Usage:
#   source /usr/lib/nftban/core/nftban_mail.sh
#   attachments=("file1.csv")
#   mail_send "to@example.com" "Subject" "Body text" "" attachments[@]

set -euo pipefail

# Configuration (override via environment)
: "${MAIL_TRANSPORT:=curl}"           # curl|msmtp
: "${SMTP_SCHEME:=smtp}"               # smtp|smtps
: "${SMTP_SERVER:=localhost}"
: "${SMTP_PORT:=587}"
: "${SMTP_USER:=}"
: "${SMTP_PASS:=}"
: "${SMTP_REQUIRE_TLS:=true}"
: "${MAIL_FROM:=nftban@localhost}"
: "${MAIL_FROM_NAME:=NFTBan Notifier}"

# --- Private helpers ---
_mail_tmp() { mktemp -t nftmail.XXXXXX.eml; }
_hdr() { printf '%s: %s\r\n' "$1" "$2"; }
_now_rfc2822() { LC_ALL=C date -R; }

_build_mime() {
  local to_list="$1" subject="$2" text="$3" html_path="$4" att_arr_name="$5"
  local eml boundary="b$RANDOM$RANDOM" alt="a$RANDOM$RANDOM"
  eml="$(_mail_tmp)"

  # Headers
  {
    _hdr Date "$(_now_rfc2822)"
    _hdr Message-ID "<$(date +%s%N).nftban@${HOSTNAME:-localhost}>"
    if [[ -n "$MAIL_FROM_NAME" ]]; then
      _hdr From "$MAIL_FROM_NAME <$MAIL_FROM>"
    else
      _hdr From "$MAIL_FROM"
    fi
    _hdr To "undisclosed-recipients:;"
    _hdr Subject "$subject"
    echo "MIME-Version: 1.0"

    # Body structure
    local -n _atts="$att_arr_name"
    if [[ -n "$html_path" || ${#_atts[@]} -gt 0 ]]; then
      echo "Content-Type: multipart/mixed; boundary=\"$boundary\""
      printf '\r\n--%s\r\n' "$boundary"
      echo "Content-Type: multipart/alternative; boundary=\"$alt\""
      printf '\r\n--%s\r\n' "$alt"
      echo "Content-Type: text/plain; charset=UTF-8"
      echo "Content-Transfer-Encoding: 8bit"
      printf '\r\n%s\r\n' "$text"

      # HTML part (optional)
      if [[ -n "$html_path" && -f "$html_path" ]]; then
        printf '\r\n--%s\r\n' "$alt"
        echo "Content-Type: text/html; charset=UTF-8"
        echo "Content-Transfer-Encoding: 8bit"
        printf '\r\n'
        cat "$html_path"
        printf '\r\n'
      fi
      printf -- '\r\n--%s--\r\n' "$alt"

      # Attachments
      for f in "${_atts[@]:-}"; do
        [[ -f "$f" ]] || continue
        local name; name="$(basename "$f")"
        printf -- '\r\n--%s\r\n' "$boundary"
        printf 'Content-Type: application/octet-stream; name="%s"\r\n' "$name"
        echo "Content-Transfer-Encoding: base64"
        printf 'Content-Disposition: attachment; filename="%s"\r\n\r\n' "$name"
        base64 -w 76 "$f"
        printf '\r\n'
      done
      printf -- '--%s--\r\n' "$boundary"
    else
      echo "Content-Type: text/plain; charset=UTF-8"
      echo "Content-Transfer-Encoding: 8bit"
      printf '\r\n%s\r\n' "$text"
    fi
  } >"$eml"

  printf '%s' "$eml"
}

_send_msmtp() {
  local eml="$1" to_list="$2"
  msmtp --read-envelope-from --from="$MAIL_FROM" -- \
    $(printf '%q ' $to_list) <"$eml"
}

_send_curl() {
  local eml="$1" to_list="$2"
  local args=(
    --silent --show-error
    --url "${SMTP_SCHEME}://${SMTP_SERVER}:${SMTP_PORT}"
    --mail-from "$MAIL_FROM"
  )
  for rcpt in $to_list; do args+=( --mail-rcpt "$rcpt" ); done
  args+=( --mail-rcpt-allowfails --upload-file "$eml" )
  [[ -n "$SMTP_USER" ]] && args+=( --user "${SMTP_USER}:${SMTP_PASS}" )
  if [[ "$SMTP_SCHEME" == "smtp" && "${SMTP_REQUIRE_TLS,,}" == "true" ]]; then
    args+=( --ssl-reqd )
  fi
  curl "${args[@]}"
}

# --- Public API ---

# mail_send - Send email
# Args:
#   $1: to_list (space-separated: "a@x.com b@y.com")
#   $2: subject
#   $3: text body
#   $4: html_path (optional, "" to skip)
#   $5: attachments array name (optional, "" to skip)
# Returns: 0 on success, non-zero on failure
mail_send() {
  local to_list="$1" subject="$2" text="$3" html_path="${4:-}" att_ref="${5:-}"
  local eml

  # Build MIME message
  eml="$(_build_mime "$to_list" "$subject" "$text" "$html_path" "$att_ref")"

  # Send via transport
  local result=0
  if [[ "${MAIL_TRANSPORT}" == "msmtp" ]]; then
    if _send_msmtp "$eml" "$to_list"; then
      result=0
    else
      result=$?
    fi
  else
    if _send_curl "$eml" "$to_list"; then
      result=0
    else
      result=$?
    fi
  fi

  # Clean up temp file
  rm -f "$eml" 2>/dev/null || true

  return $result
}

# Self-test (optional)
# MAIL_SELFTEST=1 MAIL_RCPT=you@example.org bash nftban-mail.sh
if [[ "${MAIL_SELFTEST:-0}" == "1" ]]; then
  to="${MAIL_RCPT:?set MAIL_RCPT}"
  attachments=()
  mail_send "$to" "NFTBan Mail Test $(date -Iseconds)" \
    "Hello from nftban-mail.sh

This is a test email from NFTBan v0.30 monitoring system.

If you received this, the mail subsystem is working correctly!" "" attachments[@]
  echo "✓ Test email sent to $to"
fi
