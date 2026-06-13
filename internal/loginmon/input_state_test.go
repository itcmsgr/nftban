// =============================================================================
// NFTBan v1.182.0 - LoginMon input-state observability tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
//
// meta:name="loginmon_input_state_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-13"
// meta:description="Tests for v1.182 HEALTH-NO-INPUT-AXIS LoginMon input-state observability: recordInputState/inputStateSnapshot round-trip, that the captured per-source state (OK/WARN_NO_LOGS/NO_LOGS) is surfaced through Status().Extra.InputSources and ToExtraInfo, and that the wire format stays byte-equivalent (no input_sources key) when nothing was captured. The daemon (root nftband.service) is the authority on its own watcher input-state; the kernel-truth validator cannot see watcher starvation, so this is the daemon-side observability foundation for the global health input axis."
//
// meta:inventory.files="input_state_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package loginmon

import "testing"

func TestRecordInputState_Snapshot(t *testing.T) {
	m := New()
	if snap := m.inputStateSnapshot(); snap != nil {
		t.Fatalf("fresh module should have nil input-state snapshot, got %v", snap)
	}
	m.recordInputState("webauth", inputStateOK)
	m.recordInputState("ftpauth", inputStateWarnNoLogs)
	m.recordInputState("webauth", inputStateNoLogs) // overwrite

	snap := m.inputStateSnapshot()
	if snap["webauth"] != inputStateNoLogs {
		t.Errorf("webauth=%q want %q (overwrite)", snap["webauth"], inputStateNoLogs)
	}
	if snap["ftpauth"] != inputStateWarnNoLogs {
		t.Errorf("ftpauth=%q want %q", snap["ftpauth"], inputStateWarnNoLogs)
	}
	// snapshot must be a copy — mutating it must not affect the module
	snap["webauth"] = "TAMPER"
	if m.inputStateSnapshot()["webauth"] != inputStateNoLogs {
		t.Errorf("snapshot must be a defensive copy")
	}
}

func TestStatusExposesInputSources(t *testing.T) {
	m := New()
	m.recordInputState("ftpauth", inputStateWarnNoLogs)

	st := m.Status()
	v, ok := st.Extra["input_sources"]
	if !ok {
		t.Fatalf("Status().Extra missing input_sources after capture")
	}
	srcs, ok := v.(map[string]string)
	if !ok {
		t.Fatalf("input_sources wrong type %T", v)
	}
	if srcs["ftpauth"] != inputStateWarnNoLogs {
		t.Errorf("input_sources[ftpauth]=%q want %q", srcs["ftpauth"], inputStateWarnNoLogs)
	}
}

// TestStatusInputSourcesOmittedWhenEmpty pins the byte-equivalence guarantee: with
// no captured input-state, the status extra must NOT carry an input_sources key.
func TestStatusInputSourcesOmittedWhenEmpty(t *testing.T) {
	m := New()
	st := m.Status()
	if _, ok := st.Extra["input_sources"]; ok {
		t.Errorf("input_sources must be omitted when no input-state is captured")
	}
}
