#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.4.0 - Firewall Management Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Firewall validation, conflicts, stats, logs, and atomic rollback
#
# meta:name="cmd_firewall"
# meta:type="cli"
# meta:header="NFTBan Firewall Command"
# meta:version="1.78.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Firewall management: validate --strict, conflicts, restore, rebuild, reset"
# meta:inventory.files=""
# meta:inventory.binaries="nft,journalctl,systemctl"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/conf.d/fwlog.conf"
# meta:inventory.systemd_units="fail2ban.service,firewalld.service,ufw.service,lfd.service"
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2025-11-13"
# meta:updated_date="2026-02-20"
# =============================================================================

set -Eeuo pipefail


# =============================================================================
# CONFIGURATION
# =============================================================================

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" 2>/dev/null || true

: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"
: "${NFTBAN_CLI_DIR:=/usr/lib/nftban/cli}"

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/strict.sh" || return 1
else
    # Fallback to manual strict mode
    set -Eeuo pipefail
fi

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/version.sh" || return 1
fi


# Load NFT schema (single source of truth for table/set names)
# shellcheck source=/usr/lib/nftban/lib/nft_schema.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" || return 1
fi

# Load timestamp library (unified timestamp generation)
# shellcheck source=/usr/lib/nftban/lib/nftban_timestamp.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_timestamp.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_timestamp.sh" || return 1
fi

# Load service control library (systemd service/timer primitives)
# shellcheck source=/usr/lib/nftban/lib/nftban_service_control.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_service_control.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_service_control.sh" || return 1
fi

# Load JSON helper for --json support
JSON_HELPER="${NFTBAN_LIB_DIR}/helpers/json_output.sh"
if [[ -f "$JSON_HELPER" ]]; then
    # shellcheck source=/dev/null
    source "$JSON_HELPER" || return 1
fi

# =============================================================================
# HELPERS
# =============================================================================

_firewall_substitute_placeholders() {
    # Substitute __SSH_PORT__ and __CT_LIMIT_*__ placeholders in nftables.conf
    # Usage: _firewall_substitute_placeholders <input_file> <output_file>
    # v1.49.0 FIX-F: CT limits unified with DDoS module config
    # v1.59.0 BUG-2: Fixed SSH port detection priority (sshd_config first, not nft set)
    # v1.59.0 BUG-3: Added input/output guard checks
    local input="$1" output="$2"

    # BUG-3: Guard — verify input exists and output dir is writable
    if [[ ! -f "$input" ]]; then
        echo "[NFTBan ERROR] Template file not found: $input" >&2
        return 1
    fi
    if [[ ! -r "$input" ]]; then
        echo "[NFTBan ERROR] Template file not readable: $input" >&2
        return 1
    fi
    local _output_dir
    _output_dir="$(dirname "$output")"
    if [[ ! -d "$_output_dir" || ! -w "$_output_dir" ]]; then
        echo "[NFTBan ERROR] Output directory not writable: $_output_dir" >&2
        return 1
    fi

    # v1.145 lockout fix (HOLD_V145_AND_FIX_SHELL_RENDER_PORTSD_UNION):
    # __SSH_PORT__ appears ONLY inside `elements = { ... }` for ssh_ports and
    # tcp_ports_in (both ip and ip6) — there is NO single-value context. So we
    # substitute the FULL detected SSH union (comma-separated), NOT just the
    # primary. This keeps EVERY detected SSH listener port in BOTH sets on every
    # reload/rebuild, so a multi-port host can never collapse to primary-only
    # and `nftban firewall reload` can never drop an operator connected on a
    # secondary SSH port. Fallback chain: live union -> ports.d union -> primary
    # -> 22 (never empty, never primary-only when more ports are live).
    local _ssh_port="" _ssh_ports_csv=""
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/ssh_port_detect.sh" 2>/dev/null || true
    if declare -f nftban_detect_ssh_ports >/dev/null 2>&1; then
        _ssh_ports_csv=$(nftban_detect_ssh_ports 2>/dev/null | grep -E '^[0-9]+$' | paste -sd, - 2>/dev/null) || true
    fi
    if declare -f nftban_detect_ssh_primary_port >/dev/null 2>&1; then
        _ssh_port=$(nftban_detect_ssh_primary_port 2>/dev/null) || true
    fi
    [[ -z "$_ssh_port" || ! "$_ssh_port" =~ ^[0-9]+$ ]] && _ssh_port=22
    # Fallback to the persisted ports.d SSH union if live detection returned nothing.
    if [[ -z "$_ssh_ports_csv" ]]; then
        local _portsd="${NFTBAN_CONFIG_DIR:-/etc/nftban}/ports.d/00-ssh.conf"
        if [[ -f "$_portsd" ]]; then
            _ssh_ports_csv=$(grep -oE '^[0-9]+' "$_portsd" 2>/dev/null | sort -un | paste -sd, - 2>/dev/null) || true
        fi
    fi
    # Final fallback: primary (then 22 via the guard above).
    [[ -z "$_ssh_ports_csv" ]] && _ssh_ports_csv="$_ssh_port"
    # Template style: "22, 2222, 55000"
    _ssh_ports_csv=$(printf '%s' "$_ssh_ports_csv" | sed 's/,/, /g')

    # CT limits — use DDoS config when available, else sensible defaults
    local _ct_ssh=15 _ct_http=150 _ct_mail=150
    local _ddos_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/ddos/classic.conf"
    local _ddos_local="${_ddos_conf}.local"
    # Source DDoS config (defaults then overrides) to get tuned limits
    # shellcheck disable=SC1090  # dynamic config path
    [[ -f "$_ddos_conf" ]] && source "$_ddos_conf" 2>/dev/null || true
    # shellcheck disable=SC1090  # dynamic config path
    [[ -f "$_ddos_local" ]] && source "$_ddos_local" 2>/dev/null || true
    # Use DDoS limits if defined, keeping base defaults as fallback
    [[ -n "${DDOS_CLASSIC_SSH_CONN_LIMIT:-}" ]] && _ct_ssh="$DDOS_CLASSIC_SSH_CONN_LIMIT"
    [[ -n "${DDOS_CLASSIC_HTTP_CONN_LIMIT:-}" ]] && _ct_http="$DDOS_CLASSIC_HTTP_CONN_LIMIT"
    [[ -n "${DDOS_CLASSIC_SMTP_CONN_LIMIT:-}" ]] && _ct_mail="$DDOS_CLASSIC_SMTP_CONN_LIMIT"

    sed -e "s/__SSH_PORT__/${_ssh_ports_csv}/g" \
        -e "s/__CT_LIMIT_SSH__/${_ct_ssh}/g" \
        -e "s/__CT_LIMIT_HTTP__/${_ct_http}/g" \
        -e "s/__CT_LIMIT_MAIL__/${_ct_mail}/g" \
        "$input" > "$output"
}

# =============================================================================
# MAIN COMMAND HANDLER
# =============================================================================

nftban_cmd_firewall() {
    # Main firewall command handler
    # Usage: nftban firewall <subcommand> [options]

    local subcommand="${1:-help}"

    # Check for --json flag in all args (suppress banner for JSON output)
    local json_mode=false
    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && json_mode=true && break || true
    done

    # Show banner (skip for JSON output to avoid polluting machine-readable output)
    if [[ "$json_mode" == "false" ]]; then
        if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
            # shellcheck source=/dev/null
            source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
            if [[ $(type -t nftban_banner) == "function" ]]; then
                nftban_banner
            fi
        fi
        echo ""
    fi

    case "$subcommand" in
        help|-h|--help)
            show_firewall_help
            return 0
            ;;
        status)
            shift
            firewall_status "$@"
            ;;
        init)
            # v1.38.0: BUG-002 — alias to rebuild (firewall init was never implemented)
            shift
            firewall_rebuild "$@"
            ;;
        validate)
            shift
            firewall_validate "$@"
            ;;
        check)
            shift
            firewall_check "$@"
            ;;
        stats)
            shift
            firewall_stats "$@"
            ;;
        logs)
            shift
            # Load logs command on-demand
            if [[ -f "${NFTBAN_CLI_DIR}/cmd_firewall_logs.sh" ]]; then
                # shellcheck source=/dev/null
                source "${NFTBAN_CLI_DIR}/cmd_firewall_logs.sh" || return 1
                nftban_cmd_firewall_logs "$@"
            else
                echo "ERROR: Firewall logs module not found" >&2
                return 1
            fi
            ;;
        reload)
            shift
            firewall_reload "$@"
            ;;
        rebuild)
            shift
            firewall_rebuild "$@"
            ;;
        reset)
            shift
            firewall_reset "$@"
            ;;
        conflicts)
            # Delegate to health conflicts (single implementation)
            shift
            if [[ -f "${NFTBAN_CLI_DIR}/cmd_health_analysis.sh" ]]; then
                # shellcheck source=/dev/null
                source "${NFTBAN_CLI_DIR}/cmd_health_analysis.sh" || return 1
                nftban_health_cmd_conflicts "$@"
            else
                echo "ERROR: Health analysis module not found" >&2
                return 1
            fi
            ;;
        restore)
            shift
            firewall_restore "$@"
            ;;
        record)
            shift
            firewall_record "$@"
            ;;
        takeover)
            shift
            firewall_takeover "$@"
            ;;
        whitelist-session)
            shift
            firewall_whitelist_session "$@"
            ;;
        *)
            echo "ERROR: Unknown firewall subcommand: $subcommand" >&2
            echo "Try 'nftban firewall help' for more information." >&2
            return 1
            ;;
    esac
}

# =============================================================================
# SUBCOMMAND: WHITELIST-SESSION (v1.120 — D-UPDATE-OPERATOR-SELF-BAN-GAP-001)
# =============================================================================
# Manage time-bounded operator-session whitelist entries in
# /etc/nftban/whitelist.d/00-session.conf. Each entry carries an inline
# `# EXPIRES_AT=<RFC3339>` marker; the whitelist loader (v1.119 CIDR-aware,
# extended in v1.120) skips expired entries at load time.
#
# v1.120 ships text-mode only. The `--json` flag is REJECTED with an
# operator-actionable error message per V120_OPERATOR_TEMP_WHITELIST_
# SCHEMA_IMPACT_DECISION.md §4 amendment (deferred to v1.121 pending the
# Q2 schema-envelope question).
firewall_whitelist_session() {
    local action="${1:-}"
    [[ -n "$action" ]] && shift

    # V120 §4 amendment: reject --json early at every entry point.
    # The loop below checks ALL remaining args for --json or -j and refuses.
    local arg
    for arg in "$@"; do
        case "$arg" in
            --json|-j)
                cat >&2 <<'JSON_REFUSE_EOF'
ERROR: --json output for `nftban firewall whitelist-session` is NOT supported in v1.120.

Per V120_OPERATOR_TEMP_WHITELIST_SCHEMA_IMPACT_DECISION.md, JSON output for
this new subcommand was deferred from v1.120 pending an operator decision
on whether new top-level CLI subcommand JSON falls under the M81-6 Status
JSON wire-format freeze envelope. v1.120 supports TEXT MODE only.

If you need machine-readable output, parse the text-mode `list` output OR
read /etc/nftban/whitelist.d/00-session.conf directly (one entry per line,
inline `# EXPIRES_AT=<RFC3339>  REASON=<...>  ADDED_BY=<...>` markers).

JSON support is planned for v1.121 if/when the schema decision is locked.
JSON_REFUSE_EOF
                return 2
                ;;
        esac
    done

    case "$action" in
        add)        _whitelist_session_add "$@" ;;
        list)       _whitelist_session_list "$@" ;;
        remove|rm)  _whitelist_session_remove "$@" ;;
        cleanup)    _whitelist_session_cleanup "$@" ;;
        -h|--help|help|"")
            cat <<'HELP_EOF'
Usage: nftban firewall whitelist-session <action> [args]

Manage time-bounded operator-session whitelist entries.

Actions:
  add <ip-or-cidr> --ttl <duration> [--reason <text>]
      Add a temporary whitelist entry with EXPIRES_AT = now + ttl.
      Duration format: 30m, 1h, 1h30m, 24h, etc. (Go's time.ParseDuration).
      Re-adding the same IP REFRESHES the entry (does not duplicate).
      Calls `nftban firewall reload` to make the entry effective immediately.

  list
      Show all non-expired session entries: IP | TTL remaining | Reason | Added-By.
      Text-mode only; --json deferred to v1.121 (see V120 schema decision).

  remove <ip-or-cidr>
      Delete the entry for the given IP from 00-session.conf and reload.

  cleanup
      Manually remove all expired entries from 00-session.conf.
      (The loader skips expired entries at load time regardless; this is
      file-hygiene only.)

Notes:
  - This file is machine-managed: do NOT hand-edit /etc/nftban/whitelist.d/00-session.conf.
  - Permanent operator entries belong in 99-manual.conf (NOT this file).
  - Static host-interface entries belong in 00-system.conf (NOT this file).
  - Requires elevated privileges (writes /etc/nftban/whitelist.d/); members of the nftban group are authorized via PolicyKit/polkit rules.

V120 (D-UPDATE-OPERATOR-SELF-BAN-GAP-001): closes the operator self-ban gap by
ensuring `nftban update` / `firewall takeover` / validation workflows
auto-seed the operator's SSH peer IP into this file with a bounded TTL.
This subcommand is the explicit operator-override for cases where
auto-seed cannot detect the right IP (multi-hop SSH, sudo chains, etc.).

HELP_EOF
            return 0
            ;;
        *)
            echo "ERROR: Unknown whitelist-session action: $action" >&2
            echo "Try 'nftban firewall whitelist-session help' for usage." >&2
            return 1
            ;;
    esac
}

# Internal helper: 00-session.conf path
_NFTBAN_SESSION_WHITELIST_PATH="/etc/nftban/whitelist.d/00-session.conf"

# Internal helper: validate IP or CIDR. Returns 0 if valid, 1 otherwise.
# Uses basic bash regex; not as strict as Go's net.ParseIP but catches
# obvious garbage. Real validation happens at whitelist-load time.
_whitelist_session_validate_ip() {
    local v="$1"
    # IPv4: a.b.c.d optionally /N
    [[ "$v" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] && return 0
    # IPv6: very loose pattern (full validation is the loader's job)
    [[ "$v" =~ ^[0-9a-fA-F:]+(/[0-9]{1,3})?$ && "$v" == *:* ]] && return 0
    return 1
}

# Internal helper: convert TTL like "30m" / "1h" / "1h30m" to seconds.
# Returns the integer count of seconds on stdout, or 1 on parse error.
_whitelist_session_ttl_seconds() {
    local ttl="$1"
    if [[ -z "$ttl" ]]; then
        echo "0"; return 1
    fi
    local total=0
    local rest="$ttl"
    while [[ -n "$rest" ]]; do
        if [[ "$rest" =~ ^([0-9]+)h(.*)$ ]]; then
            total=$(( total + ${BASH_REMATCH[1]} * 3600 ))
            rest="${BASH_REMATCH[2]}"
        elif [[ "$rest" =~ ^([0-9]+)m(.*)$ ]]; then
            total=$(( total + ${BASH_REMATCH[1]} * 60 ))
            rest="${BASH_REMATCH[2]}"
        elif [[ "$rest" =~ ^([0-9]+)s(.*)$ ]]; then
            total=$(( total + ${BASH_REMATCH[1]} ))
            rest="${BASH_REMATCH[2]}"
        elif [[ "$rest" =~ ^([0-9]+)$ ]]; then
            # bare integer = seconds
            total=$(( total + ${BASH_REMATCH[1]} ))
            rest=""
        else
            echo "0"; return 1
        fi
    done
    echo "$total"
    return 0
}

# Internal: ensure 00-session.conf has the canonical header on first write.
_whitelist_session_ensure_header() {
    [[ -f "$_NFTBAN_SESSION_WHITELIST_PATH" ]] && return 0
    mkdir -p "$(dirname "$_NFTBAN_SESSION_WHITELIST_PATH")"
    cat > "$_NFTBAN_SESSION_WHITELIST_PATH" <<'SESSION_HEADER_EOF'
# =============================================================================
# NFTBan Session Whitelist (managed by nftban; do not hand-edit)
# =============================================================================
#
# Time-bounded operator-session entries with inline EXPIRES_AT TTL.
# Expired entries are skipped at whitelist-load time. Use:
#   nftban firewall whitelist-session add <ip> --ttl 30m
#   nftban firewall whitelist-session list
#   nftban firewall whitelist-session remove <ip>
#   nftban firewall whitelist-session cleanup
#
# Permanent operator entries: 99-manual.conf  (NOT this file)
# Static host-interface entries: 00-system.conf  (NOT this file)
#
# =============================================================================

SESSION_HEADER_EOF
    chmod 0640 "$_NFTBAN_SESSION_WHITELIST_PATH" 2>/dev/null || true
    chown root:nftban "$_NFTBAN_SESSION_WHITELIST_PATH" 2>/dev/null || true
}

_whitelist_session_add() {
    local ip=""
    local ttl=""
    local reason="operator-explicit"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ttl)     ttl="$2"; shift 2 ;;
            --reason)  reason="$2"; shift 2 ;;
            -h|--help) _whitelist_session_add_help; return 0 ;;
            -*)        echo "ERROR: Unknown flag: $1" >&2; return 1 ;;
            *)
                if [[ -z "$ip" ]]; then
                    ip="$1"; shift
                else
                    echo "ERROR: Unexpected argument: $1" >&2
                    return 1
                fi
                ;;
        esac
    done

    if [[ -z "$ip" || -z "$ttl" ]]; then
        echo "ERROR: <ip> and --ttl are required" >&2
        _whitelist_session_add_help
        return 1
    fi

    if ! _whitelist_session_validate_ip "$ip"; then
        echo "ERROR: Invalid IP or CIDR: $ip" >&2
        return 1
    fi

    local ttl_sec
    ttl_sec=$(_whitelist_session_ttl_seconds "$ttl") || {
        echo "ERROR: Invalid --ttl value: $ttl (use formats like 30m, 1h, 1h30m)" >&2
        return 1
    }
    if [[ "$ttl_sec" -le 0 ]]; then
        echo "ERROR: --ttl must be > 0" >&2
        return 1
    fi

    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: PolicyKit/polkit authorization failed or insufficient privileges to write $_NFTBAN_SESSION_WHITELIST_PATH" >&2
        return 1
    fi

    _whitelist_session_ensure_header

    local expires_at
    expires_at=$(date -u -d "@$(( $(date -u +%s) + ttl_sec ))" '+%Y-%m-%dT%H:%M:%SZ')

    # Remove any prior entry for the same IP (refresh semantics).
    local tmp
    tmp=$(mktemp "${_NFTBAN_SESSION_WHITELIST_PATH}.XXXXXX")
    # shellcheck disable=SC2016
    awk -v ip="$ip" '
        # Drop entry lines whose first token equals ip
        {
            t = $0
            # Strip leading whitespace
            gsub(/^[ \t]+/, "", t)
            # If line starts with # or is empty, keep as-is
            if (t == "" || substr(t, 1, 1) == "#") { print; next }
            # Take first whitespace-delimited token; strip trailing comment
            split(t, a, "#")
            n = split(a[1], b, /[ \t]+/)
            if (n >= 1 && b[1] == ip) next   # drop
            print
        }
    ' "$_NFTBAN_SESSION_WHITELIST_PATH" > "$tmp"

    # Append the new entry.
    printf '%s  # EXPIRES_AT=%s  REASON=%s  ADDED_BY=nftban-firewall-whitelist-session\n' \
        "$ip" "$expires_at" "$reason" >> "$tmp"

    # Atomic rename.
    mv "$tmp" "$_NFTBAN_SESSION_WHITELIST_PATH"
    chmod 0640 "$_NFTBAN_SESSION_WHITELIST_PATH" 2>/dev/null || true
    chown root:nftban "$_NFTBAN_SESSION_WHITELIST_PATH" 2>/dev/null || true

    echo "Added: $ip  (expires $expires_at, reason=$reason)"

    # Trigger reload so the daemon picks up the new entry immediately.
    if command -v nftban >/dev/null 2>&1; then
        nftban firewall reload >/dev/null 2>&1 || true
    fi
    return 0
}

