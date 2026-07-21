// SPDX-License-Identifier: MPL-2.0
// meta:name="verdict_truth_matrix_test.go"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.223.0 verdict-truth regression matrix (installer entry points): runRepair resume-at-Validate (medium ACTIVE_MATCH→COMMITTED / ServicesComplete resume / FALLBACK_UNDERSIZED live-wins→DEGRADED), update-force delegation proofs (ACTIVE_MATCH→COMMITTED, medium underprotected→DEGRADED), per-pass Validate-retry (no masking; live-changes-between-passes uses current live truth; active pass-1 resolves once), and the DEGRADED report path (empty ServicesFailed→no false failed-unit claim; real failed unit→structured remediation). Deterministic on any host via the injected medium/small fixture profile."
// meta:inventory.files="cmd/nftban-installer/verdict_truth_matrix_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars="NFTBAN_MIN_DISK_FREE_MB,NFTBAN_LR_MAIN,NFTBAN_LR_STATE,NFTBAN_LR_TEMPLATE,NFTBAN_LR_SURICATA"
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
package main

import (
	"bytes"
	"context"
	"io"
	"os"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/healthresource"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/state"
	coresafety "github.com/itcmsgr/nftban/internal/safety"
	"github.com/itcmsgr/nftban/pkg/version"
)

func mediumProfilePtr() *coresafety.HealthResourceProfile { p := mediumProfile(); return &p }

func seedPersistedActiveMatch(sf *state.StateFile) {
	sf.HealthResourceState = string(healthresource.StateActiveMatch)
	sf.HealthResourceProfile = string(coresafety.ResourceTierMedium)
	sf.HealthResourceProtection = true
	sf.HealthMemMaxEffective = mediumProfile().MemoryMax
}

// countHealthShow returns how many times the health-service `systemctl show` was
// invoked on the mock (the resolver's per-pass live-verify probe).
func countHealthShow(m *executor.MockExecutor) int {
	n := 0
	for _, c := range m.Commands {
		if c.Name == "systemctl" && len(c.Args) >= 2 && c.Args[0] == "show" && c.Args[1] == "nftban-health.service" {
			n++
		}
	}
	return n
}

// driveRepair runs the REAL runRepair entry point with the all-pass fixture + the
// injected medium profile. phaseDetect succeeds (sshd_config seeded, real temp
// stateDir with free space), then resumes into phaseValidate where the health
// verdict is RESOLVED (phaseConfigure skipped → live systemd read).
func driveRepair(t *testing.T, startState state.InstallState, inj *assertionTestInjection, m *executor.MockExecutor, seedPersisted func(*state.StateFile)) (*state.StateFile, int) {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("NFTBAN_MIN_DISK_FREE_MB", "1")
	m.Files["/etc/ssh/sshd_config"] = []byte("Port 22\n") // phaseDetect → sshPort=22
	sf := state.NewStateFile(dir)
	sf.State = startState
	sf.Version = version.Version
	sf.SSHPort = 22
	if seedPersisted != nil {
		seedPersisted(sf)
	}
	cfg := &config{repair: true, stateDir: dir, inject: inj}
	globalPhaseData = phaseData{}
	log := logging.New(dir+"/installer.log", false)
	rc := runRepair(context.Background(), m, sf, cfg, log)
	return sf, rc
}

// ---- runRepair matrix -------------------------------------------------------

// (a) StateDegraded + medium + live ACTIVE_MATCH + persisted ACTIVE_MATCH +
// phaseConfigure skipped → COMMITTED, health PASS (no false DEGRADE on repair).
func TestRunRepair_DegradedMediumActiveMatch_Commits(t *testing.T) {
	inj, m, cleanup := newAllAssertionsPassFixture(t)
	defer cleanup()
	inj.healthProfile = mediumProfilePtr()
	setHealthActiveMatch(m, mediumProfile())

	sf, rc := driveRepair(t, state.StateDegraded, inj, m, seedPersistedActiveMatch)

	if sf.State != state.StateCommitted {
		t.Fatalf("repair medium ACTIVE_MATCH: state=%s want COMMITTED (rc=%d)", sf.State, rc)
	}
	if sf.HealthResourceState != string(healthresource.StateActiveMatch) {
		t.Errorf("resolver must have run and persisted ACTIVE_MATCH; got %q", sf.HealthResourceState)
	}
}

