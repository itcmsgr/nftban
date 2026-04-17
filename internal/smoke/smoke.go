// =============================================================================
// NFTBan - CLI Smoke Framework: Runner
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="smoke-runner"
// meta:type="package"
// meta:version="1.94.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-16"
// meta:description="Executes registered smoke tests with prerequisite checking and fatal error detection"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================

package smoke

import (
	"context"
	"os/exec"
	"strings"
	"time"
)

// Status constants for test results.
const (
	StatusPass = "PASS"
	StatusFail = "FAIL"
	StatusSkip = "SKIP"
)

// TestResult holds the outcome of a single smoke test.
type TestResult struct {
	ID         string        `json:"id"`
	Name       string        `json:"name"`
	Category   string        `json:"category"`
	Status     string        `json:"status"` // PASS, FAIL, SKIP
	DurationMs int64         `json:"duration_ms"`
	Detail     string        `json:"detail,omitempty"`
}

// Summary holds the overall smoke run result.
type Summary struct {
	Version string        `json:"version"`
	Result  string        `json:"result"` // PASS or FAIL
	Counts  SummaryCounts `json:"summary"`
	Tests   []TestResult  `json:"tests"`
}

// SummaryCounts holds pass/fail/skip counts.
type SummaryCounts struct {
	Pass int `json:"pass"`
	Fail int `json:"fail"`
	Skip int `json:"skip"`
}

// RunOptions controls smoke execution filtering.
type RunOptions struct {
	Group  string // truth, daemon, config, metrics, modules, deep, all
	Module string // filter by specific module (ddos, portscan, etc.)
	Deep   bool   // include DeepOnly tests
}

// RunSmoke executes all registered tests, filtered by options.
// Returns a Summary with PASS/FAIL/SKIP per test.
func RunSmoke(version string, opts RunOptions) Summary {
	registry := DefaultRegistry()

	s := Summary{
		Version: version,
		Result:  StatusPass,
	}

	for _, test := range registry {
		// Filter by group
		if opts.Group != "" && opts.Group != "all" && test.Category != opts.Group {
			continue
		}
		// Filter by module
		if opts.Module != "" && test.Module != opts.Module {
			continue
		}
		// Skip deep-only tests unless --deep
		if test.DeepOnly && !opts.Deep {
			continue
		}

		result := executeTest(test)
		s.Tests = append(s.Tests, result)

		switch result.Status {
		case StatusPass:
			s.Counts.Pass++
		case StatusFail:
			s.Counts.Fail++
			s.Result = StatusFail
		case StatusSkip:
			s.Counts.Skip++
		}
	}

	return s
}

func executeTest(t SmokeTest) TestResult {
	result := TestResult{
		ID:       t.ID,
		Name:     t.Name,
		Category: t.Category,
	}

	// Check prerequisites using Phase 2 evaluators
	met, unmet := CheckAllPrerequisites(t.Prerequisites)
	if !met {
		result.Status = StatusSkip
		result.Detail = "prerequisite not met: " + unmet
		return result
	}

	// Execute command with timeout
	start := time.Now()
	output := runCommand(t.Command, t.Timeout)
	result.DurationMs = time.Since(start).Milliseconds()

	// Check fatal patterns first (always FAIL)
	if pattern := matchFatalPattern(output, t.FatalPatterns); pattern != "" {
		result.Status = StatusFail
		result.Detail = "fatal runtime error: " + pattern
		return result
	}

	// Check exit code
	if !isAllowedExit(output.ExitCode, t.AllowedExit) {
		result.Status = StatusFail
		result.Detail = "exit code " + itoa(output.ExitCode) + " not in allowed set"
		return result
	}

	// Run v1.94 simple assertion (backward compat)
	if t.Assert != nil && !t.Assert(output) {
		result.Status = StatusFail
		result.Detail = "assertion failed"
		return result
	}

	// Run v1.95 structured assertions
	if len(t.Assertions) > 0 {
		_, failed, firstFail := RunAssertions(t.Assertions, output)
		if failed > 0 {
			result.Status = StatusFail
			result.Detail = "assertion failed: " + firstFail
			return result
		}
	}

	result.Status = StatusPass
	return result
}

func runCommand(args []string, timeout time.Duration) TestOutput {
	if len(args) == 0 {
		return TestOutput{ExitCode: -1}
	}

	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	// nosemgrep: go.lang.security.audit.dangerous-exec-command.dangerous-exec-command
	// #nosec G204 -- command path and args come from the trusted internal smoke registry, not user input
	cmd := exec.CommandContext(ctx, args[0], args[1:]...)
	var stdout, stderr strings.Builder
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	start := time.Now()
	err := cmd.Run()
	duration := time.Since(start)

	exitCode := 0
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			exitCode = exitErr.ExitCode()
		} else {
			exitCode = -1
		}
	}

	return TestOutput{
		ExitCode: exitCode,
		Stdout:   stdout.String(),
		Stderr:   stderr.String(),
		Duration: duration,
	}
}

func matchFatalPattern(o TestOutput, patterns []string) string {
	combined := o.Stdout + o.Stderr
	for _, p := range patterns {
		if strings.Contains(combined, p) {
			return p
		}
	}
	return ""
}

func isAllowedExit(code int, allowed []int) bool {
	if len(allowed) == 0 {
		return code == 0 // default: only 0 is success
	}
	for _, a := range allowed {
		if code == a {
			return true
		}
	}
	return false
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	s := ""
	neg := false
	if n < 0 {
		neg = true
		n = -n
	}
	for n > 0 {
		s = string(rune('0'+n%10)) + s
		n /= 10
	}
	if neg {
		s = "-" + s
	}
	return s
}
