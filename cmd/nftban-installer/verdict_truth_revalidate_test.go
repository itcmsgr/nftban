// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="verdict_truth_revalidate_test.go"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.223.0 verdict-truth: runRevalidate health-verdict truth. medium ACTIVE_MATCH→COMMITTED; medium FALLBACK_UNDERSIZED→DEGRADED; persisted ACTIVE_MATCH + live mismatch→DEGRADED (live wins); persisted failure + live ACTIVE_MATCH→COMMITTED (live wins). Proves the health_resource_policy_active assertion is PRESENT and did NOT skip (the resolver performed a live systemd verify). Deterministic via the injected medium fixture profile + fixture mock."
// meta:inventory.files="cmd/nftban-installer/verdict_truth_revalidate_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
package main

import (
	"context"
	"testing"

	"github.com/itcmsgr/nftban/internal/healthresource"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/state"
	coresafety "github.com/itcmsgr/nftban/internal/safety"
	"github.com/itcmsgr/nftban/pkg/version"
)

// writeRevalStateHealth writes a DEGRADED install_state (version-matched, ssh 22)
// carrying a persisted HEALTH_RESOURCE_* record so the "live wins over persisted"
// cases can demonstrate that stale persisted evidence never masks live truth.
func writeRevalStateHealth(t *testing.T, dir, persistedHealth string, protection bool) {
	t.Helper()
	sf := state.NewStateFile(dir)
	sf.State = state.StateDegraded
	sf.Version = version.Version
	sf.Mode = "upgrade"
	sf.SSHPort = 22
	sf.HealthResourceState = persistedHealth
	sf.HealthResourceProfile = string(coresafety.ResourceTierMedium)
	sf.HealthResourceProtection = protection
	sf.HealthMemMaxEffective = mediumProfile().MemoryMax
	// v1.232.2: a DEGRADED record produced by a real post-v1.230.0 install CARRIES
	// the convergence verdict its install recorded. revalidate can only ever carry
	// that verdict forward — it renders nothing — so a fixture that omits it is not
	// modelling "a degraded install", it is modelling "a record with no proof",
	// which is a different case and has its own test below.
	sf.ConvergenceVerified = state.ConvergenceVerifiedValue
	if err := sf.WriteAtomic(); err != nil {
		t.Fatalf("write state: %v", err)
	}
}

// ⛔ THE CASE THE INVARIANT EXPOSED. revalidate reached COMMITTED from LIVE
// ASSERTIONS ALONE on a record carrying no convergence verdict — a second path to
// the srv3 shape, found by the v1.232.2 Transition invariant rather than by review.
// All assertions pass here; the run must still refuse to certify what it did not
// observe.
func TestRevalidate_AllAssertionsPass_NoCarryableVerdict_DoesNotCommit(t *testing.T) {
	inj, m, cleanup := newAllAssertionsPassFixture(t)
	defer cleanup()
	inj.healthProfile = mediumProfilePtr()
	setHealthActiveMatch(m, mediumProfile())

	dir := t.TempDir()
	writeRevalStateHealth(t, dir, string(healthresource.StateActiveMatch), true)

	// Strip the verdict: this is the pre-v1.230.0 / never-evaluated record shape.
	stripped := state.NewStateFile(dir)
	if err := stripped.Read(); err != nil {
		t.Fatalf("read state: %v", err)
	}
	stripped.ConvergenceVerified = ""
	if err := stripped.WriteAtomic(); err != nil {
		t.Fatalf("rewrite state: %v", err)
	}

	got, rc := driveRevalidateDir(t, dir, inj, m)

	if got.State == state.StateCommitted {
		t.Fatalf("revalidate recommitted COMMITTED with CONVERGENCE_VERIFIED=%q — passing live "+
			"assertions are not a convergence proof", got.ConvergenceVerified)
	}
	if rc == state.ExitCommitted {
		t.Fatalf("revalidate returned ExitCommitted (0) on a record with no convergence verdict")
	}
	if got.State != state.StateAppliedUnverified || rc != state.ExitAppliedUnverified {
		t.Errorf("state=%s rc=%d; want %s / %d — the assertions DID all pass, so DEGRADED would "+
			"be false too", got.State, rc, state.StateAppliedUnverified, state.ExitAppliedUnverified)
	}
}

