// =============================================================================
// NFTBan - Suricata Custom Rule Validator
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="validator"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Validates Suricata rule syntax with SID range 9000000-9999999"
// meta:input="Suricata rule strings"
// meta:output="Validation results, extracted SID"
// meta:depends="os/exec,regexp"
// meta:inventory.files=""
// meta:inventory.binaries="suricata"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package customrules

import (
	"fmt"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
)

// SID range for custom rules (9000000-9999999)
const (
	MinCustomSID = 9000000
	MaxCustomSID = 9999999
)

// ValidationResult holds validation outcome
type ValidationResult struct {
	Valid   bool
	Errors  []string
	SID     int
	Action  string // alert, drop, reject
	Message string
}

// ValidateRule validates a Suricata rule
func ValidateRule(rule string) (*ValidationResult, error) {
	result := &ValidationResult{
		Valid:  true,
		Errors: make([]string, 0),
	}

	rule = strings.TrimSpace(rule)

	// Empty rule
	if rule == "" {
		result.Valid = false
		result.Errors = append(result.Errors, "Rule cannot be empty")
		return result, nil
	}

	// Comment line
	if strings.HasPrefix(rule, "#") {
		result.Valid = false
		result.Errors = append(result.Errors, "Rule is commented out")
		return result, nil
	}

	// Validate basic structure
	if err := validateBasicStructure(rule, result); err != nil {
		return nil, err
	}

	// Extract and validate SID
	if err := validateSID(rule, result); err != nil {
		return nil, err
	}

	// Validate with suricata if available
	if err := validateWithSuricata(rule, result); err != nil {
		// Don't fail if suricata not available, just skip this validation
		result.Errors = append(result.Errors, fmt.Sprintf("Warning: Could not validate with suricata: %v", err))
	}

	if len(result.Errors) > 0 {
		result.Valid = false
	}

	return result, nil
}

// validateBasicStructure checks basic rule format
func validateBasicStructure(rule string, result *ValidationResult) error {
	// Must start with action (alert, drop, reject, pass)
	validActions := []string{"alert", "drop", "reject", "pass"}
	actionFound := false
	for _, action := range validActions {
		if strings.HasPrefix(rule, action+" ") {
			result.Action = action
			actionFound = true
			break
		}
	}

	if !actionFound {
		result.Errors = append(result.Errors, "Rule must start with action: alert, drop, reject, or pass")
		return nil
	}

	// Must contain protocol
	validProtocols := []string{"tcp", "udp", "icmp", "ip", "http", "ftp", "tls", "smb", "dns"}
	protocolFound := false
	for _, proto := range validProtocols {
		if strings.Contains(strings.ToLower(rule), " "+proto+" ") {
			protocolFound = true
			break
		}
	}

	if !protocolFound {
		result.Errors = append(result.Errors, "Rule must specify protocol (tcp, udp, icmp, ip, http, etc.)")
	}

	// Must contain parentheses for rule options
	if !strings.Contains(rule, "(") || !strings.Contains(rule, ")") {
		result.Errors = append(result.Errors, "Rule must contain options in parentheses")
		return nil
	}

	// Check balanced parentheses
	openCount := strings.Count(rule, "(")
	closeCount := strings.Count(rule, ")")
	if openCount != closeCount {
		result.Errors = append(result.Errors, fmt.Sprintf("Unbalanced parentheses: %d open, %d close", openCount, closeCount))
	}

	// Must contain msg
	if !strings.Contains(rule, "msg:") {
		result.Errors = append(result.Errors, "Rule must contain 'msg:' field")
	}

	// Extract message for display
	msgRegex := regexp.MustCompile(`msg:\s*"([^"]+)"`)
	if matches := msgRegex.FindStringSubmatch(rule); len(matches) > 1 {
		result.Message = matches[1]
	}

	return nil
}

