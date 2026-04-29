// =============================================================================
// NFTBan v1.100.x PR26.2 - Reusable Panel Adapter Framework
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-panelfw"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-29"
// meta:description="Generic hosting-panel adapter framework — survival policy + registry"
// meta:inventory.files="internal/installer/panelfw/panelfw.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// PR26.2 — generic panel framework. PANEL-SURVIVAL-001 invariant:
//
//	If a hosting panel is detected before lifecycle mutation,
//	then nftban must either preserve the panel's required service ports
//	through the canonical ports model and validate integration success,
//	OR abort before StateCommitted with a clear panel-safety error.
//	Panel detected + integration failure must never reach StateCommitted,
//	unless the operator explicitly disables panel integration with a
//	supported flag.
//
// Hard exclusions in this PR (DirectAdmin/cPanel/Plesk live in PR26.3+):
//   - no real adapter implementations (RegisteredAdapters returns nil)
//   - no firewall mutation
//   - no host destructive testing
//   - no restore semantics
//
// Adapters are required to be read-only by interface contract:
// Detect, RequiredPorts, and ValidateReachability MUST NOT mutate the
// host. The framework calls each in sequence and converts results into
// a PanelResult; the caller (validate.assertion) decides whether to
// block StateCommitted.
//
// =============================================================================

package panelfw

