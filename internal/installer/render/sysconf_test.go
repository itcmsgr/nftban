// =============================================================================
// NFTBan v1.146 Phase-D - sysconf fenced-include idempotency tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-render-sysconf-test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-03"
// meta:description="v1.146 Phase-D unit tests for the fenced nftban include writer (IntegrateSystemConf) and its pure stripNftbanInclude twin: collapse of accumulated legacy duplicate comments, single-canonical-block output, no-op idempotency (no write when already canonical), and preservation of all operator-owned distro content (flush ruleset + table inet filter skeleton)."
// meta:input="None"
// meta:output="t.Fatalf/t.Errorf on assertion failure"
// meta:depends="testing,internal/installer/executor,internal/installer/logging"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package render

import (
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

const distroSkeleton = `#!/usr/sbin/nft -f

flush ruleset

table inet filter {
	chain input {
		type filter hook input priority 0;
	}
}
`

// countSubstr counts non-overlapping occurrences of sub in s.
func countSubstr(s, sub string) int { return strings.Count(s, sub) }

// assertOperatorContentPreserved fails if the distro skeleton lines were lost.
func assertOperatorContentPreserved(t *testing.T, body string) {
	t.Helper()
	for _, must := range []string{"flush ruleset", "table inet filter", "type filter hook input priority 0;"} {
		if !strings.Contains(body, must) {
			t.Errorf("operator content lost: %q missing from:\n%s", must, body)
		}
	}
}

// TestStripNftbanInclude_PureLogic covers the remover twin directly.
func TestStripNftbanInclude_PureLogic(t *testing.T) {
	// Polluted file: distro skeleton + a stale fenced block + TWO accumulated
	// legacy comments + TWO stray legacy includes (the exact pre-v1.146 bug).
	polluted := distroSkeleton +
		IncludeBeginMarker + "\n" + IncludeDirective + "\n" + IncludeEndMarker + "\n" +
		legacyComment + "\n" +
		IncludeDirective + "\n" +
		legacyComment + "\n"

	out := stripNftbanInclude(polluted)

	if strings.Contains(out, IncludeBeginMarker) || strings.Contains(out, IncludeEndMarker) {
		t.Errorf("fenced markers survived strip:\n%s", out)
	}
	if strings.Contains(out, legacyComment) {
		t.Errorf("legacy comment survived strip:\n%s", out)
	}
	if strings.Contains(out, "/etc/nftban/nftables.conf") {
		t.Errorf("include directive survived strip:\n%s", out)
	}
	assertOperatorContentPreserved(t, out)

	// Idempotent: stripping clean content changes nothing.
	if again := stripNftbanInclude(out); again != out {
		t.Errorf("strip not idempotent:\n--first--\n%s\n--second--\n%s", out, again)
	}
}

// TestIntegrateSystemConf_FreshAppendsOneFencedBlock asserts a clean distro
// file gains exactly one fenced block and keeps its content.
func TestIntegrateSystemConf_FreshAppendsOneFencedBlock(t *testing.T) {
	log := logging.New("/dev/null", false)
	defer log.Close()
	m := executor.NewMockExecutor()
	const p = "/etc/nftables.conf"
	m.Files[p] = []byte(distroSkeleton)

	if err := IntegrateSystemConf(m, p, log); err != nil {
		t.Fatalf("integrate: %v", err)
	}
	body := string(m.Files[p])
	if got := countSubstr(body, IncludeBeginMarker); got != 1 {
		t.Errorf("want exactly 1 fenced block, got %d:\n%s", got, body)
	}
	if got := countSubstr(body, IncludeDirective); got != 1 {
		t.Errorf("want exactly 1 include directive, got %d", got)
	}
	if strings.Contains(body, legacyComment) {
		t.Errorf("new write must not emit the legacy unfenced comment:\n%s", body)
	}
	assertOperatorContentPreserved(t, body)
}

// TestIntegrateSystemConf_CollapsesAccumulatedDuplicates asserts the
// self-healing path: a file polluted by the pre-v1.146 bug (multiple legacy
// comments + includes) is normalised to a single fenced block.
func TestIntegrateSystemConf_CollapsesAccumulatedDuplicates(t *testing.T) {
	log := logging.New("/dev/null", false)
	defer log.Close()
	m := executor.NewMockExecutor()
	const p = "/etc/nftables.conf"
	m.Files[p] = []byte(distroSkeleton +
		legacyComment + "\n" + IncludeDirective + "\n" +
		legacyComment + "\n" + IncludeDirective + "\n" +
		legacyComment + "\n" + IncludeDirective + "\n")

	if err := IntegrateSystemConf(m, p, log); err != nil {
		t.Fatalf("integrate: %v", err)
	}
	body := string(m.Files[p])
	if got := countSubstr(body, IncludeBeginMarker); got != 1 {
		t.Errorf("want exactly 1 fenced block after collapse, got %d:\n%s", got, body)
	}
	if got := countSubstr(body, IncludeDirective); got != 1 {
		t.Errorf("want exactly 1 include after collapse, got %d", got)
	}
	if strings.Contains(body, legacyComment) {
		t.Errorf("accumulated legacy comments not collapsed:\n%s", body)
	}
	assertOperatorContentPreserved(t, body)
}

// TestIntegrateSystemConf_IdempotentNoWrite asserts that a file already
// carrying exactly the canonical fenced block is left untouched (no write,
// mtime preserved).
func TestIntegrateSystemConf_IdempotentNoWrite(t *testing.T) {
	log := logging.New("/dev/null", false)
	defer log.Close()
	m := executor.NewMockExecutor()
	const p = "/etc/nftables.conf"

	// First integrate establishes the canonical block.
	m.Files[p] = []byte(distroSkeleton)
	if err := IntegrateSystemConf(m, p, log); err != nil {
		t.Fatalf("integrate #1: %v", err)
	}
	// Reset the write ledger and integrate again — must be a no-op.
	m.WrittenFiles = map[string][]byte{}
	if err := IntegrateSystemConf(m, p, log); err != nil {
		t.Fatalf("integrate #2: %v", err)
	}
	if _, wrote := m.WrittenFiles[p]; wrote {
		t.Errorf("second integrate wrote despite canonical content (not idempotent)")
	}
}
