#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Port Report Core Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Port scanning and nftables firewall status analysis
#
# meta:name="nftban_report_port"
# meta:type="core"
# meta:header="Port Report Core"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
# meta:description="Scans listening services and analyzes nftables firewall status per port"
# meta:input="Port filters, output format options"
# meta:output="Port status reports (terminal, HTML, mail)"
# meta:depends="bash,ss,nft"
# meta:created_date="2025-11-05"
# meta:updated_date="2026-01-14"
# meta:inventory.files=""
# meta:inventory.binaries="ss,nft"
# meta:inventory.env_vars="NFTBAN_TABLE_IPV4,NFTBAN_TABLE_IPV6"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# =============================================================================
# TABLE DEFAULTS (must be set before any nft commands)
# =============================================================================
: "${NFTBAN_TABLE_IPV4:=ip nftban}"
: "${NFTBAN_TABLE_IPV6:=ip6 nftban}"

# =============================================================================
# GLOBALS
# =============================================================================

declare -g -A NFTBAN_PORT_LISTEN_MAP=()    # key: proto_port_family -> "proc:pid"
declare -g -A NFTBAN_PORT_BIND_ADDR=()     # key: proto_port_family -> local address
declare -g -A NFTBAN_PORT_NFT_RULES=()     # key: port_proto_chain_family -> action
declare -g -A NFTBAN_PORT_NFT_GENERIC=()   # key: port_proto_chain -> action
declare -g -A NFTBAN_PORT_SEEN=()          # key: port_proto -> 1
declare -g -A NFTBAN_PORT_SERVICE_NAME=()  # key: port_proto -> service name
declare -g -A NFTBAN_PORT_STATUS=()        # key: port/proto/family/direction -> status (populated in caller, not subshell)

# shellcheck disable=SC2034  # Reserved for report headers
NFTBAN_PORT_TIMESTAMP="$(date --iso-8601=seconds)"
NFTBAN_PORT_DETAILED="${NFTBAN_PORT_DETAILED:-0}"
NFTBAN_PORT_OUTPUT_FORMAT="${NFTBAN_PORT_OUTPUT_FORMAT:-table}"
NFTBAN_PORT_FILTER_PORTS="${NFTBAN_PORT_FILTER_PORTS:-}"
NFTBAN_PORT_COLLAPSE_RANGES="${NFTBAN_PORT_COLLAPSE_RANGES:-1}"  # Collapse consecutive inactive ports into ranges
NFTBAN_PORT_ACTIVE_ONLY="${NFTBAN_PORT_ACTIVE_ONLY:-0}"  # Only show ports with active services (hides passive FTP ranges)

# Color symbols (use nftban_output.sh if available)
if type -t nftban_render_banner >/dev/null 2>&1; then
    # nftban_output.sh loaded, use its colors
    # shellcheck disable=SC2034  # Symbols for UI rendering
    NFTBAN_PORT_SYM_OK="✔"
    # shellcheck disable=SC2034  # Symbols for UI rendering
    NFTBAN_PORT_SYM_KO="✖"
    # shellcheck disable=SC2034  # Symbols for UI rendering
    NFTBAN_PORT_SYM_QUEST="−"
else
    # Fallback colors
    # shellcheck disable=SC2034  # Symbols for UI rendering
    NFTBAN_PORT_SYM_OK="✔"
    # shellcheck disable=SC2034  # Symbols for UI rendering
    NFTBAN_PORT_SYM_KO="✖"
    # shellcheck disable=SC2034  # Symbols for UI rendering
    NFTBAN_PORT_SYM_QUEST="−"
    C_RESET="\e[0m"
    C_RED="\e[31m"
    C_GREEN="\e[32m"
    C_YELLOW="\e[33m"
    # shellcheck disable=SC2034  # Reserved for future formatting
    C_BOLD="\e[1m"
fi

# =============================================================================
# HOSTING SERVICE NAME MAPPING
# =============================================================================
# Override IANA /etc/services with actual names used in modern hosting environments
# Format: NFTBAN_HOSTING_SERVICES["port_proto"]="ServiceName"

declare -g -A NFTBAN_HOSTING_SERVICES=(
    # Mail services (correct names)
    ["25_tcp"]="SMTP"
    ["465_tcp"]="SMTPS"           # NOT "urd"
    ["587_tcp"]="Submission"
    ["993_tcp"]="IMAPS"
    ["995_tcp"]="POP3S"
    ["110_tcp"]="POP3"
    ["143_tcp"]="IMAP"
    ["4190_tcp"]="Sieve"          # Dovecot mail filtering

    # cPanel/WHM
    ["2077_tcp"]="WebDAV"         # NOT "tsrmagt"
    ["2078_tcp"]="WebDAV-SSL"     # NOT "tpcsrvr"
    ["2079_tcp"]="CalDAV"         # NOT "idware-router"
    ["2080_tcp"]="CalDAV-SSL"
    ["2082_tcp"]="cPanel"         # NOT "infowave"
    ["2083_tcp"]="cPanel-SSL"     # NOT "radsec"
    ["2086_tcp"]="WHM"            # NOT "gnunet"
    ["2087_tcp"]="WHM-SSL"        # NOT "eli"
    ["2095_tcp"]="Webmail"        # NOT "nbx-ser"
    ["2096_tcp"]="Webmail-SSL"    # NOT "nbx-dir"

    # DirectAdmin
    ["2222_tcp"]="DirectAdmin"

    # Plesk
    ["8443_tcp"]="Plesk"
    ["8447_tcp"]="Plesk-Update"
    ["8880_tcp"]="Plesk-HTTP"

    # Web servers
    ["80_tcp"]="HTTP"
    ["443_tcp"]="HTTPS"
    ["8080_tcp"]="HTTP-Alt"
    ["8443_tcp"]="HTTPS-Alt"

    # DNS
    ["53_tcp"]="DNS"
    ["53_udp"]="DNS"
    ["953_tcp"]="DNS-RNDC"        # NOT generic "rndc"

    # Databases
    ["3306_tcp"]="MySQL"
    ["5432_tcp"]="PostgreSQL"
    ["6379_tcp"]="Redis"
    ["27017_tcp"]="MongoDB"

    # Security/Monitoring
    ["783_tcp"]="SpamAssassin"    # NOT "vopied"
    ["11234_tcp"]="Imunify360"
    ["8428_tcp"]="VictoriaMetrics"
    ["9090_tcp"]="Prometheus"
    ["9100_tcp"]="NodeExporter"

    # FTP
    ["20_tcp"]="FTP-Data"
    ["21_tcp"]="FTP"
    ["990_tcp"]="FTPS"

    # SSH/Remote
    ["22_tcp"]="SSH"
    ["3389_tcp"]="RDP"

    # Monitoring agents
    ["10050_tcp"]="Zabbix-Agent"
    ["10051_tcp"]="Zabbix-Trap"

    # Time sync
    ["123_udp"]="NTP"
    ["323_udp"]="Chrony"          # NOT "brcd"
)

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

