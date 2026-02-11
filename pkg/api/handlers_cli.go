// =============================================================================
// NFTBan - CLI Executor Functions
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="handlers_cli"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-30"
// meta:description="CLI command execution utilities for API handlers"
// meta:input="CLI command arguments"
// meta:output="Command output strings"
// meta:depends="os/exec,context"
// meta:inventory.files=""
// meta:inventory.binaries="nftban,nftban-core"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package api

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// execCommand executes a generic command and returns combined output
func execCommand(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("command failed: %v (output: %s)", err, string(output))
	}
	return string(output), nil
}

// execNFTBanCommand executes the nftban CLI command
func execNFTBanCommand(args ...string) (string, error) {
	// Use central config for CLI path - no hardcoding
	cmd := exec.Command(getNFTBanCLI(), args...)
	output, err := cmd.CombinedOutput()

	// Ignore netlink socket warnings - these are harmless warnings not errors
	outputStr := string(output)
	if err != nil {
		// Check if it's just netlink warnings (exit code 3 with netlink message)
		if strings.Contains(outputStr, "Unable to initialize Netlink socket") {
			// Command succeeded despite warnings, ignore the error
			return outputStr, nil
		}
		// Return output even on error so caller can check for success messages
		return outputStr, fmt.Errorf("command failed: %v (output: %s)", err, outputStr)
	}
	return outputStr, nil
}

// execNFTBanCommandWithTimeout executes nftban CLI with a timeout
// Use this for commands that may hang (feeds status, health, etc.)
func execNFTBanCommandWithTimeout(timeout time.Duration, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, getNFTBanCLI(), args...)
	output, err := cmd.CombinedOutput()

	outputStr := string(output)
	if ctx.Err() == context.DeadlineExceeded {
		return outputStr, fmt.Errorf("command timed out after %v", timeout)
	}
	if err != nil {
		// Check if it's just netlink warnings (exit code 3 with netlink message)
		if strings.Contains(outputStr, "Unable to initialize Netlink socket") {
			return outputStr, nil
		}
		return outputStr, fmt.Errorf("command failed: %v (output: %s)", err, outputStr)
	}
	return outputStr, nil
}

// execNFTBanCommandPrivileged executes nftban commands that require root privileges
// The nftban-core binary has CAP_NET_ADMIN capability set, allowing direct nft access
// when run by members of the nftban group (via polkit rules)
func execNFTBanCommandPrivileged(args ...string) (string, error) {
	// nftban-core has CAP_NET_ADMIN set, so it can manipulate nftables directly
	// No sudo/pkexec needed - capabilities handle privilege escalation
	cmd := exec.Command(getCoreBin(), args...)
	output, err := cmd.CombinedOutput()

	outputStr := string(output)
	if err != nil {
		// Check for netlink warnings
		if strings.Contains(outputStr, "Unable to initialize Netlink socket") {
			return outputStr, nil
		}
		return outputStr, fmt.Errorf("privileged command failed: %v (output: %s)", err, outputStr)
	}
	return outputStr, nil
}

// execNFTBanCoreCommand executes nftban-core Go binary (preferred for new features)
func execNFTBanCoreCommand(args ...string) (string, error) {
	// Use central config for core binary path - no hardcoding
	cmd := exec.Command(getCoreBin(), args...)
	output, err := cmd.CombinedOutput()

	outputStr := string(output)
	if err != nil {
		return "", fmt.Errorf("command failed: %v (output: %s)", err, outputStr)
	}
	return outputStr, nil
}
