#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.52.0 - Config Doctor — System Integrity Audit
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Full config+kernel+runtime integrity audit
#
# meta:name="nftban_config_doctor"
# meta:type="core"
# meta:header="Config Doctor — System Integrity Audit"
# meta:version="1.52.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Full system integrity audit: config<>kernel<>runtime alignment, module wiring, override health"
# meta:inventory.files=""
# meta:inventory.binaries="nft,ss,jq,systemctl"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="user"
#
# meta:created_date="2026-03-28"
# meta:updated_date="2026-03-28"
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${NFTBAN_CONFIG_DOCTOR_LOADED:-}" ]] && return 0
readonly NFTBAN_CONFIG_DOCTOR_LOADED=1

# =============================================================================
# DEPENDENCIES
# =============================================================================

: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"
: "${NFTBAN_CONFIG_DIR:=/etc/nftban}"

# Load nft_schema for table/set/chain constants
if [[ -f "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" || true
fi

# Load firewall_conflicts for ghost/authority checks
if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_firewall_conflicts.sh" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR}/core/nftban_firewall_conflicts.sh" || true
fi

# =============================================================================
# CONSTANTS
# =============================================================================

# Canonical security-sensitive key list — shared definition to prevent drift
readonly -a _DOCTOR_SECURITY_KEYS=(
    TCP_PORTS_IN UDP_PORTS_IN SSH_PORT
    NFTBAN_DDOS_ENABLED NFTBAN_DDOS_SYNPROXY_ENABLED
    DDOS_SYN_RATE DDOS_CONN_LIMIT_SSH DDOS_CONN_LIMIT_HTTP DDOS_CONN_LIMIT_MAIL
    NFTBAN_PORTSCAN_ENABLED PORTSCAN_BAN_THRESHOLD
    NFTBAN_LOGIN_MONITOR_ENABLED LOGIN_BAN_THRESHOLD LOGIN_BAN_DURATION
    HTTP_BOTGUARD_ENABLED
    NFTBAN_FEEDS_ENABLED
    GEOBAN_ENABLED
    NFTBAN_SURICATA_ENABLED
    NFTBAN_GEOIP_ENABLED
    SYNPROXY_ENABLED
)

# Module definitions: name -> enable_key|chain_artifacts|set_artifacts
declare -g -A _DOCTOR_MODULES=(
    ["portscan"]="NFTBAN_PORTSCAN_ENABLED|portscan_detection|"
    ["ddos"]="NFTBAN_DDOS_ENABLED|ddos_protection|"
    ["botguard"]="HTTP_BOTGUARD_ENABLED|http_bot_guard|http_bot_suspect"
    ["login"]="NFTBAN_LOGIN_MONITOR_ENABLED||"
    ["feeds"]="NFTBAN_FEEDS_ENABLED||blacklist_ipv4"
    ["geoip"]="NFTBAN_GEOIP_ENABLED||"
    ["geoban"]="GEOBAN_ENABLED||"
    ["suricata"]="NFTBAN_SURICATA_ENABLED||"
    ["synproxy"]="NFTBAN_DDOS_SYNPROXY_ENABLED||"
)

# Severity constants
readonly _SEV_OK="ok"
readonly _SEV_INFO="info"
readonly _SEV_WARN="warning"
readonly _SEV_ERR="error"

# =============================================================================
# GATHER DATA (single-pass, <500ms)
# =============================================================================

# Global data cache — populated once by _doctor_gather_data()
declare -g _DOCTOR_NFT_JSON=""
declare -g _DOCTOR_NFT_TABLES=""
declare -g _DOCTOR_SS_OUTPUT=""
declare -g _DOCTOR_EFFECTIVE_CONFIG=""
declare -g _DOCTOR_SYSTEMD_UNITS=""

_doctor_gather_data() {
    # Gather all system state in a single pass
    _DOCTOR_NFT_JSON=$(nft -j list ruleset 2>/dev/null || echo '{"nftables":[]}')
    _DOCTOR_NFT_TABLES=$(nft list tables 2>/dev/null || echo "")
    _DOCTOR_SS_OUTPUT=$(ss -tunlpH 2>/dev/null || echo "")
    _DOCTOR_EFFECTIVE_CONFIG=$(nftban_config_load_effective 2>/dev/null || echo "{}")
    _DOCTOR_SYSTEMD_UNITS=$(systemctl list-units --type=service --no-pager --plain 2>/dev/null || echo "")
}

# =============================================================================
# HELPER: Config value lookup
# =============================================================================

_doctor_config_val() {
    # Get effective config value for a key
    local key="$1"
    echo "$_DOCTOR_EFFECTIVE_CONFIG" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null
}

_doctor_config_bool() {
    # Get boolean config value (true/false/1/0/yes/no → 0=true/1=false)
    local val
    val=$(_doctor_config_val "$1")
    case "${val,,}" in
        true|1|yes|on) return 0 ;;
        *) return 1 ;;
    esac
}

# =============================================================================
# HELPER: NFT queries against cached JSON
# =============================================================================

_doctor_nft_table_exists() {
    # Check if table exists: family tablename
    local family="$1" table="$2"
    echo "$_DOCTOR_NFT_TABLES" | grep -q "^table ${family} ${table}$"
}

_doctor_nft_chain_exists() {
    # Check if chain exists in nftban table (any family)
    local chain="$1" family="${2:-}"
    if [[ -n "$family" ]]; then
        echo "$_DOCTOR_NFT_JSON" | jq -e --arg c "$chain" --arg f "$family" '
            .nftables[] | select(.chain?) | .chain |
            select(.name == $c and .table == "nftban" and .family == $f)
        ' >/dev/null 2>&1
    else
        echo "$_DOCTOR_NFT_JSON" | jq -e --arg c "$chain" '
            .nftables[] | select(.chain?) | .chain |
            select(.name == $c and .table == "nftban")
        ' >/dev/null 2>&1
    fi
}

_doctor_nft_chain_has_jump() {
    # Check if input chain has a jump to the specified chain
    local target="$1"
    echo "$_DOCTOR_NFT_JSON" | jq -e --arg t "$target" '
        [.nftables[] | select(.rule?) | .rule |
         select(.chain == "input" and .table == "nftban") |
         .expr[]? | select(.jump?) | .jump.target] |
        any(. == $t)
    ' >/dev/null 2>&1
}

