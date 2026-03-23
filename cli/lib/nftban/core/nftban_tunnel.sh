#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.30.0 - Tunnel Suspicion Scoring Engine
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Compute DNS tunnel suspicion scores from parsed DNS logs
#
# meta:name="nftban_tunnel"
# meta:type="lib"
# meta:header="Tunnel Suspicion Scoring Engine"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="DNS tunnel suspicion scoring engine — advisory only, never bans"
# meta:depends="nftban_tunnel_parsers.sh"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/conf.d/tunnel/main.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2026-03-21"
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_NFTBAN_TUNNEL_LOADED:-}" ]] && return 0
readonly _NFTBAN_TUNNEL_LOADED=1

# =============================================================================
# LOAD DEPENDENCIES
# =============================================================================

[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

# Load parsers
# shellcheck source=/dev/null
if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_tunnel_parsers.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/core/nftban_tunnel_parsers.sh" || return 1
fi

# =============================================================================
# LOAD CONFIGURATION
# =============================================================================

nftban_tunnel_load_config() {
    # Load tunnel configuration from conf files
    # shellcheck source=/dev/null
    if [[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/tunnel/main.conf" ]]; then
        source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/tunnel/main.conf" || true
    fi
    # .local override
    # shellcheck source=/dev/null
    if [[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/tunnel/main.conf.local" ]]; then
        source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/tunnel/main.conf.local" || true
    fi
}

# =============================================================================
# ENTROPY CALCULATOR (pure bash — no external deps)
# =============================================================================

_tunnel_shannon_entropy() {
    # Calculate Shannon entropy of a string (bits per character)
    # Uses awk for floating point math
    # Args: $1 = string
    # Returns: entropy value via stdout (e.g., "3.72")
    local str="$1"
    local len=${#str}

    if [[ $len -eq 0 ]]; then
        echo "0"
        return
    fi

    echo "$str" | awk -v len="$len" '
    BEGIN {
        # Count character frequencies
        split("", freq)
    }
    {
        n = split($0, chars, "")
        for (i = 1; i <= n; i++) {
            freq[chars[i]]++
        }
    }
    END {
        entropy = 0.0
        for (c in freq) {
            p = freq[c] / len
            if (p > 0) {
                entropy -= p * (log(p) / log(2))
            }
        }
        printf "%.2f", entropy
    }'
}

_tunnel_label_entropy() {
    # Calculate entropy of the labels (subdomains) of a FQDN
    # Strips the TLD+SLD (last 2 labels) and computes entropy of the rest
    # Args: $1 = FQDN (e.g., "aGVsbG8.data.tunnel.example.com")
    # Returns: entropy value via stdout
    local fqdn="$1"

    # Remove trailing dot if present
    fqdn="${fqdn%.}"

    # Split into labels
    local IFS='.'
    local -a labels
    read -ra labels <<< "$fqdn"
    local count=${#labels[@]}

    # Need at least 3 labels (subdomain.domain.tld)
    if [[ $count -lt 3 ]]; then
        echo "0"
        return
    fi

    # Concatenate all labels except the last 2 (domain.tld)
    local payload=""
    for ((i = 0; i < count - 2; i++)); do
        payload+="${labels[$i]}"
    done

    if [[ -z "$payload" ]]; then
        echo "0"
        return
    fi

    _tunnel_shannon_entropy "$payload"
}

# =============================================================================
# SIGNAL COMPUTATION
# =============================================================================
# Each signal function takes aggregated data and returns a raw value.
# The scoring engine normalizes these to 0-100 and applies weights.

nftban_tunnel_compute_signals() {
    # Compute all 5 signals for a single source IP from parsed DNS records.
    # Input: file of parsed records (SOURCE_IP|QNAME|QTYPE|RCODE) for ONE source IP
    # Output: signal values as pipe-delimited string:
    #   AVG_ENTROPY|TXT_RATIO|MAX_DEPTH|QUERY_COUNT|NXDOMAIN_RATIO
    local records_file="$1"

    if [[ ! -f "$records_file" || ! -s "$records_file" ]]; then
        echo "0:0:0:0:0"
        return
    fi

    awk -F'|' '
    BEGIN {
        total = 0
        txt_count = 0
        nxdomain_count = 0
        max_depth = 0
        total_entropy = 0.0
        entropy_count = 0
    }
    {
        total++
        qname = $2
        qtype = $3
        rcode = $4

        # Signal 2: TXT frequency
        if (toupper(qtype) == "TXT") txt_count++

        # Signal 5: NXDOMAIN ratio
        if (toupper(rcode) == "NXDOMAIN") nxdomain_count++

        # Signal 3: Subdomain depth
        # Count dots = number of labels - 1
        n = split(qname, parts, ".")
        # Remove trailing empty element from FQDN with trailing dot
        if (parts[n] == "") n--
        # Depth = labels minus domain.tld (2)
        depth = n - 2
        if (depth < 0) depth = 0
        if (depth > max_depth) max_depth = depth

        # Signal 1: Label entropy (computed on subdomain labels only)
        # Concatenate labels except last 2
        if (n > 2) {
            payload = ""
            for (i = 1; i <= n - 2; i++) {
                payload = payload parts[i]
            }
            # Shannon entropy of payload
            plen = length(payload)
            if (plen > 0) {
                split("", freq)
                for (i = 1; i <= plen; i++) {
                    c = substr(payload, i, 1)
                    freq[c]++
                }
                ent = 0.0
                for (c in freq) {
                    p = freq[c] / plen
                    if (p > 0) {
                        ent -= p * (log(p) / log(2))
                    }
                }
                total_entropy += ent
                entropy_count++
            }
        }
    }
    END {
        if (total == 0) {
            print "0:0:0:0:0"
            exit
        }

        avg_entropy = (entropy_count > 0) ? total_entropy / entropy_count : 0
        txt_ratio = txt_count / total
        nxdomain_ratio = nxdomain_count / total

        printf "%.2f:%.4f:%d:%d:%.4f\n", avg_entropy, txt_ratio, max_depth, total, nxdomain_ratio
    }
    ' "$records_file"
}

# =============================================================================
# SCORING ENGINE
# =============================================================================

nftban_tunnel_score_ip() {
    # Compute composite suspicion score for a source IP.
    # Args: $1 = signal_string "AVG_ENTROPY:TXT_RATIO:MAX_DEPTH:QUERY_COUNT:NXDOMAIN_RATIO"
    # Returns: composite score (0-100) via stdout
    local signals="$1"

    # Load thresholds from config (with defaults)
    local entropy_thresh="${NFTBAN_TUNNEL_ENTROPY_THRESHOLD:-3.5}"
    local txt_thresh="${NFTBAN_TUNNEL_TXT_RATIO_THRESHOLD:-0.15}"
    local depth_thresh="${NFTBAN_TUNNEL_SUBDOMAIN_DEPTH_THRESHOLD:-4}"
    local volume_thresh="${NFTBAN_TUNNEL_QUERY_VOLUME_THRESHOLD:-100}"
    local nxdomain_thresh="${NFTBAN_TUNNEL_NXDOMAIN_RATIO_THRESHOLD:-0.20}"

    # Load weights from config (with defaults, must sum to 100)
    local w_entropy="${NFTBAN_TUNNEL_WEIGHT_ENTROPY:-25}"
    local w_txt="${NFTBAN_TUNNEL_WEIGHT_TXT_FREQ:-20}"
    local w_depth="${NFTBAN_TUNNEL_WEIGHT_SUBDOMAIN_DEPTH:-20}"
    local w_volume="${NFTBAN_TUNNEL_WEIGHT_QUERY_VOLUME:-20}"
    local w_nxdomain="${NFTBAN_TUNNEL_WEIGHT_NXDOMAIN_RATIO:-15}"

    echo "$signals" | awk -F':' \
        -v entropy_thresh="$entropy_thresh" \
        -v txt_thresh="$txt_thresh" \
        -v depth_thresh="$depth_thresh" \
        -v volume_thresh="$volume_thresh" \
        -v nxdomain_thresh="$nxdomain_thresh" \
        -v w_entropy="$w_entropy" \
        -v w_txt="$w_txt" \
        -v w_depth="$w_depth" \
        -v w_volume="$w_volume" \
        -v w_nxdomain="$w_nxdomain" \
    '{
        avg_entropy = $1 + 0
        txt_ratio = $2 + 0
        max_depth = $3 + 0
        query_count = $4 + 0
        nxdomain_ratio = $5 + 0

        # Normalize each signal to 0-100 using threshold as midpoint
        # Formula: min(100, (value / threshold) * 50)
        # At threshold = 50, at 2x threshold = 100

        if (entropy_thresh > 0)
            s_entropy = (avg_entropy / entropy_thresh) * 50
        else
            s_entropy = 0

        if (txt_thresh > 0)
            s_txt = (txt_ratio / txt_thresh) * 50
        else
            s_txt = 0

        if (depth_thresh > 0)
            s_depth = (max_depth / depth_thresh) * 50
        else
            s_depth = 0

        if (volume_thresh > 0)
            s_volume = (query_count / volume_thresh) * 50
        else
            s_volume = 0

        if (nxdomain_thresh > 0)
            s_nxdomain = (nxdomain_ratio / nxdomain_thresh) * 50
        else
            s_nxdomain = 0

        # Clamp each to [0, 100]
        if (s_entropy > 100) s_entropy = 100
        if (s_txt > 100) s_txt = 100
        if (s_depth > 100) s_depth = 100
        if (s_volume > 100) s_volume = 100
        if (s_nxdomain > 100) s_nxdomain = 100

        # Weighted sum
        total_weight = w_entropy + w_txt + w_depth + w_volume + w_nxdomain
        if (total_weight == 0) total_weight = 100

        score = (s_entropy * w_entropy + s_txt * w_txt + s_depth * w_depth + s_volume * w_volume + s_nxdomain * w_nxdomain) / total_weight

        # Clamp to [0, 100]
        if (score > 100) score = 100
        if (score < 0) score = 0

        printf "%d\n", score
    }'
}

nftban_tunnel_score_level() {
    # Convert numeric score to suspicion level string
    # Args: $1 = score (0-100)
    # Returns: NONE, LOW, MEDIUM, or HIGH
    local score="${1:-0}"
    local thresh_low="${NFTBAN_TUNNEL_THRESHOLD_LOW:-30}"
    local thresh_med="${NFTBAN_TUNNEL_THRESHOLD_MEDIUM:-60}"
    local thresh_high="${NFTBAN_TUNNEL_THRESHOLD_HIGH:-80}"

    # Guard against empty or non-numeric score
    [[ ! "$score" =~ ^[0-9]+$ ]] && score=0

    if [[ "$score" -ge "$thresh_high" ]]; then
        echo "HIGH"
    elif [[ "$score" -ge "$thresh_med" ]]; then
        echo "MEDIUM"
    elif [[ "$score" -ge "$thresh_low" ]]; then
        echo "LOW"
    else
        echo "NONE"
    fi
}

# =============================================================================
# EXCLUSION CHECKS
# =============================================================================

_tunnel_is_excluded_domain() {
    # Check if a domain matches exclusion patterns
    # Args: $1 = domain
    # Returns: 0 if excluded, 1 if not
    local domain="$1"
    local excludes="${NFTBAN_TUNNEL_EXCLUDE_DOMAINS:-}"

    [[ -z "$excludes" ]] && return 1

    local IFS=','
    local -a patterns
    read -ra patterns <<< "$excludes"
    for pattern in "${patterns[@]}"; do
        pattern=$(echo "$pattern" | xargs)  # trim whitespace
        # shellcheck disable=SC2254
        case "$domain" in
            $pattern) return 0 ;;
        esac
    done
    return 1
}

_tunnel_is_excluded_ip() {
    # Check if an IP matches exclusion list
    # Args: $1 = IP
    # Returns: 0 if excluded, 1 if not
    local ip="$1"
    local excludes="${NFTBAN_TUNNEL_EXCLUDE_IPS:-}"

    [[ -z "$excludes" ]] && return 1

    local IFS=','
    local -a entries
    read -ra entries <<< "$excludes"
    for entry in "${entries[@]}"; do
        entry=$(echo "$entry" | xargs)  # trim whitespace
        # Exact match (CIDR matching would need ipcalc — keep simple)
        if [[ "$ip" == "$entry" ]]; then
            return 0
        fi
    done
    return 1
}

# =============================================================================
# STATE MANAGEMENT
# =============================================================================

nftban_tunnel_state_dir() {
    echo "${NFTBAN_TUNNEL_STATE_DIR:-/var/lib/nftban/tunnel}"
}

nftban_tunnel_save_score() {
    # Save score for an IP to state directory
    # Args: $1=ip, $2=score, $3=signals, $4=level, $5=timestamp
    local ip="$1" score="$2" signals="$3" level="$4" ts="$5"
    local state_dir
    state_dir=$(nftban_tunnel_state_dir)
    mkdir -p "$state_dir" 2>/dev/null || true

    # Sanitize IP for filename (replace : with _)
    local safe_ip="${ip//:/_}"

    # Write state file: timestamp|score|level|signals
    echo "${ts}|${score}|${level}|${signals}" > "${state_dir}/${safe_ip}.state"
}

nftban_tunnel_load_scores() {
    # Load all scored IPs from state directory
    # Output: IP|SCORE|LEVEL|SIGNALS|TIMESTAMP (one per line, sorted by score desc)
    local state_dir
    state_dir=$(nftban_tunnel_state_dir)

    [[ ! -d "$state_dir" ]] && return 0

    local now
    now=$(date +%s)
    local ttl_sec=$(( ${NFTBAN_TUNNEL_STATE_TTL:-24} * 3600 ))

    for state_file in "${state_dir}"/*.state; do
        [[ ! -f "$state_file" ]] && continue
        local basename
        basename=$(basename "$state_file" .state)
        # Restore IP (replace _ back to :)
        local ip="${basename//_/:}"

        local line
        line=$(head -1 "$state_file" 2>/dev/null)
        [[ -z "$line" ]] && continue

        local ts score level signals
        IFS='|' read -r ts score level signals <<< "$line"

        # TTL check — expire old entries
        if [[ $(( now - ts )) -gt $ttl_sec ]]; then
            rm -f "$state_file"
            continue
        fi

        echo "${ip}|${score}|${level}|${signals}|${ts}"
    done | sort -t'|' -k2 -rn
}

nftban_tunnel_cleanup_state() {
    # Remove expired state files
    local state_dir
    state_dir=$(nftban_tunnel_state_dir)
    [[ ! -d "$state_dir" ]] && return 0

    local now
    now=$(date +%s)
    local ttl_sec=$(( ${NFTBAN_TUNNEL_STATE_TTL:-24} * 3600 ))
    local max_ips="${NFTBAN_TUNNEL_MAX_TRACKED_IPS:-1000}"
    local count=0

    for state_file in "${state_dir}"/*.state; do
        [[ ! -f "$state_file" ]] && continue
        count=$((count + 1))

        local line ts
        line=$(head -1 "$state_file" 2>/dev/null)
        ts=$(echo "$line" | cut -d'|' -f1)

        if [[ $(( now - ${ts:-0} )) -gt $ttl_sec ]]; then
            rm -f "$state_file"
            count=$((count - 1))
        fi
    done

    # If still over max, remove oldest
    if [[ $count -gt $max_ips ]]; then
        ls -t "${state_dir}"/*.state 2>/dev/null | tail -n +$((max_ips + 1)) | xargs -r rm -f
    fi
}

# =============================================================================
# MAIN SCAN FUNCTION
# =============================================================================

nftban_tunnel_scan() {
    # Run a complete tunnel suspicion scan.
    # 1. Detect DNS source
    # 2. Parse recent logs
    # 3. Compute signals per source IP
    # 4. Score each IP
    # 5. Save state
    # 6. Log results
    # Args: --quiet (optional, for timer mode)
    local quiet=false
    [[ "${1:-}" == "--quiet" ]] && quiet=true

    local log_file="${NFTBAN_TUNNEL_LOG:-/var/log/nftban/tunnel.log}"
    local ts
    ts=$(date +%s)
    local ts_human
    ts_human=$(date '+%Y-%m-%d %H:%M:%S')

    # Ensure log directory exists
    mkdir -p "$(dirname "$log_file")" 2>/dev/null || true

    # Check if enabled
    if [[ "${NFTBAN_TUNNEL_ENABLED:-NO}" != "YES" ]]; then
        [[ "$quiet" == "false" ]] && echo "Tunnel suspicion module is DISABLED"
        return 0
    fi

    # Detect DNS source (v1.38.0: BUG-005 — improved messaging)
    if ! nftban_tunnel_detect_dns_source; then
        local msg="$ts_human|WARN|No local DNS resolver detected — cannot scan (no query logs available)"
        echo "$msg" >> "$log_file" 2>/dev/null || true
        if [[ "$quiet" == "false" ]]; then
            echo "WARNING: No local DNS resolver detected (bind, unbound, dnsmasq, systemd-resolved)"
            echo ""
            echo "  Tunnel suspicion scoring requires DNS query logs from a local resolver."
            echo "  Your server uses external resolvers directly — no query logs available."
            # Show resolvers from resolv.conf for context
            local resolvers
            resolvers=$(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | tr '\n' ', ' | sed 's/,$//')
            [[ -n "$resolvers" ]] && echo "  Current resolvers: ${resolvers}"
            echo ""
            echo "  To use tunnel scanning, install a local resolver:"
            echo "    apt install unbound   # or: yum install unbound"
            echo "  Then: nftban tunnel enable"
        fi
        return 1
    fi

    [[ "$quiet" == "false" ]] && echo "Scanning DNS logs from: ${TUNNEL_DNS_TYPE} (${TUNNEL_DNS_LOG_PATH})"

    # Calculate since timestamp (last scan interval)
    local interval="${NFTBAN_TUNNEL_SCAN_INTERVAL:-5}"
    local since_ts=$((ts - interval * 60))

    # Parse DNS logs into temp file
    local tmp_dir
    tmp_dir=$(mktemp -d /tmp/nftban-tunnel.XXXXXX)
    # Clean up temp dir on exit — use RETURN trap to avoid clobbering caller's EXIT trap
    trap 'rm -rf "$tmp_dir"' RETURN

    local all_records="${tmp_dir}/all_records.txt"
    nftban_tunnel_parse_dns_logs "$TUNNEL_DNS_TYPE" "$TUNNEL_DNS_LOG_PATH" "$since_ts" > "$all_records" 2>/dev/null || true

    local total_records
    total_records=$(wc -l < "$all_records" 2>/dev/null || echo "0")

    if [[ "$total_records" -eq 0 ]]; then
        [[ "$quiet" == "false" ]] && echo "No DNS queries found in scan interval"
        echo "$ts_human|INFO|Scan complete — 0 queries found" >> "$log_file" 2>/dev/null || true
        return 0
    fi

    [[ "$quiet" == "false" ]] && echo "Parsed $total_records DNS queries"

    # Filter excluded domains before splitting by IP
    if [[ -n "${NFTBAN_TUNNEL_EXCLUDE_DOMAINS:-}" ]]; then
        local filtered="${tmp_dir}/filtered.txt"
        while IFS='|' read -r src_ip qname qtype rcode; do
            if ! _tunnel_is_excluded_domain "$qname"; then
                echo "${src_ip}|${qname}|${qtype}|${rcode}"
            fi
        done < "$all_records" > "$filtered"
        mv "$filtered" "$all_records"
        total_records=$(wc -l < "$all_records" 2>/dev/null || echo "0")
    fi

    # Split records by source IP
    awk -F'|' '{print > ("'"$tmp_dir"'/" $1 ".records")}' "$all_records"

    # Score each source IP
    local scored=0 high_count=0 medium_count=0 low_count=0
    local state_dir
    state_dir=$(nftban_tunnel_state_dir)
    mkdir -p "$state_dir" 2>/dev/null || true

    for ip_file in "${tmp_dir}"/*.records; do
        [[ ! -f "$ip_file" ]] && continue
        local ip
        ip=$(basename "$ip_file" .records)

        # Skip excluded IPs
        if _tunnel_is_excluded_ip "$ip"; then
            continue
        fi

        # Compute signals
        local signals
        signals=$(nftban_tunnel_compute_signals "$ip_file")

        # Score
        local score
        score=$(nftban_tunnel_score_ip "$signals")

        # Level
        local level
        level=$(nftban_tunnel_score_level "$score")

        # Save state (even for NONE — allows tracking)
        nftban_tunnel_save_score "$ip" "$score" "$signals" "$level" "$ts"

        scored=$((scored + 1))

        case "$level" in
            HIGH)
                high_count=$((high_count + 1))
                echo "$ts_human|HIGH|ip=$ip score=$score signals=$signals" >> "$log_file" 2>/dev/null || true
                [[ "$quiet" == "false" ]] && printf "  HIGH  %-40s score=%d\n" "$ip" "$score"
                ;;
            MEDIUM)
                medium_count=$((medium_count + 1))
                echo "$ts_human|MEDIUM|ip=$ip score=$score signals=$signals" >> "$log_file" 2>/dev/null || true
                [[ "$quiet" == "false" ]] && printf "  MED   %-40s score=%d\n" "$ip" "$score"
                ;;
            LOW)
                low_count=$((low_count + 1))
                ;;
        esac
    done

    # Cleanup old state
    nftban_tunnel_cleanup_state

    # Summary log
    echo "$ts_human|INFO|Scan complete — $total_records queries, $scored IPs scored, HIGH=$high_count MED=$medium_count LOW=$low_count" >> "$log_file" 2>/dev/null || true

    if [[ "$quiet" == "false" ]]; then
        echo ""
        echo "Scan complete: $scored IPs scored"
        echo "  HIGH=$high_count  MEDIUM=$medium_count  LOW=$low_count"
    fi

    # Alert on HIGH if configured
    if [[ "$high_count" -gt 0 && "${NFTBAN_TUNNEL_ALERT_ON_HIGH:-YES}" == "YES" ]]; then
        _tunnel_maybe_alert "$high_count" "$ts"
    fi

    return 0
}

_tunnel_maybe_alert() {
    # Send alert if cooldown has elapsed
    local high_count="$1"
    local ts="$2"
    local state_dir
    state_dir=$(nftban_tunnel_state_dir)
    local cooldown_file="${state_dir}/.last_alert"
    local cooldown="${NFTBAN_TUNNEL_ALERT_COOLDOWN:-3600}"

    if [[ -f "$cooldown_file" ]]; then
        local last_alert
        last_alert=$(cat "$cooldown_file" 2>/dev/null || echo "0")
        if [[ $((ts - last_alert)) -lt $cooldown ]]; then
            return 0  # Still in cooldown
        fi
    fi

    # Record alert time
    echo "$ts" > "$cooldown_file" 2>/dev/null || true

    # Try to send alert email
    local alert_email="${NFTBAN_TUNNEL_ALERT_EMAIL:-}"
    [[ -z "$alert_email" ]] && alert_email="${NFTBAN_ALERT_EMAIL:-}"
    if [[ -n "$alert_email" ]]; then
        local hostname
        hostname=$(hostname -f 2>/dev/null || hostname)
        {
            echo "Subject: [NFTBan] DNS Tunnel Suspicion — $high_count HIGH on $hostname"
            echo ""
            echo "NFTBan Tunnel Suspicion Module detected $high_count HIGH-suspicion source(s)."
            echo "This is advisory-only — no IPs have been blocked."
            echo ""
            echo "Run 'nftban tunnel top' on $hostname for details."
            echo ""
            echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
        } | sendmail "$alert_email" 2>/dev/null || true
    fi
}

# Export functions
export -f nftban_tunnel_load_config
export -f nftban_tunnel_compute_signals
export -f nftban_tunnel_score_ip
export -f nftban_tunnel_score_level
export -f nftban_tunnel_scan
export -f nftban_tunnel_save_score
export -f nftban_tunnel_load_scores
export -f nftban_tunnel_cleanup_state
export -f nftban_tunnel_state_dir
