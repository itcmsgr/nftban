// =============================================================================
// NFTBan v1.120 - Session Whitelist Unit Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="session_whitelist_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-18"
// meta:description="V120 unit tests for internal/installer/safety/session_whitelist.go covering AddSessionWhitelist (create-with-header / refresh-dedup), CleanupExpiredSessionWhitelist (mixed expired/active), ReadSessionWhitelist (parses inline markers), RemoveSessionWhitelist, CaptureSSHPeerIP (env-mirror precedence, SSH_CLIENT fallback, non-routable rejection, empty-env), and lineIsExpired / parseSessionLine helpers."
// meta:input="MockExecutor in-memory files, env vars NFTBAN_OPERATOR_SESSION_IP/SSH_CLIENT"
// meta:output="t.Fatal/t.Errorf on assertion failure"
// meta:depends="testing,time,strings,internal/installer/executor,internal/installer/logging"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars="SSH_CLIENT,NFTBAN_OPERATOR_SESSION_IP"
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package safety

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// TestMain redirects the cross-process session-whitelist lock to a writable
// temp path so the package's tests neither require /run/nftban nor root (they
// run unprivileged in CI). The flock still engages on the temp file, so the
// concurrency test exercises a real lock.
func TestMain(m *testing.M) {
	d, err := os.MkdirTemp("", "nftban-sessionlock-")
	if err != nil {
		panic(err)
	}
	sessionWhitelistLockPath = filepath.Join(d, "session_whitelist.lock")
	code := m.Run()
	_ = os.RemoveAll(d)
	os.Exit(code)
}

// newSessionTestLogger returns a Logger writing to /dev/null. The test never
// asserts on log output; we just need a non-nil Logger.
func newSessionTestLogger(t *testing.T) *logging.Logger {
	t.Helper()
	return logging.New("/dev/null", false)
}

// TestAddSessionWhitelist_CreatesFileWithHeaderOnFirstAdd asserts that the
// first AddSessionWhitelist call creates 00-session.conf with the
// machine-managed header AND the new entry.
func TestAddSessionWhitelist_CreatesFileWithHeaderOnFirstAdd(t *testing.T) {
	mock := executor.NewMockExecutor()
	log := newSessionTestLogger(t)
	defer log.Close()

	entry := SessionWhitelistEntry{
		IP:        "192.0.2.122",
		ExpiresAt: time.Date(2026, 5, 18, 10, 13, 32, 0, time.UTC),
		Reason:    "v120-update-session",
		AddedBy:   "nftban-update",
	}
	if err := AddSessionWhitelist(mock, log, entry); err != nil {
		t.Fatalf("AddSessionWhitelist: %v", err)
	}

	data, err := mock.ReadFile(sessionWhitelistPath)
	if err != nil {
		t.Fatalf("ReadFile %s: %v", sessionWhitelistPath, err)
	}
	content := string(data)

	if !strings.Contains(content, "NFTBan Session Whitelist (managed by nftban; do not hand-edit)") {
		t.Errorf("header missing from new file:\n%s", content)
	}
	if !strings.Contains(content, "192.0.2.122") {
		t.Errorf("entry IP missing:\n%s", content)
	}
	if !strings.Contains(content, "EXPIRES_AT=2026-05-18T10:13:32Z") {
		t.Errorf("EXPIRES_AT marker missing or wrong format:\n%s", content)
	}
	if !strings.Contains(content, "REASON=v120-update-session") {
		t.Errorf("REASON marker missing:\n%s", content)
	}
	if !strings.Contains(content, "ADDED_BY=nftban-update") {
		t.Errorf("ADDED_BY marker missing:\n%s", content)
	}
}