_doctor_nft_set_elements() {
    # Count elements in an nft set from cached JSON
    local set_name="$1"
    echo "$_DOCTOR_NFT_JSON" | jq --arg s "$set_name" '
        [.nftables[] | select(.set?) | .set |
         select(.name == $s and .table == "nftban") |
         .elem // [] | length] | add // 0
    ' 2>/dev/null
}

_doctor_nft_set_exists() {
    # Check if a set exists
    local set_name="$1"
    echo "$_DOCTOR_NFT_JSON" | jq -e --arg s "$set_name" '
        .nftables[] | select(.set?) | .set |
        select(.name == $s and .table == "nftban")
    ' >/dev/null 2>&1
}

_doctor_nft_port_set_values() {
    # Get port values from an nft set as comma-separated list
    local set_name="$1"
    echo "$_DOCTOR_NFT_JSON" | jq -r --arg s "$set_name" '
        [.nftables[] | select(.set?) | .set |
         select(.name == $s and .table == "nftban") |
         .elem[]? | if type == "object" then .val // . else . end |
         if type == "number" then . else empty end] | sort | map(tostring) | join(",")
    ' 2>/dev/null
}

_doctor_nft_counter_count() {
    # Count named counters in ip nftban
    echo "$_DOCTOR_NFT_JSON" | jq '
        [.nftables[] | select(.counter?) | .counter |
         select(.table == "nftban")] | length
    ' 2>/dev/null
}

# =============================================================================
# FINDINGS ACCUMULATOR
# =============================================================================

declare -g -a _DOCTOR_FINDINGS=()
declare -g _DOCTOR_COUNTS_OK=0
declare -g _DOCTOR_COUNTS_INFO=0
declare -g _DOCTOR_COUNTS_WARN=0
declare -g _DOCTOR_COUNTS_ERR=0

_doctor_finding() {
    # Record a finding: severity type message source [module] [extra_json_fields]
    local severity="$1" type="$2" message="$3" source="$4"
    local module="${5:-}" extra="${6:-}"

    local json
    json=$(jq -nc \
        --arg sev "$severity" \
        --arg typ "$type" \
        --arg msg "$message" \
        --arg src "$source" \
        --arg mod "$module" \
        '{severity: $sev, type: $typ, message: $msg, source: $src} +
         (if $mod != "" then {module: $mod} else {} end)')

    # Merge extra fields if provided
    if [[ -n "$extra" ]]; then
        json=$(echo "$json" "$extra" | jq -s '.[0] * .[1]' 2>/dev/null || echo "$json")
    fi

    _DOCTOR_FINDINGS+=("$json")

    case "$severity" in
        ok)      ((_DOCTOR_COUNTS_OK++)) || true ;;
        info)    ((_DOCTOR_COUNTS_INFO++)) || true ;;
        warning) ((_DOCTOR_COUNTS_WARN++)) || true ;;
        error)   ((_DOCTOR_COUNTS_ERR++)) || true ;;
    esac
}

_doctor_overall_status() {
    if [[ $_DOCTOR_COUNTS_ERR -gt 0 ]]; then echo "error"
    elif [[ $_DOCTOR_COUNTS_WARN -gt 0 ]]; then echo "warning"
    elif [[ $_DOCTOR_COUNTS_INFO -gt 0 ]]; then echo "info"
    else echo "ok"
    fi
}

# =============================================================================
# STEP 2: CORE INTEGRITY
# =============================================================================

