#!/usr/bin/env bash
# =============================================================================
# NFTBan - PRO export profile (DATA-RELEASE AUTHORITY)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="nftban_export_profile_pro"
# meta:type="library"
# meta:version="1.229.11"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="PRO export profile: the deny-by-default allow-list deciding WHICH fields may leave this host for NFTBan PRO. It does not connect, retry, authenticate, batch, or know HTTP/TCP. It answers exactly one question: is this field permitted to leave? Transport is a separate authority and receives an already-approved payload with zero discretion to add fields."
# meta:input="nftban-validate --json (authoritative health document); VERSION; server_id"
# meta:output="approved field list / bounded JSON payload on stdout"
# meta:depends="bash,jq"
# meta:inventory.files="cli/lib/nftban/exporters/nftban_export_profile_pro.sh"
# meta:inventory.binaries="jq"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_DATA_DIR,NFTBAN_PRO_SERVER_ID_FILE"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network="none — this file performs NO network I/O"
# meta:inventory.privileges="none"
# =============================================================================
#
# ⛔ THIS FILE IS A DATA-RELEASE AUTHORITY, NOT AN EXPORTER.
#
#   It does not connect.        It does not retry.
#   It does not authenticate.   It does not know HTTP/TCP.
#
#   It only answers: "Is this field permitted to leave this host for NFTBan PRO?"
#
# The generic transport (a LATER release) then has ZERO discretion:
#
#   PROFILE     decides WHAT may leave
#   TRANSPORT   decides HOW it leaves — and CANNOT ADD FIELDS
#
# ⛔ DENY BY DEFAULT. A field not named in NFTBAN_PRO_PROFILE_FIELDS below does
#    not leave this host, however useful it might look.
#
#     NO METRIC REACHES CMS PRO UNLESS IT IS EXPLICITLY PRESENT HERE.
#     A PROFILE ENTRY WITHOUT A PRODUCER IS A CONTRACT FAILURE.
#
# Both directions are enforced by the guard, because an entry with no producer is
# a silent contract failure — the same declared-but-unconsumed class as
# DDOS_HYBRID_CLASSIC_LAYER0 and NFTBAN_PRO_REMOTE_WRITE_URL.
# =============================================================================

# =============================================================================
# WHY export_portal()'s 18 FIELDS WERE NOT ADOPTED
# =============================================================================
# nftban_unified_exporter_export.sh:430 builds an 18-field payload and never
# sends it (zero curl calls). Its field set was AUDITED, not inherited:
#
#   AN EXISTING FIELD SET IS A PROPOSAL, NOT A CONTRACT.
#
#   EXCLUDED — hardware/platform inventory with no PRO health purpose:
#     cpu_cores · cpu_model · memory_total_bytes · disk_total_bytes
#     server_type · vendor · model · os_name · os_release · kernel_version · arch
#
#   EXCLUDED — privacy-sensitive, and NOT required to state a health verdict:
#     serial_number   hardware serial — identifies the physical machine
#     mac_address     hardware address — a durable device identifier
#     networks        per-interface IP addresses
#     subnet_mask     network topology
#     location        operator-supplied site/premises information
#
#   RETAINED (1 of 18): nftban_version — needed to interpret schema and verdicts.
#
# ⛔ Excluded fields are NOT "rejected forever". Any of them may be added later
#    with an explicit product and privacy justification — which is exactly the
#    decision this allow-list forces someone to make, rather than inheriting.
# =============================================================================

# =============================================================================
# THE ALLOW-LIST
# =============================================================================
# Format: "<field>|<producer>"
#   producer  validator:<jq path>   from nftban-validate --json (authoritative)
#             local:<name>          resolved on-host by a named helper below
#
# Every producer here was verified live on lab2 (2026-08-25) against
# `nftban-validate --json`. PROVE THE PRODUCER, DO NOT ASSUME IT.
# =============================================================================
# Exported: the receiver needs to know which profile revision produced a payload,
# so a field-set change is detectable rather than silent.
export NFTBAN_PRO_PROFILE_VERSION="1"

