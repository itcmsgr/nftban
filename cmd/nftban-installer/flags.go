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
// meta:inventory.env_vars="NFTBAN_TAKEOVER, NFTBAN_INSTALLER_LOG, NFTBAN_LIFECYCLE, NFTBAN_SOURCE_DIR"
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
	"path/filepath"

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
	lifecycle   bool   // v1.98: use canonized lifecycle flow (feature flag)
	source      bool   // v1.98.x PR-14-pre: source install (stage payload + users from repo tree)
	sourceDir   string // v1.98.x PR-14-pre: source tree root for --source (resolved in parseFlags)
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
	// v1.98.x PR-14-pre: source-install support (gated behind --source; mutually
	// exclusive with --rpm / --deb). Enables user/group creation, payload staging
	// from a repo/tarball tree, and safety-whitelist seeding during Prepare/Configure.
	flag.BoolVar(&cfg.source, "source", false, "Source install from repo/tarball (stages payload from --source-dir). Mutually exclusive with --rpm and --deb.")
	flag.StringVar(&cfg.sourceDir, "source-dir", "", "Source tree root (repo clone or extracted tarball). Falls back to $NFTBAN_SOURCE_DIR then binary-relative discovery.")

	flag.Parse()

	// Environment variable overrides
	if os.Getenv("NFTBAN_TAKEOVER") == "1" {
		cfg.takeover = true
	}
	if envLog := os.Getenv("NFTBAN_INSTALLER_LOG"); envLog != "" {
		cfg.logPath = envLog
	}
	// v1.98 Phase 2: Canonized lifecycle feature flag
	// Default: ON. Set NFTBAN_LIFECYCLE=0 to use legacy path.
	cfg.lifecycle = os.Getenv("NFTBAN_LIFECYCLE") != "0"

	// v1.98.x PR-14-pre: Source-tree root resolution.
	// Priority: --source-dir > NFTBAN_SOURCE_DIR > binary-relative fallback.
	if cfg.source && cfg.sourceDir == "" {
		cfg.sourceDir = os.Getenv("NFTBAN_SOURCE_DIR")
	}
	if cfg.source && cfg.sourceDir == "" {
		// Derive from binary location: .../<srcdir>/bin/nftban-installer => sourceDir = <srcdir>
		if exe, err := os.Executable(); err == nil {
			cfg.sourceDir = filepath.Dir(filepath.Dir(exe))
		}
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

	// --source is mutually exclusive with packaging-origin flags.
	if cfg.source && (cfg.rpm || cfg.deb) {
		fmt.Fprintln(os.Stderr, "error: --source cannot be combined with --rpm or --deb")
		os.Exit(state.ExitFatal)
	}

	// --source requires a resolvable source directory.
	if cfg.source && cfg.sourceDir == "" {
		fmt.Fprintln(os.Stderr, "error: --source requires --source-dir, $NFTBAN_SOURCE_DIR, or a discoverable binary location")
		os.Exit(state.ExitFatal)
	}

	return cfg
}