// validateSID extracts and validates the SID
func validateSID(rule string, result *ValidationResult) error {
	// Extract SID using regex
	sidRegex := regexp.MustCompile(`sid:\s*(\d+)\s*;`)
	matches := sidRegex.FindStringSubmatch(rule)

	if len(matches) < 2 {
		result.Errors = append(result.Errors, "Rule must contain 'sid:' field")
		return nil
	}

	sid, err := strconv.Atoi(matches[1])
	if err != nil {
		result.Errors = append(result.Errors, fmt.Sprintf("Invalid SID format: %s", matches[1]))
		return nil
	}

	result.SID = sid

	// Validate SID range for custom rules
	if sid < MinCustomSID || sid > MaxCustomSID {
		result.Errors = append(result.Errors, fmt.Sprintf("Custom rule SID must be in range %d-%d (got %d)", MinCustomSID, MaxCustomSID, sid))
	}

	// Check for revision
	if !strings.Contains(rule, "rev:") {
		result.Errors = append(result.Errors, "Rule should contain 'rev:' field (recommended)")
	}

	return nil
}

// validateWithSuricata validates rule syntax using suricata binary
func validateWithSuricata(rule string, result *ValidationResult) error {
	// Check if suricata is available
	if _, err := exec.LookPath("suricata"); err != nil {
		return fmt.Errorf("suricata binary not found")
	}

	// Create temporary rule file content
	// We use echo and pipe to avoid file creation
	cmd := exec.Command("suricata", "-T", "-S", "-")
	cmd.Stdin = strings.NewReader(rule + "\n")

	output, err := cmd.CombinedOutput()
	if err != nil {
		// Parse error from output
		outputStr := string(output)
		if strings.Contains(outputStr, "ERROR") || strings.Contains(outputStr, "WARN") {
			// Extract error message
			lines := strings.Split(outputStr, "\n")
			for _, line := range lines {
				if strings.Contains(line, "ERROR") || strings.Contains(line, "WARN") {
					result.Errors = append(result.Errors, "Suricata validation: "+line)
				}
			}
		} else {
			result.Errors = append(result.Errors, fmt.Sprintf("Suricata validation failed: %v", err))
		}
	}

	return nil
}

// ValidateSIDAvailable checks if a SID is already in use
func ValidateSIDAvailable(sid int, rulesDir string) (bool, error) {
	// Check if SID is in valid range
	if sid < MinCustomSID || sid > MaxCustomSID {
		return false, fmt.Errorf("SID must be in range %d-%d", MinCustomSID, MaxCustomSID)
	}

	// Search for SID in custom rules directory
	cmd := exec.Command("grep", "-r", fmt.Sprintf("sid:%d;", sid), rulesDir)
	output, err := cmd.CombinedOutput()

	if err != nil {
		// grep returns error code 1 if no match (which means SID is available)
		if exitErr, ok := err.(*exec.ExitError); ok && exitErr.ExitCode() == 1 {
			return true, nil // SID available
		}
		// Other errors
		return false, fmt.Errorf("failed to check SID availability: %w", err)
	}

	// SID found in output
	if len(output) > 0 {
		return false, nil // SID in use
	}

	return true, nil // SID available
}

// SanitizeRule removes extra whitespace and normalizes formatting
func SanitizeRule(rule string) string {
	rule = strings.TrimSpace(rule)

	// Normalize multiple spaces to single space
	spaceRegex := regexp.MustCompile(`\s+`)
	rule = spaceRegex.ReplaceAllString(rule, " ")

	// Ensure semicolons have no space before them
	rule = strings.ReplaceAll(rule, " ;", ";")

	return rule
}

// GetNextAvailableSID finds the next available SID in custom range
func GetNextAvailableSID(rulesDir string) (int, error) {
	// Start from minimum custom SID
	for sid := MinCustomSID; sid <= MaxCustomSID; sid++ {
		available, err := ValidateSIDAvailable(sid, rulesDir)
		if err != nil {
			return 0, err
		}
		if available {
			return sid, nil
		}
	}

	return 0, fmt.Errorf("no available SIDs in custom range %d-%d", MinCustomSID, MaxCustomSID)
}
