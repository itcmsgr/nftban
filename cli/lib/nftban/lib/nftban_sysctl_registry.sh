#!/usr/bin/env bash
# =============================================================================
# NFTBan — Declarative sysctl registry + read-only risk scan
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="nftban-sysctl-registry"
# meta:type="library"
# meta:header="Sysctl Registry (read-only)"
# meta:version="1.215.0"
# meta:owner="NFTBan Project / Antonios Voulvoulis"
# meta:homepage="https://nftban.com"
#
# meta:description="Minimal declarative registry of NFTBan-relevant kernel sysctls (v1.216.0, OPEN_UNIFIED_PROFILE_SYSCTL_SAFE_DEFAULT) + a READ-ONLY risk scan. This library NEVER writes the live kernel or any file — it only reads /proc/sys, the shipped 90-nftban.conf, and 99-local.conf, and emits advisory findings for health/watchdog/support/CLI."
# meta:inventory.files="cli/lib/nftban/lib/nftban_sysctl_registry.sh"
# meta:inventory.binaries="sysctl,ss,grep,sed"
# meta:inventory.config_files="/etc/sysctl.d/90-nftban.conf,/etc/sysctl.d/99-local.conf"
# meta:inventory.env_vars="NFTBAN_SYSCTL_FILE,NFTBAN_SYSCTL_LOCAL"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none (read-only)"
# meta:created_date="2026-07-03"
# meta:updated_date="2026-07-03"
# =============================================================================
set -Eeuo pipefail

# Double-load prevention (sourced library)
[[ -n "${_NFTBAN_SYSCTL_REGISTRY_LOADED:-}" ]] && return 0 2>/dev/null || true
readonly _NFTBAN_SYSCTL_REGISTRY_LOADED=1

# READ-ONLY. No function here writes the kernel, a file, or nftables.

NFTBAN_SYSCTL_FILE="${NFTBAN_SYSCTL_FILE:-/etc/sysctl.d/90-nftban.conf}"
NFTBAN_SYSCTL_LOCAL="${NFTBAN_SYSCTL_LOCAL:-/etc/sysctl.d/99-local.conf}"

# nftban_sysctl_registry — emit the declarative registry, one record per line:
#   key|owner_class|package_default|override_path|risk_rule|rollback
nftban_sysctl_registry() {
    cat <<'REG'
net.netfilter.nf_conntrack_tcp_timeout_established|read-only-observed|kernel-default(432000)|/etc/sysctl.d/99-local.conf|warn if live value < net.ipv4.tcp_keepalive_time AND a local TCP DB session is LONG-IDLE (idle age approaching the established timeout); actively-refreshed monitoring sessions are INFO; unmeasurable idle age is UNKNOWN (v1.216.1 idle-age-aware)|not set by NFTBan as of v1.216.0; remove any 99-local override; kernel default applies on reboot
net.netfilter.nf_conntrack_max|nftban-owned-default|262144|/etc/sysctl.d/99-local.conf|informational: large value uses more kernel memory on small hosts|revert 90-nftban.conf / package downgrade
REG
}

_nftban_is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# _nftban_sysctl_live KEY -> live value (read-only). Test hook: NFTBAN_TEST_LIVE_<key with . -> _>
_nftban_sysctl_live() {
    local key="$1" tv
    tv="NFTBAN_TEST_LIVE_${key//./_}"
    if [ -n "${!tv:-}" ]; then printf '%s' "${!tv}"; return 0; fi
    sysctl -n "$key" 2>/dev/null | tr -d '[:space:]' || true
}

# _nftban_sysctl_file_value KEY FILE -> value assigned in FILE (last wins) or empty
_nftban_sysctl_file_value() {
    local key="$1" file="$2" k
    [ -f "$file" ] || return 0
    k="${key//./\\.}"
    grep -E "^[[:space:]]*${k}[[:space:]]*=" "$file" 2>/dev/null | tail -1 | sed -E 's/^[^=]*=[[:space:]]*//' | tr -d '[:space:]' || true
}

# v1.216.1: idle-age-aware dead-socket classification (read-only, credential-free, NO DB queries).
# The dead-socket risk is a local TCP DB session left IDLE longer than the conntrack established
# timeout (so conntrack evicts it before tcp_keepalive_time probes). A short-idle, actively-polled
# monitoring session (e.g. zabbix-agent2, idle ~60s) is NOT that risk. Idle age is derived host-only
# from the conntrack REMAINING timeout (idle ≈ established_timeout - remaining), with a cross-scan
# ss-stability fallback and an explicit UNKNOWN when idle age cannot be measured (never silent-CLEAN).
NFTBAN_SYSCTL_IDLE_WARN_PCT="${NFTBAN_SYSCTL_IDLE_WARN_PCT:-50}"   # WARN if max idle >= this % of established timeout
NFTBAN_SYSCTL_SAMPLE_SECS="${NFTBAN_SYSCTL_SAMPLE_SECS:-2}"        # cross-scan fallback window

