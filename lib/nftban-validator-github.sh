#!/usr/bin/env bash
# =============================================================================
# NFTBan Validator - GitHub SHA256 Integration
# Version: 7.0.1
# Location: lib/nftban-validator-github.sh
# Provides: Download and validate against GitHub SHA256SUMS.txt
# Requires: curl or wget, sha256sum
# =============================================================================

set -euo pipefail

# --- Module banner -----------------------------------------------------------
echo "[NFTBan] Loading: Validator GitHub Module v7.0.1"

# --- Logging helpers (fallback) ----------------------------------------------
if ! type installer_log_debug >/dev/null 2>&1; then
  installer_log_debug() { printf "%s [DEBUG] %s\n" "$(date -Is)" "$*"; }
fi
if ! type installer_log_info >/dev/null 2>&1; then
  installer_log_info() { printf "%s [INFO]  %s\n" "$(date -Is)" "$*"; }
fi
if ! type installer_log_warn >/dev/null 2>&1; then
  installer_log_warn() { printf "%s [WARN]  %s\n" "$(date -Is)" "$*"; }
fi
if ! type installer_log_error >/dev/null 2>&1; then
  installer_log_error() { printf "%s [ERROR] %s\n" "$(date -Is)" "$*"; }
fi
if ! type installer_log_success >/dev/null 2>&1; then
  installer_log_success() { printf "%s [OK]    %s\n" "$(date -Is)" "$*"; }
fi

# --- Configuration -----------------------------------------------------------
INSTALL_DIR="${INSTALL_DIR:-/etc/nftban}"
LIB_DIR="${LIB_DIR:-$INSTALL_DIR/lib}"
LOG_DIR="${LOG_DIR:-/var/log/nftban}"
CACHE_DIR="${CACHE_DIR:-/tmp/nftban_cache}"

# GitHub SHA256SUMS URL
GITHUB_SHA256_URL="${GITHUB_SHA256_URL:-https://raw.githubusercontent.com/itcmsgr/nftban/main/SHA256SUMS.txt}"

# Local cache file
SHA256_CACHE="${CACHE_DIR}/SHA256SUMS.txt"
VALIDATION_REPORT="${LOG_DIR}/validation_report.log"

mkdir -p "$LOG_DIR" "$CACHE_DIR"

has() { command -v "$1" >/dev/null 2>&1; }

# =============================================================================
# DOWNLOAD GITHUB SHA256SUMS.txt
# =============================================================================
github_download_sha256sums() {
    installer_log_info "Downloading SHA256SUMS.txt from GitHub..."
    
    mkdir -p "$CACHE_DIR"
    
    # Try curl first, then wget
    if has curl; then
        if curl -fsSL --connect-timeout 10 --max-time 30 "$GITHUB_SHA256_URL" -o "$SHA256_CACHE" 2>/dev/null; then
            installer_log_success "Downloaded SHA256SUMS.txt"
            return 0
        fi
    elif has wget; then
        if wget -q --timeout=30 "$GITHUB_SHA256_URL" -O "$SHA256_CACHE" 2>/dev/null; then
            installer_log_success "Downloaded SHA256SUMS.txt"
            return 0
        fi
    else
        installer_log_error "Neither curl nor wget found - cannot download SHA256SUMS.txt"
        return 1
    fi
    
    installer_log_warn "Failed to download SHA256SUMS.txt from GitHub"
    return 1
}

# =============================================================================
# VALIDATE FILE AGAINST GITHUB SHA256
# =============================================================================
github_validate_file() {
    local filepath="$1"
    local filename
    filename="$(basename "$filepath")"
    
    # Check if file exists
    if [[ ! -f "$filepath" ]]; then
        echo "MISSING: $filename (file not found)"
        return 2
    fi
    
    # Check if SHA256SUMS.txt is cached
    if [[ ! -f "$SHA256_CACHE" ]]; then
        echo "SKIP: $filename (no SHA256SUMS.txt cached)"
        return 3
    fi
    
    # Look for the file in SHA256SUMS.txt (skip comment lines starting with #)
    local expected_sha
    expected_sha=$(grep -v '^#' "$SHA256_CACHE" 2>/dev/null | grep -E "[[:space:]]${filename}$" | awk '{print $1}')
    
    if [[ -z "$expected_sha" ]]; then
        echo "UNKNOWN: $filename (not in SHA256SUMS.txt - possibly new file)"
        return 4
    fi
    
    # Calculate actual SHA256
    local actual_sha
    actual_sha=$(sha256sum "$filepath" 2>/dev/null | awk '{print $1}')
    
    if [[ -z "$actual_sha" ]]; then
        echo "ERROR: $filename (failed to calculate SHA256)"
        return 5
    fi
    
    # Compare
    if [[ "$actual_sha" == "$expected_sha" ]]; then
        echo "OK: $filename"
        return 0
    else
        echo "FAIL: $filename (checksum mismatch)"
        echo "  Expected: $expected_sha"
        echo "  Got:      $actual_sha"
        return 1
    fi
}

