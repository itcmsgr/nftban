// SPDX-License-Identifier: MPL-2.0
// =============================================================================
// NFTBan v1.100 — Restore Panel→Firewall Mapping (PR-25 §20)
// =============================================================================
// meta:name="restore_panel_mapping"
// meta:type="package"
// meta:version="1.100.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="PR-25 commit 3A — static panel→firewall mapping per §20. Sparse and conservative: only panels with direct repo-backed authority are mapped. Unmapped panels refuse rather than guessing firewall type. No fallback, no default, no runtime discovery."
// meta:depends="github.com/itcmsgr/nftban/internal/installer/detect"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package restore

import (
	"errors"
	"fmt"

	"github.com/itcmsgr/nftban/internal/installer/detect"
)

// PR-25 intentionally maps only panels with repo-backed authority.
// Unmapped panels refuse rather than guessing firewall type.
//
// Authoritative entries:
//
//   - PanelDirectAdmin → "csf"
//     Evidence: internal/installer/switchop/takeover.go:111 ("DirectAdmin:
//     runs `custombuild/build set csf no` to set csf=no in options.conf")
//     and the DirectAdmin-specific CSF-disarm path at takeover.go:116.
//     DirectAdmin's bundled / canonical native firewall is CSF.
//
// All other panels (CPanel, Plesk, CyberPanel, Hestia, Vesta, CWP,
// InterWorx) are intentionally left unmapped. PR-25 contract §20.3
// forbids fallback paths; an unmapped panel returns ErrUnmappedPanel
// and the dispatcher (commit 4) refuses BEFORE any mutation per §20.2.
//
// Adding a panel to this map requires repo-backed authority — typical /
// inferred / "commonly used" pairings are not sufficient. Wrong
// restoration is worse than refusal: a guessed mapping can disable or
// mutate the wrong authority and violate the lifecycle contract.

// panelToFirewall is the static, compile-time PR-25 panel→firewall
// mapping per §20.1. The map is intentionally sparse.
var panelToFirewall = map[detect.PanelType]string{
	detect.PanelDirectAdmin: "csf",
}

// ErrUnmappedPanel is returned by ResolvePanelFirewall when the supplied
// panel has no authoritative entry in panelToFirewall. Callers must
// refuse before any mutation per §20.2 — there is no fallback.
var ErrUnmappedPanel = errors.New("restore: panel has no PR-25 firewall mapping; refusal required (§20.2)")

// ErrPanelNoneNotMappable is returned by ResolvePanelFirewall when the
// caller passes detect.PanelNone. PanelNone is not a valid panel target
// and must never reach this resolver — the planner already refuses it
// (see TargetPanelNative in target_authority.go).
var ErrPanelNoneNotMappable = errors.New("restore: PanelNone has no firewall mapping (§20.1 key invariant)")

// ErrPanelMappingInvalid is returned when the static map contains an
// output that is not a member of knownFirewallTypes (the §18.2 set used
// for RecordedPrior). This is a code-time invariant: every entry in
// panelToFirewall must validate. ErrPanelMappingInvalid surfaces a
// programmer error in the map itself, not a runtime input problem.
var ErrPanelMappingInvalid = errors.New("restore: panel mapping output is not a known firewall type (§20.1 output validation)")

// ResolvePanelFirewall returns the authorized native firewall for a
// given panel per the PR-25 §20 mapping. There is exactly one path:
//
//  1. panel == detect.PanelNone     → ErrPanelNoneNotMappable
//  2. panel ∈ panelToFirewall       → return mapped value (validated against §18.2)
//  3. panel ∉ panelToFirewall       → ErrUnmappedPanel
//
// No fallback. No default. No heuristic. No live runtime discovery.
//
// The resolver does not mutate, does not call any external command,
// does not read any file or service state. It is a pure function over
// the static map.
func ResolvePanelFirewall(panel detect.PanelType) (string, error) {
	if panel == detect.PanelNone {
		return "", ErrPanelNoneNotMappable
	}
	fwt, ok := panelToFirewall[panel]
	if !ok {
		return "", fmt.Errorf("%w: panel=%q", ErrUnmappedPanel, panel)
	}
	if _, valid := knownFirewallTypes[fwt]; !valid {
		// Programmer error: map entry produced a firewall type that is
		// not a member of the §18.2 known set. Surface as an explicit
		// invariant violation rather than silently returning a value
		// that downstream code (e.g. TargetRecordedPrior) would also
		// reject — this fails closer to the source.
		return "", fmt.Errorf("%w: panel=%q mapped to %q",
			ErrPanelMappingInvalid, panel, fwt)
	}
	return fwt, nil
}