# _nftban_db_pool_count -> count of established local TCP connections to DB ports. Hook: NFTBAN_TEST_POOL_COUNT
_nftban_db_pool_count() {
    if [ -n "${NFTBAN_TEST_POOL_COUNT:-}" ]; then printf '%s' "$NFTBAN_TEST_POOL_COUNT"; return 0; fi
    local n=0
    command -v ss >/dev/null 2>&1 && n=$(ss -tnH state established 2>/dev/null | grep -cE '(127\.0\.0\.1|\[?::1\]?):(5432|3306|6379|27017)([^0-9]|$)' || true)
    _nftban_is_uint "$n" || n=0
    printf '%s' "$n"
}

# _nftban_db_conntrack_maxidle EST -> max idle seconds across local DB-port conntrack entries, or "UNKNOWN".
# Hook: NFTBAN_TEST_MAXIDLE (integer or "UNKNOWN"). Uses /proc/net/nf_conntrack (remaining timeout field
# immediately precedes "ESTABLISHED"); idle = est - remaining. No conntrack visibility -> UNKNOWN.
_nftban_db_conntrack_maxidle() {
    local est="$1" src=""
    if [ -n "${NFTBAN_TEST_MAXIDLE:-}" ]; then printf '%s' "$NFTBAN_TEST_MAXIDLE"; return 0; fi
    _nftban_is_uint "$est" || { echo "UNKNOWN"; return 0; }
    if [ -r /proc/net/nf_conntrack ]; then
        src=$(grep -E 'ESTABLISHED' /proc/net/nf_conntrack 2>/dev/null | grep -E '(sport|dport)=(5432|3306|6379|27017)([^0-9]|$)' | grep -E '127\.0\.0\.1|::1' || true)
    else echo "UNKNOWN"; return 0; fi
    [ -z "$src" ] && { echo "UNKNOWN"; return 0; }   # pool exists but no conntrack DB entries -> unmeasurable
    printf '%s\n' "$src" | awk -v est="$est" 'BEGIN{mx=-1} {for(i=1;i<=NF;i++) if($i=="ESTABLISHED"){to=$(i-1)+0; idle=est-to; if(idle<0)idle=0; if(idle>mx)mx=idle}} END{ if(mx<0) print "UNKNOWN"; else printf "%d", mx }'
}

# _nftban_db_pool_stable -> yes|no : is the DB pool connection-set unchanged across a bounded window?
# Fallback idle proxy when conntrack is unreadable. Hook: NFTBAN_TEST_SAMPLE_STABLE
_nftban_db_pool_stable() {
    if [ -n "${NFTBAN_TEST_SAMPLE_STABLE:-}" ]; then printf '%s' "$NFTBAN_TEST_SAMPLE_STABLE"; return 0; fi
    command -v ss >/dev/null 2>&1 || { echo "no"; return 0; }
    local a b
    a=$(ss -tnH state established 2>/dev/null | grep -E '(127\.0\.0\.1|\[?::1\]?):(5432|3306|6379|27017)([^0-9]|$)' | awk '{print $3"-"$4}' | sort | tr '\n' ',')
    sleep "${NFTBAN_SYSCTL_SAMPLE_SECS}" 2>/dev/null || true
    b=$(ss -tnH state established 2>/dev/null | grep -E '(127\.0\.0\.1|\[?::1\]?):(5432|3306|6379|27017)([^0-9]|$)' | awk '{print $3"-"$4}' | sort | tr '\n' ',')
    [ "$a" = "$b" ] && echo "yes" || echo "no"
}

