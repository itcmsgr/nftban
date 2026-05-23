// SPDX-License-Identifier: MPL-2.0
// =============================================================================
// V127 UX-3 item 2.4 — LogTempBan BLC-1 BEHAVIORAL (runtime) regression test
// =============================================================================
// meta:name="tracker-blc1-behavioral-test"
// meta:type="test"
// meta:version="1.127.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-24"
// meta:description="V127 UX-3 item 2.4 RUNTIME regression guard. Complements tracker_blc1_test.go (static source-file inspection) by actually invoking escalation.LogTempBan and banlog.LogResync at runtime, redirecting banlog output to a temp file via nftbanconf.DefaultConfigFile override, then asserting the emitted row is canonical 10-field BLC-1 pipe format (DATE|TIME|SOURCE|IP|COUNTRY|STATUS|REASON|BAN_ID|TIMEOUT|CLASS). Proves the A1 facade convergence holds end-to-end and that the pre-V127 space-delimited writer cannot reappear via runtime divergence. Test seam: nftbanconf.DefaultConfigFile is a pre-existing exported package var; we set it to a temp nftban.conf containing NFTBAN_LOG_DIR=<t.TempDir()> BEFORE any Load() call triggers, so banlog.getBanLogPath() routes writes to <temp>/bans.log."
// meta:input="temp config file + temp log dir"
// meta:output="t.Fatal on regression; written bans.log lines parsed and asserted"
// meta:depends="testing,os,path/filepath,strings,nftbanconf,banlog"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// Scope: AUDIT_190_LIFECYCLE/V127_FULL_UX_CORRECTION_UMBRELLA_SCOPE.md (UX-3 lane)
// =============================================================================
package escalation

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/banlog"
	"github.com/itcmsgr/nftban/internal/nftbanconf"
)

// blc1TestState carries the temp dir + bans.log path set up by TestMain so
// the behavioral tests below can read the file banlog actually wrote to.
var (
	blc1TestBansLog string
	blc1TestTempDir string
)

// TestMain configures nftbanconf to read a temp config that points
// NFTBAN_LOG_DIR at a t.TempDir-style temp directory, BEFORE any banlog
// call triggers nftbanconf.Load() (singleton sync.Once). This is the
// least-invasive runtime seam — it uses the existing exported
// nftbanconf.DefaultConfigFile package variable; no production code is
// changed.
//
// Without this TestMain, the first banlog write in this package would
// resolve bans.log under /var/log/nftban/ which is (a) not writable in
// CI/dev and (b) not isolated from real host state.
//
// This TestMain applies to ALL tests in internal/escalation. The other
// tests in this package (config_test.go) do not call nftbanconf.Load()
// so the override is benign for them.
func TestMain(m *testing.M) {
	tmpDir, err := os.MkdirTemp("", "nftban-v127-ux3-blc1-*")
	if err != nil {
		panic("v127 ux-3 behavioral test: failed to create temp dir: " + err.Error())
	}
	defer os.RemoveAll(tmpDir)

	confPath := filepath.Join(tmpDir, "nftban.conf")
	confBody := "NFTBAN_LOG_DIR=" + tmpDir + "\n"
	if err := os.WriteFile(confPath, []byte(confBody), 0644); err != nil {
		panic("v127 ux-3 behavioral test: failed to write temp nftban.conf: " + err.Error())
	}

	nftbanconf.DefaultConfigFile = confPath
	blc1TestTempDir = tmpDir
	blc1TestBansLog = filepath.Join(tmpDir, "bans.log")

	code := m.Run()
	os.Exit(code)
}

