// =============================================================================
// NFTBan v1.181.0 - LoginMon source-ownership / duplicate-source guard
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
//
// meta:name="loginmon_source_ownership_guard_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-13"
// meta:description="Source-ownership guard (v1.181): fails CI if a future change wires a known DUPLICATE/non-auth log source into the LoginMon ban path without a fresh LOG_SOURCE_OWNERSHIP_DECLARATION + non-duplicate proof. Real-production sampling in v1.180 proved that (a) cphulkd /usr/local/cpanel/logs/login_log duplicates the cPanel access_log-401 events the PanelDetector already bans, and (b) the exim rejectlog auth subset duplicates exim mainlog (already owned by the MailDetector) while its unique lines are spam/RBL/HELO rejects (web_abuse, NOT auth_failure). Adding either as a ban source would recreate the v1.179 mirror double-count class and, for rejectlog, ban legitimate mail senders. This guard asserts panelLogPaths / mailLogPaths / the FTP file globs / the journal facilities stay free of those sources. Scope: NFTBAN_ROADMAP/V1_181_AUTH_SOURCE_DEAD_KEY_AND_DUPLICATE_GUARD_SCOPE.md."
//
// meta:inventory.files="source_ownership_guard_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package loginmon

import (
	"strings"
	"testing"
)

// declRef is the remediation pointer printed when the guard trips.
const declRef = "requires a LOG_SOURCE_OWNERSHIP_DECLARATION + non-duplicate proof " +
	"(NFTBAN_ROADMAP/V1_181_AUTH_SOURCE_DEAD_KEY_AND_DUPLICATE_GUARD_SCOPE.md)"

// TestSourceOwnershipGuard_NoCphulkdLoginLog asserts cphulkd's login_log is not wired as a
// panel ban source: cPanel WHM/cPanel login failures are already owned by the PanelDetector
// via access_log 401 on POST /login/ (v1.180 real-prod proof: a sample host login_log = whostmgrd/
// cpaneld only). Adding login_log double-counts the same events.
func TestSourceOwnershipGuard_NoCphulkdLoginLog(t *testing.T) {
	for svc, paths := range panelLogPaths {
		for _, p := range paths {
			if strings.Contains(p, "login_log") {
				t.Errorf("panelLogPaths[%q] wires a cphulkd-style login_log source (%q): "+
					"cPanel login failures are already banned via access_log 401 (PanelDetector); "+
					"login_log duplicates them. %s", svc, p, declRef)
			}
		}
	}
}

// TestSourceOwnershipGuard_NoEximRejectlog asserts exim rejectlog is not wired as a mail ban
// source: its auth subset (535 Incorrect authentication data) is already in exim mainlog
// (owned by the MailDetector), and its UNIQUE lines are spam/RBL/HELO rejects = web_abuse,
// not auth_failure. Banning those = false positives on legitimate mail.
func TestSourceOwnershipGuard_NoEximRejectlog(t *testing.T) {
	for svc, paths := range mailLogPaths {
		for _, p := range paths {
			if strings.Contains(p, "rejectlog") || strings.Contains(p, "reject_log") {
				t.Errorf("mailLogPaths[%q] wires an exim rejectlog source (%q): the auth subset "+
					"already lives in exim mainlog (MailDetector) and the unique lines are "+
					"spam/RBL/HELO (web_abuse, not auth). %s", svc, p, declRef)
			}
		}
	}
}

// TestSourceOwnershipGuard_FTPGlobsNoPureFTPdOrReject asserts the FTP FILE globs never include
// pure-ftpd (journal-routed at facility 11 since v1.180 — globbing its stats-only file would
// add a no-auth source and risk double-counting) nor any rejectlog.
func TestSourceOwnershipGuard_FTPGlobsNoPureFTPdOrReject(t *testing.T) {
	m := &Module{detectedServices: map[string]bool{
		"pure-ftpd": true, "vsftpd": true, "proftpd": true,
	}}
	for _, g := range m.ftpLogGlobs() {
		if strings.Contains(g, "pureftpd") || strings.Contains(g, "pure-ftpd") {
			t.Errorf("ftpLogGlobs includes a pure-ftpd file glob (%q): pure-ftpd is journal-routed "+
				"(SYSLOG_FACILITY=11) and its dedicated file is stats-only; globbing it double-counts. %s",
				g, declRef)
		}
		if strings.Contains(g, "rejectlog") || strings.Contains(g, "reject_log") {
			t.Errorf("ftpLogGlobs includes a rejectlog source (%q) — not an FTP auth source. %s", g, declRef)
		}
	}
}

// TestSourceOwnershipGuard_JournalFacilities pins the journal facility set the watcher
// consumes. Any change feeds new input to the detector registry and must come with a
// LOG_SOURCE_OWNERSHIP_DECLARATION. Expected: auth(4), authpriv(10), ftp(11, v1.180).
func TestSourceOwnershipGuard_JournalFacilities(t *testing.T) {
	want := map[string]bool{"4": true, "10": true, "11": true}
	if len(journalAuthFacilities) != len(want) {
		t.Fatalf("journalAuthFacilities=%v, want exactly %v — a change here %s",
			journalAuthFacilities, []string{"4", "10", "11"}, declRef)
	}
	for _, f := range journalAuthFacilities {
		if !want[f] {
			t.Errorf("unexpected journal facility %q wired into LoginMon — %s", f, declRef)
		}
	}
}