_whitelist_session_add_help() {
    cat <<'HELP_EOF'
Usage: nftban firewall whitelist-session add <ip-or-cidr> --ttl <duration> [--reason <text>]

Add a time-bounded whitelist entry for the operator-session.

Required:
  <ip-or-cidr>           IPv4 or IPv6 address, optionally with CIDR suffix.
  --ttl <duration>       Time-to-live: 30m, 1h, 1h30m, 24h, 3600s, etc.

Optional:
  --reason <text>        Short description (default: "operator-explicit").

Examples:
  nftban firewall whitelist-session add 62.38.150.122 --ttl 30m
  nftban firewall whitelist-session add 192.168.1.0/24 --ttl 1h --reason "office VPN"
HELP_EOF
}

_whitelist_session_list() {
    if [[ ! -f "$_NFTBAN_SESSION_WHITELIST_PATH" ]]; then
        echo "(no session whitelist entries — file absent)"
        return 0
    fi

    local now_unix
    now_unix=$(date -u +%s)

    local count=0
    printf '%-22s %-12s %-30s %s\n' "IP/CIDR" "TTL-LEFT" "REASON" "ADDED-BY"
    printf '%-22s %-12s %-30s %s\n' "----------------------" "------------" "------------------------------" "--------"

    local line
    while IFS= read -r line; do
        # Skip blank and comment lines (header)
        local trimmed="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$trimmed" ]] && continue
        [[ "$trimmed" =~ ^# ]] && continue

        # Extract IP token (first whitespace-delimited field before #)
        local before_hash="${line%%#*}"
        local ip
        # shellcheck disable=SC2086
        ip=$(echo $before_hash | awk '{print $1}')
        [[ -z "$ip" ]] && continue

        # Extract EXPIRES_AT, REASON, ADDED_BY from the comment portion
        local expires_at="" reason="-" added_by="-"
        if [[ "$line" == *EXPIRES_AT=* ]]; then
            expires_at=$(echo "$line" | grep -oE 'EXPIRES_AT=[^ ]+' | head -1 | cut -d= -f2)
        fi
        if [[ "$line" == *REASON=* ]]; then
            reason=$(echo "$line" | grep -oE 'REASON=[^ ]+' | head -1 | cut -d= -f2)
        fi
        if [[ "$line" == *ADDED_BY=* ]]; then
            added_by=$(echo "$line" | grep -oE 'ADDED_BY=[^ ]+' | head -1 | cut -d= -f2)
        fi

        if [[ -z "$expires_at" ]]; then
            continue
        fi

        # Compute TTL remaining
        local expires_unix
        expires_unix=$(date -u -d "$expires_at" +%s 2>/dev/null) || continue
        local ttl_left=$(( expires_unix - now_unix ))
        if [[ "$ttl_left" -le 0 ]]; then
            continue  # skip expired
        fi

        local ttl_pretty
        if [[ "$ttl_left" -ge 3600 ]]; then
            ttl_pretty="$(( ttl_left / 3600 ))h$(( (ttl_left % 3600) / 60 ))m"
        elif [[ "$ttl_left" -ge 60 ]]; then
            ttl_pretty="$(( ttl_left / 60 ))m$(( ttl_left % 60 ))s"
        else
            ttl_pretty="${ttl_left}s"
        fi

        printf '%-22s %-12s %-30s %s\n' "$ip" "$ttl_pretty" "$reason" "$added_by"
        count=$(( count + 1 ))
    done < "$_NFTBAN_SESSION_WHITELIST_PATH"

    echo ""
    echo "($count active session whitelist entries)"
}

_whitelist_session_remove() {
    local ip="${1:-}"
    if [[ -z "$ip" ]]; then
        echo "ERROR: <ip-or-cidr> is required" >&2
        echo "Usage: nftban firewall whitelist-session remove <ip-or-cidr>" >&2
        return 1
    fi

    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: PolicyKit/polkit authorization failed or insufficient privileges to write $_NFTBAN_SESSION_WHITELIST_PATH" >&2
        return 1
    fi

    if [[ ! -f "$_NFTBAN_SESSION_WHITELIST_PATH" ]]; then
        echo "(no session whitelist file — nothing to remove)"
        return 0
    fi

    local tmp
    tmp=$(mktemp "${_NFTBAN_SESSION_WHITELIST_PATH}.XXXXXX")
    local removed=0
    # SC2016: single-quoted awk script (intentional — awk variable references,
    # not bash expansion). SC2327/SC2328: the awk capture is dead-code by design
    # — stdout goes to "$tmp" via `> "$tmp"`, stderr is process-substituted
    # through `tail -1`, and the outer command-substitution captures the empty
    # stdout. The real "removed" count is computed via the IP-presence re-check
    # below (see "Re-count removed by diffing against the original" block).
    # Kept as-is to avoid behavior churn in v1.124.1 hotfix; the cleaner
    # refactor (drop the dead capture and the END block) is deferred to V125+.
    # shellcheck disable=SC2016,SC2327,SC2328
    removed=$(awk -v ip="$ip" '
        {
            t = $0
            gsub(/^[ \t]+/, "", t)
            if (t == "" || substr(t, 1, 1) == "#") { print; next }
            split(t, a, "#")
            n = split(a[1], b, /[ \t]+/)
            if (n >= 1 && b[1] == ip) { count++; next }
            print
        }
        END { print count > "/dev/stderr" }
    ' "$_NFTBAN_SESSION_WHITELIST_PATH" 2> >(tail -1) > "$tmp")

    if [[ ! -s "$tmp" ]]; then
        # awk produced no output (file was effectively empty)
        : > "$tmp"
    fi

    mv "$tmp" "$_NFTBAN_SESSION_WHITELIST_PATH"
    chmod 0640 "$_NFTBAN_SESSION_WHITELIST_PATH" 2>/dev/null || true

    # Re-count removed by diffing against the original (simpler & reliable)
    # We approximate count by re-checking presence of the IP.
    if grep -qE "^[[:space:]]*${ip//./\\.}[[:space:]]" "$_NFTBAN_SESSION_WHITELIST_PATH" 2>/dev/null; then
        echo "(no entries removed — $ip not found)"
    else
        echo "Removed: $ip"
    fi

    if command -v nftban >/dev/null 2>&1; then
        nftban firewall reload >/dev/null 2>&1 || true
    fi
    return 0
}

_whitelist_session_cleanup() {
    if [[ ! -f "$_NFTBAN_SESSION_WHITELIST_PATH" ]]; then
        echo "(no session whitelist file — nothing to clean up)"
        return 0
    fi

    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: PolicyKit/polkit authorization failed or insufficient privileges to write $_NFTBAN_SESSION_WHITELIST_PATH" >&2
        return 1
    fi

    local now_unix
    now_unix=$(date -u +%s)
    local tmp
    tmp=$(mktemp "${_NFTBAN_SESSION_WHITELIST_PATH}.XXXXXX")

    local removed=0
    local line
    while IFS= read -r line; do
        local trimmed="${line#"${line%%[![:space:]]*}"}"
        if [[ -z "$trimmed" || "${trimmed:0:1}" == "#" ]]; then
            printf '%s\n' "$line" >> "$tmp"
            continue
        fi

        # Entry line — check EXPIRES_AT
        if [[ "$line" == *EXPIRES_AT=* ]]; then
            local expires_at
            expires_at=$(echo "$line" | grep -oE 'EXPIRES_AT=[^ ]+' | head -1 | cut -d= -f2)
            local expires_unix
            expires_unix=$(date -u -d "$expires_at" +%s 2>/dev/null)
            if [[ -z "$expires_unix" ]]; then
                # Unparseable — drop conservatively
                removed=$(( removed + 1 ))
                continue
            fi
            if [[ "$expires_unix" -le "$now_unix" ]]; then
                # Expired — drop
                removed=$(( removed + 1 ))
                continue
            fi
        fi
        # No EXPIRES_AT marker OR not expired — keep
        printf '%s\n' "$line" >> "$tmp"
    done < "$_NFTBAN_SESSION_WHITELIST_PATH"

    mv "$tmp" "$_NFTBAN_SESSION_WHITELIST_PATH"
    chmod 0640 "$_NFTBAN_SESSION_WHITELIST_PATH" 2>/dev/null || true

    if [[ "$removed" -gt 0 ]]; then
        echo "Removed $removed expired entries"
        if command -v nftban >/dev/null 2>&1; then
            nftban firewall reload >/dev/null 2>&1 || true
        fi
    else
        echo "(no expired entries — nothing to remove)"
    fi
    return 0
}

# =============================================================================
# SUBCOMMAND: TAKEOVER (v1.117 — registry-backed discoverability)
# =============================================================================
# Forwards to the installer's panel-auto-takeover flow. The mechanism is
# unchanged from PR-22B; this is a discoverability surface only. The actual
# disarm logic lives in cmd/nftban-installer + internal/installer/switchop.
firewall_takeover() {
    local panel_auto=false
    local dry_run=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --panel-auto-takeover) panel_auto=true; shift ;;
            --dry-run|-n) dry_run=true; shift ;;
            -h|--help|help)
                cat <<'HELP_EOF'
Usage: nftban firewall takeover [--panel-auto-takeover] [--dry-run]

Disarm conflicting external firewalls (CSF/iptables/firewalld) so nftban
can become the sole authority on this host. REVERSIBLE.

Options:
  --panel-auto-takeover   Allow detected control-panel presence
                          (cPanel/Plesk/DirectAdmin) to auto-approve
                          takeover. Default OFF (PR-22B gate).
                          This is a PERMISSION flag — it permits
                          panel-aware conflict handling.
                          The flag does NOT itself authorize takeover.
                          The wrapper supplies the real takeover
                          authorization (--takeover) internally when
                          this flag is set on a real (non-dry-run) call.
  --dry-run, -n           Preview the takeover wrapper path only. Uses
                          an upgrade-mode preview because the installer
                          does not implement an honest install-mode
                          dry-run orchestrator (v1.100 PR-22B scope).
                          --dry-run does NOT perform conflict disarm or
                          authority transition, and is NOT an exact
                          simulation of the install-mode takeover phases.

What this wrapper does for a real (non-dry-run) call:
  nftban firewall takeover --panel-auto-takeover  ← supported takeover
  is the public CLI for source-install or RPM hosts where install_state
  AUTHORITY=AMBIGUOUS or CONFLICTS!=(empty). The wrapper invokes the
  installer with takeover authorization to disarm detected panel /
  external-firewall conflicts so nftban becomes the sole authority.

Underlying invocation (v1.124+):
  Real:    nftban-installer --mode=install --takeover --force [--panel-auto-takeover]
  Dry-run: nftban-installer --mode=upgrade --dry-run [--panel-auto-takeover]

Why two modes:
  --takeover is the authorizer (cmd/nftban-installer/main.go:104-106;
  sets NFTBAN_TAKEOVER=1; reaches switchop.DisableConflicts via the
  authority classifier's takeover branch at phases.go:259).
  --panel-auto-takeover (flags.go:127-128) only opts panel presence
  into auto-approval; it does NOT itself initiate the takeover branch.
  Both flags are passed on real runs.

What disarm does (reversible):
  - External firewall binary renamed to <name>.disabled (sha256-equal)
  - Service masked (systemctl mask)
  - Config trees preserved verbatim
  - Cron-backup manifest written before any rm

To reverse:
  nftban firewall restore csf
  # or equivalently:
  /usr/lib/nftban/bin/nftban-installer --mode=restore

Env mirror:
  NFTBAN_PANEL_AUTO_TAKEOVER=1   useful for cloud-init / Ansible /
                                 package %post hooks.

Requires elevated privileges (members of the nftban group are authorized via PolicyKit/polkit rules).
HELP_EOF
                return 0
                ;;
            *)
                echo "ERROR: Unknown takeover argument: $1" >&2
                echo "Try 'nftban firewall takeover --help' for more information." >&2
                return 2
                ;;
        esac
    done

    if [[ "$panel_auto" == "false" && "$dry_run" == "false" ]]; then
        echo "ERROR: nftban firewall takeover requires --panel-auto-takeover or --dry-run." >&2
        echo "  --panel-auto-takeover : opt into auto-approve on detected panel hosts (PR-22B gate)" >&2
        echo "  --dry-run             : preview without changes" >&2
        echo "Reference: nftban firewall takeover --help" >&2
        return 2
    fi

    if [[ $EUID -ne 0 && "$dry_run" == "false" ]]; then
        echo "ERROR: PolicyKit/polkit authorization failed or insufficient privileges (nftban firewall takeover mutates kernel state; members of the nftban group are authorized via PolicyKit/polkit rules)." >&2
        return 1
    fi

    local installer="${NFTBAN_INSTALLER_BIN:-/usr/lib/nftban/bin/nftban-installer}"
    if [[ ! -x "$installer" ]]; then
        echo "ERROR: nftban-installer not found at $installer" >&2
        echo "       Set NFTBAN_INSTALLER_BIN to override path." >&2
        return 1
    fi

    # v1.124 fix (BUG-C / V124_TAKEOVER_CLI_GUIDANCE_AND_WRAPPER_FIX):
    # Real takeover requires --mode=install --takeover. The --panel-auto-takeover
    # flag is a permission (cmd/nftban-installer/flags.go:127-128), not an
    # authorizer; the authorizer is --takeover which sets NFTBAN_TAKEOVER=1
    # (main.go:104-106) and reaches the authority classifier's takeover branch
    # (phases.go:259 → switchop.DisableConflicts).
    # --force is needed because hosts arriving here typically have
    # install_state INSTALL_STATE=COMMITTED (terminal).
    # --mode=install --dry-run is explicitly rejected by the installer
    # ("an honest install dry-run orchestrator is out of scope for v1.100
    # PR-22B"), so --dry-run preview falls back to --mode=upgrade --dry-run
    # which exercises the same preflight/plan code path.
    # dns2 migration evidence:
    # AUDIT_190_LIFECYCLE/DNS2_MIGRATION_EXECUTED_CLOSURE.md §4.4.
    local args
    if [[ "$dry_run" == "true" ]]; then
        args=(--mode=upgrade --dry-run)
    else
        args=(--mode=install --takeover --force)
    fi
    [[ "$panel_auto" == "true" ]] && args+=(--panel-auto-takeover)

    echo "Invoking installer: $installer ${args[*]}"
    exec "$installer" "${args[@]}"
}

# =============================================================================
# SUBCOMMAND: STATUS (v1.38.0 — BUG-001 fix)
# =============================================================================

firewall_status() {
    # Quick situational awareness: tables, sets, services, conflicts
    # Usage: nftban firewall status [--json]

    local json_mode=false
    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && json_mode=true || true
    done

    # --- 1. Tables ---
    local ipv4_table="${NFTBAN_TABLE_IPV4:-ip nftban}"
    local ipv6_table="${NFTBAN_TABLE_IPV6:-ip6 nftban}"
    local v4_ok=false v6_ok=false

    nft list table $ipv4_table &>/dev/null 2>&1 && v4_ok=true
    nft list table $ipv6_table &>/dev/null 2>&1 && v6_ok=true

    if [[ "$json_mode" == "true" ]]; then
        # Collect stats for JSON
        local v4_sets=0 v6_sets=0 v4_chains=0 v6_chains=0 v4_elements=0 v6_elements=0
        # v1.87.2: Use `nft list table` — plural `list sets/chains` with table filter
        # is broken on nftables v1.0.x-v1.1.x.
        if [[ "$v4_ok" == "true" ]]; then
            local _v4_dump
            _v4_dump=$(nft list table $ipv4_table 2>/dev/null || true)
            v4_sets=$(echo "$_v4_dump" | grep -c "set " || true)
            v4_sets=${v4_sets:-0}
            v4_chains=$(echo "$_v4_dump" | grep -c "chain " || true)
            v4_chains=${v4_chains:-0}
            v4_elements=$(echo "$_v4_dump" | grep -oP 'elements\s*=\s*\K\d+' | paste -sd+ | bc 2>/dev/null || echo 0)
        fi
        if [[ "$v6_ok" == "true" ]]; then
            local _v6_dump
            _v6_dump=$(nft list table $ipv6_table 2>/dev/null || true)
            v6_sets=$(echo "$_v6_dump" | grep -c "set " || true)
            v6_sets=${v6_sets:-0}
            v6_chains=$(echo "$_v6_dump" | grep -c "chain " || true)
            v6_chains=${v6_chains:-0}
            v6_elements=$(echo "$_v6_dump" | grep -oP 'elements\s*=\s*\K\d+' | paste -sd+ | bc 2>/dev/null || echo 0)
        fi

        local daemon_active=false
        systemctl is-active nftband &>/dev/null 2>&1 && daemon_active=true

        cat <<ENDJSON
{
  "tables": {"ipv4": $v4_ok, "ipv6": $v6_ok},
  "sets": {"ipv4": $v4_sets, "ipv6": $v6_sets},
  "chains": {"ipv4": $v4_chains, "ipv6": $v6_chains},
  "elements": {"ipv4": ${v4_elements:-0}, "ipv6": ${v6_elements:-0}},
  "daemon": $daemon_active
}
ENDJSON
        return 0
    fi

    # --- Text output ---
    echo "Firewall Status"
    echo "==============="
    echo ""

    # Tables
    echo "Tables:"
    if [[ "$v4_ok" == "true" ]]; then
        echo "  IPv4 ($ipv4_table): ACTIVE"
    else
        echo "  IPv4 ($ipv4_table): MISSING"
    fi
    if [[ "$v6_ok" == "true" ]]; then
        echo "  IPv6 ($ipv6_table): ACTIVE"
    else
        echo "  IPv6 ($ipv6_table): MISSING"
    fi

    # Sets summary
    echo ""
    echo "Sets:"
    if [[ "$v4_ok" == "true" ]]; then
        local set_count
        set_count=$(nft list table $ipv4_table 2>/dev/null | grep -c "set " || true)
        set_count=${set_count:-0}
        echo "  IPv4: ${set_count} sets"
    fi
    if [[ "$v6_ok" == "true" ]]; then
        local set_count6
        set_count6=$(nft list table $ipv6_table 2>/dev/null | grep -c "set " || true)
        set_count6=${set_count6:-0}
        echo "  IPv6: ${set_count6} sets"
    fi

    # Services
    echo ""
    echo "Services:"
    local services=("nftband" "nftban-maintenance.timer" "nftban-health.timer" "nftban-watchdog.timer")
    for svc in "${services[@]}"; do
        local state
        state=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
        printf "  %-30s %s\n" "$svc" "$state"
    done

    # Conflicts
    echo ""
    echo "Firewall Conflicts:"
    local has_conflict=false
    for fw in fail2ban firewalld ufw csf lfd; do
        if systemctl is-active "${fw}.service" &>/dev/null 2>&1 || systemctl is-active "${fw}d.service" &>/dev/null 2>&1; then
            echo "  WARNING: $fw is ACTIVE (conflicts with NFTBan)"
            has_conflict=true
        fi
    done
    [[ "$has_conflict" == "false" ]] && echo "  None detected"

    echo ""
    echo "For details: nftban firewall validate --strict"
    echo "For stats:   nftban firewall stats"

    return 0
}

