// =============================================================================
// NFTBan v1.97 - CLI Lifecycle Command
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="cmd_lifecycle"
// meta:type="command"
// meta:version="1.97.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-17"
// meta:description="Lifecycle planning engine CLI — nftban lifecycle run --mode=X --dry-run"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// Contract: V197_LIFECYCLE_CONTRACT.md §6 PR-05
// INV-LC-001: Engine is side-effect free. DRY-RUN ONLY in v1.97.
// INV-LC-005: Dry-run uses same classification logic as real execution.
// INV-LC-007: No lifecycle command in v1.97 may mutate the system.
// =============================================================================

package main

import (
	"fmt"
	"os"
	"os/exec"

	"github.com/itcmsgr/nftban/internal/lifecycle"
	"github.com/itcmsgr/nftban/internal/rebuild"
)

func cmdLifecycle(args []string) int {
	if len(args) == 0 || args[0] == "--help" || args[0] == "-h" {
		printLifecycleUsage()
		return 0
	}

	subcmd := args[0]
	subargs := args[1:]

	switch subcmd {
	case "run":
		return cmdLifecycleRun(subargs)
	default:
		fmt.Fprintf(os.Stderr, "Unknown lifecycle subcommand: %s\n", subcmd)
		printLifecycleUsage()
		return 1
	}
}

func cmdLifecycleRun(args []string) int {
	var mode string
	var jsonOutput bool
	dryRun := true // v1.97: ALWAYS dry-run (INV-LC-001)

	for _, arg := range args {
		switch {
		case arg == "--json":
			jsonOutput = true
		case len(arg) > 7 && arg[:7] == "--mode=":
			mode = arg[7:]
		case arg == "--no-dry-run":
			// v1.97: refuse real execution (INV-LC-007)
			fmt.Fprintf(os.Stderr, "Error: real execution is not available in v1.97\n")
			fmt.Fprintf(os.Stderr, "  Lifecycle execution will be enabled in v1.98+\n")
			fmt.Fprintf(os.Stderr, "  Use --dry-run (default) for planning\n")
			return 1
		case arg == "--dry-run":
			dryRun = true // explicit, same as default
		case arg == "--help" || arg == "-h":
			printLifecycleRunUsage()
			return 0
		default:
			fmt.Fprintf(os.Stderr, "Unknown option: %s\n", arg)
			return 1
		}
	}

	if mode == "" {
		fmt.Fprintf(os.Stderr, "Error: --mode is required\n")
		fmt.Fprintf(os.Stderr, "  Valid modes: install, update, uninstall, maintenance\n")
		return 1
	}

	lcMode := lifecycle.Mode(mode)
	if !lifecycle.ValidMode(lcMode) {
		fmt.Fprintf(os.Stderr, "Error: invalid mode: %s\n", mode)
		fmt.Fprintf(os.Stderr, "  Valid modes: install, update, uninstall, maintenance\n")
		return 1
	}

	// Build snapshot from real system state
	snap := buildSnapshot(lcMode, dryRun)

	// Run lifecycle engine (pure, no side effects)
	result := lifecycle.Run(snap)

	// Log evidence
	logger := lifecycle.NewLogger(os.Stderr, lcMode, dryRun)
	logger.LogDetect(snap.CurrentAuthority, snap.Detection)
	logger.LogPlan(result.Plan, result.LastOperation)
	logger.LogResult(result)

	// Render output
	if jsonOutput {
		if err := lifecycle.RenderJSON(os.Stdout, result); err != nil {
			fmt.Fprintf(os.Stderr, "Error rendering JSON: %v\n", err)
			return 1
		}
	} else {
		if err := lifecycle.RenderText(os.Stdout, result); err != nil {
			fmt.Fprintf(os.Stderr, "Error rendering output: %v\n", err)
			return 1
		}
	}

	// Exit code: 0 for success/plan-valid, non-zero for failures
	if result.Outcome == lifecycle.OutcomeSuccess {
		return 0
	}
	return 1
}

// buildSnapshot creates a lifecycle Snapshot from real system state.
// This reads actual system observations — it does NOT guess or assume.
func buildSnapshot(mode lifecycle.Mode, dryRun bool) lifecycle.Snapshot {
	snap := lifecycle.Snapshot{
		Mode:   mode,
		DryRun: dryRun,
	}

	// Detect current authority from validator
	snap.CurrentAuthority = detectAuthority()

	// Read v1.96 recovery marker
	snap.LastOperation = readLastOperation()

	// Detect system state
	snap.Detection = detectSystem()

	return snap
}

