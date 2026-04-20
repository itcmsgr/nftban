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
	"github.com/itcmsgr/nftban/internal/installer/extfw"
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
//   - extfw.Detect(exec, log)               — unified external-firewall
//     detection (see internal/installer/extfw — single source of truth
//     for UFW / firewalld / iptables / CSF probing across install,
//     update, and uninstall lifecycle paths; PR-P2-2)
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

	// PR-P2-2: route external-firewall detection through the unified
	// extfw.Detect — single source of truth shared with install-side
	// and update-side consumers.
	extRes := extfw.Detect(exec, log)
	var ext string
	extPresent := false
	extAmbiguous := false
	switch {
	case extRes.Ambiguous:
		// Multiple distinct external firewalls active simultaneously —
		// do NOT silently collapse via precedence. Surface the list so
		// the plan can show it to the operator.
		extAmbiguous = true
		extPresent = true
		names := make([]string, 0, len(extRes.Active))
		for _, n := range extRes.Active {
			names = append(names, string(n))
		}
		ext = joinStrings(names, "+")
	case extRes.Authoritative != extfw.NameNone:
		ext = string(extRes.Authoritative)
		extPresent = true
	default:
		ext = ""
	}
	res.External = ext

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
	case nftbanPartial && !extPresent:
		// PR-22A audit fix (INV-U-AMBIG-PARTIAL): partial nftban WITHOUT
		// external must NOT collapse to AuthorityNone. The kernel still
		// holds an ip nftban table OR the daemon is still up — calling
		// that "no authority" would let a later PR's release logic skip
		// kernel cleanup of an orphan table. Classify as Ambiguous so
		// PR-23/24 must explicitly acknowledge the transition state
		// before taking any action.
		res.State = AuthorityAmbiguous
		res.Notes = append(res.Notes,
			"partial nftban state (table OR daemon present, not both) AND no external firewall observable; kernel still holds nftban artifacts — host is in an indeterminate transition, operator must resolve before any mutation")
	case !nftbanPresent && !nftbanPartial && extAmbiguous:
		// PR-P2-2: multiple distinct external firewalls are active.
		// The host has an internally-inconsistent takeover state and
		// cannot be safely uninstalled/restored without operator
		// intervention. Do NOT silently pick one via precedence.
		res.State = AuthorityAmbiguous
		res.Notes = append(res.Notes,
			"no nftban authority, but multiple external firewalls appear active simultaneously ("+ext+"); operator must resolve which one owns authority before any mutation")
	case !nftbanPresent && !nftbanPartial && extPresent:
		res.State = AuthorityExternal
		res.Notes = append(res.Notes,
			"no nftban authority (no table AND no daemon); external firewall ("+ext+") appears authoritative")
	case !nftbanPresent && !nftbanPartial && !extPresent:
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

// joinStrings concatenates parts with sep. Local helper used to render
// the multi-external-active name list; stdlib strings.Join would
// require an import that's not otherwise needed in this file.
func joinStrings(parts []string, sep string) string {
	if len(parts) == 0 {
		return ""
	}
	out := parts[0]
	for _, p := range parts[1:] {
		out += sep + p
	}
	return out
}