# =============================================================================
# SUBCOMMAND: VALIDATE
# =============================================================================

# Exit codes for strict mode (Single Firewall Authority)
readonly VALIDATE_OK=0
readonly VALIDATE_STRUCTURE_ERROR=1
readonly VALIDATE_POLICYKIT_MISSING=10
readonly VALIDATE_FIREWALL_CONFLICT=20
readonly VALIDATE_NFT_COLLISION=30
readonly VALIDATE_ENV_ERROR=40

firewall_validate() {
    # Validate nftables structure against NFTBan specification
    # Args: [--strict] [--json] [--quiet]
    #
    # --strict: Enforce Single Firewall Authority
    #   - policykit-1 MANDATORY on Debian/Ubuntu
    #   - No competing firewalls (fail2ban, ufw, firewalld, csf)
    #   - No non-NFTBan active input hooks

    local output_json=false
    local strict_mode=false
    local quiet_mode=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                output_json=true
                shift
                ;;
            --strict|-s)
                strict_mode=true
                shift
                ;;
            --quiet|-q)
                quiet_mode=true
                shift
                ;;
            -h|--help)
                show_validate_help
                return 0
                ;;
            *)
                echo "ERROR: Unknown option: $1" >&2
                echo "Try 'nftban firewall validate --help' for more information." >&2
                return 1
                ;;
        esac
    done

    # v1.84 A2-2: Go validator is the sole structural authority.
    # Shell validate_structure removed — no dual-authority path.
    local _go_validator="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/bin/nftban-validate"
    if [[ ! -x "$_go_validator" ]]; then
        [[ "$quiet_mode" != "true" ]] && echo "ERROR: Go validator not found at $_go_validator" >&2
        return $VALIDATE_ENV_ERROR
    fi

    # V130 PR-A Option C closure for D6.A: when running as a non-root operator,
    # route the validator through the polkit-authorized
    # nftban-firewall-validate.service (oneshot, root+CAP_NET_ADMIN). The
    # nftban-group members get authorized via the allowedUnits[] whitelist in
    # 10-nftban-systemd.rules. This preserves the v1.0.19 "no pkexec / no nft
    # polkit" boundary while making `nftban firewall validate` JustWork without
    # sudo. If the unit is missing (e.g. partially-upgraded host pre-v1.130),
    # fall through to direct invocation (which will surface the permission
    # error with the v1.129 PR-C D6.B polkit-aware Remediation).
    local _route_via_systemd=false
    if [[ $EUID -ne 0 ]] \
       && command -v systemctl >/dev/null 2>&1 \
       && systemctl cat nftban-firewall-validate.service &>/dev/null; then
        _route_via_systemd=true
    fi

    # Helper: emit validator JSON to stdout, set _validator_exit to the
    # validator's exit code. Uses direct invocation if root; uses
    # systemctl-then-journal if non-root with the service installed.
    _invoke_validator_json() {
        _validator_exit=0
        if [[ "$_route_via_systemd" == "true" ]]; then
            local _ts_start
            _ts_start=$(date +%s)
            # --wait makes systemctl block until the oneshot finishes; the
            # exit code reflects whether the unit could be started, not the
            # ExecMainStatus. Fetch the validator's true rc separately.
            if ! systemctl start --wait nftban-firewall-validate.service 2>/dev/null; then
                # Service couldn't even start (e.g. polkit denial on a host
                # where the user is not in the nftban group). Fall back to
                # direct invocation so the v1.129 D6.B Remediation surfaces.
                "$_go_validator" --json 2>/dev/null
                _validator_exit=$?
                return $_validator_exit
            fi
            local _es
            _es=$(systemctl show -p ExecMainStatus --value nftban-firewall-validate.service 2>/dev/null)
            [[ -n "$_es" ]] && _validator_exit=$_es
            # V131.1 D13 fix: read the validator JSON from the group-readable
            # file the ExecStart wrapper (firewall_validate_run.sh) writes,
            # NOT from the unit journal. A non-root nftban-group operator (the
            # whole point of Option C) cannot read this unit's journal without
            # systemd-journal/adm membership, so the old journalctl read (D10)
            # returned empty for exactly the users this service exists to serve.
            # The wrapper writes /run/nftban/firewall-validate/last.json with
            # chgrp nftban + chmod 0640 — that file is the PRIMARY source now.
            local _runfile="${NFTBAN_RUN_DIR:-/run/nftban}/firewall-validate/last.json"
            local _output=""
            _output=$(cat "$_runfile" 2>/dev/null)
            # Last-resort fallback ONLY if the file is empty/unreadable (e.g. an
            # unusual /run on a root invocation): try the journal once so root
            # still works. Non-root operators rely on the file above.
            if [[ -z "$_output" ]]; then
                _output=$(journalctl -u nftban-firewall-validate.service --since "@${_ts_start}" -o cat 2>/dev/null)
            fi
            printf '%s' "$_output"
        else
            "$_go_validator" --json 2>/dev/null
            _validator_exit=$?
        fi
    }

    local validation_result=$VALIDATE_OK
    local _validator_exit=0
    local go_exit=0

    if [[ "$quiet_mode" == "true" ]]; then
        _invoke_validator_json >/dev/null
        go_exit=$_validator_exit
    elif [[ "$output_json" == "true" ]]; then
        _invoke_validator_json
        go_exit=$_validator_exit
    else
        # Human-readable: render validator JSON as text
        local _val_json
        _val_json=$(_invoke_validator_json)
        go_exit=$_validator_exit
        if [[ -n "$_val_json" ]] && command -v jq >/dev/null 2>&1; then
            local _val_status
            _val_status=$(echo "$_val_json" | jq -r '.status' 2>/dev/null)
            echo "Validator Status: $(echo "$_val_status" | tr '[:lower:]' '[:upper:]')"
            echo "$_val_json" | jq -r '.findings[] | "  [\(.severity | ascii_upcase)] \(.code): \(.message)"' 2>/dev/null || true
        elif [[ -n "$_val_json" ]]; then
            echo "$_val_json"
        fi
    fi

    if [[ $go_exit -ne 0 ]]; then
        validation_result=$VALIDATE_STRUCTURE_ERROR
    fi

    # If strict mode, run additional checks
    if [[ "$strict_mode" == "true" ]]; then
        local strict_exit=$VALIDATE_OK
        # V129 PR-C D8: tell strict mode whether the structural validator passed
        # so its footer label matches the exit code we'll return.
        local _struct_ok="true"
        [[ $validation_result -ne $VALIDATE_OK ]] && _struct_ok="false"
        if [[ "$quiet_mode" == "true" ]]; then
            _firewall_validate_strict "$output_json" "$_struct_ok" >/dev/null 2>&1 || strict_exit=$?
        else
            _firewall_validate_strict "$output_json" "$_struct_ok" || strict_exit=$?
        fi

        # Return the more severe exit code
        if [[ $strict_exit -ne $VALIDATE_OK ]]; then
            return $strict_exit
        fi
    fi

    return $validation_result
}

# =============================================================================
# STRICT MODE VALIDATION (Single Firewall Authority)
# =============================================================================

_firewall_validate_strict() {
    # Enforce Single Firewall Authority
    # Returns: 0=OK, 10=policykit, 20=conflict, 30=collision, 40=env
    # V129 PR-C D8: 2nd arg `structural_ok` ("true"/"false") tells strict mode
    # whether the structural validator passed. When false, the strict-mode
    # footer MUST NOT say PASSED — the operator must see a UX-consistent
    # report that matches the nonzero exit code from the caller.
    local json_mode="${1:-false}"
    local structural_ok="${2:-true}"

    [[ "$json_mode" == "false" ]] && echo ""
    [[ "$json_mode" == "false" ]] && echo "STRICT MODE: Single Firewall Authority Check"
    [[ "$json_mode" == "false" ]] && echo "=============================================="

    # Check 1: policykit-1 on Debian/Ubuntu
    if ! _check_policykit "$json_mode"; then
        return $VALIDATE_POLICYKIT_MISSING
    fi

    # Check 2: Firewall authority conflicts
    if ! _check_firewall_conflicts "$json_mode"; then
        return $VALIDATE_FIREWALL_CONFLICT
    fi

    # Check 3: NFTables hook collisions (non-NFTBan active input hooks)
    if ! _check_nft_collisions "$json_mode"; then
        return $VALIDATE_NFT_COLLISION
    fi

    [[ "$json_mode" == "false" ]] && echo ""
    if [[ "$structural_ok" == "true" ]]; then
        [[ "$json_mode" == "false" ]] && echo "STRICT PREFLIGHT: PASSED"
        [[ "$json_mode" == "false" ]] && echo "NFTBan is sole firewall authority - enforce mode OK"
    else
        # V129 PR-C D8: structural validator did NOT pass. Strict-mode conflict
        # checks all passed, but we can NOT say PASSED because the caller will
        # return a nonzero rc reflecting the structural failure. Operator must
        # see a label that matches the exit code.
        [[ "$json_mode" == "false" ]] && echo "STRICT PREFLIGHT: NOT VERIFIED (see Validator Status above)"
        [[ "$json_mode" == "false" ]] && echo "Conflict checks passed, but the structural validator could not confirm ruleset truth."
    fi

    return $VALIDATE_OK
}

_check_policykit() {
    # Check policykit-1 on Debian/Ubuntu (MANDATORY)
    local json_mode="${1:-false}"

    # Detect distro
    local distro_id=""
    local distro_like=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release || true
        distro_id="${ID:-}"
        distro_like="${ID_LIKE:-}"
    fi

    # Only check on Debian/Ubuntu family
    local is_debian_ubuntu=false
    case "$distro_id" in
        debian|ubuntu) is_debian_ubuntu=true ;;
    esac
    [[ "$distro_like" == *debian* ]] && is_debian_ubuntu=true
    [[ "$distro_like" == *ubuntu* ]] && is_debian_ubuntu=true

    if [[ "$is_debian_ubuntu" == "false" ]]; then
        [[ "$json_mode" == "false" ]] && echo "[OK] policykit-1: Not required (non-Debian/Ubuntu)"
        return 0
    fi

    # Check polkit package (Debian 13+ renamed policykit-1 to polkitd)
    if command -v dpkg-query &>/dev/null; then
        if dpkg-query -W -f='${Status}\n' policykit-1 2>/dev/null | grep -q "install ok installed" || \
           dpkg-query -W -f='${Status}\n' polkitd 2>/dev/null | grep -q "install ok installed"; then
            [[ "$json_mode" == "false" ]] && echo "[OK] polkit: Installed"
            return 0
        else
            [[ "$json_mode" == "false" ]] && echo "[FAIL] polkit: MISSING (required on Debian/Ubuntu)"
            [[ "$json_mode" == "false" ]] && echo "       Fix: apt-get install -y polkitd  (or policykit-1 on older releases)"
            return 1
        fi
    else
        [[ "$json_mode" == "false" ]] && echo "[WARN] polkit: Cannot verify (dpkg-query missing)"
        return 1
    fi
}

_check_firewall_conflicts() {
    # Check for competing firewall authorities
    local json_mode="${1:-false}"

    # Load firewall conflicts library
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_firewall_conflicts.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_firewall_conflicts.sh" || return 1
    else
        [[ "$json_mode" == "false" ]] && echo "[WARN] Cannot load conflict detection library"
        return 0  # Don't fail if library missing
    fi

    # Run all conflict detection
    nftban_detect_all_conflicts
    local severity=$?

    # CRITICAL (3) = hard fail, WARNING (2) = fail in strict mode
    # v1.150 (16.2): the conflicts library now always declares CONFLICT_*
    # above its load-guard, but reference them with defaults here so a
    # missing/partly-loaded library can never abort under `set -u`.
    if [[ $severity -ge ${CONFLICT_WARNING:-2} ]]; then
        [[ "$json_mode" == "false" ]] && echo "[FAIL] Firewall authority conflict detected"
        for conflict in "${NFTBAN_FIREWALL_CONFLICTS[@]}"; do
            [[ "$json_mode" == "false" ]] && echo "       $conflict" || true
        done
        [[ "$json_mode" == "false" ]] && echo ""
        [[ "$json_mode" == "false" ]] && echo "       Remediation:"
        for fix in "${NFTBAN_FIREWALL_FIXES[@]}"; do
            [[ "$json_mode" == "false" ]] && echo "       $fix" || true
        done
        return 1
    elif [[ $severity -eq ${CONFLICT_INFO:-1} ]]; then
        [[ "$json_mode" == "false" ]] && echo "[OK] Firewall conflicts: Minor (non-blocking)"
        return 0
    else
        [[ "$json_mode" == "false" ]] && echo "[OK] Firewall conflicts: None detected"
        return 0
    fi
}

_check_nft_collisions() {
    # Check for non-NFTBan tables with active input hooks
    local json_mode="${1:-false}"

    # Get current ruleset
    local ruleset
    ruleset=$(nft -a list ruleset 2>/dev/null) || {
        [[ "$json_mode" == "false" ]] && echo "[WARN] Cannot read nftables ruleset"
        return 0
    }

    # Parse for non-nftban active input hooks
    # Active = has policy != accept OR has actual rules
    local collisions
    collisions=$(echo "$ruleset" | awk '
        BEGIN { family=""; table=""; chain=""; in_chain=0; has_hook=0; policy=""; rule_count=0; }
        /^table / { family=$2; table=$3; gsub(/{.*/, "", table); next }
        /^[[:space:]]*chain / {
            chain=$2; gsub(/{.*/, "", chain);
            in_chain=1; has_hook=0; policy=""; rule_count=0;
            next
        }
        in_chain && /hook[[:space:]]+input/ {
            has_hook=1
            if (match($0, /policy[[:space:]]+([a-zA-Z]+)/, m)) policy=m[1]
            next
        }
        in_chain && /^[[:space:]]+/ {
            line=$0
            if (index(line, "hook ") > 0) next
            if (index(line, "type ") > 0) next
            if (match(line, /^[[:space:]]*policy[[:space:]]/)) next
            if (match(line, /(saddr|daddr|sport|dport|tcp|udp|icmp|ct |counter|drop|reject|accept|log|meta|iif|oif)/)) {
                rule_count++
            }
            next
        }
        /^[[:space:]]*}[[:space:]]*$/ {
            if (in_chain && has_hook) {
                is_nftban = (table == "nftban") ? 1 : 0
                if (!is_nftban) {
                    is_active = 0
                    if (policy != "" && policy != "accept") is_active = 1
                    if (rule_count > 0) is_active = 1
                    if (is_active) {
                        printf "%s %s|%s|policy=%s|rules=%d\n", family, table, chain, policy, rule_count
                    }
                }
            }
            in_chain=0
            next
        }
    ')

    if [[ -n "$collisions" ]]; then
        [[ "$json_mode" == "false" ]] && echo "[FAIL] Non-NFTBan active input hooks detected:"
        echo "$collisions" | while IFS= read -r line; do
            [[ "$json_mode" == "false" ]] && echo "       $line" || true
        done
        [[ "$json_mode" == "false" ]] && echo ""
        [[ "$json_mode" == "false" ]] && echo "       Fix: nft flush ruleset && nftban firewall rebuild"
        return 1
    else
        [[ "$json_mode" == "false" ]] && echo "[OK] NFTables hooks: No conflicting input hooks"
        return 0
    fi
}

# =============================================================================
# SUBCOMMAND: CHECK
# =============================================================================

firewall_check() {
    # Check if IP or port is blocked/allowed
    # Args: <ip|port> [--json]

    local value=""
    local output_json=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                output_json=true
                shift
                ;;
            -h|--help)
                show_check_help
                return 0
                ;;
            -*)
                echo "ERROR: Unknown option: $1" >&2
                echo "Try 'nftban firewall check --help' for more information." >&2
                return 1
                ;;
            *)
                value="$1"
                shift
                ;;
        esac
    done

    # Validate value provided
    if [[ -z "$value" ]]; then
        echo "ERROR: No IP or port specified" >&2
        echo "Try 'nftban firewall check --help' for more information." >&2
        return 1
    fi

    # Load core validator
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_ip_and_stats.sh" ]]; then
        # shellcheck source=/dev/null
        # v1.82: relocated to nftban_ip_and_stats.sh (nftban_validator.sh deleted)
        source "${NFTBAN_LIB_DIR}/core/nftban_ip_and_stats.sh" || return 1
    else
        echo "ERROR: Cannot find nftban_ip_and_stats.sh" >&2
        return 1
    fi

    # Run check
    if [[ "$output_json" == "true" ]]; then
        check_ip_or_port "$value" "true"
    else
        check_ip_or_port "$value" "false"
    fi
}

# =============================================================================
# SUBCOMMAND: STATS
# =============================================================================

