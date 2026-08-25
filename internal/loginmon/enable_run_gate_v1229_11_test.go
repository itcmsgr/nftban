// =============================================================================
// NFTBan v1.229.11 - LoginMon enable-flag runtime gate
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="loginmon_enable_run_gate_v1229_11_test"
// meta:type="test"
// meta:version="1.229.11"
// meta:owner="NFTBan Project / Antonios Voulvoulis"
// meta:description="Closes OPEN_MODULE_ENABLE_FLAG_NOT_A_RUN_GATE for LoginMon. LOGIN_ENABLED was parsed into config.Enabled whose only consumers were the status field and config reload; there was no gate in Start(), Registry.StartAll or the ban path, so the module ran and could enforce regardless of durable operator intent -- nftban login disable changed the reported status and nothing else (fail-OPEN). The register named ddos and portscan as sharing the shape; both were verified already gated on 2026-08-25 (ddos v1.229.7 PR-2 :308/:355, portscan :298/:344, botguard always correct), so loginmon was the last affected module. Asserts: a disabled module does not start runtime work and reports not-running; a disabled module cannot emit a ban even if the path is reached (defence in depth, closest to the effect); an enabled module is unaffected; and Stop() on a disabled module is a no-op so a service stop cannot durably change module configuration."
// meta:inventory.files="internal/loginmon/module.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars="LOGIN_ENABLED"
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package loginmon

import (
	"context"
	"testing"
)

// REUSE the package's existing newTestModule (watcher_respawn_v176_test.go) —
// it already builds a Module with a live bus, which is what Start() needs.
// New() alone leaves m.bus nil and Start() faults on it: a harness gap, not a
// product defect.
//
//	REUSE THE EXISTING TEST AUTHORITY — A SECOND CONSTRUCTOR IS A SECOND TRUTH.
func gateModule(enabled bool) *Module {
	m := newTestModule()
	m.config.Enabled = enabled
	return m
}

// A DISABLED module must not start runtime work.
//
//	A FLAG THAT ONLY REACHES THE STATUS FIELD IS A LABEL, NOT A CONTROL.
func TestDisabledModuleDoesNotStart(t *testing.T) {
	m := gateModule(false)

	if err := m.Start(context.Background()); err != nil {
		t.Fatalf("Start() on a disabled module must return nil, got %v", err)
	}

	// The gate returns before MarkRunning(), so the module must not claim to run.
	if m.status.Running {
		t.Error("disabled module reports Running=true — the enable flag is not a run gate")
	}
	// And it must not have taken a cancel func, which only Start's live path sets.
	if m.cancel != nil {
		t.Error("disabled module acquired a cancel func — runtime work was started")
	}
}

// The ENABLED path must be unaffected by the gate. Without this, a gate that
// simply returned early for everyone would pass the test above.
//
//	A GUARD THAT BLOCKS EVERYTHING IS NOT A GUARD.
func TestEnabledModuleStillStarts(t *testing.T) {
	m := gateModule(true)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	if err := m.Start(ctx); err != nil {
		t.Fatalf("Start() on an enabled module must succeed, got %v", err)
	}
	defer func() { _ = m.Stop() }()

	if !m.status.Running {
		t.Error("enabled module did not mark itself Running — the gate blocks the live path")
	}
	if m.cancel == nil {
		t.Error("enabled module has no cancel func — Start did not reach its live path")
	}
}

// Stop() on a disabled module is a no-op.
//
//	SERVICE RESTART MUST NOT CHANGE MODULE CONFIGURATION.
func TestStopOnDisabledModuleIsNoop(t *testing.T) {
	m := gateModule(false)

	if err := m.Stop(); err != nil {
		t.Fatalf("Stop() on a disabled module must return nil, got %v", err)
	}
	if !m.config.Enabled == false {
		t.Error("Stop() altered durable module configuration")
	}
}

// DEFENCE IN DEPTH: the ban path is the last point before an enforcement action
// leaves the module, so it must refuse when disabled even if reached directly --
// an in-flight detection after a reload flipped Enabled, a future caller, or a
// test harness.
//
//	THE GATE THAT MATTERS MOST IS THE ONE CLOSEST TO THE EFFECT.
//
// This asserts the gate EXISTS and returns before doing work. It is deliberately
// not a substitute for TestDisabledModuleDoesNotStart: a module that should not
// run must not run, not merely decline to act.
func TestDisabledModuleDoesNotBan(t *testing.T) {
	m := gateModule(false)

	// triggerBan publishes to the event bus on its live path. A disabled module
	// must return before any of that, so the call must be inert rather than
	// panicking on the uninitialised collaborators a stopped module has.
	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("triggerBan on a disabled module reached its live path and panicked: %v", r)
		}
	}()

	m.triggerBan(nil) // nil action: only reachable safely if the gate returns first
}

// NEGATIVE CONTROL. If triggerBan did NOT gate, the nil action above would reach
// the live path and fault. This asserts the control is meaningful by proving the
// enabled module genuinely dereferences the action.
//
//	A NEGATIVE CONTROL MUST HIT THE MOTIVATING DEFECT.
func TestBanGateNegativeControl(t *testing.T) {
	m := gateModule(true)

	reached := false
	defer func() {
		if r := recover(); r != nil {
			reached = true
		}
		if !reached {
			t.Error("enabled triggerBan(nil) did not reach the live path — the gate test proves nothing")
		}
	}()

	m.triggerBan(nil)
}
