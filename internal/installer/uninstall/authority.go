// =============================================================================
// NFTBan v1.100 PR-22 — Uninstall Authority Classifier (Read-Only)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-uninstall-authority"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-19"
// meta:description="4-state authority classifier for uninstall planning"
// meta:inventory.files="internal/installer/uninstall/authority.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// PR-22 scope lock: READ-ONLY classification. This file does not mutate
// kernel, service, or filesystem state. No nft add/flush/delete. No
// systemctl stop/disable. Strictly detection.
//
// =============================================================================
package uninstall

import (
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// CurrentAuthority is one of four mutually exclusive states returned by
// the PR-22 classifier. The three conceptual axes are:
//
//   - does nftban own authority right now (ip nftban table + active daemon)
//   - is an external firewall observable (UFW / firewalld / iptables / CSF)
//   - is the detection result conclusive
//
// per the frozen V1100 contract §4.3 and PR-22 contract §"Authority
// classification".
type CurrentAuthority string

const (
	// AuthorityNFTBan means nftban is authoritative on this host right now.
	AuthorityNFTBan CurrentAuthority = "nftban"

	// AuthorityExternal means an external firewall appears authoritative.
	// Uninstall of nftban in this state is cheap (nothing to remove on
	// the kernel side) but the classifier records which external firewall
	// for the restore-plan renderer downstream.
	AuthorityExternal CurrentAuthority = "external"

	// AuthorityNone means no authoritative firewall is detectable.
	// Uninstall in this state is a no-op on kernel authority.
	AuthorityNone CurrentAuthority = "none"

	// AuthorityAmbiguous means both nftban and external appear present,
	// OR the detection is inconclusive. Classifier returns ambiguity
	// rather than guessing — the plan renderer surfaces the state and
	// the operator decides.
	AuthorityAmbiguous CurrentAuthority = "ambiguous"
)

// ClassifyResult is the full read-only observation returned by Classify.
// Plan renderers consume this rather than re-probing.
type ClassifyResult struct {
	State    CurrentAuthority `json:"state"`
	External string           `json:"external,omitempty"` // ufw / firewalld / iptables / csf / ""
	Notes    []string         `json:"notes,omitempty"`    // human-readable rationale for the classification
}

// Classify inspects the current host state and returns the 4-state
// classification plus detection notes. It is READ-ONLY and idempotent.
//
// Detection inputs (all read-only):
//   - exec.NftTableExists("ip", "nftban")  — is nftban authoritative
//   - exec.ServiceActive("nftband.service") — is the daemon up
//   - exec.ServiceActive("ufw")             — is UFW up
//   - exec.ServiceActive("firewalld.service") — is firewalld up
//   - exec.Run("iptables-save")             — are iptables rules present
//   - exec.FileExists("/etc/csf/csf.conf")  — is CSF installed
//
// The classifier does NOT: invoke nft add/flush/delete, run systemctl
// stop/disable, read any config file beyond the FileExists probe, or
// write anything.
func Classify(exec executor.Executor, log *logging.Logger) *ClassifyResult {
	res := &ClassifyResult{}

	nftbanTable := exec.NftTableExists("ip", "nftban")
	nftbandActive := exec.ServiceActive("nftband.service")
	nftbanPresent := nftbanTable && nftbandActive
	// "partial" means one side of nftban is present but not the other —
	// table without daemon, or daemon without table. Either way the
	// host is in a mid-install / mid-uninstall / crashed state. The
	// classifier must not overstate certainty on top of that (audit D.1).
	nftbanPartial := (nftbanTable || nftbandActive) && !nftbanPresent

	ext := detectExternalAuthority(exec)
	res.External = ext

	extPresent := ext != ""

	switch {
	case nftbanPresent && !extPresent:
		res.State = AuthorityNFTBan
		res.Notes = append(res.Notes,
			"ip nftban table + nftband.service both present; no external firewall observed")
	case nftbanPresent && extPresent:
		res.State = AuthorityAmbiguous
		res.Notes = append(res.Notes,
			"both nftban (table + daemon) and external firewall ("+ext+") observable; uninstall plan cannot assume who owns the firewall")
	case nftbanPartial && extPresent:
		// Partial-nftban + external: a later PR's mutation logic would
		// be wrong to silently remove nftban artifacts AND silently let
		// external take over, because the operator may have expected
		// one of the other paths. Surface the ambiguity.
		res.State = AuthorityAmbiguous
		res.Notes = append(res.Notes,
			"partial nftban state (table OR daemon present, not both) AND external firewall ("+ext+") observable; host is in an indeterminate transition — operator must resolve before any mutation")
	case !nftbanPresent && !nftbanPartial && extPresent:
		res.State = AuthorityExternal
		res.Notes = append(res.Notes,
			"no nftban authority (no table AND no daemon); external firewall ("+ext+") appears authoritative")
	case !nftbanPresent && !extPresent:
		// Distinguish "nothing authoritative" from "detection failed".
		// If both probes returned a negative answer from live exec
		// calls, that's a real NONE. If probes failed to execute at
		// all, that's ambiguity.
		if exec == nil {
			res.State = AuthorityAmbiguous
			res.Notes = append(res.Notes, "executor unavailable; classification inconclusive")
		} else {
			res.State = AuthorityNone
			res.Notes = append(res.Notes,
				"no nftban authority AND no external firewall detected; host is unprotected by any firewall authority")
		}
	}

	if nftbanTable && !nftbandActive {
		res.Notes = append(res.Notes,
			"ip nftban table present but nftband.service inactive — may indicate a half-installed or recently-stopped nftban")
	}
	if !nftbanTable && nftbandActive {
		res.Notes = append(res.Notes,
			"nftband.service active but ip nftban table missing — may indicate a daemon without kernel authority")
	}

	log.Debug("uninstall/authority: state=%s external=%s", res.State, res.External)
	return res
}

// detectExternalAuthority returns the name of the external firewall
// that currently appears authoritative, or "" if none detected.
// Order is deterministic — first positive wins.
func detectExternalAuthority(exec executor.Executor) string {
	// UFW (Debian/Ubuntu) — check service active + status output non-empty.
	if exec.ServiceActive("ufw") {
		return "ufw"
	}
	// firewalld (RHEL family)
	if exec.ServiceActive("firewalld.service") || exec.ServiceActive("firewalld") {
		return "firewalld"
	}
	// iptables direct — active rules without nftban-owned tables imply
	// iptables is the authority. We check iptables-legacy and iptables-nft
	// ghost tables (the pattern already used by detect.DetectConflicts).
	if hasActiveIptables(exec) {
		return "iptables"
	}
	// CSF — detect by config file presence (CSF is a shell-wrapper around
	// iptables, so its "service" is not always systemd-managed)
	if exec.FileExists("/etc/csf/csf.conf") {
		return "csf"
	}
	return ""
}

// hasActiveIptables reports whether non-nftban iptables rules appear
// present. READ-ONLY: uses `iptables-save` / `ip6tables-save` to count
// rule lines. No mutation.
func hasActiveIptables(exec executor.Executor) bool {
	// A practical heuristic: if iptables-save produces more than the
	// empty "# Generated by" preamble (≤ 5 lines), something is holding
	// rules. Nftban itself does not use legacy iptables, so any rules
	// here indicate external authority.
	r := exec.Run("iptables-save")
	if r.ExitCode != 0 {
		return false
	}
	return countNonCommentLines(r.Stdout) >= 3
}

// countNonCommentLines returns the number of lines in s that are neither
// empty nor iptables/ip6tables comments.
func countNonCommentLines(s string) int {
	var n int
	start := 0
	for i := 0; i <= len(s); i++ {
		if i == len(s) || s[i] == '\n' {
			line := s[start:i]
			start = i + 1
			// trim left whitespace
			j := 0
			for j < len(line) && (line[j] == ' ' || line[j] == '\t') {
				j++
			}
			if j >= len(line) {
				continue
			}
			if line[j] == '#' || line[j] == '*' || line[j] == ':' {
				// skip iptables-save preamble lines
				continue
			}
			n++
		}
	}
	return n
}