firewall_stats() {
    # Display firewall statistics
    # Args: [--json]

    local output_json=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                output_json=true
                shift
                ;;
            -h|--help)
                show_stats_help
                return 0
                ;;
            *)
                echo "ERROR: Unknown option: $1" >&2
                echo "Try 'nftban firewall stats --help' for more information." >&2
                return 1
                ;;
        esac
    done

    # Load core validator
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_ip_and_stats.sh" ]]; then
        # shellcheck source=/dev/null
        # v1.82: relocated to nftban_ip_and_stats.sh (nftban_validator.sh deleted)
        source "${NFTBAN_LIB_DIR}/core/nftban_ip_and_stats.sh" || return 1
    else
        echo "ERROR: Cannot find nftban_ip_and_stats.sh" >&2
        return 1
    fi

    # Get statistics
    if [[ "$output_json" == "true" ]]; then
        get_firewall_stats "true"
    else
        get_firewall_stats "false"
    fi
}

# =============================================================================
# SUBCOMMAND: RELOAD
# =============================================================================

firewall_reload() {
    # Reload nftables ruleset AND re-apply NFTBan rules
    # v1.23.0 FIX (P1-17): reload now re-applies NFTBan schema + syncs whitelist
    local quiet=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h|help)
                # v1.141 PR-A (BUG-B5): help-guard. Prior to v1.141, this parser
                # had only --quiet|-q and *) → ERROR; `nftban firewall reload --help`
                # returned rc=1 with "Unknown option". help is now inert (no nft,
                # systemctl, daemon IPC, or filesystem mutation).
                cat <<'FIREWALL_RELOAD_HELP'
nftban firewall reload — atomic rebuild of nftables ruleset

Usage:
    nftban firewall reload                Reload + re-apply NFTBan schema + whitelist sync
    nftban firewall reload --quiet        Reload silently (script-friendly; rc indicates result)
    nftban firewall reload --help         Show this help text

What it does:
  * Reloads /etc/nftables.conf via systemd or nft -f (per distro).
  * Re-applies the NFTBan schema (whitelist, blacklist, etc.) after the kernel
    ruleset is replaced.
  * Atomic: kernel never sees an empty/partial ruleset.

Exit codes:
    0    Reload committed
    1    Reload failed; previous ruleset retained (or other error)
    2    Conflict with another firewall manager (UFW, firewalld, etc.)

Privilege: root required (operations on /etc/nftables.conf + nft kernel writes).
FIREWALL_RELOAD_HELP
                return 0
                ;;
            --quiet|-q)
                quiet=true
                shift
                ;;
            *)
                echo "ERROR: Unknown option: $1" >&2
                return 1
                ;;
        esac
    done

    # Step 1: Reload system nftables config
    local nft_conf
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR}/lib/nftban_distro_config.sh" 2>/dev/null || true
    nft_conf=$(nftban_distro_get_path "nftables_conf" 2>/dev/null)
    [[ -z "$nft_conf" ]] && nft_conf="/etc/nftables.conf"

    if [[ ! -f "$nft_conf" ]]; then
        echo "ERROR: nftables config not found: $nft_conf" >&2
        echo "Check distro config in /etc/nftban/distros/" >&2
        return 1
    fi

    [[ "$quiet" == "false" ]] && echo "Reloading nftables configuration..."
    if ! nft -f "$nft_conf" 2>&1; then
        echo "ERROR: Failed to reload nftables" >&2
        return 1
    fi

    # Step 2: Re-apply NFTBan schema
    # v1.50.0: Render from template if available, otherwise use live config
    local nftban_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftables.conf"
    local _template="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/templates/nftables.conf.tpl"
    if [[ -f "$_template" ]]; then
        [[ "$quiet" == "false" ]] && echo "Re-applying NFTBan schema from template..."
        local _tmp_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/.nftables.conf.tmp"
        _firewall_substitute_placeholders "$_template" "$_tmp_conf"
        if nft -c -f "$_tmp_conf" 2>/dev/null; then
            mv "$_tmp_conf" "$nftban_conf"
            chmod 640 "$nftban_conf" 2>/dev/null || true
            chown root:nftban "$nftban_conf" 2>/dev/null || true
            if ! nft -f "$nftban_conf" 2>&1; then
                echo "Warning: Failed to re-apply NFTBan schema" >&2
                echo "Try: nftban firewall rebuild" >&2
            fi
        else
            echo "Warning: Template validation failed, loading live config" >&2
            rm -f "$_tmp_conf"
            if [[ -f "$nftban_conf" ]] && ! nft -f "$nftban_conf" 2>&1; then
                echo "Try: nftban firewall rebuild" >&2
            fi
        fi
    elif [[ -f "$nftban_conf" ]]; then
        [[ "$quiet" == "false" ]] && echo "Re-applying NFTBan schema..."
        if grep -qE '__SSH_PORT__|__CT_LIMIT_' "$nftban_conf" 2>/dev/null; then
            # Legacy: live config has placeholders, no template — render in place
            local _tmp_conf
            _tmp_conf=$(mktemp) || { echo "ERROR: mktemp failed" >&2; return 1; }
            _firewall_substitute_placeholders "$nftban_conf" "$_tmp_conf"
            if ! nft -f "$_tmp_conf" 2>&1; then
                echo "Warning: Failed to re-apply NFTBan schema" >&2
                echo "Try: nftban firewall rebuild" >&2
            fi
            rm -f "$_tmp_conf"
        else
            if ! nft -f "$nftban_conf" 2>&1; then
                echo "Warning: Failed to re-apply NFTBan schema" >&2
                echo "Try: nftban firewall rebuild" >&2
            fi
        fi
    fi

    # Step 3: Re-sync system whitelist (ensures admin IPs are protected)
    # v1.59.1 BUG-5: Removed --quick — firewall reload is interactive, not postinst.
    # --quick skipped public IP detection AND atomic reload → server IPs not in nft set → lockout risk.
    [[ "$quiet" == "false" ]] && echo "Syncing whitelist..."
    nftban whitelist sync 2>/dev/null || true

    # Step 3b (v1.149 BUG-2): the reload above flushed the whitelist/blacklist sets, and
    # `nftban whitelist sync` re-applies only auto-detected SYSTEM IPs — NOT the durable
    # whitelist.d entries (operator `--static` admin IPs) or manual blacklist entries.
    # Those would stay dropped until the next periodic sync — a transient lockout window
    # that breaks the WL-STATIC durability promise. Reconcile them from config now via
    # the daemon. Use the core binary directly with --quick (whitelist/blacklist only,
    # no feeds/geoban) — calling `nftban sync` here would recurse back into firewall_reload.
    # No-op if the daemon/core binary is unavailable. (This is NOT the v1.59.1 system-IP
    # --quick path; it is the daemon LoadWhitelists/LoadBlacklists reconcile from files.)
    local _core_reconcile="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/bin/nftban-core"
    if [[ -x "$_core_reconcile" ]]; then
        [[ "$quiet" == "false" ]] && echo "Reconciling durable whitelist.d/blacklist.d entries..."
        "$_core_reconcile" sync --quick >/dev/null 2>&1 || true
    fi

    # Step 4 (v1.34.0): Re-apply DDoS protection if it was enabled.
    # firewall reload destroys DDoS chains (synproxy, portscan, ddos_protection).
    # Without this step, reload leaves the server unprotected.
    local _ddos_enabled="false"
    local _ddos_local_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/ddos/main.conf.local"
    if [[ -f "$_ddos_local_conf" ]]; then
        _ddos_enabled=$(grep -oP '^DDOS_ENABLED="\K[^"]+' "$_ddos_local_conf" 2>/dev/null || echo "false")
    fi
    if [[ "$_ddos_enabled" == "true" ]]; then
        [[ "$quiet" == "false" ]] && echo "Re-applying DDoS protection rules..."
        nftban ddos reload 2>/dev/null || {
            [[ "$quiet" == "false" ]] && echo "Warning: Failed to re-apply DDoS rules. Run: nftban ddos reload" || true
        }
    fi

    # Step 4b (v1.50.1): Re-apply portscan if enabled — reload destroys jump rules
    local _portscan_enabled="false"
    local _portscan_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/portscan/main.conf.local"
    [[ -f "$_portscan_conf" ]] && _portscan_enabled=$(grep -oP '^PORTSCAN_ENABLED="\K[^"]+' "$_portscan_conf" 2>/dev/null || echo "false")
    [[ "$_portscan_enabled" != "true" ]] && _portscan_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/portscan/main.conf" && \
        [[ -f "$_portscan_conf" ]] && _portscan_enabled=$(grep -oP '^PORTSCAN_ENABLED="\K[^"]+' "$_portscan_conf" 2>/dev/null || echo "false")
    if [[ "$_portscan_enabled" == "true" ]]; then
        [[ "$quiet" == "false" ]] && echo "Re-applying portscan detection rules..."
        nftban portscan enable --quiet 2>/dev/null || {
            [[ "$quiet" == "false" ]] && echo "Warning: Failed to re-apply portscan rules. Run: nftban portscan enable" || true
        }
    fi

    # Step 4c (v1.50.1, v1.81.0 key fix): Re-apply botguard if enabled — reload
    # destroys nft rules. Reuses cmd_botguard's enable path which calls
    # nft_fragment_enable_module "botguard" (idempotent: recreates sets, chain,
    # jump rule) and restarts nftband.
    if _firewall_botguard_is_enabled; then
        [[ "$quiet" == "false" ]] && echo "Re-applying BotGuard rules..."
        nftban botguard enable --quiet 2>/dev/null || {
            [[ "$quiet" == "false" ]] && echo "Warning: Failed to re-apply BotGuard rules. Run: nftban botguard enable" || true
        }
    fi

    # Step 4d (v1.126): Re-apply trust providers if any enabled — reload destroys
    # whitelist_ipv4/6 elements added by `nftban trust enable <PROVIDER>`.
    # Without this step, any reload (incl. via V120 whitelist-session add/remove
    # which calls firewall_reload internally) erases trust ranges from the kernel
    # sets and they don't auto-re-apply — they stay gone until the operator
    # manually runs `nftban trust enable <PROVIDER>` or `nftban trust update --all`.
    # Closes D-FIREWALL-RELOAD-DOES-NOT-REMERGE-TRUST-PROVIDERS (fleet-wide latent;
    # surfaced by V125 srv3 validation 2026-05-22; scope at
    # AUDIT_190_LIFECYCLE/V126_TRUST_WHITELIST_RELOAD_MERGE_SCOPE.md).
    # Uses `nftban trust load` CLI subprocess (idempotent over enabled providers;
    # reads from on-disk /var/lib/nftban/trust/*.txt cache; no network re-fetch).
    local _any_trust_enabled="false"
    local _trust_packaged="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/trust.conf"
    local _trust_local="${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf.local"
    local _trust_file
    for _trust_file in "$_trust_packaged" "$_trust_local"; do
        if [[ -f "$_trust_file" ]] && \
           grep -qE '^TRUST_[A-Z]+_ENABLED="true"' "$_trust_file" 2>/dev/null; then
            _any_trust_enabled="true"
            break
        fi
    done
    if [[ "$_any_trust_enabled" == "true" ]]; then
        [[ "$quiet" == "false" ]] && echo "Re-applying trust provider rules..."
        # v1.126.1 (D-NFTBAN-TRUST-LOAD-SILENT-NOOP-WHEN-PROVIDER-ENABLED-VIA-LOCAL-OVERRIDE):
        # nftban trust load now returns rc=2 when a provider is enabled in config
        # but its generated whitelist file is missing (per V126_1_LANE_C_HOTFIX_SCOPE.md
        # §4.6.1). Surface trust load's stderr (instead of `2>&1` swallowing it) so
        # the operator sees the per-provider "Run: nftban trust enable X" lines
        # directly. The warning message below references the canonical repair
        # (`nftban trust enable <PROVIDER>`) instead of the v1.126.0 no-op advice
        # ("Run: nftban trust load") that would have just re-triggered the same
        # silent skip.
        nftban trust load >/dev/null || {
            [[ "$quiet" == "false" ]] && echo "Warning: trust providers enabled but not loadable. Run: nftban trust enable <PROVIDER> (see 'nftban trust load' output for which providers)" || true
        }
    fi

    # Step 5 (v1.50.1): Re-sync feeds — reload destroys sets (delete table + recreate)
    [[ "$quiet" == "false" ]] && echo "Re-syncing threat feeds..."
    if declare -f nftban_feeds_sync_to_nftables &>/dev/null; then
        nftban_feeds_sync_to_nftables 2>/dev/null || true
    elif [[ -x "${NFTBAN_CORE_BIN:-${NFTBAN_LIB_DIR}/bin/nftban-core}" ]]; then
        timeout 120s "${NFTBAN_CORE_BIN:-${NFTBAN_LIB_DIR}/bin/nftban-core}" feeds sync 2>/dev/null || true
    fi

    # Step 6 (v1.50.1): Re-sync geoban
    [[ "$quiet" == "false" ]] && echo "Re-syncing GeoBan..."
    timeout 120s nftban geoban sync 2>/dev/null || true

    if [[ "$quiet" == "false" ]]; then
        echo ""
        echo "═══════════════════════════════════════════════════════"
        echo "Firewall rules reloaded successfully"
    fi
}

# =============================================================================
# REBUILD TRANSACTION HELPERS (v1.78.0)
# =============================================================================
# Safe rebuild with PRE/POST validation and rollback capability.
# Exit codes: 0=PROTECTED, 1=DEGRADED, 2=FAILED (rolled back), 3=FATAL

# Validator binary path
_REBUILD_VALIDATOR_BIN="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/bin/nftban-validate"

# v1.81.0 BOTGUARD-REBUILD-UX fix:
# Returns 0 if BotGuard is enabled in config, 1 otherwise.
#
# This is a *gating* fix, not a sequencing fix. Step 10 of firewall_rebuild
# (Re-apply BotGuard) was already correctly placed before POST-rebuild
# validation. The bug was that all three module-restore sites
# (firewall_reload, firewall_rebuild Step 10, firewall_reset Step 8) read the
# wrong config key `BOTGUARD_ENABLED` instead of the canonical
# `HTTP_BOTGUARD_ENABLED` used everywhere else in the codebase
# (cmd_botguard.sh, cmd_status.sh, health checks, exporter, doctor,
# config-schema). The grep returned empty, the local var fell through to
# "false", the re-init silently no-op'd, BotGuard chains stayed missing,
# and the existing PROTECTED→degraded rollback fired unnecessarily on srv1.
#
# This helper centralises the read of the canonical key so the wrong-key bug
# cannot recur in any of the three call sites.
_firewall_botguard_is_enabled() {
    local conf_dir="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/botguard"
    local val=""
    if [[ -f "$conf_dir/main.conf.local" ]]; then
        val=$(grep -oP '^HTTP_BOTGUARD_ENABLED="\K[^"]+' "$conf_dir/main.conf.local" 2>/dev/null || true)
    fi
    if [[ "$val" != "true" && -f "$conf_dir/main.conf" ]]; then
        val=$(grep -oP '^HTTP_BOTGUARD_ENABLED="\K[^"]+' "$conf_dir/main.conf" 2>/dev/null || true)
    fi
    [[ "$val" == "true" ]]
}

_rebuild_get_validator_state() {
    # Call Go validator and return status (protected/degraded/down)
    # Also outputs chain count for relative comparison
    # Returns: "status:chain_count" e.g. "protected:16"
    local json_output

    if [[ ! -x "$_REBUILD_VALIDATOR_BIN" ]]; then
        echo "down:0"
        return
    fi

    json_output=$("$_REBUILD_VALIDATOR_BIN" --json 2>/dev/null) || true

    if [[ -z "$json_output" ]]; then
        echo "down:0"
        return
    fi

    local status chain_count
    if command -v jq >/dev/null 2>&1; then
        status=$(echo "$json_output" | jq -r '.status' 2>/dev/null || echo "down")
        chain_count=$(echo "$json_output" | jq -r '.chain_counts.total_chains' 2>/dev/null || echo "0")
    else
        status=$(echo "$json_output" | grep -oP '"status"\s*:\s*"\K[^"]+' || echo "down")
        chain_count=$(echo "$json_output" | grep -oP '"total_chains"\s*:\s*\K[0-9]+' || echo "0")
    fi

    echo "${status}:${chain_count}"
}

_rebuild_snapshot_full() {
    # Create full ruleset snapshot for rollback
    # Args: $1 = snapshot directory
    local snapshot_dir="$1"
    mkdir -p "$snapshot_dir" || return 1

    # Snapshot 1: Full nft ruleset (nft format for easy reload)
    nft list ruleset > "$snapshot_dir/ruleset.nft" 2>/dev/null || true

    # Snapshot 2: JSON format for inspection
    nft -j list ruleset > "$snapshot_dir/ruleset.json" 2>/dev/null || true

    # Snapshot 3: Validator state
    if [[ -x "$_REBUILD_VALIDATOR_BIN" ]]; then
        "$_REBUILD_VALIDATOR_BIN" --json > "$snapshot_dir/validator_state.json" 2>/dev/null || true
    fi

    # Snapshot 4: Individual sets (for granular restore)
    mkdir -p "$snapshot_dir/sets"
    for family in ip ip6; do
        for set in whitelist blacklist blacklist_manual; do
            local set_name="${set}_ipv${family#ip}"
            [[ "$family" == "ip" ]] && set_name="${set}_ipv4"
            [[ "$family" == "ip6" ]] && set_name="${set}_ipv6"
            nft list set $family nftban "$set_name" > "$snapshot_dir/sets/${set_name}.nft" 2>/dev/null || true
        done
    done

    echo "$snapshot_dir"
}

_rebuild_rollback() {
    # Restore from snapshot
    # Args: $1 = snapshot directory
    local snapshot_dir="$1"
    local ruleset_file="$snapshot_dir/ruleset.nft"

    if [[ ! -f "$ruleset_file" ]]; then
        echo "ERROR: Snapshot not found: $ruleset_file" >&2
        return 1
    fi

    # v1.78.0: Skip pre-validation — snapshot came from working state.
    # Syntax check (nft -c) fails when objects already exist in kernel.
    # Instead, we flush then load, which is always valid for a captured ruleset.

    echo "Flushing current ruleset..." >&2

    # Flush all tables to ensure clean state
    nft flush ruleset 2>/dev/null || true

    echo "Loading snapshot..." >&2

    if nft -f "$ruleset_file" 2>&1; then
        echo "Rollback successful from: $snapshot_dir"
        return 0
    else
        echo "ERROR: Rollback FAILED — firewall may be in inconsistent state!" >&2
        echo "  Try manually: nft flush ruleset && nft -f $ruleset_file" >&2
        return 1
    fi
}

# =============================================================================
# SUBCOMMAND: REBUILD
# =============================================================================

