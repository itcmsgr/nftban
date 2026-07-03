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
net.netfilter.nf_conntrack_tcp_timeout_established|read-only-observed|kernel-default(432000)|/etc/sysctl.d/99-local.conf|warn if live value < net.ipv4.tcp_keepalive_time AND a local idle TCP DB pool exists (dead-socket precondition)|not set by NFTBan as of v1.216.0; remove any 99-local override; kernel default applies on reboot
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

# _nftban_local_db_pool -> yes|no : any local idle TCP connection to a DB port. Test hook: NFTBAN_TEST_DB_POOL
_nftban_local_db_pool() {
    if [ -n "${NFTBAN_TEST_DB_POOL:-}" ]; then printf '%s' "$NFTBAN_TEST_DB_POOL"; return 0; fi
    local n=0
    if command -v ss >/dev/null 2>&1; then
        n=$(ss -tnH state established 2>/dev/null | grep -cE '(127\.0\.0\.1|\[?::1\]?):(5432|3306|6379|27017)([^0-9]|$)') || n=0
    fi
    _nftban_is_uint "$n" || n=0
    [ "$n" -gt 0 ] && echo "yes" || echo "no"
}

# nftban_sysctl_risk_scan — emit findings "SEVERITY|key|message" (SEVERITY = INFO|WARN). READ-ONLY.
nftban_sysctl_risk_scan() {
    local est="net.netfilter.nf_conntrack_tcp_timeout_established"
    local live_est file_est local_est keepalive dbpool
    live_est=$(_nftban_sysctl_live "$est")
    file_est=$(_nftban_sysctl_file_value "$est" "$NFTBAN_SYSCTL_FILE")
    local_est=$(_nftban_sysctl_file_value "$est" "$NFTBAN_SYSCTL_LOCAL")
    keepalive=$(_nftban_sysctl_live "net.ipv4.tcp_keepalive_time")
    _nftban_is_uint "$keepalive" || keepalive=7200
    dbpool=$(_nftban_local_db_pool)

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
    # (a) the incident precondition: live established < keepalive AND a local idle TCP DB pool
    if _nftban_is_uint "$live_est" && [ "$live_est" -lt "$keepalive" ]; then
        if [ "$dbpool" = "yes" ]; then
            echo "WARN|$est|live established timeout (${live_est}s) < tcp_keepalive_time (${keepalive}s) with a local idle TCP DB pool — idle DB connections can be conntrack-evicted before keepalive probes (dead-socket risk)"
        else
            echo "INFO|$est|established timeout (${live_est}s) < tcp_keepalive_time (${keepalive}s) — no local DB pool detected, low risk"
        fi
    fi
    return 0
}