// TestAddSessionWhitelist_RefreshesExistingEntry asserts that re-adding the
// same IP REPLACES rather than DUPLICATES the prior entry (refresh semantics).
func TestAddSessionWhitelist_RefreshesExistingEntry(t *testing.T) {
	mock := executor.NewMockExecutor()
	log := newSessionTestLogger(t)
	defer log.Close()

	first := SessionWhitelistEntry{
		IP:        "192.0.2.122",
		ExpiresAt: time.Date(2026, 5, 18, 10, 0, 0, 0, time.UTC),
		Reason:    "first-add",
		AddedBy:   "nftban-update",
	}
	if err := AddSessionWhitelist(mock, log, first); err != nil {
		t.Fatalf("first AddSessionWhitelist: %v", err)
	}

	second := SessionWhitelistEntry{
		IP:        "192.0.2.122",
		ExpiresAt: time.Date(2026, 5, 18, 11, 0, 0, 0, time.UTC),
		Reason:    "second-add",
		AddedBy:   "nftban-firewall-whitelist-session",
	}
	if err := AddSessionWhitelist(mock, log, second); err != nil {
		t.Fatalf("second AddSessionWhitelist: %v", err)
	}

	data, err := mock.ReadFile(sessionWhitelistPath)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	content := string(data)
	// T-1 fix (V120_PR_637_CI_AND_DIFF_VERIFICATION §3): count only DATA
	// lines whose first whitespace-delimited token equals the IP. A naive
	// strings.Count over the raw content double-counts the example
	// occurrence inside the file header (`# 192.0.2.122 # EXPIRES_AT=...
	// REASON=v120-update-session ADDED_BY=nftban-update`). Skip blank and
	// `#`-prefixed comment lines so the header example is not counted.
	occurrences := countDataLinesForIP(content, "192.0.2.122")
	if occurrences != 1 {
		t.Errorf("expected exactly 1 data-line occurrence of 192.0.2.122 after refresh, got %d:\n%s",
			occurrences, content)
	}
	if !strings.Contains(content, "REASON=second-add") {
		t.Errorf("expected refresh to keep newer REASON; not found:\n%s", content)
	}
	if strings.Contains(content, "REASON=first-add") {
		t.Errorf("expected refresh to drop older REASON; still present:\n%s", content)
	}
}

// countDataLinesForIP returns the number of non-blank, non-comment lines
// in `content` whose first whitespace-delimited token equals `ip`. Used by
// V120 dedup/refresh assertions where a naive substring count would also
// match the IP appearing inside file-header example/documentation lines.
//
// Lines whose trimmed-leading-whitespace form starts with `#` are treated
// as comments and skipped. Blank lines are skipped. For non-skipped lines,
// the IP is matched only against the first token before any inline `#`.
func countDataLinesForIP(content, ip string) int {
	count := 0
	for _, line := range strings.Split(content, "\n") {
		trimmed := strings.TrimLeft(line, " \t")
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		// Strip inline `# ...` trailing comment, then take the first token.
		beforeHash := trimmed
		if idx := strings.IndexByte(beforeHash, '#'); idx >= 0 {
			beforeHash = beforeHash[:idx]
		}
		fields := strings.Fields(beforeHash)
		if len(fields) > 0 && fields[0] == ip {
			count++
		}
	}
	return count
}

// TestCleanupExpiredSessionWhitelist_RemovesOnlyExpired asserts cleanup
// drops expired entries and preserves active entries + header lines.
func TestCleanupExpiredSessionWhitelist_RemovesOnlyExpired(t *testing.T) {
	mock := executor.NewMockExecutor()
	log := newSessionTestLogger(t)
	defer log.Close()

	now := time.Now().UTC()
	expired := SessionWhitelistEntry{
		IP:        "10.0.0.1",
		ExpiresAt: now.Add(-1 * time.Hour),
		Reason:    "stale",
		AddedBy:   "test",
	}
	active := SessionWhitelistEntry{
		IP:        "10.0.0.2",
		ExpiresAt: now.Add(1 * time.Hour),
		Reason:    "fresh",
		AddedBy:   "test",
	}
	if err := AddSessionWhitelist(mock, log, expired); err != nil {
		t.Fatalf("seed expired: %v", err)
	}
	if err := AddSessionWhitelist(mock, log, active); err != nil {
		t.Fatalf("seed active: %v", err)
	}

	removed, err := CleanupExpiredSessionWhitelist(mock, log)
	if err != nil {
		t.Fatalf("CleanupExpiredSessionWhitelist: %v", err)
	}
	if removed != 1 {
		t.Errorf("expected 1 removed, got %d", removed)
	}

	data, _ := mock.ReadFile(sessionWhitelistPath)
	content := string(data)
	if strings.Contains(content, "10.0.0.1") {
		t.Errorf("expired entry not removed:\n%s", content)
	}
	if !strings.Contains(content, "10.0.0.2") {
		t.Errorf("active entry was incorrectly removed:\n%s", content)
	}
	if !strings.Contains(content, "NFTBan Session Whitelist") {
		t.Errorf("header was clobbered:\n%s", content)
	}
}

