// =============================================================================
// NFTBan v1.164 - switchop classify-empty hermetic tests (PR-A + PR-B)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-switchop-classify-empty-v164-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-08"
// meta:description="Locks classify-empty ghost cleanup: empty raw/inet-filter skeletons removed, populated tables preserved, override honoured, unconditional ghosts unchanged"
// meta:inventory.files="internal/installer/switchop/classify_empty_v164_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars="NFTBAN_ALLOW_REMOVE_INET_FILTER"
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
//
// These tests drive CleanGhostTables through the MockExecutor. Delete vs
// preserve is asserted via the mock's NftTables map: NftDeleteTable deletes the
// "family:table" key, so NftTableExists returns false after a delete. A table
// that survives keeps its key true. Empty vs populated is driven by
// RunResults["nft:list:table:<family>:<table>"] — an empty Stdout (or only
// structural lines) classifies as empty; a Stdout containing a rule line
// classifies as populated.
package switchop

import (
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
)

// rawSkeletonOutput is what `nft list table ip raw` prints for a bare
// iptables-nft skeleton: a chain shell with no rules. tableRuleCount == 0.
const rawSkeletonOutput = "table ip raw {\n\tchain prerouting {\n\t\ttype filter hook prerouting priority -300; policy accept;\n\t}\n}\n"

// rawPopulatedOutput holds a real NOTRACK rule line (non-structural).
const rawPopulatedOutput = "table ip raw {\n\tchain prerouting {\n\t\ttype filter hook prerouting priority -300; policy accept;\n\t\tip daddr 10.0.0.0/8 notrack\n\t}\n}\n"

// inetFilterPopulatedOutput holds an operator drop rule (non-structural).
const inetFilterPopulatedOutput = "table inet filter {\n\tchain input {\n\t\ttype filter hook input priority 0; policy drop;\n\t\ttcp dport 8080 accept\n\t}\n}\n"

func TestV164_EmptyIPRaw_Removed(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.NftTables["ip:raw"] = true
	mock.RunResults["nft:list:table:ip:raw"] = executor.Result{Stdout: rawSkeletonOutput}

	CleanGhostTables(mock, newTestLogger())

	if mock.NftTableExists("ip", "raw") {
		t.Error("expected empty ip raw skeleton to be removed")
	}
}

func TestV164_PopulatedIPRaw_Preserved(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.NftTables["ip:raw"] = true
	mock.RunResults["nft:list:table:ip:raw"] = executor.Result{Stdout: rawPopulatedOutput}

	CleanGhostTables(mock, newTestLogger())

	if !mock.NftTableExists("ip", "raw") {
		t.Error("expected populated ip raw (NOTRACK/operator content) to be preserved")
	}
}

func TestV164_EmptyIP6Raw_Removed(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.NftTables["ip6:raw"] = true
	mock.RunResults["nft:list:table:ip6:raw"] = executor.Result{Stdout: "table ip6 raw {\n\tchain prerouting {\n\t\ttype filter hook prerouting priority -300; policy accept;\n\t}\n}\n"}

	CleanGhostTables(mock, newTestLogger())

	if mock.NftTableExists("ip6", "raw") {
		t.Error("expected empty ip6 raw skeleton to be removed")
	}
}

func TestV164_EmptyInetFilter_Removed(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.NftTables["inet:filter"] = true
	// Empty/default skeleton: chain shell only, no rules.
	mock.RunResults["nft:list:table:inet:filter"] = executor.Result{Stdout: "table inet filter {\n\tchain input {\n\t\ttype filter hook input priority 0; policy accept;\n\t}\n}\n"}

	CleanGhostTables(mock, newTestLogger())

	if mock.NftTableExists("inet", "filter") {
		t.Error("expected empty inet filter skeleton to be removed (CVE-2025-NFTBAN-001)")
	}
}

func TestV164_PopulatedInetFilter_Preserved(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.NftTables["inet:filter"] = true
	mock.RunResults["nft:list:table:inet:filter"] = executor.Result{Stdout: inetFilterPopulatedOutput}

	// No override set.
	CleanGhostTables(mock, newTestLogger())

	if !mock.NftTableExists("inet", "filter") {
		t.Error("expected populated operator-owned inet filter to be PRESERVED (not deleted) without override")
	}
}

