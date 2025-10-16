#!/usr/bin/env bash
# =============================================================================
# NFTBan Validator - Panel Module
# Version: 7.0.0
# Provides: Interactive TUI for module validation (whiptail/fzf/plain)
# Location: /etc/nftban/lib/nftban-validator-panel.sh
# Requires: jq, sha256sum; optional: whiptail or fzf
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================
INSTALL_DIR="${INSTALL_DIR:-/etc/nftban}"
LIB_DIR="${LIB_DIR:-$INSTALL_DIR/lib}"
LOG_DIR="${LOG_DIR:-/var/log/nftban}"
MANIFEST="${MANIFEST:-$LIB_DIR/nftban-validator-manifest.json}"
PANEL_MODE="${PANEL_MODE:-auto}"  # auto|whiptail|fzf|plain
LOG_FILE="${LOG_DIR}/validator.log"

# =============================================================================
# LOGGING HELPERS
# =============================================================================
log_debug() { echo "[$(date -Is)] [DEBUG] $*" | tee -a "$LOG_FILE"; }
log_info()  { echo "[$(date -Is)] [INFO]  $*" | tee -a "$LOG_FILE"; }
log_warn()  { echo "[$(date -Is)] [WARN]  $*" | tee -a "$LOG_FILE"; }
log_error() { echo "[$(date -Is)] [ERROR] $*" | tee -a "$LOG_FILE" >&2; }

# =============================================================================
# INITIALIZATION
# =============================================================================
init_panel() {
    mkdir -p "$LOG_DIR"
    
    # Check dependencies
    if ! command -v jq &>/dev/null; then
        log_error "Required tool 'jq' not found"
        exit 1
    fi
    
    if ! command -v sha256sum &>/dev/null; then
        log_error "Required tool 'sha256sum' not found"
        exit 1
    fi
    
    if [[ ! -f "$MANIFEST" ]]; then
        log_error "Manifest not found: $MANIFEST"
        exit 1
    fi
    
    log_debug "Validator Panel initialized"
}

# =============================================================================
# PANEL MODE DETECTION
# =============================================================================
has_tool() {
    command -v "$1" &>/dev/null
}

detect_panel_mode() {
    if [[ "$PANEL_MODE" == "whiptail" ]] || { [[ "$PANEL_MODE" == "auto" ]] && has_tool whiptail; }; then
        echo "whiptail"
    elif [[ "$PANEL_MODE" == "fzf" ]] || { [[ "$PANEL_MODE" == "auto" ]] && has_tool fzf; }; then
        echo "fzf"
    else
        echo "plain"
    fi
}

# =============================================================================
# MODULE LISTING
# =============================================================================
list_modules() {
    jq -r '.modules[].filename' "$MANIFEST"
}

get_module_info() {
    local module="$1"
    jq -r ".modules[] | select(.filename==\"$module\") | .description" "$MANIFEST" 2>/dev/null || echo "No description"
}

get_module_layer() {
    local module="$1"
    jq -r ".modules[] | select(.filename==\"$module\") | .layer" "$MANIFEST" 2>/dev/null || echo "unknown"
}

get_module_critical() {
    local module="$1"
    jq -r ".modules[] | select(.filename==\"$module\") | .critical" "$MANIFEST" 2>/dev/null || echo "false"
}

# =============================================================================
# MODULE STATUS
# =============================================================================
get_module_status() {
    local module="$1"
    local file="$LIB_DIR/$module"
    
    local installed="NO"
    local version="-"
    local status="❌"
    
    if [[ -f "$file" ]]; then
        installed="YES"
        
        # Extract version from file
        version=$(grep -Eo 'Version: [0-9]+\.[0-9]+\.[0-9]+' "$file" 2>/dev/null | head -1 | awk '{print $2}')
        [[ -z "$version" ]] && version="?"
        
        # Check SHA256
        local expected_sha actual_sha
        expected_sha=$(jq -r ".modules[] | select(.filename==\"$module\").sha256" "$MANIFEST")
        
        if [[ -n "$expected_sha" && "$expected_sha" != "null" && "$expected_sha" != "" ]]; then
            actual_sha=$(sha256sum "$file" 2>/dev/null | awk '{print $1}')
            
            if [[ "$actual_sha" == "$expected_sha" ]]; then
                status="✅"
            else
                status="⚠️"
            fi
        else
            status="❓"
        fi
    fi
    
    echo "${module}|${installed}|${version}|${status}"
}

