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

import (
	"strings"
	"testing"
)

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

func TestParseLoginMonReason(t *testing.T) {
	cases := map[string]string{
		"[LOGINMON] webauth: state=WARN_NO_LOGS resolved_by=discovery files=0 reason=web_stack_present_no_access_logs": "web_stack_present_no_access_logs",
		"[LOGINMON] roundcube: state=NO_LOGS resolved_by=discovery files=0 reason=no_roundcube":                        "no_roundcube",
		"[LOGINMON] webauth: state=OK resolved_by=discovery files=3":                                                   "", // no reason token
		"no marker here": "",
	}
	for line, want := range cases {
		if got := parseLoginMonReason(line); got != want {
			t.Errorf("parseLoginMonReason(%q)=%q want %q", line, got, want)
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

// loginMonInputFinding returns the CodeLoginMonNoInput finding whose message names
// the given source, or a zero Finding if none.
func loginMonInputFinding(source string) Finding {
	for _, f := range moduleFindings {
		if f.Code == CodeLoginMonNoInput && strings.Contains(f.Message, source) {
			return f
		}
	}
	return Finding{}
}

// TestLoginMonInputAxis_BenignAbsent: VAL-LOGINMON-002-UX. webauth NO_LOGS with
// reason=no_web_stack means the web stack is simply not present on this host. That
// is benign — it must surface as INFO (not a warning) and preserve the reason so an
// operator can see "not installed here", not "installed but unreadable".
func TestLoginMonInputAxis_BenignAbsent(t *testing.T) {
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/login_alert.conf.local": `NFTBAN_LOGIN_ALERT_ENABLED="true"`,
	})
	defer cleanup()

	SetJournalReader(mockJournalReader{lines: []string{
		"Jun 13 nftband[1]: 2026/06/13 [LOGINMON] webauth: state=NO_LOGS resolved_by=discovery files=0 reason=no_web_stack",
		"Jun 13 nftband[1]: 2026/06/13 module_start: loginmon",
	}})
	defer SetJournalReader(SystemdJournalReader{})

	moduleFindings = nil
	h := evaluateLoginMon(ServiceState{Nftband: RuntimeRunning})
	if h.Input != InputNoLogs {
		t.Fatalf("Input=%q want %q", h.Input, InputNoLogs)
	}
	f := loginMonInputFinding("webauth")
	if f.Code != CodeLoginMonNoInput {
		t.Fatal("expected a CodeLoginMonNoInput finding naming webauth")
	}
	if f.Severity != SeverityInfo {
		t.Errorf("benign-absent webauth severity=%q want %q (must not warn)", f.Severity, SeverityInfo)
	}
	if !strings.Contains(f.Message, "no_web_stack") {
		t.Errorf("finding must preserve reason; message=%q", f.Message)
	}
}

// TestLoginMonInputAxis_NoRoundcubeBenign: no Roundcube present → INFO, not a warning.
func TestLoginMonInputAxis_NoRoundcubeBenign(t *testing.T) {
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/login_alert.conf.local": `NFTBAN_LOGIN_ALERT_ENABLED="true"`,
	})
	defer cleanup()

	SetJournalReader(mockJournalReader{lines: []string{
		"Jun 13 nftband[1]: 2026/06/13 [LOGINMON] roundcube: state=NO_LOGS resolved_by=discovery files=0 reason=no_roundcube",
	}})
	defer SetJournalReader(SystemdJournalReader{})

	moduleFindings = nil
	_ = evaluateLoginMon(ServiceState{Nftband: RuntimeRunning})
	f := loginMonInputFinding("roundcube")
	if f.Severity != SeverityInfo {
		t.Errorf("no-Roundcube severity=%q want %q (benign)", f.Severity, SeverityInfo)
	}
}

// TestLoginMonInputAxis_Starved: webauth WARN_NO_LOGS reason=web_stack_present_no_access_logs
// means the stack IS present but NFTBan sees no readable logs. That is actionable and
// must stay WARN, with the source + reason preserved.
func TestLoginMonInputAxis_Starved(t *testing.T) {
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/login_alert.conf.local": `NFTBAN_LOGIN_ALERT_ENABLED="true"`,
	})
	defer cleanup()

	SetJournalReader(mockJournalReader{lines: []string{
		"Jun 13 nftband[1]: 2026/06/13 [LOGINMON] webauth: state=WARN_NO_LOGS resolved_by=discovery files=0 reason=web_stack_present_no_access_logs",
		"Jun 13 nftband[1]: 2026/06/13 module_start: loginmon",
	}})
	defer SetJournalReader(SystemdJournalReader{})

	moduleFindings = nil
	h := evaluateLoginMon(ServiceState{Nftband: RuntimeRunning})
	if h.Input != InputWarnNoLogs {
		t.Fatalf("Input=%q want %q", h.Input, InputWarnNoLogs)
	}
	f := loginMonInputFinding("webauth")
	if f.Code != CodeLoginMonNoInput {
		t.Fatal("expected a CodeLoginMonNoInput finding naming webauth")
	}
	if f.Severity != SeverityWarn {
		t.Errorf("starved webauth severity=%q want %q (actionable)", f.Severity, SeverityWarn)
	}
	if !strings.Contains(f.Message, "web_stack_present_no_access_logs") {
		t.Errorf("finding must preserve reason; message=%q", f.Message)
	}
}

// TestLoginMonInputAxis_MixedSources: a starved webauth (WARN) and an absent roundcube
// (INFO) must each emit their own correctly-classified finding — proving classification
// is per-source and not collapsed to one worst-of message.
func TestLoginMonInputAxis_MixedSources(t *testing.T) {
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/login_alert.conf.local": `NFTBAN_LOGIN_ALERT_ENABLED="true"`,
	})
	defer cleanup()

	SetJournalReader(mockJournalReader{lines: []string{
		"Jun 13 nftband[1]: 2026/06/13 [LOGINMON] webauth: state=WARN_NO_LOGS resolved_by=discovery files=0 reason=web_stack_present_no_access_logs",
		"Jun 13 nftband[1]: 2026/06/13 [LOGINMON] roundcube: state=NO_LOGS resolved_by=discovery files=0 reason=no_roundcube",
	}})
	defer SetJournalReader(SystemdJournalReader{})

	moduleFindings = nil
	_ = evaluateLoginMon(ServiceState{Nftband: RuntimeRunning})
	if got := loginMonInputFinding("webauth").Severity; got != SeverityWarn {
		t.Errorf("webauth (starved) severity=%q want warn", got)
	}
	if got := loginMonInputFinding("roundcube").Severity; got != SeverityInfo {
		t.Errorf("roundcube (absent) severity=%q want info", got)
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