_doctor_core_integrity() {
    local section_status="$_SEV_OK"

    # --- Tables ---
    local ipv4_ok=false
    # shellcheck disable=SC2034  # Reserved for future IPv6 parallel validation
    local ipv6_ok=false
    if _doctor_nft_table_exists "ip" "nftban"; then
        ipv4_ok=true
        _doctor_finding "$_SEV_OK" "table_present" "Table ip nftban exists" "nft"
    else
        section_status="$_SEV_ERR"
        _doctor_finding "$_SEV_ERR" "table_missing" "Table ip nftban MISSING" "nft"
    fi
    if _doctor_nft_table_exists "ip6" "nftban"; then
        # shellcheck disable=SC2034
        ipv6_ok=true
        _doctor_finding "$_SEV_OK" "table_present" "Table ip6 nftban exists" "nft"
    else
        section_status="$_SEV_ERR"
        _doctor_finding "$_SEV_ERR" "table_missing" "Table ip6 nftban MISSING" "nft"
    fi

    # --- Chains (IPv4) ---
    if [[ "$ipv4_ok" == "true" ]]; then
        for chain in input forward output; do
            if _doctor_nft_chain_exists "$chain" "ip"; then
                _doctor_finding "$_SEV_OK" "chain_present" "Chain $chain exists in ip nftban" "nft"
            else
                section_status="$_SEV_ERR"
                _doctor_finding "$_SEV_ERR" "chain_missing" "Chain $chain MISSING in ip nftban" "nft"
            fi
        done
    fi

    # --- Chains (IPv6) ---
    if [[ "$ipv6_ok" == "true" ]]; then
        for chain in input forward output; do
            if _doctor_nft_chain_exists "$chain" "ip6"; then
                _doctor_finding "$_SEV_OK" "chain_present" "Chain $chain exists in ip6 nftban" "nft"
            else
                section_status="$_SEV_ERR"
                _doctor_finding "$_SEV_ERR" "chain_missing" "Chain $chain MISSING in ip6 nftban" "nft"
            fi
        done
    fi

    # --- Sets (IPv4) ---
    local expected_v4=0
    declare -p NFTBAN_IPV4_SETS &>/dev/null && expected_v4=${#NFTBAN_IPV4_SETS[@]}
    local present_v4=0
    if [[ "$ipv4_ok" == "true" ]]; then
        for set_name in "${!NFTBAN_IPV4_SETS[@]}"; do
            if _doctor_nft_set_exists "$set_name"; then
                ((present_v4++)) || true
            fi
        done
    fi
    if [[ $present_v4 -eq $expected_v4 ]] && [[ $expected_v4 -gt 0 ]]; then
        _doctor_finding "$_SEV_OK" "sets_complete" "All $expected_v4 IPv4 sets present" "nft"
    else
        section_status="$_SEV_ERR"
        _doctor_finding "$_SEV_ERR" "sets_incomplete" "$present_v4 of $expected_v4 IPv4 sets present" "nft"
    fi

    # --- Sets (IPv6) ---
    local expected_v6=0
    declare -p NFTBAN_IPV6_SETS &>/dev/null && expected_v6=${#NFTBAN_IPV6_SETS[@]}
    local present_v6=0
    if [[ "$ipv6_ok" == "true" ]]; then
        for set_name in "${!NFTBAN_IPV6_SETS[@]}"; do
            if _doctor_nft_set_exists "$set_name"; then
                ((present_v6++)) || true
            fi
        done
    fi
    if [[ $present_v6 -eq $expected_v6 ]] && [[ $expected_v6 -gt 0 ]]; then
        _doctor_finding "$_SEV_OK" "sets_complete" "All $expected_v6 IPv6 sets present" "nft"
    else
        section_status="$_SEV_ERR"
        _doctor_finding "$_SEV_ERR" "sets_incomplete" "$present_v6 of $expected_v6 IPv6 sets present" "nft"
    fi

    # --- Named Counters ---
    local counter_count
    counter_count=$(_doctor_nft_counter_count)
    if [[ "$counter_count" -ge 22 ]]; then
        _doctor_finding "$_SEV_OK" "counters_present" "$counter_count named counters present" "nft"
    elif [[ "$counter_count" -gt 0 ]]; then
        [[ "$section_status" != "$_SEV_ERR" ]] && section_status="$_SEV_WARN"
        _doctor_finding "$_SEV_WARN" "counters_partial" "$counter_count of 22 expected named counters present" "nft"
    else
        _doctor_finding "$_SEV_INFO" "counters_absent" "No named counters (anonymous counters in use)" "nft"
    fi

    # --- Hook Authority ---
    local foreign_tables=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local tspec="${line#table }"
        case "$tspec" in
            "ip nftban"|"ip6 nftban"|"ip raw"|"ip6 raw") continue ;;
        esac
        foreign_tables+=("$tspec")
    done <<< "$_DOCTOR_NFT_TABLES"

    if [[ ${#foreign_tables[@]} -eq 0 ]]; then
        _doctor_finding "$_SEV_OK" "hook_authority" "NFTBan has sole firewall authority" "nft"
    else
        [[ "$section_status" != "$_SEV_ERR" ]] && section_status="$_SEV_WARN"
        for ft in "${foreign_tables[@]}"; do
            _doctor_finding "$_SEV_WARN" "foreign_table" "Non-NFTBan table: $ft" "nft"
        done
    fi

    # --- Ghost Tables ---
    local ghost_found=false
    if [[ -n "${NFTBAN_DEPRECATED_TABLES+x}" ]]; then
        for deprecated_table in "${!NFTBAN_DEPRECATED_TABLES[@]}"; do
            if echo "$_DOCTOR_NFT_TABLES" | grep -q "^table ${deprecated_table}$"; then
                ghost_found=true
                [[ "$section_status" != "$_SEV_ERR" ]] && section_status="$_SEV_WARN"
                _doctor_finding "$_SEV_WARN" "ghost_table" "Legacy ghost table: $deprecated_table" "nft"
            fi
        done
    fi
    if [[ "$ghost_found" == "false" ]]; then
        _doctor_finding "$_SEV_OK" "no_ghosts" "No ghost/legacy tables" "nft"
    fi

    echo "$section_status"
}

# =============================================================================
# STEP 3: OVERRIDE ANALYSIS
# =============================================================================

# Override accumulator arrays (JSON strings)
declare -g -a _DOCTOR_OVR_ACTIVE=()
declare -g -a _DOCTOR_OVR_DEAD=()
declare -g -a _DOCTOR_OVR_STALE=()
declare -g -a _DOCTOR_OVR_UNAPPLIED=()

_doctor_is_security_key() {
    local key="$1"
    local k
    for k in "${_DOCTOR_SECURITY_KEYS[@]}"; do
        [[ "$key" == "$k" ]] && return 0
    done
    return 1
}

_doctor_override_analysis() {
    local config_dir="$NFTBAN_CONFIG_DIR"

    # Process all .conf.local files
    local local_files=()
    [[ -f "$config_dir/nftban.conf.local" ]] && local_files+=("$config_dir/nftban.conf.local")
    for f in "$config_dir"/conf.d/*.conf.local "$config_dir"/conf.d/*/*.conf.local; do
        [[ -f "$f" ]] && local_files+=("$f")
    done

    for local_file in "${local_files[@]}"; do
        local base_file="${local_file%.local}"
        local local_json defaults_json
        local_json=$(nftban_config_parse_to_json "$local_file" 2>/dev/null || echo "{}")
        defaults_json=$(nftban_config_parse_to_json "$base_file" 2>/dev/null || echo "{}")

        local keys
        keys=$(echo "$local_json" | jq -r 'keys[]' 2>/dev/null) || continue

        while IFS= read -r key; do
            [[ -z "$key" ]] && continue
            local local_val default_val
            local_val=$(echo "$local_json" | jq -r --arg k "$key" '.[$k]')
            default_val=$(echo "$defaults_json" | jq -r --arg k "$key" '.[$k] // "__MISSING__"')

            local is_sec=false
            _doctor_is_security_key "$key" && is_sec=true

            if [[ "$default_val" == "__MISSING__" ]]; then
                # Dead: key not in base config
                _DOCTOR_OVR_DEAD+=("$(jq -nc --arg k "$key" --arg f "$local_file" --arg v "$local_val" \
                    '{key: $k, file: $f, value: $v, source: "config.local"}')")
                _doctor_finding "$_SEV_WARN" "override_dead" "Dead override: $key (not in schema)" "config.local"
            elif [[ "$local_val" == "$default_val" ]]; then
                # Stale: override = default (redundant)
                _DOCTOR_OVR_STALE+=("$(jq -nc --arg k "$key" --arg f "$local_file" --arg v "$local_val" \
                    '{key: $k, file: $f, value: $v, source: "config.local"}')")
                _doctor_finding "$_SEV_INFO" "override_stale" "Stale override: $key=$local_val (same as default)" "config.local"
            else
                # Active override
                _DOCTOR_OVR_ACTIVE+=("$(jq -nc --arg k "$key" --arg f "$local_file" \
                    --arg d "$default_val" --arg o "$local_val" --argjson sec "$is_sec" \
                    '{key: $k, file: $f, default: $d, override: $o, source: "config.local", security_sensitive: $sec}')")
                if [[ "$is_sec" == "true" ]]; then
                    _doctor_finding "$_SEV_INFO" "override_security" "Security-sensitive override: $key=$local_val (default: $default_val)" "config.local"
                fi
            fi
        done <<< "$keys"
    done
}

# =============================================================================
# STEP 3b: GLOBAL DRIFT (config vs kernel port comparison)
# =============================================================================

_doctor_global_drift() {
    # Compare config port sets with kernel port sets
    local config_tcp_in config_ssh_port
    config_tcp_in=$(_doctor_config_val "TCP_PORTS_IN")
    config_ssh_port=$(_doctor_config_val "SSH_PORT")

    # Get kernel TCP ports
    local kernel_tcp_in
    kernel_tcp_in=$(_doctor_nft_port_set_values "tcp_ports_in")

    if [[ -n "$config_tcp_in" && -n "$kernel_tcp_in" ]]; then
        # Normalize: sort both, compare
        local config_sorted kernel_sorted
        config_sorted=$(echo "$config_tcp_in" | tr ',' '\n' | sort -n | tr '\n' ',' | sed 's/,$//')
        kernel_sorted=$(echo "$kernel_tcp_in" | tr ',' '\n' | sort -n | tr '\n' ',' | sed 's/,$//')

        if [[ "$config_sorted" != "$kernel_sorted" ]]; then
            _doctor_finding "$_SEV_WARN" "drift_tcp_ports" \
                "TCP_PORTS_IN drift: config=$config_sorted kernel=$kernel_sorted" "nft" "" \
                "$(jq -nc --arg cv "$config_sorted" --arg kv "$kernel_sorted" '{config_value: $cv, kernel_value: $kv}')"
        else
            _doctor_finding "$_SEV_OK" "tcp_ports_synced" "TCP_PORTS_IN: config matches kernel" "nft"
        fi
    fi

    # SSH port check
    if [[ -n "$config_ssh_port" ]]; then
        # Check if SSH port is in the kernel TCP port set
        if [[ -n "$kernel_tcp_in" ]]; then
            if ! echo ",$kernel_tcp_in," | grep -q ",${config_ssh_port},"; then
                _doctor_finding "$_SEV_ERR" "ssh_port_not_allowed" \
                    "SSH_PORT=$config_ssh_port is NOT in kernel tcp_ports_in ($kernel_tcp_in)" "nft" "" \
                    "$(jq -nc --arg p "$config_ssh_port" '{port: $p}')"
            fi
        fi
    fi

    # Check for unapplied module enables (config says enabled but no kernel artifacts)
    for mod_name in "${!_DOCTOR_MODULES[@]}"; do
        local mod_def="${_DOCTOR_MODULES[$mod_name]}"
        local enable_key chain_artifact
        IFS='|' read -r enable_key chain_artifact _ <<< "$mod_def"

        [[ -z "$enable_key" ]] && continue
        [[ -z "$chain_artifact" ]] && continue

        local config_enabled=false
        _doctor_config_bool "$enable_key" && config_enabled=true

        local kernel_present=false
        _doctor_nft_chain_exists "$chain_artifact" && kernel_present=true

        if [[ "$config_enabled" == "true" && "$kernel_present" == "false" ]]; then
            _DOCTOR_OVR_UNAPPLIED+=("$(jq -nc --arg k "$enable_key" --arg m "$mod_name" \
                '{key: $k, module: $m, config_value: "true", kernel_value: "chain missing", source: "config.local", kernel_source: "nft"}')")
            _doctor_finding "$_SEV_WARN" "drift_module_unapplied" \
                "$mod_name: enabled in config but $chain_artifact chain missing (needs rebuild)" "config.local" "$mod_name"
        fi
    done
}

# =============================================================================
# STEP 4: PER-MODULE AUDIT (L1-L4)
# =============================================================================

# Module results accumulator: module -> JSON object
declare -g -A _DOCTOR_MODULE_RESULTS=()

_doctor_module_audit() {
    # Audit a single module through L1 (enabled) → L2 (materialized) → L3 (referenced)
    local mod_name="$1"
    local mod_def="${_DOCTOR_MODULES[$mod_name]}"
    local enable_key chain_artifact set_artifact
    IFS='|' read -r enable_key chain_artifact set_artifact <<< "$mod_def"

    local mod_status="$_SEV_OK"
    local l1_enabled=false l2_materialized=false l3_referenced=false
    local l1_source="config" l2_source="nft" l3_source="nft"
    local state_label="" l2_artifacts="" l3_rules=""

    # --- L1: Enabled in config? ---
    if [[ -n "$enable_key" ]]; then
        _doctor_config_bool "$enable_key" && l1_enabled=true
    fi

    # --- L2: Kernel artifacts exist? ---
    if [[ -n "$chain_artifact" ]]; then
        _doctor_nft_chain_exists "$chain_artifact" && l2_materialized=true
        l2_artifacts="chain:$chain_artifact"
    elif [[ -n "$set_artifact" ]]; then
        # Module uses sets instead of chains (feeds, geoban)
        local elem_count
        elem_count=$(_doctor_nft_set_elements "$set_artifact")
        if [[ "${elem_count:-0}" -gt 0 ]]; then
            l2_materialized=true
            l2_artifacts="set:$set_artifact(${elem_count} elements)"
        fi
    else
        # Module without kernel artifacts (login, geoip, suricata) — check service
        case "$mod_name" in
            login)
                if echo "$_DOCTOR_SYSTEMD_UNITS" | grep -q "nftband.service.*running"; then
                    l2_materialized=true
                    l2_artifacts="service:nftband"
                fi
                ;;
            geoip)
                local geoip_dir="${NFTBAN_DATA_DIR:-/var/lib/nftban}/geoip"
                for db_file in "dbip-country-lite.mmdb" "GeoLite2-City.mmdb" "GeoLite2-Country.mmdb"; do
                    if [[ -f "${geoip_dir}/${db_file}" ]]; then
                        l2_materialized=true
                        l2_artifacts="file:${db_file}"
                        break
                    fi
                done
                ;;
            suricata)
                if echo "$_DOCTOR_SYSTEMD_UNITS" | grep -q "suricata.service.*running"; then
                    l2_materialized=true
                    l2_artifacts="service:suricata"
                fi
                ;;
            synproxy)
                if _doctor_nft_table_exists "ip" "raw"; then
                    l2_materialized=true
                    l2_artifacts="table:ip raw"
                fi
                ;;
        esac
    fi

    # --- L3: Referenced in active rule path? ---
    if [[ -n "$chain_artifact" ]]; then
        _doctor_nft_chain_has_jump "$chain_artifact" && l3_referenced=true
        l3_rules="input→$chain_artifact"
    elif [[ "$mod_name" == "feeds" || "$mod_name" == "geoban" ]]; then
        # Feed/geoban data lives in blacklist set which is always referenced
        l3_referenced=$l2_materialized
        l3_rules="input→blacklist check"
    else
        # Non-chain modules: L3 = L2 (if materialized, considered referenced)
        l3_referenced=$l2_materialized
    fi

    # --- L4: Effective Targeting (v1.52.0) ---
    # Only check L4 if module is ACTIVE (L1+L2+L3 all true)
    local l4_effective=true l4_detail="" l4_source="nft+config"
    if [[ "$l1_enabled" == "true" && "$l2_materialized" == "true" && "$l3_referenced" == "true" ]]; then
        case "$mod_name" in
            login)
                # SSH port config↔kernel match
                local _cfg_ssh_port _kernel_ssh_ports
                _cfg_ssh_port=$(_doctor_config_val "SSH_PORT")
                [[ -z "$_cfg_ssh_port" ]] && _cfg_ssh_port="22"
                _kernel_ssh_ports=$(_doctor_nft_port_set_values "tcp_ports_in")
                if [[ -n "$_kernel_ssh_ports" ]] && ! echo ",$_kernel_ssh_ports," | grep -q ",$_cfg_ssh_port,"; then
                    l4_effective=false
                    l4_detail="SSH port $_cfg_ssh_port not in kernel tcp_ports_in ($_kernel_ssh_ports)"
                    _doctor_finding "$_SEV_WARN" "module_l4_ssh_mismatch" \
                        "$mod_name: SSH port $_cfg_ssh_port not in firewall port set — login bans may not protect SSH" "nft+config" "$mod_name"
                else
                    l4_detail="Protecting SSH on port $_cfg_ssh_port"
                fi
                ;;
            portscan)
                # Open port count vs detection effectiveness
                local _tcp_open _port_count
                _tcp_open=$(_doctor_nft_port_set_values "tcp_ports_in")
                _port_count=$(echo "$_tcp_open" | tr ',' '\n' | grep -c '[0-9]' 2>/dev/null || echo "0")
                if (( _port_count > 20 )); then
                    l4_detail="$_port_count open ports — portscan detection effectiveness reduced (INFO)"
                    _doctor_finding "$_SEV_INFO" "module_l4_many_ports" \
                        "$mod_name: $_port_count open ports — portscan detection less effective with many open ports" "nft" "$mod_name"
                else
                    l4_detail="$_port_count open ports — effective detection range"
                fi
                ;;
            botguard)
                # HTTP port in tcp_ports_in check
                local _tcp_ports
                _tcp_ports=$(_doctor_nft_port_set_values "tcp_ports_in")
                local _has_http=false
                echo ",$_tcp_ports," | grep -q ",80," && _has_http=true
                echo ",$_tcp_ports," | grep -q ",443," && _has_http=true
                echo ",$_tcp_ports," | grep -q ",8080," && _has_http=true
                echo ",$_tcp_ports," | grep -q ",8443," && _has_http=true
                if [[ "$_has_http" == "false" ]]; then
                    l4_effective=false
                    l4_detail="No HTTP/HTTPS port in tcp_ports_in — BotGuard has no target"
                    _doctor_finding "$_SEV_WARN" "module_l4_no_http_target" \
                        "$mod_name: No HTTP/HTTPS port (80/443/8080/8443) in firewall — BotGuard cannot protect anything" "nft" "$mod_name"
                else
                    l4_detail="HTTP traffic is being inspected"
                fi
                ;;
            ddos)
                # Jump ordering: DDoS must be before tcp_ports_in accept
                local _jump_order
                _jump_order=$(echo "$_DOCTOR_NFT_JSON" | jq -r '
                    [.nftables[] | select(.rule?) | .rule |
                     select(.chain == "input" and .table == "nftban") |
                     .expr[]? |
                     if .jump? then .jump.target
                     elif .match? then
                       if (.match.right? | type) == "string" and (.match.right? | test("@tcp_ports_in")) then "@tcp_ports_in"
                       else empty end
                     else empty end] | join(",")
                ' 2>/dev/null || echo "")
                # Check if ddos_protection appears before @tcp_ports_in in the rule chain
                local _ddos_pos _ports_pos
                _ddos_pos=$(echo ",$_jump_order" | grep -ob 'ddos_protection' | head -1 | cut -d: -f1)
                _ports_pos=$(echo ",$_jump_order" | grep -ob '@tcp_ports_in' | head -1 | cut -d: -f1)
                if [[ -n "$_ddos_pos" && -n "$_ports_pos" ]] && (( _ddos_pos > _ports_pos )); then
                    l4_effective=false
                    l4_detail="DDoS jump is AFTER tcp_ports_in accept — traffic bypasses DDoS checks"
                    _doctor_finding "$_SEV_ERR" "module_l4_ddos_ordering" \
                        "$mod_name: DDoS protection chain is inserted AFTER port accept — ineffective (FIX-A regression)" "nft" "$mod_name"
                else
                    l4_detail="DDoS chain correctly ordered before port accept"
                fi
                ;;
            synproxy)
                # SSH port must NOT be in SYNPROXY config (breaks SSH conntrack)
                local _synproxy_conf="/etc/nftban/conf.d/ddos/synproxy.conf"
                local _synproxy_local="${_synproxy_conf}.local"
                local _synproxy_ports=""
                [[ -f "$_synproxy_conf" ]] && _synproxy_ports=$(grep -m1 'SYNPROXY_PORTS=' "$_synproxy_conf" 2>/dev/null | cut -d= -f2 | tr -d '"' || true)
                [[ -f "$_synproxy_local" ]] && _synproxy_ports=$(grep -m1 'SYNPROXY_PORTS=' "$_synproxy_local" 2>/dev/null | cut -d= -f2 | tr -d '"' || true)
                local _cfg_ssh
                _cfg_ssh=$(_doctor_config_val "SSH_PORT")
                [[ -z "$_cfg_ssh" ]] && _cfg_ssh="22"
                if [[ -n "$_synproxy_ports" ]] && echo ",$_synproxy_ports," | grep -q ",$_cfg_ssh,"; then
                    l4_effective=false
                    l4_detail="SSH port $_cfg_ssh is in SYNPROXY target — breaks SSH conntrack"
                    _doctor_finding "$_SEV_ERR" "module_l4_synproxy_ssh" \
                        "$mod_name: SSH port $_cfg_ssh in SYNPROXY config — this breaks SSH connection tracking (MISCONFIGURED)" "config" "$mod_name"
                else
                    l4_detail="SSH port excluded from SYNPROXY — correct"
                fi
                ;;
            *)
                l4_detail=""
                ;;
        esac
    fi

    # --- State Matrix ---
    if [[ "$l1_enabled" == "true" ]]; then
        if [[ "$l2_materialized" == "true" ]]; then
            if [[ "$l3_referenced" == "true" ]]; then
                if [[ "$l4_effective" == "true" ]]; then
                    state_label="EFFECTIVE"
                    _doctor_finding "$_SEV_OK" "module_effective" "$mod_name: EFFECTIVE (L1-L4 all pass)" "nft+config" "$mod_name"
                else
                    state_label="MISCONFIGURED"
                    mod_status="$_SEV_WARN"
                    _doctor_finding "$_SEV_WARN" "module_misconfigured" "$mod_name: MISCONFIGURED (active but targeting issue)" "nft+config" "$mod_name"
                fi
            else
                state_label="UNWIRED"
                mod_status="$_SEV_WARN"
                _doctor_finding "$_SEV_WARN" "module_unwired" "$mod_name: UNWIRED (artifacts exist but not in rule path)" "nft" "$mod_name"
            fi
        else
            state_label="MISSING"
            mod_status="$_SEV_ERR"
            _doctor_finding "$_SEV_ERR" "module_missing" "$mod_name: MISSING (enabled but no kernel artifacts — needs rebuild)" "nft" "$mod_name"
        fi
    else
        if [[ "$l2_materialized" == "true" ]]; then
            if [[ "$l3_referenced" == "true" ]]; then
                state_label="ORPHAN-ACTIVE"
                mod_status="$_SEV_WARN"
                _doctor_finding "$_SEV_WARN" "module_orphan_active" "$mod_name: ORPHAN-ACTIVE (disabled but still active in kernel)" "nft" "$mod_name"
            else
                state_label="ORPHAN"
                mod_status="$_SEV_INFO"
                _doctor_finding "$_SEV_INFO" "module_orphan" "$mod_name: ORPHAN (disabled, artifacts remain but unreferenced)" "nft" "$mod_name"
            fi
        else
            state_label="DISABLED"
            _doctor_finding "$_SEV_OK" "module_disabled" "$mod_name: DISABLED" "config" "$mod_name"
        fi
    fi

    # Build module result JSON
    _DOCTOR_MODULE_RESULTS["$mod_name"]=$(jq -nc \
        --arg status "$mod_status" \
        --arg state "$state_label" \
        --argjson l1_val "$l1_enabled" \
        --arg l1_src "$l1_source" \
        --arg l1_key "${enable_key:-}" \
        --argjson l2_val "$l2_materialized" \
        --arg l2_src "$l2_source" \
        --arg l2_art "$l2_artifacts" \
        --argjson l3_val "$l3_referenced" \
        --arg l3_src "$l3_source" \
        --arg l3_rules "$l3_rules" \
        --argjson l4_val "$l4_effective" \
        --arg l4_src "$l4_source" \
        --arg l4_detail "$l4_detail" \
        '{
            status: $status,
            state: $state,
            enabled: {value: $l1_val, source: $l1_src, key: $l1_key},
            materialized: {value: $l2_val, source: $l2_src, artifacts: [$l2_art]},
            referenced: {value: $l3_val, source: $l3_src, rules: [$l3_rules]},
            effective_targeting: {value: $l4_val, source: $l4_src, detail: $l4_detail}
        }')
}

