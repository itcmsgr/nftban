// =============================================================================
// NFTBan - verify-rules CLI (SEC-RULEFP, v1.138 PR-A)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="cmd_verify_rules"
// meta:type="go"
// meta:package="main"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-27"
// meta:description="nftban-core verify-rules subcommand: recompute the canonical nftban ruleset fingerprint and compare to the captured baseline. Reports OK/MISMATCH/BASELINE_MISSING/NFT_UNAVAILABLE with exit codes (OK/BASELINE_MISSING=0, MISMATCH=2, NFT_UNAVAILABLE=3). With --capture, (re)captures the baseline from the live ruleset — intended ONLY for the trusted apply/rebuild completion path, never auto-run on a mismatch."
// meta:input="--capture (optional)"
// meta:output="status line + exit code"
// meta:depends="context,fmt,os,time,internal/rulefp"
// meta:inventory.files="/var/lib/nftban/state/ruleset_fingerprint.json"
// meta:inventory.binaries="nft"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="CAP_NET_ADMIN (nft read); write baseline (state dir)"
// =============================================================================

package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/itcmsgr/nftban/internal/rulefp"
)

// Exit codes for verify-rules (OK and BASELINE_MISSING are non-error/advisory).
const (
	verifyExitOK             = 0
	verifyExitMismatch       = 2
	verifyExitNFTUnavailable = 3
)

// cmdVerifyRules implements `nftban-core verify-rules [--capture]`.
func cmdVerifyRules(args []string) int {
	capture := false
	for _, a := range args {
		if a == "--capture" || a == "--refresh-baseline" {
			capture = true
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	if capture {
		// Trusted-path baseline (re)capture from the live ruleset.
		if err := rulefp.CaptureLive(ctx, rulefp.BaselineFile); err != nil {
			fmt.Fprintf(os.Stderr, "verify-rules: baseline capture failed: %v\n", err)
			return verifyExitNFTUnavailable
		}
		fmt.Printf("verify-rules: baseline captured (%s)\n", rulefp.BaselineFile)
		return verifyExitOK
	}

	status, expected, actual, err := rulefp.VerifyLive(ctx, rulefp.BaselineFile)
	switch status {
	case rulefp.StatusOK:
		fmt.Println("verify-rules: OK — live ruleset matches the captured baseline")
		return verifyExitOK
	case rulefp.StatusBaselineMissing:
		// Advisory, not a tamper signal: no baseline captured yet.
		fmt.Println("verify-rules: BASELINE_MISSING — no baseline captured yet (run 'nftban firewall rebuild' to capture)")
		return verifyExitOK
	case rulefp.StatusMismatch:
		fmt.Printf("verify-rules: MISMATCH — live ruleset DIFFERS from the baseline (possible rule injection / chain-policy flip)\n")
		fmt.Printf("  expected (baseline): %s\n  actual   (live):     %s\n", expected, actual)
		return verifyExitMismatch
	case rulefp.StatusNFTUnavailable:
		fmt.Fprintf(os.Stderr, "verify-rules: NFT_UNAVAILABLE — could not read the live ruleset: %v\n", err)
		return verifyExitNFTUnavailable
	default:
		fmt.Fprintf(os.Stderr, "verify-rules: unexpected status %q\n", status)
		return verifyExitNFTUnavailable
	}
}