// TestReadSessionWhitelist_ParsesInlineMarkers asserts the reader returns
// structured entries (IP + ExpiresAt + Reason + AddedBy) from the file.
func TestReadSessionWhitelist_ParsesInlineMarkers(t *testing.T) {
	mock := executor.NewMockExecutor()
	log := newSessionTestLogger(t)
	defer log.Close()

	// T-2 fix (V120_PR_637_CI_AND_DIFF_VERIFICATION §3): use relative
	// timestamps so neither entry can be "born expired" when the test
	// runs near a calendar boundary. The original hard-coded 2026-05-18
	// fixtures became stale relative to "now" when CI ran on the same
	// day, causing the v1.120 loader's EXPIRES_AT skip to drop the first
	// entry and surface a false-negative read assertion.
	//
	// T-2 follow-on fix (V120_PR_637_CI_AND_DIFF_VERIFICATION_RERUN §3):
	// truncate to second precision so the in-memory value matches the
	// RFC3339 round-trip the implementation performs at write/read.
	// time.Now() returns nanosecond precision; AddSessionWhitelist
	// serializes via RFC3339 ("2026-05-18T12:08:59Z") which drops sub-
	// second digits; ReadSessionWhitelist parses back at 0 ns. Without
	// the Truncate, entries[0].ExpiresAt.Equal(t1) returns false for
	// any non-zero-nanosecond t1 even when the implementation is correct.
	t1 := time.Now().UTC().Add(time.Hour).Truncate(time.Second)
	t2 := time.Now().UTC().Add(2 * time.Hour).Truncate(time.Second)
	_ = AddSessionWhitelist(mock, log, SessionWhitelistEntry{
		IP: "10.0.0.1", ExpiresAt: t1, Reason: "one", AddedBy: "test",
	})
	_ = AddSessionWhitelist(mock, log, SessionWhitelistEntry{
		IP: "10.0.0.2", ExpiresAt: t2, Reason: "two", AddedBy: "test",
	})

	entries, err := ReadSessionWhitelist(mock, log)
	if err != nil {
		t.Fatalf("ReadSessionWhitelist: %v", err)
	}
	if len(entries) != 2 {
		t.Fatalf("expected 2 entries, got %d: %+v", len(entries), entries)
	}
	// Order: insertion order preserved in the file.
	if entries[0].IP != "10.0.0.1" {
		t.Errorf("entry[0].IP = %q, want 10.0.0.1", entries[0].IP)
	}
	if !entries[0].ExpiresAt.Equal(t1) {
		t.Errorf("entry[0].ExpiresAt = %v, want %v", entries[0].ExpiresAt, t1)
	}
	if entries[0].Reason != "one" {
		t.Errorf("entry[0].Reason = %q, want one", entries[0].Reason)
	}
}

// TestRemoveSessionWhitelist_RemovesByIP asserts removal of one IP keeps
// other entries intact.
func TestRemoveSessionWhitelist_RemovesByIP(t *testing.T) {
	mock := executor.NewMockExecutor()
	log := newSessionTestLogger(t)
	defer log.Close()

	now := time.Now().UTC().Add(1 * time.Hour)
	_ = AddSessionWhitelist(mock, log, SessionWhitelistEntry{IP: "10.0.0.1", ExpiresAt: now, Reason: "a", AddedBy: "t"})
	_ = AddSessionWhitelist(mock, log, SessionWhitelistEntry{IP: "10.0.0.2", ExpiresAt: now, Reason: "b", AddedBy: "t"})

	removed, err := RemoveSessionWhitelist(mock, log, "10.0.0.1")
	if err != nil {
		t.Fatalf("RemoveSessionWhitelist: %v", err)
	}
	if removed != 1 {
		t.Errorf("expected removed=1, got %d", removed)
	}

	entries, _ := ReadSessionWhitelist(mock, log)
	if len(entries) != 1 {
		t.Fatalf("expected 1 surviving entry, got %d: %+v", len(entries), entries)
	}
	if entries[0].IP != "10.0.0.2" {
		t.Errorf("survivor IP = %q, want 10.0.0.2", entries[0].IP)
	}
}

