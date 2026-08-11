// =============================================================================
// NFTBan v1.164 - Empty-table classifier (switchop ghost cleanup)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-switchop-classify"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-08"
// meta:description="Classify-empty primitive for ghost-table cleanup: count non-structural rule lines so populated/operator tables are preserved"
// meta:inventory.files="internal/installer/switchop/classify.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// v1.164 switchop classify-empty (PR-A + PR-B)
//
// Ghost-table cleanup historically deleted certain nftables tables
// unconditionally. That is correct for tables that an iptables-nft compat
// shim creates purely as a side-effect of iptables being installed (ip
// filter/nat/mangle/security, inet firewalld) — those are skeletons by
// construction and never hold operator rules.
//
// It is NOT correct for tables that can legitimately hold operator or kernel
// content even when an empty skeleton of the same name also occurs in the
// iptables-nft world. Two cases motivated this primitive:
//
//	ip raw / ip6 raw  — an empty `raw` table is the iptables-nft skeleton, but
//	                    a populated `raw` table holds real NOTRACK / conntrack
//	                    exemptions an operator (or the kernel default path) put
//	                    there. Deleting it silently drops those rules.
//	inet filter       — already classify-then-act'd by the CVE-2025-NFTBAN-001
//	                    guard (detect/cve_inet_filter.go), which PRESERVES a
//	                    populated operator-owned table. The unconditional
//	                    delete in CleanGhostTables could then destroy exactly
//	                    what the detect phase had deliberately kept.
//
// TableIsEmpty is the shared primitive that lets CleanGhostTables remove only
// proven-empty skeletons and preserve populated tables. It reuses the same
// "is this a rule?" structural-line heuristic as the CVE guard's
// inetFilterRuleCount (detect/cve_inet_filter.go) so the two paths classify
// identically; this is the generalized form (it also treats set/elements/map
// structural blocks as non-rules so set-only tables read as empty-of-rules).
//
// =============================================================================
package switchop

import (
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/executor"
)

// TableIsEmpty reports whether the named nft table exists and contains zero
// rule lines — i.e. it is a bare iptables-nft / distro skeleton safe to
// remove. It runs `nft list table <family> <table>` and counts non-structural,
// non-blank lines (the same heuristic the CVE inet-filter guard uses).
//
// Conservative by contract: if the table does not exist, or `nft` errors
// (non-zero exit), TableIsEmpty returns false so the caller does NOT treat it
// as a removable skeleton. Callers gate the actual delete on NftTableExists
// first; the existence re-check here is defense-in-depth for the error case.
// TableClass is the tri-state result of classifying a foreign nft table.
//
// TableIsEmpty collapses "populated" and "could not observe" into a single
// false, which is correct for a delete gate (both must refuse) but wrong for
// reporting: an install that could not CLASSIFY a table has not established
// that its cleanup was safe, and must not report clean success. v1.228.11
// separates the two so callers can preserve in both cases while telling the
// truth about which one happened.
type TableClass int

const (
	// TableClassUnknown — `nft` could not be read. Observation failure is NEVER
	// permission to delete (OBSERVATION_FAILURE != SECURITY_STATE_EMPTY).
	TableClassUnknown TableClass = iota
	// TableClassAbsent — the table does not exist; nothing to do.
	TableClassAbsent
	// TableClassEmpty — exists with zero rule lines: a bare iptables-nft/distro
	// skeleton, eligible for cleanup.
	TableClassEmpty
	// TableClassPopulated — holds real rules. Ownership is NOT established by
	// the table name, so this is foreign-or-unknown and must be preserved.
	TableClassPopulated
)

// ClassifyTable reports the tri-state class of a table using the same
// structural-line heuristic as TableIsEmpty, so the delete gate and the
// reporting path can never disagree.
func ClassifyTable(exec executor.Executor, family, table string) TableClass {
	if !exec.NftTableExists(family, table) {
		return TableClassAbsent
	}
	res := exec.Run("nft", "list", "table", family, table)
	if res.ExitCode != 0 {
		return TableClassUnknown
	}
	if tableRuleCount(res.Stdout) == 0 {
		return TableClassEmpty
	}
	return TableClassPopulated
}

func TableIsEmpty(exec executor.Executor, family, table string) bool {
	if !exec.NftTableExists(family, table) {
		return false
	}
	res := exec.Run("nft", "list", "table", family, table)
	if res.ExitCode != 0 {
		// nft errored (table vanished mid-flight, transient failure): do not
		// claim emptiness — refuse to delete on uncertain evidence.
		return false
	}
	return tableRuleCount(res.Stdout) == 0
}

// tableRuleCount counts non-structural, non-blank lines in `nft list table`
// output — the generalized form of the CVE guard's inetFilterRuleCount
// (detect/cve_inet_filter.go). Structural lines (table/chain/type /policy/
// closing-brace/comment, plus set/elements/map block headers) are not rules;
// anything else is.
func tableRuleCount(out string) int {
	count := 0
	for _, raw := range strings.Split(out, "\n") {
		line := strings.TrimSpace(raw)
		if line == "" {
			continue
		}
		if isStructuralLine(line) {
			continue
		}
		count++
	}
	return count
}

// isStructuralLine reports whether a trimmed line is structural (and therefore
// not a rule). Mirrors detect/cve_inet_filter.go::isInetFilterStructuralLine
// and extends it with set/elements/map so a table whose only content is an
// empty/declarative set still reads as empty-of-rules.
//
// Note "type " keeps its trailing space (matches `type filter hook ...`, the
// chain type declaration) so it never swallows a real rule that merely starts
// with the token "type".
func isStructuralLine(line string) bool {
	switch {
	case strings.HasPrefix(line, "table"):
		return true
	case strings.HasPrefix(line, "chain"):
		return true
	case strings.HasPrefix(line, "type "):
		return true
	case strings.HasPrefix(line, "policy"):
		return true
	case strings.HasPrefix(line, "}"):
		return true
	case strings.HasPrefix(line, "#"):
		return true
	case strings.HasPrefix(line, "set"):
		return true
	case strings.HasPrefix(line, "elements"):
		return true
	case strings.HasPrefix(line, "map"):
		return true
	}
	return false
}