firewall_rebuild() {
    # v1.96: Retry wrapper around core rebuild.
    # Calls _firewall_rebuild_core(), then checks if result is retryable.
    # At most 1 immediate retry for transient failures (INV-RR-006).
    # No retry for PREVALIDATION_FAILED or structural failures (INV-RR-005).
    local _rebuild_exit=0

    _firewall_rebuild_core "$@"
    _rebuild_exit=$?

    # Exit 0 = success, no retry needed
    if [[ $_rebuild_exit -eq 0 ]]; then
        # SEC-RULEFP (v1.138): capture the ruleset fingerprint baseline ONLY after a
        # successful rebuild (we are inside the exit-0 branch — never on failure).
        # Best-effort: a capture failure must not fail the rebuild. Same rulefp
        # baseline format as the daemon apply hook (nftban-core owns the write).
        local _rulefp_core="${NFTBAN_CORE_BIN:-${NFTBAN_LIB_DIR:-/usr/lib/nftban}/bin/nftban-core}"
        if [[ -x "$_rulefp_core" ]]; then
            "$_rulefp_core" verify-rules --capture >/dev/null 2>&1 || \
                echo "  ⚠️  ruleset fingerprint baseline capture failed (non-fatal)" >&2
        fi
        return 0
    fi

    # Exit 1 with no marker = PREVALIDATION_FAILED or pre-existing DEGRADED → no retry
    # Exit 3 = FATAL → never retry
    if [[ $_rebuild_exit -eq 3 ]]; then
        return 3
    fi

    # Check if classification library is available and marker was written
    if ! declare -f _rebuild_marker_exists &>/dev/null; then
        return $_rebuild_exit  # no classification available, pass through
    fi

    if ! _rebuild_marker_exists; then
        return $_rebuild_exit  # no marker = prevalidation or non-retryable, pass through
    fi

    # Read failure class from marker
    local _fail_class
    _fail_class=$(_rebuild_marker_get_class)

    # Check retry eligibility — never-retry classes pass through immediately
    case "$_fail_class" in
        PREVALIDATION_FAILED|SNAPSHOT_FAILED|POSTVALIDATION_HARD_FAIL|ROLLBACK_FAILED|AUTHORITY_CONFLICT|BACKUP_MISSING|RETRY_EXHAUSTED)
            return $_rebuild_exit
            ;;
        POSTVALIDATION_REGRESSION)
            # Retry only if daemon-related (INV-RR-005 tightening)
            if [[ "$_REBUILD_DAEMON_WAS_DOWN" != "true" ]]; then
                return $_rebuild_exit
            fi
            ;;
    esac

    # Eligible for immediate retry — attempt once
    echo "" >&2
    echo "  [RETRY] Transient failure detected ($_fail_class) — retrying rebuild (attempt 2/2)..." >&2
    echo "" >&2

    _firewall_rebuild_core "$@"
    _rebuild_exit=$?

    if [[ $_rebuild_exit -eq 0 ]]; then
        echo "  [RETRY] Rebuild succeeded on retry" >&2
        # Marker already cleared by success path in _firewall_rebuild_core
    else
        echo "  [RETRY] Rebuild still failed after retry (exit $_rebuild_exit)" >&2
        # Update marker: increment retry count, mark deferred if eligible
        if _rebuild_marker_exists; then
            local _marker_file="$REBUILD_RECOVERY_MARKER"
            local _current_count
            _current_count=$(jq -r '.retry_count // 0' "$_marker_file" 2>/dev/null || echo "0")
            local _new_count=$((_current_count + 1))
            local _max=3
            local _exhausted_val="false"
            [[ $_new_count -ge $_max ]] && _exhausted_val="true"
            # Update in-place via jq
            local _tmp="${_marker_file}.tmp"
            jq --argjson count "$_new_count" --argjson exhausted "$_exhausted_val" \
                '.retry_count = $count | .exhausted = $exhausted | .deferred_retry_pending = (if $exhausted then false else .deferred_retry_pending end)' \
                "$_marker_file" > "$_tmp" 2>/dev/null && mv -f "$_tmp" "$_marker_file" || rm -f "$_tmp"
        fi
    fi

    return $_rebuild_exit
}

_firewall_rebuild_core() {
    # Rebuild nftables schema from scratch (keeps existing IPs in sets)
    # This is the correct way to fix corrupted schema
    #
    # v1.78.0: Safe transaction with PRE/POST validation and rollback
    # v1.47.0 DEPLOY-001: Atomic rebuild — validate BEFORE flushing
    # v1.47.0 DEPLOY-002: Detect .rpmnew files from RPM upgrades
    # v1.50.0: Template-based rebuild — render from .tpl, validate, atomic-write
    local force=false
    local quiet=false
    local use_new=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|-f)
                force=true
                shift
                ;;
            --quiet|-q)
                quiet=true
                shift
                ;;
            --use-new)
                # v1.47.0 DEPLOY-002: Prefer .rpmnew config over existing
                use_new=true
                shift
                ;;
            --help|-h)
                show_rebuild_help
                return 0
                ;;
            *)
                echo "ERROR: Unknown option: $1" >&2
                return 1
                ;;
        esac
    done

    [[ "$quiet" == "false" ]] && echo "Rebuilding NFTBan firewall schema..."

    # v1.96: Load rebuild failure classification library
    local _classify_lib="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_rebuild_classify.sh"
    if [[ -f "$_classify_lib" ]]; then
        # shellcheck source=/dev/null
        source "$_classify_lib" 2>/dev/null || true
    fi
    # Reset classification state for this rebuild
    if declare -f _rebuild_classify_reset &>/dev/null; then
        _rebuild_classify_reset
    fi

    # v1.78.0: PRE-REBUILD VALIDATION — Capture state before changes
    local pre_state pre_status pre_chains
    [[ "$quiet" == "false" ]] && echo "  [PRE] Capturing pre-rebuild state..."
    pre_state=$(_rebuild_get_validator_state)
    pre_status="${pre_state%%:*}"
    pre_chains="${pre_state##*:}"
    [[ "$quiet" == "false" ]] && echo "    PRE state: $pre_status (chains: $pre_chains)"

    # Step 0: Create full snapshot for rollback (v1.78.0)
    local backup_dir="/var/lib/nftban/backup"
    mkdir -p "$backup_dir" || return 1
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local snapshot_dir="$backup_dir/rebuild_$timestamp"

    [[ "$quiet" == "false" ]] && echo "  [0/12] Creating full ruleset snapshot..."
    _rebuild_snapshot_full "$snapshot_dir" >/dev/null 2>&1 || true
    [[ "$quiet" == "false" ]] && echo "    Snapshot: $snapshot_dir"

    # Step 1: Backup current IPs from sets (preserve bans/whitelist)
    [[ "$quiet" == "false" ]] && echo "  [1/12] Backing up current sets..."
    timeout 10s nft list set ip nftban whitelist_ipv4 2>/dev/null > "$backup_dir/whitelist_ipv4_$timestamp.txt" || true
    timeout 10s nft list set ip nftban blacklist_ipv4 2>/dev/null > "$backup_dir/blacklist_ipv4_$timestamp.txt" || true
    timeout 10s nft list set ip6 nftban whitelist_ipv6 2>/dev/null > "$backup_dir/whitelist_ipv6_$timestamp.txt" || true
    timeout 10s nft list set ip6 nftban blacklist_ipv6 2>/dev/null > "$backup_dir/blacklist_ipv6_$timestamp.txt" || true

    # v1.50.0: Template-based rebuild architecture
    # Source: /usr/lib/nftban/templates/nftables.conf.tpl (package-owned template)
    # Target: /etc/nftban/nftables.conf (rendered, boot-safe live config)
    local nftban_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftables.conf"
    local template_file="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/templates/nftables.conf.tpl"
    local rpmnew_conf="${nftban_conf}.rpmnew"
    local tmp_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/.nftables.conf.tmp"
    local source_file=""

    # Determine source: --use-new → .rpmnew, else template, else legacy fallback
    if [[ "$use_new" == "true" && -f "$rpmnew_conf" ]]; then
        [[ "$quiet" == "false" ]] && echo "  [INFO] Using new config from $rpmnew_conf (--use-new)"
        source_file="$rpmnew_conf"
    elif [[ -f "$template_file" ]]; then
        source_file="$template_file"
    else
        # Legacy migration: template not installed yet (pre-v1.50.0 package)
        if [[ -f "$nftban_conf" ]]; then
            if grep -qE '__SSH_PORT__|__CT_LIMIT_' "$nftban_conf" 2>/dev/null; then
                echo "WARNING: [COMPAT] Using live config as template source — run 'dnf reinstall nftban' to install template" >&2
                source_file="$nftban_conf"
            else
                # Pre-v1.49.0 hardcoded config, no placeholders → load directly
                [[ "$quiet" == "false" ]] && echo "  [INFO] Pre-template config detected, loading directly"
                source_file=""
            fi
        else
            echo "ERROR: Template not found: $template_file — reinstall nftban package" >&2
            return 1
        fi
    fi

    # .rpmnew advisory warning (when not using --use-new)
    if [[ "$use_new" != "true" && -f "$rpmnew_conf" ]]; then
        echo "" >&2
        echo "WARNING: New config available at $rpmnew_conf" >&2
        echo "  RPM upgrade created a new config but your existing one was modified." >&2
        echo "  Options:" >&2
        echo "    1. Review and merge: diff $nftban_conf $rpmnew_conf" >&2
        echo "    2. Use new config:   nftban firewall rebuild --use-new" >&2
        echo "" >&2
    fi

    # Render: substitute placeholders → temp file → validate → atomic write
    [[ "$quiet" == "false" ]] && echo "  [2/12] Rendering schema from template..."
    local load_conf="$nftban_conf"

    if [[ -n "$source_file" ]]; then
        if grep -qE '__SSH_PORT__|__CT_LIMIT_' "$source_file" 2>/dev/null; then
            _firewall_substitute_placeholders "$source_file" "$tmp_conf"
            [[ "$quiet" == "false" ]] && echo "    Substituted placeholders (SSH port + CT limits)"
        else
            cp "$source_file" "$tmp_conf"
        fi

        # Validate rendered config BEFORE writing to live config
        [[ "$quiet" == "false" ]] && echo "  [3/12] Validating new schema (dry-run)..."
        local validate_output
        if ! validate_output=$(nft -c -f "$tmp_conf" 2>&1); then
            echo "ERROR: Schema validation FAILED — existing firewall preserved!" >&2
            echo "  Source: $source_file" >&2
            echo "  Error:  $validate_output" >&2
            echo "" >&2
            echo "  Fix the config file and retry: nftban firewall rebuild" >&2
            # v1.96: PREVALIDATION_FAILED — no kernel mutation, no recovery marker (INV-RR-005)
            rm -f "$tmp_conf"
            return 1
        fi
        [[ "$quiet" == "false" ]] && echo "    Schema validation: PASSED"

        # Atomic write: mv on same filesystem = atomic
        mv "$tmp_conf" "$nftban_conf"
        chmod 640 "$nftban_conf" 2>/dev/null || true
        chown root:nftban "$nftban_conf" 2>/dev/null || true
        load_conf="$nftban_conf"
    else
        # No template, no placeholders — validate live config directly
        [[ "$quiet" == "false" ]] && echo "  [3/12] Validating schema (dry-run)..."
        local validate_output
        if ! validate_output=$(nft -c -f "$load_conf" 2>&1); then
            echo "ERROR: Schema validation FAILED — existing firewall preserved!" >&2
            echo "  Config: $load_conf" >&2
            echo "  Error:  $validate_output" >&2
            echo "" >&2
            echo "  Fix the config file and retry: nftban firewall rebuild" >&2
            # v1.96: PREVALIDATION_FAILED — no kernel mutation, no recovery marker (INV-RR-005)
            return 1
        fi
        [[ "$quiet" == "false" ]] && echo "    Schema validation: PASSED" || true
    fi

    # Step 4: Classify and clean ghost tables (PR26.6 / 6A).
    # TAKEOVER-PRESERVES-NON-NFTBAN-AUTHORITY-001 — replaces prior
    # allowlist-sweep that silently deleted operator-retained tables
    # such as `inet ssh_safety`. Default policy is WARN-and-preserve
    # for OPERATOR_SAFETY; only EXTERNAL_AUTHORITY_GHOST is deleted.
    [[ "$quiet" == "false" ]] && echo "  [4/12] Classifying nft tables (preserve operator safety)..."
    local _classify_lib="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_table_classify.sh"
    if [[ -f "$_classify_lib" ]]; then
        # shellcheck source=/dev/null
        source "$_classify_lib" 2>/dev/null || true
    fi

    local ALL_TABLES
    ALL_TABLES=$(nft list tables 2>/dev/null || true)

    while IFS= read -r table_line; do
        [[ -z "$table_line" ]] && continue
        local TABLE_SPEC="${table_line#table }"
        local _class=""
        if declare -f nftban_classify_table_line &>/dev/null; then
            _class="$(nftban_classify_table_line "$table_line")"
        fi
        case "$_class" in
            "$TC_EXTERNAL_AUTHORITY_GHOST")
                if nft delete table "$TABLE_SPEC" 2>/dev/null; then
                    [[ "$quiet" == "false" ]] && echo "    Deleted external-authority ghost table: $TABLE_SPEC" || true
                fi
                ;;
            "$TC_OPERATOR_SAFETY")
                # PR26.6 invariant — preserve operator-retained tables.
                # Emit warning to stderr so it lands in install logs.
                echo "WARNING: preserving non-nftban operator table: $TABLE_SPEC (TAKEOVER-PRESERVES-NON-NFTBAN-AUTHORITY-001)" >&2
                ;;
            "$TC_NFTBAN_OWNED"|"$TC_KERNEL_DEFAULT")
                # nftban-owned: flushed in step 5 below.
                # kernel default (ip raw / ip6 raw): preserve silently.
                : ;;
            *)
                # Classifier unavailable (lib missing) — preserve, do
                # not silently delete. Better to leave a foreign table
                # than to wipe operator state.
                echo "WARNING: table classifier unavailable; preserving: $TABLE_SPEC" >&2
                ;;
        esac
    done <<< "$ALL_TABLES"

    # Step 5: Flush + load (safe — we validated above)
    [[ "$quiet" == "false" ]] && echo "  [5/12] Flushing and loading new schema..."
    nft flush table ip nftban 2>/dev/null || true
    nft flush table ip6 nftban 2>/dev/null || true

    if ! nft -f "$load_conf" 2>&1; then
        echo "ERROR: Failed to load NFTBan schema from $load_conf" >&2
        echo "Try: nftban firewall reset --force" >&2
        # v1.96: APPLY_FAILED — validated config failed to load (may be transient)
        if declare -f _rebuild_marker_write &>/dev/null; then
            _rebuild_marker_write "$FC_APPLY_FAILED" "$OR_FAILED_DEGRADED" "$snapshot_dir" "degraded"
        fi
        return 1
    fi

    # Step 6: Re-sync system whitelist
    [[ "$quiet" == "false" ]] && echo "  [6/12] Re-syncing system whitelist..."
    nftban whitelist sync >/dev/null 2>&1 || true

    # Step 7: Restore blacklist from backup (BUG FIX: R74 - blacklist was never restored)
    [[ "$quiet" == "false" ]] && echo "  [7/12] Restoring blacklist from backup..."
    local restored_count=0
    for backup_file in "$backup_dir/blacklist_ipv4_$timestamp.txt" "$backup_dir/blacklist_ipv6_$timestamp.txt"; do
        [[ -f "$backup_file" ]] || continue
        # Extract elements from backup (format: elements = { ip1, ip2, ... })
        local elements
        # v1.19.20 FIX: Prevent pipefail exit 1 when grep finds no match
        elements=$(grep -oP 'elements = \{ \K[^}]+' "$backup_file" 2>/dev/null | tr -d '\n\t' | sed 's/  */ /g' || true)
        [[ -z "$elements" ]] && continue

        # v1.19.27 SECURITY: Validate elements contain only safe characters (defense-in-depth)
        # Allow: digits, dots, colons (IPv6), slashes (CIDR), commas, spaces, 'timeout', 's/m/h/d'
        if [[ ! "$elements" =~ ^[0-9a-fA-F.:,/[:space:]timeouts]+$ ]]; then
            [[ "$quiet" == "false" ]] && echo "    WARNING: Skipping backup with invalid characters: $backup_file"
            continue
        fi

        # Determine table and set from filename
        local table_family set_name
        if [[ "$backup_file" == *ipv4* ]]; then
            table_family="ip nftban"
            set_name="blacklist_ipv4"
        else
            table_family="ip6 nftban"
            set_name="blacklist_ipv6"
        fi
        # Add elements back to set
        if nft add element $table_family $set_name "{ $elements }" 2>/dev/null; then
            # v1.19.20 FIX
            ((restored_count++)) || true
            [[ "$quiet" == "false" ]] && echo "    Restored: $set_name" || true
        fi
    done
    [[ "$quiet" == "false" && "$restored_count" -eq 0 ]] && echo "    No blacklist entries to restore"

    # Step 8 (v1.50.1): Re-apply DDoS protection if enabled
    # Preflight: module re-enable requires daemon IPC. If daemon is down
    # (e.g. start-limit-hit from update cycles), attempt recovery first.
    # Without this, module commands fail silently and POST validation sees
    # missing chains → DEGRADED → installer treats as FAILED.
    [[ "$quiet" == "false" ]] && echo "  [8/12] Re-applying protection modules..."
    if ! systemctl is-active --quiet nftband.service 2>/dev/null; then
        [[ "$quiet" == "false" ]] && echo "    Daemon not running — attempting recovery..."
        # Clear start-limit-hit then try to start
        if command -v nftban_service_clear_failed &>/dev/null; then
            nftban_service_clear_failed "nftband.service" 2>/dev/null || true
            nftban_service_clear_failed "nftband.socket" 2>/dev/null || true
        else
            systemctl reset-failed nftband.service 2>/dev/null || true
            systemctl reset-failed nftband.socket 2>/dev/null || true
        fi
        systemctl start nftband.service 2>/dev/null || true
        sleep 2
        if systemctl is-active --quiet nftband.service 2>/dev/null; then
            [[ "$quiet" == "false" ]] && echo "    Daemon recovered — proceeding with module re-enable"
        else
            echo "    WARNING: Daemon still down — module re-enable will fail." >&2
            echo "    Module chains will be absent. POST validation may report DEGRADED." >&2
            echo "    After install: systemctl reset-failed nftband && systemctl start nftband" >&2
            # v1.96: Track daemon-down for failure classification
            declare -f _rebuild_classify_daemon_down &>/dev/null && _rebuild_classify_daemon_down
        fi
    fi
    local _ddos_enabled="false"
    local _ddos_local_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/ddos/main.conf.local"
    if [[ -f "$_ddos_local_conf" ]]; then
        _ddos_enabled=$(grep -oP '^DDOS_ENABLED="\K[^"]+' "$_ddos_local_conf" 2>/dev/null || echo "false")
    fi
    if [[ "$_ddos_enabled" == "true" ]]; then
        [[ "$quiet" == "false" ]] && echo "    DDoS protection: re-applying..."
        if nftban ddos reload 2>/dev/null; then
            declare -f _rebuild_classify_module_result &>/dev/null && _rebuild_classify_module_result "ddos" "$MR_OK"
        else
            [[ "$quiet" == "false" ]] && echo "    Warning: DDoS reload failed. Run: nftban ddos reload" || true
            declare -f _rebuild_classify_module_result &>/dev/null && _rebuild_classify_module_result "ddos" "$MR_FAILED"
        fi
    fi

    # Step 9 (v1.50.1): Re-apply portscan if enabled
    [[ "$quiet" == "false" ]] && echo "  [9/12] Re-applying portscan detection..."
    local _portscan_enabled="false"
    local _portscan_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/portscan/main.conf.local"
    [[ -f "$_portscan_conf" ]] && _portscan_enabled=$(grep -oP '^PORTSCAN_ENABLED="\K[^"]+' "$_portscan_conf" 2>/dev/null || echo "false")
    [[ "$_portscan_enabled" != "true" ]] && _portscan_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/portscan/main.conf" && \
        [[ -f "$_portscan_conf" ]] && _portscan_enabled=$(grep -oP '^PORTSCAN_ENABLED="\K[^"]+' "$_portscan_conf" 2>/dev/null || echo "false")
    if [[ "$_portscan_enabled" == "true" ]]; then
        if nftban portscan enable --quiet 2>/dev/null; then
            declare -f _rebuild_classify_module_result &>/dev/null && _rebuild_classify_module_result "portscan" "$MR_OK"
        else
            [[ "$quiet" == "false" ]] && echo "    Warning: Portscan enable failed. Run: nftban portscan enable" || true
            declare -f _rebuild_classify_module_result &>/dev/null && _rebuild_classify_module_result "portscan" "$MR_FAILED"
        fi
    else
        [[ "$quiet" == "false" ]] && echo "    Portscan: not enabled, skipped" || true
    fi

    # Step 10 (v1.50.1, v1.81.0 key fix): Re-apply botguard if enabled.
    # Sequencing was already correct (this step runs before [POST] validation
    # so the validator does not see a transient missing-helper-chain state).
    # The v1.81.0 fix is to the *gating*: Step 10 was previously checked
    # against the wrong config key and silently skipped on BotGuard hosts.
    [[ "$quiet" == "false" ]] && echo "  [10/12] Re-applying BotGuard..."
    if _firewall_botguard_is_enabled; then
        if nftban botguard enable --quiet 2>/dev/null; then
            declare -f _rebuild_classify_module_result &>/dev/null && _rebuild_classify_module_result "botguard" "$MR_OK"
        else
            [[ "$quiet" == "false" ]] && echo "    Warning: BotGuard enable failed. Run: nftban botguard enable" || true
            declare -f _rebuild_classify_module_result &>/dev/null && _rebuild_classify_module_result "botguard" "$MR_FAILED"
        fi
    else
        [[ "$quiet" == "false" ]] && echo "    BotGuard: not enabled, skipped" || true
    fi

    # Step 11: Re-sync feeds (v1.50.1: auto-restore, was manual-only)
    [[ "$quiet" == "false" ]] && echo "  [11/12] Re-syncing threat feeds..."
    if declare -f nftban_feeds_sync_to_nftables &>/dev/null; then
        nftban_feeds_sync_to_nftables 2>/dev/null && \
            { [[ "$quiet" == "false" ]] && echo "    Feeds synced to nftables"; } || \
            { [[ "$quiet" == "false" ]] && echo "    No feeds to sync (disabled or empty)"; }
    elif [[ -x "${NFTBAN_CORE_BIN:-${NFTBAN_LIB_DIR}/bin/nftban-core}" ]]; then
        timeout 120s "${NFTBAN_CORE_BIN:-${NFTBAN_LIB_DIR}/bin/nftban-core}" feeds sync 2>/dev/null && \
            { [[ "$quiet" == "false" ]] && echo "    Feeds synced to nftables"; } || \
            { [[ "$quiet" == "false" ]] && echo "    Feeds sync skipped (not configured or failed)"; }
    else
        [[ "$quiet" == "false" ]] && echo "    Feeds sync skipped (no sync function available)" || true
    fi

    # Step 12: Re-sync geoban (v1.50.1: auto-restore, was manual-only)
    [[ "$quiet" == "false" ]] && echo "  [12/12] Re-syncing GeoBan..."
    if command -v nftban &>/dev/null; then
        timeout 120s nftban geoban sync 2>/dev/null && \
            { [[ "$quiet" == "false" ]] && echo "    GeoBan synced to nftables"; } || \
            { [[ "$quiet" == "false" ]] && echo "    GeoBan sync skipped (not configured or failed)"; }
    else
        [[ "$quiet" == "false" ]] && echo "    GeoBan sync skipped (nftban not available)" || true
    fi

    # Handle .rpmnew: if --use-new consumed it, delete the .rpmnew (already rendered into live config)
    if [[ "$use_new" == "true" && -f "$rpmnew_conf" ]]; then
        rm -f "$rpmnew_conf" 2>/dev/null || true
        [[ "$quiet" == "false" ]] && echo "  Consumed .rpmnew and rendered into live config" || true
    fi

    # ─────────────────────────────────────────────────────────────────────────
    # v1.96: Post-module-restore verification (INV-RR-007)
    # Level 1: Structure presence (chains + sets exist in kernel)
    # Level 2: Wiring correctness (jumps in correct anchor positions)
    # Level 3 deferred — requires traffic (WARNING only if missing)
    # ─────────────────────────────────────────────────────────────────────────
    if declare -f _rebuild_classify_module_result &>/dev/null; then
        [[ "$quiet" == "false" ]] && echo ""
        [[ "$quiet" == "false" ]] && echo "  [VERIFY] Module restore verification..."

        # DDoS: check for ddos helper chains in ip nftban
        # Actual chain names: ddos_protection, ddos_sanity, ddos_prefix, ddos_penalty
        if [[ "$_ddos_enabled" == "true" && "$_REBUILD_MODULE_DDOS" == "$MR_OK" ]]; then
            if nft list chain ip nftban ddos_protection &>/dev/null; then
                # Level 1+2: chain exists and is reachable (nft validates jump targets)
                [[ "$quiet" == "false" ]] && echo "    DDoS: chain verified (Level 1+2)"
            else
                _rebuild_classify_module_result "ddos" "$MR_INCOMPLETE"
                [[ "$quiet" == "false" ]] && echo "    DDoS: chain MISSING after enable (downgraded to INCOMPLETE)"
            fi
        fi

        # Portscan: check for portscan helper chain
        # Actual chain name: portscan_detection
        if [[ "$_portscan_enabled" == "true" && "$_REBUILD_MODULE_PORTSCAN" == "$MR_OK" ]]; then
            if nft list chain ip nftban portscan_detection &>/dev/null; then
                [[ "$quiet" == "false" ]] && echo "    Portscan: chain verified (Level 1+2)"
            else
                _rebuild_classify_module_result "portscan" "$MR_INCOMPLETE"
                [[ "$quiet" == "false" ]] && echo "    Portscan: chain MISSING after enable (downgraded to INCOMPLETE)"
            fi
        fi

        # BotGuard: check for botguard helper chain
        # Actual chain name: botguard_filter
        if _firewall_botguard_is_enabled 2>/dev/null && [[ "$_REBUILD_MODULE_BOTGUARD" == "$MR_OK" ]]; then
            if nft list chain ip nftban botguard_filter &>/dev/null; then
                [[ "$quiet" == "false" ]] && echo "    BotGuard: chain verified (Level 1+2)"
            else
                _rebuild_classify_module_result "botguard" "$MR_INCOMPLETE"
                [[ "$quiet" == "false" ]] && echo "    BotGuard: chain MISSING after enable (downgraded to INCOMPLETE)"
            fi
        fi
    fi

    # v1.78.0: POST-REBUILD VALIDATION — Compare with PRE state
    [[ "$quiet" == "false" ]] && echo ""
    [[ "$quiet" == "false" ]] && echo "  [POST] Validating post-rebuild state..."
    local post_state post_status post_chains
    post_state=$(_rebuild_get_validator_state)
    post_status="${post_state%%:*}"
    post_chains="${post_state##*:}"
    [[ "$quiet" == "false" ]] && echo "    POST state: $post_status (chains: $post_chains)"

    # v1.78.0: CRITICAL SAFETY CHECK — Rollback if degraded from PROTECTED
    # v1.96: 'idle' is structurally equivalent to 'protected' (all checks pass,
    # just no traffic observed yet after rebuild). Do not treat idle as regression.
    if [[ "$pre_status" == "protected" && "$post_status" != "protected" && "$post_status" != "idle" ]]; then
        echo "" >&2
        echo "═══════════════════════════════════════════════════════════════════" >&2
        echo "REBUILD FAILED: Post-rebuild validation returned $post_status" >&2
        echo "  PRE state:  $pre_status (chains: $pre_chains)" >&2
        echo "  POST state: $post_status (chains: $post_chains)" >&2
        echo "" >&2
        echo "Attempting rollback from snapshot..." >&2
        echo "═══════════════════════════════════════════════════════════════════" >&2

        if _rebuild_rollback "$snapshot_dir"; then
            echo "Rollback successful — firewall restored to pre-rebuild state" >&2
            # v1.96: Classify regression. Determine restored health for marker.
            local _restored_state _restored_status
            if declare -f _rebuild_get_validator_state &>/dev/null; then
                _restored_state=$(_rebuild_get_validator_state)
                _restored_status="${_restored_state%%:*}"
            else
                _restored_status="unknown"
            fi
            if declare -f _rebuild_marker_write &>/dev/null; then
                if [[ "$_restored_status" == "protected" ]]; then
                    _rebuild_marker_write "$FC_POSTVALIDATION_REGRESSION" "$OR_FAILED_RECOVERED" "$snapshot_dir" "$_restored_status"
                else
                    _rebuild_marker_write "$FC_POSTVALIDATION_REGRESSION" "$OR_FAILED_DEGRADED" "$snapshot_dir" "$_restored_status"
                fi
            fi
            return 2  # FAILED (rolled back)
        else
            echo "FATAL: Rollback FAILED — manual intervention required!" >&2
            echo "  Snapshot location: $snapshot_dir" >&2
            echo "  Try: nft -f $snapshot_dir/ruleset.nft" >&2
            echo "" >&2
            # v1.96: Enhanced exit 3 recovery instructions (INV-RR-010)
            echo "  Recovery procedure:" >&2
            echo "    1. nft -f $snapshot_dir/ruleset.nft" >&2
            echo "    2. nftban-validate status" >&2
            echo "    3. nftban status" >&2
            echo "    4. rm -f $REBUILD_RECOVERY_MARKER" >&2
            if declare -f _rebuild_marker_write &>/dev/null; then
                _rebuild_marker_write "$FC_ROLLBACK_FAILED" "$OR_FAILED_FATAL" "$snapshot_dir" "down"
            fi
            return 3  # FATAL (rollback failed)
        fi
    fi

    # v1.78.0: Chain count regression check (relative comparison)
    if [[ "$post_chains" -lt "$pre_chains" ]]; then
        echo "" >&2
        echo "WARNING: Chain count decreased (PRE: $pre_chains → POST: $post_chains)" >&2
        echo "  Some helper chains may be missing. Run: nftban ddos enable" >&2
    fi

    [[ "$quiet" == "false" ]] && echo ""
    [[ "$quiet" == "false" ]] && echo "Schema rebuilt successfully!"
    [[ "$quiet" == "false" ]] && echo "Snapshot saved to: $snapshot_dir"

    # Final validation summary
    [[ "$quiet" == "false" ]] && echo ""
    case "$post_status" in
        protected|idle)
            [[ "$quiet" == "false" ]] && echo "Final status: ${post_status^^} (all checks passed)"
            # v1.96: SUCCESS — clear any stale recovery marker
            # idle = structurally equivalent to protected (no traffic observed yet)
            declare -f _rebuild_marker_clear &>/dev/null && _rebuild_marker_clear
            return 0
            ;;
        degraded)
            [[ "$quiet" == "false" ]] && echo "Final status: DEGRADED (some checks failed)"
            [[ "$quiet" == "false" ]] && echo "  Run 'nftban status' for details"
            # v1.96: Classify DEGRADED — determine if module-related
            if declare -f _rebuild_marker_write &>/dev/null; then
                if _rebuild_classify_has_module_failure 2>/dev/null; then
                    _rebuild_marker_write "$FC_MODULE_RESTORE_FAILED" "$OR_FAILED_DEGRADED" "$snapshot_dir" "degraded"
                elif _rebuild_classify_has_module_incomplete 2>/dev/null; then
                    _rebuild_marker_write "$FC_MODULE_RESTORE_INCOMPLETE" "$OR_FAILED_DEGRADED" "$snapshot_dir" "degraded"
                elif [[ "$_REBUILD_DAEMON_WAS_DOWN" == "true" ]]; then
                    _rebuild_marker_write "$FC_DAEMON_RESTART_FAILED" "$OR_FAILED_DEGRADED" "$snapshot_dir" "degraded"
                fi
                # If DEGRADED but no module/daemon issue, don't write marker
                # (could be a pre-existing DEGRADED state, not caused by this rebuild)
            fi
            return 1
            ;;
        *)
            [[ "$quiet" == "false" ]] && echo "Final status: $post_status"
            # v1.96: Unknown/down post-state without regression from PROTECTED
            if declare -f _rebuild_marker_write &>/dev/null; then
                _rebuild_marker_write "$FC_POSTVALIDATION_HARD_FAIL" "$OR_FAILED_DEGRADED" "$snapshot_dir" "$post_status"
            fi
            return 1
            ;;
    esac
}

