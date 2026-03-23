// =============================================================================
// NFTBan - NFT CLI Execution Layer
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nft_cli"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Centralized nft CLI command execution with timeout and error handling"
// meta:input="NFT commands"
// meta:output="Command results"
// meta:depends="os/exec"
// meta:inventory.files=""
// meta:inventory.binaries="nft"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================

// Package sync provides nftables synchronization utilities
package setsync

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// =============================================================================
// Centralized NFT CLI Execution Layer
// =============================================================================
// Purpose: All nft CLI calls go through these helpers for:
// - Consistent timeout handling
// - Unified error handling with ignorable patterns
// - Logging and debugging
// - Future: metrics collection, rate limiting
// =============================================================================

// Default timeout for nft commands
const (
	nftTimeoutDefault = 30 * time.Second
	nftTimeoutFast    = 5 * time.Second
	nftTimeoutSlow    = 120 * time.Second
)

// Common ignorable error patterns
const (
	ErrFileExists       = "File exists"
	ErrIntervalOverlaps = "interval overlaps"
	ErrElementNotExist  = "element does not exist"
	ErrNoSuchFile       = "No such file or directory"
)

// runNft executes an nft command with default timeout
// Returns combined stdout+stderr output and error
func runNft(args ...string) ([]byte, error) {
	return runNftWithTimeout(nftTimeoutDefault, args...)
}

// runNftFast executes an nft command with fast timeout (5s)
// Use for simple queries like list, status checks
func runNftFast(args ...string) ([]byte, error) {
	return runNftWithTimeout(nftTimeoutFast, args...)
}

//nolint:U1000 // Helper for large batch operations with extended timeout

// runNftWithTimeout executes an nft command with specified timeout
func runNftWithTimeout(timeout time.Duration, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "nft", args...)
	output, err := cmd.CombinedOutput()

	if err != nil {
		if ctx.Err() == context.DeadlineExceeded {
			return output, fmt.Errorf("nft command timed out after %v: %v", timeout, args)
		}
		return output, fmt.Errorf("nft %v failed: %w (output: %s)", args, err, string(output))
	}

	return output, nil
}

// runNftFile executes nft -f <file> with default timeout
func runNftFile(path string) ([]byte, error) {
	return runNft("-f", path)
}

//nolint:U1000 // Helper for large rule files with extended timeout

// isIgnorableNftError checks if an nft error output contains ignorable patterns
// Returns true if the error can be safely ignored
func isIgnorableNftError(output string, patterns ...string) bool {
	for _, pattern := range patterns {
		if strings.Contains(output, pattern) {
			return true
		}
	}
	return false
}

// runNftIgnoring executes nft and ignores specified error patterns
// Returns nil error if command succeeds OR if error matches any ignore pattern
func runNftIgnoring(ignorePatterns []string, args ...string) error {
	output, err := runNft(args...)
	if err != nil {
		if isIgnorableNftError(string(output), ignorePatterns...) {
			return nil
		}
		return err
	}
	return nil
}

// =============================================================================
// Convenience Functions for Common Operations
// =============================================================================

// nftAddSet creates a set with the given definition
// Ignores "File exists" errors (set already exists)
func nftAddSet(family, table, setName, setDef string) error {
	args := []string{"add", "set", family, table, setName, setDef}
	return runNftIgnoring([]string{ErrFileExists}, args...)
}

// nftAddElement adds elements to a set
// Ignores "interval overlaps" errors (element already covered)
func nftAddElement(family, table, setName, elements string) error {
	args := []string{"add", "element", family, table, setName, elements}
	return runNftIgnoring([]string{ErrIntervalOverlaps, ErrFileExists}, args...)
}

// nftDeleteElement deletes elements from a set
// Ignores "element does not exist" and "No such file" errors
func nftDeleteElement(family, table, setName, elements string) error {
	args := []string{"delete", "element", family, table, setName, elements}
	return runNftIgnoring([]string{ErrElementNotExist, ErrNoSuchFile}, args...)
}

// nftFlushSet flushes all elements from a set
func nftFlushSet(family, table, setName string) error {
	_, err := runNft("flush", "set", family, table, setName)
	return err
}

// NftListSet lists elements of a set (exported for emulate command)
func NftListSet(family, table, setName string) (string, error) {
	output, err := runNftFast("list", "set", family, table, setName)
	return string(output), err
}

// nftListSetWithHandles lists elements of a set with handles (-a flag)
func nftListSetWithHandles(family, table, setName string) (string, error) {
	output, err := runNftFast("-a", "list", "set", family, table, setName)
	return string(output), err
}

// =============================================================================
// Batch Operations
// =============================================================================

// nftAddElementsBatch adds elements in batches to avoid argument list limits
// batchSize controls how many elements per nft command
func nftAddElementsBatch(family, table, setName string, elements []string, batchSize int) error {
	if len(elements) == 0 {
		return nil
	}

	if batchSize <= 0 {
		batchSize = 1000 // default
	}

	for i := 0; i < len(elements); i += batchSize {
		end := i + batchSize
		if end > len(elements) {
			end = len(elements)
		}

		batch := elements[i:end]
		elemStr := "{ " + strings.Join(batch, ", ") + " }"

		if err := nftAddElement(family, table, setName, elemStr); err != nil {
			return fmt.Errorf("batch %d-%d failed: %w", i, end, err)
		}
	}

	return nil
}

// nftDeleteElementsBatch deletes elements in batches
func nftDeleteElementsBatch(family, table, setName string, elements []string, batchSize int) error {
	if len(elements) == 0 {
		return nil
	}

	if batchSize <= 0 {
		batchSize = 1000 // default
	}

	for i := 0; i < len(elements); i += batchSize {
		end := i + batchSize
		if end > len(elements) {
			end = len(elements)
		}

		batch := elements[i:end]
		elemStr := "{ " + strings.Join(batch, ", ") + " }"

		if err := nftDeleteElement(family, table, setName, elemStr); err != nil {
			return fmt.Errorf("batch %d-%d failed: %w", i, end, err)
		}
	}

	return nil
}

// =============================================================================
// Family Helper
// =============================================================================

// nftFamily returns "ip" or "ip6" based on IPv4 flag
func nftFamily(ipv4 bool) string {
	if ipv4 {
		return "ip"
	}
	return "ip6"
}

//nolint:U1000 // Helper for nftables type determination
