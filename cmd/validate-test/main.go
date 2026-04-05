// =============================================================================
// NFTBan v1.78 - Validator Test Command
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="validate-test"
// meta:type="cmd"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-05"
// meta:description="Test command for kernel validator"
// meta:inventory.files="cmd/validate-test/main.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// Usage:
//   go build -o validate-test ./cmd/validate-test
//   sudo ./validate-test
//   sudo ./validate-test --json
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
