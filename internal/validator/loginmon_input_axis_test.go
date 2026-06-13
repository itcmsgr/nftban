// =============================================================================
// NFTBan v1.183.0 - Validator LoginMon Input-axis tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
//
// meta:name="validator_loginmon_input_axis_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-13"
// meta:description="Tests for v1.183 HEALTH-NO-INPUT-AXIS increment 2: the validator derives an internal LoginMon input-readability state from the daemon's '[LOGINMON] <src>: state=...' journal lines (parseLoginMonState/worseInputState/loginMonInputState). An enabled-but-starved source (WARN_NO_LOGS/NO_LOGS) emits a CodeLoginMonNoInput finding so it is visible in nftban health instead of reading healthy; worst-of precedence across sources. The frozen M81-6 health-output schema is NOT extended (Input stays internal json:- ; a first-class JSON axis awaits SCHEMA-UNFREEZE)."
//
// meta:inventory.files="loginmon_input_axis_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package validator

import "testing"

func TestParseLoginMonState(t *testing.T) {
	cases := map[string]InputState{
		"2026/06/13 [LOGINMON] webauth: state=OK resolved_by=discovery files=2":                    InputOK,
		"2026/06/13 [LOGINMON] webauth: state=WARN_NO_LOGS resolved_by=discovery files=0 reason=x": InputWarnNoLogs,
		"2026/06/13 [LOGINMON] ftpauth: state=NO_LOGS resolved_by=discovery files=0 reason=y":      InputNoLogs,
		"2026/06/13 [LOGINMON] ftpauth: state=BOGUS":                                               InputUnknown,
		"no marker here": InputUnknown,
	}
	for line, want := range cases {
		if got := parseLoginMonState(line); got != want {
			t.Errorf("parseLoginMonState(%q)=%q want %q", line, got, want)
		}
	}
}

func TestWorseInputState(t *testing.T) {
	if worseInputState(InputOK, InputNoLogs) != InputNoLogs {
		t.Error("no_logs must beat ok")
	}
	if worseInputState(InputWarnNoLogs, InputOK) != InputWarnNoLogs {
		t.Error("warn_no_logs must beat ok")
	}
	if worseInputState(InputNoLogs, InputWarnNoLogs) != InputNoLogs {
		t.Error("no_logs must beat warn_no_logs")
	}
	if worseInputState(InputUnknown, InputOK) != InputOK {
		t.Error("ok must beat unknown")
	}
}

// TestLoginMonInputAxis_Starved drives evaluateLoginMon with an enabled config + a
// journal that reports webauth NO_LOGS → Input axis = no_logs + a CodeLoginMonNoInput
// finding (enabled-but-starved is now visible, not healthy).
func TestLoginMonInputAxis_Starved(t *testing.T) {
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/login_alert.conf.local": `NFTBAN_LOGIN_ALERT_ENABLED="true"`,
	})
	defer cleanup()

	SetJournalReader(mockJournalReader{lines: []string{
		"Jun 13 nftband[1]: 2026/06/13 [LOGINMON] webauth: state=NO_LOGS resolved_by=discovery files=0 reason=no_web_stack",
		"Jun 13 nftband[1]: 2026/06/13 module_start: loginmon",
		"Jun 13 nftband[1]: 2026/06/13 [LOGINMON] exim: maillog=/var/log/exim/mainlog resolved_by=distroconf",
	}})
	defer SetJournalReader(SystemdJournalReader{})

	moduleFindings = nil
	h := evaluateLoginMon(ServiceState{Nftband: RuntimeRunning})
	if h.Input != InputNoLogs {
		t.Fatalf("Input=%q want %q", h.Input, InputNoLogs)
	}
	found := false
	for _, f := range moduleFindings {
		if f.Code == CodeLoginMonNoInput {
			found = true
		}
	}
	if !found {
		t.Errorf("expected a CodeLoginMonNoInput finding for an enabled-but-starved source")
	}
}

// TestLoginMonInputAxis_OK: a healthy webauth source → Input=ok, no starvation finding.
func TestLoginMonInputAxis_OK(t *testing.T) {
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/login_alert.conf.local": `NFTBAN_LOGIN_ALERT_ENABLED="true"`,
	})
	defer cleanup()

	SetJournalReader(mockJournalReader{lines: []string{
		"Jun 13 nftband[1]: 2026/06/13 [LOGINMON] webauth: state=OK resolved_by=discovery files=3",
		"Jun 13 nftband[1]: 2026/06/13 module_start: loginmon",
		"Jun 13 nftband[1]: 2026/06/13 [LOGINMON] exim: resolved_by=distroconf",
	}})
	defer SetJournalReader(SystemdJournalReader{})

	moduleFindings = nil
	h := evaluateLoginMon(ServiceState{Nftband: RuntimeRunning})
	if h.Input != InputOK {
		t.Fatalf("Input=%q want %q", h.Input, InputOK)
	}
	for _, f := range moduleFindings {
		if f.Code == CodeLoginMonNoInput {
			t.Errorf("did not expect a starvation finding when input is OK")
		}
	}
}
