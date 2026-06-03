// =============================================================================
// NFTBan v1.146 - sysconf fenced-include idempotency + Shape-B skeleton tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-render-sysconf-test"
// meta:type="test"
// meta:version="1.1.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-03"
// meta:description="v1.146 unit tests for IntegrateSystemConf: Phase-D fenced-include idempotency (one canonical block, legacy duplicate collapse, no-op when already canonical) + Shape-B distro-skeleton neutralization (comment bare flush ruleset, remove default EMPTY inet filter skeleton, PRESERVE a populated/operator-owned inet filter verbatim and genuine operator content). Shape B is reboot-proven required (V146_BOOT_SUFFICIENCY_GATE2_REBOOT_PROOF_RECORD.md)."
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

// distroSkeleton is the Debian/Ubuntu default plus a genuine operator sentinel
// line that must always survive.
const operatorSentinel = "# OPERATOR_KEEP_ME do not delete"
const distroSkeleton = `#!/usr/sbin/nft -f

flush ruleset

table inet filter {
	chain input {
		type filter hook input priority 0; policy accept;
	}
	chain forward {
		type filter hook forward priority 0; policy accept;
	}
}
` + operatorSentinel + "\n"

func countSubstr(s, sub string) int { return strings.Count(s, sub) }

func newTestLogger() *logging.Logger { return logging.New("/dev/null", false) }

// TestNeutralize_EmptySkeletonRemoved_FlushCommented covers the Shape-B pure fn.
func TestNeutralize_EmptySkeletonRemoved_FlushCommented(t *testing.T) {
	out := neutralizeDistroSkeleton(distroSkeleton, nil)
	// bare `flush ruleset` must be gone (commented form retains the words)
	for _, line := range strings.Split(out, "\n") {
		if strings.TrimSpace(line) == "flush ruleset" {
			t.Errorf("bare `flush ruleset` survived neutralization:\n%s", out)
		}
	}
	if !strings.Contains(out, "# flush ruleset") {
		t.Errorf("flush ruleset not commented (expected `# flush ruleset ...`):\n%s", out)
	}
	// empty skeleton removed: its inner rule-less chain decls must be gone
	if strings.Contains(out, "type filter hook input priority 0;") {
		t.Errorf("empty inet filter skeleton not removed:\n%s", out)
	}
	// operator content preserved
	if !strings.Contains(out, operatorSentinel) {
		t.Errorf("operator sentinel lost:\n%s", out)
	}
	// idempotent: neutralizing already-neutralized content changes nothing
	if again := neutralizeDistroSkeleton(out, nil); again != out {
		t.Errorf("neutralize not idempotent:\n--1--\n%s\n--2--\n%s", out, again)
	}
}

// TestNeutralize_PopulatedInetFilterPreserved asserts an operator-owned
// populated inet filter is preserved verbatim (never deleted).
func TestNeutralize_PopulatedInetFilterPreserved(t *testing.T) {
	populated := `flush ruleset

table inet filter {
	chain input {
		type filter hook input priority 0; policy drop;
		tcp dport 22 accept
		ct state established,related accept
	}
}
`
	out := neutralizeDistroSkeleton(populated, nil)
	for _, must := range []string{"table inet filter", "tcp dport 22 accept", "ct state established,related accept"} {
		if !strings.Contains(out, must) {
			t.Errorf("populated inet filter content lost (%q):\n%s", must, out)
		}
	}
	// flush ruleset still neutralized even when filter is populated
	if strings.Contains(out, "\nflush ruleset\n") {
		t.Errorf("bare flush ruleset survived alongside populated filter:\n%s", out)
	}
}

// TestStripNftbanInclude_PureLogic covers the remover twin directly.
func TestStripNftbanInclude_PureLogic(t *testing.T) {
	polluted := distroSkeleton +
		IncludeBeginMarker + "\n" + IncludeDirective + "\n" + IncludeEndMarker + "\n" +
		legacyComment + "\n" + IncludeDirective + "\n" + legacyComment + "\n"
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
	if !strings.Contains(out, operatorSentinel) {
		t.Errorf("operator sentinel lost in strip:\n%s", out)
	}
	if again := stripNftbanInclude(out); again != out {
		t.Errorf("strip not idempotent")
	}
}

// TestIntegrateSystemConf_FreshShapeB: one fenced block + skeleton neutralized +
// operator content preserved.
func TestIntegrateSystemConf_FreshShapeB(t *testing.T) {
	log := newTestLogger()
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
		t.Errorf("want exactly 1 include, got %d", got)
	}
	for _, line := range strings.Split(body, "\n") {
		if strings.TrimSpace(line) == "flush ruleset" {
			t.Errorf("Shape B: bare flush ruleset not neutralized:\n%s", body)
		}
	}
	if strings.Contains(body, "type filter hook input priority 0;") {
		t.Errorf("Shape B: empty inet filter skeleton not removed:\n%s", body)
	}
	if !strings.Contains(body, operatorSentinel) {
		t.Errorf("operator content lost:\n%s", body)
	}
}

// TestIntegrateSystemConf_CollapsesAccumulatedDuplicates: self-heal path.
func TestIntegrateSystemConf_CollapsesAccumulatedDuplicates(t *testing.T) {
	log := newTestLogger()
	defer log.Close()
	m := executor.NewMockExecutor()
	const p = "/etc/nftables.conf"
	m.Files[p] = []byte(distroSkeleton +
		legacyComment + "\n" + IncludeDirective + "\n" +
		legacyComment + "\n" + IncludeDirective + "\n")
	if err := IntegrateSystemConf(m, p, log); err != nil {
		t.Fatalf("integrate: %v", err)
	}
	body := string(m.Files[p])
	if got := countSubstr(body, IncludeBeginMarker); got != 1 {
		t.Errorf("want 1 fenced block after collapse, got %d:\n%s", got, body)
	}
	if strings.Contains(body, legacyComment) {
		t.Errorf("legacy comments not collapsed:\n%s", body)
	}
}

// TestIntegrateSystemConf_IdempotentNoWrite: second integrate on an
// already-neutralized canonical file must not write.
func TestIntegrateSystemConf_IdempotentNoWrite(t *testing.T) {
	log := newTestLogger()
	defer log.Close()
	m := executor.NewMockExecutor()
	const p = "/etc/nftables.conf"
	m.Files[p] = []byte(distroSkeleton)
	if err := IntegrateSystemConf(m, p, log); err != nil {
		t.Fatalf("integrate #1: %v", err)
	}
	m.WrittenFiles = map[string][]byte{}
	if err := IntegrateSystemConf(m, p, log); err != nil {
		t.Fatalf("integrate #2: %v", err)
	}
	if _, wrote := m.WrittenFiles[p]; wrote {
		t.Errorf("second integrate wrote despite canonical+neutralized content (not idempotent):\n%s", string(m.Files[p]))
	}
}
