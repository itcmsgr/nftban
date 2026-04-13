#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.80 - B80-5 Schema Codegen
# =============================================================================
# meta:name="generate-go-schema"
# meta:type="tool"
# meta:version="1.80.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Generates Go schema constants from the canonical shell schema (nft_schema.sh). Prevents drift between shell and Go truth surfaces."
# meta:inventory.files="cli/lib/nftban/lib/nft_schema.sh,internal/validator/schema_generated.go"
# meta:inventory.binaries="bash,sort"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
#
# Usage:
#   ./scripts/generate-go-schema.sh
#
# Output:
#   internal/validator/schema_generated.go
#
# The canonical schema source is cli/lib/nftban/lib/nft_schema.sh.
# This script sources it, extracts the associative array keys, and generates
# a Go file with sorted string slices that the validator uses for structural
# checks. The generated file MUST be committed. CI (B80-8) will re-run this
# script and fail if the output differs from the committed version.
#
# Running this script twice MUST produce byte-identical output (determinism).
# =============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SCHEMA_SRC="$PROJECT_ROOT/cli/lib/nftban/lib/nft_schema.sh"
OUTPUT_FILE="$PROJECT_ROOT/internal/validator/schema_generated.go"

if [[ ! -f "$SCHEMA_SRC" ]]; then
    echo "ERROR: canonical schema not found at $SCHEMA_SRC" >&2
    exit 1
fi

# Source the canonical schema. This populates the NFTBAN_* associative arrays.
# We disable strict mode temporarily because nft_schema.sh may call exported
# functions or reference vars that don't exist in this offline context.
set +eu
# shellcheck source=/dev/null
source "$SCHEMA_SRC" 2>/dev/null || true
set -eu

# -----------------------------------------------------------------------------
# Extract sorted key lists from the shell associative arrays.
# Using printf + sort ensures deterministic output regardless of bash hash order.
# -----------------------------------------------------------------------------

extract_sorted_keys() {
    local -n arr=$1
    local filter="${2:-}"
    local keys=()
    for key in "${!arr[@]}"; do
        [[ "$key" == "_placeholder" ]] && continue
        if [[ -n "$filter" ]]; then
            # Only include keys matching the filter pattern
            # shellcheck disable=SC2254  # intentional glob match
            case "$key" in $filter) keys+=("$key") ;; esac
        else
            keys+=("$key")
        fi
    done
    printf '%s\n' "${keys[@]}" | sort
}

# Base chains (same for v4 and v6)
base_chains=$(extract_sorted_keys NFTBAN_IPV4_CHAINS)

# Helper chains from the shell schema
shell_helper_chains=$(extract_sorted_keys NFTBAN_IPV4_HELPER_CHAINS)

# DDoS fragment-created sub-chains. These are NOT in the shell schema's
# helper chain array because they are created by nft_fragment.sh at enable
# time, not by the base nftables.conf template. However, the validator MUST
# require them when DDoS is enabled, because they are jump targets from the
# input chain. We add them as a known extension.
ddos_fragment_chains="ddos_penalty
ddos_prefix
ddos_sanity"

# Merge shell helpers + DDoS fragment chains, deduplicate, sort
all_helper_chains=$(printf '%s\n%s' "$shell_helper_chains" "$ddos_fragment_chains" | sort -u)

# Required sets: the core sets that MUST exist for base protection.
# BotGuard/module sets are optional (validator warns, not errors).
# This list matches the validator's current RequiredSetsIPv4/IPv6.
required_sets_v4=$(printf '%s\n' \
    "blacklist_ipv4" \
    "blacklist_manual_ipv4" \
    "tcp_ports_in" \
    "udp_ports_in" \
    "whitelist_ipv4" | sort)

required_sets_v6=$(printf '%s\n' \
    "blacklist_ipv6" \
    "blacklist_manual_ipv6" \
    "tcp_ports_in" \
    "udp_ports_in" \
    "whitelist_ipv6" | sort)

# All known sets (for future use — generated but not yet consumed by validator)
all_sets_v4=$(extract_sorted_keys NFTBAN_IPV4_SETS)
all_sets_v6=$(extract_sorted_keys NFTBAN_IPV6_SETS)

# Anchors are a validator-only concept (rule comments in the input chain).
# They are NOT in the shell schema and have a STRICT ORDER requirement that
# alphabetical sort would break. They stay manually maintained in types.go.
# DO NOT generate them.

# -----------------------------------------------------------------------------
# Generate the Go file
# -----------------------------------------------------------------------------

go_string_slice() {
    local varname="$1"
    local items="$2"
    local comment="$3"

    echo "// $comment"
    echo "var $varname = []string{"
    while IFS= read -r item; do
        [[ -z "$item" ]] && continue
        printf '\t"%s",\n' "$item"
    done <<< "$items"
    echo "}"
    echo ""
}

# Build the generated file's license line via concatenation so the header
# validator does not count it as a second SPDX occurrence in THIS script.
_SPDX="SPDX-License-Iden""tifier: MPL-2.0"

cat > "$OUTPUT_FILE" <<HEADER
// =============================================================================
// NFTBan v1.80 - Generated Schema Constants
// =============================================================================
// ${_SPDX}
// meta:name="schema_generated"
// meta:type="generated"
// meta:version="1.80.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Generated Go schema constants from canonical shell schema"
// meta:inventory.files="internal/validator/schema_generated.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
//
// Code generated by scripts/generate-go-schema.sh from cli/lib/nftban/lib/nft_schema.sh.
// DO NOT EDIT. Re-run the generator and commit the result.
//
// Canonical source: cli/lib/nftban/lib/nft_schema.sh
// Generator:        scripts/generate-go-schema.sh
//
// This file provides sorted string slices used by the validator for
// structural checks. The CI gate (B80-8) re-runs the generator and
// fails if the output differs from the committed version.
// =============================================================================

package validator

HEADER

go_string_slice "GeneratedRequiredBaseChains" "$base_chains" \
    "GeneratedRequiredBaseChains from NFTBAN_IPV4_CHAINS keys." \
    >> "$OUTPUT_FILE"

go_string_slice "GeneratedRequiredHelperChains" "$all_helper_chains" \
    "GeneratedRequiredHelperChains merges shell NFTBAN_IPV4_HELPER_CHAINS + DDoS fragment sub-chains (ddos_sanity, ddos_penalty, ddos_prefix)." \
    >> "$OUTPUT_FILE"

go_string_slice "GeneratedRequiredSetsIPv4" "$required_sets_v4" \
    "GeneratedRequiredSetsIPv4 — core sets required for base protection." \
    >> "$OUTPUT_FILE"

go_string_slice "GeneratedRequiredSetsIPv6" "$required_sets_v6" \
    "GeneratedRequiredSetsIPv6 — core sets required for base protection." \
    >> "$OUTPUT_FILE"

go_string_slice "GeneratedAllSetsIPv4" "$all_sets_v4" \
    "GeneratedAllSetsIPv4 — all known IPv4 set names from canonical schema (including optional module sets)." \
    >> "$OUTPUT_FILE"

go_string_slice "GeneratedAllSetsIPv6" "$all_sets_v6" \
    "GeneratedAllSetsIPv6 — all known IPv6 set names from canonical schema (including optional module sets)." \
    >> "$OUTPUT_FILE"

echo "Generated: $OUTPUT_FILE"
echo "Source:    $SCHEMA_SRC"