// (b) StateServicesComplete + medium + live ACTIVE_MATCH → resumes at Validate,
// resolver runs, COMMITTED.
func TestRunRepair_ServicesCompleteMediumActiveMatch_Commits(t *testing.T) {
	inj, m, cleanup := newAllAssertionsPassFixture(t)
	defer cleanup()
	inj.healthProfile = mediumProfilePtr()
	setHealthActiveMatch(m, mediumProfile())

	sf, rc := driveRepair(t, state.StateServicesComplete, inj, m, nil)

	if sf.State != state.StateCommitted {
		t.Fatalf("repair-resume ServicesComplete ACTIVE_MATCH: state=%s want COMMITTED (rc=%d)", sf.State, rc)
	}
	if countHealthShow(m) < 1 {
		t.Error("resolver must have performed a live systemd verify (health assertion did NOT skip)")
	}
	if sf.HealthResourceState != string(healthresource.StateActiveMatch) {
		t.Errorf("resolver persisted state=%q want ACTIVE_MATCH", sf.HealthResourceState)
	}
}

// (c) StateDegraded + medium + live FALLBACK_UNDERSIZED + persisted ACTIVE_MATCH →
// live wins → stays DEGRADED (no false COMMIT; persisted ACTIVE_MATCH does NOT mask).
func TestRunRepair_DegradedMediumUndersized_LiveWinsStaysDegraded(t *testing.T) {
	inj, m, cleanup := newAllAssertionsPassFixture(t)
	defer cleanup()
	inj.healthProfile = mediumProfilePtr()
	setHealthFallbackUndersized(m)

	sf, rc := driveRepair(t, state.StateDegraded, inj, m, seedPersistedActiveMatch)

	if sf.State != state.StateDegraded {
		t.Fatalf("repair medium underprotected: state=%s want DEGRADED (rc=%d) — live must win over persisted ACTIVE_MATCH", sf.State, rc)
	}
	if sf.HealthResourceState != string(healthresource.StateFallbackUnder) {
		t.Errorf("live verdict must overwrite persisted; got state=%q want FALLBACK_UNDERSIZED", sf.HealthResourceState)
	}
	if sf.ServicesFailed != "" {
		t.Errorf("a resource-policy DEGRADED must have EMPTY SERVICES_FAILED; got %q", sf.ServicesFailed)
	}
}

// ---- update-force delegation proofs (installer entry point) ------------------
//
// The shell `nftban update force` branch delegates to the Go installer (proven
// structurally by cli/lib/nftban/tests/update_force_delegation_v1223_test.sh). These
// two tests prove the DELEGATION TARGET (the installer resume/validate path) consumes
// the RESOLVED verdict correctly, so the negative (underprotected) is proven in CI at
// the installer level — NOT via dns2.

// CI_UPDATE_FORCE_DELEGATION: force + live ACTIVE_MATCH → no false DEGRADED.
func TestUpdateForceDelegation_LiveActiveMatch_NoFalseDegraded(t *testing.T) {
	inj, m, cleanup := newAllAssertionsPassFixture(t)
	defer cleanup()
	inj.healthProfile = mediumProfilePtr()
	setHealthActiveMatch(m, mediumProfile())

	sf, _ := driveRepair(t, state.StateDegraded, inj, m, seedPersistedActiveMatch)
	if sf.State != state.StateCommitted {
		t.Fatalf("force-delegated installer + live ACTIVE_MATCH: state=%s want COMMITTED (no false DEGRADED)", sf.State)
	}
}