func TestV164_PopulatedInetFilter_OverrideRemoves(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.NftTables["inet:filter"] = true
	mock.RunResults["nft:list:table:inet:filter"] = executor.Result{Stdout: inetFilterPopulatedOutput}
	mock.Env["NFTBAN_ALLOW_REMOVE_INET_FILTER"] = "1"

	CleanGhostTables(mock, newTestLogger())

	if mock.NftTableExists("inet", "filter") {
		t.Error("expected populated inet filter to be removed when NFTBAN_ALLOW_REMOVE_INET_FILTER=1 (explicit opt-in)")
	}
}

// SUPERSEDED by v1.228.11. The former
// TestV164_UnconditionalGhost_RemovedRegardlessOfContent asserted that Class 1
// deletes `ip filter` "regardless of content", on the premise that it "is a
// compat-shim skeleton by construction ... it is never classified".
//
// RUNTIME FALSIFIED THAT PREMISE. On a host with NFTBan and CSF both proven
// absent, a populated operator-owned `ip filter` (hooked chain, accept + drop
// rules) was destroyed by an ordinary `dnf install`, and a populated `ip mangle`
// by a `--force --allow-recommit` run — both returning rc=0/COMMITTED. The name
// does not establish ownership, so "by construction" was an assumption, not a
// property. See OPEN_INSTALLER_DELETES_POPULATED_FOREIGN_NFT_TABLES_BY_NAME.
//
// The replacement below locks the corrected contract. It is deliberately the
// inverse assertion on the SAME fixture, so this file records that the previous
// behaviour was pinned as intended rather than merely overlooked.
func TestV1228_11_PopulatedClass1Table_Preserved(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.NftTables["ip:filter"] = true
	mock.RunResults["nft:list:table:ip:filter"] = executor.Result{Stdout: "table ip filter {\n\tchain input {\n\t\ttype filter hook input priority 0; policy accept;\n\t\ttcp dport 22 accept\n\t}\n}\n"}

	CleanGhostTables(mock, newTestLogger())

	if !mock.NftTableExists("ip", "filter") {
		t.Error("populated Class-1 ip filter was DELETED — ownership is not established by name; " +
			"a populated foreign table must be preserved (INV-CSF-03)")
	}
}

// Empty Class-1 skeletons must STILL be removable, or the fix would be inert.
func TestV1228_11_EmptyClass1Table_StillRemoved(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.NftTables["ip:mangle"] = true
	mock.RunResults["nft:list:table:ip:mangle"] = executor.Result{Stdout: "table ip mangle {\n}\n"}

	CleanGhostTables(mock, newTestLogger())

	if mock.NftTableExists("ip", "mangle") {
		t.Error("empty Class-1 skeleton was preserved — cleanup path is inert (positive control)")
	}
}

// Observation failure is never permission to delete.
func TestV1228_11_UnclassifiableClass1Table_Preserved(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.NftTables["ip:nat"] = true
	mock.RunResults["nft:list:table:ip:nat"] = executor.Result{ExitCode: 1, Stderr: "nft: read failed"}

	CleanGhostTables(mock, newTestLogger())

	if !mock.NftTableExists("ip", "nat") {
		t.Error("table was deleted after a FAILED classification — observation failure must never " +
			"be interpreted as an empty/removable table")
	}
}

// TestV164_AllStaticGhostsStillRemoved guards the unconditional list end-to-end
// so a future edit that accidentally drops an entry (or makes one conditional)
// is caught. None of these are classified; all must be gone.
func TestV164_AllStaticGhostsStillRemoved(t *testing.T) {
	mock := executor.NewMockExecutor()
	static := [][2]string{
		{"ip", "filter"}, {"ip6", "filter"},
		{"ip", "nat"}, {"ip6", "nat"},
		{"ip", "mangle"}, {"ip6", "mangle"},
		{"ip", "security"}, {"ip6", "security"},
		{"inet", "firewalld"},
	}
	for _, g := range static {
		mock.NftTables[g[0]+":"+g[1]] = true
	}

	CleanGhostTables(mock, newTestLogger())

	for _, g := range static {
		if mock.NftTableExists(g[0], g[1]) {
			t.Errorf("expected unconditional ghost %s %s to be removed", g[0], g[1])
		}
	}
}
