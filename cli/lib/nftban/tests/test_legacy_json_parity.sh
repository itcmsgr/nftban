#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.56.0 - Legacy JSON Parity Verification Test
# =============================================================================
# meta:name="test_legacy_json_parity"
# meta:type="test"
# meta:version="1.56.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Compares legacy metrics_collector output vs compat layer output for schema parity"
# meta:inventory.files=""
# meta:inventory.binaries="bash,jq,nftban"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units="nftban-unified-exporter.timer"
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================
#
# PURPOSE:
# Verifies that the new compatibility layer (nftban_exporter_json_compat.sh)
# produces JSON output matching the legacy metrics_collector.sh schema.
#
# RUNS ON: Lab servers ONLY (requires live nftban installation)
#
# CHECKS:
#   1. All legacy keys present in compat output (no MISSING)
#   2. Value types preserved (no type changes)
#   3. Reports additive keys (EXTRA — acceptable if documented)
#
# EXIT CODES:
#   0 = PASS (no MISSING or MISMATCH)
#   1 = FAIL (MISSING or MISMATCH found)
#   2 = SKIP (prerequisites not met)
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m'

# Counters
TOTAL=0
MATCH=0
MISMATCH=0
MISSING=0
EXTRA=0

# Temp files
LEGACY_FILE=""
COMPAT_FILE=""

cleanup() {
    rm -f "$LEGACY_FILE" "$COMPAT_FILE" \
          /tmp/nftban_parity_legacy_keys.txt \
          /tmp/nftban_parity_compat_keys.txt \
          /tmp/nftban_parity_legacy_types.txt \
          /tmp/nftban_parity_compat_types.txt \
          2>/dev/null || true
}
trap cleanup EXIT