nftban_port_trim() {
    local s="${*-}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

nftban_port_is_loopback() {
    local a="${1-}"
    [[ -z "$a" ]] && return 1
    [[ "$a" == "127.0.0.1" || "$a" == "::1" || "$a" == "localhost" ]] && return 0
    [[ "$a" =~ ^127\. ]] && return 0
    return 1
}

nftban_port_bind_scope() {
    local a="${1-}"
    if nftban_port_is_loopback "$a"; then echo "LOCAL-ONLY"; return; fi
    [[ "$a" == "0.0.0.0" || "$a" == "::" || "$a" == "*" ]] && { echo "PUBLIC"; return; }
    # Any non-loopback specific IP is considered exposed
    echo "PUBLIC"
}

# =============================================================================
# PORT SCANNING FUNCTIONS
# =============================================================================

nftban_port_gather_listeners() {
    # Gather listening ports using ss (preferred) or lsof (fallback)
    # Populates: NFTBAN_PORT_LISTEN_MAP, NFTBAN_PORT_BIND_ADDR, NFTBAN_PORT_SEEN

    # Prefer ss
    while IFS= read -r line; do
        # Skip non-listener lines or lines without process info
        [[ "$line" =~ users: ]] || continue

        local proto local_ap port addr family users cmd pid proto_norm key

        # Grab the local address:port from the 5th field
        proto="$(awk '{print $1}' <<<"$line")"
        local_ap="$(awk '{print $5}' <<<"$line")"

        # Ensure it's an address:port pair
        [[ "$local_ap" =~ : ]] || continue

        port="${local_ap##*:}"
        addr="${local_ap%:*}"
        # Normalize IPv6 [::] / [::ffff:...] -> ::... (strip brackets)
        addr="${addr#[}"; addr="${addr%]}"
        family="ipv4"; [[ "$addr" =~ : ]] && family="ipv6"

        users="$(sed -n 's/.*users:(\([^)]*\)).*/\1/p' <<<"$line" || true)"
        cmd=""; pid=""
        if [[ "$users" =~ \"([^\"]+)\"[,[:space:]]*pid=([0-9]+) ]]; then
            cmd="${BASH_REMATCH[1]}"; pid="${BASH_REMATCH[2]}"
        fi

        proto_norm="tcp"; [[ "$proto" =~ udp ]] && proto_norm="udp"
        key="${proto_norm}_${port}_${family}"

        NFTBAN_PORT_LISTEN_MAP["$key"]="${cmd:+$cmd:}${pid}"
        NFTBAN_PORT_BIND_ADDR["$key"]="$addr"
        NFTBAN_PORT_SEEN["${port}_${proto_norm}"]=1
    done < <(ss -tunlp -H 2>/dev/null || true)

    # Fallback 1: netstat (if ss found nothing)
    if (( ${#NFTBAN_PORT_LISTEN_MAP[@]} == 0 )) && command -v netstat >/dev/null 2>&1; then
        while IFS= read -r line; do
            # Parse netstat output: tcp/tcp6/udp/udp6  0  0  0.0.0.0:22  0.0.0.0:*  LISTEN  1234/sshd
            [[ "$line" =~ ^(tcp|tcp6|udp|udp6)[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+([^\ :]+):([0-9]+)[[:space:]]+[^\ ]+[[:space:]]+(LISTEN)?[[:space:]]*([0-9]+)/([^\ ]+) ]] || continue

            local proto_raw="${BASH_REMATCH[1]}"
            local addr="${BASH_REMATCH[2]}"
            local port="${BASH_REMATCH[3]}"
            local pid="${BASH_REMATCH[5]}"
            local cmd="${BASH_REMATCH[6]}"

            # Normalize protocol and family
            local proto_norm="tcp"
            local family="ipv4"

            case "$proto_raw" in
                tcp)  proto_norm="tcp"; family="ipv4" ;;
                tcp6) proto_norm="tcp"; family="ipv6" ;;
                udp)  proto_norm="udp"; family="ipv4" ;;
                udp6) proto_norm="udp"; family="ipv6" ;;
            esac

            # Normalize address (strip brackets from IPv6)
            addr="${addr#[}"; addr="${addr%]}"
            [[ "$addr" == ":::" ]] && addr="::"

            local key="${proto_norm}_${port}_${family}"
            NFTBAN_PORT_LISTEN_MAP["$key"]="${cmd:+$cmd:}${pid}"
            NFTBAN_PORT_BIND_ADDR["$key"]="$addr"
            NFTBAN_PORT_SEEN["${port}_${proto_norm}"]=1
        done < <(netstat -tulnp 2>/dev/null || true)
    fi

    # Fallback 2: lsof (only if ss and netstat found nothing)
    if (( ${#NFTBAN_PORT_LISTEN_MAP[@]} == 0 )) && command -v lsof >/dev/null 2>&1; then
        while IFS= read -r l; do
            # mysqld 1234 ... TCP 0.0.0.0:3306 (LISTEN)  OR TCP [::]:22 (LISTEN)
            [[ "$l" =~ ^([[:alnum:]._-]+)[[:space:]]+([0-9]+).*TCP[[:space:]]+(\[::\]|[^\ :]+):([0-9]+)[[:space:]]+\(LISTEN\) ]] || continue
            local cmd2 pid2 addr2 port2 family2 key2
            cmd2="${BASH_REMATCH[1]}"; pid2="${BASH_REMATCH[2]}"; addr2="${BASH_REMATCH[3]}"; port2="${BASH_REMATCH[4]}"
            addr2="${addr2#[}"; addr2="${addr2%]}"
            family2="ipv4"; [[ "$addr2" =~ : ]] && family2="ipv6"
            key2="tcp_${port2}_${family2}"
            NFTBAN_PORT_LISTEN_MAP["$key2"]="${cmd2:+$cmd2:}${pid2}"
            NFTBAN_PORT_BIND_ADDR["$key2"]="$addr2"
            NFTBAN_PORT_SEEN["${port2}_tcp"]=1
        done < <(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null || true)
    fi
}

nftban_port_gather_nft_rules() {
    # Parse nftables ruleset and populate NFT_RULES/NFT_GENERIC
    # Populates: NFTBAN_PORT_NFT_RULES, NFTBAN_PORT_NFT_GENERIC, NFTBAN_PORT_SEEN

    local RULESET_RAW
    RULESET_RAW="$(nft list ruleset 2>/dev/null || true)"
    [[ -z "$RULESET_RAW" ]] && return

    # First, gather set-based rules (tcp dport @tcp_ports, etc.)
    local set_rules=()
    local line cur_chain=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*chain[[:space:]]+([[:alnum:]_-]+) ]]; then
            cur_chain="${BASH_REMATCH[1]}"; continue
        fi
        # Detect set-based rules: tcp dport @tcp_ports accept
        # Note: May have 'counter' between set and action
        if [[ "$line" =~ (tcp|udp)[[:space:]]+dport[[:space:]]+@([[:alnum:]_-]+)[[:space:]].*(accept|drop|reject) ]]; then
            local proto="${BASH_REMATCH[1]}" set_name="${BASH_REMATCH[2]}" action="${BASH_REMATCH[3]}"
            set_rules+=("${proto}|${set_name}|${cur_chain}|${action}")
        fi
    done < <(printf '%s\n' "$RULESET_RAW")

    # Parse sets and expand them to individual ports
    for rule in "${set_rules[@]}"; do
        IFS='|' read -r proto set_name chain action <<< "$rule"
        # Normalize chain name: services_in→input, services_out→output, input_*→input, etc.
        local norm_chain="$chain"
        [[ "$chain" =~ input|_in$ ]] && norm_chain="input"
        [[ "$chain" =~ output|_out$ ]] && norm_chain="output"

        # Get set contents (v0.7.3: check IPv4 table, could also check IPv6)
        # Note: elements may span multiple lines, so we use tr to join lines first
        local set_contents
        set_contents=$(nft list set ${NFTBAN_TABLE_IPV4} "$set_name" 2>/dev/null | tr '\n' ' ' | grep -oP 'elements = \{\K[^}]+' || true)
        if [[ -n "$set_contents" ]]; then
            # Parse ports from set (handles: 22, 80, 443, etc.)
            local port
            for port in $(echo "$set_contents" | tr ',' '\n' | grep -oE '[0-9]+'); do
                NFTBAN_PORT_NFT_GENERIC["${port}_${proto}_${norm_chain}"]="$action"
                NFTBAN_PORT_SEEN["${port}_${proto}"]=1
            done
        fi
    done

    # Then, gather direct port rules (tcp dport 22 accept)
    cur_chain=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*chain[[:space:]]+([[:alnum:]_-]+) ]]; then
            cur_chain="${BASH_REMATCH[1]}"; continue
        fi
        if [[ "$line" =~ (tcp|udp)[[:space:]]+dport[[:space:]]+([0-9]+) ]]; then
            local proto port family="generic" action="unknown"
            proto="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"
            [[ "$line" =~ nfproto[[:space:]]+ipv6 ]] && family="ipv6"
            [[ "$line" =~ nfproto[[:space:]]+ipv4 ]] && family="ipv4"
            if [[ "$line" =~ (accept|drop|reject) ]]; then action="${BASH_REMATCH[1]}"; fi
            if [[ "$family" == "generic" ]]; then
                NFTBAN_PORT_NFT_GENERIC["${port}_${proto}_${cur_chain}"]="$action"
            else
                NFTBAN_PORT_NFT_RULES["${port}_${proto}_${cur_chain}_${family}"]="$action"
            fi
            NFTBAN_PORT_SEEN["${port}_${proto}"]=1
        fi
    done < <(printf '%s\n' "$RULESET_RAW")
}

# =============================================================================
# STATUS DETERMINATION FUNCTIONS
# =============================================================================

nftban_port_determine_status() {
    # Determine firewall status for a port/proto
    # Args: $1 = port, $2 = proto
    # Output: "v4in|v4out|v6in|v6out|notes"

    local port="$1" proto="$2"
    local in="input" out="output"
    local notes=()

    _res() {
        local p="$1" r="$2" c="$3" f="$4"
        if [[ -n "${NFTBAN_PORT_NFT_RULES["${p}_${r}_${c}_${f}"]+x}" ]]; then
            printf '%s' "${NFTBAN_PORT_NFT_RULES["${p}_${r}_${c}_${f}"]}"; return
        fi
        if [[ -n "${NFTBAN_PORT_NFT_GENERIC["${p}_${r}_${c}"]+x}" ]]; then
            printf '%s_generic' "${NFTBAN_PORT_NFT_GENERIC["${p}_${r}_${c}"]}"; return
        fi
        printf 'no-rule'
    }

    local v4i v4o v6i v6o
    v4i="$(_res "$port" "$proto" "$in" "ipv4")"
    v4o="$(_res "$port" "$proto" "$out" "ipv4")"
    v6i="$(_res "$port" "$proto" "$in" "ipv6")"
    v6o="$(_res "$port" "$proto" "$out" "ipv6")"

    [[ "$v4i" == *_generic ]] && notes+=("ipv4-in:generic")
    [[ "$v4o" == *_generic ]] && notes+=("ipv4-out:generic")
    [[ "$v6i" == *_generic ]] && notes+=("ipv6-in:generic")
    [[ "$v6o" == *_generic ]] && notes+=("ipv6-out:generic")

    map_action() {
        case "$1" in
            accept|accept_generic) echo "Allowed" ;;
            drop|reject|drop_generic|reject_generic) echo "Blocked" ;;
            no-rule) echo "No-rule" ;;
            *) echo "Unknown" ;;
        esac
    }

    # NOTE: Array population moved to caller scope (BUG-005 FIX)
    # Command substitution runs in subshell - array changes were lost here

    printf "%s|%s|%s|%s|%s\n" \
        "$(map_action "${v4i%%_*}")" "$(map_action "${v4o%%_*}")" \
        "$(map_action "${v6i%%_*}")" "$(map_action "${v6o%%_*}")" \
        "$(printf '%s; ' "${notes[@]-}" | sed 's/; $//')"
}

