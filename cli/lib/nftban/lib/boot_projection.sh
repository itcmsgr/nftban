#!/usr/bin/env bash
# =============================================================================
# NFTBan - boot projection authority (v1.229.12 P12-FPA Phase 1)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="boot_projection"
# meta:type="library"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-28"
# meta:description="Single authority for the NFTBan BOOT PROJECTION: the generated, persistent, early-boot executable nftables artifact that nftables.service includes. Owns its path, its DO-NOT-EDIT header, its generation from the canonical schema, and its validation. It DOES NOT substitute placeholders itself — it requires _firewall_substitute_placeholders (cmd_firewall.sh) and FAILS CLOSED when that authority is absent, because a local fallback would be the second firewall authority P12-FPA exists to remove. PHASE 1: generation and validation only. NOTHING here repoints a live boot include."
# meta:input="canonical schema (nftables.conf.tpl); _firewall_substitute_placeholders"
# meta:output="validated boot projection at the requested path"
# meta:depends="bash,nft,mktemp,mv"
# meta:inventory.files="/etc/nftban/generated/nftban-boot.nft"
# meta:inventory.binaries="nft,mktemp,mv"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root (writes under /etc/nftban)"
# =============================================================================

# Prevent double-loading
[[ -n "${NFTBAN_BOOT_PROJECTION_LOADED:-}" ]] && return 0
NFTBAN_BOOT_PROJECTION_LOADED=1

# -----------------------------------------------------------------------------
# PATH AUTHORITY.
#
# /etc/nftban/generated/ is a DELIBERATE FHS EXCEPTION, frozen by owner ruling
# 2026-08-28. nftables.service may run BEFORE a separate /var is mounted on
# Debian-family systems (DefaultDependencies=no, ordered only after -.mount), so
# the boot projection must live on the root filesystem. DO NOT "fix" this by
# moving it to /var/lib without first changing and PROVING the nftables.service
# mount-order contract — a projection that can be missing at boot is a worse
# defect than an FHS placement exception.
#
# This is NOT a configuration file. It is generated executable state.
# -----------------------------------------------------------------------------
nftban_boot_projection_dir()  { printf '%s/generated' "${NFTBAN_CONFIG_DIR:-/etc/nftban}"; }
nftban_boot_projection_path() { printf '%s/nftban-boot.nft' "$(nftban_boot_projection_dir)"; }

# -----------------------------------------------------------------------------
# HEADER AUTHORITY (frozen).
#
# Deliberately carries NO timestamp and NO hostname: the projection must be
# byte-reproducible from the same inputs, or drift detection cannot tell a
# regeneration from a modification.
# -----------------------------------------------------------------------------
nftban_boot_projection_header() {
    cat <<'HDR'
# NFTBAN GENERATED BOOT PROJECTION
# Owner: NFTBan
# Lifecycle: persistent early-boot nftables projection
# Source: canonical NFTBan firewall schema + effective configuration
# DO NOT EDIT
# Operator overrides belong in /etc/nftban/conf.d/*.conf.local
HDR
}

# -----------------------------------------------------------------------------
# nftban_boot_projection_validate <file> [label]
#
# nft -c parses without committing. On an unprivileged host nft still opens
# netlink, so retry inside a user+net namespace. A privilege failure is
# reported as UNKNOWN (rc=2), never as success: an unrunnable check is not a
# passed check.
#   rc=0 valid · rc=1 INVALID · rc=2 UNKNOWN (could not be checked)
# -----------------------------------------------------------------------------
nftban_boot_projection_validate() {
    local file="$1" label="${2:-boot projection}" err=""
    [[ -f "$file" ]] || { echo "[NFTBan ERROR] $label: not found: $file" >&2; return 1; }
    command -v nft >/dev/null 2>&1 || { echo "[NFTBan WARN] $label: nft absent — NOT validated" >&2; return 2; }

    if err=$(nft -c -f "$file" 2>&1); then return 0; fi
    if grep -qiE 'permission|not permitted|netlink|Operation not' <<<"$err" \
       && command -v unshare >/dev/null 2>&1; then
        if err=$(unshare -rn nft -c -f "$file" 2>&1); then return 0; fi
    fi
    if grep -qiE 'permission|not permitted|netlink|Operation not' <<<"$err"; then
        echo "[NFTBan WARN] $label: nft -c could not run (privileges) — NOT validated" >&2
        return 2
    fi
    echo "[NFTBan ERROR] $label: nft -c REJECTED the ruleset:" >&2
    head -5 <<<"$err" >&2
    return 1
}