import (
	"context"
	"fmt"
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// PanelID is the canonical identifier for a hosting panel adapter.
// Matches the lower-case panel-name convention used throughout the
// installer (e.g., "directadmin", "cpanel", "plesk", "fakepanel").
type PanelID string

// PanelDetection is the structured outcome of an adapter's Detect()
// call. Adapters set Detected=true only when their evidence list is
// non-empty; Confidence is "strong" when the adapter is sure (e.g.,
// canonical install dir + listening port + active service) and "weak"
// when only one indicator was found.
type PanelDetection struct {
	ID          PanelID
	Detected    bool
	Confidence  string
	Evidence    []string
	RequiredTCP []int
	RequiredUDP []int
	Warnings    []string
}

// PanelAdapter is the contract every panel plugin implements. All
// methods MUST be read-only — the framework guarantees that calling
// Detect, RequiredPorts, or ValidateReachability never mutates host
// state. Adapters that need to write configuration (e.g., to apply
// ports to the canonical ports model) do that through a separate
// host-controlled write path; the framework only consults the adapter
// for facts and validates outcomes.
type PanelAdapter interface {
	// ID returns the canonical adapter identifier.
	ID() PanelID

	// Detect inspects the host and returns whether this adapter's
	// panel is present, with evidence and required ports.
	Detect(ctx context.Context, exec executor.Executor) PanelDetection

	// RequiredPorts returns the TCP and UDP port lists the panel
	// must keep reachable for its control surface to survive an
	// nftban lifecycle operation. Returns an error if the adapter
	// cannot enumerate them (e.g., panel config unreadable).
	RequiredPorts(ctx context.Context, exec executor.Executor) (tcp []int, udp []int, err error)

	// ValidateReachability confirms the panel's control surface is
	// reachable in the current ruleset. Read-only: it MUST NOT
	// mutate ports, services, or rules. Returns nil on success or
	// a structured error describing the missing-port/timeout/etc.
	// condition.
	ValidateReachability(ctx context.Context, exec executor.Executor) error
}

// PanelPolicy controls how the framework converts adapter outcomes
// into a Fatal/non-fatal verdict.
type PanelPolicy struct {
	// RequirePanelSuccess: when an adapter detects a panel and either
	// RequiredPorts or ValidateReachability errors, the result is
	// Fatal. Default true. The "non-fatal warning" path that let
	// dns2's panel-enable failure slip through StateCommitted is
	// removed by setting this to true.
	RequirePanelSuccess bool

	// AllowPanelAbsent: when no adapter detects a panel, treat as
	// healthy (the common no-panel case). Default true.
	AllowPanelAbsent bool

	// OperatorDisabled: operator passed --no-panel (or equivalent
	// supported flag) to opt out of panel-survival enforcement on
	// this run. The framework still runs adapters for diagnostic
	// purposes but always returns Fatal=false.
	OperatorDisabled bool
}

// DefaultPolicy returns the production-default policy:
// RequirePanelSuccess=true, AllowPanelAbsent=true, OperatorDisabled=false.
func DefaultPolicy() PanelPolicy {
	return PanelPolicy{
		RequirePanelSuccess: true,
		AllowPanelAbsent:    true,
		OperatorDisabled:    false,
	}
}

// PanelResult is the structured outcome of Evaluate.
type PanelResult struct {
	// Detection is the first adapter's detection record (or a
	// zero-value detection with ID="" when no adapter detected
	// anything).
	Detection PanelDetection

	// PortsTCP / PortsUDP mirror the RequiredPorts result for the
	// detected panel (nil when no panel detected or RequiredPorts
	// errored).
	PortsTCP []int
	PortsUDP []int

	// PortsApplied indicates whether the adapter's RequiredPorts
	// call succeeded. It does NOT confirm ports were written to the
	// canonical ports model — that is a separate framework
	// responsibility outside PR26.2 scope. The flag exists so the
	// assertion message can distinguish "couldn't determine ports"
	// from "ports known and reachability validated".
	PortsApplied bool

	// ReachableAfter is true when ValidateReachability returned nil.
	// False on adapter error or when the framework did not reach
	// the reachability check (e.g., RequiredPorts errored first).
	ReachableAfter bool

	// Fatal is the policy-derived verdict. When true, the caller
	// (validate.assertion) MUST block StateCommitted.
	Fatal bool

	// Reason carries a human-readable summary suitable for the
	// AssertionResult.Detail field. Empty when not Fatal.
	Reason string
}

// registry holds adapters in package-private state. Production code
// path: filled by adapter packages' init() (PR26.3 onwards). Tests
// pass an explicit slice to EvaluateAdapters and bypass the registry.
var registry []PanelAdapter

// Register adds a PanelAdapter to the package registry. Adapter
// packages call this from init(); the framework iterates the registry
// in registration order during Evaluate.
//
// Duplicate IDs are not enforced — the first detected panel wins
// regardless. Adapter authors are responsible for non-overlapping
// detection criteria.
func Register(a PanelAdapter) {
	if a == nil {
		return
	}
	registry = append(registry, a)
}

// RegisteredAdapters returns a copy of the current registry. Stable
// in registration order. Returns an empty slice when nothing has
// been registered (the PR26.2 default — no adapters compiled in).
func RegisteredAdapters() []PanelAdapter {
	out := make([]PanelAdapter, len(registry))
	copy(out, registry)
	return out
}

// resetRegistryForTest is exported via _test.go helpers to allow
// per-test isolation. Production code never calls it.
func resetRegistryForTest() {
	registry = nil
}

// Evaluate runs the registered adapters and returns the first detected
// panel's PanelResult. Pure framework call — relies entirely on the
// adapter contract; no panel-specific knowledge in this function.
func Evaluate(ctx context.Context, exec executor.Executor, log *logging.Logger, policy PanelPolicy) PanelResult {
	return EvaluateAdapters(ctx, exec, log, RegisteredAdapters(), policy)
}

// EvaluateAdapters is the test-callable variant of Evaluate. Callers
// pass an explicit adapter slice so they can inject FakePanelAdapter
// without touching the global registry.
func EvaluateAdapters(ctx context.Context, exec executor.Executor, log *logging.Logger, adapters []PanelAdapter, policy PanelPolicy) PanelResult {
	if log == nil {
		log = logging.New("/dev/null", false)
	}

	// No adapter detected anything → policy decides. Default
	// AllowPanelAbsent=true means non-fatal pass.
	if len(adapters) == 0 {
		log.Debug("panelfw: no adapters registered — treating as no-panel host")
		return PanelResult{
			Detection: PanelDetection{},
			Fatal:     !policy.AllowPanelAbsent,
			Reason:    panelAbsentReason(policy),
		}
	}

	for _, a := range adapters {
		det := a.Detect(ctx, exec)
		if !det.Detected {
			continue
		}
		log.Info("panelfw: detected panel id=%s confidence=%s",
			string(det.ID), det.Confidence)
		return finalizeDetected(ctx, exec, log, a, det, policy)
	}

	log.Debug("panelfw: no adapter reported a detected panel")
	return PanelResult{
		Detection: PanelDetection{},
		Fatal:     !policy.AllowPanelAbsent,
		Reason:    panelAbsentReason(policy),
	}
}

func panelAbsentReason(policy PanelPolicy) string {
	if policy.AllowPanelAbsent {
		return ""
	}
	return "no hosting panel detected, but policy.AllowPanelAbsent=false requires one"
}

// finalizeDetected runs RequiredPorts + ValidateReachability and
// converts the outcomes into a policy-derived PanelResult.
func finalizeDetected(ctx context.Context, exec executor.Executor, log *logging.Logger, a PanelAdapter, det PanelDetection, policy PanelPolicy) PanelResult {
	res := PanelResult{Detection: det}

	tcp, udp, err := a.RequiredPorts(ctx, exec)
	if err != nil {
		res.PortsApplied = false
		res.Reason = fmt.Sprintf("panel %s RequiredPorts failed: %v", string(det.ID), err)
		log.Warn("panelfw: %s", res.Reason)
		res.Fatal = computeFatal(policy)
		return res
	}
	res.PortsTCP = tcp
	res.PortsUDP = udp
	res.PortsApplied = true

	if rerr := a.ValidateReachability(ctx, exec); rerr != nil {
		res.ReachableAfter = false
		res.Reason = fmt.Sprintf("panel %s ValidateReachability failed: %v", string(det.ID), rerr)
		log.Warn("panelfw: %s", res.Reason)
		res.Fatal = computeFatal(policy)
		return res
	}
	res.ReachableAfter = true
	log.Info("panelfw: panel %s integration validated tcp=%s udp=%s",
		string(det.ID), portsToString(tcp), portsToString(udp))
	return res
}

// computeFatal applies the policy to a failed integration outcome.
// The OperatorDisabled override turns any failure non-fatal — the
// operator has explicitly accepted the risk via --no-panel.
func computeFatal(policy PanelPolicy) bool {
	if policy.OperatorDisabled {
		return false
	}
	return policy.RequirePanelSuccess
}

// portsToString renders a port slice as a stable comma-separated
// string for log output.
func portsToString(ps []int) string {
	if len(ps) == 0 {
		return "[]"
	}
	parts := make([]string, len(ps))
	for i, p := range ps {
		parts[i] = fmt.Sprintf("%d", p)
	}
	return "[" + strings.Join(parts, ",") + "]"
}