_doctor_all_modules() {
    for mod_name in portscan ddos botguard login feeds geoip geoban suricata synproxy; do
        [[ -z "${_DOCTOR_MODULES[$mod_name]:-}" ]] && continue
        _doctor_module_audit "$mod_name"
    done
}

# =============================================================================
# STEP 5: SECURITY GAPS
# =============================================================================

_doctor_security_gaps() {
    # CSF conflict detection
    if command -v csf &>/dev/null 2>&1 || [[ -f /etc/csf/csf.conf ]]; then
        _doctor_finding "$_SEV_ERR" "csf_conflict" "CSF firewall installed — dual firewall conflict" "file"
    fi

    # SSH port config vs kernel mismatch
    local config_ssh
    config_ssh=$(_doctor_config_val "SSH_PORT")
    if [[ -n "$config_ssh" ]]; then
        # Check sshd actual listen port
        local sshd_port
        sshd_port=$(echo "$_DOCTOR_SS_OUTPUT" | grep -oP '(?<=:)\d+(?=\s)' | head -1 || echo "")
        # Check if sshd is actually listening on the config port
        if [[ -n "$sshd_port" ]]; then
            local sshd_on_config=false
            while IFS= read -r line; do
                if echo "$line" | grep -q "sshd\|ssh" && echo "$line" | grep -q ":${config_ssh} "; then
                    sshd_on_config=true
                    break
                fi
            done <<< "$_DOCTOR_SS_OUTPUT"

            if [[ "$sshd_on_config" == "false" ]]; then
                # Check if SSH is on a different port
                local actual_ssh_port
                actual_ssh_port=$(echo "$_DOCTOR_SS_OUTPUT" | grep -E "sshd|ssh" | grep -oP '(?<=:)\d+(?=\s)' | head -1 || echo "")
                if [[ -n "$actual_ssh_port" && "$actual_ssh_port" != "$config_ssh" ]]; then
                    _doctor_finding "$_SEV_ERR" "misconfig_ssh_mismatch" \
                        "SSH daemon on port $actual_ssh_port but config SSH_PORT=$config_ssh (lockout risk!)" "ss" "" \
                        "$(jq -nc --arg cp "$config_ssh" --arg ap "$actual_ssh_port" '{config_port: $cp, actual_port: $ap}')"
                fi
            fi
        fi
    fi

    # CT limit check for SSH
    local ddos_enabled=false
    _doctor_config_bool "NFTBAN_DDOS_ENABLED" && ddos_enabled=true
    if [[ "$ddos_enabled" == "false" ]]; then
        # Check if SSH is in allowed ports — warning if no DDoS protection
        local kernel_tcp
        kernel_tcp=$(_doctor_nft_port_set_values "tcp_ports_in")
        local ssh_port="${config_ssh:-22}"
        if echo ",$kernel_tcp," | grep -q ",${ssh_port},"; then
            _doctor_finding "$_SEV_WARN" "no_ct_limit_ssh" \
                "SSH on port $ssh_port exposed without DDoS/CT protection (ddos module disabled)" "config"
        fi
    fi

    # BotGuard check: HTTP exposed but no bot protection
    local botguard_enabled=false
    _doctor_config_bool "HTTP_BOTGUARD_ENABLED" && botguard_enabled=true
    if [[ "$botguard_enabled" == "false" ]]; then
        local kernel_tcp
        kernel_tcp=$(_doctor_nft_port_set_values "tcp_ports_in")
        if echo ",$kernel_tcp," | grep -qE ",80,|,443,|,8080,|,8443,"; then
            _doctor_finding "$_SEV_WARN" "no_botguard_http" \
                "HTTP/S ports exposed but BotGuard disabled" "config"
        fi
    fi
}