// TestLogTempBan_EmitsBLC1 invokes LogTempBan at runtime and asserts the
// row actually appended to bans.log is canonical BLC-1 (10 pipe fields)
// with STATUS=BANNED, normalized SOURCE, preserved IP, and class=temp.
// This is the load-bearing regression check: a future caller-side or
// internals-side rewrite that re-introduces the legacy "%s %s %s %s\n"
// writer would fail this test even if the static guard somehow missed it.
func TestLogTempBan_EmitsBLC1(t *testing.T) {
	// Reset bans.log so this test sees only its own emission.
	_ = os.Remove(blc1TestBansLog)

	const (
		testIP     = "203.0.113.42"
		testJail   = "nftban-sshd" // normalized -> "login" by banlog.normalizeSource
		testReason = "SSH brute force"
	)
	// LogTempBan's logPath parameter is intentionally unused post-V127;
	// the canonical path comes from nftbanconf paths. Pass a sentinel
	// to make sure that ignoring it is intentional and survives refactors.
	if err := LogTempBan("/dev/null/IGNORED-BY-FACADE", testIP, testJail, testReason); err != nil {
		t.Fatalf("LogTempBan returned error: %v", err)
	}

	data, err := os.ReadFile(blc1TestBansLog)
	if err != nil {
		t.Fatalf("could not read bans.log written by LogTempBan: %v (path=%s)", err, blc1TestBansLog)
	}
	lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	if len(lines) != 1 {
		t.Fatalf("expected exactly 1 line in bans.log after one LogTempBan call, got %d: %q", len(lines), string(data))
	}
	line := lines[0]

	// (1) Must be 10 pipe-delimited BLC-1 fields.
	fields := strings.Split(line, "|")
	if len(fields) != 10 {
		t.Fatalf("BLC-1 violation: expected 10 pipe-delimited fields, got %d in line %q", len(fields), line)
	}

	// (2) Field 3 (SOURCE) must be normalized from "nftban-sshd" -> banlog.SourceLogin.
	if fields[2] != banlog.SourceLogin {
		t.Errorf("SOURCE field = %q, want %q (banlog.normalizeSource(\"nftban-sshd\") -> SourceLogin)", fields[2], banlog.SourceLogin)
	}

	// (3) Field 4 (IP) must be preserved verbatim.
	if fields[3] != testIP {
		t.Errorf("IP field = %q, want %q", fields[3], testIP)
	}

	// (4) Field 6 (STATUS) must be BANNED — LogTempBan is a real-ban-emit facade.
	if fields[5] != banlog.StatusBanned {
		t.Errorf("STATUS field = %q, want %q", fields[5], banlog.StatusBanned)
	}

	// (5) Field 7 (REASON) must be preserved.
	if fields[6] != testReason {
		t.Errorf("REASON field = %q, want %q", fields[6], testReason)
	}

	// (6) Field 10 (CLASS) must be "temp" — LogTempBan is named for the temp class.
	if fields[9] != banlog.ClassTemp {
		t.Errorf("CLASS field = %q, want %q", fields[9], banlog.ClassTemp)
	}

	// (7) Legacy space-delimited pattern absent. The pre-V127 writer
	// produced "<RFC3339> <ip> <jail> <reason>" with NO pipes and a 'T'
	// in the first timestamp token. BLC-1 splits date and time across
	// two pipe fields, so field 1 must NEVER contain 'T'.
	if strings.Contains(fields[0], "T") {
		t.Errorf("LEGACY FORMAT REGRESSION: first field looks like RFC3339 (contains 'T') — BLC-1 uses date|time split: %q", fields[0])
	}
}

