// =============================================================================
// NFTBan - Suricata Custom Rules Manager
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="manager"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="CRUD operations for custom Suricata rules with backup management"
// meta:input="Custom rule definitions"
// meta:output="Rule file modifications"
// meta:depends="github.com/itcmsgr/nftban/internal/nftbanconf"
// meta:inventory.files="/etc/nftban/suricata/rules/custom.rules"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package customrules

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/nftbanconf"
)

// CustomRule represents a custom Suricata rule
type CustomRule struct {
	SID      int
	FilePath string
	Rule     string
	Message  string
	Action   string
	Enabled  bool
}

// Manager handles custom rule operations
type Manager struct {
	rulesDir   string
	backupDir  string
	customFile string
}

// NewManager creates a new custom rules manager
func NewManager() (*Manager, error) {
	cfg := nftbanconf.MustLoad()
	rulesDir := filepath.Join(cfg.ConfigDir, "suricata/rules")
	backupDir := filepath.Join(cfg.ConfigDir, "suricata/rules/backups")
	customFile := filepath.Join(rulesDir, "custom.rules")

	// Ensure directories exist
	if err := os.MkdirAll(rulesDir, 0755); err != nil {
		return nil, fmt.Errorf("failed to create rules directory: %w", err)
	}
	if err := os.MkdirAll(backupDir, 0755); err != nil {
		return nil, fmt.Errorf("failed to create backup directory: %w", err)
	}

	// Create custom.rules if it doesn't exist
	if _, err := os.Stat(customFile); os.IsNotExist(err) {
		header := `# NFTBan Custom Suricata Rules
# SID Range: 9000000-9999999
# Edit with: nftban suricata custom add/edit
# Validate with: nftban suricata custom validate
#
# IMPORTANT: Always use SIDs in range 9000000-9999999
# Lower SIDs are reserved for official rulesets
#
`
		if err := os.WriteFile(customFile, []byte(header), 0644); err != nil {
			return nil, fmt.Errorf("failed to create custom.rules: %w", err)
		}
	}

	return &Manager{
		rulesDir:   rulesDir,
		backupDir:  backupDir,
		customFile: customFile,
	}, nil
}

// AddRule adds a new custom rule
func (m *Manager) AddRule(rule string) (*ValidationResult, error) {
	// Sanitize and validate
	rule = SanitizeRule(rule)
	result, err := ValidateRule(rule)
	if err != nil {
		return nil, err
	}

	if !result.Valid {
		return result, fmt.Errorf("rule validation failed")
	}

	// Check if SID is already in use
	available, err := ValidateSIDAvailable(result.SID, m.rulesDir)
	if err != nil {
		return result, err
	}
	if !available {
		return result, fmt.Errorf("SID %d is already in use", result.SID)
	}

	// Create backup before modification
	if err := m.CreateBackup(); err != nil {
		return result, fmt.Errorf("failed to create backup: %w", err)
	}

	// Append rule to custom.rules
	f, err := os.OpenFile(m.customFile, os.O_APPEND|os.O_WRONLY, 0644)
	if err != nil {
		return result, fmt.Errorf("failed to open custom.rules: %w", err)
	}
	defer f.Close()

	// Ensure rule ends with newline
	if !strings.HasSuffix(rule, "\n") {
		rule += "\n"
	}

	if _, err := f.WriteString(rule); err != nil {
		return result, fmt.Errorf("failed to write rule: %w", err)
	}

	return result, nil
}

// RemoveRule removes a custom rule by SID
func (m *Manager) RemoveRule(sid int) error {
	// Validate SID range
	if sid < MinCustomSID || sid > MaxCustomSID {
		return fmt.Errorf("SID must be in custom range %d-%d", MinCustomSID, MaxCustomSID)
	}

	// Create backup
	if err := m.CreateBackup(); err != nil {
		return fmt.Errorf("failed to create backup: %w", err)
	}

	// Read current rules
	content, err := os.ReadFile(m.customFile)
	if err != nil {
		return fmt.Errorf("failed to read custom.rules: %w", err)
	}

	// Filter out the rule with matching SID
	lines := strings.Split(string(content), "\n")
	newLines := make([]string, 0, len(lines))
	removed := false

	sidPattern := fmt.Sprintf("sid:%d;", sid)

	for _, line := range lines {
		if strings.Contains(line, sidPattern) && !strings.HasPrefix(strings.TrimSpace(line), "#") {
			removed = true
			continue // Skip this line
		}
		newLines = append(newLines, line)
	}

	if !removed {
		return fmt.Errorf("rule with SID %d not found", sid)
	}

	// Write back
	newContent := strings.Join(newLines, "\n")
	if err := os.WriteFile(m.customFile, []byte(newContent), 0644); err != nil {
		return fmt.Errorf("failed to write custom.rules: %w", err)
	}

	return nil
}

