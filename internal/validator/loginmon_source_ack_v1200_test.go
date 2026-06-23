// =============================================================================
// NFTBan v1.200 - LoginMon source-visibility: ack/suppress + per-reason remediation
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="loginmon_source_ack_v1200_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-23"
// meta:description="v1.200 (VAL-LOGINMON-002 R2): a starved LoginMon source (WARN_NO_LOGS) carries EXACT per-source remediation text and stays WARN unless the operator acks it via LOGINMON_SOURCE_ACK in conf.d/login/main.conf(.local); an acked source becomes INFO but stays VISIBLE (message says operator-acked) — never silently hidden; an absent source stays INFO; a malformed/other-source ack does not hide an unacked starved source. Schema-frozen; validator-only."
// meta:input="setupTestConfig (temp ConfigDir + login_alert/login configs) + mockJournalReader ([LOGINMON] <src>: state=...) → evaluateLoginMon → moduleFindings"
// meta:output="t.Error on wrong severity / missing remediation / silent hide / leaked ack"
// meta:depends="testing,strings"
// meta:inventory.files="internal/validator/module_health.go,etc/nftban/conf.d/login/main.conf"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="conf.d/login/main.conf,conf.d/login_alert.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package validator

import (
	"strings"
	"testing"
)

const rcStarvedLine = "Jun 13 nftband[1]: 2026/06/13 [LOGINMON] roundcube: state=WARN_NO_LOGS resolved_by=discovery files=0 reason=roundcube_present_no_login_logs"
const modStartLine = "Jun 13 nftband[1]: 2026/06/13 module_start: loginmon"

// helper: run evaluateLoginMon with login enabled + the given ack value + a starved roundcube
func runLoginMonWithAck(t *testing.T, ack string) {
	t.Helper()
	files := map[string]string{"conf.d/login_alert.conf.local": `NFTBAN_LOGIN_ALERT_ENABLED="true"`}
	if ack != "__none__" {
		files["conf.d/login/main.conf"] = "LOGINMON_SOURCE_ACK=\"" + ack + "\"\n"
	}
	cleanup := setupTestConfig(t, files)
	defer cleanup()
	SetJournalReader(mockJournalReader{lines: []string{rcStarvedLine, modStartLine}})
	defer SetJournalReader(SystemdJournalReader{})
	moduleFindings = nil
	evaluateLoginMon(ServiceState{Nftband: RuntimeRunning})
}

// Unacked starved source → WARN with the EXACT remediation (names log_logins for roundcube).
func TestLoginMonAck_UnackedStarvedWarnWithRemediation(t *testing.T) {
	runLoginMonWithAck(t, "__none__")
	f := loginMonInputFinding("roundcube")
	if f.Severity != SeverityWarn {
		t.Errorf("unacked starved roundcube severity=%q want WARN (actionable)", f.Severity)
	}
	if !strings.Contains(f.Remediation, "log_logins") {
		t.Errorf("roundcube remediation must name the exact fix (log_logins); got %q", f.Remediation)
	}
	if !strings.Contains(f.Remediation, "LOGINMON_SOURCE_ACK") {
		t.Error("remediation should also point at the ack knob for starved-by-design hosts")
	}
}

// Operator-acked starved source → INFO but VISIBLE (message says operator-acked).
func TestLoginMonAck_AckedStarvedBecomesInfoButVisible(t *testing.T) {
	runLoginMonWithAck(t, "roundcube")
	f := loginMonInputFinding("roundcube")
	if f.Severity != SeverityInfo {
		t.Errorf("acked starved roundcube severity=%q want INFO", f.Severity)
	}
	if !strings.Contains(f.Message, "operator-acked") {
		t.Errorf("acked finding must remain VISIBLE and say operator-acked; got %q", f.Message)
	}
	if f.Code != CodeLoginMonNoInput {
		t.Errorf("acked finding code=%q want %q (still emitted, not hidden)", f.Code, CodeLoginMonNoInput)
	}
}

// Ack lists OTHER/unknown sources → roundcube NOT acked → stays WARN (no silent hide).
func TestLoginMonAck_OtherSourceAckDoesNotHideRoundcube(t *testing.T) {
	runLoginMonWithAck(t, "webauth bogus")
	f := loginMonInputFinding("roundcube")
	if f.Severity != SeverityWarn {
		t.Errorf("roundcube not in ack list but severity=%q want WARN (must not be hidden)", f.Severity)
	}
}

// Empty/whitespace ack → nothing acked → roundcube stays WARN.
func TestLoginMonAck_EmptyAckSafe(t *testing.T) {
	runLoginMonWithAck(t, "   ")
	f := loginMonInputFinding("roundcube")
	if f.Severity != SeverityWarn {
		t.Errorf("empty ack must leave roundcube WARN; got %q", f.Severity)
	}
}

// Case-insensitive ack matching (operator may type RoundCube).
func TestLoginMonAck_CaseInsensitive(t *testing.T) {
	runLoginMonWithAck(t, "RoundCube")
	if got := loginMonInputFinding("roundcube").Severity; got != SeverityInfo {
		t.Errorf("case-insensitive ack: severity=%q want INFO", got)
	}
}

// Per-source remediation text is source-specific.
func TestLoginMonRemediation_SourceSpecific(t *testing.T) {
	if !strings.Contains(loginMonRemediation("roundcube"), "log_logins") {
		t.Error("roundcube remediation must name log_logins")
	}
	if !strings.Contains(loginMonRemediation("ftpauth"), "FTP") {
		t.Error("ftpauth remediation must mention the FTP auth log")
	}
	if !strings.Contains(loginMonRemediation("webauth"), "web") {
		t.Error("webauth remediation must mention the web auth log")
	}
	if !strings.Contains(loginMonRemediation("somethingelse"), "LOGINMON_SOURCE_ACK") {
		t.Error("default remediation must still point at the ack knob")
	}
}
