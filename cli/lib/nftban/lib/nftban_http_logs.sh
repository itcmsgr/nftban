#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.177 - Panel-aware HTTP access-log discovery (shared)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_http_logs"
# meta:type="lib"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-12"
# meta:description="Shared panel-aware HTTP access-log discovery for the SHELL surfaces — BotScan (timer→shell, real runtime) and shell LoginMon-WordPress (classic-mode/CLI). Detects the control panel (DirectAdmin/cPanel/Plesk) and web stack, expands panel-appropriate + generic access-log globs, filters to existing+readable files, excludes error logs, dedups, and bounds the result (most-recently-modified, capped count). Replaces the legacy single-file first-match logic on those SHELL surfaces; it does NOT cover the Go daemon (internal/loginmon) runtime login path, whose WordPress/web watcher is deferred to v1.178 (see V1_178_LOGINMON_WEB_RUNTIME_AUTHORITY_SCOPE_STUB.md) — do not read this as fleet-wide replacement. Also provides a bounded incremental (offset/inode) reader so a timer cycle does not re-scan whole domain logs from BOF, with rotation/truncation handling. Honors a multi-glob config override; never silently blind when auto-detect can still find logs. Read-only/no-mutation except its own offset state-dir under DATA_DIR."
# meta:input="env: NFTBAN_HTTP_LOG_PATHS (override globs), NFTBAN_HTTP_LOG_MAX_FILES, NFTBAN_HTTP_LOG_MAX_BYTES, NFTBAN_HTTP_LOG_OFFSET_DIR, NFTBAN_DATA_DIR"
# meta:output="newline-separated access-log paths; bounded line streams"
# meta:depends="bash,stat,find"
# meta:inventory.files="cli/lib/nftban/core/nftban_botscan.sh,cli/lib/nftban/core/nftban_login_classic.sh"
# meta:inventory.binaries="stat,find,tail,wc"
# meta:inventory.env_vars="NFTBAN_HTTP_LOG_PATHS,NFTBAN_HTTP_LOG_MAX_FILES,NFTBAN_HTTP_LOG_MAX_BYTES,NFTBAN_HTTP_LOG_OFFSET_DIR,NFTBAN_DATA_DIR"
# meta:inventory.config_files="/etc/nftban/conf.d/botscan/main.conf,/etc/nftban/conf.d/login/main.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
# Idempotent source guard
[[ -n "${_NFTBAN_HTTP_LOGS_SOURCED:-}" ]] && return 0
_NFTBAN_HTTP_LOGS_SOURCED=1

# Bounds (overridable via env/config). Defaults are conservative for busy hosts.
: "${NFTBAN_HTTP_LOG_MAX_FILES:=500}"           # cap discovered logs per cycle
: "${NFTBAN_HTTP_LOG_MAX_BYTES:=10485760}"      # 10 MiB read per file per cycle
: "${NFTBAN_HTTP_LOG_OFFSET_DIR:=${NFTBAN_DATA_DIR:-/var/lib/nftban}/http-log-offsets}"

# Last-discovery diagnostics (populated by nftban_http_discover_access_logs).
_NFTBAN_HTTP_LAST_PANEL=""
_NFTBAN_HTTP_LAST_SELECTED=()
_NFTBAN_HTTP_LAST_SKIPPED=()   # "path: reason"

# --- panel / stack detection -------------------------------------------------
nftban_http_detect_panel() {
    if [[ -x /usr/local/directadmin/directadmin || -d /usr/local/directadmin ]]; then echo "directadmin"; return 0; fi
    if command -v whmapi1 >/dev/null 2>&1 || [[ -d /usr/local/cpanel ]]; then echo "cpanel"; return 0; fi
    if command -v plesk >/dev/null 2>&1 || [[ -d /usr/local/psa || -d /var/www/vhosts/system ]]; then echo "plesk"; return 0; fi
    echo ""
}

nftban_http_detect_stack() {
    local s=""
    [[ -x /usr/sbin/httpd || -x /usr/sbin/apache2 || -d /etc/httpd || -d /etc/apache2 ]] && s+="apache "
    [[ -x /usr/sbin/nginx || -d /etc/nginx ]] && s+="nginx "
    [[ -x /usr/local/lsws/bin/lshttpd || -d /usr/local/lsws ]] && s+="litespeed "
    echo "${s% }"
}

