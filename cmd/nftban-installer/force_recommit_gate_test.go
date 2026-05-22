// =============================================================================
// NFTBan v1.125 R-4 — --force / --allow-recommit gate regression test
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftban-installer-force-recommit-gate-test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-22"
// meta:description="V125 R-4 regression test: shouldRefuseForceRecommit predicate truth table + parseFlags --allow-recommit registration"
// meta:input="None (predicate is pure; flag test manipulates os.Args + flag.CommandLine in isolation)"
// meta:output="t.Fatal on predicate drift or flag-registration regression"
// meta:depends="testing,flag,os,internal/installer/state"
// meta:inventory.files=""
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
	"os"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/state"
)

// TestShouldRefuseForceRecommit covers the V125 R-4 gate predicate truth
// table. The predicate is a pure function over (currentState, force,
// allowRecommit). Extracted from run() so the gate is testable without
// constructing a full executor + state file + logger.
//
// Refusal MUST fire only when all three conditions hold simultaneously:
//   1. --force was passed
//   2. install_state is COMMITTED
//   3. --allow-recommit was NOT passed
//
// All other combinations MUST allow the run (return false).
func TestShouldRefuseForceRecommit(t *testing.T) {
	cases := []struct {
		name          string
		currentState  state.InstallState
		force         bool
		allowRecommit bool
		wantRefuse    bool
	}{
		{
			name:          "force on COMMITTED without allow-recommit REFUSES",
			currentState:  state.StateCommitted,
			force:         true,
			allowRecommit: false,
			wantRefuse:    true,
		},
		{
			name:          "force on COMMITTED with allow-recommit ALLOWS (explicit operator intent)",
			currentState:  state.StateCommitted,
			force:         true,
			allowRecommit: true,
			wantRefuse:    false,
		},
		{
			name:          "force on StateFailedRebuild without allow-recommit ALLOWS (recovery path)",
			currentState:  state.StateFailedRebuild,
			force:         true,
			allowRecommit: false,
			wantRefuse:    false,
		},
		{
			name:          "force on StateFailedRender without allow-recommit ALLOWS (recovery path)",
			currentState:  state.StateFailedRender,
			force:         true,
			allowRecommit: false,
			wantRefuse:    false,
		},
		{
			name:          "force on StateFailedNoFirewall without allow-recommit ALLOWS (recovery path)",
			currentState:  state.StateFailedNoFirewall,
			force:         true,
			allowRecommit: false,
			wantRefuse:    false,
		},
		{
			name:          "force on StateFailedTakeover without allow-recommit ALLOWS (recovery path)",
			currentState:  state.StateFailedTakeover,
			force:         true,
			allowRecommit: false,
			wantRefuse:    false,
		},
		{
			name:          "force on StateDegraded without allow-recommit ALLOWS (recovery path)",
			currentState:  state.StateDegraded,
			force:         true,
			allowRecommit: false,
			wantRefuse:    false,
		},
		{
			name:          "force on empty state (fresh install) ALLOWS (no install present)",
			currentState:  state.InstallState(""),
			force:         true,
			allowRecommit: false,
			wantRefuse:    false,
		},
		{
			name:          "NO force on COMMITTED ALLOWS (e.g., package-manager postinst with --rpm/--deb)",
			currentState:  state.StateCommitted,
			force:         false,
			allowRecommit: false,
			wantRefuse:    false,
		},
		{
			name:          "NO force with allow-recommit on COMMITTED ALLOWS (allowRecommit alone is harmless)",
			currentState:  state.StateCommitted,
			force:         false,
			allowRecommit: true,
			wantRefuse:    false,
		},
		{
			name:          "NO force on StateFailedRebuild ALLOWS",
			currentState:  state.StateFailedRebuild,
			force:         false,
			allowRecommit: false,
			wantRefuse:    false,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := shouldRefuseForceRecommit(tc.currentState, tc.force, tc.allowRecommit)
			if got != tc.wantRefuse {
				t.Fatalf("shouldRefuseForceRecommit(state=%q, force=%v, allowRecommit=%v) = %v; want %v",
					tc.currentState, tc.force, tc.allowRecommit, got, tc.wantRefuse)
			}
		})
	}
}

// TestParseFlags_AllowRecommitDefault asserts that parseFlags registers
// --allow-recommit and defaults it to false when the operator does not
// pass the flag. Mirrors the V120 TestParseFlags_SessionWhitelistTTLDefault
// pattern (V120_PR_637_ORPHAN_AND_DEAD_CODE_AUDIT B-2 — a flag declared in
// the config struct but never registered via flag.BoolVar silently no-ops
// in production).
//
// Uses --mode=upgrade (the lightest-validation install mode) so that
// parseFlags reaches the return path without hitting any os.Exit branch.
func TestParseFlags_AllowRecommitDefault(t *testing.T) {
	origArgs := os.Args
	origCmdLine := flag.CommandLine
	t.Cleanup(func() {
		os.Args = origArgs
		flag.CommandLine = origCmdLine
	})

	flag.CommandLine = flag.NewFlagSet("nftban-installer-allowrecommittest", flag.ContinueOnError)
	os.Args = []string{"nftban-installer", "--mode=upgrade"}

	cfg := parseFlags()

	if cfg.allowRecommit != false {
		t.Fatalf("parseFlags() with no --allow-recommit returned cfg.allowRecommit=%v; want false (default)", cfg.allowRecommit)
	}
}

// TestParseFlags_AllowRecommitExplicit asserts that --allow-recommit is
// honored when explicitly passed on the command line.
func TestParseFlags_AllowRecommitExplicit(t *testing.T) {
	origArgs := os.Args
	origCmdLine := flag.CommandLine
	t.Cleanup(func() {
		os.Args = origArgs
		flag.CommandLine = origCmdLine
	})

	flag.CommandLine = flag.NewFlagSet("nftban-installer-allowrecommitexplicit", flag.ContinueOnError)
	os.Args = []string{"nftban-installer", "--mode=upgrade", "--force", "--allow-recommit"}

	cfg := parseFlags()

	if !cfg.allowRecommit {
		t.Fatal("parseFlags() with --allow-recommit returned cfg.allowRecommit=false; want true")
	}
	if !cfg.force {
		t.Fatal("parseFlags() with --force returned cfg.force=false; want true (sanity check that --allow-recommit didn't shadow --force)")
	}
}