// UNDERPROTECTED_MEDIUM_FIXTURE: force-delegated installer + live FALLBACK_UNDERSIZED
// (medium fixture) → remains DEGRADED, false COMMIT = 0.
func TestUpdateForceDelegation_LiveUndersizedMedium_StaysDegraded(t *testing.T) {
	inj, m, cleanup := newAllAssertionsPassFixture(t)
	defer cleanup()
	inj.healthProfile = mediumProfilePtr()
	setHealthFallbackUndersized(m)

	sf, _ := driveRepair(t, state.StateDegraded, inj, m, seedPersistedActiveMatch)
	if sf.State != state.StateCommitted && sf.State != state.StateDegraded {
		t.Fatalf("unexpected terminal state %s", sf.State)
	}
	if sf.State == state.StateCommitted {
		t.Fatal("FALSE COMMIT: medium underprotected host must NOT be COMMITTED via update-force delegation")
	}
}

// ---- per-pass Validate-retry (drive phaseValidate directly) -----------------

// drivePhaseValidate runs the real phaseValidate with globalPhaseData wired to the
// injected medium profile and the fixture mock (ssh port 22).
func drivePhaseValidate(t *testing.T, inj *assertionTestInjection, m *executor.MockExecutor) (*state.StateFile, error) {
	t.Helper()
	dir := t.TempDir()
	sf := state.NewStateFile(dir)
	sf.State = state.StateServicesComplete
	sf.Version = version.Version
	sf.SSHPort = 22
	globalPhaseData = phaseData{sshPort: 22, inject: inj}
	log := logging.New(dir+"/installer.log", false)
	err := phaseValidate(context.Background(), m, sf, log)
	return sf, err
}

// VALIDATE_1 mismatch + NO live change → VALIDATE_2 mismatch → stays DEGRADED (no masking).
func TestValidateRetry_NoLiveChange_StaysDegraded(t *testing.T) {
	inj, m, cleanup := newAllAssertionsPassFixture(t)
	defer cleanup()
	inj.healthProfile = mediumProfilePtr()
	setHealthFallbackUndersized(m) // static: both passes see FALLBACK_UNDERSIZED

	sf, _ := drivePhaseValidate(t, inj, m)
	if sf.State != state.StateDegraded {
		t.Fatalf("no live change: state=%s want DEGRADED (VALIDATE_2 must not mask the persistent mismatch)", sf.State)
	}
	if countHealthShow(m) != 2 {
		t.Errorf("per-pass resolution must probe live systemd exactly twice on the retry path; got %d", countHealthShow(m))
	}
}

// VALIDATE_1 mismatch, then live becomes ACTIVE_MATCH before VALIDATE_2 → VALIDATE_2
// uses CURRENT live truth (not a cached verdict) → COMMITTED. Proven via RunResultSeq.
func TestValidateRetry_LiveChangesBetweenPasses_UsesCurrentTruth(t *testing.T) {
	inj, m, cleanup := newAllAssertionsPassFixture(t)
	defer cleanup()
	p := mediumProfile()
	inj.healthProfile = &p
	// The health `systemctl show` returns UNDERSIZED on pass 1 and ACTIVE_MATCH on
	// pass 2 — modeling a drop-in that only becomes effective after the retry.
	m.RunResultSeq[healthShowKey()] = []executor.Result{
		{Stdout: showOut(192*miB, 256*miB, 64, "")},                                 // VALIDATE_1: undersized
		{Stdout: showOut(p.MemoryHigh, p.MemoryMax, 64, healthresource.DropinFile)}, // VALIDATE_2: active
	}

	sf, _ := drivePhaseValidate(t, inj, m)
	if sf.State != state.StateCommitted {
		t.Fatalf("live changed to ACTIVE_MATCH before VALIDATE_2: state=%s want COMMITTED (must use current live truth)", sf.State)
	}
	// VALIDATE_2 resolved a FRESH live verdict (not the VALIDATE_1 cache): the
	// persisted state reflects the second pass's ACTIVE_MATCH.
	if sf.HealthResourceState != string(healthresource.StateActiveMatch) {
		t.Errorf("VALIDATE_2 must reflect the fresh live ACTIVE_MATCH; persisted=%q", sf.HealthResourceState)
	}
	if countHealthShow(m) != 2 {
		t.Errorf("expected exactly 2 live probes (one per pass); got %d", countHealthShow(m))
	}
}

