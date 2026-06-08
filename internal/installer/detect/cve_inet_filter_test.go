// =============================================================================
// NFTBan v1.161 - CVE-2025-NFTBAN-001 inet-filter guard tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-detect-cve-inet-filter-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-08"
// meta:description="Hermetic tests for the CVE-2025-NFTBAN-001 Go inet-filter guard"
// meta:inventory.files="internal/installer/detect/cve_inet_filter_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars="NFTBAN_ALLOW_REMOVE_INET_FILTER"
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package detect

import (
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
)

const listTableInetFilterKey = "nft:list:table:inet:filter"

// emptyInetFilterDump is a realistic `nft list table inet filter` for a
// default/skeleton table: only structural lines (table/chain/type/policy/
// braces) and no rules. Mirrors the stock distro accept-all skeleton.
const emptyInetFilterDump = `table inet filter {
	chain input {
		type filter hook input priority 0; policy accept;
	}
	chain forward {
		type filter hook forward priority 0; policy accept;
	}
	chain output {
		type filter hook output priority 0; policy accept;
	}
}
`

// populatedInetFilterDump carries an actual rule line (a real operator rule),
// so the classifier must treat it as POPULATED.
const populatedInetFilterDump = `table inet filter {
	chain input {
		type filter hook input priority 0; policy drop;
		tcp dport 22 accept
		ct state established,related accept
	}
}
`

// TestCVEInetFilter_NoTable_NoOp — no `inet filter` table present -> NONE,
// no delete attempted. Idempotent post-scriptlet case.
func TestCVEInetFilter_NoTable_NoOp(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.ExistingCommands["nft"] = true
	// NftTables map intentionally empty: no inet:filter.

	v := CheckCVEInetFilter(mock, newTestLogger())
	if v != CVEInetFilterNone {
		t.Errorf("expected NONE, got %s", v)
	}
	if mock.NftTableExists("inet", "filter") {
		t.Errorf("no table should still mean no table")
	}
}

// TestCVEInetFilter_EmptySkeleton_Removed — an empty/default skeleton table is
// deleted (it would shadow nftban). Verify via NftTableExists going false.
func TestCVEInetFilter_EmptySkeleton_Removed(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.ExistingCommands["nft"] = true
	mock.NftTables["inet:filter"] = true
	mock.RunResults[listTableInetFilterKey] = executor.Result{ExitCode: 0, Stdout: emptyInetFilterDump}

	v := CheckCVEInetFilter(mock, newTestLogger())
	if v != CVEInetFilterRemoved {
		t.Errorf("expected REMOVED, got %s", v)
	}
	if mock.NftTableExists("inet", "filter") {
		t.Errorf("empty skeleton must have been deleted")
	}
}

// TestCVEInetFilter_Populated_NotRemoved — a populated operator-owned table is
// NEVER auto-deleted; the verdict is POPULATED and the table survives.
func TestCVEInetFilter_Populated_NotRemoved(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.ExistingCommands["nft"] = true
	mock.NftTables["inet:filter"] = true
	mock.RunResults[listTableInetFilterKey] = executor.Result{ExitCode: 0, Stdout: populatedInetFilterDump}

	v := CheckCVEInetFilter(mock, newTestLogger())
	if v != CVEInetFilterPopulated {
		t.Errorf("expected POPULATED, got %s", v)
	}
	if !mock.NftTableExists("inet", "filter") {
		t.Errorf("populated operator-owned table must NOT be deleted")
	}
}

// TestCVEInetFilter_Populated_OverrideRemoves — with the explicit opt-in
// NFTBAN_ALLOW_REMOVE_INET_FILTER=1, a populated table IS removed and the
// verdict is REMOVED_OVERRIDE.
func TestCVEInetFilter_Populated_OverrideRemoves(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.ExistingCommands["nft"] = true
	mock.NftTables["inet:filter"] = true
	mock.RunResults[listTableInetFilterKey] = executor.Result{ExitCode: 0, Stdout: populatedInetFilterDump}
	mock.Env["NFTBAN_ALLOW_REMOVE_INET_FILTER"] = "1"

	v := CheckCVEInetFilter(mock, newTestLogger())
	if v != CVEInetFilterRemovedOverride {
		t.Errorf("expected REMOVED_OVERRIDE, got %s", v)
	}
	if mock.NftTableExists("inet", "filter") {
		t.Errorf("override must have deleted the populated table")
	}
}

// TestCVEInetFilter_Override_DoesNotForceDeleteEmpty — the override does not
// change the empty-skeleton path: it is still REMOVED (not REMOVED_OVERRIDE),
// because the empty branch fires first regardless of the env var.
func TestCVEInetFilter_Override_DoesNotForceDeleteEmpty(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.ExistingCommands["nft"] = true
	mock.NftTables["inet:filter"] = true
	mock.RunResults[listTableInetFilterKey] = executor.Result{ExitCode: 0, Stdout: emptyInetFilterDump}
	mock.Env["NFTBAN_ALLOW_REMOVE_INET_FILTER"] = "1"

	v := CheckCVEInetFilter(mock, newTestLogger())
	if v != CVEInetFilterRemoved {
		t.Errorf("expected REMOVED for empty skeleton even with override set, got %s", v)
	}
}

// TestCVEInetFilter_Idempotent_PostScriptlet — running after the package
// scriptlet already removed the skeleton (table gone) is a clean no-op.
func TestCVEInetFilter_Idempotent_PostScriptlet(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.ExistingCommands["nft"] = true
	mock.NftTables["inet:filter"] = true
	mock.RunResults[listTableInetFilterKey] = executor.Result{ExitCode: 0, Stdout: emptyInetFilterDump}

	// First run removes the skeleton.
	if v := CheckCVEInetFilter(mock, newTestLogger()); v != CVEInetFilterRemoved {
		t.Fatalf("first run: expected REMOVED, got %s", v)
	}
	// Second run: table is gone -> NONE, no-op.
	if v := CheckCVEInetFilter(mock, newTestLogger()); v != CVEInetFilterNone {
		t.Errorf("second run: expected NONE (idempotent), got %s", v)
	}
}

// TestInetFilterRuleCount — unit-level check of the rule-counting heuristic,
// the Go twin of the shell grep pipeline.
func TestInetFilterRuleCount(t *testing.T) {
	if n := inetFilterRuleCount(emptyInetFilterDump); n != 0 {
		t.Errorf("empty skeleton should count 0 rules, got %d", n)
	}
	if n := inetFilterRuleCount(populatedInetFilterDump); n < 1 {
		t.Errorf("populated table should count >=1 rules, got %d", n)
	}
	if n := inetFilterRuleCount(""); n != 0 {
		t.Errorf("empty string should count 0 rules, got %d", n)
	}
}