# Panel-appropriate + generic candidate globs (one per line). NOT yet existence-checked.
nftban_http_candidate_globs() {
    local panel="${1:-}"
    case "$panel" in
        directadmin)
            printf '%s\n' '/var/log/httpd/domains/*.log' '/var/log/nginx/domains/*.log' ;;
        cpanel)
            printf '%s\n' '/usr/local/apache/domlogs/*' '/usr/local/apache/domlogs/*/*' '/var/log/apache2/domlogs/*' ;;
        plesk)
            printf '%s\n' '/var/www/vhosts/system/*/logs/access_log' '/var/www/vhosts/system/*/logs/access_ssl_log' ;;
    esac
    # Generic stacks — always candidates (harmless if absent).
    printf '%s\n' \
        '/var/log/httpd/access_log' \
        '/var/log/apache2/access.log' \
        '/var/log/nginx/access.log' \
        '/var/log/nginx/*access*' \
        '/usr/local/lsws/logs/*access*'
}

# Internal: expand a single glob and append existing readable non-error access
# files to the global _NFTBAN_HTTP_FOUND; unreadable matches go to
# _NFTBAN_HTTP_LAST_SKIPPED. Runs in the CURRENT shell (no subshell) so the
# global mutations persist. compgen -G yields one match per line (no nullglob /
# word-split pitfalls; empty on no match).
_nftban_http_collect_glob() {
    local g="$1" f
    local -a matches=()
    mapfile -t matches < <(compgen -G "$g" 2>/dev/null || true)
    for f in "${matches[@]}"; do
        [[ -f "$f" ]] || continue
        case "$f" in
            *error_log|*error.log|*-error*|*_error*|*.gz|*.[0-9]) continue ;;  # skip error/rotated/compressed
        esac
        if [[ -r "$f" ]]; then
            _NFTBAN_HTTP_FOUND+=("$f")
        else
            _NFTBAN_HTTP_LAST_SKIPPED+=("$f: unreadable")
        fi
    done
}

