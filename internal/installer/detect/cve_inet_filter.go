// =============================================================================
// NFTBan v1.161 - CVE-2025-NFTBAN-001 inet-filter guard (Go installer detect)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-detect-cve-inet-filter"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-08"
// meta:description="CVE-2025-NFTBAN-001 inet filter classify-then-act for the Go installer detect phase"
// meta:inventory.files="internal/installer/detect/cve_inet_filter.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars="NFTBAN_ALLOW_REMOVE_INET_FILTER"
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// CVE-2025-NFTBAN-001 — one-source consolidation (INST-CVE-PARITY / A-11)
//
// The package scriptlets (DEB packaging/deb/postinst:38-104, RPM
// packaging/build_nftban.sh:1022-1065, both v1.146 Phase-D) already carry a
// classify-then-act guard on any pre-existing `inet filter` table. The
// source-install path (install.sh -> nftban-installer --source) had no
// equivalent in its detect phase, so a host installed from source got no
// inet-filter classification. This file closes that gap by mirroring the
// shell's exact logic and operator-facing wording inside the Go detect phase.
//
// The DEB/RPM scriptlet guards are NOT replaced — they remain the proven,
// idempotent belt-and-suspenders for the package paths. This is the source-
// path twin, drift-checked against the shell behaviour:
//
//	NONE             — no `inet filter` table present -> no-op.
//	REMOVED          — an empty/skeleton accept-all `inet filter` table was
//	                   deleted (it would shadow nftban blocking).
//	REMOVED_OVERRIDE — a POPULATED operator-owned table was deleted ONLY
//	                   because NFTBAN_ALLOW_REMOVE_INET_FILTER=1 was set
//	                   (explicit, deterministic, logged opt-in).
//	POPULATED        — a populated operator-owned table is present and was
//	                   NOT removed. Warned (may shadow nftban). Non-fatal in
//	                   the detect phase, consistent with the other detect
//	                   steps; the operator-facing remediation runbook is the
//	                   same wording the scriptlets print.
//
// The "is this a rule?" heuristic mirrors the shell grep filter (structural
// lines — table/chain/type/policy/closing-brace/comment — are not rules) and
// internal/installer/extfw/detect.go.
//
// Idempotency: running this after the package scriptlet already removed the
// skeleton observes NONE and is a clean no-op. Running it twice is a no-op.
//
// =============================================================================
package detect

