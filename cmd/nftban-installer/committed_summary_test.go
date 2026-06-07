// =============================================================================
// NFTBan v1.160 - committedSummaryLine wording tests (PR-A)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="committed_summary_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-07"
// meta:description="v1.160 PR-A: verifies the COMMITTED summary wording — zero warnings keeps the 'no warnings' line; one or more warnings reports the count, pluralizes the noun, marks them non-fatal, and points at the log path."
// meta:input="committedSummaryLine(warnCount, logPath) calls"
// meta:output="t.Error on wording mismatch"
// meta:depends="testing"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package main

import (
	"strings"
	"testing"
)

func TestCommittedSummaryLineNoWarnings(t *testing.T) {
	got := committedSummaryLine(0, "/var/log/nftban/installer.log")
	want := "[NFTBan] Install/upgrade completed (state: COMMITTED, no warnings)."
	if got != want {
		t.Fatalf("committedSummaryLine(0, …) = %q, want %q", got, want)
	}
}

func TestCommittedSummaryLineSingleWarning(t *testing.T) {
	got := committedSummaryLine(1, "/var/log/nftban/installer.log")
	if !strings.Contains(got, "with 1 warning ") {
		t.Errorf("expected singular %q in %q", "with 1 warning ", got)
	}
	if strings.Contains(got, "warnings") {
		t.Errorf("count of 1 should not pluralize: %q", got)
	}
	if !strings.Contains(got, "non-fatal") {
		t.Errorf("expected non-fatal marker in %q", got)
	}
	if !strings.Contains(got, "/var/log/nftban/installer.log") {
		t.Errorf("expected log path in %q", got)
	}
}

func TestCommittedSummaryLineMultipleWarnings(t *testing.T) {
	got := committedSummaryLine(2, "/tmp/installer.log")
	if !strings.Contains(got, "with 2 warnings ") {
		t.Errorf("expected plural %q in %q", "with 2 warnings ", got)
	}
	if !strings.Contains(got, "COMMITTED") {
		t.Errorf("expected COMMITTED in %q", got)
	}
	if !strings.Contains(got, "/tmp/installer.log") {
		t.Errorf("expected log path in %q", got)
	}
}