# =============================================================================
# MODULE VALIDATION
# =============================================================================
validate_module() {
    local module="$1"
    local file="$LIB_DIR/$module"
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Validating: $module"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Check if file exists
    if [[ ! -f "$file" ]]; then
        log_error "$module: File not found"
        echo "❌ MISSING: $file"
        return 1
    fi
    
    echo "✓ File exists: $file"
    
    # Check SHA256
    local expected_sha actual_sha
    expected_sha=$(jq -r ".modules[] | select(.filename==\"$module\").sha256" "$MANIFEST")
    
    if [[ -z "$expected_sha" || "$expected_sha" == "null" || "$expected_sha" == "" ]]; then
        log_warn "$module: No SHA256 in manifest"
        echo "❓ WARNING: No SHA256 hash in manifest"
    else
        actual_sha=$(sha256sum "$file" 2>/dev/null | awk '{print $1}')
        
        if [[ "$actual_sha" == "$expected_sha" ]]; then
            echo "✓ SHA256 verified"
        else
            log_error "$module: SHA256 mismatch"
            echo "❌ SHA256 MISMATCH"
            echo "   Expected: $expected_sha"
            echo "   Got:      $actual_sha"
            return 2
        fi
    fi
    
    # Check syntax
    if bash -n "$file" 2>/dev/null; then
        echo "✓ Bash syntax valid"
    else
        log_error "$module: Syntax error"
        echo "❌ SYNTAX ERROR"
        return 3
    fi
    
    # Check permissions
    if [[ -r "$file" ]]; then
        echo "✓ File readable"
    else
        log_error "$module: Not readable"
        echo "❌ NOT READABLE"
        return 4
    fi
    
    # Check size
    local expected_size
    expected_size=$(jq -r ".modules[] | select(.filename==\"$module\").size_bytes" "$MANIFEST" 2>/dev/null)
    
    if [[ -n "$expected_size" && "$expected_size" != "null" && "$expected_size" != "0" ]]; then
        local actual_size
        actual_size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null)
        
        if [[ "$actual_size" == "$expected_size" ]]; then
            echo "✓ File size matches ($actual_size bytes)"
        else
            log_warn "$module: Size mismatch ($actual_size vs $expected_size)"
            echo "⚠️  Size mismatch: $actual_size vs $expected_size bytes"
        fi
    fi
    
    log_info "$module: VALIDATED"
    echo "✅ VALIDATION PASSED"
    echo ""
    return 0
}

# =============================================================================
# PLAIN TEXT PANEL
# =============================================================================
panel_plain() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  NFTBan Module Validation Panel (Plain Mode)"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    
    printf "%-3s %-35s %-5s %-7s %-6s\n" "No." "Module" "Inst" "Version" "Status"
    echo "───────────────────────────────────────────────────────────────"
    
    local count=0
    while read -r module; do
        ((count++))
        local status_line
        status_line=$(get_module_status "$module")
        
        IFS='|' read -r mod inst ver stat <<< "$status_line"
        printf "%-3s %-35s %-5s %-7s %-6s\n" "$count" "$mod" "$inst" "$ver" "$stat"
    done < <(list_modules)
    
    echo "───────────────────────────────────────────────────────────────"
    echo ""
    echo "Legend: ✅=Valid ⚠️=Checksum Issue ❓=No Hash ❌=Missing"
    echo ""
    echo "Commands:"
    echo "  Full validation: sudo nftban validate run"
    echo "  Interactive:     sudo nftban validate panel"
    echo ""
}

# =============================================================================
# WHIPTAIL PANEL
# =============================================================================
panel_whiptail() {
    local items=()
    local count=0
    
    while read -r module; do
        ((count++))
        local info
        info=$(get_module_info "$module")
        local status_line
        status_line=$(get_module_status "$module")
        
        IFS='|' read -r mod inst ver stat <<< "$status_line"
        
        items+=("$module" "$stat $info" "OFF")
    done < <(list_modules)
    
    local selection
    selection=$(whiptail --title "NFTBan Module Validator" \
        --checklist "Select modules to validate (SPACE=select, ENTER=confirm)" \
        25 80 15 "${items[@]}" \
        3>&1 1>&2 2>&3) || {
        log_info "Validation cancelled by user"
        exit 0
    }
    
    # Remove quotes from selection
    selection=$(echo "$selection" | tr -d '"')
    
    if [[ -z "$selection" ]]; then
        log_info "No modules selected"
        exit 0
    fi
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Validating Selected Modules"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    
    local passed=0
    local failed=0
    
    for module in $selection; do
        if validate_module "$module"; then
            ((passed++))
        else
            ((failed++))
        fi
    done
    
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Validation Summary"
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Passed: $passed"
    echo "  Failed: $failed"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    
    [[ $failed -eq 0 ]] && return 0 || return 1
}

# =============================================================================
# FZF PANEL
# =============================================================================
panel_fzf() {
    echo "Select modules to validate (TAB=select, ENTER=confirm):"
    echo ""
    
    local selection
    selection=$(list_modules | fzf --multi \
        --prompt="Select modules> " \
        --preview="echo 'Module: {}'; echo ''; cat $LIB_DIR/{} 2>/dev/null | head -20" \
        --preview-window=right:50%:wrap)
    
    if [[ -z "$selection" ]]; then
        log_info "No modules selected"
        exit 0
    fi
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Validating Selected Modules"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    
    local passed=0
    local failed=0
    
    while read -r module; do
        if validate_module "$module"; then
            ((passed++))
        else
            ((failed++))
        fi
    done <<< "$selection"
    
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Validation Summary"
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Passed: $passed"
    echo "  Failed: $failed"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    
    [[ $failed -eq 0 ]] && return 0 || return 1
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    init_panel
    
    local mode
    mode=$(detect_panel_mode)
    
    log_info "Validator Panel starting (mode: $mode)"
    
    case "$mode" in
        whiptail)
            panel_whiptail
            ;;
        fzf)
            panel_fzf
            ;;
        plain|*)
            panel_plain
            ;;
    esac
    
    log_debug "Validator Panel finished"
}

main "$@"