// UpdateRule updates an existing rule
func (m *Manager) UpdateRule(sid int, newRule string) (*ValidationResult, error) {
	// Sanitize and validate new rule
	newRule = SanitizeRule(newRule)
	result, err := ValidateRule(newRule)
	if err != nil {
		return nil, err
	}

	if !result.Valid {
		return result, fmt.Errorf("rule validation failed")
	}

	// Ensure new rule has the same SID
	if result.SID != sid {
		return result, fmt.Errorf("new rule SID (%d) must match original SID (%d)", result.SID, sid)
	}

	// Create backup
	if err := m.CreateBackup(); err != nil {
		return result, fmt.Errorf("failed to create backup: %w", err)
	}

	// Read current rules
	content, err := os.ReadFile(m.customFile)
	if err != nil {
		return result, fmt.Errorf("failed to read custom.rules: %w", err)
	}

	// Replace the rule
	lines := strings.Split(string(content), "\n")
	newLines := make([]string, 0, len(lines))
	updated := false

	sidPattern := fmt.Sprintf("sid:%d;", sid)

	for _, line := range lines {
		if strings.Contains(line, sidPattern) && !strings.HasPrefix(strings.TrimSpace(line), "#") {
			newLines = append(newLines, newRule)
			updated = true
		} else {
			newLines = append(newLines, line)
		}
	}

	if !updated {
		return result, fmt.Errorf("rule with SID %d not found", sid)
	}

	// Write back
	newContent := strings.Join(newLines, "\n")
	if err := os.WriteFile(m.customFile, []byte(newContent), 0644); err != nil {
		return result, fmt.Errorf("failed to write custom.rules: %w", err)
	}

	return result, nil
}

// EnableRule enables a rule by removing comment
func (m *Manager) EnableRule(sid int) error {
	return m.setRuleEnabled(sid, true)
}

// DisableRule disables a rule by commenting it out
func (m *Manager) DisableRule(sid int) error {
	return m.setRuleEnabled(sid, false)
}

// setRuleEnabled enables or disables a rule
func (m *Manager) setRuleEnabled(sid int, enabled bool) error {
	// Create backup
	if err := m.CreateBackup(); err != nil {
		return fmt.Errorf("failed to create backup: %w", err)
	}

	// Read current rules
	content, err := os.ReadFile(m.customFile)
	if err != nil {
		return fmt.Errorf("failed to read custom.rules: %w", err)
	}

	// Modify the rule
	lines := strings.Split(string(content), "\n")
	newLines := make([]string, 0, len(lines))
	modified := false

	sidPattern := fmt.Sprintf("sid:%d;", sid)

	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.Contains(line, sidPattern) {
			if enabled {
				// Remove comment if present
				if strings.HasPrefix(trimmed, "#") {
					line = strings.TrimPrefix(trimmed, "#")
					line = strings.TrimSpace(line)
					modified = true
				}
			} else {
				// Add comment if not present
				if !strings.HasPrefix(trimmed, "#") {
					line = "# " + trimmed
					modified = true
				}
			}
		}
		newLines = append(newLines, line)
	}

	if !modified {
		if enabled {
			return fmt.Errorf("rule with SID %d is already enabled or not found", sid)
		}
		return fmt.Errorf("rule with SID %d is already disabled or not found", sid)
	}

	// Write back
	newContent := strings.Join(newLines, "\n")
	if err := os.WriteFile(m.customFile, []byte(newContent), 0644); err != nil {
		return fmt.Errorf("failed to write custom.rules: %w", err)
	}

	return nil
}

