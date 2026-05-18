// =============================================================================
// NFTBan v1.120 - flags.go regression test for --session-whitelist-ttl default
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftban-installer-flags-test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-18"
// meta:description="V120 regression test for V120_PR_637_ORPHAN_AND_DEAD_CODE_AUDIT B-2: asserts parseFlags() registers --session-whitelist-ttl and defaults it to safety.DefaultSessionWhitelistTTL when the operator does not pass the flag. If this test fails, the auto-seed feature silently no-ops on every host (TTL=0 → ExpiresAt=now → loader skips on first reload → D-UPDATE-OPERATOR-SELF-BAN-GAP-001 fix defeated)."
// meta:input="None (manipulates os.Args and flag.CommandLine in isolation; restored via t.Cleanup)"
// meta:output="t.Fatal on TTL drift"
// meta:depends="testing,flag,os,internal/installer/safety"
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

	"github.com/itcmsgr/nftban/internal/installer/safety"
)

// TestParseFlags_SessionWhitelistTTLDefault is the v1.120 regression guard
// for V120_PR_637_ORPHAN_AND_DEAD_CODE_AUDIT B-2. The audit caught that
// `--session-whitelist-ttl` was declared in the config struct and consumed
// in main.go + phases.go, but was never registered via flag.DurationVar
// in parseFlags(). The silent net effect was: every auto-seeded session
// whitelist entry got ExpiresAt = time.Now() + 0 (the zero-value default
// of time.Duration), which the v1.120 loader skips on the first reload,
// silently defeating the D-UPDATE-OPERATOR-SELF-BAN-GAP-001 P1 safety fix.
//
// This test asserts that absent the flag on the command line, parseFlags
// returns cfg.sessionWhitelistTTL == safety.DefaultSessionWhitelistTTL.
// If a future change removes the flag.DurationVar registration again,
// this test must catch it BEFORE the silent no-op reaches production.
//
// Uses --mode=upgrade (the lightest-validation install mode) so that
// parseFlags reaches the return path without hitting any os.Exit branch.
func TestParseFlags_SessionWhitelistTTLDefault(t *testing.T) {
	origArgs := os.Args
	origCmdLine := flag.CommandLine
	t.Cleanup(func() {
		os.Args = origArgs
		flag.CommandLine = origCmdLine
	})

	flag.CommandLine = flag.NewFlagSet("nftban-installer-flagstest", flag.ContinueOnError)
	os.Args = []string{"nftban-installer", "--mode=upgrade"}

	cfg := parseFlags()
	if cfg == nil {
		t.Fatal("parseFlags() returned nil cfg for --mode=upgrade")
	}
	if cfg.sessionWhitelistTTL != safety.DefaultSessionWhitelistTTL {
		t.Fatalf("cfg.sessionWhitelistTTL = %v, want %v (safety.DefaultSessionWhitelistTTL); "+
			"--session-whitelist-ttl flag.DurationVar registration is missing from parseFlags(); "+
			"silently defeats D-UPDATE-OPERATOR-SELF-BAN-GAP-001 by giving every auto-seeded "+
			"entry a zero TTL (born expired).",
			cfg.sessionWhitelistTTL, safety.DefaultSessionWhitelistTTL)
	}
}

// TestParseFlags_SessionWhitelistTTLExplicit asserts that an explicit
// --session-whitelist-ttl=<value> CLI override is honoured. This protects
// against a future regression where the registration is present but
// bound to the wrong variable.
func TestParseFlags_SessionWhitelistTTLExplicit(t *testing.T) {
	origArgs := os.Args
	origCmdLine := flag.CommandLine
	t.Cleanup(func() {
		os.Args = origArgs
		flag.CommandLine = origCmdLine
	})

	flag.CommandLine = flag.NewFlagSet("nftban-installer-flagstest", flag.ContinueOnError)
	os.Args = []string{"nftban-installer", "--mode=upgrade", "--session-whitelist-ttl=1h30m"}

	cfg := parseFlags()
	if cfg == nil {
		t.Fatal("parseFlags() returned nil cfg")
	}
	const want = 90 * 60 * 1_000_000_000 // 1h30m in nanoseconds (time.Duration)
	if int64(cfg.sessionWhitelistTTL) != int64(want) {
		t.Fatalf("cfg.sessionWhitelistTTL = %v, want 1h30m", cfg.sessionWhitelistTTL)
	}
}