# =============================================================================
# STEP 5b: CONFIG DIFF --kernel
# =============================================================================

_doctor_diff_kernel() {
    # Compare config values vs kernel state (narrow: ports, module enables, SSH)
    local json_mode="${1:-0}"

    # Gather data if not already done
    [[ -z "$_DOCTOR_NFT_JSON" ]] && _doctor_gather_data

    local has_divergence=0

    if [[ "$json_mode" != "1" ]]; then
        echo "═══ Config Diff: CONFIG ↔ KERNEL ═══"
        echo ""
        printf "  %-22s %-22s %-22s %s\n" "KEY" "CONFIG VALUE" "KERNEL STATE" "STATUS"
        echo "  ────────────────────── ────────────────────── ────────────────────── ──────────"
    fi

    local findings=()

    # TCP_PORTS_IN
    local config_tcp kernel_tcp
    config_tcp=$(_doctor_config_val "TCP_PORTS_IN")
    kernel_tcp=$(_doctor_nft_port_set_values "tcp_ports_in")
    if [[ -n "$config_tcp" && -n "$kernel_tcp" ]]; then
        local cfg_sorted kern_sorted
        cfg_sorted=$(echo "$config_tcp" | tr ',' '\n' | sort -n | tr '\n' ',' | sed 's/,$//')
        kern_sorted=$(echo "$kernel_tcp" | tr ',' '\n' | sort -n | tr '\n' ',' | sed 's/,$//')
        local status_sym="✓ SYNCED"
        if [[ "$cfg_sorted" != "$kern_sorted" ]]; then
            status_sym="⚠ DIVERGED"
            has_divergence=1
        fi
        if [[ "$json_mode" != "1" ]]; then
            printf "  %-22s %-22s %-22s %s\n" "TCP_PORTS_IN" "$cfg_sorted" "$kern_sorted" "$status_sym"
        fi
        findings+=("$(jq -nc --arg k "TCP_PORTS_IN" --arg cv "$cfg_sorted" --arg kv "$kern_sorted" --arg s "$status_sym" \
            '{key: $k, config_value: $cv, kernel_value: $kv, status: $s}')")
    fi

    # SSH_PORT
    local config_ssh
    config_ssh=$(_doctor_config_val "SSH_PORT")
    if [[ -n "$config_ssh" ]]; then
        local ssh_in_kernel="yes"
        if [[ -n "$kernel_tcp" ]] && ! echo ",$kernel_tcp," | grep -q ",${config_ssh},"; then
            ssh_in_kernel="no"
        fi
        local status_sym="✓ SYNCED"
        if [[ "$ssh_in_kernel" == "no" ]]; then
            status_sym="⚠ DIVERGED"
            has_divergence=1
        fi
        if [[ "$json_mode" != "1" ]]; then
            printf "  %-22s %-22s %-22s %s\n" "SSH_PORT" "$config_ssh" "in_ports=$ssh_in_kernel" "$status_sym"
        fi
        findings+=("$(jq -nc --arg k "SSH_PORT" --arg cv "$config_ssh" --arg kv "in_ports=$ssh_in_kernel" --arg s "$status_sym" \
            '{key: $k, config_value: $cv, kernel_value: $kv, status: $s}')")
    fi

    # Module enable states
    for mod_name in portscan ddos botguard; do
        local mod_def="${_DOCTOR_MODULES[$mod_name]:-}"
        [[ -z "$mod_def" ]] && continue
        local enable_key chain_artifact
        IFS='|' read -r enable_key chain_artifact _ <<< "$mod_def"
        [[ -z "$enable_key" || -z "$chain_artifact" ]] && continue

        local config_val="false"
        _doctor_config_bool "$enable_key" && config_val="true"

        local kernel_val="absent"
        _doctor_nft_chain_exists "$chain_artifact" && kernel_val="present"

        local status_sym="✓ SYNCED"
        if { [[ "$config_val" == "true" && "$kernel_val" == "absent" ]] || \
             [[ "$config_val" == "false" && "$kernel_val" == "present" ]]; }; then
            status_sym="⚠ DIVERGED"
            has_divergence=1
        fi

        if [[ "$json_mode" != "1" ]]; then
            printf "  %-22s %-22s %-22s %s\n" "$enable_key" "$config_val" "chain=$kernel_val" "$status_sym"
        fi
        findings+=("$(jq -nc --arg k "$enable_key" --arg cv "$config_val" --arg kv "chain=$kernel_val" --arg s "$status_sym" \
            '{key: $k, config_value: $cv, kernel_value: $kv, status: $s}')")
    done

    if [[ "$json_mode" == "1" ]]; then
        printf '%s\n' "${findings[@]}" | jq -s '{config_vs_kernel: .}'
    else
        echo ""
        if [[ $has_divergence -gt 0 ]]; then
            echo "Summary: config↔kernel divergences found"
            echo "  Fix: nftban firewall rebuild"
        else
            echo "Summary: config and kernel are in sync"
        fi
    fi
}