// driveRevalidate runs the REAL runRevalidate entry point against the fixture mock +
// injected medium profile, after the given persisted state is on disk.
func driveRevalidate(t *testing.T, inj *assertionTestInjection, m *executor.MockExecutor) (*state.StateFile, int) {
	t.Helper()
	dir := t.TempDir()
	// on-disk persisted record (default: DEGRADED, no persisted health).
	writeRevalState(t, dir, state.StateDegraded, version.Version)
	return driveRevalidateDir(t, dir, inj, m)
}

func driveRevalidateDir(t *testing.T, dir string, inj *assertionTestInjection, m *executor.MockExecutor) (*state.StateFile, int) {
	t.Helper()
	cfg := &config{stateDir: dir, revalidate: true, inject: inj}
	sf := newRevalSF(dir) // mimics main(): read on-disk, overwrite Version, blank Mode
	log := logging.New(dir+"/installer.log", false)
	rc := runRevalidate(context.Background(), m, sf, cfg, log)
	// re-read the persisted terminal state for assertion.
	got := state.NewStateFile(dir)
	_ = got.Read()
	return got, rc
}

// medium + live ACTIVE_MATCH → COMMITTED.
func TestRevalidate_MediumActiveMatch_Commits(t *testing.T) {
	inj, m, cleanup := newAllAssertionsPassFixture(t)
	defer cleanup()
	inj.healthProfile = mediumProfilePtr()
	setHealthActiveMatch(m, mediumProfile())

	got, rc := driveRevalidate(t, inj, m)
	if got.State != state.StateCommitted || rc != state.ExitCommitted {
		t.Fatalf("medium ACTIVE_MATCH: state=%s rc=%d want COMMITTED", got.State, rc)
	}
	if countHealthShow(m) < 1 {
		t.Error("health assertion must NOT skip — the resolver must perform a live systemd verify")
	}
}

// medium + live FALLBACK_UNDERSIZED → DEGRADED (no false COMMIT).
func TestRevalidate_MediumUndersized_StaysDegraded(t *testing.T) {
	inj, m, cleanup := newAllAssertionsPassFixture(t)
	defer cleanup()
	inj.healthProfile = mediumProfilePtr()
	setHealthFallbackUndersized(m)

	got, rc := driveRevalidate(t, inj, m)
	if got.State != state.StateDegraded || rc != state.ExitDegraded {
		t.Fatalf("medium FALLBACK_UNDERSIZED: state=%s rc=%d want DEGRADED", got.State, rc)
	}
}

// persisted ACTIVE_MATCH + live mismatch → DEGRADED (LIVE wins; persisted never masks).
func TestRevalidate_PersistedActiveMatch_LiveMismatch_Degrades(t *testing.T) {
	inj, m, cleanup := newAllAssertionsPassFixture(t)
	defer cleanup()
	inj.healthProfile = mediumProfilePtr()
	setHealthFallbackUndersized(m) // live mismatch

	dir := t.TempDir()
	writeRevalStateHealth(t, dir, string(healthresource.StateActiveMatch), true) // stale persisted ACTIVE_MATCH
	got, rc := driveRevalidateDir(t, dir, inj, m)

	if got.State != state.StateDegraded || rc != state.ExitDegraded {
		t.Fatalf("persisted ACTIVE_MATCH + live mismatch: state=%s rc=%d want DEGRADED (live must win)", got.State, rc)
	}
}

// persisted failure + live ACTIVE_MATCH → COMMITTED (LIVE wins; stale failure cleared).
func TestRevalidate_PersistedFailure_LiveActiveMatch_Commits(t *testing.T) {
	inj, m, cleanup := newAllAssertionsPassFixture(t)
	defer cleanup()
	inj.healthProfile = mediumProfilePtr()
	setHealthActiveMatch(m, mediumProfile()) // live ACTIVE_MATCH

	dir := t.TempDir()
	writeRevalStateHealth(t, dir, string(healthresource.StateFallbackUnder), false) // stale persisted failure
	got, rc := driveRevalidateDir(t, dir, inj, m)

	if got.State != state.StateCommitted || rc != state.ExitCommitted {
		t.Fatalf("persisted failure + live ACTIVE_MATCH: state=%s rc=%d want COMMITTED (live must win)", got.State, rc)
	}
}
