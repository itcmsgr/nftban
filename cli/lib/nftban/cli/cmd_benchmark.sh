#!/usr/bin/env bash
# =============================================================================
# NFTBan - Benchmark Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Performance benchmarking of NFTBan components
#
# meta:name="cmd_benchmark"
# meta:type="cli"
# meta:header="Benchmark Command"
# meta:version="1.43.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
# meta:description="IPC latency, nft operations timing, set sizes"
# meta:inventory.files=""
# meta:inventory.binaries="nft,nftban-core"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="nftban"
#
# meta:created_date="2026-03-27"
# meta:updated_date="2026-03-27"
# =============================================================================
set -Eeuo pipefail

# Prevent double-loading
[[ -n "${CMD_BENCHMARK_LOADED:-}" ]] && return 0

# Load common CLI helpers
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/cmd_common.sh" || return 1

cmd_init

readonly CMD_BENCHMARK_LOADED=1

# =============================================================================
# COMMAND HANDLER
# =============================================================================

nftban_cmd_benchmark() {
    # Run performance benchmarks
    # Usage: nftban benchmark [ipc|nft|sets|all] [--json] [--iterations N]

    local what="${1:-all}"
    local json_mode=false
    local iterations=10

    # Check for help first
    cmd_wants_help "$@" && { _benchmark_usage; return 0; }

    # Parse arguments
    shift || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json|-j) json_mode=true; shift ;;
            --iterations|-n) iterations="$2"; shift 2 ;;
            help|-h|--help) _benchmark_usage; return 0 ;;
            *) shift ;;
        esac
    done

    if [[ "$json_mode" != "true" ]]; then
        echo "NFTBan Performance Benchmark"
        echo "============================"
        echo "Iterations: $iterations"
        echo ""
    fi

    local results="{}"

    case "$what" in
        ipc)    results=$(_bench_ipc "$iterations" "$json_mode") ;;
        nft)    results=$(_bench_nft "$iterations" "$json_mode") ;;
        sets)   results=$(_bench_sets "$json_mode") ;;
        all)
            local ipc_r nft_r sets_r
            ipc_r=$(_bench_ipc "$iterations" "true")
            nft_r=$(_bench_nft "$iterations" "true")
            sets_r=$(_bench_sets "true")
            results=$(jq -n \
                --argjson ipc "$ipc_r" \
                --argjson nft "$nft_r" \
                --argjson sets "$sets_r" \
                '{ipc: $ipc, nft: $nft, sets: $sets}' 2>/dev/null || echo '{}')

            if [[ "$json_mode" != "true" ]]; then
                echo "$results" | jq -r '
                    "IPC Benchmark:",
                    "  Status latency:  \(.ipc.status_latency_ms // "N/A") ms (avg)",
                    "  Ban latency:     \(.ipc.ban_latency_ms // "N/A") ms (avg)",
                    "",
                    "NFT Benchmark:",
                    "  List ruleset:    \(.nft.list_ruleset_ms // "N/A") ms (avg)",
                    "  Add element:     \(.nft.add_element_ms // "N/A") ms (avg)",
                    "  Delete element:  \(.nft.delete_element_ms // "N/A") ms (avg)",
                    "",
                    "Set Sizes:",
                    (.sets | to_entries[] | "  \(.key): \(.value) elements")
                ' 2>/dev/null || echo "$results"
                return 0
            fi
            ;;
        *)
            echo "ERROR: Unknown benchmark target: $what" >&2
            echo "Valid targets: ipc, nft, sets, all" >&2
            return 1
            ;;
    esac

    if [[ "$json_mode" == "true" ]]; then
        echo "$results"
    fi
}

# =============================================================================
# IPC BENCHMARK
# =============================================================================

_bench_ipc() {
    local iterations="$1" json_mode="$2"

    # Load IPC module
    if ! declare -f nft_ipc_status >/dev/null 2>&1; then
        if [[ -f "${NFTBAN_LIB_DIR}/lib/nft_ipc.sh" ]]; then
            # shellcheck source=/dev/null
            source "${NFTBAN_LIB_DIR}/lib/nft_ipc.sh" || true
        fi
    fi

    local total_ms=0
    local success=0
    local i

    for ((i=1; i<=iterations; i++)); do
        local start_ns end_ns elapsed_ms
        start_ns=$(date +%s%N 2>/dev/null || echo 0)
        if nft_ipc_status &>/dev/null; then
            end_ns=$(date +%s%N 2>/dev/null || echo 0)
            elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
            total_ms=$((total_ms + elapsed_ms))
            ((success++)) || true
        fi
    done

    local avg_ms=0
    [[ $success -gt 0 ]] && avg_ms=$((total_ms / success))

    if [[ "$json_mode" != "true" ]]; then
        echo "[IPC Benchmark]"
        echo "  Status calls:    $success/$iterations succeeded"
        echo "  Avg latency:     ${avg_ms} ms"
        echo ""
    fi

    jq -n --argjson avg "$avg_ms" --argjson ok "$success" --argjson total "$iterations" \
        '{status_latency_ms: $avg, success: $ok, iterations: $total}' 2>/dev/null || echo '{}'
}

