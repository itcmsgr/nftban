// =============================================================================
// NFTBan - CLI Smoke Framework: Test Registry
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="smoke-registry"
// meta:type="package"
// meta:version="1.94.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-16"
// meta:description="Registry-driven smoke test definitions with strict PASS/FAIL/SKIP semantics"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================

package smoke

import "time"

// SmokeTest defines a single registered smoke probe.
// All test execution is driven by this metadata — no ad hoc logic outside the registry.
type SmokeTest struct {
	ID            string
	Name          string
	Category      string   // truth, daemon, config, metrics
	Command       []string // command + args to execute
	AllowedExit   []int    // exit codes that count as PASS (e.g. [0,1,2])
	Timeout       time.Duration
	Prerequisites []Prerequisite
	FatalPatterns []string              // stderr/stdout patterns that force FAIL
	Assert        func(TestOutput) bool // custom assertion on output (optional)
	Notes         string
}

// Prerequisite defines a condition that must be true for a test to run.
// If not met, the test is SKIP (not FAIL).
type Prerequisite struct {
	Type string // "daemon", "file", "binary"
	Name string // e.g. "nftband.service", "/etc/nftban/main.conf", "nftban-validate"
}

// TestOutput holds captured output from a test execution.
type TestOutput struct {
	ExitCode int
	Stdout   string
	Stderr   string
	Duration time.Duration
}

// DefaultFatalPatterns are runtime errors that always indicate FAIL.
// These catch shell explosions, Go panics, and missing binaries.
var DefaultFatalPatterns = []string{
	"bad array subscript",
	"unbound variable",
	"syntax error",
	"command not found",
	"No such file or directory",
	"panic:",
	"segmentation fault",
	"traceback",
	"SIGSEGV",
	"nil pointer dereference",
}

// DefaultRegistry returns the Phase 1 smoke test set.
// Small, high-value, contract-safe. No module-deep or counter assertions.
func DefaultRegistry() []SmokeTest {
	return []SmokeTest{
		// === TRUTH (validator-backed) ===
		{
			ID:          "T1",
			Name:        "validator JSON",
			Category:    "truth",
			Command:     []string{"nftban-validate", "--json"},
			AllowedExit: []int{0, 1, 2},
			Timeout:     10 * time.Second,
			Prerequisites: []Prerequisite{
				{Type: "binary", Name: "nftban-validate"},
			},
			FatalPatterns: DefaultFatalPatterns,
			Assert: func(o TestOutput) bool {
				return len(o.Stdout) > 2 && o.Stdout[0] == '{'
			},
			Notes: "Validator must return valid JSON with .status field",
		},
		{
			ID:          "T2",
			Name:        "health JSON",
			Category:    "truth",
			Command:     []string{"nftban", "health", "--json"},
			AllowedExit: []int{0, 1, 2},
			Timeout:     10 * time.Second,
			Prerequisites: []Prerequisite{
				{Type: "binary", Name: "nftban"},
			},
			FatalPatterns: DefaultFatalPatterns,
			Assert: func(o TestOutput) bool {
				return len(o.Stdout) > 2 && o.Stdout[0] == '{'
			},
			Notes: "Health must return valid JSON",
		},
		{
			ID:          "T3",
			Name:        "status",
			Category:    "truth",
			Command:     []string{"nftban", "status"},
			AllowedExit: []int{0, 1, 2},
			Timeout:     10 * time.Second,
			Prerequisites: []Prerequisite{
				{Type: "binary", Name: "nftban"},
			},
			FatalPatterns: DefaultFatalPatterns,
			Notes:         "Status command must not crash",
		},

		// === DAEMON ===
		{
			ID:       "D1",
			Name:     "nftband service",
			Category: "daemon",
			Command:  []string{"systemctl", "is-active", "nftband.service"},
			AllowedExit: []int{0},
			Timeout:     5 * time.Second,
			Prerequisites: []Prerequisite{
				{Type: "binary", Name: "systemctl"},
			},
			FatalPatterns: nil,
			Notes:         "Daemon must be active for IPC and ban operations",
		},

		// === CONFIG ===
		{
			ID:       "C1",
			Name:     "main.conf readable",
			Category: "config",
			Command:  []string{"test", "-r", "/etc/nftban/nftban.conf"},
			AllowedExit: []int{0},
			Timeout:     2 * time.Second,
			Prerequisites: []Prerequisite{
				{Type: "file", Name: "/etc/nftban/nftban.conf"},
			},
			FatalPatterns: nil,
			Notes:         "Main config must exist and be readable",
		},

		// === METRICS ===
		{
			ID:       "M1",
			Name:     "/metrics reachable",
			Category: "metrics",
			Command:  []string{"curl", "-sf", "--max-time", "5", "http://127.0.0.1:9580/metrics"},
			AllowedExit: []int{0},
			Timeout:     10 * time.Second,
			Prerequisites: []Prerequisite{
				{Type: "daemon", Name: "nftband.service"},
				{Type: "binary", Name: "curl"},
			},
			FatalPatterns: nil,
			Assert: func(o TestOutput) bool {
				return len(o.Stdout) > 100 // metrics output should be substantial
			},
			Notes: "Daemon /metrics endpoint must respond",
		},
	}
}
