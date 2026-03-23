// =============================================================================
// NFTBan - Suricata Integration - Custom rules add/remove/edit/list/validate/backup
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="cmd_suricata"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Custom rules add/remove/edit/list/validate/backup"
// meta:inventory.files="/var/log/nftban/suricata/eve-alerts.json"
// meta:inventory.binaries="suricata"
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/suricata/*.conf"
// meta:inventory.systemd_units="suricata.service"
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================

package main

import (
	"fmt"
	"os"
	"strings"
	"text/tabwriter"

	"github.com/itcmsgr/nftban/internal/suricata/customrules"
	"github.com/itcmsgr/nftban/pkg/version"
)

// cmdSuricataCustomAdd adds a new custom rule
func cmdSuricataCustomAdd(rule string) error {
	fmt.Println(version.BannerWithEmoji("➕", "Add Custom Suricata Rule"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Create manager
	manager, err := customrules.NewManager()
	if err != nil {
		return fmt.Errorf("failed to create manager: %w", err)
	}

	// Add rule
	result, err := manager.AddRule(rule)
	if err != nil {
		if result != nil && len(result.Errors) > 0 {
			fmt.Println("✗ Validation failed:")
			for _, e := range result.Errors {
				fmt.Printf("  - %s\n", e)
			}
		}
		return err
	}

	fmt.Printf("✓ Custom rule added successfully\n\n")
	fmt.Printf("SID:     %d\n", result.SID)
	fmt.Printf("Action:  %s\n", result.Action)
	fmt.Printf("Message: %s\n", result.Message)
	fmt.Println()
	fmt.Println("Next steps:")
	fmt.Println("  1. Reload Suricata: systemctl reload suricata")
	fmt.Println("  2. Monitor alerts: nftban suricata sid info", result.SID)
	fmt.Println()

	return nil
}

// cmdSuricataCustomRemove removes a custom rule
func cmdSuricataCustomRemove(sid int) error {
	fmt.Println(version.BannerWithEmoji("🗑️", "Remove Custom Suricata Rule"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Create manager
	manager, err := customrules.NewManager()
	if err != nil {
		return fmt.Errorf("failed to create manager: %w", err)
	}

	// Get rule details before removal
	rule, err := manager.GetRule(sid)
	if err != nil {
		return err
	}

	fmt.Printf("Removing SID %d: %s\n", sid, rule.Message)
	fmt.Println()

	// Remove rule
	if err := manager.RemoveRule(sid); err != nil {
		return err
	}

	fmt.Println("✓ Custom rule removed successfully")
	fmt.Println()
	fmt.Println("Backup created before removal")
	fmt.Println("To undo: nftban suricata custom rollback")
	fmt.Println()

	return nil
}

// cmdSuricataCustomEdit edits an existing custom rule
func cmdSuricataCustomEdit(sid int, newRule string) error {
	fmt.Println(version.BannerWithEmoji("✏️", "Edit Custom Suricata Rule"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Create manager
	manager, err := customrules.NewManager()
	if err != nil {
		return fmt.Errorf("failed to create manager: %w", err)
	}

	// Update rule
	result, err := manager.UpdateRule(sid, newRule)
	if err != nil {
		if result != nil && len(result.Errors) > 0 {
			fmt.Println("✗ Validation failed:")
			for _, e := range result.Errors {
				fmt.Printf("  - %s\n", e)
			}
		}
		return err
	}

	fmt.Printf("✓ Custom rule updated successfully\n\n")
	fmt.Printf("SID:     %d\n", result.SID)
	fmt.Printf("Action:  %s\n", result.Action)
	fmt.Printf("Message: %s\n", result.Message)
	fmt.Println()
	fmt.Println("Reload Suricata to apply: systemctl reload suricata")
	fmt.Println()

	return nil
}

// cmdSuricataCustomList lists all custom rules
func cmdSuricataCustomList() error {
	fmt.Println(version.BannerWithEmoji("📋", "Custom Suricata Rules"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Create manager
	manager, err := customrules.NewManager()
	if err != nil {
		return fmt.Errorf("failed to create manager: %w", err)
	}

	// List rules
	rules, err := manager.ListRules()
	if err != nil {
		return err
	}

	if len(rules) == 0 {
		fmt.Println("No custom rules found")
		fmt.Println()
		fmt.Println("Add a rule:")
		fmt.Println("  nftban suricata custom add 'alert tcp any any -> any any (msg:\"Test\"; sid:9000000; rev:1;)'")
		fmt.Println()
		return nil
	}

	// Display table
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "SID\tStatus\tAction\tMessage")
	fmt.Fprintln(w, "---\t------\t------\t-------")

	for _, rule := range rules {
		status := "✓ Enabled"
		if !rule.Enabled {
			status = "✗ Disabled"
		}

		message := rule.Message
		if len(message) > 50 {
			message = message[:47] + "..."
		}

		fmt.Fprintf(w, "%d\t%s\t%s\t%s\n", rule.SID, status, rule.Action, message)
	}
	_ = w.Flush()

	fmt.Println()
	fmt.Printf("Total: %d custom rules\n", len(rules))
	fmt.Println()

	return nil
}

// cmdSuricataCustomValidate validates all custom rules
func cmdSuricataCustomValidate() error {
	fmt.Println(version.BannerWithEmoji("✅", "Validate Custom Suricata Rules"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Create manager
	manager, err := customrules.NewManager()
	if err != nil {
		return fmt.Errorf("failed to create manager: %w", err)
	}

	// Validate all
	results, err := manager.ValidateAll()
	if err != nil {
		return err
	}

	if len(results) == 0 {
		fmt.Println("No custom rules to validate")
		fmt.Println()
		return nil
	}

	// Display results
	allValid := true
	for sid, result := range results {
		if result.Valid {
			fmt.Printf("✓ SID %d: Valid\n", sid)
		} else {
			fmt.Printf("✗ SID %d: Invalid\n", sid)
			for _, e := range result.Errors {
				fmt.Printf("  - %s\n", e)
			}
			allValid = false
		}
	}

	fmt.Println()
	if allValid {
		fmt.Println("✅ All custom rules are valid")
	} else {
		fmt.Println("⚠️  Some rules have validation errors")
		return fmt.Errorf("validation failed")
	}
	fmt.Println()

	return nil
}

// cmdSuricataCustomEnable enables a custom rule
func cmdSuricataCustomEnable(sid int) error {
	fmt.Println(version.BannerWithEmoji("✅", "Enable Custom Rule"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Create manager
	manager, err := customrules.NewManager()
	if err != nil {
		return fmt.Errorf("failed to create manager: %w", err)
	}

	// Enable rule
	if err := manager.EnableRule(sid); err != nil {
		return err
	}

	fmt.Printf("✓ Custom rule SID %d enabled\n", sid)
	fmt.Println()
	fmt.Println("Reload Suricata to apply: systemctl reload suricata")
	fmt.Println()

	return nil
}

// cmdSuricataCustomDisable disables a custom rule
func cmdSuricataCustomDisable(sid int) error {
	fmt.Println(version.BannerWithEmoji("❌", "Disable Custom Rule"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Create manager
	manager, err := customrules.NewManager()
	if err != nil {
		return fmt.Errorf("failed to create manager: %w", err)
	}

	// Disable rule
	if err := manager.DisableRule(sid); err != nil {
		return err
	}

	fmt.Printf("✓ Custom rule SID %d disabled\n", sid)
	fmt.Println()
	fmt.Println("Reload Suricata to apply: systemctl reload suricata")
	fmt.Println()

	return nil
}

// cmdSuricataCustomBackup creates a backup of custom rules
func cmdSuricataCustomBackup() error {
	fmt.Println(version.BannerWithEmoji("💾", "Backup Custom Rules"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Create manager
	manager, err := customrules.NewManager()
	if err != nil {
		return fmt.Errorf("failed to create manager: %w", err)
	}

	// Create backup
	if err := manager.CreateBackup(); err != nil {
		return err
	}

	fmt.Println("✓ Backup created successfully")
	fmt.Println()

	// List backups
	backups, err := manager.ListBackups()
	if err != nil {
		return err
	}

	fmt.Printf("Available backups (%d):\n", len(backups))
	for _, backup := range backups {
		fmt.Printf("  - %s\n", backup)
	}
	fmt.Println()

	return nil
}

// cmdSuricataCustomRollback restores from a backup
func cmdSuricataCustomRollback(backupName string) error {
	fmt.Println(version.BannerWithEmoji("⏮️", "Rollback Custom Rules"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Create manager
	manager, err := customrules.NewManager()
	if err != nil {
		return fmt.Errorf("failed to create manager: %w", err)
	}

	fmt.Printf("Rolling back to: %s\n", backupName)
	fmt.Println()

	// Rollback
	if err := manager.Rollback(backupName); err != nil {
		return err
	}

	fmt.Println("✓ Rollback completed successfully")
	fmt.Println()
	fmt.Println("Current state backed up before rollback")
	fmt.Println("Reload Suricata to apply: systemctl reload suricata")
	fmt.Println()

	return nil
}