# =============================================================================
# SUBCOMMAND: RESET
# =============================================================================

firewall_reset() {
    # Complete firewall reset - flush everything and rebuild clean
    # WARNING: This will remove all bans, whitelists, and geoban data!
    local force=false
    local quiet=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|-f)
                force=true
                shift
                ;;
            --quiet|-q)
                quiet=true
                shift
                ;;
            --help|-h)
                show_reset_help
                return 0
                ;;
            *)
                echo "ERROR: Unknown option: $1" >&2
                return 1
                ;;
        esac
    done

    if [[ "$force" == "false" ]]; then
        echo "WARNING: This will completely reset the firewall!"
        echo ""
        echo "The following will be DELETED:"
        echo "  - All banned IPs"
        echo "  - All whitelisted IPs (will be re-synced)"
        echo "  - All GeoBan entries"
        echo "  - All threat feed entries"
        echo ""
        echo "Use --force to confirm, or Ctrl+C to cancel."
        return 1
    fi

    [[ "$quiet" == "false" ]] && echo "Performing complete firewall reset..."

    # Step 1: Stop nftban services temporarily
    [[ "$quiet" == "false" ]] && echo "  [1/11] Stopping NFTBan services..."
    systemctl stop nftban-maintenance.timer 2>/dev/null || true
    systemctl stop nftband 2>/dev/null || true

    # Step 2: Backup current ruleset
    local backup_dir="/var/lib/nftban/backup"
    mkdir -p "$backup_dir" || return 1
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    [[ "$quiet" == "false" ]] && echo "  [2/11] Backing up current ruleset..."
    nft list ruleset > "$backup_dir/ruleset_$timestamp.nft" 2>/dev/null || true

    # Step 3: Remove NFTBan tables (preserves Docker/cPanel/foreign tables)
    [[ "$quiet" == "false" ]] && echo "  [3/11] Removing NFTBan tables..."
    nft delete table ip nftban 2>/dev/null || true
    nft delete table ip6 nftban 2>/dev/null || true

    # Step 4: Reload NFTBan schema
    [[ "$quiet" == "false" ]] && echo "  [4/11] Loading clean NFTBan schema..."
    local nftban_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftables.conf"
    if [[ -f "$nftban_conf" ]]; then
        if ! nft -f "$nftban_conf" 2>&1; then
            echo "ERROR: Failed to load NFTBan schema" >&2
            echo "Restoring backup..." >&2
            nft -f "$backup_dir/ruleset_$timestamp.nft" 2>/dev/null || true
            return 1
        fi
    fi

    # Step 5: Re-sync system whitelist (lockout protection)
    [[ "$quiet" == "false" ]] && echo "  [5/11] Re-syncing system whitelist..."
    nftban whitelist sync >/dev/null 2>&1 || true

    # Step 6 (v1.50.1): Re-apply DDoS protection if enabled
    [[ "$quiet" == "false" ]] && echo "  [6/11] Re-applying protection modules..."
    local _ddos_enabled="false"
    local _ddos_local_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/ddos/main.conf.local"
    [[ -f "$_ddos_local_conf" ]] && _ddos_enabled=$(grep -oP '^DDOS_ENABLED="\K[^"]+' "$_ddos_local_conf" 2>/dev/null || echo "false")
    if [[ "$_ddos_enabled" == "true" ]]; then
        nftban ddos reload 2>/dev/null || [[ "$quiet" == "false" ]] && echo "    Warning: DDoS reload failed"
    fi

    # Step 7 (v1.50.1): Re-apply portscan if enabled
    [[ "$quiet" == "false" ]] && echo "  [7/11] Re-applying portscan detection..."
    local _portscan_enabled="false"
    local _portscan_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/portscan/main.conf.local"
    [[ -f "$_portscan_conf" ]] && _portscan_enabled=$(grep -oP '^PORTSCAN_ENABLED="\K[^"]+' "$_portscan_conf" 2>/dev/null || echo "false")
    [[ "$_portscan_enabled" != "true" ]] && _portscan_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/portscan/main.conf" && \
        [[ -f "$_portscan_conf" ]] && _portscan_enabled=$(grep -oP '^PORTSCAN_ENABLED="\K[^"]+' "$_portscan_conf" 2>/dev/null || echo "false")
    if [[ "$_portscan_enabled" == "true" ]]; then
        nftban portscan enable --quiet 2>/dev/null || [[ "$quiet" == "false" ]] && echo "    Warning: Portscan enable failed"
    fi

    # Step 8 (v1.50.1, v1.81.0 key fix): Re-apply botguard if enabled
    [[ "$quiet" == "false" ]] && echo "  [8/11] Re-applying BotGuard..."
    if _firewall_botguard_is_enabled; then
        nftban botguard enable --quiet 2>/dev/null || [[ "$quiet" == "false" ]] && echo "    Warning: BotGuard enable failed"
    fi

    # Step 9: Re-sync feeds (v1.50.1: auto-restore)
    [[ "$quiet" == "false" ]] && echo "  [9/11] Re-syncing threat feeds..."
    if declare -f nftban_feeds_sync_to_nftables &>/dev/null; then
        nftban_feeds_sync_to_nftables 2>/dev/null || true
    elif [[ -x "${NFTBAN_CORE_BIN:-${NFTBAN_LIB_DIR}/bin/nftban-core}" ]]; then
        timeout 120s "${NFTBAN_CORE_BIN:-${NFTBAN_LIB_DIR}/bin/nftban-core}" feeds sync 2>/dev/null || true
    fi

    # Step 10: Re-sync geoban (v1.50.1: auto-restore)
    [[ "$quiet" == "false" ]] && echo "  [10/11] Re-syncing GeoBan..."
    timeout 120s nftban geoban sync 2>/dev/null || true

    # Step 11: Restart services
    [[ "$quiet" == "false" ]] && echo "  [11/11] Restarting NFTBan services..."
    systemctl start nftban-maintenance.timer 2>/dev/null || true
    systemctl start nftband 2>/dev/null || true

    [[ "$quiet" == "false" ]] && echo ""
    [[ "$quiet" == "false" ]] && echo "Firewall reset complete!"
    [[ "$quiet" == "false" ]] && echo "Backup saved to: $backup_dir/ruleset_$timestamp.nft"

    return 0
}