# =============================================================================
# NFT BENCHMARK
# =============================================================================

_bench_nft() {
    local iterations="$1" json_mode="$2"

    # Ensure IPC module is loaded (writes must go through daemon)
    if ! declare -f nft_ipc_add_element >/dev/null 2>&1; then
        if [[ -f "${NFTBAN_LIB_DIR}/lib/nft_ipc.sh" ]]; then
            # shellcheck source=/dev/null
            source "${NFTBAN_LIB_DIR}/lib/nft_ipc.sh" || true
        fi
    fi

    local list_total=0 add_total=0 del_total=0
    local list_ok=0 add_ok=0 del_ok=0
    local i

    # Benchmark: nft list ruleset
    for ((i=1; i<=iterations; i++)); do
        local start_ns end_ns elapsed_ms
        start_ns=$(date +%s%N 2>/dev/null || echo 0)
        if nft list ruleset &>/dev/null; then
            end_ns=$(date +%s%N 2>/dev/null || echo 0)
            elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
            list_total=$((list_total + elapsed_ms))
            ((list_ok++)) || true
        fi
    done

    # Benchmark: IPC add/delete element (architecture policy: all writes via daemon)
    local test_ip="198.51.100.99"  # RFC 5737 documentation range
    for ((i=1; i<=iterations; i++)); do
        local start_ns end_ns elapsed_ms
        start_ns=$(date +%s%N 2>/dev/null || echo 0)
        if nft_ipc_add_element "ip nftban" "whitelist_ipv4" "$test_ip" 2>/dev/null; then
            end_ns=$(date +%s%N 2>/dev/null || echo 0)
            elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
            add_total=$((add_total + elapsed_ms))
            ((add_ok++)) || true

            # Delete it
            start_ns=$(date +%s%N 2>/dev/null || echo 0)
            if nft_ipc_delete_element "ip nftban" "whitelist_ipv4" "$test_ip" 2>/dev/null; then
                end_ns=$(date +%s%N 2>/dev/null || echo 0)
                elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))
                del_total=$((del_total + elapsed_ms))
                ((del_ok++)) || true
            fi
        fi
    done

    local list_avg=0 add_avg=0 del_avg=0
    [[ $list_ok -gt 0 ]] && list_avg=$((list_total / list_ok))
    [[ $add_ok -gt 0 ]] && add_avg=$((add_total / add_ok))
    [[ $del_ok -gt 0 ]] && del_avg=$((del_total / del_ok))

    if [[ "$json_mode" != "true" ]]; then
        echo "[NFT Benchmark]"
        echo "  List ruleset:    ${list_avg} ms avg ($list_ok/$iterations)"
        echo "  Add element:     ${add_avg} ms avg ($add_ok/$iterations)"
        echo "  Delete element:  ${del_avg} ms avg ($del_ok/$iterations)"
        echo ""
    fi

    jq -n --argjson list "$list_avg" --argjson add "$add_avg" --argjson del "$del_avg" \
        '{list_ruleset_ms: $list, add_element_ms: $add, delete_element_ms: $del}' 2>/dev/null || echo '{}'
}

# =============================================================================
# SET SIZES
# =============================================================================

_bench_sets() {
    local json_mode="$1"

    local result="{}"
    local sets_output
    sets_output=$(nft -j list sets 2>/dev/null) || sets_output=""

    if [[ -n "$sets_output" ]]; then
        result=$(echo "$sets_output" | jq '
            [.nftables[] | select(.set) | .set |
             {key: "\(.family) \(.table) \(.name)", value: (.elem // [] | length)}
            ] | from_entries
        ' 2>/dev/null || echo '{}')
    fi

    if [[ "$json_mode" != "true" ]]; then
        echo "[Set Sizes]"
        echo "$result" | jq -r 'to_entries[] | "  \(.key): \(.value) elements"' 2>/dev/null || echo "  (unable to read sets)"
        echo ""
    fi

    echo "$result"
}

# =============================================================================
# USAGE
# =============================================================================

_benchmark_usage() {
    cat <<'EOF'
Usage: nftban benchmark [TARGET] [OPTIONS]

Run performance benchmarks on NFTBan components.

TARGETS:
    all         Run all benchmarks (default)
    ipc         IPC socket latency (daemon status calls)
    nft         nftables operation timing (list, add, delete)
    sets        Show all nft set sizes

OPTIONS:
    --iterations N, -n N    Number of iterations (default: 10)
    --json, -j              JSON output
    --help, -h              Show this help

Examples:
    nftban benchmark
    nftban benchmark ipc --iterations 50
    nftban benchmark sets --json

EOF
}

# Export function
export -f nftban_cmd_benchmark
