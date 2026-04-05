// =============================================================================
// NFTBan v1.78 - Validator CLI Helpers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="validator-cli"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-05"
// meta:description="CLI output helpers for the validator"
// meta:inventory.files="internal/validator/cli.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package validator

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
)

// RunValidation is a convenience function that runs validation and returns
// the result. Returns (result, nil) even if status is DOWN - that's a valid result.
func RunValidation(ctx context.Context) (*ValidationResult, error) {
	return ValidateKernel(ctx)
}

// ToJSON converts the validation result to JSON.
func (r *ValidationResult) ToJSON() ([]byte, error) {
	return json.MarshalIndent(r, "", "  ")
}

// StatusString returns a human-readable status with emoji.
func (r *ValidationResult) StatusString() string {
	switch r.Status {
	case StatusProtected:
		return "PROTECTED"
	case StatusDegraded:
		return "DEGRADED"
	case StatusDown:
		return "DOWN"
	default:
		return string(r.Status)
	}
}

// ExitCode returns the appropriate exit code for the status.
// 0 = PROTECTED, 1 = DEGRADED, 2 = DOWN
func (r *ValidationResult) ExitCode() int {
	switch r.Status {
	case StatusProtected:
		return 0
	case StatusDegraded:
		return 1
	case StatusDown:
		return 2
	default:
		return 2
	}
}

// PrintSummary prints a human-readable summary to stdout.
func (r *ValidationResult) PrintSummary() {
	fmt.Printf("NFTBan Kernel Validation\n")
	fmt.Printf("========================\n")
	fmt.Printf("Status: %s\n", r.StatusString())
	fmt.Printf("Timestamp: %s\n", r.Timestamp.Format("2006-01-02 15:04:05"))
	fmt.Println()

	// Families
	fmt.Printf("Families:\n")
	for _, fr := range r.Families {
		status := "OK"
		if fr.Status == StatusDegraded {
			status = "DEGRADED"
		}
		tableStr := "present"
		if !fr.TablePresent {
			tableStr = "MISSING"
		}
		fmt.Printf("  %s nftban: %s (table %s, %d chains, %d sets)\n",
			fr.Family, status, tableStr, fr.ChainCount, fr.SetCount)

		if !fr.Anchors.Ordered || len(fr.Anchors.Missing) > 0 {
			fmt.Printf("    Anchors: %d/%d (ordered: %v)\n",
				fr.Anchors.FoundCount, fr.Anchors.RequiredCount, fr.Anchors.Ordered)
			if len(fr.Anchors.Missing) > 0 {
				fmt.Printf("    Missing: %s\n", strings.Join(fr.Anchors.Missing, ", "))
			}
		}

		if len(fr.HelperChains.Missing) > 0 {
			fmt.Printf("    Helper chains missing: %s\n",
				strings.Join(fr.HelperChains.Missing, ", "))
		}
	}
	fmt.Println()

	// Chain counts
	fmt.Printf("Chain Counts:\n")
	fmt.Printf("  IPv4: %d total (%d base, %d helper)\n",
		r.ChainCount.IPv4Total, r.ChainCount.IPv4Base, r.ChainCount.IPv4Helper)
	fmt.Printf("  IPv6: %d total (%d base, %d helper)\n",
		r.ChainCount.IPv6Total, r.ChainCount.IPv6Base, r.ChainCount.IPv6Helper)
	fmt.Printf("  Total: %d\n", r.ChainCount.TotalChains)
	fmt.Println()

	// Module truth
	fmt.Printf("Module Status:\n")
	fmt.Printf("  DDoS: %s\n", enabledStr(r.ModuleTruth.DDoS.Enabled))
	fmt.Printf("  Portscan: %s\n", enabledStr(r.ModuleTruth.Portscan.Enabled))
	fmt.Printf("  Blacklist: %s\n", enabledStr(r.ModuleTruth.Blacklist.Enabled))
	fmt.Printf("  Whitelist: %s\n", enabledStr(r.ModuleTruth.Whitelist.Enabled))
	fmt.Printf("  Service: %s\n", enabledStr(r.ModuleTruth.ServiceAdmission.Enabled))
	fmt.Println()

	// Findings
	if len(r.Findings) > 0 {
		fmt.Printf("Findings (%d):\n", len(r.Findings))
		for _, f := range r.Findings {
			sev := strings.ToUpper(string(f.Severity))
			fmt.Printf("  [%s] %s: %s\n", sev, f.Code, f.Message)
		}
	} else {
		fmt.Printf("Findings: none\n")
	}
}

func enabledStr(b bool) string {
	if b {
		return "ENABLED"
	}
	return "disabled"
}

// CompareChainCounts compares pre and post chain counts for rebuild safety.
// Returns (degraded bool, message string).
func CompareChainCounts(pre, post ChainCounts, tolerance int) (bool, string) {
	if post.TotalChains < pre.TotalChains-tolerance {
		return true, fmt.Sprintf("chain count dropped: %d -> %d (tolerance: %d)",
			pre.TotalChains, post.TotalChains, tolerance)
	}
	if post.IPv4Helper < pre.IPv4Helper {
		return true, fmt.Sprintf("IPv4 helper chains dropped: %d -> %d",
			pre.IPv4Helper, post.IPv4Helper)
	}
	if post.IPv6Helper < pre.IPv6Helper {
		return true, fmt.Sprintf("IPv6 helper chains dropped: %d -> %d",
			pre.IPv6Helper, post.IPv6Helper)
	}
	return false, ""
}
