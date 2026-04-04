// =============================================================================
// NFTBan v1.75 - nftban-installer - CLI flag parsing
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftban-installer-flags"
// meta:type="cmd"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="CLI flag definitions and environment variable overrides"
// meta:inventory.files="cmd/nftban-installer/flags.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars="NFTBAN_TAKEOVER, NFTBAN_INSTALLER_LOG"
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/state"
)

// config holds parsed CLI flags and environment variable overrides.
type config struct {
	mode        string // "install" or "upgrade"
	rpm         bool   // called from RPM %post
	deb         bool   // called from DEB postinst
	repair      bool   // resume from last failed phase
	force       bool   // re-run all phases ignoring state
	takeover    bool   // approve takeover of conflicting firewalls
	dryRun      bool   // show what would happen without changes
	verbose     bool   // full diagnostic logging
	quiet       bool   // minimal output
	jsonOutput  bool   // machine-readable JSON output
	stateDir    string // override state directory
	logPath     string // override log file path
	showVersion bool   // print version and exit
}

func parseFlags() *config {
	cfg := &config{}

	flag.StringVar(&cfg.mode, "mode", "", "Install mode: install or upgrade (required unless --repair)")
	flag.BoolVar(&cfg.rpm, "rpm", false, "Called from RPM %post")
	flag.BoolVar(&cfg.deb, "deb", false, "Called from DEB postinst")
	flag.BoolVar(&cfg.repair, "repair", false, "Resume from last failed phase")
	flag.BoolVar(&cfg.force, "force", false, "Re-run all phases ignoring state")
	flag.BoolVar(&cfg.takeover, "takeover", false, "Approve takeover of conflicting firewalls")
	flag.BoolVar(&cfg.dryRun, "dry-run", false, "Show what would happen without changes")
	flag.BoolVar(&cfg.verbose, "verbose", false, "Full diagnostic logging")
	flag.BoolVar(&cfg.quiet, "quiet", false, "Minimal output")
	flag.BoolVar(&cfg.jsonOutput, "json", false, "Machine-readable JSON output")
	flag.StringVar(&cfg.stateDir, "state-dir", state.DefaultStateDir, "State directory path")
	flag.StringVar(&cfg.logPath, "log", logging.DefaultLogPath, "Log file path")
	flag.BoolVar(&cfg.showVersion, "version", false, "Print version and exit")

	flag.Parse()

	// Environment variable overrides
	if os.Getenv("NFTBAN_TAKEOVER") == "1" {
		cfg.takeover = true
	}
	if envLog := os.Getenv("NFTBAN_INSTALLER_LOG"); envLog != "" {
		cfg.logPath = envLog
	}

	// Validate
	if !cfg.showVersion && !cfg.repair {
		if cfg.mode != "install" && cfg.mode != "upgrade" {
			fmt.Fprintf(os.Stderr, "error: --mode must be 'install' or 'upgrade' (got %q)\n", cfg.mode)
			fmt.Fprintf(os.Stderr, "usage: nftban-installer --mode=install|upgrade [flags]\n")
			fmt.Fprintf(os.Stderr, "       nftban-installer --repair [flags]\n")
			os.Exit(state.ExitFatal)
		}
	}

	return cfg
}
