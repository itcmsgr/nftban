#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Core IPC Enforcement Review Test
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Static analysis to enforce IPC boundary invariants
#
# meta:name="01_core_ipc_test"
# meta:type="test"
# meta:header="Core IPC Enforcement Review"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Static analysis tests verifying IPC boundary enforcement"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,awk"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
#
# meta:created_date="2026-02-27"
# meta:updated_date="2026-02-27"
# =============================================================================
set -Eeuo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Directories under test
SHELL_DIR="${REPO_ROOT}/cli/lib/nftban"
GO_PKG_DIR="${REPO_ROOT}/pkg"
GO_CMD_DIR="${REPO_ROOT}/cmd"

# The IPC library is the ONLY shell file allowed to contain emergency nft writes
IPC_LIB="cli/lib/nftban/lib/nft_ipc.sh"

# Canonical socket path
CANONICAL_SOCKET_PATH="/run/nftban/nftband.sock"

# =============================================================================
# TEST FRAMEWORK
# =============================================================================

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# Colors (disabled if not a terminal)
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[0;33m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    GREEN=''
    RED=''
    YELLOW=''
    BOLD=''
    RESET=''
fi

check() {
    local description="$1"
    local result="$2"  # 0=pass, 1=fail

    if [[ "$result" -eq 0 ]]; then
        echo -e "  ${GREEN}[PASS]${RESET} ${description}"
        ((PASS_COUNT++)) || true
    else
        echo -e "  ${RED}[FAIL]${RESET} ${description}"
        ((FAIL_COUNT++)) || true
    fi
}

skip() {
    local description="$1"
    local reason="$2"
    echo -e "  ${YELLOW}[SKIP]${RESET} ${description} -- ${reason}"
    ((SKIP_COUNT++)) || true
}

section() {
    echo ""
    echo -e "${BOLD}=== $1 ===${RESET}"
}

detail() {
    echo -e "         $1"
}

# =============================================================================
# PRECONDITION CHECKS
# =============================================================================

section "Preconditions"

if [[ -d "$SHELL_DIR" ]]; then
    check "Shell source directory exists: cli/lib/nftban/" 0
else
    check "Shell source directory exists: cli/lib/nftban/" 1
    echo "FATAL: Cannot continue without shell source directory" >&2
    exit 1
fi

if [[ -d "$GO_PKG_DIR" ]]; then
    check "Go pkg/ directory exists" 0
else
    check "Go pkg/ directory exists" 1
fi

if [[ -d "$GO_CMD_DIR" ]]; then
    check "Go cmd/ directory exists" 0
else
    check "Go cmd/ directory exists" 1
fi

if [[ -f "${REPO_ROOT}/${IPC_LIB}" ]]; then
    check "IPC library exists: ${IPC_LIB}" 0
else
    check "IPC library exists: ${IPC_LIB}" 1
fi

# =============================================================================
# TEST 1: No direct "nft add element" in shell modules outside IPC lib
# =============================================================================
# INVARIANT: Ban/unban operations MUST go through IPC. Direct "nft add element"
# or "nft delete element" for blacklist sets is a CRITICAL violation unless it
# is inside nft_ipc.sh (emergency fallback) or guarded by emergency gate.
# =============================================================================

section "T1: Direct nft element writes in shell (outside IPC lib)"

# Find all shell files with direct "nft add element" (excluding IPC lib and comments)
_t1_add_violations=""
_t1_add_count=0
while IFS= read -r line; do
    file="${line%%:*}"
    rel_file="${file#${REPO_ROOT}/}"

    # Skip the IPC library itself -- emergency direct calls are allowed there
    [[ "$rel_file" == "$IPC_LIB" ]] && continue

    # Skip comment-only lines (# Add port: nft add element ...)
    line_content="${line#*:}"
    # Strip leading line number if present (grep -n format: "123:content")
    if [[ "$line_content" =~ ^[0-9]+: ]]; then
        line_content="${line_content#*:}"
    fi
    # Skip lines that are pure comments
    trimmed="${line_content#"${line_content%%[![:space:]]*}"}"
    [[ "$trimmed" == \#* ]] && continue
    # Skip lines inside echo/printf (user-facing messages/docs)
    [[ "$trimmed" == echo* ]] && continue
    [[ "$trimmed" == *'echo "'*'nft add element'* ]] && continue
    [[ "$trimmed" == printf* ]] && continue

    _t1_add_violations="${_t1_add_violations}${rel_file}: ${line_content}
"
    ((_t1_add_count++)) || true
done < <(grep -rn 'nft add element' "${SHELL_DIR}" --include="*.sh" 2>/dev/null || true)

if [[ $_t1_add_count -eq 0 ]]; then
    check "No 'nft add element' outside IPC lib" 0
else
    check "No 'nft add element' outside IPC lib (found ${_t1_add_count} occurrences)" 1
    while IFS= read -r v; do
        [[ -n "$v" ]] && detail "VIOLATION: $v"
    done <<< "$_t1_add_violations"
fi

# Same check for "nft delete element"
_t1_del_violations=""
_t1_del_count=0
while IFS= read -r line; do
    file="${line%%:*}"
    rel_file="${file#${REPO_ROOT}/}"

    [[ "$rel_file" == "$IPC_LIB" ]] && continue

    line_content="${line#*:}"
    if [[ "$line_content" =~ ^[0-9]+: ]]; then
        line_content="${line_content#*:}"
    fi
    trimmed="${line_content#"${line_content%%[![:space:]]*}"}"
    [[ "$trimmed" == \#* ]] && continue
    [[ "$trimmed" == echo* ]] && continue
    [[ "$trimmed" == printf* ]] && continue

    _t1_del_violations="${_t1_del_violations}${rel_file}: ${line_content}
"
    ((_t1_del_count++)) || true
done < <(grep -rn 'nft delete element' "${SHELL_DIR}" --include="*.sh" 2>/dev/null || true)

if [[ $_t1_del_count -eq 0 ]]; then
    check "No 'nft delete element' outside IPC lib" 0
else
    check "No 'nft delete element' outside IPC lib (found ${_t1_del_count} occurrences)" 1
    while IFS= read -r v; do
        [[ -n "$v" ]] && detail "VIOLATION: $v"
    done <<< "$_t1_del_violations"
fi

# =============================================================================
# TEST 2: No direct "nft add rule" / "nft delete rule" in shell modules
# =============================================================================
# INVARIANT: Rule management should go through the daemon. Direct nft rule
# writes from shell modules bypass the IPC validator.
# =============================================================================

section "T2: Direct nft rule writes in shell modules"

_t2_violations=""
_t2_count=0
while IFS= read -r line; do
    file="${line%%:*}"
    rel_file="${file#${REPO_ROOT}/}"

    [[ "$rel_file" == "$IPC_LIB" ]] && continue

    line_content="${line#*:}"
    if [[ "$line_content" =~ ^[0-9]+: ]]; then
        line_content="${line_content#*:}"
    fi
    trimmed="${line_content#"${line_content%%[![:space:]]*}"}"
    [[ "$trimmed" == \#* ]] && continue
    [[ "$trimmed" == echo* ]] && continue
    [[ "$trimmed" == printf* ]] && continue

    _t2_violations="${_t2_violations}${rel_file}: ${line_content}
"
    ((_t2_count++)) || true
done < <(grep -rn 'nft \(add\|insert\|delete\) rule ' "${SHELL_DIR}" --include="*.sh" 2>/dev/null || true)

if [[ $_t2_count -eq 0 ]]; then
    check "No direct 'nft add/insert/delete rule' in shell modules" 0
else
    check "No direct 'nft add/insert/delete rule' in shell modules (found ${_t2_count})" 1
    while IFS= read -r v; do
        [[ -n "$v" ]] && detail "VIOLATION: $v"
    done <<< "$_t2_violations"
fi

# =============================================================================
# TEST 3: No direct "nft flush" in shell modules outside authorized files
# =============================================================================
# Authorized exceptions:
#   - cmd_firewall.sh (firewall reset/rebuild is an admin-only operation)
#   - cmd_flush.sh (flush command is intentionally direct for recovery)
# =============================================================================

section "T3: Direct nft flush operations in shell modules"

# Authorized files for flush operations (admin/recovery commands)
FLUSH_AUTHORIZED=(
    "cli/lib/nftban/cli/cmd_firewall.sh"
    "cli/lib/nftban/cli/cmd_flush.sh"
)

_t3_violations=""
_t3_count=0
while IFS= read -r line; do
    file="${line%%:*}"
    rel_file="${file#${REPO_ROOT}/}"

    [[ "$rel_file" == "$IPC_LIB" ]] && continue

    # Check authorized list
    authorized=false
    for auth_file in "${FLUSH_AUTHORIZED[@]}"; do
        [[ "$rel_file" == "$auth_file" ]] && authorized=true && break
    done
    [[ "$authorized" == "true" ]] && continue

    line_content="${line#*:}"
    if [[ "$line_content" =~ ^[0-9]+: ]]; then
        line_content="${line_content#*:}"
    fi
    trimmed="${line_content#"${line_content%%[![:space:]]*}"}"
    [[ "$trimmed" == \#* ]] && continue
    [[ "$trimmed" == echo* ]] && continue
    [[ "$trimmed" == printf* ]] && continue

    _t3_violations="${_t3_violations}${rel_file}: ${line_content}
"
    ((_t3_count++)) || true
done < <(grep -rn 'nft flush ' "${SHELL_DIR}" --include="*.sh" 2>/dev/null || true)

if [[ $_t3_count -eq 0 ]]; then
    check "No unauthorized 'nft flush' in shell modules" 0
else
    check "No unauthorized 'nft flush' in shell modules (found ${_t3_count})" 1
    while IFS= read -r v; do
        [[ -n "$v" ]] && detail "VIOLATION: $v"
    done <<< "$_t3_violations"
fi

# =============================================================================
# TEST 4: No direct "nft add table/chain/set" in shell outside authorized files
# =============================================================================
# Authorized exception:
#   - nftban_health_fixes.sh (schema repair is admin-only emergency operation)
# =============================================================================

section "T4: Direct nft schema writes (table/chain/set) in shell modules"

SCHEMA_AUTHORIZED=(
    "cli/lib/nftban/core/nftban_health_fixes.sh"
)

_t4_violations=""
_t4_count=0
while IFS= read -r line; do
    file="${line%%:*}"
    rel_file="${file#${REPO_ROOT}/}"

    [[ "$rel_file" == "$IPC_LIB" ]] && continue

    authorized=false
    for auth_file in "${SCHEMA_AUTHORIZED[@]}"; do
        [[ "$rel_file" == "$auth_file" ]] && authorized=true && break
    done
    [[ "$authorized" == "true" ]] && continue

    line_content="${line#*:}"
    if [[ "$line_content" =~ ^[0-9]+: ]]; then
        line_content="${line_content#*:}"
    fi
    trimmed="${line_content#"${line_content%%[![:space:]]*}"}"
    [[ "$trimmed" == \#* ]] && continue
    [[ "$trimmed" == echo* ]] && continue
    [[ "$trimmed" == printf* ]] && continue

    _t4_violations="${_t4_violations}${rel_file}: ${line_content}
"
    ((_t4_count++)) || true
done < <(grep -rn 'nft \(add\|create\) \(table\|chain\|set\) ' "${SHELL_DIR}" --include="*.sh" 2>/dev/null || true)

if [[ $_t4_count -eq 0 ]]; then
    check "No unauthorized 'nft add table/chain/set' in shell modules" 0
else
    check "No unauthorized 'nft add table/chain/set' in shell modules (found ${_t4_count})" 1
    while IFS= read -r v; do
        [[ -n "$v" ]] && detail "VIOLATION: $v"
    done <<< "$_t4_violations"
fi

# =============================================================================
# TEST 5: No direct "nft delete table" in shell outside authorized files
# =============================================================================
# Authorized exceptions:
#   - cmd_firewall.sh (firewall reset/rebuild)
#   - nftban_firewall_conflicts.sh (conflict resolution is admin operation)
#   - cmd_health_core.sh (rogue table cleanup is admin operation)
#   - helpers/autoheal.sh (auto-repair)
# =============================================================================

section "T5: Direct nft delete table in shell modules"

DELETE_TABLE_AUTHORIZED=(
    "cli/lib/nftban/cli/cmd_firewall.sh"
    "cli/lib/nftban/core/nftban_firewall_conflicts.sh"
    "cli/lib/nftban/cli/cmd_health_core.sh"
    "cli/lib/nftban/helpers/autoheal.sh"
)

_t5_violations=""
_t5_count=0
while IFS= read -r line; do
    file="${line%%:*}"
    rel_file="${file#${REPO_ROOT}/}"

    [[ "$rel_file" == "$IPC_LIB" ]] && continue

    authorized=false
    for auth_file in "${DELETE_TABLE_AUTHORIZED[@]}"; do
        [[ "$rel_file" == "$auth_file" ]] && authorized=true && break
    done
    [[ "$authorized" == "true" ]] && continue

    line_content="${line#*:}"
    if [[ "$line_content" =~ ^[0-9]+: ]]; then
        line_content="${line_content#*:}"
    fi
    trimmed="${line_content#"${line_content%%[![:space:]]*}"}"
    [[ "$trimmed" == \#* ]] && continue
    [[ "$trimmed" == echo* ]] && continue
    [[ "$trimmed" == printf* ]] && continue
    # Skip string array assignments (NFTBAN_FIREWALL_FIXES+=(...))
    [[ "$trimmed" == *'+='* ]] && continue

    _t5_violations="${_t5_violations}${rel_file}: ${line_content}
"
    ((_t5_count++)) || true
done < <(grep -rn 'nft delete table' "${SHELL_DIR}" --include="*.sh" 2>/dev/null || true)

if [[ $_t5_count -eq 0 ]]; then
    check "No unauthorized 'nft delete table' in shell modules" 0
else
    check "No unauthorized 'nft delete table' in shell modules (found ${_t5_count})" 1
    while IFS= read -r v; do
        [[ -n "$v" ]] && detail "VIOLATION: $v"
    done <<< "$_t5_violations"
fi

# =============================================================================
# TEST 6: Read-only nft operations are allowed (nft list, nft get, nft -c)
# =============================================================================
# These are permitted in any file -- just validate they exist and are
# the dominant form of nft usage in shell modules.
# =============================================================================

section "T6: Read-only nft operations (informational)"

readonly_count=$(grep -rn 'nft \(list\|get\|-c\|-j list\) ' "${SHELL_DIR}" --include="*.sh" 2>/dev/null | \
    grep -v '^\s*#' | wc -l || echo 0)
write_count=$(grep -rn 'nft \(add\|delete\|insert\|flush\|create\) ' "${SHELL_DIR}" --include="*.sh" 2>/dev/null | \
    grep -v '^\s*#' | wc -l || echo 0)

check "Read-only nft operations found in shell (${readonly_count} occurrences)" 0
detail "Read-only: ${readonly_count}, Write: ${write_count}"

if [[ "$readonly_count" -gt 0 ]] && [[ "$write_count" -gt 0 ]]; then
    ratio=$((readonly_count * 100 / (readonly_count + write_count)))
    detail "Read-only ratio: ${ratio}% of all nft calls"
fi

# =============================================================================
# TEST 7: cmd_ban.sh and cmd_unban.sh do NOT call nft directly for writes
# =============================================================================
# These are the primary ban/unban entry points. They MUST delegate to
# nftban-core (Go binary) which uses IPC, NOT call nft directly.
# =============================================================================

section "T7: cmd_ban.sh and cmd_unban.sh IPC compliance"

for cmd_file in "cli/lib/nftban/cli/cmd_ban.sh" "cli/lib/nftban/cli/cmd_unban.sh"; do
    if [[ ! -f "${REPO_ROOT}/${cmd_file}" ]]; then
        skip "${cmd_file}: no direct nft writes" "File not found"
        continue
    fi

    write_hits=$(grep -n 'nft \(add\|delete\|insert\|flush\) ' "${REPO_ROOT}/${cmd_file}" 2>/dev/null | \
        grep -v '^\s*#' | grep -v 'nft list' | grep -v 'nft get' | grep -v 'nft -c' || true)

    if [[ -z "$write_hits" ]]; then
        check "${cmd_file}: no direct nft writes (delegates to nftban-core)" 0
    else
        check "${cmd_file}: no direct nft writes" 1
        while IFS= read -r hit; do
            [[ -n "$hit" ]] && detail "VIOLATION: ${hit}"
        done <<< "$write_hits"
    fi
done

# =============================================================================
# TEST 8: IPC socket path consistency across shell files
# =============================================================================
# The canonical socket path is /run/nftban/nftband.sock
# All references must use this path (or NFTBAN_DAEMON_SOCKET variable).
# /var/run/nftban/ is a legacy alias and should be avoided for consistency.
# =============================================================================

section "T8: IPC socket path consistency"

# Check for /var/run/nftban/ (legacy, should be /run/nftban/)
var_run_hits=""
var_run_count=0
while IFS= read -r line; do
    file="${line%%:*}"
    rel_file="${file#${REPO_ROOT}/}"

    line_content="${line#*:}"
    if [[ "$line_content" =~ ^[0-9]+: ]]; then
        line_content="${line_content#*:}"
    fi
    trimmed="${line_content#"${line_content%%[![:space:]]*}"}"
    [[ "$trimmed" == \#* ]] && continue

    var_run_hits="${var_run_hits}${rel_file}: ${line_content}
"
    ((var_run_count++)) || true
done < <(grep -rn '/var/run/nftban/' "${SHELL_DIR}" --include="*.sh" 2>/dev/null || true)

if [[ $var_run_count -eq 0 ]]; then
    check "No legacy /var/run/nftban/ references in shell files" 0
else
    check "No legacy /var/run/nftban/ references in shell files (found ${var_run_count})" 1
    while IFS= read -r v; do
        [[ -n "$v" ]] && detail "LEGACY PATH: $v"
    done <<< "$var_run_hits"
fi

# Check Go code for /var/run/nftban/
go_var_run_count=0
if [[ -d "$GO_PKG_DIR" ]] || [[ -d "$GO_CMD_DIR" ]]; then
    go_var_run_count=$(grep -rn '/var/run/nftban/' "${GO_PKG_DIR}" "${GO_CMD_DIR}" --include="*.go" 2>/dev/null | \
        grep -v '^\s*//' | wc -l || echo 0)
fi

if [[ $go_var_run_count -eq 0 ]]; then
    check "No legacy /var/run/nftban/ references in Go files" 0
else
    check "No legacy /var/run/nftban/ references in Go files (found ${go_var_run_count})" 1
    grep -rn '/var/run/nftban/' "${GO_PKG_DIR}" "${GO_CMD_DIR}" --include="*.go" 2>/dev/null | \
        grep -v '^\s*//' | while IFS= read -r hit; do
            detail "LEGACY PATH: ${hit#${REPO_ROOT}/}"
        done
fi

# Verify canonical path is used in IPC lib
if grep -q "${CANONICAL_SOCKET_PATH}" "${REPO_ROOT}/${IPC_LIB}" 2>/dev/null; then
    check "IPC lib uses canonical socket path ${CANONICAL_SOCKET_PATH}" 0
else
    check "IPC lib uses canonical socket path ${CANONICAL_SOCKET_PATH}" 1
fi

# Verify Go IPC client uses canonical path
go_ipc_client="${REPO_ROOT}/pkg/ipc/client.go"
if [[ -f "$go_ipc_client" ]]; then
    if grep -q "DefaultSocketPath.*${CANONICAL_SOCKET_PATH}" "$go_ipc_client" 2>/dev/null; then
        check "Go IPC client uses canonical socket path" 0
    else
        check "Go IPC client uses canonical socket path" 1
    fi
else
    skip "Go IPC client uses canonical socket path" "pkg/ipc/client.go not found"
fi

# Verify systemd socket unit uses canonical path
socket_unit="${REPO_ROOT}/install/systemd/nftband.socket"
if [[ -f "$socket_unit" ]]; then
    if grep -q "ListenStream=${CANONICAL_SOCKET_PATH}" "$socket_unit" 2>/dev/null; then
        check "Systemd socket unit uses canonical socket path" 0
    else
        check "Systemd socket unit uses canonical socket path" 1
    fi
else
    skip "Systemd socket unit uses canonical socket path" "nftband.socket not found"
fi

# =============================================================================
# TEST 9: Emergency mode is gated in nft_ipc.sh
# =============================================================================
# The IPC library provides emergency fallback functions. These MUST:
# 1. Check NFTBAN_EMERGENCY_MODE before any direct nft call
# 2. Log a warning when emergency mode is used
# =============================================================================

section "T9: Emergency mode gating in IPC library"

if [[ -f "${REPO_ROOT}/${IPC_LIB}" ]]; then
    # Check that emergency ban function validates NFTBAN_EMERGENCY_MODE
    if grep -A2 'nft_emergency_ban' "${REPO_ROOT}/${IPC_LIB}" | grep -q 'NFTBAN_EMERGENCY_MODE'; then
        check "nft_emergency_ban checks NFTBAN_EMERGENCY_MODE" 0
    else
        check "nft_emergency_ban checks NFTBAN_EMERGENCY_MODE" 1
    fi

    # Check that emergency unban function validates NFTBAN_EMERGENCY_MODE
    if grep -A2 'nft_emergency_unban' "${REPO_ROOT}/${IPC_LIB}" | grep -q 'NFTBAN_EMERGENCY_MODE'; then
        check "nft_emergency_unban checks NFTBAN_EMERGENCY_MODE" 0
    else
        check "nft_emergency_unban checks NFTBAN_EMERGENCY_MODE" 1
    fi

    # Check that the IPC check-or-emergency function exists
    if grep -q 'nftban_ipc_check_or_emergency' "${REPO_ROOT}/${IPC_LIB}"; then
        check "nftban_ipc_check_or_emergency gate function exists" 0
    else
        check "nftban_ipc_check_or_emergency gate function exists" 1
    fi

    # Verify emergency gate file path is defined
    if grep -q '/run/nftban/.emergency_unlock' "${REPO_ROOT}/${IPC_LIB}"; then
        check "Emergency gate file path defined (/run/nftban/.emergency_unlock)" 0
    else
        check "Emergency gate file path defined" 1
    fi
else
    skip "Emergency mode checks" "IPC library not found"
fi

# =============================================================================
# TEST 10: Go daemon is the ONLY place with nft write exec.Command calls
# =============================================================================
# In Go code, only pkg/nftbackend/ and pkg/sync/ should call nft for writes.
# Other packages must use the IPC client.
# =============================================================================

section "T10: Go nft write operations confined to backend/sync"

# Authorized Go packages for nft CLI execution
GO_NFT_AUTHORIZED=(
    "pkg/nftbackend/"
    "pkg/sync/"
    "cmd/nftband/"
)

_t10_violations=""
_t10_count=0

if [[ -d "$GO_PKG_DIR" ]] && [[ -d "$GO_CMD_DIR" ]]; then
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        file="${line%%:*}"
        rel_file="${file#${REPO_ROOT}/}"

        authorized=false
        for auth_pkg in "${GO_NFT_AUTHORIZED[@]}"; do
            [[ "$rel_file" == ${auth_pkg}* ]] && authorized=true && break
        done
        [[ "$authorized" == "true" ]] && continue

        line_content="${line#*:}"
        if [[ "$line_content" =~ ^[0-9]+: ]]; then
            line_content="${line_content#*:}"
        fi
        trimmed="${line_content#"${line_content%%[![:space:]]*}"}"
        # Skip Go comments
        [[ "$trimmed" == //* ]] && continue
        # Skip meta:inventory lines (just metadata about binaries)
        [[ "$trimmed" == *'meta:inventory'* ]] && continue
        # Skip string literals that are just binary names in lists (e.g. {"nft", "/usr/sbin/nft"})
        [[ "$trimmed" == *'{"nft"'* ]] && continue

        # Only flag actual exec.Command("nft",...) calls that perform writes
        # Read-only calls (list, -c, -j list) are allowed anywhere
        if echo "$line_content" | grep -qE 'exec\.Command.*"nft"'; then
            # Check if it is a read-only call
            if echo "$line_content" | grep -qE '"list"|"-c"|"-j"'; then
                continue  # read-only, allowed
            fi
            _t10_violations="${_t10_violations}${rel_file}: ${line_content}
"
            ((_t10_count++)) || true
        fi
    done < <(grep -rn 'exec\.Command.*"nft"' "${GO_PKG_DIR}" "${GO_CMD_DIR}" --include="*.go" 2>/dev/null || true)
fi

if [[ $_t10_count -eq 0 ]]; then
    check "No unauthorized Go nft write exec.Command outside backend/sync/daemon" 0
else
    check "No unauthorized Go nft write exec.Command outside backend/sync/daemon (found ${_t10_count})" 1
    while IFS= read -r v; do
        [[ -n "$v" ]] && detail "VIOLATION: $v"
    done <<< "$_t10_violations"
fi

# =============================================================================
# TEST 11: Go IPC client exists and has required methods
# =============================================================================
# The IPC client (pkg/ipc/client.go) must provide Ban, Unban, AddElement,
# DeleteElement methods so callers never need direct nft access.
# =============================================================================

section "T11: Go IPC client API completeness"

if [[ -f "${REPO_ROOT}/pkg/ipc/client.go" ]]; then
    for method in Ban Unban AddElement DeleteElement FlushSet ApplyRuleset Ping; do
        if grep -qE "func \(.*\) ${method}\(" "${REPO_ROOT}/pkg/ipc/client.go" 2>/dev/null; then
            check "Go IPC client has ${method}() method" 0
        else
            check "Go IPC client has ${method}() method" 1
        fi
    done
else
    skip "Go IPC client API completeness" "pkg/ipc/client.go not found"
fi

# =============================================================================
# TEST 12: Shell IPC functions exist in nft_ipc.sh
# =============================================================================
# The shell IPC library must provide wrapper functions for ban/unban/add/delete
# so shell modules use IPC rather than direct nft calls.
# =============================================================================

section "T12: Shell IPC library function completeness"

if [[ -f "${REPO_ROOT}/${IPC_LIB}" ]]; then
    for func in "nft_ipc_ban" "nft_ipc_unban" "nft_ipc_add_element" "nft_ipc_delete_element" \
                "nft_ipc_request" "nft_ipc_is_daemon_running" "nft_smart_ban" "nft_smart_unban" \
                "nftban_ipc_check_or_emergency"; do
        if grep -q "^${func}()" "${REPO_ROOT}/${IPC_LIB}" 2>/dev/null; then
            check "Shell IPC lib has ${func}()" 0
        else
            check "Shell IPC lib has ${func}()" 1
        fi
    done
else
    skip "Shell IPC library function completeness" "IPC library not found"
fi

# =============================================================================
# TEST 13: Shell modules that perform writes use IPC gate
# =============================================================================
# Files outside nft_ipc.sh that contain nft write operations SHOULD call
# nftban_ipc_check_or_emergency or nft_ipc_* functions.
# =============================================================================

section "T13: Shell write modules use IPC gate function"

# Check cmd_whitelist.sh uses the IPC gate
whitelist_file="${REPO_ROOT}/cli/lib/nftban/cli/cmd_whitelist.sh"
if [[ -f "$whitelist_file" ]]; then
    if grep -q 'nftban_ipc_check_or_emergency\|nft_ipc_' "$whitelist_file" 2>/dev/null; then
        check "cmd_whitelist.sh uses IPC gate or IPC functions" 0
    else
        check "cmd_whitelist.sh uses IPC gate or IPC functions" 1
    fi
else
    skip "cmd_whitelist.sh IPC gate usage" "File not found"
fi

# Check cmd_flush.sh uses the IPC gate
flush_file="${REPO_ROOT}/cli/lib/nftban/cli/cmd_flush.sh"
if [[ -f "$flush_file" ]]; then
    if grep -q 'nftban_ipc_check_or_emergency\|nft_ipc_' "$flush_file" 2>/dev/null; then
        check "cmd_flush.sh uses IPC gate or IPC functions" 0
    else
        check "cmd_flush.sh uses IPC gate or IPC functions" 1
    fi
else
    skip "cmd_flush.sh IPC gate usage" "File not found"
fi

# Check maintenance.sh uses IPC (it has direct nft writes for whitelist)
maint_file="${REPO_ROOT}/cli/lib/nftban/cron/maintenance.sh"
if [[ -f "$maint_file" ]]; then
    if grep -q 'nftban_ipc_check_or_emergency\|nft_ipc_\|nft_smart_' "$maint_file" 2>/dev/null; then
        check "cron/maintenance.sh uses IPC functions" 0
    else
        # maintenance.sh has direct nft add element calls -- flag it
        if grep -q 'nft add element\|nft delete element' "$maint_file" 2>/dev/null; then
            check "cron/maintenance.sh uses IPC functions (has direct nft writes without IPC gate)" 1
        else
            check "cron/maintenance.sh: no nft writes (ok)" 0
        fi
    fi
else
    skip "cron/maintenance.sh IPC gate usage" "File not found"
fi

# =============================================================================
# TEST 14: IPC double-load prevention guard
# =============================================================================
# The IPC library must have a _LOADED guard to prevent double-sourcing.
# =============================================================================

section "T14: IPC library double-load prevention"

if [[ -f "${REPO_ROOT}/${IPC_LIB}" ]]; then
    if grep -q '_NFTBAN_NFT_IPC_LOADED' "${REPO_ROOT}/${IPC_LIB}" 2>/dev/null; then
        check "IPC library has double-load prevention guard" 0
    else
        check "IPC library has double-load prevention guard" 1
    fi
else
    skip "IPC library double-load prevention" "IPC library not found"
fi

# =============================================================================
# TEST 15: IPC library has set -Eeuo pipefail
# =============================================================================

section "T15: IPC library strict mode"

if [[ -f "${REPO_ROOT}/${IPC_LIB}" ]]; then
    if head -20 "${REPO_ROOT}/${IPC_LIB}" | grep -q 'set -Eeuo pipefail'; then
        check "IPC library has 'set -Eeuo pipefail'" 0
    else
        check "IPC library has 'set -Eeuo pipefail'" 1
    fi
else
    skip "IPC library strict mode" "IPC library not found"
fi

# =============================================================================
# TEST 16: Socket path consistency across all references
# =============================================================================
# Collect all unique socket paths referenced and verify they resolve to
# the same canonical path.
# =============================================================================

section "T16: Socket path unification"

# Count distinct socket path patterns in shell code
canonical_refs=$(grep -rn "${CANONICAL_SOCKET_PATH}" "${SHELL_DIR}" --include="*.sh" 2>/dev/null | \
    grep -v '^\s*#' | wc -l || echo 0)
var_socket_refs=$(grep -rn 'NFTBAN_DAEMON_SOCKET\|NFTBAN_SOCKET' "${SHELL_DIR}" --include="*.sh" 2>/dev/null | \
    grep -v '^\s*#' | wc -l || echo 0)

detail "Canonical path references: ${canonical_refs}"
detail "Variable-based references: ${var_socket_refs}"

# All NFTBAN_DAEMON_SOCKET / NFTBAN_SOCKET defaults should point to canonical path
# Must NOT use /var/run/ (legacy alias that works but is inconsistent)
bad_defaults=0
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # Flag if line uses /var/run/ instead of /run/
    if echo "$line" | grep -q '/var/run/nftban/'; then
        ((bad_defaults++)) || true
        detail "BAD DEFAULT (legacy /var/run/): $line"
    elif ! echo "$line" | grep -q "${CANONICAL_SOCKET_PATH}"; then
        ((bad_defaults++)) || true
        detail "BAD DEFAULT (wrong path): $line"
    fi
done < <(grep -rn 'NFTBAN_DAEMON_SOCKET:-' "${SHELL_DIR}" --include="*.sh" 2>/dev/null || true)
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if echo "$line" | grep -q '/var/run/nftban/'; then
        ((bad_defaults++)) || true
        detail "BAD DEFAULT (legacy /var/run/): $line"
    elif ! echo "$line" | grep -q "${CANONICAL_SOCKET_PATH}"; then
        ((bad_defaults++)) || true
        detail "BAD DEFAULT (wrong path): $line"
    fi
done < <(grep -rn 'NFTBAN_SOCKET:-' "${SHELL_DIR}" --include="*.sh" 2>/dev/null || true)

if [[ $bad_defaults -eq 0 ]]; then
    check "All socket variable defaults resolve to canonical path" 0
else
    check "All socket variable defaults resolve to canonical path (found ${bad_defaults} mismatches)" 1
fi

# =============================================================================
# TEST 17: Inventory of all nft write calls in shell (informational)
# =============================================================================
# Not a pass/fail -- just an inventory for review.
# =============================================================================

section "T17: Full nft write inventory (informational)"

total_writes=$(grep -rn 'nft \(add\|delete\|insert\|flush\|create\) ' "${SHELL_DIR}" --include="*.sh" 2>/dev/null | \
    grep -v '^\s*#' | grep -v '^\s*echo' | grep -v '^\s*printf' | wc -l || echo 0)

detail "Total non-comment nft write operations in shell: ${total_writes}"

# Group by file
if [[ "$total_writes" -gt 0 ]]; then
    detail ""
    detail "Breakdown by file:"
    grep -rn 'nft \(add\|delete\|insert\|flush\|create\) ' "${SHELL_DIR}" --include="*.sh" 2>/dev/null | \
        grep -v '^\s*#' | grep -v '^\s*echo' | grep -v '^\s*printf' | \
        awk -F: '{print $1}' | sort | uniq -c | sort -rn | \
        while IFS= read -r entry; do
            detail "  ${entry#${REPO_ROOT}/}"
        done
fi

check "NFT write inventory generated" 0

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo -e "${BOLD}======================================${RESET}"
echo -e "${BOLD}  IPC Enforcement Review Summary${RESET}"
echo -e "${BOLD}======================================${RESET}"
echo ""
echo -e "  ${GREEN}PASSED:${RESET}  ${PASS_COUNT}"
echo -e "  ${RED}FAILED:${RESET}  ${FAIL_COUNT}"
echo -e "  ${YELLOW}SKIPPED:${RESET} ${SKIP_COUNT}"
echo -e "  TOTAL:   $((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))"
echo ""

if [[ $FAIL_COUNT -gt 0 ]]; then
    echo -e "  ${RED}${BOLD}RESULT: FAIL${RESET} -- ${FAIL_COUNT} check(s) failed"
    echo ""
    exit 1
else
    echo -e "  ${GREEN}${BOLD}RESULT: PASS${RESET} -- All checks passed"
    echo ""
    exit 0
fi
