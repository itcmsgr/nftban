// =============================================================================
// NFTBan v1.73 - Installer Ghost Table Cleanup
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-switchop-ghost"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Remove ghost nftables tables from conflicting firewalls"
// meta:inventory.files="internal/installer/switchop/ghost.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package switchop

import (
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// inetFilterOverrideEnv is the exact env var the shell scriptlets and the
// detect-phase CVE guard honour (packaging/deb/postinst,
// packaging/build_nftban.sh, detect/cve_inet_filter.go). Mirrored verbatim so
// every path reacts identically to the same operator opt-in: setting it to "1"
// authorises deleting a POPULATED, operator-owned `inet filter` table.
const inetFilterOverrideEnv = "NFTBAN_ALLOW_REMOVE_INET_FILTER"

// ghostTables is the Class-1 name list. v1.228.11: these names are CANDIDATES
// for cleanup, no longer an unconditional-delete list — each is classified by
// ClassifyTable and only a proven-EMPTY skeleton is removed. A populated or
// unclassifiable table is preserved and warned about. See the Class-1 block in
// CleanGhostTables and OPEN_INSTALLER_DELETES_POPULATED_FOREIGN_NFT_TABLES_BY_NAME.
//
// Original note: tables an iptables-nft compat
// shim (or firewalld) creates purely as a side-effect and that never legitimately
// hold operator rules. These are skeletons by construction, so deleting them on
// sight is safe.
//
// NOTE: `inet filter` is intentionally NOT in this list. It moved to the
// classify-empty path below (v1.164 PR-B) because a populated `inet filter`
// can be operator-owned (CVE-2025-NFTBAN-001 guard preserves it). Likewise
// `ip raw` / `ip6 raw` are handled by the classify-empty path (PR-A), not here.
var ghostTables = []struct {
	family string
	table  string
}{
	{"ip", "filter"},
	{"ip6", "filter"},
	{"ip", "nat"},
	{"ip6", "nat"},
	{"ip", "mangle"},
	{"ip6", "mangle"},
	{"ip", "security"},
	{"ip6", "security"},
	{"inet", "firewalld"},
}

// rawGhostTables are the conditional classify-empty raw tables (v1.164 PR-A).
// An EMPTY `raw` table is an iptables-nft skeleton (created merely because
// iptables-nft is installed) and is safe to remove. A POPULATED `raw` table
// holds real NOTRACK / conntrack-exemption rules an operator (or the kernel
// default path) put there — it is preserved, never deleted on sight.
var rawGhostTables = []struct {
	family string
	table  string
}{
	{"ip", "raw"},
	{"ip6", "raw"},
}

// CleanGhostTables removes known ghost nftables tables.
//
// Three classes, by removability:
//
//   - ghostTables (filter/nat/mangle/security/firewalld): unconditional delete
//     — these are always compat-shim skeletons.
//   - rawGhostTables (ip raw / ip6 raw): classify-empty (PR-A) — delete only if
//     proven empty; preserve populated operator/kernel content.
//   - inet filter: classify-empty + override (PR-B) — delete only if proven
//     empty; preserve populated operator-owned table unless the operator
//     explicitly sets NFTBAN_ALLOW_REMOVE_INET_FILTER=1.
//
// Ignores errors for tables that don't exist.
func CleanGhostTables(exec executor.Executor, log *logging.Logger) {
	// Class 1 — v1.228.11: was UNCONDITIONAL DELETE BY NAME.
	//
	// OPEN_INSTALLER_DELETES_POPULATED_FOREIGN_NFT_TABLES_BY_NAME (P0). The
	// previous form deleted these tables because their family/name matched,
	// with no emptiness check and no ownership attribution. REPRODUCED twice on
	// a host with NFTBan and CSF both proven ABSENT beforehand: an ordinary
	// `dnf install` destroyed a populated operator-owned `ip filter` (hooked
	// chain + accept/drop rules), and a `--force --allow-recommit` run destroyed
	// a populated `ip mangle`. Both installs returned rc=0/COMMITTED, and the
	// same log said "No conflicting firewall tools detected" three lines before
	// "removed ghost table: ip filter" — the name alone triggered the delete.
	//
	// This is NOT takeover-gated (phases.go: "Clean ghost tables (all paths)"),
	// so it was reachable by any supported install/upgrade.
	//
	//	UNKNOWN_FOREIGN_FIREWALL_STATE MUST NEVER BE DELETED AS GHOST STATE.
	//
	// Class 1 now uses the SAME classify-then-act posture Classes 2 and 3
	// already demonstrate, via the shared ClassifyTable primitive — deliberately
	// not a fourth cleanup model.
	for _, gt := range ghostTables {
		switch ClassifyTable(exec, gt.family, gt.table) {
		case TableClassAbsent:
			// nothing to do
		case TableClassEmpty:
			if err := exec.NftDeleteTable(gt.family, gt.table); err != nil {
				log.Warn("delete ghost table %s %s: %v", gt.family, gt.table, err)
			} else {
				log.Info("removed ghost table: %s %s (empty skeleton)", gt.family, gt.table)
			}
		case TableClassPopulated:
			// Ownership is not established by the table name. A populated table
			// under a Class-1 name is foreign-or-unknown and is PRESERVED.
			log.Warn("Populated '%s %s' table present — NOT removed (foreign or unattributed ownership).", gt.family, gt.table)
			log.Warn("  It holds rules this installer did not create and cannot attribute. If it is a")
			log.Warn("  stale skeleton you want gone, remove it deliberately: nft delete table %s %s", gt.family, gt.table)
		case TableClassUnknown:
			// Observation failure is never permission to delete, AND it must not
			// be reported as a clean cleanup: log.Warn feeds the installer's
			// warnCount, so the summary says "with N warning" rather than
			// claiming success for a check that never completed.
			log.Warn("Could not classify '%s %s' (nft read failed) — PRESERVED.", gt.family, gt.table)
			log.Warn("  Cleanup safety for this table is UNVERIFIED; it was left untouched by design.")
		}
	}

	// Class 2 — ip raw / ip6 raw, classify-empty (PR-A). An empty raw table is
	// an iptables-nft skeleton; a populated one holds operator/kernel NOTRACK
	// rules and must be preserved.
	for _, rt := range rawGhostTables {
		if !exec.NftTableExists(rt.family, rt.table) {
			continue
		}
		if !TableIsEmpty(exec, rt.family, rt.table) {
			log.Warn("preserving populated %s %s (operator/kernel content, e.g. NOTRACK) — not an empty iptables-nft skeleton", rt.family, rt.table)
			continue
		}
		if err := exec.NftDeleteTable(rt.family, rt.table); err != nil {
			log.Warn("delete empty raw ghost table %s %s: %v", rt.family, rt.table, err)
		} else {
			log.Info("removed empty raw ghost skeleton: %s %s", rt.family, rt.table)
		}
	}

	// Class 3 — inet filter, classify-empty + explicit override (PR-B). Mirrors
	// the CVE-2025-NFTBAN-001 detect guard (detect/cve_inet_filter.go) and the
	// DEB/RPM scriptlets: an empty/default skeleton is removed (it would shadow
	// nftban blocking); a populated operator-owned table is PRESERVED and warned,
	// never auto-deleted — unless NFTBAN_ALLOW_REMOVE_INET_FILTER=1 authorises a
	// deliberate, logged high-risk removal. The detect phase already classified
	// this table earlier in the pipeline; this re-classification keeps the two
	// paths in agreement so cleanup cannot destroy what detect preserved.
	cleanInetFilter(exec, log)

	// NOTE: Do NOT clean inet nftban_install_emergency here.
	// Its lifecycle is managed by InjectEmergencySSH / RemoveEmergencySSH
	// in sshguard.go — phaseSwitch controls when it's safe to remove.
}

// cleanInetFilter applies the classify-empty + override policy to the
// `inet filter` table (v1.164 PR-B). See CleanGhostTables Class 3.
func cleanInetFilter(exec executor.Executor, log *logging.Logger) {
	if !exec.NftTableExists("inet", "filter") {
		return
	}

	if TableIsEmpty(exec, "inet", "filter") {
		if err := exec.NftDeleteTable("inet", "filter"); err != nil {
			log.Warn("delete empty inet filter skeleton: %v", err)
		} else {
			log.Info("removed default accept-all inet filter skeleton (CVE-2025-NFTBAN-001 guard)")
		}
		return
	}

	// Populated / operator-owned. Default: NEVER delete. Explicit opt-in via
	// NFTBAN_ALLOW_REMOVE_INET_FILTER=1 authorises a high-risk removal, matching
	// the detect guard and the deb/rpm scriptlets verbatim.
	if exec.Getenv(inetFilterOverrideEnv) == "1" {
		if err := exec.NftDeleteTable("inet", "filter"); err != nil {
			log.Warn("delete populated inet filter (override): %v", err)
			return
		}
		log.Warn("HIGH-RISK: removed a POPULATED operator-owned 'inet filter' table because %s=1 was set (explicit opt-in).", inetFilterOverrideEnv)
		log.Warn("Any firewall rules that table held are now gone. This action was deliberate and is logged here for audit.")
		return
	}

	log.Warn("Populated 'inet filter' table present — NOT removed (operator-owned).")
	log.Warn("It may shadow nftban blocking (CVE-2025-NFTBAN-001). If it is the distro")
	log.Warn("default, run: nft delete table inet filter   (then: nftban firewall reload)")
}