nftban_port_detect_service() {
    # Detect service name and running status
    # Args: $1 = port, $2 = proto
    # Output: "NAME|RUNNING|PROCSTR|BIND|SCOPE"

    local port="$1" proto="$2"
    local k4="${proto}_${port}_ipv4" k6="${proto}_${port}_ipv6"
    local p4="${NFTBAN_PORT_LISTEN_MAP[$k4]:-}" p6="${NFTBAN_PORT_LISTEN_MAP[$k6]:-}"
    local b4="${NFTBAN_PORT_BIND_ADDR[$k4]:-}" b6="${NFTBAN_PORT_BIND_ADDR[$k6]:-}"

    local running="no" proc="" bind="" scope=""
    if [[ -n "$p4$b4$p6$b6" ]]; then
        running="yes"
        proc="$(nftban_port_trim "${p4:-}${p4:+ / }${p6:-}")"
        bind="$(nftban_port_trim "${b4:-}${b4:+ / }${b6:-}")"
        local sc4=""; [[ -n "$b4" ]] && sc4="$(nftban_port_bind_scope "$b4")"
        local sc6=""; [[ -n "$b6" ]] && sc6="$(nftban_port_bind_scope "$b6")"
        if [[ "$sc4" == "PUBLIC" || "$sc6" == "PUBLIC" ]]; then scope="PUBLIC"; else scope="LOCAL-ONLY"; fi
    fi

    local sname="${NFTBAN_PORT_SERVICE_NAME["${port}_${proto}"]-}"

    # Priority 1: Check hosting-specific service names (overrides IANA)
    if [[ -z "$sname" ]]; then
        sname="${NFTBAN_HOSTING_SERVICES["${port}_${proto}"]-}"
    fi

    # Priority 2: Fallback to /etc/services (IANA names)
    if [[ -z "$sname" && -r /etc/services ]]; then
        sname="$(awk -v P="$port" -v R="$proto" '!/^#/ && NF >= 2 { if ($2 ~ P"/"R) { print $1; exit; } }' /etc/services 2>/dev/null || true)"
    fi

    [[ -z "$sname" ]] && sname="UNKNOWN"

    printf "%s|%s|%s|%s|%s\n" "$sname" "$running" "$proc" "$bind" "$scope"
}