# nftban_db_dead_socket_classify EST KEEPALIVE -> "CLASS|pool|maxidle|reason"  (CLASS: CLEAN|INFO|WARN|UNKNOWN)
nftban_db_dead_socket_classify() {
    local est="$1" keep="$2" pool mi thr st
    pool=$(_nftban_db_pool_count); _nftban_is_uint "$pool" || pool=0
    [ "$pool" -eq 0 ] && { echo "CLEAN|0|0|no local TCP DB pool"; return 0; }
    # established >= keepalive: keepalive probes before conntrack evicts -> no dead-socket risk regardless of idle
    if _nftban_is_uint "$est" && [ "$est" -ge "$keep" ]; then
        echo "INFO|$pool|0|${pool} local TCP DB session(s); established timeout ${est}s >= keepalive ${keep}s (keepalive probes first) — no dead-socket risk"; return 0
    fi
    mi=$(_nftban_db_conntrack_maxidle "$est")
    if [ "$mi" = "UNKNOWN" ]; then
        st=$(_nftban_db_pool_stable)
        if [ "$st" = "no" ]; then
            echo "INFO|$pool|?|${pool} local TCP DB session(s), pool churning across ${NFTBAN_SYSCTL_SAMPLE_SECS}s sample (active) — idle age unmeasurable, low risk"
        else
            echo "UNKNOWN|$pool|?|${pool} local TCP DB session(s) stable across sample but idle age UNMEASURABLE (conntrack unreadable) — cannot confirm safe"
        fi
        return 0
    fi
    _nftban_is_uint "$mi" || mi=0
    thr=$(( est * NFTBAN_SYSCTL_IDLE_WARN_PCT / 100 ))
    if [ "$mi" -ge "$thr" ]; then
        echo "WARN|$pool|$mi|${pool} local TCP DB session(s), max idle ~${mi}s >= ${NFTBAN_SYSCTL_IDLE_WARN_PCT}% of established timeout ${est}s (< keepalive ${keep}s) — long-idle dead-socket risk"
    else
        echo "INFO|$pool|$mi|${pool} local TCP DB session(s), actively refreshed (max idle ~${mi}s << established timeout ${est}s) — low risk"
    fi
}

# nftban_sysctl_risk_scan — emit findings "SEVERITY|key|message" (SEVERITY = INFO|WARN). READ-ONLY.
nftban_sysctl_risk_scan() {
    local est="net.netfilter.nf_conntrack_tcp_timeout_established"
    local live_est file_est local_est keepalive
    live_est=$(_nftban_sysctl_live "$est")
    file_est=$(_nftban_sysctl_file_value "$est" "$NFTBAN_SYSCTL_FILE")
    local_est=$(_nftban_sysctl_file_value "$est" "$NFTBAN_SYSCTL_LOCAL")
    keepalive=$(_nftban_sysctl_live "net.ipv4.tcp_keepalive_time")
    _nftban_is_uint "$keepalive" || keepalive=7200

    # (e) operator override present -> INFO
    [ -n "$local_est" ] && echo "INFO|$est|operator override present in ${NFTBAN_SYSCTL_LOCAL} = ${local_est}s"
    # (b) legacy static 600 still in the shipped file (should be gone as of v1.216.0)
    [ "$file_est" = "600" ] && echo "WARN|$est|legacy established=600 present in ${NFTBAN_SYSCTL_FILE} (pre-v1.216.0 default) — remove it or override in 99-local.conf"
    # (c) file-vs-live drift
    if [ -n "$file_est" ] && [ -n "$live_est" ] && [ "$file_est" != "$live_est" ]; then
        echo "WARN|$est|file value (${file_est}) != live value (${live_est}) — not applied (pending reboot or module-load race)"
    fi
    # (d) module-load race: file configures a non-default value but live is the kernel default
    if [ -n "$file_est" ] && [ "$file_est" != "432000" ] && [ "$live_est" = "432000" ]; then
        echo "WARN|$est|configured ${file_est} but live is kernel-default 432000 — nf_conntrack not loaded when sysctl was applied (module-load race)"
    fi
    # (a) dead-socket precondition — v1.216.1 idle-age-aware classification (CLEAN/INFO/WARN/UNKNOWN).
    # WARN only for genuinely long-idle local TCP DB sessions (idle approaching the established timeout);
    # actively-refreshed monitoring sessions (short idle) are INFO; unmeasurable idle age is UNKNOWN.
    local _cls _class _reason
    _cls=$(nftban_db_dead_socket_classify "${live_est:-}" "${keepalive}")
    _class="${_cls%%|*}"; _reason="${_cls##*|}"
    case "$_class" in
        WARN)    echo "WARN|$est|established ${live_est}s < keepalive ${keepalive}s + ${_reason} (dead-socket risk)" ;;
        UNKNOWN) echo "UNKNOWN|$est|established ${live_est}s < keepalive ${keepalive}s + ${_reason}" ;;
        INFO)    echo "INFO|$est|${_reason}" ;;
        CLEAN)   : ;;  # no local TCP DB pool -> no line
    esac
    return 0
}
