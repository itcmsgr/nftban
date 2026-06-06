// =============================================================================
// NFTBan v1.100.x PR26.2 - Panel Framework Tests (FakePanelAdapter)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-panelfw-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-29"
// meta:description="FakePanelAdapter + EvaluateAdapters tests; framework read-only invariant"
// meta:inventory.files="internal/installer/panelfw/panelfw_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package panelfw

import (
	"context"
	"errors"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

func newTestLogger() *logging.Logger {
	return logging.New("/dev/null", false)
}

// FakePanelAdapter is a configurable test double for the PanelAdapter
// contract. It is defined in _test.go so it never compiles into the
// production binary.
//
// It deliberately does NOT call any executor mutation method — the
// framework-read-only invariant is enforced structurally by giving
// the fake no mutation surface to invoke.
type FakePanelAdapter struct {
	IDValue          PanelID
	DetectResult     PanelDetection
	RequiredTCP      []int
	RequiredUDP      []int
	RequiredPortsErr error
	ReachabilityErr  error

	// Counters for assertions about call discipline.
	DetectCalls       int
	RequiredCalls     int
	ReachabilityCalls int
}

func (f *FakePanelAdapter) ID() PanelID { return f.IDValue }

func (f *FakePanelAdapter) Detect(_ context.Context, _ executor.Executor) PanelDetection {
	f.DetectCalls++
	return f.DetectResult
}

func (f *FakePanelAdapter) RequiredPorts(_ context.Context, _ executor.Executor) ([]int, []int, error) {
	f.RequiredCalls++
	return f.RequiredTCP, f.RequiredUDP, f.RequiredPortsErr
}

func (f *FakePanelAdapter) ValidateReachability(_ context.Context, _ executor.Executor) error {
	f.ReachabilityCalls++
	return f.ReachabilityErr
}

// ----------------------------------------------------------------------------
// Spec case 1: fake panel detected + integration failure → StateCommitted blocked
// ----------------------------------------------------------------------------

func TestFake_Detected_ReachabilityFails_PolicyBlocks(t *testing.T) {
	fake := &FakePanelAdapter{
		IDValue: "fakepanel",
		DetectResult: PanelDetection{
			ID:          "fakepanel",
			Detected:    true,
			Confidence:  "strong",
			Evidence:    []string{"fake-marker"},
			RequiredTCP: []int{12345},
		},
		RequiredTCP:     []int{12345},
		ReachabilityErr: errors.New("port 12345 unreachable"),
	}
	mock := executor.NewMockExecutor()

	res := EvaluateAdapters(context.Background(), mock, newTestLogger(),
		[]PanelAdapter{fake}, DefaultPolicy())

	if !res.Fatal {
		t.Fatalf("expected Fatal=true; got %#v", res)
	}
	if !res.Detection.Detected {
		t.Errorf("expected Detection.Detected=true")
	}
	if !res.PortsApplied {
		t.Errorf("PortsApplied should be true (RequiredPorts succeeded)")
	}
	if res.ReachableAfter {
		t.Errorf("ReachableAfter should be false")
	}
	if fake.ReachabilityCalls != 1 {
		t.Errorf("expected ValidateReachability called once; got %d", fake.ReachabilityCalls)
	}
}

func TestFake_Detected_RequiredPortsFails_PolicyBlocks(t *testing.T) {
	fake := &FakePanelAdapter{
		IDValue:          "fakepanel",
		DetectResult:     PanelDetection{ID: "fakepanel", Detected: true},
		RequiredPortsErr: errors.New("config unreadable"),
	}
	res := EvaluateAdapters(context.Background(), executor.NewMockExecutor(), newTestLogger(),
		[]PanelAdapter{fake}, DefaultPolicy())
	if !res.Fatal {
		t.Fatalf("expected Fatal=true on RequiredPorts error")
	}
	if res.PortsApplied {
		t.Errorf("PortsApplied should be false on RequiredPorts error")
	}
	if fake.ReachabilityCalls != 0 {
		t.Errorf("ValidateReachability must NOT be called after RequiredPorts errored; got %d", fake.ReachabilityCalls)
	}
}

// ----------------------------------------------------------------------------
// Spec case 2: fake panel absent → pass
// ----------------------------------------------------------------------------

func TestFake_Absent_PolicyPasses(t *testing.T) {
	fake := &FakePanelAdapter{
		IDValue:      "fakepanel",
		DetectResult: PanelDetection{ID: "fakepanel", Detected: false},
	}
	res := EvaluateAdapters(context.Background(), executor.NewMockExecutor(), newTestLogger(),
		[]PanelAdapter{fake}, DefaultPolicy())
	if res.Fatal {
		t.Fatalf("expected Fatal=false when no panel detected; got %#v", res)
	}
	if fake.RequiredCalls != 0 || fake.ReachabilityCalls != 0 {
		t.Errorf("RequiredPorts/Reachability must NOT be called when Detect=false; got Required=%d Reachability=%d",
			fake.RequiredCalls, fake.ReachabilityCalls)
	}
}

// AllowPanelAbsent=false should make absence Fatal.
func TestAbsent_AllowPanelAbsentFalse_Fatal(t *testing.T) {
	policy := DefaultPolicy()
	policy.AllowPanelAbsent = false
	res := EvaluateAdapters(context.Background(), executor.NewMockExecutor(), newTestLogger(),
		nil, policy)
	if !res.Fatal {
		t.Fatalf("expected Fatal=true when AllowPanelAbsent=false")
	}
	if res.Reason == "" {
		t.Errorf("expected non-empty Reason for absent + AllowPanelAbsent=false")
	}
}

// ----------------------------------------------------------------------------
// Spec case 3: fake panel detected + required ports applied → pass
// ----------------------------------------------------------------------------

func TestFake_Detected_HappyPath_PolicyPasses(t *testing.T) {
	fake := &FakePanelAdapter{
		IDValue: "fakepanel",
		DetectResult: PanelDetection{
			ID:          "fakepanel",
			Detected:    true,
			Confidence:  "strong",
			RequiredTCP: []int{12345},
		},
		RequiredTCP: []int{12345},
	}
	res := EvaluateAdapters(context.Background(), executor.NewMockExecutor(), newTestLogger(),
		[]PanelAdapter{fake}, DefaultPolicy())
	if res.Fatal {
		t.Fatalf("expected Fatal=false on happy path; got %#v", res)
	}
	if !res.PortsApplied || !res.ReachableAfter {
		t.Errorf("expected PortsApplied=true ReachableAfter=true; got %#v", res)
	}
	if len(res.PortsTCP) != 1 || res.PortsTCP[0] != 12345 {
		t.Errorf("expected PortsTCP=[12345]; got %v", res.PortsTCP)
	}
}

// ----------------------------------------------------------------------------
// Spec case 4: --no-panel / explicit disabled mode → policy decides
// ----------------------------------------------------------------------------

// OperatorDisabled=true makes a failed integration non-fatal.
func TestFake_Detected_FailingIntegration_OperatorDisabled_Passes(t *testing.T) {
	fake := &FakePanelAdapter{
		IDValue:         "fakepanel",
		DetectResult:    PanelDetection{ID: "fakepanel", Detected: true},
		RequiredTCP:     []int{12345},
		ReachabilityErr: errors.New("port unreachable"),
	}
	policy := DefaultPolicy()
	policy.OperatorDisabled = true
	res := EvaluateAdapters(context.Background(), executor.NewMockExecutor(), newTestLogger(),
		[]PanelAdapter{fake}, policy)
	if res.Fatal {
		t.Fatalf("OperatorDisabled=true must convert failure to non-fatal; got Fatal=true (%#v)", res)
	}
	if res.ReachableAfter {
		t.Errorf("ReachableAfter should still reflect actual outcome (false), not policy override")
	}
}

// OperatorDisabled=true with happy-path integration still passes.
func TestFake_Detected_HappyPath_OperatorDisabled_Passes(t *testing.T) {
	fake := &FakePanelAdapter{
		IDValue:      "fakepanel",
		DetectResult: PanelDetection{ID: "fakepanel", Detected: true},
		RequiredTCP:  []int{12345},
	}
	policy := DefaultPolicy()
	policy.OperatorDisabled = true
	res := EvaluateAdapters(context.Background(), executor.NewMockExecutor(), newTestLogger(),
		[]PanelAdapter{fake}, policy)
	if res.Fatal {
		t.Fatalf("expected Fatal=false on happy path even with OperatorDisabled; got %#v", res)
	}
}

// RequirePanelSuccess=false disables the gate even when OperatorDisabled is
// false. Mirrors the pre-PR26.2 "warn only" behavior, useful for migration.
func TestFake_Detected_FailingIntegration_RequirePanelSuccessFalse_Passes(t *testing.T) {
	fake := &FakePanelAdapter{
		IDValue:         "fakepanel",
		DetectResult:    PanelDetection{ID: "fakepanel", Detected: true},
		RequiredTCP:     []int{12345},
		ReachabilityErr: errors.New("port unreachable"),
	}
	policy := DefaultPolicy()
	policy.RequirePanelSuccess = false
	res := EvaluateAdapters(context.Background(), executor.NewMockExecutor(), newTestLogger(),
		[]PanelAdapter{fake}, policy)
	if res.Fatal {
		t.Fatalf("RequirePanelSuccess=false must convert failure to non-fatal; got Fatal=true")
	}
}

// ----------------------------------------------------------------------------
// Spec case 5: framework read-only — no executor mutation
// ----------------------------------------------------------------------------

// The fake adapter calls only the methods declared on PanelAdapter.
// We verify the framework never invokes a mutation primitive on the
// executor by inspecting MockExecutor.Commands and the WrittenFiles
// map after EvaluateAdapters runs across every shape.
func TestFramework_NoExecutorMutation(t *testing.T) {
	cases := []struct {
		name string
		fake *FakePanelAdapter
	}{
		{"absent", &FakePanelAdapter{IDValue: "fakepanel"}},
		{"happy", &FakePanelAdapter{
			IDValue:      "fakepanel",
			DetectResult: PanelDetection{ID: "fakepanel", Detected: true},
			RequiredTCP:  []int{12345},
		}},
		{"reach-fail", &FakePanelAdapter{
			IDValue:         "fakepanel",
			DetectResult:    PanelDetection{ID: "fakepanel", Detected: true},
			RequiredTCP:     []int{12345},
			ReachabilityErr: errors.New("x"),
		}},
		{"required-fail", &FakePanelAdapter{
			IDValue:          "fakepanel",
			DetectResult:     PanelDetection{ID: "fakepanel", Detected: true},
			RequiredPortsErr: errors.New("x"),
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			mock := executor.NewMockExecutor()
			_ = EvaluateAdapters(context.Background(), mock, newTestLogger(),
				[]PanelAdapter{c.fake}, DefaultPolicy())
			if len(mock.WrittenFiles) != 0 {
				t.Errorf("framework wrote %d files via executor (want 0)", len(mock.WrittenFiles))
			}
			if len(mock.Commands) != 0 {
				t.Errorf("framework executed %d commands via executor (want 0); first=%v",
					len(mock.Commands), mock.Commands[0])
			}
		})
	}
}

// ----------------------------------------------------------------------------
// First-detected-wins semantics across multi-adapter registry.
// ----------------------------------------------------------------------------

func TestEvaluateAdapters_FirstDetectedWins(t *testing.T) {
	first := &FakePanelAdapter{
		IDValue:      "first",
		DetectResult: PanelDetection{ID: "first", Detected: false},
	}
	second := &FakePanelAdapter{
		IDValue:      "second",
		DetectResult: PanelDetection{ID: "second", Detected: true},
		RequiredTCP:  []int{2222},
	}
	third := &FakePanelAdapter{
		IDValue:      "third",
		DetectResult: PanelDetection{ID: "third", Detected: true},
	}
	res := EvaluateAdapters(context.Background(), executor.NewMockExecutor(), newTestLogger(),
		[]PanelAdapter{first, second, third}, DefaultPolicy())
	if res.Detection.ID != "second" {
		t.Errorf("expected detection ID=second; got %q", res.Detection.ID)
	}
	if third.DetectCalls != 0 {
		t.Errorf("third adapter MUST NOT be called after second matched; got DetectCalls=%d", third.DetectCalls)
	}
}

// ----------------------------------------------------------------------------
// Registry isolation
// ----------------------------------------------------------------------------

func TestRegisteredAdapters_EmptyByDefault(t *testing.T) {
	resetRegistryForTest()
	t.Cleanup(resetRegistryForTest)
	got := RegisteredAdapters()
	if len(got) != 0 {
		t.Fatalf("expected empty registry in PR26.2; got %d adapters", len(got))
	}
}

func TestRegister_AppendsAndCopiesOut(t *testing.T) {
	resetRegistryForTest()
	t.Cleanup(resetRegistryForTest)
	a := &FakePanelAdapter{IDValue: "fakepanel"}
	Register(a)
	got := RegisteredAdapters()
	if len(got) != 1 || got[0].ID() != "fakepanel" {
		t.Fatalf("Register did not append fakepanel; got %v", got)
	}
	// Returned slice must be a copy — mutating it must not affect the
	// internal registry.
	got[0] = nil
	got2 := RegisteredAdapters()
	if got2[0] == nil {
		t.Errorf("RegisteredAdapters returned slice aliasing internal state")
	}
}

func TestRegister_NilIsNoop(t *testing.T) {
	resetRegistryForTest()
	t.Cleanup(resetRegistryForTest)
	Register(nil)
	if len(RegisteredAdapters()) != 0 {
		t.Errorf("Register(nil) must be a no-op")
	}
}

// ----------------------------------------------------------------------------
// DefaultPolicy contract
// ----------------------------------------------------------------------------

func TestDefaultPolicy_Values(t *testing.T) {
	p := DefaultPolicy()
	if !p.RequirePanelSuccess {
		t.Errorf("DefaultPolicy.RequirePanelSuccess must be true")
	}
	if !p.AllowPanelAbsent {
		t.Errorf("DefaultPolicy.AllowPanelAbsent must be true")
	}
	if p.OperatorDisabled {
		t.Errorf("DefaultPolicy.OperatorDisabled must be false")
	}
}

// Logger nil tolerance: production wires a real logger; tests sometimes
// pass nil. The framework must not panic.
func TestEvaluateAdapters_NilLoggerTolerated(t *testing.T) {
	res := EvaluateAdapters(context.Background(), executor.NewMockExecutor(), nil,
		nil, DefaultPolicy())
	if res.Fatal {
		t.Errorf("nil logger + empty adapters + default policy should be non-fatal")
	}
}

// ----------------------------------------------------------------------------
// v1.151 BUG-PANELFW-WEAK-DA-FALSE-POSITIVE: a "weak" detection (single
// host-env signal, e.g. a bare :2222 listener on a no-panel host) must NOT be
// validated or have its panel port set printed as if confirmed.
// ----------------------------------------------------------------------------

func TestFake_WeakDetection_NotValidated_FallsToNoPanel(t *testing.T) {
	fake := &FakePanelAdapter{
		IDValue: "directadmin",
		DetectResult: PanelDetection{
			ID:         "directadmin",
			Detected:   true,
			Confidence: "weak", // single indicator → must be ignored
			Evidence:   []string{"listener-tcp:2222"},
		},
		RequiredTCP: []int{35000, 35999}, // would be printed if (wrongly) finalized
	}
	res := EvaluateAdapters(context.Background(), executor.NewMockExecutor(), newTestLogger(),
		[]PanelAdapter{fake}, DefaultPolicy())

	// Weak → not confirmed → no panel ports queried/validated/printed.
	if fake.RequiredCalls != 0 || fake.ReachabilityCalls != 0 {
		t.Errorf("weak detection must NOT validate/print ports; got Required=%d Reachability=%d",
			fake.RequiredCalls, fake.ReachabilityCalls)
	}
	// Falls through to no-panel (DefaultPolicy allows absent → non-fatal).
	if res.Detection.Detected {
		t.Errorf("weak detection must NOT be reported as a confirmed panel")
	}
	if res.PortsApplied {
		t.Errorf("PortsApplied must be false for a weak (unconfirmed) detection")
	}
	if res.Fatal {
		t.Errorf("weak-only host with AllowPanelAbsent=true must be non-fatal; got %#v", res)
	}
	if fake.DetectCalls != 1 {
		t.Errorf("Detect should be called once; got %d", fake.DetectCalls)
	}
}

// Regression guard: a STRONG detection still finalizes (validates + applies ports).
func TestFake_StrongDetection_StillFinalizes(t *testing.T) {
	fake := &FakePanelAdapter{
		IDValue: "directadmin",
		DetectResult: PanelDetection{
			ID:         "directadmin",
			Detected:   true,
			Confidence: "strong",
		},
		RequiredTCP: []int{2222, 2086},
	}
	res := EvaluateAdapters(context.Background(), executor.NewMockExecutor(), newTestLogger(),
		[]PanelAdapter{fake}, DefaultPolicy())
	if fake.RequiredCalls != 1 || fake.ReachabilityCalls != 1 {
		t.Errorf("strong detection must validate/apply ports; got Required=%d Reachability=%d",
			fake.RequiredCalls, fake.ReachabilityCalls)
	}
	if !res.PortsApplied || !res.Detection.Detected {
		t.Errorf("strong detection must finalize as a confirmed panel; got %#v", res)
	}
}