# =============================================================================
# SUBCOMMAND: RESTORE (Enterprise Rollback)
# =============================================================================

firewall_restore() {
    # Enterprise rollback - restore previous firewall state
    # Usage: nftban firewall restore <action>
    # Actions:
    #   list      - Show available backups
    #   backup    - Create manual backup
    #   <file>    - Restore from specific backup file
    #   fail2ban  - Re-enable fail2ban
    #   csf       - Re-enable CSF
    #   ufw       - Re-enable UFW
    #   firewalld - Re-enable firewalld

    local action="${1:-list}"
    shift 2>/dev/null || true

    case "$action" in
        -h|--help|help)
            show_restore_help
            return 0
            ;;
        list)
            _restore_list_backups
            ;;
        backup)
            _restore_create_backup "$@"
            ;;
        fail2ban|csf|ufw|firewalld)
            _restore_previous_firewall "$action"
            ;;
        *)
            # Assume it's a backup file path
            if [[ -f "$action" ]]; then
                _restore_from_file "$action"
            elif [[ -f "/var/lib/nftban/backup/$action" ]]; then
                _restore_from_file "/var/lib/nftban/backup/$action"
            else
                echo "ERROR: Unknown action or backup file not found: $action" >&2
                show_restore_help
                return 1
            fi
            ;;
    esac
}

_restore_list_backups() {
    local backup_dir="/var/lib/nftban/backup"

    echo "Available NFTBan Backups"
    echo "========================"
    echo ""

    if [[ ! -d "$backup_dir" ]]; then
        echo "No backup directory found: $backup_dir"
        return 0
    fi

    local count=0
    for f in "$backup_dir"/ruleset_*.nft; do
        [[ -f "$f" ]] || continue
        local fname
        fname=$(basename "$f")
        local fsize
        fsize=$(stat -c%s "$f" 2>/dev/null || echo "?")
        local fdate
        fdate=$(stat -c%y "$f" 2>/dev/null | cut -d. -f1 || echo "?")
        printf "  %-40s %8s bytes  %s\n" "$fname" "$fsize" "$fdate"
        count=$((count + 1))
    done

    if [[ $count -eq 0 ]]; then
        echo "  No backups found"
    fi

    echo ""
    echo "To restore: nftban firewall restore <filename>"
}

_restore_create_backup() {
    local backup_dir="/var/lib/nftban/backup"
    local label="${1:-manual}"

    mkdir -p "$backup_dir" || return 1

    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="$backup_dir/ruleset_${label}_$timestamp.nft"

    echo "Creating backup..."
    if nft list ruleset > "$backup_file" 2>/dev/null; then
        echo "Backup saved: $backup_file"
        return 0
    else
        echo "ERROR: Failed to create backup" >&2
        return 1
    fi
}

_restore_from_file() {
    local backup_file="$1"

    echo "Restoring from: $backup_file"
    echo ""

    # Safety: stop NFTBan services first
    echo "[1/4] Stopping NFTBan services..."
    systemctl stop nftban-maintenance.timer 2>/dev/null || true
    systemctl stop nftband 2>/dev/null || true

    # Flush current ruleset
    echo "[2/4] Flushing current ruleset..."
    nft flush ruleset 2>/dev/null || true

    # Restore backup
    echo "[3/4] Restoring backup..."
    if ! nft -f "$backup_file" 2>&1; then
        echo "ERROR: Failed to restore backup" >&2
        echo "Attempting to reload NFTBan schema..." >&2
        # v1.50.0: Live config should be rendered (no placeholders). Just load it.
        local _nftban_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftables.conf"
        if [[ -f "$_nftban_conf" ]]; then
            nft -f "$_nftban_conf" 2>/dev/null || true
        fi
        return 1
    fi

    # Restart services
    echo "[4/4] Restarting NFTBan services..."
    systemctl start nftban-maintenance.timer 2>/dev/null || true
    systemctl start nftband 2>/dev/null || true

    echo ""
    echo "Restore complete!"
}

_restore_previous_firewall() {
    local firewall="$1"

    echo "Restoring previous firewall: $firewall"
    echo "======================================="
    echo ""
    echo "WARNING: This will disable NFTBan and re-enable $firewall"
    echo ""

    # Step 1: Disable NFTBan
    echo "[1/4] Disabling NFTBan services..."
    systemctl stop nftban-maintenance.timer 2>/dev/null || true
    systemctl stop nftband 2>/dev/null || true
    systemctl disable nftban-maintenance.timer 2>/dev/null || true
    systemctl disable nftband 2>/dev/null || true

    # Step 2: Flush NFTBan tables
    echo "[2/4] Flushing NFTBan nftables..."
    nft delete table ip nftban 2>/dev/null || true
    nft delete table ip6 nftban 2>/dev/null || true

    # Step 3: Re-enable previous firewall
    echo "[3/4] Re-enabling $firewall..."
    case "$firewall" in
        fail2ban)
            systemctl enable fail2ban 2>/dev/null || true
            systemctl start fail2ban 2>/dev/null || true
            ;;
        csf)
            if command -v csf &>/dev/null; then
                csf -e 2>/dev/null || true
            fi
            systemctl enable lfd 2>/dev/null || true
            systemctl start lfd 2>/dev/null || true
            ;;
        ufw)
            systemctl enable ufw 2>/dev/null || true
            systemctl start ufw 2>/dev/null || true
            ufw enable 2>/dev/null || true
            ;;
        firewalld)
            systemctl enable firewalld 2>/dev/null || true
            systemctl start firewalld 2>/dev/null || true
            ;;
    esac

    # Step 4: Verify
    echo "[4/4] Verifying..."
    if systemctl is-active --quiet "$firewall" 2>/dev/null; then
        echo ""
        echo "$firewall is now ACTIVE"
        echo "NFTBan has been disabled"
        echo ""
        echo "To return to NFTBan:"
        echo "  systemctl disable --now $firewall"
        echo "  nftban enable all"
    else
        echo ""
        echo "WARNING: $firewall may not have started correctly"
        echo "Check: systemctl status $firewall"
    fi
}

# =============================================================================
# SUBCOMMAND: RECORD (Schema Snapshot for Audit/Comparison)
# =============================================================================

