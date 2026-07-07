#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan - Shared redaction authority (SEC-P1-2 P2a)
# =============================================================================
# meta:name="nftban_redact"
# meta:type="library"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-07"
# meta:description="Single source-of-truth redactor for secret material in any operator-facing output (support bundles, comms/delivery logs, forensics, future webhook/RBLMON evidence). Declarative pattern registry covers *_PASS/*_PASSWORD/*_SECRET/*_TOKEN/*_API_KEY/*_AUTH/*_LICENSE_KEY/*_SASL_PASS assignments, Bearer tokens, URL credentials (scheme://user:pass@host), netrc password material, SMTP Auth User, and the Recipient: local-part. The sensitive key-suffix must be the whole key or a _-delimited segment so benign keys (KAFKA_PARTITION_KEY, bypass=, surpass=) survive; forensic identifiers (attacker IPs, usernames) are never redacted. APIs: nftban_redact_string / nftban_redact_stream / nftban_redact_file. Coverage may only GROW — never weaken a call site when migrating to this lib."
# meta:inventory.files=""
# meta:inventory.binaries="sed"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_NFTBAN_REDACT_LOADED:-}" ]] && return 0
readonly _NFTBAN_REDACT_LOADED=1

# -----------------------------------------------------------------------------
# PATTERN REGISTRY — one authoritative set. Each entry is a GNU-sed -E program.
# The `I` (case-insensitive) flag is used where key names vary in case.
# Design rules:
#   * KEY=VALUE / KEY: VALUE — the sensitive word must be the WHOLE key or a
#     `_`-delimited segment of it (prefix, if any, ends in `_`) AND start at a
#     token boundary (^|[^A-Za-z0-9_]). So `bypass=`/`surpass=` (…ends in "pass"
#     but not a `_`-segment) and `KAFKA_PARTITION_KEY=` (bare KEY excluded; only
#     API_KEY/APIKEY/LICENSE_KEY qualify) do NOT match, while `SMTP_PASS=` does.
#   * The opening quote (if any) is preserved; the VALUE becomes [REDACTED].
#   * URL creds redact the password only, keeping scheme://user@host readable.
#   * Recipient redaction is context-anchored to a "Recipient:" label (won't
#     touch arbitrary operational emails elsewhere).
# -----------------------------------------------------------------------------
# shellcheck disable=SC2016  # single-quoted sed programs are intentional
readonly -a NFTBAN_REDACT_PATTERNS=(
    # sensitive KEY = VALUE (token-anchored; sensitive word = whole key or a _-delimited segment)
    's/(^|[^A-Za-z0-9_])([A-Za-z0-9_]*_)?(PASSWORD|PASS|SECRET|TOKEN|API_?KEY|APIKEY|AUTH|LICENSE_KEY|SASL_PASSWORD|SASL_PASS)([[:space:]]*[=:][[:space:]]*["'"'"']?)[^"'"'"'[:space:],]*/\1\2\3\4[REDACTED]/Ig'
    # Bearer <token>
    's/(Bearer[[:space:]]+)[A-Za-z0-9._~+/=-]+/\1[REDACTED]/Ig'
    # URL credentials: scheme://user:PASS@host  ->  scheme://user:[REDACTED]@host
    's|(://[^/:@[:space:]]+:)[^/@[:space:]]+@|\1[REDACTED]@|g'
    # netrc/keyword: "password <x>" — the netrc secret. (SEC-P1-2 P2b-1: the netrc
    # "login <x>" pattern is intentionally NOT included — in free-text journals "login"
    # is followed by a USERNAME [forensic evidence, must survive] or filler text, so
    # redacting it would destroy identifiers. netrc passwords remain covered here.)
    's/(\bpassword[[:space:]]+)[^[:space:]]+/\1[REDACTED]/Ig'
    # SMTP "Auth User: <x>"
    's/(Auth User:[[:space:]]*)[^[:space:]]+/\1[REDACTED]/Ig'
    # Recipient: local@domain  ->  [redacted]@domain (context-anchored)
    's/(Recipient:[[:space:]]*)[^@[:space:]]+@([^[:space:]]+)/\1[redacted]@\2/g'
)

# Precompute the sed -e argument list once.
_NFTBAN_REDACT_SED_ARGS=()
for _p in "${NFTBAN_REDACT_PATTERNS[@]}"; do _NFTBAN_REDACT_SED_ARGS+=(-e "$_p"); done
unset _p

# nftban_redact_stream — stdin -> stdout, fully redacted. Idempotent.
nftban_redact_stream() {
    sed -E "${_NFTBAN_REDACT_SED_ARGS[@]}" 2>/dev/null || cat
}

# nftban_redact_string "<text>" — echo the redacted text (no trailing newline forced
# beyond sed's own). Value never appears in a child process argv beyond this call.
nftban_redact_string() {
    printf '%s' "${1:-}" | nftban_redact_stream
}

# nftban_redact_file <src> <dst> — redact a file to dst (no-op if src missing).
nftban_redact_file() {
    local src="${1:-}" dst="${2:-}"
    [[ -f "$src" && -n "$dst" ]] || return 0
    nftban_redact_stream < "$src" > "$dst"
}

export -f nftban_redact_stream nftban_redact_string nftban_redact_file 2>/dev/null || true