// ListRules lists all custom rules
func (m *Manager) ListRules() ([]*CustomRule, error) {
	file, err := os.Open(m.customFile)
	if err != nil {
		return nil, fmt.Errorf("failed to open custom.rules: %w", err)
	}
	defer file.Close()

	rules := make([]*CustomRule, 0)
	scanner := bufio.NewScanner(file)

	for scanner.Scan() {
		line := scanner.Text()
		trimmed := strings.TrimSpace(line)

		// Skip empty lines and header comments
		if trimmed == "" || strings.HasPrefix(trimmed, "# NFTBan") || strings.HasPrefix(trimmed, "# SID") {
			continue
		}

		// Check if disabled (commented)
		enabled := !strings.HasPrefix(trimmed, "#")
		if !enabled {
			trimmed = strings.TrimPrefix(trimmed, "#")
			trimmed = strings.TrimSpace(trimmed)
		}

		// Skip if not a rule line
		if !strings.Contains(trimmed, "sid:") {
			continue
		}

		// Validate to extract metadata
		result, err := ValidateRule(trimmed)
		if err != nil {
			continue // Skip invalid rules
		}

		rule := &CustomRule{
			SID:      result.SID,
			FilePath: m.customFile,
			Rule:     trimmed,
			Message:  result.Message,
			Action:   result.Action,
			Enabled:  enabled,
		}

		rules = append(rules, rule)
	}

	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("error reading custom.rules: %w", err)
	}

	return rules, nil
}

// GetRule retrieves a specific rule by SID
func (m *Manager) GetRule(sid int) (*CustomRule, error) {
	rules, err := m.ListRules()
	if err != nil {
		return nil, err
	}

	for _, rule := range rules {
		if rule.SID == sid {
			return rule, nil
		}
	}

	return nil, fmt.Errorf("rule with SID %d not found", sid)
}

// ValidateAll validates all custom rules
func (m *Manager) ValidateAll() (map[int]*ValidationResult, error) {
	rules, err := m.ListRules()
	if err != nil {
		return nil, err
	}

	results := make(map[int]*ValidationResult)

	for _, rule := range rules {
		result, err := ValidateRule(rule.Rule)
		if err != nil {
			return nil, fmt.Errorf("failed to validate SID %d: %w", rule.SID, err)
		}
		results[rule.SID] = result
	}

	return results, nil
}

// CreateBackup creates a timestamped backup of custom.rules
func (m *Manager) CreateBackup() error {
	// Check if custom.rules exists
	if _, err := os.Stat(m.customFile); os.IsNotExist(err) {
		return nil // Nothing to backup
	}

	// Read current content
	content, err := os.ReadFile(m.customFile)
	if err != nil {
		return fmt.Errorf("failed to read custom.rules: %w", err)
	}

	// Create backup filename with timestamp
	timestamp := time.Now().Format("20060102-150405")
	backupFile := filepath.Join(m.backupDir, fmt.Sprintf("custom.rules.%s", timestamp))

	// Write backup
	if err := os.WriteFile(backupFile, content, 0644); err != nil {
		return fmt.Errorf("failed to write backup: %w", err)
	}

	// Cleanup old backups (keep last 10)
	if err := m.cleanupOldBackups(10); err != nil {
		// Log but don't fail
		fmt.Printf("Warning: failed to cleanup old backups: %v\n", err)
	}

	return nil
}

// cleanupOldBackups removes old backups, keeping only the most recent N
func (m *Manager) cleanupOldBackups(keep int) error {
	files, err := filepath.Glob(filepath.Join(m.backupDir, "custom.rules.*"))
	if err != nil {
		return err
	}

	if len(files) <= keep {
		return nil // Nothing to cleanup
	}

	// Sort by modification time (oldest first)
	// Since we use timestamp in filename, alphabetical sort works
	// Remove oldest files
	for i := 0; i < len(files)-keep; i++ {
		if err := os.Remove(files[i]); err != nil {
			return err
		}
	}

	return nil
}

// ListBackups lists available backups
func (m *Manager) ListBackups() ([]string, error) {
	files, err := filepath.Glob(filepath.Join(m.backupDir, "custom.rules.*"))
	if err != nil {
		return nil, err
	}

	// Extract just the filenames
	backups := make([]string, len(files))
	for i, file := range files {
		backups[i] = filepath.Base(file)
	}

	return backups, nil
}

// Rollback restores from a backup
func (m *Manager) Rollback(backupName string) error {
	backupFile := filepath.Join(m.backupDir, backupName)

	// Check if backup exists
	if _, err := os.Stat(backupFile); os.IsNotExist(err) {
		return fmt.Errorf("backup not found: %s", backupName)
	}

	// Create a backup of current state before rollback
	if err := m.CreateBackup(); err != nil {
		return fmt.Errorf("failed to create pre-rollback backup: %w", err)
	}

	// Read backup content
	content, err := os.ReadFile(backupFile)
	if err != nil {
		return fmt.Errorf("failed to read backup: %w", err)
	}

	// Write to custom.rules
	if err := os.WriteFile(m.customFile, content, 0644); err != nil {
		return fmt.Errorf("failed to restore backup: %w", err)
	}

	return nil
}