// TestLogResync_EmitsBLC1 verifies the V127 UX-3 item 2.5 RESYNC marker
// reaches bans.log as a 10-field BLC-1 row with STATUS=RESYNC and
// CLASS=resync — proving operators can grep RESYNC events out of bans.log
// to distinguish idempotent re-syncs from real new bans.
func TestLogResync_EmitsBLC1(t *testing.T) {
	// Reset bans.log so this test sees only its own emission.
	_ = os.Remove(blc1TestBansLog)

	const (
		testIP      = "198.51.100.7"
		testSource  = "manual"
		testCountry = "GR"
		testReason  = "already-banned re-sync"
	)
	if err := banlog.LogResync(testIP, testSource, testCountry, testReason); err != nil {
		t.Fatalf("banlog.LogResync returned error: %v", err)
	}

	data, err := os.ReadFile(blc1TestBansLog)
	if err != nil {
		t.Fatalf("could not read bans.log written by LogResync: %v (path=%s)", err, blc1TestBansLog)
	}
	lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	if len(lines) != 1 {
		t.Fatalf("expected exactly 1 line in bans.log after one LogResync call, got %d: %q", len(lines), string(data))
	}
	line := lines[0]

	fields := strings.Split(line, "|")
	if len(fields) != 10 {
		t.Fatalf("BLC-1 violation: expected 10 pipe-delimited fields, got %d in line %q", len(fields), line)
	}

	if fields[2] != banlog.SourceManual {
		t.Errorf("SOURCE field = %q, want %q (normalized from \"manual\")", fields[2], banlog.SourceManual)
	}
	if fields[3] != testIP {
		t.Errorf("IP field = %q, want %q", fields[3], testIP)
	}
	if fields[4] != testCountry {
		t.Errorf("COUNTRY field = %q, want %q", fields[4], testCountry)
	}
	if fields[5] != banlog.StatusResync {
		t.Errorf("STATUS field = %q, want %q (V127 UX-3 item 2.5 RESYNC marker missing at runtime)", fields[5], banlog.StatusResync)
	}
	if fields[6] != testReason {
		t.Errorf("REASON field = %q, want %q", fields[6], testReason)
	}
	if fields[9] != banlog.ClassResync {
		t.Errorf("CLASS field = %q, want %q (V127 UX-3 item 2.5 resync class missing at runtime)", fields[9], banlog.ClassResync)
	}
}

// TestLogTempBan_TwoCallsAppendTwoBLC1Rows asserts repeated invocations
// produce two clean BLC-1 rows (no interleaved formats, no truncation,
// no missing newlines between rows) — the exact regression mode of the
// pre-V127 bug where space-delimited and pipe-delimited rows coexisted
// in bans.log and broke `nftban stats recent`.
func TestLogTempBan_TwoCallsAppendTwoBLC1Rows(t *testing.T) {
	_ = os.Remove(blc1TestBansLog)

	if err := LogTempBan("/ignored", "192.0.2.1", "nftban-sshd", "first"); err != nil {
		t.Fatalf("first LogTempBan: %v", err)
	}
	if err := LogTempBan("/ignored", "192.0.2.2", "portscan", "second"); err != nil {
		t.Fatalf("second LogTempBan: %v", err)
	}

	data, err := os.ReadFile(blc1TestBansLog)
	if err != nil {
		t.Fatalf("could not read bans.log: %v", err)
	}
	lines := strings.Split(strings.TrimRight(string(data), "\n"), "\n")
	if len(lines) != 2 {
		t.Fatalf("expected 2 BLC-1 rows after two LogTempBan calls, got %d: %q", len(lines), string(data))
	}
	for i, line := range lines {
		fields := strings.Split(line, "|")
		if len(fields) != 10 {
			t.Errorf("row %d: expected 10 pipe-delimited fields, got %d in %q", i+1, len(fields), line)
		}
		if fields[5] != banlog.StatusBanned {
			t.Errorf("row %d: STATUS field = %q, want %q", i+1, fields[5], banlog.StatusBanned)
		}
		if fields[9] != banlog.ClassTemp {
			t.Errorf("row %d: CLASS field = %q, want %q", i+1, fields[9], banlog.ClassTemp)
		}
	}
	// Cross-row sanity: sources differ across the two calls
	r1 := strings.Split(lines[0], "|")
	r2 := strings.Split(lines[1], "|")
	if r1[2] != banlog.SourceLogin {
		t.Errorf("row 1 SOURCE = %q, want %q", r1[2], banlog.SourceLogin)
	}
	if r2[2] != banlog.SourcePortscan {
		t.Errorf("row 2 SOURCE = %q, want %q", r2[2], banlog.SourcePortscan)
	}
}