NFTBAN_PRO_PROFILE_FIELDS=(
    # --- IDENTITY: which host is speaking -----------------------------------
    "server_id|local:server_id"
    "hostname|local:hostname"
    "nftban_version|local:nftban_version"

    # --- OBSERVATION: when this truth was established, and under which schema
    # observed_at is the OBSERVATION time, not the send time. It is DATA, never
    # an exposition-timestamp field.
    #   THE OBSERVATION TIME IS DATA, NOT METADATA.
    "schema_version|validator:.schema_version"
    "observed_at|validator:.timestamp"

    # --- HEALTH: the verdict, and whether it is PROVABLE ---------------------
    # consistency is the axis srv3 needed: the daemon was alive and enforcing
    # while the validator could not prove the effective mode.
    #   DAEMON ALIVE != PROTECTION PROVEN.
    "overall_status|validator:.status"
    "consistency_status|validator:.consistency.kernel_vs_validator"
    "service_state|validator:.service_state.nftband"

    # --- MODULES: per-module truth, not a collapsed boolean ------------------
    # config/structural/runtime/effective are distinct axes. A single "up" would
    # have reported green throughout the srv3 incident.
    "module_ddos_config|validator:.modules.ddos.config"
    "module_ddos_structural|validator:.modules.ddos.structural"
    # ⛔ ADDED BEFORE v1 WAS EVER CONSUMED. The validator produces
    # .modules.ddos.effective and this profile omitted it, while portscan and
    # loginmon both admit theirs. `effective` is the PROVABILITY axis — it is what
    # separates "configured and running" from "protection actually established",
    # which is precisely the distinction the srv3 incident turned on. Without it a
    # receiver could never compute DEGRADED for ddos, however clearly the host
    # said so.
    #   A VERSIONED CONTRACT IS CHEAPEST TO CORRECT BEFORE ANYTHING CONSUMES IT.
    # Nothing consumes it today: no transport in .11 by design, and no receiver
    # endpoint. Shipping v1 knowingly incomplete would force .12 either to mutate
    # v1's meaning silently or to publish v2 for a contract never used.
    # ⛔ ONLY the proven producer -> missing field. NOT botguard.runtime/effective,
    # NOT ddos.runtime, NOT portscan.runtime — no axis is admitted because
    # symmetry looks tidy. The lab proves botguard emits `config` ALONE.
    "module_ddos_effective|validator:.modules.ddos.effective"
    "module_portscan_config|validator:.modules.portscan.config"
    "module_portscan_structural|validator:.modules.portscan.structural"
    "module_portscan_effective|validator:.modules.portscan.effective"
    "module_loginmon_config|validator:.modules.loginmon.config"
    "module_loginmon_structural|validator:.modules.loginmon.structural"
    "module_loginmon_runtime|validator:.modules.loginmon.runtime"
    "module_loginmon_effective|validator:.modules.loginmon.effective"
    "module_botguard_config|validator:.modules.botguard.config"

    # --- PROTECTION: enforcement state, where authoritative ------------------
    "blacklist_manual_state|validator:.modules.blacklist.manual.state"
    "blacklist_manual_entries|validator:.modules.blacklist.manual.entries"
    "blacklist_feeds_state|validator:.modules.blacklist.feeds.state"
    "blacklist_geoban_state|validator:.modules.blacklist.geoban.state"
)

# nftban_pro_profile_fields — the permitted field names, one per line.
nftban_pro_profile_fields() {
    local e
    for e in "${NFTBAN_PRO_PROFILE_FIELDS[@]}"; do printf '%s\n' "${e%%|*}"; done
}

# nftban_pro_profile_producer <field> — the declared producer, or rc=1.
nftban_pro_profile_producer() {
    local want="$1" e
    for e in "${NFTBAN_PRO_PROFILE_FIELDS[@]}"; do
        [[ "${e%%|*}" == "$want" ]] && { printf '%s\n' "${e#*|}"; return 0; }
    done
    return 1
}

# nftban_pro_profile_permits <field> — rc=0 permitted, rc=1 denied.
#
#   DENY BY DEFAULT. An unknown field is denied, never passed through.
nftban_pro_profile_permits() {
    nftban_pro_profile_producer "$1" >/dev/null 2>&1
}

# _nftban_pro_local <name> — resolve a local:* producer. Unknown name -> rc=1,
# never a silent empty value.
#   AN UNRESOLVED PRODUCER IS AN ERROR, NOT AN EMPTY FIELD.
_nftban_pro_local() {
    case "$1" in
        server_id)
            local f="${NFTBAN_PRO_SERVER_ID_FILE:-/etc/nftban/server_id}"
            [[ -r "$f" ]] || return 1
            tr -d '\n' < "$f"
            ;;
        hostname)       hostname -f 2>/dev/null || hostname ;;
        nftban_version) cat "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/VERSION" 2>/dev/null | head -1 ;;
        *) return 1 ;;
    esac
}

# nftban_pro_profile_build [validator_json] — emit the APPROVED payload as JSON.
#
# ⛔ Emits ONLY fields in the allow-list. There is no passthrough, no merge with
#    an external document, and no "extra fields" parameter — by construction a
#    caller cannot widen the export surface.
#
# A field whose producer yields nothing is emitted as null, NOT omitted: the
# receiver must be able to distinguish "we could not observe this" from "this
# host does not report it".
#   ABSENT != UNKNOWN.
nftban_pro_profile_build() {
    local vjson="${1:-}"
    command -v jq >/dev/null 2>&1 || { echo "nftban_pro_profile_build: jq required" >&2; return 1; }

    if [[ -z "$vjson" ]]; then
        local vbin="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/bin/nftban-validate"
        [[ -x "$vbin" ]] || { echo "nftban_pro_profile_build: validator not executable: $vbin" >&2; return 1; }
        # A validator failure is NOT an empty document — fail loudly.
        vjson="$("$vbin" --json 2>/dev/null)" || true
        [[ -n "$vjson" ]] || { echo "nftban_pro_profile_build: validator produced no document" >&2; return 1; }
    fi

    local out="{" first=1 e field producer val
    for e in "${NFTBAN_PRO_PROFILE_FIELDS[@]}"; do
        field="${e%%|*}"; producer="${e#*|}"
        case "$producer" in
            validator:*) val="$(jq -r "${producer#validator:} // empty" <<<"$vjson" 2>/dev/null)" ;;
            local:*)     val="$(_nftban_pro_local "${producer#local:}" 2>/dev/null)" || val="" ;;
            *)           echo "nftban_pro_profile_build: unknown producer kind for $field" >&2; return 1 ;;
        esac
        [[ "$first" -eq 1 ]] && first=0 || out+=","
        if [[ -z "$val" ]]; then
            out+="\"${field}\":null"
        else
            out+="\"${field}\":$(jq -Rn --arg v "$val" '$v')"
        fi
    done
    out+="}"
    printf '%s\n' "$out"
}

export -f nftban_pro_profile_fields nftban_pro_profile_producer \
           nftban_pro_profile_permits nftban_pro_profile_build 2>/dev/null || true
