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
	// v1.100 PR-22: uninstall scaffold flags. All plan-only in PR-22 —
	// no mutation code consumes these; they only influence the rendered
	// release plan.
	purge                     bool // --purge: stronger uninstall mode (preserves .conf.local by default)
	forceDeleteOperatorConfig bool // --force-delete-operator-config: with --purge, also delete .conf.local
	restorePriorAuthority     bool // --restore-prior-authority: opt into restoring pre-install external firewall (requires recorded prior state)
	// v1.100 PR-22B: panel-auto-takeover gate. Previously implicit: any
	// detected control panel (cPanel/Plesk/DA/etc.) silently auto-approved
	// takeover of conflicting firewalls. The audit flagged this as
	// "silent authority takeover" and scope-locked PR-22B to gate it
	// behind an explicit default-off flag. Operators that relied on the
	// prior behaviour must now pass --panel-auto-takeover.
	panelAutoTakeover bool // --panel-auto-takeover: allow panel presence to auto-approve takeover (default OFF)
	// v1.100 PR-23: --confirm-mutation replaces the PR-22 auto-elevate
	// shim. --mode=uninstall now requires exactly one of:
	//   --dry-run          (observational plan)
	//   --confirm-mutation (authority release core)
	// Passing neither is refused; passing both is refused. This
	// eliminates the "safe by default" UX drift that the PR-22 scaffold
	// had to temporarily tolerate. The G3-UN-SHIM-LOCK CI gate catches
	// any regression that reintroduces an auto-elevate path while the
	// mutation code is present.
	confirmMutation bool // --confirm-mutation: authorize uninstall authority release (PR-23)
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
	// v1.100 PR-22 uninstall flags (plan-only; no mutation in PR-22).
	flag.BoolVar(&cfg.purge, "purge", false, "Uninstall in purge mode (stronger deletion; preserves .conf.local unless --force-delete-operator-config is also set). Plan-only in PR-22.")
	flag.BoolVar(&cfg.forceDeleteOperatorConfig, "force-delete-operator-config", false, "With --purge, also delete .conf.local. Explicit destructive-intent flag. Plan-only in PR-22.")
	flag.BoolVar(&cfg.restorePriorAuthority, "restore-prior-authority", false, "Restore pre-install external firewall authority. Requires recorded prior-authority record. Plan-only in PR-22.")
	// v1.100 PR-22B: explicit panel-auto-takeover gate (see config field doc).
	flag.BoolVar(&cfg.panelAutoTakeover, "panel-auto-takeover", false, "Allow control-panel presence to auto-approve takeover of conflicting firewalls. Default OFF. Set explicitly to preserve pre-PR-22B behaviour.")
	// v1.100 PR-23: --confirm-mutation — explicit uninstall mutation entry.
	flag.BoolVar(&cfg.confirmMutation, "confirm-mutation", false, "Authorize uninstall authority release (real kernel + service mutation). Required for --mode=uninstall without --dry-run. Mutually exclusive with --dry-run.")

	flag.Parse()

	// Environment variable overrides
	if os.Getenv("NFTBAN_TAKEOVER") == "1" {
		cfg.takeover = true
	}
	if envLog := os.Getenv("NFTBAN_INSTALLER_LOG"); envLog != "" {
		cfg.logPath = envLog
	}
	// v1.100 PR-22B: env mirror for panel auto-takeover. Same default-off
	// policy — only "1" enables. Any other value (including unset) leaves
	// whatever the CLI flag supplied, which defaults to false.
	if os.Getenv("NFTBAN_PANEL_AUTO_TAKEOVER") == "1" {
		cfg.panelAutoTakeover = true
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
	//
	// PR-22B audit finding N-1: --repair --dry-run must be refused. The
	// previous validation block was skipped entirely for repair mode,
	// so --dry-run was silently accepted even though phaseSwitch's nft
	// and systemctl calls still mutate. sf.DryRun=true suppresses only
	// state-file writes, not kernel/service mutation. Refuse rather
	// than silently proceed.
	if cfg.repair && cfg.dryRun {
		fmt.Fprintln(os.Stderr, "error: --repair --dry-run is not implemented in this release")
		fmt.Fprintln(os.Stderr, "       repair mode runs the full phase pipeline, which mutates kernel and service state.")
		fmt.Fprintln(os.Stderr, "       an honest repair dry-run is out of scope for v1.100 PR-22B.")
		fmt.Fprintln(os.Stderr, "       run --repair without --dry-run, or use --mode=upgrade --dry-run to preview an upgrade.")
		os.Exit(state.ExitFatal)
	}

	if !cfg.showVersion && !cfg.repair {
		// v1.100 PR-24: --mode=restore — authority restoration policy
		// decision engine (pure, no mutation). Validation rules here
		// exist to keep the invocation surface tight per seed §2: the
		// engine consumes --restore-prior-authority / --panel-auto-
		// takeover as decision inputs; other execution-oriented flags
		// are rejected because they are meaningless (and risk misleading
		// the operator).
		if cfg.mode == "restore" {
			if cfg.confirmMutation {
				fmt.Fprintln(os.Stderr, "error: --confirm-mutation is not valid with --mode=restore")
				fmt.Fprintln(os.Stderr, "       --mode=restore invokes the PR-24 decision engine; it performs NO mutation.")
				os.Exit(state.ExitFatal)
			}
			if cfg.dryRun {
				fmt.Fprintln(os.Stderr, "error: --dry-run is not valid with --mode=restore")
				fmt.Fprintln(os.Stderr, "       --mode=restore is ALWAYS pure policy decision — no mutation path exists.")
				os.Exit(state.ExitFatal)
			}
			if cfg.takeover {
				fmt.Fprintln(os.Stderr, "error: --takeover is not valid with --mode=restore")
				os.Exit(state.ExitFatal)
			}
			if cfg.force {
				fmt.Fprintln(os.Stderr, "error: --force is not valid with --mode=restore")
				os.Exit(state.ExitFatal)
			}
			if cfg.rpm || cfg.deb || cfg.source {
				fmt.Fprintln(os.Stderr, "error: package-origin flags (--rpm/--deb/--source) are not valid with --mode=restore")
				os.Exit(state.ExitFatal)
			}
			if cfg.purge || cfg.forceDeleteOperatorConfig {
				fmt.Fprintln(os.Stderr, "error: uninstall mode flags (--purge/--force-delete-operator-config) are not valid with --mode=restore")
				os.Exit(state.ExitFatal)
			}
			return cfg
		}
		if cfg.mode == "uninstall" {
			// PR-22B: flag combos that are only meaningful for uninstall
			// are validated here, because the uninstall block early-returns
			// before the general-validation block below.
			if cfg.forceDeleteOperatorConfig && !cfg.purge {
				fmt.Fprintln(os.Stderr, "error: --force-delete-operator-config requires --purge")
				fmt.Fprintln(os.Stderr, "       this flag is the escape hatch for deleting .conf.local during purge mode.")
				fmt.Fprintln(os.Stderr, "       it has no effect on remove mode and cannot be passed alone.")
				os.Exit(state.ExitFatal)
			}
			// v1.100 PR-23: auto-elevate shim REMOVED. The operator must
			// explicitly choose between:
			//
			//   --dry-run          : observational plan (zero mutation)
			//   --confirm-mutation : authority release core (real kernel
			//                        + service mutation)
			//
			// Passing neither is refused. Passing both is refused. This
			// replaces the PR-22 scaffold-era "safe by default" UX with
			// explicit consent, closing the audit-C regression seam. The
			// G3-UN-SHIM-LOCK CI gate verifies no auto-elevate path
			// coexists with uninstall mutation code.
			if !cfg.dryRun && !cfg.confirmMutation {
				fmt.Fprintln(os.Stderr, "error: --mode=uninstall requires exactly one of --dry-run OR --confirm-mutation")
				fmt.Fprintln(os.Stderr, "       --dry-run          : render the release plan, make no changes")
				fmt.Fprintln(os.Stderr, "       --confirm-mutation : release nftban authority (real kernel + service mutation)")
				fmt.Fprintln(os.Stderr, "       explicit consent is required — silent default behaviour was removed in PR-23.")
				os.Exit(state.ExitFatal)
			}
			if cfg.dryRun && cfg.confirmMutation {
				fmt.Fprintln(os.Stderr, "error: --dry-run and --confirm-mutation are mutually exclusive")
				fmt.Fprintln(os.Stderr, "       one asks for a plan; the other authorises mutation. Pick one.")
				os.Exit(state.ExitFatal)
			}
			return cfg
		}
		if cfg.mode != "install" && cfg.mode != "upgrade" {
			fmt.Fprintf(os.Stderr, "error: --mode must be 'install', 'upgrade', 'uninstall', or 'restore' (got %q)\n", cfg.mode)
			fmt.Fprintf(os.Stderr, "usage: nftban-installer --mode=install|upgrade|uninstall|restore [flags]\n")
			fmt.Fprintf(os.Stderr, "       nftban-installer --repair [flags]\n")
			os.Exit(state.ExitFatal)
		}

		// v1.100 PR-22B: install dry-run is REFUSED, not silently
		// proceeding to real install. Until an honest install dry-run
		// orchestrator lands (deferred — out of PR-22B scope), the flag
		// combination has no truthful meaning and must be rejected. This
		// closes the audit finding that --mode=install --dry-run silently
		// executed all five mutating phases.
		//
		// PR-22B does not add install preview capability; it removes
		// false dry-run semantics by refusing unsupported install dry-run
		// invocations.
		if cfg.mode == "install" && cfg.dryRun {
			fmt.Fprintln(os.Stderr, "error: --mode=install --dry-run is not implemented in this release")
			fmt.Fprintln(os.Stderr, "       an honest install dry-run orchestrator is out of scope for v1.100 PR-22B")
			fmt.Fprintln(os.Stderr, "       run without --dry-run to execute install, or use --mode=upgrade --dry-run to preview an upgrade")
			os.Exit(state.ExitFatal)
		}

		// --takeover --dry-run is incoherent: dry-run is observational,
		// takeover is an explicit mutation consent. Reject rather than
		// silently drop either meaning.
		if cfg.takeover && cfg.dryRun {
			fmt.Fprintln(os.Stderr, "error: --takeover cannot be combined with --dry-run")
			fmt.Fprintln(os.Stderr, "       --takeover authorises mutation; --dry-run refuses it. Pick one.")
			os.Exit(state.ExitFatal)
		}
	}

	// --rpm and --deb are mutually exclusive package-origin flags. The
	// dispatcher in main.go routes differently for each; setting both
	// would silently pick one and ignore the other.
	if cfg.rpm && cfg.deb {
		fmt.Fprintln(os.Stderr, "error: --rpm and --deb cannot both be set")
		os.Exit(state.ExitFatal)
	}

	// PR-23: --confirm-mutation has no meaning outside --mode=uninstall.
	// Reject explicitly so operators don't get a silent no-op or a
	// nonsense interaction with install/upgrade takeover semantics.
	if cfg.confirmMutation && cfg.mode != "uninstall" {
		fmt.Fprintln(os.Stderr, "error: --confirm-mutation is only valid with --mode=uninstall")
		os.Exit(state.ExitFatal)
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

	// v1.100 PR-22B: --force-delete-operator-config only has meaning with
	// --purge (it is the escape hatch that allows the purge mode to also
	// delete .conf.local, the operator-owned override file). Passing it
	// alone previously caused modeFromFlags to silently drop it, which
	// obscured the operator's intent. Reject explicitly.
	if cfg.forceDeleteOperatorConfig && !cfg.purge {
		fmt.Fprintln(os.Stderr, "error: --force-delete-operator-config requires --purge")
		fmt.Fprintln(os.Stderr, "       this flag is the escape hatch for deleting .conf.local during purge mode.")
		fmt.Fprintln(os.Stderr, "       it has no effect on remove mode and cannot be passed alone.")
		os.Exit(state.ExitFatal)
	}

	return cfg
}