# =============================================================================
# RENDERERS
# =============================================================================

_doctor_render_human() {
    local filter_module="${1:-}" filter_security="${2:-}"

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NFTBan Config Doctor — System Integrity Audit"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    local overall
    overall=$(_doctor_overall_status)

    # Core section (skip if filtering by module)
    if [[ -z "$filter_module" && -z "$filter_security" ]]; then
        echo "CORE INTEGRITY"
        echo "──────────────"
        for f in "${_DOCTOR_FINDINGS[@]}"; do
            local ftype fsev fmsg
            ftype=$(echo "$f" | jq -r '.type')
            fsev=$(echo "$f" | jq -r '.severity')
            fmsg=$(echo "$f" | jq -r '.message')
            case "$ftype" in
                table_*|chain_*|sets_*|counters_*|hook_*|foreign_*|ghost_*|no_ghosts)
                    local icon="  ✓"
                    case "$fsev" in
                        warning) icon="  ⚠" ;;
                        error)   icon="  ✖" ;;
                        info)    icon="  ℹ" ;;
                    esac
                    echo "$icon $fmsg"
                    ;;
            esac
        done
        echo ""
    fi

    # Override section (skip if filtering)
    if [[ -z "$filter_module" && -z "$filter_security" ]]; then
        echo "OVERRIDES"
        echo "─────────"
        echo "  Active: ${#_DOCTOR_OVR_ACTIVE[@]}  Dead: ${#_DOCTOR_OVR_DEAD[@]}  Stale: ${#_DOCTOR_OVR_STALE[@]}  Unapplied: ${#_DOCTOR_OVR_UNAPPLIED[@]}"
        for d in "${_DOCTOR_OVR_DEAD[@]}"; do
            local dk dv
            dk=$(echo "$d" | jq -r '.key')
            dv=$(echo "$d" | jq -r '.value')
            echo "  ⚠ DEAD: $dk=$dv (not in schema)"
        done
        for s in "${_DOCTOR_OVR_STALE[@]}"; do
            local sk sv
            sk=$(echo "$s" | jq -r '.key')
            sv=$(echo "$s" | jq -r '.value')
            echo "  ℹ STALE: $sk=$sv (same as default)"
        done
        for u in "${_DOCTOR_OVR_UNAPPLIED[@]}"; do
            local uk ucv ukv
            uk=$(echo "$u" | jq -r '.key // .module')
            ucv=$(echo "$u" | jq -r '.config_value')
            ukv=$(echo "$u" | jq -r '.kernel_value')
            echo "  ⚠ UNAPPLIED: $uk config=$ucv kernel=$ukv"
        done
        echo ""
    fi

    # Modules section
    echo "MODULES (L1:enabled → L2:materialized → L3:referenced → L4:targeting)"
    echo "──────────────────────────────────────────────────────────────────────"
    for mod_name in portscan ddos botguard login feeds geoip geoban suricata synproxy; do
        [[ -n "$filter_module" && "$filter_module" != "$mod_name" ]] && continue
        local mresult="${_DOCTOR_MODULE_RESULTS[$mod_name]:-}"
        [[ -z "$mresult" ]] && continue
        local mstate mstatus ml4detail
        mstate=$(echo "$mresult" | jq -r '.state')
        mstatus=$(echo "$mresult" | jq -r '.status')
        ml4detail=$(echo "$mresult" | jq -r '.effective_targeting.detail // empty')
        local icon="✓"
        case "$mstatus" in
            warning) icon="⚠" ;;
            error)   icon="✖" ;;
            info)    icon="ℹ" ;;
        esac
        printf "  %s %-12s %s\n" "$icon" "$mod_name" "$mstate"
        [[ -n "$ml4detail" && "$mstate" != "DISABLED" ]] && printf "    └─ %s\n" "$ml4detail"
    done
    echo ""

    # Security section
    if [[ -z "$filter_module" ]] || [[ -n "$filter_security" ]]; then
        local has_security=false
        echo "SECURITY"
        echo "────────"
        for f in "${_DOCTOR_FINDINGS[@]}"; do
            local ftype fsev fmsg
            ftype=$(echo "$f" | jq -r '.type')
            fsev=$(echo "$f" | jq -r '.severity')
            fmsg=$(echo "$f" | jq -r '.message')
            case "$ftype" in
                csf_*|misconfig_*|no_ct_*|no_botguard_*|ssh_port_not_allowed)
                    has_security=true
                    local icon="  ⚠"
                    [[ "$fsev" == "error" ]] && icon="  ✖"
                    echo "$icon $fmsg"
                    ;;
            esac
        done
        [[ "$has_security" == "false" ]] && echo "  ✓ No security gaps detected"
        echo ""
    fi

    # Drift section
    if [[ -z "$filter_module" && -z "$filter_security" ]]; then
        local has_drift=false
        for f in "${_DOCTOR_FINDINGS[@]}"; do
            local ftype
            ftype=$(echo "$f" | jq -r '.type')
            case "$ftype" in
                drift_*) has_drift=true; break ;;
            esac
        done
        if [[ "$has_drift" == "true" ]]; then
            echo "DRIFT"
            echo "─────"
            for f in "${_DOCTOR_FINDINGS[@]}"; do
                local ftype fmsg
                ftype=$(echo "$f" | jq -r '.type')
                fmsg=$(echo "$f" | jq -r '.message')
                case "$ftype" in
                    drift_*)
                        echo "  ⚠ $fmsg"
                        ;;
                esac
            done
            echo ""
        fi
    fi

    # Summary
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local total=$(( _DOCTOR_COUNTS_OK + _DOCTOR_COUNTS_INFO + _DOCTOR_COUNTS_WARN + _DOCTOR_COUNTS_ERR ))
    echo "  Status: ${overall^^}  (${total} checks: ${_DOCTOR_COUNTS_OK} ok, ${_DOCTOR_COUNTS_INFO} info, ${_DOCTOR_COUNTS_WARN} warning, ${_DOCTOR_COUNTS_ERR} error)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

