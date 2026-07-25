// =============================================================================
// NFTBan - installer verify mode (v1.228.0)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="verify_mode"
// meta:type="package"
// meta:version="1.228.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="--verify-install-state: read-only terminal mode answering whether the persisted install_state belongs to the CURRENT package transaction. Runs before logging, lock acquisition and every mutation path."
// meta:inventory.files="/var/lib/nftban/state/install_state"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
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
	"sort"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/installer/postinstall"
	"github.com/itcmsgr/nftban/internal/installer/state"
)

// verifyAllowedFlags is a STRICT ALLOWLIST, deliberately not a reject list.
//
// A reject list silently accepts every flag added in future — the new flag is
// simply absent from the list, so verify mode inherits it. An allowlist fails
// closed instead: an unrecognised flag is an invalid invocation until someone
// deliberately adds it here. The installer currently declares 25 flags; only
// these four have any meaning for a read-only state verification.
var verifyAllowedFlags = map[string]bool{
	"verify-install-state": true,
	"expected-version":     true,
	"not-before":           true,
	"state-dir":            true,
}

// validateVerifyInvocation enforces the strict allowlist and required
// arguments at PARSE time, so an invalid verification invocation never reaches
// the installer's mutating validation path. Terminal on failure.
func validateVerifyInvocation(cfg *config) {
	// STRICT ALLOWLIST over EXPLICITLY SUPPLIED flags. flag.Visit walks only
	// flags actually set on the command line, so defaults never trip this.
	var offenders []string
	flag.Visit(func(f *flag.Flag) {
		if !verifyAllowedFlags[f.Name] {
			offenders = append(offenders, "--"+f.Name)
		}
	})
	if len(offenders) > 0 {
		sort.Strings(offenders)
		os.Exit(verifyUsageFailure(cfg,
			fmt.Sprintf("--verify-install-state is incompatible with: %s", strings.Join(offenders, " "))))
	}
	if cfg.expectedVersion == "" {
		os.Exit(verifyUsageFailure(cfg, "--expected-version is required with --verify-install-state"))
	}
	if cfg.notBefore == "" {
		os.Exit(verifyUsageFailure(cfg, "--not-before is required with --verify-install-state"))
	}
	// RFC3339Nano requires an explicit zone, so "2026-07-25T14:24:11" or
	// "2026-07-25 14:24:11" is rejected here rather than silently read as
	// host-local time.
	if _, err := time.Parse(time.RFC3339Nano, cfg.notBefore); err != nil {
		os.Exit(verifyUsageFailure(cfg, fmt.Sprintf(
			"--not-before must be RFC3339 with an explicit zone (e.g. 2026-07-25T14:24:11.123456789Z): %v", err)))
	}
}

// runInstallStateVerification is a TERMINAL, READ-ONLY mode.
//
// It must be invoked immediately after parseFlags() and before logging.New():
// logging.New opens the installer log, which would make a nominally read-only
// mode a writer — and `defer log.Close()` does not run on os.Exit anyway.
//
// Guarantees, all verified against the code paths involved:
//   - no logger is constructed
//   - no installer lock is acquired (critical: lock contention must still be
//     able to report STALE_STATE from the unchanged historical state)
//   - no directory is created
//   - no StateFile is initialised or transitioned
//   - no phase runs
//   - output goes directly to stdout in one fixed token format
//
// Exit codes reuse the installer's established taxonomy rather than inventing a
// competing 0/1/2 scheme: ExitDegraded=1 would falsely classify every stale or
// malformed case as DEGRADED, and ExitFailed=2 for a caller error would
// conflate invocation errors with installer-state failures.
//
//	ExitCommitted (0) verified current COMMITTED
//	ExitFailed    (2) any determinate non-verified verdict
//	ExitFatal     (4) invalid invocation — matches every existing usage-error site
func runInstallStateVerification(cfg *config) int {
	// Arguments were validated at parse time; a parse error is terminal there.
	notBefore, err := time.Parse(time.RFC3339Nano, cfg.notBefore)
	if err != nil {
		return verifyUsageFailure(cfg, "internal: --not-before failed to re-parse")
	}

	opt := postinstall.Options{
		StateDir:        cfg.stateDir,
		ExpectedVersion: cfg.expectedVersion,
		NotBefore:       notBefore.UTC(),
	}
	res := postinstall.Verify(opt)
	emitVerifyTokens(res, opt)

	if res.Verdict.Verified() {
		return state.ExitCommitted
	}
	return state.ExitFailed
}

// verifyUsageFailure emits the same token set as any other outcome, so a caller
// parsing tokens never has to special-case invocation errors, then returns the
// installer's established usage-error code.
func verifyUsageFailure(cfg *config, detail string) int {
	fmt.Fprintf(os.Stderr, "ERROR: %s\n", detail)
	nb := time.Time{}
	if t, err := time.Parse(time.RFC3339Nano, cfg.notBefore); err == nil {
		nb = t.UTC()
	}
	emitVerifyTokens(
		postinstall.Result{Verdict: postinstall.InvalidInvocation, Detail: detail},
		postinstall.Options{ExpectedVersion: cfg.expectedVersion, NotBefore: nb},
	)
	return state.ExitFatal
}

// emitVerifyTokens writes the fixed contract to stdout. One format, always the
// same keys, on every path — no banners, no logger, no alternate renderer.
func emitVerifyTokens(res postinstall.Result, opt postinstall.Options) {
	for _, line := range res.Tokens(opt, -1) {
		fmt.Println(line)
	}
	if res.Detail != "" {
		fmt.Fprintf(os.Stderr, "%s\n", res.Detail)
	}
}
