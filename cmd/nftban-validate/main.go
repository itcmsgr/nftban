// =============================================================================
// NFTBan v1.78 - Kernel Validator Command
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftban-validate"
// meta:type="cmd"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-05"
// meta:description="Production kernel validator binary for CLI integration"
// meta:inventory.files="cmd/nftban-validate/main.go"
// meta:inventory.binaries="nftban-validate"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// Usage:
//   nftban-validate          # Human-readable output
//   nftban-validate --json   # Machine-readable JSON output
//
// Exit Codes:
//   0 = PROTECTED   - All validation checks passed
//   1 = DEGRADED    - Partial protection, some checks failed
//   2 = DOWN        - No viable protection detected
//   3 = ERROR       - Validation failed (nft unavailable, etc.)
//
// This binary is called by `nftban status` for authoritative kernel state.
// CRITICAL: This binary is ZERO-SIDE-EFFECT. Never writes files or modifies nft.
//
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/itcmsgr/nftban/internal/validator"
)

func main() {
	jsonOutput := flag.Bool("json", false, "Output JSON instead of summary")
	flag.Parse()

	// Create context with timeout
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// Run validation
	result, err := validator.ValidateKernel(ctx)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Validation error: %v\n", err)
		os.Exit(3)
	}

	if *jsonOutput {
		data, err := result.ToJSON()
		if err != nil {
			fmt.Fprintf(os.Stderr, "JSON error: %v\n", err)
			os.Exit(3)
		}
		fmt.Println(string(data))
	} else {
		result.PrintSummary()
	}

	os.Exit(result.ExitCode())
}