# =============================================================================
# VALIDATE DIRECTORY (NON-BLOCKING)
# =============================================================================
github_validate_directory() {
    local dir="${1:-$LIB_DIR}"
    local report_file="${2:-$VALIDATION_REPORT}"
    
    installer_log_info "Validating directory: $dir"
    
    # Download fresh SHA256SUMS.txt
    if ! github_download_sha256sums; then
        installer_log_warn "Proceeding with cached SHA256SUMS.txt (if available)"
    fi
    
    # Initialize counters
    local total=0
    local ok=0
    local fail=0
    local skip=0
    local unknown=0
    local missing=0
    
    # Clear report
    echo "# NFTBan Validation Report" > "$report_file"
    echo "# Generated: $(date -Is)" >> "$report_file"
    echo "# Directory: $dir" >> "$report_file"
    echo "" >> "$report_file"
    
    # Validate all .sh files in the directory
    while IFS= read -r filepath; do
        ((total++))
        
        local result
        result=$(github_validate_file "$filepath")
        local status=$?
        
        echo "$result" | tee -a "$report_file"
        
        case $status in
            0) ((ok++)) ;;
            1) ((fail++)) ;;
            2) ((missing++)) ;;
            3) ((skip++)) ;;
            4) ((unknown++)) ;;
            *) ((fail++)) ;;
        esac
        
    done < <(find "$dir" -type f -name "*.sh" 2>/dev/null)
    
    # Summary
    echo "" | tee -a "$report_file"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$report_file"
    echo "VALIDATION SUMMARY" | tee -a "$report_file"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$report_file"
    echo "  Total files:    $total" | tee -a "$report_file"
    echo "  ✓ Valid:        $ok" | tee -a "$report_file"
    echo "  ✗ Failed:       $fail" | tee -a "$report_file"
    echo "  ? Unknown:      $unknown (new/not tracked)" | tee -a "$report_file"
    echo "  ⊘ Missing:      $missing" | tee -a "$report_file"
    echo "  ⊝ Skipped:      $skip" | tee -a "$report_file"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$report_file"
    echo "" | tee -a "$report_file"
    
    if [[ $fail -gt 0 ]]; then
        installer_log_warn "⚠️  $fail file(s) failed validation!"
        installer_log_warn "Run 'nftban validate panel' to review issues"
        echo "⚠️  VALIDATION WARNINGS DETECTED" | tee -a "$report_file"
        echo "Run: nftban validate panel" | tee -a "$report_file"
    elif [[ $unknown -gt 0 ]]; then
        installer_log_info "ℹ️  $unknown new/untracked file(s) detected"
        echo "ℹ️  Some files are not yet in SHA256SUMS.txt" | tee -a "$report_file"
    fi
    
    if [[ $ok -gt 0 ]]; then
        installer_log_success "$ok file(s) validated successfully"
    fi
    
    echo "" | tee -a "$report_file"
    echo "Full report: $report_file" | tee -a "$report_file"
    
    # Return 0 (success) even if there are failures (non-blocking)
    return 0
}

# =============================================================================
# VALIDATE SINGLE FILE (CLI FRIENDLY)
# =============================================================================
github_validate_single() {
    local filepath="$1"
    
    if [[ -z "$filepath" ]]; then
        installer_log_error "Usage: github_validate_single <filepath>"
        return 1
    fi
    
    # Download SHA256SUMS.txt if not cached
    if [[ ! -f "$SHA256_CACHE" ]]; then
        github_download_sha256sums || return 1
    fi
    
    github_validate_file "$filepath"
    return $?
}

# =============================================================================
# CHECK IF SHA256SUMS.txt EXISTS ON GITHUB
# =============================================================================
github_check_sha256sums_exists() {
    installer_log_info "Checking if SHA256SUMS.txt exists on GitHub..."
    
    if has curl; then
        if curl -fsSL --head --connect-timeout 5 "$GITHUB_SHA256_URL" >/dev/null 2>&1; then
            installer_log_success "SHA256SUMS.txt exists on GitHub"
            return 0
        fi
    elif has wget; then
        if wget --spider --timeout=5 "$GITHUB_SHA256_URL" >/dev/null 2>&1; then
            installer_log_success "SHA256SUMS.txt exists on GitHub"
            return 0
        fi
    fi
    
    installer_log_warn "SHA256SUMS.txt not found on GitHub (may not exist yet)"
    return 1
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f github_download_sha256sums
export -f github_validate_file
export -f github_validate_directory
export -f github_validate_single
export -f github_check_sha256sums_exists

installer_log_debug "Validator GitHub module loaded"