_doctor_render_brief() {
    local overall
    overall=$(_doctor_overall_status)
    local total=$(( _DOCTOR_COUNTS_OK + _DOCTOR_COUNTS_INFO + _DOCTOR_COUNTS_WARN + _DOCTOR_COUNTS_ERR ))
    echo "doctor: ${overall^^} (${total} checks: ${_DOCTOR_COUNTS_OK} ok, ${_DOCTOR_COUNTS_INFO} info, ${_DOCTOR_COUNTS_WARN} warn, ${_DOCTOR_COUNTS_ERR} err)"
}

_doctor_render_json() {
    local filter_module="${1:-}"

    local overall
    overall=$(_doctor_overall_status)
    local total=$(( _DOCTOR_COUNTS_OK + _DOCTOR_COUNTS_INFO + _DOCTOR_COUNTS_WARN + _DOCTOR_COUNTS_ERR ))
    local version
    version=$(cat "${NFTBAN_LIB_DIR}/../../VERSION" 2>/dev/null || echo "unknown")

    # Build modules JSON
    local modules_json="{}"
    for mod_name in portscan ddos botguard login feeds geoip geoban suricata synproxy; do
        [[ -n "$filter_module" && "$filter_module" != "$mod_name" ]] && continue
        local mresult="${_DOCTOR_MODULE_RESULTS[$mod_name]:-}"
        [[ -z "$mresult" ]] && continue
        modules_json=$(echo "$modules_json" | jq --arg m "$mod_name" --argjson r "$mresult" '. + {($m): $r}')
    done

    # Build overrides JSON
    local ovr_active_json ovr_dead_json ovr_stale_json ovr_unapplied_json
    ovr_active_json=$(printf '%s\n' "${_DOCTOR_OVR_ACTIVE[@]}" 2>/dev/null | jq -s '.' 2>/dev/null || echo "[]")
    ovr_dead_json=$(printf '%s\n' "${_DOCTOR_OVR_DEAD[@]}" 2>/dev/null | jq -s '.' 2>/dev/null || echo "[]")
    ovr_stale_json=$(printf '%s\n' "${_DOCTOR_OVR_STALE[@]}" 2>/dev/null | jq -s '.' 2>/dev/null || echo "[]")
    ovr_unapplied_json=$(printf '%s\n' "${_DOCTOR_OVR_UNAPPLIED[@]}" 2>/dev/null | jq -s '.' 2>/dev/null || echo "[]")

    # Build findings arrays by section
    local core_findings=() drift_findings=() security_findings=()
    for f in "${_DOCTOR_FINDINGS[@]}"; do
        local ftype
        ftype=$(echo "$f" | jq -r '.type')
        case "$ftype" in
            table_*|chain_*|sets_*|counters_*|hook_*|foreign_*|ghost_*|no_ghosts)
                core_findings+=("$f") ;;
            drift_*|tcp_*|ssh_port_not_allowed)
                drift_findings+=("$f") ;;
            csf_*|misconfig_*|no_ct_*|no_botguard_*)
                security_findings+=("$f") ;;
        esac
    done

    local core_json drift_json sec_json
    core_json=$(printf '%s\n' "${core_findings[@]}" 2>/dev/null | jq -s '.' 2>/dev/null || echo "[]")
    drift_json=$(printf '%s\n' "${drift_findings[@]}" 2>/dev/null | jq -s '.' 2>/dev/null || echo "[]")
    sec_json=$(printf '%s\n' "${security_findings[@]}" 2>/dev/null | jq -s '.' 2>/dev/null || echo "[]")

    jq -nc \
        --arg schema "nftban-doctor-v1" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg ver "$version" \
        --arg status "$overall" \
        --argjson total "$total" \
        --argjson passed "$_DOCTOR_COUNTS_OK" \
        --argjson info "$_DOCTOR_COUNTS_INFO" \
        --argjson warn "$_DOCTOR_COUNTS_WARN" \
        --argjson err "$_DOCTOR_COUNTS_ERR" \
        --argjson ovr_active "$ovr_active_json" \
        --argjson ovr_dead "$ovr_dead_json" \
        --argjson ovr_stale "$ovr_stale_json" \
        --argjson ovr_unapplied "$ovr_unapplied_json" \
        --argjson core_findings "$core_json" \
        --argjson drift_findings "$drift_json" \
        --argjson sec_findings "$sec_json" \
        --argjson modules "$modules_json" \
        '{
            "$schema": $schema,
            timestamp: $ts,
            version: $ver,
            status: $status,
            summary: {total: $total, passed: $passed, info: $info, warning: $warn, error: $err},
            overrides: {active: $ovr_active, dead: $ovr_dead, stale: $ovr_stale, unapplied: $ovr_unapplied},
            core: {findings: $core_findings},
            drift: {findings: $drift_findings},
            modules: $modules,
            security: {findings: $sec_findings}
        }' | jq '.'
}

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

