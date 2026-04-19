// =============================================================================
// NFTBan v1.100 PR-22 — Uninstall Plan Struct + Renderer
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-uninstall-plan"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-19"
// meta:description="Release-plan struct + contract-language renderer"
// meta:inventory.files="internal/installer/uninstall/plan.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
//
// Per PR-22 contract §"Plan output — contract-language rendering": the
// rendered plan reads like a release contract preview. Every field
// references the frozen V1100 contract row it implements. No debug
// dumps, no implementation-language leakage.
//
// PR-22 scope lock: plan rendering is pure in/pure out. No mutation,
// no I/O beyond Render's io.Writer. The Plan struct is the output of
// BuildPlan; consumers render it once.
//
// =============================================================================
package uninstall

import (
	"encoding/json"
	"fmt"
	"io"
)

// Mode encodes the operator's requested uninstall mode. Corresponds
// directly to the V1100 §4.4 purge/remove table columns.
type Mode string

const (
	ModeRemove         Mode = "remove"           // §4.4 column 1
	ModePurge          Mode = "purge"            // §4.4 column 2 (default purge — preserves operator .conf.local)
	ModePurgeForceDOC  Mode = "purge+force-doc"  // §4.4 column 3 — purge + --force-delete-operator-config
)

// Plan is the complete release-plan preview computed by BuildPlan and
// rendered for the operator. Every field corresponds to a decision
// frozen in V1100_LIFECYCLE_COMPLETION_CONTRACT.md §13.
type Plan struct {
	// SchemaVersion locks the on-wire contract for tooling consumers.
	SchemaVersion string `json:"schema_version"`

	// RequestedMode is one of ModeRemove / ModePurge / ModePurgeForceDOC.
	RequestedMode Mode `json:"requested_mode"`

	// ArtifactPolicy is a one-line description of what the §4.4 row
	// authorises for this mode. Present for operator readability; the
	// authoritative source is the frozen contract table.
	ArtifactPolicy string `json:"artifact_policy"`

	// CurrentAuthority is the 4-state classifier output (nftban /
	// external / none / ambiguous).
	CurrentAuthority CurrentAuthority `json:"current_authority"`

	// DetectedExternal names the external firewall observed, or ""
	// when none. Populated regardless of RestoreRequested so the
	// operator sees the ambient reality.
	DetectedExternal string `json:"detected_external,omitempty"`

	// TargetAuthority names the authority state the plan would produce
	// if a later PR actually executed mutation. Per Q2=C (frozen), the
	// default is AuthorityNone and the restore path is opt-in.
	TargetAuthority CurrentAuthority `json:"target_authority"`

	// RestoreRequested reflects the presence of --restore-prior-authority
	// on the command line.
	RestoreRequested bool `json:"restore_requested"`

	// RestoreAuthorized is true only when RestoreRequested AND
	// PriorState == PriorRecordUsable. This is the PR-22 classifier
	// output; PR-24 enforces it.
	RestoreAuthorized bool `json:"restore_authorized"`

	// PriorState is the 3-state probe result for the prior-authority
	// record. Populated regardless of RestoreRequested so the operator
	// always sees the underlying ambiguity.
	PriorState PriorRecordState `json:"prior_state"`

	// Warnings is the operator-visible list of concerns that do NOT
	// abort the plan but should be surfaced. Example: "restore flag
	// set but no prior-authority record on disk".
	Warnings []string `json:"warnings,omitempty"`

	// PhasesThatWouldMutate lists, in contract language, which later
	// phases would perform mutation if this PR's scope were expanded.
	// PR-22 ships NONE of these — the list is informational.
	PhasesThatWouldMutate []string `json:"phases_that_would_mutate,omitempty"`
}

// PlanSchemaVersion is the current plan wire contract.
const PlanSchemaVersion = "1.100.0"