// TestCaptureSSHPeerIP_PrefersExplicitEnvMirror asserts that
// NFTBAN_OPERATOR_SESSION_IP wins over SSH_CLIENT.
func TestCaptureSSHPeerIP_PrefersExplicitEnvMirror(t *testing.T) {
	t.Setenv("NFTBAN_OPERATOR_SESSION_IP", "8.8.8.8")
	t.Setenv("SSH_CLIENT", "1.1.1.1 22 22")

	if got := CaptureSSHPeerIP(); got != "8.8.8.8" {
		t.Errorf("CaptureSSHPeerIP = %q, want 8.8.8.8 (explicit env-mirror wins)", got)
	}
}

// TestCaptureSSHPeerIP_FallsBackToSSHClient asserts SSH_CLIENT is used when
// the explicit env-mirror is empty.
func TestCaptureSSHPeerIP_FallsBackToSSHClient(t *testing.T) {
	t.Setenv("NFTBAN_OPERATOR_SESSION_IP", "")
	t.Setenv("SSH_CLIENT", "192.0.2.122 51234 22")

	if got := CaptureSSHPeerIP(); got != "192.0.2.122" {
		t.Errorf("CaptureSSHPeerIP = %q, want 192.0.2.122", got)
	}
}

// TestCaptureSSHPeerIP_EmptyOnBothMissing asserts non-SSH invocations
// (cron, systemd timer, package scriptlet without env-mirror) return "".
func TestCaptureSSHPeerIP_EmptyOnBothMissing(t *testing.T) {
	t.Setenv("NFTBAN_OPERATOR_SESSION_IP", "")
	t.Setenv("SSH_CLIENT", "")

	if got := CaptureSSHPeerIP(); got != "" {
		t.Errorf("CaptureSSHPeerIP = %q, want \"\" (non-SSH invocation)", got)
	}
}

// TestCaptureSSHPeerIP_RejectsNonRoutable asserts loopback / RFC5735
// non-routable addresses are filtered (matches v1.98.x SeedManualWhitelist
// contract via shared isRoutableIP).
func TestCaptureSSHPeerIP_RejectsNonRoutable(t *testing.T) {
	t.Setenv("NFTBAN_OPERATOR_SESSION_IP", "127.0.0.1")
	t.Setenv("SSH_CLIENT", "")

	if got := CaptureSSHPeerIP(); got != "" {
		t.Errorf("CaptureSSHPeerIP = %q, want \"\" (loopback rejected)", got)
	}
}

// TestLineIsExpired_ParsesEXPIRES_AT covers the helper directly.
func TestLineIsExpired_ParsesEXPIRES_AT(t *testing.T) {
	now := time.Date(2026, 5, 18, 10, 0, 0, 0, time.UTC)

	cases := []struct {
		name        string
		line        string
		wantExpired bool
	}{
		{"expired", "10.0.0.1  # EXPIRES_AT=2026-05-18T09:00:00Z  REASON=x  ADDED_BY=t", true},
		{"active", "10.0.0.1  # EXPIRES_AT=2026-05-18T11:00:00Z  REASON=x  ADDED_BY=t", false},
		{"no_marker", "10.0.0.1  # REASON=x  ADDED_BY=t", false},
		{"comment_only", "# header line", false},
		{"blank", "", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, _ := lineIsExpired(c.line, now)
			if got != c.wantExpired {
				t.Errorf("lineIsExpired(%q) = %v, want %v", c.line, got, c.wantExpired)
			}
		})
	}
}

// TestExtractIPField_Basics covers the IP-token extractor used by
// dedup/remove paths.
func TestExtractIPField_Basics(t *testing.T) {
	cases := []struct {
		line string
		want string
	}{
		{"10.0.0.1  # EXPIRES_AT=2026-05-18T11:00:00Z", "10.0.0.1"},
		{"  192.168.1.0/24   # comment", "192.168.1.0/24"},
		{"# just a comment", ""},
		{"", ""},
		{"  ", ""},
	}
	for _, c := range cases {
		if got := extractIPField(c.line); got != c.want {
			t.Errorf("extractIPField(%q) = %q, want %q", c.line, got, c.want)
		}
	}
}