# =============================================================================
# REPORT RENDERING FUNCTIONS
# =============================================================================

nftban_port_render_json() {
    # Render port report as JSON
    # Uses: NFTBAN_PORT_SEEN, NFTBAN_PORT_FILTER_PORTS

    # Parse filter ports if provided
    local -a filter_ports_arr=()
    if [[ -n "$NFTBAN_PORT_FILTER_PORTS" ]]; then
        IFS=',' read -ra filter_ports_arr <<< "$NFTBAN_PORT_FILTER_PORTS"
    fi

    # Sorted iteration
    local -a keys=()
    local k
    for k in "${!NFTBAN_PORT_SEEN[@]}"; do keys+=("$k"); done
    IFS=$'\n' read -r -d '' -a sorted < <(printf '%s\n' "${keys[@]}" | sort -t_ -k1n -k2 && printf '\0') || true

    # Build JSON array
    local json_ports="["
    local first=true

    for entry in "${sorted[@]}"; do
        local port="${entry%%_*}" proto="${entry##*_}"

        # Filter (if any)
        if [[ ${#filter_ports_arr[@]} -gt 0 ]]; then
            local match=0 pf
            for pf in "${filter_ports_arr[@]}"; do
                [[ "$pf" == "$port" ]] && match=1
            done
            (( match == 1 )) || continue
        fi

        local svcinfo
        svcinfo="$(nftban_port_detect_service "$port" "$proto")"
        local svc running procinfo bind scope
        svc="$(cut -d'|' -f1 <<<"$svcinfo")"
        running="$(cut -d'|' -f2 <<<"$svcinfo")"
        procinfo="$(cut -d'|' -f3 <<<"$svcinfo")"
        bind="$(cut -d'|' -f4 <<<"$svcinfo")"
        scope="$(cut -d'|' -f5 <<<"$svcinfo")"

        # Check if in firewall
        local in_firewall=false
        if [[ -n "${NFTBAN_PORT_NFT_GENERIC["${port}_${proto}_input"]+x}" ]] || \
           [[ -n "${NFTBAN_PORT_NFT_RULES["${port}_${proto}_input_ipv4"]+x}" ]] || \
           [[ -n "${NFTBAN_PORT_NFT_RULES["${port}_${proto}_input_ipv6"]+x}" ]]; then
            in_firewall=true
        fi

        # Skip only if: NOT listening AND NOT in firewall
        if [[ "$running" != "yes" ]] && [[ "$in_firewall" == "false" ]]; then
            continue
        fi

        # If --active flag set, skip ports without active services (hides passive FTP ranges etc.)
        if (( NFTBAN_PORT_ACTIVE_ONLY )) && [[ "$running" != "yes" ]]; then
            continue
        fi

        local status_line
        status_line="$(nftban_port_determine_status "$port" "$proto")"
        local v4in v4out v6in v6out notes
        v4in="$(cut -d'|' -f1 <<< "$status_line")"
        v4out="$(cut -d'|' -f2 <<< "$status_line")"
        v6in="$(cut -d'|' -f3 <<< "$status_line")"
        v6out="$(cut -d'|' -f4 <<< "$status_line")"
        notes="$(cut -d'|' -f5 <<< "$status_line")"

        # Populate array in caller scope (BUG-005 FIX - subshell can't modify parent arrays)
        NFTBAN_PORT_STATUS["${port}/${proto}/ipv4/in"]="$v4in"
        NFTBAN_PORT_STATUS["${port}/${proto}/ipv4/out"]="$v4out"
        NFTBAN_PORT_STATUS["${port}/${proto}/ipv6/in"]="$v6in"
        NFTBAN_PORT_STATUS["${port}/${proto}/ipv6/out"]="$v6out"

        # Determine direction (IN/OUT/BOTH)
        local direction="IN"
        if [[ "$v4out" == "Allowed" ]] || [[ "$v6out" == "Allowed" ]]; then
            if [[ "$v4in" == "Allowed" ]] || [[ "$v6in" == "Allowed" ]]; then
                direction="IN/OUT"
            else
                direction="OUT"
            fi
        fi

        # Determine status
        local status="Closed"
        if [[ "$running" == "yes" ]]; then
            if [[ "$v4in" == "Allowed" ]] || [[ "$v6in" == "Allowed" ]]; then
                status="Open"
            else
                status="Listening"
            fi
        elif [[ "$in_firewall" == "true" ]]; then
            status="Open"
        fi

        # Add to JSON array
        if [[ "$first" == "true" ]]; then
            first=false
        else
            json_ports+=","
        fi

        # Escape quotes in strings
        svc="${svc//\"/\\\"}"
        notes="${notes//\"/\\\"}"

        json_ports+="{"
        json_ports+="\"port\":$port,"
        json_ports+="\"protocol\":\"${proto^^}\","
        json_ports+="\"direction\":\"$direction\","
        json_ports+="\"service\":\"$svc\","
        json_ports+="\"status\":\"$status\","
        json_ports+="\"listening\":$(if [[ "$running" == "yes" ]]; then echo "true"; else echo "false"; fi),"
        json_ports+="\"ipv4_in\":\"$v4in\","
        json_ports+="\"ipv4_out\":\"$v4out\","
        json_ports+="\"ipv6_in\":\"$v6in\","
        json_ports+="\"ipv6_out\":\"$v6out\""
        json_ports+="}"
    done

    json_ports+="]"

    # Output JSON
    echo "{"
    echo "  \"timestamp\":\"$(date --iso-8601=seconds)\","
    echo "  \"total\":$(echo "$json_ports" | { grep -o '{' || true; } | wc -l),"
    echo "  \"ports\":$json_ports"
    echo "}"

    return 0
}

nftban_port_render_table() {
    # Render port report as terminal table or JSON
    # Uses: NFTBAN_PORT_OUTPUT_FORMAT, NFTBAN_PORT_DETAILED, NFTBAN_PORT_FILTER_PORTS

    # Handle JSON output first (early return)
    if [[ "$NFTBAN_PORT_OUTPUT_FORMAT" == "json" ]]; then
        nftban_port_render_json
        return $?
    fi

    if [[ "$NFTBAN_PORT_OUTPUT_FORMAT" == "table" ]]; then
        local short_ts
        short_ts=$(date +"%Y-%m-%d %H:%M")
        echo ""
        echo "╔══════════════════════════════════════════════════════════════════════════════════╗"
        printf "║  Port Status                    %-12s                                      ║\n" "$short_ts"
        echo "╚══════════════════════════════════════════════════════════════════════════════════╝"
        echo ""
        if (( NFTBAN_PORT_DETAILED )); then
            printf "%-12s %-10s %-10s %-12s %-20s %-9s %-9s %-9s %-9s %-12s\n" \
                "PORT/PROTO" "SERVICE" "STATUS" "BIND" "PROCESS" "IPv4 IN" "IPv4 OUT" "IPv6 IN" "IPv6 OUT" "ACCESS"
        else
            printf "%-12s %-10s %-10s %-9s %-9s %-9s %-9s %-12s\n" \
                "PORT/PROTO" "SERVICE" "STATUS" "IPv4 IN" "IPv4 OUT" "IPv6 IN" "IPv6 OUT" "ACCESS"
        fi
        echo "──────────────────────────────────────────────────────────────────────────────────"
    elif [[ "$NFTBAN_PORT_OUTPUT_FORMAT" == "md" ]]; then
        if (( NFTBAN_PORT_DETAILED )); then
            echo "| SERVICE | PORT | PROTO | RUNNING | BIND | PROCESS | IPv4 IN | IPv4 OUT | IPv6 IN | IPv6 OUT | NOTES |"
            echo "|---:|---:|:---:|:---:|:---|:---|:---:|:---:|:---:|:---:|:---|"
        else
            echo "| SERVICE | PORT | PROTO | RUNNING | IPv4 IN | IPv4 OUT | IPv6 IN | IPv6 OUT | NOTES |"
            echo "|---:|---:|:---:|:---:|:---:|:---:|:---:|:---:|:---|"
        fi
    elif [[ "$NFTBAN_PORT_OUTPUT_FORMAT" == "csv" ]]; then
        if (( NFTBAN_PORT_DETAILED )); then
            echo "SERVICE,PORT,PROTO,RUNNING,BIND,PROCESS,IPv4 IN,IPv4 OUT,IPv6 IN,IPv6 OUT,NOTES"
        else
            echo "SERVICE,PORT,PROTO,RUNNING,IPv4 IN,IPv4 OUT,IPv6 IN,IPv6 OUT,NOTES"
        fi
    fi

    # Parse filter ports if provided
    local -a filter_ports_arr=()
    if [[ -n "$NFTBAN_PORT_FILTER_PORTS" ]]; then
        IFS=',' read -ra filter_ports_arr <<< "$NFTBAN_PORT_FILTER_PORTS"
    fi

    # Sorted iteration
    local -a keys=()
    local k
    for k in "${!NFTBAN_PORT_SEEN[@]}"; do keys+=("$k"); done
    IFS=$'\n' read -r -d '' -a sorted < <(printf '%s\n' "${keys[@]}" | sort -t_ -k1n -k2 && printf '\0') || true

    local entry
    for entry in "${sorted[@]}"; do
        local port="${entry%%_*}" proto="${entry##*_}"

        # Filter (if any)
        if [[ ${#filter_ports_arr[@]} -gt 0 ]]; then
            local match=0 pf
            for pf in "${filter_ports_arr[@]}"; do
                [[ "$pf" == "$port" ]] && match=1
            done
            (( match == 1 )) || continue
        fi

        local svcinfo
        svcinfo="$(nftban_port_detect_service "$port" "$proto")"
        local svc running procinfo bind scope
        svc="$(cut -d'|' -f1 <<<"$svcinfo")"
        running="$(cut -d'|' -f2 <<<"$svcinfo")"
        procinfo="$(cut -d'|' -f3 <<<"$svcinfo")"
        bind="$(cut -d'|' -f4 <<<"$svcinfo")"
        scope="$(cut -d'|' -f5 <<<"$svcinfo")"

        # Show port if EITHER: (1) service is listening, OR (2) port is in firewall rules
        # This ensures user-added ports show up even if nothing is listening yet
        local in_firewall=false
        if [[ -n "${NFTBAN_PORT_NFT_GENERIC["${port}_${proto}_input"]+x}" ]] || \
           [[ -n "${NFTBAN_PORT_NFT_RULES["${port}_${proto}_input_ipv4"]+x}" ]] || \
           [[ -n "${NFTBAN_PORT_NFT_RULES["${port}_${proto}_input_ipv6"]+x}" ]]; then
            in_firewall=true
        fi

        # Skip only if: NOT listening AND NOT in firewall
        if [[ "$running" != "yes" ]] && [[ "$in_firewall" == "false" ]]; then
            continue
        fi

        # If --active flag set, skip ports without active services (hides passive FTP ranges etc.)
        if (( NFTBAN_PORT_ACTIVE_ONLY )) && [[ "$running" != "yes" ]]; then
            continue
        fi

        local status_line
        status_line="$(nftban_port_determine_status "$port" "$proto")"
        local v4in v4out v6in v6out notes
        v4in="$(cut -d'|' -f1 <<< "$status_line")"
        v4out="$(cut -d'|' -f2 <<< "$status_line")"
        v6in="$(cut -d'|' -f3 <<< "$status_line")"
        v6out="$(cut -d'|' -f4 <<< "$status_line")"
        notes="$(cut -d'|' -f5 <<< "$status_line")"
        [[ -n "$scope" ]] && notes="$(nftban_port_trim "$notes $scope")"

        # Populate array in caller scope (BUG-005 FIX - subshell can't modify parent arrays)
        NFTBAN_PORT_STATUS["${port}/${proto}/ipv4/in"]="$v4in"
        NFTBAN_PORT_STATUS["${port}/${proto}/ipv4/out"]="$v4out"
        NFTBAN_PORT_STATUS["${port}/${proto}/ipv6/in"]="$v6in"
        NFTBAN_PORT_STATUS["${port}/${proto}/ipv6/out"]="$v6out"

        badge() {
            case "$1" in
                Allowed) echo -e "${C_GREEN:-}✔${C_RESET:-}" ;;
                Blocked) echo -e "${C_RED:-}✖${C_RESET:-}" ;;
                "No-rule") echo -e "${C_YELLOW:-}−${C_RESET:-}" ;;
                Unknown) echo -e "${C_YELLOW:-}?${C_RESET:-}" ;;
                *) echo "$1" ;;
            esac
        }

        access_icon() {
            local scope_notes="$1"

            # If service not running, no access
            if [[ "$running" != "yes" ]]; then
                echo "−"
                return
            fi

            # If bound to localhost only, always local
            if [[ "$scope_notes" == *"LOCAL-ONLY"* ]] || [[ "$scope_notes" == *"local"* ]]; then
                echo "🔒 Local"
                return
            fi

            # If firewall explicitly allows (port in nftables sets), it's public
            if [[ "$v4in" == "Allowed" ]] || [[ "$v6in" == "Allowed" ]]; then
                echo "🌍 Public"
                return
            fi

            # Service is running, bound to public interface, but NOT in firewall allow list
            # This means default deny policy blocks it
            if [[ "$scope_notes" == *"PUBLIC"* ]] || [[ "$scope_notes" == *"public"* ]]; then
                echo "❌ Blocked"
                return
            fi

            # Fallback
            echo "−"
        }

        status_icon() {
            local run="$1"
            if [[ "$run" == "yes" ]]; then
                echo -e "${C_GREEN:-}✓ Running${C_RESET:-}"
            else
                echo -e "${C_YELLOW:-}− Stopped${C_RESET:-}"
            fi
        }

        # Add note if port is open but not listening
        if [[ "$running" != "yes" ]] && [[ "$in_firewall" == "true" ]]; then
            notes="$(nftban_port_trim "$notes OPEN-NO-LISTENER")"
        fi

        if [[ "$NFTBAN_PORT_OUTPUT_FORMAT" == "table" ]]; then
            local port_proto="${port}/${proto^^}"  # Combine port/proto as "22/TCP"
            local status_display access_display
            status_display="$(status_icon "$running")"
            access_display="$(access_icon "$notes")"

            if (( NFTBAN_PORT_DETAILED )); then
                printf "%-12s %-10s %-10s %-12s %-20s %-9s %-9s %-9s %-9s %-12s\n" \
                    "$port_proto" "$svc" "$status_display" "${bind:-?}" "${procinfo:-?}" \
                    "$(badge "$v4in")" "$(badge "$v4out")" "$(badge "$v6in")" "$(badge "$v6out")" "$access_display"
            else
                printf "%-12s %-10s %-10s %-9s %-9s %-9s %-9s %-12s\n" \
                    "$port_proto" "$svc" "$status_display" \
                    "$(badge "$v4in")" "$(badge "$v4out")" "$(badge "$v6in")" "$(badge "$v6out")" "$access_display"
            fi
        elif [[ "$NFTBAN_PORT_OUTPUT_FORMAT" == "md" ]]; then
            if (( NFTBAN_PORT_DETAILED )); then
                printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n" \
                    "$svc" "$port" "$proto" "$running" "${bind:-?}" "${procinfo:-?}" \
                    "$v4in" "$v4out" "$v6in" "$v6out" "$(nftban_port_trim "$notes")"
            else
                printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n" \
                    "$svc" "$port" "$proto" "$running" "$v4in" "$v4out" "$v6in" "$v6out" "$(nftban_port_trim "$notes")"
            fi
        else # csv
            if (( NFTBAN_PORT_DETAILED )); then
                printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
                    "$svc" "$port" "$proto" "$running" "\"${bind:-}\"" "\"${procinfo:-}\"" \
                    "$v4in" "$v4out" "$v6in" "$v6out" "\"$(nftban_port_trim "$notes")\""
            else
                printf "%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
                    "$svc" "$port" "$proto" "$running" "$v4in" "$v4out" "$v6in" "$v6out" "\"$(nftban_port_trim "$notes")\""
            fi
        fi
    done

    if [[ "$NFTBAN_PORT_OUTPUT_FORMAT" == "table" ]]; then
        echo
        echo "Firewall Rules:"
        echo -e "  ${C_GREEN:-}✔${C_RESET:-} Allowed   ${C_RED:-}✖${C_RESET:-} Blocked   ${C_YELLOW:-}−${C_RESET:-} No-rule"
        echo
        echo "Access:"
        echo "  🌍 Public   - Accessible from internet"
        echo "  🔒 Local    - Localhost only"
        echo "  ❌ Blocked  - Firewall blocked"
        echo
    fi
}

# =============================================================================
# HTML REPORT GENERATION
# =============================================================================

nftban_port_generate_html_report() {
    # Generate HTML report from port data
    # Returns: Path to generated HTML file

    local template_path="${NFTBAN_TEMPLATE_DIR:-/usr/share/nftban/templates}/reports/port_report.html"
    local report_dir="${NFTBAN_REPORT_DIR:-/var/lib/nftban/reports}"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local report_file="${report_dir}/port_report_${timestamp}.html"

    # Ensure report directory exists
    mkdir -p "$report_dir" 2>/dev/null || true

    # Check if template exists
    if [[ ! -f "$template_path" ]]; then
        echo "ERROR: Template not found: $template_path" >&2
        return 1
    fi

    # Gather data if not already gathered
    if [[ ${#NFTBAN_PORT_LISTENERS[@]} -eq 0 ]]; then
        nftban_port_gather_listeners
        nftban_port_gather_nft_rules
    fi

    # Calculate statistics
    local total_ports=${#NFTBAN_PORT_LISTENERS[@]}
    local running_services=0
    local public_ports=0
    local local_ports=0

    for key in "${!NFTBAN_PORT_LISTENERS[@]}"; do
        IFS='/' read -r port proto <<< "$key"
        local bind="${NFTBAN_PORT_BIND_ADDR[$key]:-unknown}"

        [[ "$bind" != "-" ]] && running_services=$((running_services + 1)) || true

        if [[ "$bind" == "0.0.0.0" ]] || [[ "$bind" == "::" ]] || [[ "$bind" == "*" ]]; then
            public_ports=$((public_ports + 1)) || true
        elif [[ "$bind" != "-" ]]; then
            local_ports=$((local_ports + 1)) || true
        fi
    done

    # Generate HTML table rows
    local table_rows=""
    for key in $(printf '%s\n' "${!NFTBAN_PORT_LISTENERS[@]}" | sort -t'/' -k1 -n); do
        IFS='/' read -r port proto <<< "$key"

        local service="${NFTBAN_PORT_SERVICE_MAP[$port]:-unknown}"
        local process="${NFTBAN_PORT_LISTENERS[$key]:-}"
        local bind="${NFTBAN_PORT_BIND_ADDR[$key]:-}"

        # Get firewall status
        local ipv4_in="${NFTBAN_PORT_STATUS["${port}/${proto}/ipv4/in"]:-?}"
        local ipv4_out="${NFTBAN_PORT_STATUS["${port}/${proto}/ipv4/out"]:-?}"
        local ipv6_in="${NFTBAN_PORT_STATUS["${port}/${proto}/ipv6/in"]:-?}"
        local ipv6_out="${NFTBAN_PORT_STATUS["${port}/${proto}/ipv6/out"]:-?}"

        # Status badges
        local status_badge="<span class=\"badge badge-stopped\">Stopped</span>"
        [[ -n "$process" && "$process" != "-" ]] && status_badge="<span class=\"badge badge-running\">Running</span>"

        # Bind badge
        local bind_badge="-"
        if [[ "$bind" == "0.0.0.0" ]] || [[ "$bind" == "::" ]] || [[ "$bind" == "*" ]]; then
            bind_badge="<span class=\"badge badge-public\">PUBLIC</span>"
        elif [[ -n "$bind" && "$bind" != "-" ]]; then
            bind_badge="<span class=\"badge badge-local\">LOCAL</span>"
        fi

        # Status cells with colors
        local ipv4_in_html
        ipv4_in_html="<span class=\"status-${ipv4_in}\">$(nftban_port_status_symbol "$ipv4_in")</span>"
        local ipv4_out_html
        ipv4_out_html="<span class=\"status-${ipv4_out}\">$(nftban_port_status_symbol "$ipv4_out")</span>"
        local ipv6_in_html
        ipv6_in_html="<span class=\"status-${ipv6_in}\">$(nftban_port_status_symbol "$ipv6_in")</span>"
        local ipv6_out_html
        ipv6_out_html="<span class=\"status-${ipv6_out}\">$(nftban_port_status_symbol "$ipv6_out")</span>"

        table_rows+="                <tr>
                    <td>${service}</td>
                    <td><strong>${port}</strong></td>
                    <td>${proto}</td>
                    <td>${status_badge}</td>
                    <td>${ipv4_in_html}</td>
                    <td>${ipv4_out_html}</td>
                    <td>${ipv6_in_html}</td>
                    <td>${ipv6_out_html}</td>
                    <td>${bind_badge}</td>
                    <td class=\"perm-text\">${process:-N/A}</td>
                    <td>-</td>
                </tr>
"
    done

    # Read template
    local html_content
    html_content=$(cat "$template_path")

    # Get system info
    local hostname
    hostname=$(hostname -f 2>/dev/null || hostname)
    local server_ip
    server_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "N/A")
    local current_date
    current_date=$(date +%Y-%m-%d)
    local current_time
    current_time=$(date +%H:%M:%S)

    # Substitute placeholders
    html_content="${html_content//\{HOSTNAME\}/$hostname}"
    html_content="${html_content//\{SERVER_IP\}/$server_ip}"
    html_content="${html_content//\{DATE\}/$current_date}"
    html_content="${html_content//\{TIME\}/$current_time}"
    html_content="${html_content//\{NFTBAN_VERSION\}/${NFTBAN_VERSION:-unknown}}"
    html_content="${html_content//\{COMPANY_NAME\}/${NFTBAN_COMPANY_NAME:-}}"
    html_content="${html_content//\{LOGO_HTML\}/}"
    html_content="${html_content//\{VERSION_HTML\}/<p>Version: <strong>${NFTBAN_VERSION:-unknown}</strong></p>}"

    # Statistics
    html_content="${html_content//\{TOTAL_PORTS\}/$total_ports}"
    html_content="${html_content//\{RUNNING_SERVICES\}/$running_services}"
    html_content="${html_content//\{PUBLIC_PORTS\}/$public_ports}"
    html_content="${html_content//\{LOCAL_PORTS\}/$local_ports}"

    # Table rows
    html_content="${html_content//\{PORT_TABLE_ROWS\}/$table_rows}"

    # Warnings section (empty for now)
    html_content="${html_content//\{WARNINGS_SECTION\}/}"

    # Write HTML file
    echo "$html_content" > "$report_file"

    # Set permissions
    chmod 640 "$report_file" 2>/dev/null || true

    echo "$report_file"
}

nftban_port_status_symbol() {
    # Convert status to symbol for HTML
    case "$1" in
        allowed) echo "✔ Allowed" ;;
        blocked) echo "✖ Blocked" ;;
        no-rule) echo "? No-Rule" ;;
        *) echo "? Unknown" ;;
    esac
}

# =============================================================================
# MAIN REPORT FUNCTION
# =============================================================================

nftban_port_report_status() {
    # Main function to generate port status report
    # Called by CLI handler

    # Gather data
    nftban_port_gather_listeners
    nftban_port_gather_nft_rules

    # Render report
    nftban_port_render_table

    # Explicitly return success
    return 0
}

# =============================================================================
# MODULE FOOTER
# =============================================================================

# Module loaded notification (only in debug mode)
if [[ "${NFTBAN_DEBUG_MODE:-false}" == "true" ]]; then
    if type -t nftban_module_loaded >/dev/null 2>&1; then
        nftban_module_loaded "nftban_report_port" "1.0.0" "Port Report Core" "core" "bash,ss,nft"
    fi
fi