# Discover access logs. Args: $1 = optional override glob list (space/newline).
# Order: explicit override (if it resolves to >=1 readable file) → else auto
# (panel-aware + generic). Bounded to MAX_FILES by most-recent mtime. Dedup'd.
# Populates _NFTBAN_HTTP_LAST_{PANEL,SELECTED,SKIPPED}. Echoes selected paths.
nftban_http_discover_access_logs() {
    local override="${1:-}"
    local panel; panel="$(nftban_http_detect_panel)"
    _NFTBAN_HTTP_LAST_PANEL="$panel"
    _NFTBAN_HTTP_LAST_SELECTED=()
    _NFTBAN_HTTP_LAST_SKIPPED=()

    _NFTBAN_HTTP_FOUND=()
    local g
    if [[ -n "$override" ]]; then
        # Override may be space-, tab-, or newline-separated globs. Split it
        # IFS-INDEPENDENTLY (callers like login_classic set IFS=$'\n\t' with no
        # space, which would otherwise merge a space-separated list into one token).
        local og; local -a _ovr=()
        local _save_ifs="$IFS"; IFS=$' \t\n'; read -ra _ovr <<< "$override"; IFS="$_save_ifs"
        for og in "${_ovr[@]}"; do
            [[ -n "$og" ]] && _nftban_http_collect_glob "$og"
        done
        if [[ ${#_NFTBAN_HTTP_FOUND[@]} -eq 0 ]]; then
            # Bad/empty override must NOT silently disable detection: fall through to auto.
            _NFTBAN_HTTP_LAST_SKIPPED+=("override '$override': no readable files — falling back to auto-detect")
        fi
    fi
    if [[ ${#_NFTBAN_HTTP_FOUND[@]} -eq 0 ]]; then
        while IFS= read -r g; do
            [[ -n "$g" ]] && _nftban_http_collect_glob "$g"
        done < <(nftban_http_candidate_globs "$panel")
    fi

    local -a found=("${_NFTBAN_HTTP_FOUND[@]}")
    [[ ${#found[@]} -eq 0 ]] && return 1

    # Dedup (preserve), then sort by mtime desc and cap at MAX_FILES.
    local -A seen=()
    local -a uniq=()
    local f
    for f in "${found[@]}"; do
        [[ -n "${seen[$f]:-}" ]] && continue
        seen[$f]=1; uniq+=("$f")
    done
    if [[ ${#uniq[@]} -gt ${NFTBAN_HTTP_LOG_MAX_FILES} ]]; then
        # Keep the MAX_FILES most-recently-modified; record the rest as skipped.
        local kept; kept="$(printf '%s\n' "${uniq[@]}" | while IFS= read -r f; do printf '%s\t%s\n' "$(stat -c %Y "$f" 2>/dev/null || echo 0)" "$f"; done | sort -rn | cut -f2-)"
        local -a ordered=(); while IFS= read -r f; do [[ -n "$f" ]] && ordered+=("$f"); done <<< "$kept"
        local i=0
        for f in "${ordered[@]}"; do
            if [[ $i -lt ${NFTBAN_HTTP_LOG_MAX_FILES} ]]; then _NFTBAN_HTTP_LAST_SELECTED+=("$f"); else _NFTBAN_HTTP_LAST_SKIPPED+=("$f: over MAX_FILES=${NFTBAN_HTTP_LOG_MAX_FILES}"); fi
            i=$((i+1))
        done
    else
        _NFTBAN_HTTP_LAST_SELECTED=("${uniq[@]}")
    fi

    printf '%s\n' "${_NFTBAN_HTTP_LAST_SELECTED[@]}"
    return 0
}

# Bounded incremental reader for ONE file. Emits only NEW bytes since the last
# call (per-file offset keyed by path), capped at MAX_BYTES. Handles rotation
# (inode change) and truncation (size < stored offset) by reading from BOF.
# Falls back to a bounded tail if the offset dir is not writable (never blind).
nftban_http_read_incremental() {
    local file="$1"
    [[ -f "$file" && -r "$file" ]] || return 0
    local size inode key statefile prev_off prev_ino start
    size="$(stat -c %s "$file" 2>/dev/null || echo 0)"
    inode="$(stat -c %i "$file" 2>/dev/null || echo 0)"
    key="$(printf '%s' "$file" | tr '/' '_' )"
    statefile="${NFTBAN_HTTP_LOG_OFFSET_DIR}/${key}"

    if ! mkdir -p "${NFTBAN_HTTP_LOG_OFFSET_DIR}" 2>/dev/null; then
        # No state dir → bounded tail (last MAX_BYTES) so we still detect, just not incrementally.
        tail -c "${NFTBAN_HTTP_LOG_MAX_BYTES}" "$file" 2>/dev/null
        return 0
    fi

    prev_off=0; prev_ino=0
    if [[ -r "$statefile" ]]; then
        IFS=':' read -r prev_ino prev_off < "$statefile" 2>/dev/null || { prev_ino=0; prev_off=0; }
    fi
    [[ "$prev_ino" =~ ^[0-9]+$ ]] || prev_ino=0
    [[ "$prev_off" =~ ^[0-9]+$ ]] || prev_off=0

    if [[ "$inode" != "$prev_ino" || "$prev_off" -gt "$size" ]]; then
        start=0   # rotated or truncated → read from BOF (bounded below)
    else
        start="$prev_off"
    fi

    # Bound the read window to MAX_BYTES (read the newest MAX_BYTES if the gap is huge).
    if [[ $((size - start)) -gt ${NFTBAN_HTTP_LOG_MAX_BYTES} ]]; then
        start=$((size - NFTBAN_HTTP_LOG_MAX_BYTES))
    fi

    if [[ "$size" -gt "$start" ]]; then
        tail -c +$((start + 1)) "$file" 2>/dev/null | head -c "${NFTBAN_HTTP_LOG_MAX_BYTES}"
    fi
    # Persist new offset = current size (atomic-ish).
    printf '%s:%s\n' "$inode" "$size" > "${statefile}.tmp" 2>/dev/null && mv -f "${statefile}.tmp" "$statefile" 2>/dev/null
    return 0
}