// detectAuthority reads current firewall authority from validator/nft state.
func detectAuthority() lifecycle.AuthorityState {
	auth := lifecycle.AuthorityState{
		Owner:  lifecycle.AuthorityNone,
		Health: lifecycle.HealthDown,
	}

	// Check if nftban tables exist in kernel
	// Use nft list tables to detect presence (read-only, no mutation)
	if fileExists("/usr/lib/nftban/bin/nftban-validate") || fileExists("/usr/sbin/nftban") {
		// NFTBan is installed — check if it owns the firewall
		auth.Owner = lifecycle.AuthorityNFTBan

		// Try to get health from validator
		health := getValidatorHealth()
		switch health {
		case "protected":
			auth.Health = lifecycle.HealthProtected
		case "idle":
			auth.Health = lifecycle.HealthIdle
		case "degraded":
			auth.Health = lifecycle.HealthDegraded
		case "down":
			auth.Health = lifecycle.HealthDown
		default:
			auth.Health = lifecycle.HealthDown
		}
	}

	return auth
}

// readLastOperation reads v1.96 recovery marker for last operation truth.
func readLastOperation() lifecycle.LastOperation {
	lo := lifecycle.LastOperation{}

	marker, err := rebuild.ReadMarker()
	if err != nil || marker == nil {
		lo.Result = "SUCCESS"
		return lo
	}

	lo.Result = string(marker.OperationResult)
	lo.FailureClass = string(marker.FailureClass)
	lo.RecoveryPending = marker.ShouldDeferRetry()
	lo.LastRebuildFailed = marker.OperationResult != rebuild.ResultSuccess

	return lo
}

// detectSystem checks for conflicting firewalls, kernel validity, etc.
func detectSystem() lifecycle.Detection {
	det := lifecycle.Detection{
		SSHSafe: true, // default safe unless proven otherwise
	}

	// Check for conflicting firewalls
	det.ConflictingFirewall = isServiceActive("firewalld") ||
		isServiceActive("ufw")

	// Check kernel validity (nftban tables exist and are parseable)
	det.KernelValid = nftTablesExist()

	// Validator consistency (tables match expected schema)
	det.ValidatorConsistent = det.KernelValid // simplified for v1.97

	return det
}

// Helper functions for system detection

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func isServiceActive(service string) bool {
	// Read-only check via systemctl (no mutation)
	cmd := fmt.Sprintf("systemctl is-active --quiet %s 2>/dev/null", service)
	return runQuietCmd(cmd) == nil
}

func nftTablesExist() bool {
	return runQuietCmd("nft list table ip nftban 2>/dev/null") == nil
}

func getValidatorHealth() string {
	// Try nftban-validate if available
	out, err := runCmdOutput("nftban-validate", "status", "--quiet")
	if err != nil {
		return "down"
	}
	// Output is the status string
	for _, status := range []string{"protected", "idle", "degraded", "down"} {
		if len(out) >= len(status) && out[:len(status)] == status {
			return status
		}
	}
	return "down"
}

func runQuietCmd(cmdStr string) error {
	c := exec.Command("bash", "-c", cmdStr) // #nosec G204 — controlled input
	return c.Run()
}

func runCmdOutput(name string, args ...string) (string, error) {
	c := exec.Command(name, args...) // #nosec G204 — controlled input
	out, err := c.Output()
	if err != nil {
		return "", err
	}
	return string(out), nil
}

func printLifecycleUsage() {
	fmt.Println("Usage: nftban lifecycle <subcommand> [options]")
	fmt.Println("")
	fmt.Println("Subcommands:")
	fmt.Println("  run    Plan a lifecycle operation (dry-run by default)")
	fmt.Println("")
	fmt.Println("Examples:")
	fmt.Println("  nftban lifecycle run --mode=install --dry-run")
	fmt.Println("  nftban lifecycle run --mode=update --json")
}

func printLifecycleRunUsage() {
	fmt.Println("Usage: nftban lifecycle run --mode=MODE [options]")
	fmt.Println("")
	fmt.Println("Plan a lifecycle operation without executing it.")
	fmt.Println("")
	fmt.Println("Modes:")
	fmt.Println("  install       Plan fresh installation")
	fmt.Println("  update        Plan upgrade of existing installation")
	fmt.Println("  uninstall     Plan removal")
	fmt.Println("  maintenance   Plan maintenance operations")
	fmt.Println("")
	fmt.Println("Options:")
	fmt.Println("  --dry-run     Plan only, no changes (default)")
	fmt.Println("  --json        Output as JSON")
	fmt.Println("  --help        Show this help")
	fmt.Println("")
	fmt.Println("Note: Real execution is not available in v1.97.")
	fmt.Println("      Lifecycle execution will be enabled in v1.98+.")
}
