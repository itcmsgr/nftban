// =============================================================================
// NFTBan v1.216.2 - LoginMon Source-Binding Heartbeat Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="loginmon_heartbeat_test"
// meta:type="test"
// meta:version="1.216.2"
// meta:owner="NFTBan Project / Antonios Voulvoulis"
// meta:description="Producer-side guarantees for the v1.216.2 LoginMon source-binding heartbeat: bound line carries registration marker + resolved_by=, unbound (sources=0) omits resolved_by= so genuine-unbound stays flagged, interval below the validator 15m journal window, and no secrets leak."
// meta:inventory.files="internal/loginmon/heartbeat_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package loginmon

import (
	"strings"
	"testing"
	"time"
)

// v1.216.2 health-truth hotfix — producer-side guarantees for the source-binding
// heartbeat that keeps VAL-LOGINMON-001 honest on quiet, long-running hosts.

// A bound heartbeat (sources>0) must carry the registration marker AND resolved_by= so
// the validator's registration + binding evidence both refresh from one line.
func TestBindingHeartbeatLineBound(t *testing.T) {
	line := bindingHeartbeatLine(3)
	for _, want := range []string{"loginmon_source_binding_heartbeat", "resolved_by=", "sources=3", "state=running"} {
		if !strings.Contains(line, want) {
			t.Errorf("bound heartbeat missing %q: %q", want, line)
		}
	}
}

// An unbound heartbeat (sources=0) must include the marker but NOT resolved_by=, so a
// genuinely running-but-unbound module still trips the validator's binding AND-condition.
func TestBindingHeartbeatLineUnbound(t *testing.T) {
	line := bindingHeartbeatLine(0)
	if !strings.Contains(line, "loginmon_source_binding_heartbeat") {
		t.Errorf("unbound heartbeat missing registration marker: %q", line)
	}
	if strings.Contains(line, "resolved_by=") {
		t.Errorf("unbound heartbeat (sources=0) must NOT carry resolved_by=: %q", line)
	}
	if !strings.Contains(line, "sources=0") {
		t.Errorf("unbound heartbeat missing sources=0: %q", line)
	}
}

// The heartbeat must fire well inside the validator's bounded journal window (15m,
// internal/validator/journal.go) — otherwise the evidence ages out and the false INFO
// returns. This guards against future interval drift.
func TestBindingHeartbeatIntervalBelowJournalWindow(t *testing.T) {
	const journalWindow = 15 * time.Minute
	if bindingHeartbeatInterval >= journalWindow {
		t.Fatalf("heartbeat interval %s must be < validator journal window %s", bindingHeartbeatInterval, journalWindow)
	}
}

// The heartbeat must never leak secrets — only a source count and state vocabulary.
func TestBindingHeartbeatLineNoSecrets(t *testing.T) {
	for _, n := range []int{0, 1, 9} {
		line := strings.ToLower(bindingHeartbeatLine(n))
		for _, bad := range []string{"password", "passwd", "token", "secret", "smtp_pass", "key="} {
			if strings.Contains(line, bad) {
				t.Errorf("heartbeat line leaks %q: %q", bad, bindingHeartbeatLine(n))
			}
		}
	}
}
