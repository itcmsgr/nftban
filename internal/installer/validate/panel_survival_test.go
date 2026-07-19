// =============================================================================
// NFTBan v1.100.x PR26.2 - panel_survival_ok assertion integration tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-validate-panel-survival-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-29"
// meta:description="End-to-end test that PANEL-SURVIVAL-001 blocks StateCommitted via AllPassed"
// meta:inventory.files="internal/installer/validate/panel_survival_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package validate

import (
	"context"
	"errors"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/panelfw"
)

// fakeAdapter is a minimal stand-in. We deliberately do NOT import
// the FakePanelAdapter from panelfw_test.go (which is _test-scoped
// to that package).
type fakeAdapter struct {
	id       panelfw.PanelID
	detected bool
	tcp      []int
	rpErr    error
	reachErr error
}

func (f fakeAdapter) ID() panelfw.PanelID { return f.id }
func (f fakeAdapter) Detect(_ context.Context, _ executor.Executor) panelfw.PanelDetection {
	return panelfw.PanelDetection{ID: f.id, Detected: f.detected, RequiredTCP: f.tcp}
}
func (f fakeAdapter) RequiredPorts(_ context.Context, _ executor.Executor) ([]int, []int, error) {
	return f.tcp, nil, f.rpErr
}
func (f fakeAdapter) ValidateReachability(_ context.Context, _ executor.Executor) error {
	return f.reachErr
}

// Detected + integration failure must block StateCommitted: the new
// panel_survival_ok assertion flips Passed=false; AllPassed returns
// false; the lifecycle gate at phases.go:353/378 falls through to
// StateDegraded.
func TestRunAssertions_PanelSurvival_BlocksStateCommitted(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Services["nftables"] = true
	mock.Services["nftband.service"] = true
	mock.NftTables["ip:nftban"] = true
	mock.NftTables["ip6:nftban"] = true
	mock.RunResults["nft:list:chain:ip:nftban:input"] = executor.Result{ExitCode: 0}
	mock.NftSets["ip:nftban:tcp_ports_in"] = "elements = { 22, 80, 443 }"
	mock.Files["/var/lib/nftban/state/install_state"] = []byte("COMMITTED")
	seedCompletePayloadInventory(mock)

	failingAdapter := fakeAdapter{
		id:       "fakepanel",
		detected: true,
		tcp:      []int{12345},
		reachErr: errors.New("port 12345 unreachable"),
	}
	opts := AssertionOpts{
		PanelAdapters: []panelfw.PanelAdapter{failingAdapter},
	}.WithPanelPolicy(panelfw.DefaultPolicy())

	results := RunAssertionsWithOpts(mock, 22, newTestLogger(), opts)

	if AllPassed(results) {
		t.Fatalf("AllPassed must be false when panel-survival fails")
	}
	var found bool
	for _, r := range results {
		if r.Name == "panel_survival_ok" {
			found = true
			if r.Passed {
				t.Errorf("panel_survival_ok must be Passed=false")
			}
			if r.Detail == "" {
				t.Errorf("panel_survival_ok must carry a non-empty Detail message")
			}
		}
	}
	if !found {
		t.Errorf("panel_survival_ok assertion missing from results: %v", FailedNames(results))
	}
}

// Operator-disabled (--no-panel) flips a failing adapter to non-fatal:
// the assertion still runs (diagnostic) but does not block StateCommitted.
func TestRunAssertions_PanelSurvival_OperatorDisabled_DoesNotBlock(t *testing.T) {
	seedReadyLogretention(t)
	mock := executor.NewMockExecutor()
	mock.Services["nftables"] = true
	mock.Services["nftband.service"] = true
	mock.NftTables["ip:nftban"] = true
	mock.NftTables["ip6:nftban"] = true
	mock.RunResults["nft:list:chain:ip:nftban:input"] = executor.Result{ExitCode: 0}
	mock.NftSets["ip:nftban:tcp_ports_in"] = "elements = { 22, 80, 443 }"
	mock.Files["/var/lib/nftban/state/install_state"] = []byte("COMMITTED")
	seedCompletePayloadInventory(mock)

	failingAdapter := fakeAdapter{
		id:       "fakepanel",
		detected: true,
		tcp:      []int{12345},
		reachErr: errors.New("port 12345 unreachable"),
	}
	policy := panelfw.DefaultPolicy()
	policy.OperatorDisabled = true
	opts := AssertionOpts{
		PanelAdapters: []panelfw.PanelAdapter{failingAdapter},
	}.WithPanelPolicy(policy)

	results := RunAssertionsWithOpts(mock, 22, newTestLogger(), opts)

	if !AllPassed(results) {
		t.Fatalf("AllPassed must be true when --no-panel disables the gate; failures: %v", FailedNames(results))
	}
}

// Default RunAssertions (no opts) keeps the registry empty + default
// policy → assertion is a no-op pass. Verifies existing callers stay
// source-compatible.
func TestRunAssertions_DefaultPath_PanelSurvivalPasses(t *testing.T) {
	seedReadyLogretention(t)
	mock := executor.NewMockExecutor()
	mock.Services["nftables"] = true
	mock.Services["nftband.service"] = true
	mock.NftTables["ip:nftban"] = true
	mock.NftTables["ip6:nftban"] = true
	mock.RunResults["nft:list:chain:ip:nftban:input"] = executor.Result{ExitCode: 0}
	mock.NftSets["ip:nftban:tcp_ports_in"] = "elements = { 22, 80, 443 }"
	mock.Files["/var/lib/nftban/state/install_state"] = []byte("COMMITTED")
	seedCompletePayloadInventory(mock)

	results := RunAssertions(mock, 22, newTestLogger())

	if !AllPassed(results) {
		t.Fatalf("default RunAssertions must pass when registry is empty: failures=%v", FailedNames(results))
	}
	var seen bool
	for _, r := range results {
		if r.Name == "panel_survival_ok" {
			seen = true
			if !r.Passed {
				t.Errorf("panel_survival_ok must pass with empty registry + default policy")
			}
		}
	}
	if !seen {
		t.Errorf("panel_survival_ok must be present in default RunAssertions output")
	}
}