// VALIDATE_1 active → COMMITTED with NO second resolution call (resolver/systemctl
// show invoked exactly once).
func TestValidateRetry_ActivePass1_ResolvesOnce(t *testing.T) {
	inj, m, cleanup := newAllAssertionsPassFixture(t)
	defer cleanup()
	inj.healthProfile = mediumProfilePtr()
	setHealthActiveMatch(m, mediumProfile())

	sf, _ := drivePhaseValidate(t, inj, m)
	if sf.State != state.StateCommitted {
		t.Fatalf("active pass 1: state=%s want COMMITTED", sf.State)
	}
	if got := countHealthShow(m); got != 1 {
		t.Errorf("VALIDATE_1 all-pass must resolve the verdict EXACTLY once (no retry); live probes=%d want 1", got)
	}
}

// ---- DEGRADED report path ---------------------------------------------------

func captureReport(t *testing.T, sf *state.StateFile) string {
	t.Helper()
	origStdout := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	os.Stdout = w
	log := logging.New(t.TempDir()+"/installer.log", false)
	_ = report(sf, log)
	_ = w.Close()
	var buf bytes.Buffer
	_, _ = io.Copy(&buf, r)
	os.Stdout = origStdout
	log.Close()
	return buf.String()
}

// Resource-policy DEGRADED (empty ServicesFailed) → NO "failed NFTBan unit" claim
// and no unit reset guidance (BUG-DEGRADED-REPORT-FALSE-FAILED-UNIT-CLAIM).
func TestReportDegraded_EmptyServicesFailed_NoFalseUnitClaim(t *testing.T) {
	sf := state.NewStateFile(t.TempDir())
	sf.State = state.StateDegraded
	sf.Authority = "UPDATE"
	sf.FailureReason = "failed assertions after safe auto-fix: health_resource_policy_active (profile=medium ...)"
	sf.ServicesFailed = "" // resource-policy verdict DEGRADED — no failed unit

	out := captureReport(t, sf)

	if strings.Contains(out, "failed NFTBan unit") {
		t.Errorf("resource-policy DEGRADED must NOT claim a failed NFTBan unit; output:\n%s", out)
	}
	if strings.Contains(out, "reset-failed") || strings.Contains(out, "Failed unit:") {
		t.Errorf("resource-policy DEGRADED must NOT print unit reset guidance; output:\n%s", out)
	}
	if !strings.Contains(out, "State: DEGRADED") {
		t.Errorf("DEGRADED report must state DEGRADED; output:\n%s", out)
	}
}

// A real failed unit (ServicesFailed set) → structured per-unit remediation present.
func TestReportDegraded_RealFailedUnit_StructuredRemediation(t *testing.T) {
	sf := state.NewStateFile(t.TempDir())
	sf.State = state.StateDegraded
	sf.FailureReason = "failed assertions after safe auto-fix: failed_units_postinstall_ok"
	sf.ServicesFailed = "nftban-botscan.service"

	out := captureReport(t, sf)

	if !strings.Contains(out, "Failed unit: nftban-botscan.service") {
		t.Errorf("real failed unit must be surfaced with structured remediation; output:\n%s", out)
	}
	if !strings.Contains(out, "systemctl start nftban-botscan.service") {
		t.Errorf("structured remediation must include the start/verify step; output:\n%s", out)
	}
}
