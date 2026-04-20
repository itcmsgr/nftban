// =============================================================================
// NFTBan v1.73 - Installer Conflict Detection (PR-P2-2: thin adapter over extfw)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-detect-conflicts"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Conflicting firewall detection (services + ghost nft tables)"
// meta:inventory.files="internal/installer/detect/conflicts.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// PR-P2-2 unification note:
//
//   This file used to own its own detection surface (service probes +
//   ghost-nft-table parsing). As of PR-P2-2 it is a thin adapter over
//   internal/installer/extfw.Detect(), which is the single source of
//   truth for external-firewall detection across the install, update,
//   and uninstall lifecycle paths.
//
//   The Conflict struct and DetectConflicts()/ConflictNames() API are
//   preserved for backward compatibility with existing consumers
//   (phaseDetect, switchop.DisableConflicts, etc.). Internally, every
//   signal comes from extfw.Detect.
//
// Option A resolution (2026-04-20): /etc/csf/csf.conf is a valid CSF
// signal. Install side now honors it — same as uninstall — so the two
// lifecycle surfaces cannot disagree about whether CSF is present.
//
// =============================================================================
package detect

import (
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/extfw"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// Conflict represents a detected conflicting firewall. One observation
// (service / ghost table / config file) maps to one Conflict. A single
// firewall may produce multiple Conflicts — CSF with both csf.service
// and lfd.service active emits two Conflict entries so the takeover
// path can stop+disable+mask each unit independently.
type Conflict struct {
	Name    string // e.g., "CSF", "UFW", "firewalld", "iptables", "iptables-nft"
	Service string // systemd unit name; empty for non-service observations
	Active  bool   // always true — if it was observed, it's active
}

// DetectConflicts returns the conflict list for the current host.
// Read-only; delegates to extfw.Detect for the underlying signals.
//
// PR-P2-2A: only observations whose Name is in the canonical Active
// list become Conflicts. Observations from informational-only signals
// (e.g. iptables ghost-table alone, which does NOT corroborate to a
// real iptables presence under the Path B rule) are recorded in
// res.Observations for transparency but excluded from the Conflict
// list because they do not classify external authority.
func DetectConflicts(exec executor.Executor, log *logging.Logger) []Conflict {
	res := extfw.Detect(exec, log)

	// Build the set of Names that extfw classified as active.
	activeNames := make(map[extfw.Name]bool, len(res.Active))
	for _, n := range res.Active {
		activeNames[n] = true
	}

	var conflicts []Conflict
	// De-dup by (Name + Service) so that ghost-table + service for the
	// same firewall don't emit duplicate entries with empty Service.
	// Two CSF service observations (csf + lfd) remain distinct because
	// their Service fields differ.
	seen := make(map[string]bool)
	for _, obs := range res.Observations {
		// PR-P2-2A: skip observations whose Name is not in the
		// classified Active set. This prevents ghost-table-alone
		// iptables observations from leaking into the Conflict list
		// on stock Ubuntu hosts.
		if !activeNames[obs.Name] {
			continue
		}
		key := obs.DisplayName() + "|" + obs.Unit
		if seen[key] {
			continue
		}
		seen[key] = true
		conflicts = append(conflicts, Conflict{
			Name:    obs.DisplayName(),
			Service: obs.Unit,
			Active:  true,
		})
	}

	// Logging mirrors the pre-PR-P2-2 shape so CI gates and operator
	// output don't regress.
	if len(conflicts) == 0 {
		log.Detect("conflict", "result", "none")
	} else {
		names := ConflictNames(conflicts)
		log.Detect("conflict", "result", joinNames(names))
		for _, c := range conflicts {
			source := "service"
			if c.Service == "" {
				source = "ghost/file"
			}
			log.Detect("conflict", c.Name, source+" ("+c.Service+")")
		}
	}

	return conflicts
}

// ConflictNames returns a deduplicated list of conflict names,
// preserving the order they appeared in the input slice.
func ConflictNames(conflicts []Conflict) []string {
	seen := make(map[string]bool)
	var names []string
	for _, c := range conflicts {
		if !seen[c.Name] {
			seen[c.Name] = true
			names = append(names, c.Name)
		}
	}
	return names
}

func joinNames(names []string) string {
	if len(names) == 0 {
		return ""
	}
	out := names[0]
	for _, n := range names[1:] {
		out += ", " + n
	}
	return out
}