print_header() {
    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  NFTBan v1.56.0 - Legacy JSON Parity Test                ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# =============================================================================
# PREREQUISITES CHECK
# =============================================================================
check_prerequisites() {
    local ok=true

    echo -e "${CYAN}Checking prerequisites...${NC}"

    # jq required
    if ! command -v jq &>/dev/null; then
        echo -e "  ${RED}FAIL${NC} jq not found"
        ok=false
    else
        echo -e "  ${GREEN}OK${NC}   jq $(jq --version 2>/dev/null || echo 'available')"
    fi

    # Legacy collector must exist
    local collector="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/exporters/nftban_metrics_collector.sh"
    if [[ ! -f "$collector" ]]; then
        echo -e "  ${RED}FAIL${NC} Legacy collector not found: $collector"
        ok=false
    else
        echo -e "  ${GREEN}OK${NC}   Legacy collector: $collector"
    fi

    # Unified exporter must exist
    local exporter="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/exporters/nftban_unified_exporter.sh"
    if [[ ! -f "$exporter" ]]; then
        echo -e "  ${RED}FAIL${NC} Unified exporter not found: $exporter"
        ok=false
    else
        echo -e "  ${GREEN}OK${NC}   Unified exporter: $exporter"
    fi

    # Compat layer must exist
    local compat="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/exporters/nftban_exporter_json_compat.sh"
    if [[ ! -f "$compat" ]]; then
        echo -e "  ${RED}FAIL${NC} Compat layer not found: $compat"
        ok=false
    else
        echo -e "  ${GREEN}OK${NC}   Compat layer: $compat"
    fi

    # stats.json must exist (unified exporter produces it)
    local stats_json="${NFTBAN_CACHE_DIR:-/var/cache/nftban}/metrics/stats.json"
    if [[ ! -f "$stats_json" ]]; then
        echo -e "  ${YELLOW}WARN${NC} stats.json not found — running unified exporter first"
        if bash "$exporter" 2>/dev/null; then
            echo -e "  ${GREEN}OK${NC}   Unified exporter ran successfully"
        else
            echo -e "  ${RED}FAIL${NC} Unified exporter failed"
            ok=false
        fi
    else
        echo -e "  ${GREEN}OK${NC}   stats.json: $stats_json"
    fi

    echo ""
    if [[ "$ok" != "true" ]]; then
        echo -e "${RED}Prerequisites not met — aborting${NC}"
        exit 2
    fi
}

# =============================================================================
# STEP 1: Generate legacy output
# =============================================================================
generate_legacy() {
    echo -e "${CYAN}Step 1: Generating legacy collector output...${NC}"
    LEGACY_FILE=$(mktemp /tmp/nftban_parity_legacy_XXXXXX.json)

    local lib_dir="${NFTBAN_LIB_DIR:-/usr/lib/nftban}"
    local collector="${lib_dir}/exporters/nftban_metrics_collector.sh"
    local nft_schema="${lib_dir}/lib/nft_schema.sh"

    # The legacy collector depends on nft_schema.sh for nftban_nft_count_set_elements()
    # but doesn't source it itself. Wrap in a subshell that pre-sources the dependency.
    # shellcheck disable=SC1090  # Dynamic source paths (runtime-resolved)
    if (
        source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" 2>/dev/null || true
        [[ -f "$nft_schema" ]] && source "$nft_schema" 2>/dev/null || true
        source "$collector"
        main --stdout
    ) > "$LEGACY_FILE" 2>/dev/null; then
        echo -e "  ${GREEN}OK${NC}   Legacy output: $(wc -c < "$LEGACY_FILE") bytes"
    else
        echo -e "  ${RED}FAIL${NC} Legacy collector failed (exit $?)"
        echo -e "  ${YELLOW}HINT${NC} Run manually: source nft_schema.sh && bash collector --stdout"
        exit 1
    fi

    # Validate JSON
    if ! jq -e . "$LEGACY_FILE" &>/dev/null; then
        echo -e "  ${RED}FAIL${NC} Legacy output is not valid JSON"
        exit 1
    fi
    echo -e "  ${GREEN}OK${NC}   Valid JSON"
}

# =============================================================================
# STEP 2: Generate compat output
# =============================================================================
generate_compat() {
    echo -e "${CYAN}Step 2: Generating compat layer output...${NC}"

    # Run the unified exporter (which now includes compat layer)
    local exporter="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/exporters/nftban_unified_exporter.sh"
    bash "$exporter" 2>/dev/null || true

    local dynamic="${NFTBAN_CACHE_DIR:-/var/cache/nftban}/metrics/dynamic.json"
    local inventory="${NFTBAN_CACHE_DIR:-/var/cache/nftban}/metrics/inventory.json"
    local combined="${NFTBAN_CACHE_DIR:-/var/cache/nftban}/metrics/combined.json"

    # Check output files exist
    if [[ ! -f "$dynamic" ]]; then
        echo -e "  ${RED}FAIL${NC} Compat dynamic.json not created"
        exit 1
    fi
    echo -e "  ${GREEN}OK${NC}   dynamic.json: $(wc -c < "$dynamic") bytes"

    if [[ -f "$inventory" ]]; then
        echo -e "  ${GREEN}OK${NC}   inventory.json: $(wc -c < "$inventory") bytes"
    else
        echo -e "  ${YELLOW}WARN${NC} inventory.json not generated (may not be inventory run)"
    fi

    if [[ ! -f "$combined" ]]; then
        echo -e "  ${RED}FAIL${NC} Compat combined.json not created"
        exit 1
    fi
    echo -e "  ${GREEN}OK${NC}   combined.json: $(wc -c < "$combined") bytes"

    COMPAT_FILE=$(mktemp /tmp/nftban_parity_compat_XXXXXX.json)
    cp "$combined" "$COMPAT_FILE"

    # Validate JSON
    if ! jq -e . "$COMPAT_FILE" &>/dev/null; then
        echo -e "  ${RED}FAIL${NC} Compat output is not valid JSON"
        exit 1
    fi
    echo -e "  ${GREEN}OK${NC}   Valid JSON"
}

# =============================================================================
# STEP 3: Extract keys recursively with types
# =============================================================================
extract_keys_with_types() {
    local file="$1"
    local output="$2"

    # Recursively extract all leaf paths with their types
    jq -r '
        paths(scalars) as $p |
        "\($p | join(".")) \(getpath($p) | type)"
    ' "$file" | sort > "$output"
}

# =============================================================================
# STEP 4: Compare schemas
# =============================================================================
compare_schemas() {
    echo ""
    echo -e "${CYAN}Step 3: Comparing schemas...${NC}"
    echo ""

    local legacy_keys="/tmp/nftban_parity_legacy_keys.txt"
    local compat_keys="/tmp/nftban_parity_compat_keys.txt"
    local legacy_types="/tmp/nftban_parity_legacy_types.txt"
    local compat_types="/tmp/nftban_parity_compat_types.txt"

    # Extract keys and types
    extract_keys_with_types "$LEGACY_FILE" "$legacy_types"
    extract_keys_with_types "$COMPAT_FILE" "$compat_types"

    # Extract just the key paths
    awk '{print $1}' "$legacy_types" > "$legacy_keys"
    awk '{print $1}' "$compat_types" > "$compat_keys"

    local total_legacy total_compat
    total_legacy=$(wc -l < "$legacy_keys")
    total_compat=$(wc -l < "$compat_keys")

    echo -e "  Legacy keys:  $total_legacy"
    echo -e "  Compat keys:  $total_compat"
    echo ""

    # --- Check for MISSING keys (in legacy, not in compat) ---
    echo -e "${CYAN}── Missing keys (in legacy, NOT in compat) ──${NC}"
    local missing_found=false
    while IFS= read -r key; do
        local legacy_type compat_type
        legacy_type=$(awk -v k="${key}" '$1 == k' "$legacy_types" | awk '{print $2}')
        compat_type=$(awk -v k="${key}" '$1 == k' "$compat_types" | awk '{print $2}')

        if [[ -z "$compat_type" ]]; then
            echo -e "  ${RED}MISSING${NC}  $key  (legacy type: $legacy_type)"
            ((MISSING++)) || true
            missing_found=true
        fi
        ((TOTAL++)) || true
    done < "$legacy_keys"
    if [[ "$missing_found" != "true" ]]; then
        echo -e "  ${GREEN}None${NC}"
    fi

    # --- Check for TYPE MISMATCHES ---
    echo ""
    echo -e "${CYAN}── Type mismatches ──${NC}"
    local mismatch_found=false
    while IFS= read -r line; do
        local key type_l
        key=$(echo "$line" | awk '{print $1}')
        type_l=$(echo "$line" | awk '{print $2}')

        local type_c
        type_c=$(awk -v k="${key}" '$1 == k' "$compat_types" | awk '{print $2}')

        if [[ -n "$type_c" ]] && [[ "$type_l" != "$type_c" ]]; then
            echo -e "  ${RED}MISMATCH${NC}  $key  (legacy: $type_l, compat: $type_c)"
            ((MISMATCH++)) || true
            mismatch_found=true
        elif [[ -n "$type_c" ]]; then
            ((MATCH++)) || true
        fi
    done < "$legacy_types"
    if [[ "$mismatch_found" != "true" ]]; then
        echo -e "  ${GREEN}None${NC}"
    fi

    # --- Check for EXTRA keys (in compat, not in legacy) ---
    echo ""
    echo -e "${CYAN}── Extra keys (in compat, NOT in legacy — acceptable) ──${NC}"
    local extra_found=false
    while IFS= read -r key; do
        local compat_type
        compat_type=$(awk -v k="${key}" '$1 == k' "$compat_types" | awk '{print $2}')

        if ! awk -v k="${key}" '$1 == k {found=1} END {exit !found}' "$legacy_keys"; then
            echo -e "  ${YELLOW}EXTRA${NC}    $key  (type: $compat_type)"
            ((EXTRA++)) || true
            extra_found=true
        fi
    done < "$compat_keys"
    if [[ "$extra_found" != "true" ]]; then
        echo -e "  ${GREEN}None${NC}"
    fi
}

# =============================================================================
# STEP 5: Print summary
# =============================================================================
print_summary() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  PARITY TEST SUMMARY${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  Total legacy keys: $TOTAL"
    echo -e "  ${GREEN}MATCH:${NC}    $MATCH  (key present, same type)"
    echo -e "  ${RED}MISMATCH:${NC} $MISMATCH  (key present, different type)"
    echo -e "  ${RED}MISSING:${NC}  $MISSING  (key in legacy, not in compat)"
    echo -e "  ${YELLOW}EXTRA:${NC}    $EXTRA  (key in compat, not in legacy — OK if documented)"
    echo ""

    if [[ $MISSING -eq 0 ]] && [[ $MISMATCH -eq 0 ]]; then
        echo -e "  ${GREEN}RESULT: PASS${NC}"
        echo -e "  All legacy keys present with correct types."
        if [[ $EXTRA -gt 0 ]]; then
            echo -e "  ($EXTRA additive keys in compat output — backward compatible)"
        fi
        echo ""
        return 0
    else
        echo -e "  ${RED}RESULT: FAIL${NC}"
        [[ $MISSING -gt 0 ]] && echo -e "  $MISSING key(s) missing from compat output"
        [[ $MISMATCH -gt 0 ]] && echo -e "  $MISMATCH type mismatch(es) found"
        echo ""
        return 1
    fi
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    print_header
    check_prerequisites
    generate_legacy
    echo ""
    generate_compat
    compare_schemas
    print_summary
}

main "$@"