// BuildPlan assembles a Plan from the read-only classifier + probe
// results + operator flags. Pure function — all inputs, no I/O.
//
// restoreRequested should be set from the presence of the
// --restore-prior-authority flag at call time.
func BuildPlan(mode Mode, auth *ClassifyResult, prior *ProbeResult, restoreRequested bool) *Plan {
	p := &Plan{
		SchemaVersion:     PlanSchemaVersion,
		RequestedMode:     mode,
		ArtifactPolicy:    artifactPolicyFor(mode),
		CurrentAuthority:  auth.State,
		DetectedExternal:  auth.External,
		RestoreRequested:  restoreRequested,
		PriorState:        prior.State,
		RestoreAuthorized: restoreRequested && prior.State == PriorRecordUsable,
	}

	// TargetAuthority — per Q2=C (frozen), default is None; restore is
	// opt-in AND authorized (needs recorded usable prior).
	switch {
	case p.RestoreAuthorized && prior.Record != nil:
		p.TargetAuthority = CurrentAuthority(prior.Record.FirewallType) // e.g. "ufw"
	default:
		p.TargetAuthority = AuthorityNone
	}

	// Operator-visible warnings — surfacing ambiguity is part of the
	// PR-22 contract. PR-24 will enforce these; PR-22 reports them.
	if restoreRequested && prior.State == PriorNoRecord {
		p.Warnings = append(p.Warnings,
			"--restore-prior-authority requested but no prior-authority record exists — PR-24 will refuse this combination")
	}
	if restoreRequested && prior.State == PriorRecordIncomplete {
		p.Warnings = append(p.Warnings,
			"--restore-prior-authority requested but prior-authority record is incomplete/unparseable — PR-24 will refuse this combination")
	}
	if auth.State == AuthorityAmbiguous {
		p.Warnings = append(p.Warnings,
			"current authority is ambiguous — both nftban and an external firewall appear present; operator should resolve before any mutation ships")
	}
	if auth.State == AuthorityNone {
		p.Warnings = append(p.Warnings,
			"no firewall authority detected — uninstall is a no-op on kernel authority; host is already unprotected")
	}

	// Phase inventory — which phases WOULD mutate if executed. PR-22
	// ships none of these. Strings match the PR-22 contract so the
	// scope-boundary block in Render stays literally accurate.
	p.PhasesThatWouldMutate = []string{
		"Switch — flush + remove nftban tables (PR-23)",
		"Configure — disable/mask services, stop timers (PR-23)",
		"Configure — artifact removal per " + string(mode) + " mode (PR-25)",
	}
	if p.RestoreAuthorized {
		p.PhasesThatWouldMutate = append(p.PhasesThatWouldMutate,
			"Switch — external firewall restoration (PR-24, conditional)")
	}
	p.PhasesThatWouldMutate = append(p.PhasesThatWouldMutate,
		"Validate — post-uninstall verification gate (PR-26)")

	return p
}

// artifactPolicyFor returns a one-line description of what the §4.4
// row authorises for the given mode.
func artifactPolicyFor(mode Mode) string {
	switch mode {
	case ModeRemove:
		return "remove: uninstall runtime (binaries/shell/systemd/logrotate); preserve operator state (base config, .conf.local, state dir, history, user/group)"
	case ModePurge:
		return "purge (default): uninstall runtime + base config + state dir + user/group; preserve .conf.local (INV-100-006: no silent operator-config deletion); preserve update history (audit artifact)"
	case ModePurgeForceDOC:
		return "purge + --force-delete-operator-config: same as purge, AND delete .conf.local (only mode that crosses this boundary; explicit destructive-intent flag required)"
	default:
		return "unknown mode: " + string(mode)
	}
}

// Render prints the plan as a contract-language preview. Output is
// stable and reviewable by humans; machine consumers should use JSON.
//
// The scope-boundary block is MANDATORY per PR-22 contract.
func (p *Plan) Render(w io.Writer) {
	fmt.Fprintln(w, "")
	fmt.Fprintln(w, "NFTBan Uninstall — Plan")
	fmt.Fprintln(w, "═══════════════════════════════════════════════════════════════")
	fmt.Fprintln(w, "")

	fmt.Fprintf(w, "  Requested mode              : %s\n", p.RequestedMode)
	fmt.Fprintf(w, "  Artifact policy             : %s\n", p.ArtifactPolicy)
	fmt.Fprintf(w, "  Current authority           : %s\n", p.CurrentAuthority)
	if p.DetectedExternal != "" {
		fmt.Fprintf(w, "  Detected external firewall  : %s\n", p.DetectedExternal)
	}
	fmt.Fprintf(w, "  Target authority            : %s\n", p.TargetAuthority)
	fmt.Fprintf(w, "  Restore requested           : %s\n", yesNo(p.RestoreRequested))
	fmt.Fprintf(w, "  Restore authorized          : %s\n", yesNo(p.RestoreAuthorized))
	fmt.Fprintf(w, "  Prior-authority record      : %s\n", p.PriorState)
	fmt.Fprintln(w, "")

	if len(p.Warnings) > 0 {
		fmt.Fprintln(w, "  Warnings:")
		for _, wmsg := range p.Warnings {
			fmt.Fprintf(w, "    ⚠ %s\n", wmsg)
		}
		fmt.Fprintln(w, "")
	}

	fmt.Fprintln(w, "  Phases that would mutate (NOT IMPLEMENTED in PR-22):")
	for _, ph := range p.PhasesThatWouldMutate {
		fmt.Fprintf(w, "    • %s\n", ph)
	}
	fmt.Fprintln(w, "")

	// MANDATORY scope-boundary block per PR-22 contract.
	fmt.Fprintln(w, "  Scope boundary:")
	fmt.Fprintln(w, "    PR-22 ships detect + plan only. No mutation code exists in")
	fmt.Fprintln(w, "    this release. Running this command does NOT uninstall nftban.")
	fmt.Fprintln(w, "    To plan an actual uninstall in a future release, the later")
	fmt.Fprintln(w, "    PRs in the v1.100 track must land first.")
	fmt.Fprintln(w, "")
}

// JSON returns the plan as pretty-printed JSON for machine consumers.
func (p *Plan) JSON() ([]byte, error) {
	return json.MarshalIndent(p, "", "  ")
}

func yesNo(b bool) string {
	if b {
		return "yes"
	}
	return "no"
}
