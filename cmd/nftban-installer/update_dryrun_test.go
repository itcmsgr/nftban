// =============================================================================
// NFTBan v1.100 PR-22B — runUpdateDryRun Purity Test (Lifecycle Truth Repair)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftban-installer-update-dryrun-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-19"
// meta:description="Falsifiable purity test: runUpdateDryRun must not mutate"
// meta:inventory.files="cmd/nftban-installer/update_dryrun_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
//
// Closes audit item I (install/update audit) and audit item N-2
// (post-PR-22B re-audit): before this test, the update dry-run was
// defended only at CI filesystem-snapshot granularity. A future subtle
// write gated on $LANG / hostname / time could pass CI unnoticed. This
// unit test exercises runUpdateDryRun under a MockExecutor and applies
// the shared audit.PurityHarness.
//
// The preflight inside runUpdateDryRun may or may not pass depending on
// mock setup — that is irrelevant to this test. Whatever the preflight
// decision, the observational contract is: zero writes, zero mutation
// commands, zero new files in stateDir.
//
// =============================================================================
package main

import (
	"context"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/audit"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/state"
)

// TestRunUpdateDryRun_Purity_NoMutation invokes runUpdateDryRun with a
// MockExecutor and asserts the observational contract holds regardless
// of preflight outcome.
func TestRunUpdateDryRun_Purity_NoMutation(t *testing.T) {
	tmp := t.TempDir()

	mock := executor.NewMockExecutor()
	// Seed a plausible authoritative host so preflight passes — this
	// exercises the success path. The purity contract must hold whether
	// preflight passes or fails; we use the pass path because it runs
	// more of the orchestrator code before returning.
	mock.NftTables["ip:nftban"] = true
	mock.Services["nftband.service"] = true
	mock.Files["/usr/lib/nftban/VERSION"] = []byte("1.99.0\n")
	mock.RunResults["sh:-c:command -v nft >/dev/null 2>&1"] = executor.Result{ExitCode: 0}
	mock.Files["/var/lib/nftban/state/install_state"] = []byte("COMMITTED\n")

	sf := state.NewStateFile(tmp)
	sf.DryRun = true
	log := logging.New("/dev/null", false)

	cfg := &config{
		mode:     "upgrade",
		dryRun:   true,
		stateDir: tmp,
	}

	// rc is not asserted — preflight result drives it. What matters is
	// the purity contract below, which must hold regardless of the rc.
	_ = runUpdateDryRun(context.Background(), mock, sf, cfg, log)

	audit.NewPurityHarness(mock, tmp).AssertAllPurity(t)
}

// TestRunUpdateDryRun_Purity_PreflightFail covers the branch where
// preflight fails (no authoritative nftban). The run must still be
// observationally pure.
func TestRunUpdateDryRun_Purity_PreflightFail(t *testing.T) {
	tmp := t.TempDir()

	// Intentionally empty mock — nftban is not present, preflight fails.
	mock := executor.NewMockExecutor()

	sf := state.NewStateFile(tmp)
	sf.DryRun = true
	log := logging.New("/dev/null", false)
	cfg := &config{mode: "upgrade", dryRun: true, stateDir: tmp}

	_ = runUpdateDryRun(context.Background(), mock, sf, cfg, log)

	audit.NewPurityHarness(mock, tmp).AssertAllPurity(t)
}