# -----------------------------------------------------------------------------
# nftban_boot_projection_generate <canonical_schema> <output_path>
#
# TRANSACTION ORDER (frozen): render -> assert fully rendered -> nft -c ->
# abort on error -> install atomically. The output path is only ever written by
# an atomic rename, so a reader (including nftables.service mid-boot) sees
# either the previous projection or the new one, never a partial file.
#
# FAIL-CLOSED on a missing render authority. Substituting here instead would
# create exactly the duplicated firewall authority this lane exists to remove,
# and scripts/ci/check-firewall-projection-authority.sh P2 fails the build for it.
# -----------------------------------------------------------------------------
nftban_boot_projection_generate() {
    local schema="$1" out="$2"
    local out_dir tmp_render tmp_out rc

    if [[ ! -f "$schema" ]]; then
        echo "[NFTBan ERROR] boot projection: canonical schema not found: $schema" >&2
        return 1
    fi
    if ! declare -F _firewall_substitute_placeholders >/dev/null 2>&1; then
        echo "[NFTBan ERROR] boot projection: render authority _firewall_substitute_placeholders is NOT loaded." >&2
        echo "[NFTBan ERROR]   Source the firewall command file first. This function MUST NOT substitute" >&2
        echo "[NFTBan ERROR]   placeholders itself — a second substitution path is the duplicated firewall" >&2
        echo "[NFTBan ERROR]   authority P12-FPA exists to remove." >&2
        return 1
    fi

    out_dir="$(dirname "$out")"
    if [[ ! -d "$out_dir" ]]; then
        mkdir -p "$out_dir" || { echo "[NFTBan ERROR] boot projection: cannot create $out_dir" >&2; return 1; }
    fi
    [[ -w "$out_dir" ]] || { echo "[NFTBan ERROR] boot projection: not writable: $out_dir" >&2; return 1; }

    tmp_render=$(mktemp) || return 1
    tmp_out=$(mktemp "${out}.tmp.XXXXXX") || { rm -f "$tmp_render"; return 1; }
    # shellcheck disable=SC2064  # expand the paths now, on purpose
    trap "rm -f '$tmp_render' '$tmp_out'" RETURN

    # 1. render through the single substitution authority
    if ! _firewall_substitute_placeholders "$schema" "$tmp_render"; then
        echo "[NFTBan ERROR] boot projection: render failed — existing projection preserved" >&2
        return 1
    fi

    # 2. a partially rendered projection must never reach disk: nft would reject
    #    __CT_LIMIT_SSH__ at boot and the host would come up with no NFTBan table.
    local leftover
    leftover=$(grep -oE '__[A-Z0-9_]+__' "$tmp_render" | sort -u | tr '\n' ' ')
    if [[ -n "${leftover// /}" ]]; then
        echo "[NFTBan ERROR] boot projection: unrendered placeholders remain: ${leftover% }" >&2
        return 1
    fi

    # 3. header + rendered schema (the schema keeps its own #! line first)
    {
        head -1 "$tmp_render"
        nftban_boot_projection_header
        tail -n +2 "$tmp_render"
    } > "$tmp_out"

    # 4. validate BEFORE install
    nftban_boot_projection_validate "$tmp_out" "candidate boot projection"; rc=$?
    case "$rc" in
        0) : ;;
        2) echo "[NFTBan WARN] boot projection: installing a candidate that could not be validated here" >&2 ;;
        *) echo "[NFTBan ERROR] boot projection: candidate REJECTED — existing projection preserved" >&2; return 1 ;;
    esac

    # 5. atomic install
    chmod 0640 "$tmp_out" 2>/dev/null || true
    if ! mv -f "$tmp_out" "$out"; then
        echo "[NFTBan ERROR] boot projection: atomic install failed: $out" >&2
        return 1
    fi
    return 0
}