nftban_cmd_config_doctor() {
    local json_mode=0
    local brief_mode=0
    local filter_module=""
    local filter_security=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json_mode=1 ;;
            --brief) brief_mode=1 ;;
            --module)
                shift
                filter_module="${1:-}"
                if [[ -z "$filter_module" ]]; then
                    echo "ERROR: --module requires a module name" >&2
                    return 1
                fi
                ;;
            --security) filter_security="1" ;;
            -h|--help|help)
                echo "Usage: nftban config doctor [options]"
                echo ""
                echo "Full system integrity audit (config+kernel+runtime)"
                echo ""
                echo "OPTIONS:"
                echo "  --json              JSON output (machine-readable)"
                echo "  --brief             Single summary line"
                echo "  --module <name>     Audit single module only"
                echo "  --security          Show security gaps only"
                echo ""
                echo "MODULES: portscan, ddos, botguard, login, feeds, geoip, geoban, suricata, synproxy"
                return 0
                ;;
            *) ;;
        esac
        shift
    done

    # Gather all data (single pass)
    _doctor_gather_data

    # Run all analysis phases
    _doctor_core_integrity >/dev/null
    _doctor_override_analysis
    _doctor_global_drift
    _doctor_all_modules
    _doctor_security_gaps

    # Render output
    if [[ $json_mode -eq 1 ]]; then
        _doctor_render_json "$filter_module"
    elif [[ $brief_mode -eq 1 ]]; then
        _doctor_render_brief
    else
        _doctor_render_human "$filter_module" "$filter_security"
    fi
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_cmd_config_doctor
export -f _doctor_diff_kernel