firewall_record() {
    # Snapshot current live nft schema to JSON for audit/comparison.
    # Usage: nftban firewall record [--output <path>] [--json] [--diff <path>]

    local output_file="/var/lib/nftban/schema/schema_record.json"
    local to_stdout=false
    local diff_file=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output|-o)
                shift
                if [[ $# -eq 0 || "$1" == -* ]]; then
                    echo "ERROR: --output requires a file path" >&2
                    return 1
                fi
                output_file="$1"
                shift
                ;;
            --json)
                to_stdout=true
                shift
                ;;
            --diff|-d)
                shift
                if [[ $# -eq 0 || "$1" == -* ]]; then
                    echo "ERROR: --diff requires a file path" >&2
                    return 1
                fi
                diff_file="$1"
                shift
                ;;
            -h|--help)
                show_record_help
                return 0
                ;;
            *)
                echo "ERROR: Unknown option: $1" >&2
                echo "Try 'nftban firewall record --help' for more information." >&2
                return 1
                ;;
        esac
    done

    # Diff mode: compare current schema against a previously recorded file
    if [[ -n "$diff_file" ]]; then
        _firewall_record_diff "$diff_file"
        return $?
    fi

    # Ensure jq is available (required for JSON generation)
    if ! command -v jq &>/dev/null; then
        echo "ERROR: jq is required for schema recording. Install with: apt install jq" >&2
        return 1
    fi

    # Ensure nft_schema.sh is loaded
    if [[ -z "${NFTBAN_NFT_SCHEMA_LOADED:-}" ]]; then
        if [[ -f "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" ]]; then
            # shellcheck source=/dev/null
            source "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" || {
                echo "ERROR: Cannot load nft_schema.sh" >&2
                return 1
            }
        fi
    fi

    # Get nftban version
    local nftban_version="unknown"
    if [[ -f /VERSION ]]; then
        nftban_version=$(cat /VERSION 2>/dev/null | tr -d '[:space:]')
    fi

    # ── Collect table information ──
    local tables_json="[]"
    local existing_tables
    existing_tables=$(nft list tables 2>/dev/null || true)
    local table_arr=()
    if echo "$existing_tables" | grep -q "^table ${NFTBAN_TABLE_IPV4}$"; then
        table_arr+=("\"${NFTBAN_TABLE_IPV4}\"")
    fi
    if echo "$existing_tables" | grep -q "^table ${NFTBAN_TABLE_IPV6}$"; then
        table_arr+=("\"${NFTBAN_TABLE_IPV6}\"")
    fi
    if [[ ${#table_arr[@]} -gt 0 ]]; then
        tables_json=$(printf '%s\n' "${table_arr[@]}" | jq -s '.')
    fi

    # ── Collect set information (IPv4) ──
    local ipv4_sets_json="{}"
    local ipv4_set_entries=""
    for set_name in "${!NFTBAN_IPV4_SETS[@]}"; do
        local set_spec="${NFTBAN_IPV4_SETS[$set_name]}"
        local _expected_type _expected_flags
        IFS='|' read -r _expected_type _expected_flags _ <<< "$set_spec"

        local count=0
        local actual_type="" actual_flags=""
        if nft list set ip nftban "$set_name" &>/dev/null; then
            count=$(nftban_nft_count_set ip nftban "$set_name" 2>/dev/null || echo 0)
            local set_info
            set_info=$(nft list set ip nftban "$set_name" 2>/dev/null)
            actual_type=$(echo "$set_info" | grep -oP 'type \K[a-z0-9_]+' | head -1 || true)
            actual_flags=$(echo "$set_info" | grep -oP 'flags \K[a-z,]+' | head -1 || true)
        fi

        local entry
        entry=$(jq -n \
            --arg type "${actual_type:-missing}" \
            --arg flags "${actual_flags:-}" \
            --argjson elements "${count:-0}" \
            '{type: $type, flags: $flags, elements: $elements}')
        ipv4_set_entries="${ipv4_set_entries}$(jq -n --arg k "$set_name" --argjson v "$entry" '{($k): $v}')"$'\n'
    done
    if [[ -n "$ipv4_set_entries" ]]; then
        ipv4_sets_json=$(echo "$ipv4_set_entries" | jq -s 'add')
    fi

    # ── Collect set information (IPv6) ──
    local ipv6_sets_json="{}"
    local ipv6_set_entries=""
    for set_name in "${!NFTBAN_IPV6_SETS[@]}"; do
        local set_spec="${NFTBAN_IPV6_SETS[$set_name]}"
        local _expected_type _expected_flags
        IFS='|' read -r _expected_type _expected_flags _ <<< "$set_spec"

        local count=0
        local actual_type="" actual_flags=""
        if nft list set ip6 nftban "$set_name" &>/dev/null; then
            count=$(nftban_nft_count_set ip6 nftban "$set_name" 2>/dev/null || echo 0)
            local set_info
            set_info=$(nft list set ip6 nftban "$set_name" 2>/dev/null)
            actual_type=$(echo "$set_info" | grep -oP 'type \K[a-z0-9_]+' | head -1 || true)
            actual_flags=$(echo "$set_info" | grep -oP 'flags \K[a-z,]+' | head -1 || true)
        fi

        local entry
        entry=$(jq -n \
            --arg type "${actual_type:-missing}" \
            --arg flags "${actual_flags:-}" \
            --argjson elements "${count:-0}" \
            '{type: $type, flags: $flags, elements: $elements}')
        ipv6_set_entries="${ipv6_set_entries}$(jq -n --arg k "$set_name" --argjson v "$entry" '{($k): $v}')"$'\n'
    done
    if [[ -n "$ipv6_set_entries" ]]; then
        ipv6_sets_json=$(echo "$ipv6_set_entries" | jq -s 'add')
    fi

    # ── Collect chain information ──
    local ipv4_chains_json="{}"
    local ipv4_chain_entries=""
    for chain_name in "${!NFTBAN_IPV4_CHAINS[@]}"; do
        local chain_spec="${NFTBAN_IPV4_CHAINS[$chain_name]}"
        local chain_type chain_hook chain_priority _chain_policy
        IFS='|' read -r chain_type chain_hook chain_priority _chain_policy _ <<< "$chain_spec"

        local actual_policy=""
        if nft list chain ip nftban "$chain_name" &>/dev/null; then
            local chain_info
            chain_info=$(nft list chain ip nftban "$chain_name" 2>/dev/null || true)
            chain_info=$(echo "$chain_info" | head -3)
            actual_policy=$(echo "$chain_info" | grep -oP 'policy \K[a-z]+' || true)
        fi

        local entry
        entry=$(jq -n \
            --arg type "$chain_type" \
            --arg hook "$chain_hook" \
            --argjson priority "$chain_priority" \
            --arg policy "${actual_policy:-missing}" \
            '{type: $type, hook: $hook, priority: $priority, policy: $policy}')
        ipv4_chain_entries="${ipv4_chain_entries}$(jq -n --arg k "$chain_name" --argjson v "$entry" '{($k): $v}')"$'\n'
    done
    if [[ -n "$ipv4_chain_entries" ]]; then
        ipv4_chains_json=$(echo "$ipv4_chain_entries" | jq -s 'add')
    fi

    local ipv6_chains_json="{}"
    local ipv6_chain_entries=""
    for chain_name in "${!NFTBAN_IPV6_CHAINS[@]}"; do
        local chain_spec="${NFTBAN_IPV6_CHAINS[$chain_name]}"
        local chain_type chain_hook chain_priority _chain_policy
        IFS='|' read -r chain_type chain_hook chain_priority _chain_policy _ <<< "$chain_spec"

        local actual_policy=""
        if nft list chain ip6 nftban "$chain_name" &>/dev/null; then
            local chain_info
            chain_info=$(nft list chain ip6 nftban "$chain_name" 2>/dev/null || true)
            chain_info=$(echo "$chain_info" | head -3)
            actual_policy=$(echo "$chain_info" | grep -oP 'policy \K[a-z]+' || true)
        fi

        local entry
        entry=$(jq -n \
            --arg type "$chain_type" \
            --arg hook "$chain_hook" \
            --argjson priority "$chain_priority" \
            --arg policy "${actual_policy:-missing}" \
            '{type: $type, hook: $hook, priority: $priority, policy: $policy}')
        ipv6_chain_entries="${ipv6_chain_entries}$(jq -n --arg k "$chain_name" --argjson v "$entry" '{($k): $v}')"$'\n'
    done
    if [[ -n "$ipv6_chain_entries" ]]; then
        ipv6_chains_json=$(echo "$ipv6_chain_entries" | jq -s 'add')
    fi

    # ── Collect rule order validation ──
    local rule_order_json="{}"
    local ip_wl_before_bl=false ip_bl_before_est=false
    local ip6_wl_before_bl=false ip6_bl_before_est=false

    for family in ip ip6; do
        local wl_set="whitelist_ipv4" bl_set="blacklist_ipv4"
        [[ "$family" == "ip6" ]] && wl_set="whitelist_ipv6" && bl_set="blacklist_ipv6"

        local rules
        rules=$(nft -a list chain "$family" nftban input 2>/dev/null || true)
        [[ -z "$rules" ]] && continue

        local wl_h bl_h est_h
        wl_h=$(echo "$rules" | grep -E "@${wl_set}.*accept" | grep -oP 'handle \K[0-9]+' | head -1 || true)
        bl_h=$(echo "$rules" | grep -E "@${bl_set}.*drop" | grep -oP 'handle \K[0-9]+' | head -1 || true)
        est_h=$(echo "$rules" | grep -E 'ct state.*established' | grep -oP 'handle \K[0-9]+' | head -1 || true)

        wl_h=${wl_h:-0}; bl_h=${bl_h:-0}; est_h=${est_h:-0}

        local wl_bl=false bl_est=false
        [[ $wl_h -gt 0 && $bl_h -gt 0 && $wl_h -lt $bl_h ]] && wl_bl=true
        [[ $bl_h -gt 0 && $est_h -gt 0 && $bl_h -lt $est_h ]] && bl_est=true

        if [[ "$family" == "ip" ]]; then
            ip_wl_before_bl=$wl_bl
            ip_bl_before_est=$bl_est
        else
            ip6_wl_before_bl=$wl_bl
            ip6_bl_before_est=$bl_est
        fi
    done

    rule_order_json=$(jq -n \
        --argjson ip_wl "$ip_wl_before_bl" \
        --argjson ip_bl "$ip_bl_before_est" \
        --argjson ip6_wl "$ip6_wl_before_bl" \
        --argjson ip6_bl "$ip6_bl_before_est" \
        '{ip: {whitelist_before_blacklist: $ip_wl, blacklist_before_established: $ip_bl}, ip6: {whitelist_before_blacklist: $ip6_wl, blacklist_before_established: $ip6_bl}}')

    # ── Run validation checks ──
    local tables_ok=false sets_ok=false chains_ok=false types_ok=false rule_order_ok=false
    nftban_nft_validate_tables &>/dev/null && tables_ok=true
    nftban_nft_validate_sets &>/dev/null && sets_ok=true
    nftban_nft_validate_chains &>/dev/null && chains_ok=true
    nftban_nft_validate_set_flags &>/dev/null && types_ok=true
    nftban_nft_validate_rule_order &>/dev/null && rule_order_ok=true

    local overall="PASS"
    if [[ "$tables_ok" != "true" || "$sets_ok" != "true" || "$chains_ok" != "true" || "$types_ok" != "true" || "$rule_order_ok" != "true" ]]; then
        overall="FAIL"
    fi

    local validation_json
    validation_json=$(jq -n \
        --argjson tables_ok "$tables_ok" \
        --argjson sets_ok "$sets_ok" \
        --argjson chains_ok "$chains_ok" \
        --argjson types_ok "$types_ok" \
        --argjson rule_order_ok "$rule_order_ok" \
        --arg overall "$overall" \
        '{tables_ok: $tables_ok, sets_ok: $sets_ok, chains_ok: $chains_ok, types_ok: $types_ok, rule_order_ok: $rule_order_ok, overall: $overall}')

    # ── Assemble final JSON ──
    local recorded_at
    recorded_at=$(date -Is 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z')

    local final_json
    final_json=$(jq -n \
        --arg recorded_at "$recorded_at" \
        --arg nftban_version "$nftban_version" \
        --argjson tables "$tables_json" \
        --argjson ipv4_sets "$ipv4_sets_json" \
        --argjson ipv6_sets "$ipv6_sets_json" \
        --argjson ipv4_chains "$ipv4_chains_json" \
        --argjson ipv6_chains "$ipv6_chains_json" \
        --argjson rule_order "$rule_order_json" \
        --argjson validation "$validation_json" \
        '{
            recorded_at: $recorded_at,
            nftban_version: $nftban_version,
            schema: {
                tables: $tables,
                sets: {
                    "ip nftban": $ipv4_sets,
                    "ip6 nftban": $ipv6_sets
                },
                chains: {
                    "ip nftban": $ipv4_chains,
                    "ip6 nftban": $ipv6_chains
                },
                rule_order: $rule_order,
                validation: $validation
            }
        }')

    # ── Output ──
    if [[ "$to_stdout" == "true" ]]; then
        echo "$final_json"
    else
        # Write to file
        local output_dir
        output_dir=$(dirname "$output_file")
        if [[ ! -d "$output_dir" ]]; then
            mkdir -p "$output_dir" 2>/dev/null || {
                echo "ERROR: Cannot create directory: $output_dir" >&2
                return 1
            }
        fi
        echo "$final_json" > "$output_file" || {
            echo "ERROR: Cannot write to: $output_file" >&2
            return 1
        }
        echo "Schema recorded to: $output_file"
        echo "Version: $nftban_version"
        echo "Validation: $overall"
        echo "Tables: $(echo "$tables_json" | jq -r 'length') | Sets: $((${#NFTBAN_IPV4_SETS[@]} + ${#NFTBAN_IPV6_SETS[@]})) | Chains: $((${#NFTBAN_IPV4_CHAINS[@]} + ${#NFTBAN_IPV6_CHAINS[@]}))"
    fi

    return 0
}

_firewall_record_diff() {
    # Compare current live schema against a previously recorded JSON file
    local baseline_file="$1"

    if [[ ! -f "$baseline_file" ]]; then
        echo "ERROR: Baseline file not found: $baseline_file" >&2
        return 1
    fi

    if ! command -v jq &>/dev/null; then
        echo "ERROR: jq is required for schema diff. Install with: apt install jq" >&2
        return 1
    fi

    # Validate JSON
    if ! jq empty "$baseline_file" 2>/dev/null; then
        echo "ERROR: Invalid JSON in baseline file: $baseline_file" >&2
        return 1
    fi

    # Record current state to temp file
    local current_file
    current_file=$(mktemp /tmp/nftban_schema_current_XXXXXX.json) || return 1

    # Capture current schema to stdout
    firewall_record --json > "$current_file" 2>/dev/null || {
        echo "ERROR: Failed to record current schema" >&2
        rm -f "$current_file"
        return 1
    }

    local baseline_time baseline_version
    baseline_time=$(jq -r '.recorded_at // "unknown"' "$baseline_file")
    baseline_version=$(jq -r '.nftban_version // "unknown"' "$baseline_file")
    local current_version
    current_version=$(jq -r '.nftban_version // "unknown"' "$current_file")

    echo "NFTBan Schema Diff"
    echo "==================="
    echo ""
    echo "Baseline: $baseline_file"
    echo "  Recorded: $baseline_time"
    echo "  Version:  $baseline_version"
    echo ""
    echo "Current:"
    echo "  Version:  $current_version"
    echo ""

    local changes=0

    # Compare tables
    local baseline_tables current_tables
    baseline_tables=$(jq -r '.schema.tables // [] | sort | .[]' "$baseline_file" 2>/dev/null)
    current_tables=$(jq -r '.schema.tables // [] | sort | .[]' "$current_file" 2>/dev/null)

    if [[ "$baseline_tables" != "$current_tables" ]]; then
        echo "Tables: CHANGED"
        local added removed
        added=$(comm -13 <(echo "$baseline_tables" | sort) <(echo "$current_tables" | sort) 2>/dev/null || true)
        removed=$(comm -23 <(echo "$baseline_tables" | sort) <(echo "$current_tables" | sort) 2>/dev/null || true)
        [[ -n "$added" ]] && echo "  Added: $added"
        [[ -n "$removed" ]] && echo "  Removed: $removed"
        changes=$((changes + 1))
    else
        echo "Tables: unchanged"
    fi

    # Compare sets (count changes)
    echo ""
    echo "Set Element Counts:"
    for table_key in "ip nftban" "ip6 nftban"; do
        local jq_key="$table_key"
        local baseline_sets current_sets
        baseline_sets=$(jq -r --arg t "$jq_key" '.schema.sets[$t] // {} | keys[]' "$baseline_file" 2>/dev/null | sort)
        current_sets=$(jq -r --arg t "$jq_key" '.schema.sets[$t] // {} | keys[]' "$current_file" 2>/dev/null | sort)

        for set_name in $(echo -e "${baseline_sets}\n${current_sets}" | sort -u); do
            local b_count c_count
            b_count=$(jq -r --arg t "$jq_key" --arg s "$set_name" '.schema.sets[$t][$s].elements // 0' "$baseline_file" 2>/dev/null)
            c_count=$(jq -r --arg t "$jq_key" --arg s "$set_name" '.schema.sets[$t][$s].elements // 0' "$current_file" 2>/dev/null)
            if [[ "$b_count" != "$c_count" ]]; then
                local delta=$((c_count - b_count))
                local sign="+"
                [[ $delta -lt 0 ]] && sign=""
                echo "  ${table_key} ${set_name}: ${b_count} -> ${c_count} (${sign}${delta})"
                changes=$((changes + 1))
            fi
        done
    done

    # Compare validation results
    echo ""
    local baseline_overall current_overall
    baseline_overall=$(jq -r '.schema.validation.overall // "unknown"' "$baseline_file" 2>/dev/null)
    current_overall=$(jq -r '.schema.validation.overall // "unknown"' "$current_file" 2>/dev/null)
    if [[ "$baseline_overall" != "$current_overall" ]]; then
        echo "Validation: ${baseline_overall} -> ${current_overall}"
        changes=$((changes + 1))
    else
        echo "Validation: ${current_overall} (unchanged)"
    fi

    echo ""
    if [[ $changes -eq 0 ]]; then
        echo "Result: No differences detected"
    else
        echo "Result: ${changes} change(s) detected"
    fi

    rm -f "$current_file"
    return 0
}

# =============================================================================
# HELP FUNCTIONS
# =============================================================================

show_firewall_help() {
    cat <<'EOF'
Usage: nftban firewall <subcommand> [options]

Firewall structure validation, IP/port checking, and management.

Overview:
  status        Quick overview (tables, sets, services, conflicts)
  stats         Show firewall statistics (tables, chains, sets, IPs)

Validation & Diagnostics:
  validate      Validate nftables structure (use --strict for full check)
  conflicts     Detect conflicting firewalls (fail2ban, ufw, etc.)
  check         Check if IP or port is blocked/allowed
  logs          View and filter firewall logs
  record        Snapshot current nft schema to JSON for audit/comparison

Operations:
  init          Initialize firewall tables (alias for rebuild)
  reload        Reload nftables ruleset from config
  rebuild       Rebuild schema (fix corruption, keeps IPs)
  reset         Complete reset (flush all, rebuild clean)
  restore       Enterprise rollback (restore previous state)
  takeover      Disarm conflicting external firewalls (CSF/iptables/firewalld); reversible

Examples:
  # Validate with strict mode (recommended before enabling)
  nftban firewall validate --strict

  # Check for conflicting firewalls
  nftban firewall conflicts

  # Quick checks
  nftban firewall check 1.2.3.4
  nftban firewall stats

  # Schema audit
  nftban firewall record               # Snapshot schema to JSON
  nftban firewall record --json        # Output to stdout
  nftban firewall record --diff file   # Compare against baseline

  # Recovery operations
  nftban firewall rebuild              # Fix corruption
  nftban firewall reset --force        # Full reset
  nftban firewall restore list         # Show backups
  nftban firewall restore fail2ban     # Rollback to fail2ban

Global options:
  --json        Output results as JSON (for scripts/API integration)
  -h, --help    Show help for specific subcommand

CTRL+C / INTERRUPTION:
  Do NOT interrupt rebuild, reset, restore, reload, or takeover with
  Ctrl+C once execution has started. These operations apply nft rulesets
  in stages; an interrupted run can leave the kernel between rulesets
  with partial protection. If a recovery is needed after an interruption,
  run 'nftban firewall reload' or 'nftban firewall rebuild' from a stable
  shell to converge back to config.

REQUIRES:
  Elevated privileges for mutating subcommands:
    rebuild, reset, restore, reload, takeover, record --write.

  Users in the nftban group may be authorized through PolicyKit/polkit
  rules for supported NFTBan operations.

  Read-only subcommands do not require elevated privileges:
    status, stats, validate, conflicts, check, logs, record without --write.

Exit codes (validate --strict):
  0   OK - NFTBan is sole firewall authority
  10  policykit-1 missing (Debian/Ubuntu)
  20  Firewall conflict (fail2ban/ufw/firewalld/csf active)
  30  NFTables collision (non-NFTBan input hooks)
  1   Structural validation failed (Go validator reported errors)
  40  Validator binary missing or environment error

Exit codes (other subcommands):
  0   Success
  1   General error (nft failure, IPC failure)
  2   PolicyKit/polkit authorization failed or insufficient privileges

For detailed help:
  nftban firewall validate --help
  nftban firewall restore --help

EOF
}

show_restore_help() {
    cat <<'EOF'
Usage: nftban firewall restore <action>

Enterprise rollback - restore previous firewall state.

Actions:
  list              Show available backup files
  backup [label]    Create manual backup with optional label
  <filename>        Restore from specific backup file
  fail2ban          Disable NFTBan, re-enable fail2ban
  csf               Disable NFTBan, re-enable CSF
  ufw               Disable NFTBan, re-enable UFW
  firewalld         Disable NFTBan, re-enable firewalld

Examples:
  # List available backups
  nftban firewall restore list

  # Create manual backup
  nftban firewall restore backup pre-upgrade

  # Restore from backup file
  nftban firewall restore ruleset_20260220_143000.nft

  # Rollback to previous firewall
  nftban firewall restore fail2ban

Backup location: /var/lib/nftban/backup/

What 'restore <firewall>' does:
  1. Stops NFTBan services
  2. Disables NFTBan services
  3. Flushes NFTBan nftables
  4. Re-enables specified firewall
  5. Starts specified firewall

To return to NFTBan after rollback:
  systemctl disable --now <firewall>
  nftban enable all

EOF
}

show_validate_help() {
    cat <<'EOF'
Usage: nftban firewall validate [OPTIONS]

Validate nftables structure against NFTBan specification.

Standard Checks:
  - Required tables exist (ip nftban, ip6 nftban)
  - Forbidden tables don't exist (inet filter - bypasses NFTBan!)
  - Required sets exist (whitelist_ipv4, blacklist_ipv4, tcp_ports_in, etc.)
  - Chain policies are correct (input=drop, output=accept)
  - Priority order is correct (-10, -5, 0)

Strict Mode (--strict): Single Firewall Authority
  - policykit-1 MANDATORY on Debian/Ubuntu
  - No competing firewalls (fail2ban, ufw, firewalld, csf, iptables)
  - No non-NFTBan active input hooks in nftables

Options:
  --strict, -s  Enforce Single Firewall Authority (recommended)
  --json        Output results as JSON
  -h, --help    Show this help message

Exit codes:
  0   All validation checks passed (OK)
  1   Structure validation errors
  10  policykit-1 missing (Debian/Ubuntu only)
  20  Firewall authority conflict (fail2ban/ufw/firewalld/csf active)
  30  NFTables hook collision (non-NFTBan active input hooks)
  40  Environment error (missing commands/libraries)

Examples:
  # Standard validation
  nftban firewall validate

  # Strict mode - enforce single firewall authority
  nftban firewall validate --strict

  # JSON output for automation
  nftban firewall validate --strict --json

  # Use in scripts
  if nftban firewall validate --strict; then
    nftban enable all
  else
    echo "Fix issues before enabling NFTBan"
    exit $?
  fi

See also:
  nftban health conflicts    - Detect and fix conflicting firewalls
  nftban firewall rebuild    - Rebuild schema (preserves IPs)
  nftban firewall reset      - Complete reset (flush all data)

EOF
}

show_check_help() {
    cat <<'EOF'
Usage: nftban firewall check <IP|PORT> [OPTIONS]

Check if IP address or port is blocked or allowed in nftables.

The command:
  1. Detects if value is an IP (contains . or :) or port (numeric)
  2. Checks nftables processing path (priority -10 → -5 → 0)
  3. Shows which rule matched (table, chain, set, verdict)
  4. Displays available actions (block, unblock, whitelist, etc.)

Arguments:
  IP|PORT       IP address (1.2.3.4 or 2001:db8::1) or port number (22)

Options:
  --json        Output results as JSON
  -h, --help    Show this help message

Exit codes:
  0   Check completed successfully
  1   Error (invalid input, nftables error)

Examples:
  # Check if IP is blocked
  nftban firewall check 1.2.3.4

  # Check if port is allowed
  nftban firewall check 22

  # JSON output (for scripts/API)
  nftban firewall check 1.2.3.4 --json

Processing Path:
  Priority: ip/ip6 nftban input_temp_whitelist (temp whitelist)
  Priority: ip/ip6 nftban input_tempban (temp bans)
  Priority: ip/ip6 nftban input (whitelist, blacklist, ports, default deny)

Output includes:
  - Status: allowed / blocked / unknown
  - Matched rule: table, chain, set/rule, verdict
  - Processing path: shows which chains were checked
  - Available actions: block, unblock, whitelist, etc.

EOF
}

show_stats_help() {
    cat <<'EOF'
Usage: nftban firewall stats [OPTIONS]

Display firewall statistics (tables, chains, sets, rules, IP counts).

Statistics include:
  - Summary: total tables, chains, sets, rules
  - Per-set counts: number of IPs in whitelist, blacklist, temp bans, etc.
  - Per-table breakdown: main table vs runtime table

Options:
  --json        Output results as JSON
  -h, --help    Show this help message

Exit codes:
  0   Statistics retrieved successfully
  1   Error (nftables error, permission denied)

Examples:
  # Display statistics
  nftban firewall stats

  # JSON output (for scripts/API)
  nftban firewall stats --json

Output includes:
  - Total counts (tables, chains, sets, rules)
  - ip/ip6 nftban: whitelist, blacklist, tcp_ports_in/out, udp_ports_in/out
  - ip/ip6 nftban: temp_whitelist, temp_ban (with auto-expire)

EOF
}

show_rebuild_help() {
    cat <<'EOF'
Usage: nftban firewall rebuild [OPTIONS]

Rebuild nftables schema from scratch while preserving IP data.

Use this when:
  - Schema is corrupted (validation errors)
  - Rogue tables detected (ip raw, ip6 raw, etc.)
  - After manual nft commands broke the structure
  - After RPM upgrade when .rpmnew config exists

What it does:
  1. Backs up current IPs from all sets
  2. Renders template with SSH port + CT limits (from DDoS config)
  3. Validates rendered schema (dry-run) BEFORE flushing
  4. Atomic-writes rendered config to /etc/nftban/nftables.conf
  5. Removes rogue tables (non-NFTBan tables)
  6. Flushes and loads validated schema
  7. Re-syncs system whitelist + restores blacklist

Safety: Schema is validated with 'nft -c -f' before any changes.
If validation fails, existing firewall is preserved (no lockout).
Source: /usr/lib/nftban/templates/nftables.conf.tpl (v1.50.0+)

Options:
  --force, -f   Skip confirmation prompts
  --quiet, -q   Suppress progress output
  --use-new     Prefer .rpmnew config over existing (after RPM upgrade)
  -h, --help    Show this help message

Examples:
  nftban firewall rebuild
  nftban firewall rebuild --force
  nftban firewall rebuild --use-new   # Use RPM-provided new config

Note: For complete reset (lose all data), use:
  nftban firewall reset --force

EOF
}

show_reset_help() {
    cat <<'EOF'
Usage: nftban firewall reset [OPTIONS]

Complete firewall reset - flush everything and rebuild clean.

WARNING: This DELETES all:
  - Banned IPs
  - Whitelisted IPs (auto-resynced after)
  - GeoBan entries
  - Threat feed entries

Use this when:
  - Schema is completely broken
  - Need to start fresh
  - firewall rebuild fails

What it does:
  1. Stops NFTBan services
  2. Backs up current ruleset
  3. Flushes ALL nftables rules
  4. Loads clean NFTBan schema
  5. Re-syncs system whitelist (lockout protection)
  6. Restarts NFTBan services

Options:
  --force, -f   Required to confirm the reset
  --quiet, -q   Suppress progress output
  -h, --help    Show this help message

Examples:
  nftban firewall reset --force

After reset, restore data with:
  nftban geoban sync
  nftban feeds sync

EOF
}

show_record_help() {
    cat <<'EOF'
Usage: nftban firewall record [OPTIONS]

Snapshot the current live nft schema to a JSON file for audit/comparison.
Creates a "known good" baseline that can later be diffed against.

Options:
  --output, -o <path>   Where to save (default: /var/lib/nftban/schema/schema_record.json)
  --json                Output to stdout instead of file (for piping)
  --diff, -d <path>     Compare current schema against a previously recorded file
  -h, --help            Show this help message

What it records:
  - Tables present (ip nftban, ip6 nftban)
  - All sets with types, flags, and element counts
  - All chains with types, hooks, priorities, and policies
  - Rule order validation (whitelist -> blacklist -> established)
  - Overall validation result (PASS/FAIL)

Examples:
  # Record current schema to default location
  nftban firewall record

  # Record to custom path
  nftban firewall record --output /tmp/schema_before_upgrade.json

  # Output JSON to stdout (for piping)
  nftban firewall record --json | jq .schema.validation

  # Compare current schema against a baseline
  nftban firewall record --diff /var/lib/nftban/schema/schema_record.json

Workflow:
  # Before upgrade: record baseline
  nftban firewall record --output /var/lib/nftban/schema/pre_upgrade.json

  # After upgrade: compare
  nftban firewall record --diff /var/lib/nftban/schema/pre_upgrade.json

Output location: /var/lib/nftban/schema/

EOF
}

# Export functions
export -f nftban_cmd_firewall
