// =============================================================================
// NFTBan - CLI Smoke Command
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="cmd_smoke"
// meta:type="command"
// meta:version="1.94.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-16"
// meta:description="Registry-driven smoke test runner — nftban smoke [--json] [--group GROUP]"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================

package main

import (
	"fmt"
	"os"

	"github.com/itcmsgr/nftban/internal/smoke"
	"github.com/itcmsgr/nftban/pkg/version"
)

func cmdSmoke(args []string) int {
	opts := smoke.RunOptions{Group: "all"}
	jsonOutput := false

	// Parse flags
	for _, arg := range args {
		switch {
		case arg == "--json":
			jsonOutput = true
		case arg == "--deep":
			opts.Deep = true
		case len(arg) > 8 && arg[:8] == "--group=":
			opts.Group = arg[8:]
		case len(arg) > 9 && arg[:9] == "--module=":
			opts.Module = arg[9:]
			opts.Group = "modules"
		case arg == "--help" || arg == "-h":
			fmt.Println("Usage: nftban smoke [--json] [--group=GROUP] [--module=MODULE] [--deep]")
			fmt.Println("")
			fmt.Println("Run registry-driven smoke tests to verify system integrity.")
			fmt.Println("")
			fmt.Println("Options:")
			fmt.Println("  --json            Output results as JSON")
			fmt.Println("  --group=GROUP     Run only tests in GROUP (default: all)")
			fmt.Println("                    Groups: truth, daemon, config, metrics, modules, deep")
			fmt.Println("  --module=MODULE   Run only tests for MODULE (ddos, portscan, botguard, loginmon)")
			fmt.Println("  --deep            Include deep checks (heavier assertions)")
			return 0
		}
	}

	// Run smoke tests
	summary := smoke.RunSmoke(version.Version, opts)

	// Output
	if jsonOutput {
		out, err := smoke.FormatJSON(summary)
		if err != nil {
			fmt.Fprintf(os.Stderr, "JSON format error: %v\n", err)
			return 2
		}
		fmt.Println(out)
	} else {
		fmt.Print(smoke.FormatHuman(summary))
	}

	return smoke.ExitCode(summary)
}
