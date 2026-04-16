// =============================================================================
// NFTBan - CLI Smoke Framework: Report Formatter
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="smoke-report"
// meta:type="package"
// meta:version="1.94.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-16"
// meta:description="Human and JSON output formatters for smoke test results"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package smoke

import (
	"encoding/json"
	"fmt"
	"strings"
)

// FormatHuman returns a human-readable smoke report.
func FormatHuman(s Summary) string {
	var b strings.Builder

	b.WriteString(fmt.Sprintf("NFTBan Smoke — v%s\n", s.Version))
	b.WriteString(strings.Repeat("=", 30) + "\n\n")

	// Group by category
	categories := []string{"truth", "daemon", "config", "metrics"}
	for _, cat := range categories {
		tests := filterByCategory(s.Tests, cat)
		if len(tests) == 0 {
			continue
		}

		b.WriteString(fmt.Sprintf("  %s:\n", cat))
		for _, t := range tests {
			icon := statusIcon(t.Status)
			line := fmt.Sprintf("    %s %s", icon, t.Name)
			if t.Detail != "" && t.Status != StatusPass {
				line += fmt.Sprintf(" (%s)", t.Detail)
			}
			b.WriteString(line + "\n")
		}
		b.WriteString("\n")
	}

	total := s.Counts.Pass + s.Counts.Fail + s.Counts.Skip
	b.WriteString(fmt.Sprintf("Result: %s (%d/%d PASS", s.Result, s.Counts.Pass, total))
	if s.Counts.Skip > 0 {
		b.WriteString(fmt.Sprintf(", %d SKIP", s.Counts.Skip))
	}
	if s.Counts.Fail > 0 {
		b.WriteString(fmt.Sprintf(", %d FAIL", s.Counts.Fail))
	}
	b.WriteString(")\n")

	return b.String()
}

// FormatJSON returns a JSON smoke report.
func FormatJSON(s Summary) (string, error) {
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return "", err
	}
	return string(data), nil
}

// ExitCode returns the process exit code for a smoke summary.
// 0 = all PASS (SKIPs don't count as failure)
// 1 = any FAIL
func ExitCode(s Summary) int {
	if s.Counts.Fail > 0 {
		return 1
	}
	return 0
}

func filterByCategory(tests []TestResult, cat string) []TestResult {
	var out []TestResult
	for _, t := range tests {
		if t.Category == cat {
			out = append(out, t)
		}
	}
	return out
}

func statusIcon(status string) string {
	switch status {
	case StatusPass:
		return "ok"
	case StatusFail:
		return "FAIL"
	case StatusSkip:
		return "skip"
	default:
		return "?"
	}
}