import (
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// inetFilterOverrideEnv is the exact env var the shell scriptlets honour
// (packaging/deb/postinst, packaging/build_nftban.sh). Mirrored verbatim so
// the source path and package paths react identically to the same operator
// opt-in. Setting it to "1" authorises deleting a POPULATED, operator-owned
// `inet filter` table — a high-risk action, kept deterministic and logged.
const inetFilterOverrideEnv = "NFTBAN_ALLOW_REMOVE_INET_FILTER"

// CVEInetFilterVerdict is the classification of the pre-existing
// `inet filter` table, mirroring the single-token verdict the shell
// _nftban_classify_inet_filter function echoes.
type CVEInetFilterVerdict string

const (
	// CVEInetFilterNone — no `inet filter` table present (or nft absent).
	CVEInetFilterNone CVEInetFilterVerdict = "NONE"
	// CVEInetFilterRemoved — empty/skeleton table removed (would shadow nftban).
	CVEInetFilterRemoved CVEInetFilterVerdict = "REMOVED"
	// CVEInetFilterRemovedOverride — populated table removed via explicit opt-in.
	CVEInetFilterRemovedOverride CVEInetFilterVerdict = "REMOVED_OVERRIDE"
	// CVEInetFilterPopulated — populated operator-owned table left in place.
	CVEInetFilterPopulated CVEInetFilterVerdict = "POPULATED"
	// CVEInetFilterUnknown — the table exists but its CONTENTS could not be
	// established, so no classification was reached and nothing was deleted.
	// Deliberately distinct from NONE: "we saw nothing" and "we could not
	// look" authorise different actions, and only one of them authorises a
	// destructive one.
	CVEInetFilterUnknown CVEInetFilterVerdict = "UNKNOWN"
)

// CheckCVEInetFilter classifies any pre-existing `inet filter` table and acts
// per the CVE-2025-NFTBAN-001 guard, mirroring the DEB/RPM scriptlets. It is
// read-only EXCEPT for the documented CVE skeleton removal (and the explicit
// override removal) — it does not otherwise change firewall behaviour.
//
// Non-fatal by contract: it returns a verdict and never aborts the install
// itself. The detect phase logs the verdict and continues, consistent with
// the other detect steps. The empty-skeleton removal is the safe automatic
// action; the populated case is warned, not auto-deleted.
//
// Idempotent: after the package scriptlet (or a prior call) has removed the
// skeleton, the table no longer exists -> NONE -> no-op.
func CheckCVEInetFilter(exec executor.Executor, log *logging.Logger) CVEInetFilterVerdict {
	verdict := classifyAndActInetFilter(exec)

	switch verdict {
	case CVEInetFilterNone:
		log.Detect("cve_inet_filter", "result", "none")
	case CVEInetFilterRemoved:
		log.Detect("cve_inet_filter", "result", "removed")
		// Same wording as the DEB postinst REMOVED branch.
		log.Info("Removed default accept-all inet filter skeleton due to CVE-2025-NFTBAN-001 guard.")
	case CVEInetFilterRemovedOverride:
		log.Detect("cve_inet_filter", "result", "removed_override")
		// Same wording as the DEB postinst REMOVED_OVERRIDE branch.
		log.Warn("HIGH-RISK: removed a POPULATED operator-owned 'inet filter' table because %s=1 was set (explicit opt-in).", inetFilterOverrideEnv)
		log.Warn("Any firewall rules that table held are now gone. This action was deliberate and is logged here for audit.")
	case CVEInetFilterUnknown:
		log.Detect("cve_inet_filter", "result", "unknown")
		log.Warn("An 'inet filter' table is present but its contents could not be read — NOT removed.")
		log.Warn("Classification requires a successful read: a failed observation must never authorise")
		log.Warn("deleting a table. Check: nft list table inet filter")
	case CVEInetFilterPopulated:
		log.Detect("cve_inet_filter", "result", "populated")
		// Same wording as the DEB postinst POPULATED (upgrade) branch: warn,
		// do not auto-delete an operator-owned table. Non-fatal here.
		log.Warn("Populated 'inet filter' table present — NOT removed (operator-owned).")
		log.Warn("It may shadow nftban blocking (CVE-2025-NFTBAN-001). If it is the distro")
		log.Warn("default, run: nft delete table inet filter   (then: nftban firewall reload)")
	}

	return verdict
}

// classifyAndActInetFilter is the pure classify-then-act core, a direct twin
// of the shell _nftban_classify_inet_filter function. Separated from logging
// so it is exercisable in isolation.
func classifyAndActInetFilter(exec executor.Executor) CVEInetFilterVerdict {
	// command -v nft / nft list table inet filter guard. NftTableExists runs
	// `nft list table inet filter` and returns false if nft is absent or the
	// table does not exist — covering both shell guards in one call.
	if !exec.NftTableExists("inet", "filter") {
		return CVEInetFilterNone
	}

	// Count rule lines exactly as the shell does: drop structural lines
	// (table/chain/type/policy/closing-brace/comment) and any blank line; if
	// nothing remains, the table is an empty/default skeleton.
	res := exec.Run("nft", "list", "table", "inet", "filter")
	// The rule count is only evidence if the read SUCCEEDED. A failed nft
	// invocation returns empty stdout, which counts as zero rules, which used
	// to mean "empty skeleton" and authorise deleting the table. That is a
	// destructive action taken on the strength of a measurement that never
	// happened. The existence guard above already proved the table is there,
	// so a failure here is a read failure, not an absence.
	if res.ExitCode != 0 {
		return CVEInetFilterUnknown
	}
	// rc=0 with no output is equally unusable: `nft list table` prints at
	// minimum the table and chain scaffolding for a table it can see.
	if strings.TrimSpace(res.Stdout) == "" {
		return CVEInetFilterUnknown
	}
	if inetFilterRuleCount(res.Stdout) == 0 {
		// Empty/default distro skeleton — remove it (it would shadow nftban).
		_ = exec.NftDeleteTable("inet", "filter")
		return CVEInetFilterRemoved
	}

	// Populated / operator-owned. Default: NEVER delete. Explicit opt-in via
	// NFTBAN_ALLOW_REMOVE_INET_FILTER=1 authorises a high-risk removal.
	if exec.Getenv(inetFilterOverrideEnv) == "1" {
		_ = exec.NftDeleteTable("inet", "filter")
		return CVEInetFilterRemovedOverride
	}

	return CVEInetFilterPopulated
}

// inetFilterRuleCount counts non-structural, non-blank lines in `nft list
// table inet filter` output — the Go equivalent of the shell pipeline:
//
//	grep -vE '^[[:space:]]*(table|chain|type |policy|[}]|#)' | grep -cE '[^[:space:]]'
//
// Structural lines (table/chain/type/policy/closing-brace/comment) and blank
// lines are not rules; anything else is.
func inetFilterRuleCount(out string) int {
	count := 0
	for _, raw := range strings.Split(out, "\n") {
		line := strings.TrimSpace(raw)
		if line == "" {
			continue
		}
		if isInetFilterStructuralLine(line) {
			continue
		}
		count++
	}
	return count
}

// isInetFilterStructuralLine reports whether a trimmed line is structural
// (and therefore not a rule), mirroring the shell grep -vE anchors. The shell
// pattern anchors on leading whitespace then the token; after TrimSpace the
// token sits at the start of the line, so a prefix check is the faithful twin.
// Note the shell uses "type " and "policy" (the space after type matches
// `type filter hook ...`; policy matches `policy accept`/`policy drop`).
func isInetFilterStructuralLine(line string) bool {
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
	}
	return false
}
