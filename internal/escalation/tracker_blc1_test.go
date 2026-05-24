// SPDX-License-Identifier: MPL-2.0
// =============================================================================
// V127 UX-3 item 2.4 — LogTempBan BLC-1 convergence regression test
// =============================================================================
// meta:name="tracker-blc1-test"
// meta:type="test"
// meta:version="1.127.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-24"
// meta:description="V127 UX-3 item 2.4 regression guard. Pre-V127 internal/escalation/tracker.go::LogTempBan wrote a space-delimited legacy format to its logPath argument (typically /var/log/nftban/bans.log via cfg.BanLog), which is the SAME file internal/banlog/banlog.go::writeEntryFull writes BLC-1 pipe format to — producing interleaved mixed-format rows that broke nftban stats recent. V127 fix (A1 facade convergence): LogTempBan keeps its signature but its body delegates to banlog.LogBanFull so bans.log has ONE canonical 10-field BLC-1 pipe writer. This test asserts (a) the source code no longer contains the legacy fmt.Sprintf(\"%s %s %s %s\\n\", ...) writer pattern, (b) LogTempBan source code references banlog.LogBanFull, (c) the escalation package now imports banlog. Full runtime behavior (actual BLC-1 line written to a temp file) is covered indirectly by Go integration tests of banlog.writeEntryFull elsewhere in the suite; here we focus on the regression-guard property that the legacy format CANNOT reappear via this function unless someone rewrites the body."
// meta:input="static source-file read"
// meta:output="t.Fatal on regression"
// meta:depends="testing,bytes,os"
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
	"bytes"
	"os"
	"strings"
	"testing"
)

// TestLogTempBanBLC1Convergence is the V127 UX-3 item 2.4 regression guard.
// Asserts the source code of tracker.go shape such that the legacy space-
// delimited writer cannot reappear without a deliberate source rewrite.
func TestLogTempBanBLC1Convergence(t *testing.T) {
	src, err := os.ReadFile("tracker.go")
	if err != nil {
		t.Fatalf("could not read tracker.go for regression-guard inspection: %v", err)
	}

	// (a) The pre-V127 legacy space-delimited writer pattern MUST be absent.
	// Specifically the format string with 4 %s separated by spaces + newline,
	// which produced "2025-11-27T10:00:00Z 1.2.3.4 nftban-sshd SSH brute force\n".
	legacyPatterns := []string{
		`fmt.Sprintf("%s %s %s %s\n", timestamp`,
		`fmt.Sprintf("%s %s %s %s\n", time.Now().Format(time.RFC3339)`,
		// Catch any other "%s %s %s %s\n" Sprintf form regardless of var name
		`"%s %s %s %s\n"`,
	}
	for _, p := range legacyPatterns {
		if bytes.Contains(src, []byte(p)) {
			t.Errorf("V127 UX-3 item 2.4 REGRESSION: legacy space-delimited writer pattern %q found in tracker.go — LogTempBan MUST delegate to banlog.LogBanFull (BLC-1 pipe format); see V127_FULL_UX_CORRECTION_UMBRELLA_SCOPE.md UX-3 item 2.4", p)
		}
	}

	// (b) LogTempBan source code MUST reference banlog.LogBanFull
	if !bytes.Contains(src, []byte("banlog.LogBanFull")) {
		t.Errorf("V127 UX-3 item 2.4: tracker.go does NOT call banlog.LogBanFull — A1 facade convergence is broken; LogTempBan must delegate to the canonical BLC-1 writer")
	}

	// (c) Escalation package must import banlog
	if !bytes.Contains(src, []byte(`"github.com/itcmsgr/nftban/internal/banlog"`)) {
		t.Errorf("V127 UX-3 item 2.4: tracker.go does not import internal/banlog — A1 facade convergence cannot work")
	}

	// (d) LogTempBan signature must be preserved (backward-compat facade contract)
	if !bytes.Contains(src, []byte("func LogTempBan(logPath, ip, jail, reason string) error {")) {
		t.Errorf("V127 UX-3 item 2.4: LogTempBan signature changed — A1 contract requires signature preservation for zero call-site churn (cmd/nftban-core/cmd_ban.go:369 and cmd/nftband/daemon_handlers_ban.go:96 must not need changes)")
	}

	// (e) The V127 scope comment anchor must be present in the source
	if !bytes.Contains(src, []byte("V127 UX-3 item 2.4")) {
		t.Errorf("V127 UX-3 item 2.4: scope-anchor comment missing from tracker.go — required for traceability")
	}
}

// TestLogTempBanFunctionShape asserts the rewritten function body is the
// minimal A1 facade and not an in-place rewrite that still does its own
// fmt.Sprintf string-building (which could regress to space-delimited).
func TestLogTempBanFunctionShape(t *testing.T) {
	src, err := os.ReadFile("tracker.go")
	if err != nil {
		t.Fatalf("could not read tracker.go: %v", err)
	}
	srcStr := string(src)

	// Locate LogTempBan function
	idx := strings.Index(srcStr, "func LogTempBan(logPath, ip, jail, reason string) error {")
	if idx < 0 {
		t.Fatalf("LogTempBan function not found")
	}
	// Find the closing brace of this function (next standalone "}" line after idx)
	tail := srcStr[idx:]
	endIdx := strings.Index(tail, "\n}\n")
	if endIdx < 0 {
		t.Fatalf("could not locate end of LogTempBan function body")
	}
	body := tail[:endIdx]

	// Body MUST contain the delegation call
	if !strings.Contains(body, "banlog.LogBanFull(") {
		t.Errorf("LogTempBan body does not contain banlog.LogBanFull call — A1 facade contract violated")
	}

	// Body must NOT contain any os.OpenFile / safety.SafeOpenFile / WriteString
	// pattern (any direct write would be a separate writer path = regression)
	forbiddenInBody := []string{
		"safety.SafeOpenFile",
		"os.OpenFile",
		"WriteString",
		"f.Write",
	}
	for _, p := range forbiddenInBody {
		if strings.Contains(body, p) {
			t.Errorf("LogTempBan body contains forbidden direct-write pattern %q — must delegate to banlog.LogBanFull only", p)
		}
	}
}
