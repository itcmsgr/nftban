// =============================================================================
// NFTBan v1.99 PR-16 — Update Plan + Version Detection
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-update-plan"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-19"
// meta:description="Update trigger: current→target version detection + plan struct"
// meta:inventory.files="internal/installer/update/plan.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
//
// PR-16 closes G3-U2 (current→target version detection) and G3-U3 (--dry-run).
//
// INV-U-001 reminder: update is a BOUNDED TRIGGER into the rebuild/lifecycle
// pipeline — not a parallel execution path. This package only provides the
// PLAN structure and VERSION DETECTION for the update trigger. Apply work
// (PR-18) routes through the existing rebuild semantics.
//
// =============================================================================

package update

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// Plan describes the intended update transition. Produced by `nftban-installer
// --mode=upgrade --dry-run`; consumed by the shell update dispatcher for
// lifecycle recording and by CI for the G3-U2/U3 assertions.
//
// PR-16 scope: Plan is purely descriptive. Apply logic lands in PR-18.
type Plan struct {
	// SchemaVersion locks the on-wire contract. Bump on any breaking change.
	SchemaVersion string `json:"schema_version"`

	// CurrentVersion is the version currently installed on the host,
	// read from /usr/lib/nftban/VERSION (or the canonical lookup chain
	// documented in cli/lib/nftban/lib/version.sh).
	CurrentVersion string `json:"current_version"`

	// TargetVersion is the version that would be installed if apply ran.
	// For source installs this is the VERSION file in the source tree;
	// for package installs this is the package's Version field.
	TargetVersion string `json:"target_version"`

	// InstallOrigin is "rpm", "deb", or "source" — determines which apply
	// path would execute in PR-18.
	InstallOrigin string `json:"install_origin"`

	// NeedsUpdate is true when CurrentVersion != TargetVersion. False means
	// a run would be a bounded no-op per G3-U16 (idempotency).
	NeedsUpdate bool `json:"needs_update"`

	// Preflight records the preflight result that was folded into this plan.
	Preflight *PreflightResult `json:"preflight"`

	// Warnings are non-fatal notes the operator should see (e.g. "current
	// state is DEGRADED — update will proceed with caution").
	Warnings []string `json:"warnings,omitempty"`

	// Actions is a human-oriented list of what apply would do. PR-16 keeps
	// this abstract ("reuse rebuild pipeline"); PR-18 fills in concrete
	// steps.
	Actions []string `json:"actions,omitempty"`
}

// PlanSchemaVersion is the current wire contract for Plan. Consumers should
// reject plans with unexpected schema versions.
const PlanSchemaVersion = "1.99.0"

// DetectVersions reads the current installed version from the FHS VERSION
// file and the target version from the source-tree VERSION (for source
// installs) or from the package metadata path.
//
// For PR-16 we support source-install detection; package-install target
// detection is handled in PR-17.
func DetectVersions(exec executor.Executor, sourceDir string, log *logging.Logger) (current, target string, err error) {
	current = readCurrentVersion(exec, log)

	// Source install: target VERSION lives at <sourceDir>/VERSION.
	if sourceDir != "" {
		tPath := filepath.Join(sourceDir, "VERSION")
		if data, rErr := exec.ReadFile(tPath); rErr == nil {
			target = strings.TrimSpace(string(data))
		} else {
			log.Debug("update: source VERSION not readable at %s: %v", tPath, rErr)
		}
	}

	if current == "" {
		return current, target, fmt.Errorf("update: cannot detect current version (no VERSION file)")
	}
	if target == "" {
		// PR-16: target detection for package installs lands in PR-17.
		// For now, missing target is non-fatal — the plan records it and
		// the preflight flags it as a warning.
		log.Info("update: target version not yet detected (package-install detection lands in PR-17)")
	}
	return current, target, nil
}

// readCurrentVersion implements the same lookup chain as
// cli/lib/nftban/lib/version.sh (/usr/lib/nftban/VERSION first, then
// ${NFTBAN_ROOT}/VERSION). We keep this Go-side implementation simple; the
// shell entry point guarantees VERSION is present before calling us.
func readCurrentVersion(exec executor.Executor, log *logging.Logger) string {
	for _, p := range []string{
		"/usr/lib/nftban/VERSION",
		"/etc/nftban/VERSION", // legacy fallback
	} {
		if !exec.FileExists(p) {
			continue
		}
		data, err := exec.ReadFile(p)
		if err != nil {
			log.Debug("update: read %s failed: %v", p, err)
			continue
		}
		return strings.TrimSpace(string(data))
	}
	return ""
}

// Render prints a human-readable plan. Used by --dry-run text mode.
func (p *Plan) Render(w io.Writer) {
	fmt.Fprintln(w, "")
	fmt.Fprintln(w, "NFTBan Update — Plan")
	fmt.Fprintln(w, "════════════════════════════════════════════════════════════")
	fmt.Fprintln(w, "")
	fmt.Fprintf(w, "  Current version : %s\n", displayVersion(p.CurrentVersion))
	fmt.Fprintf(w, "  Target version  : %s\n", displayVersion(p.TargetVersion))
	fmt.Fprintf(w, "  Install origin  : %s\n", displayString(p.InstallOrigin))
	fmt.Fprintf(w, "  Needs update    : %v\n", p.NeedsUpdate)
	fmt.Fprintln(w, "")

	if p.Preflight != nil {
		fmt.Fprintln(w, "  Preflight:")
		for _, c := range p.Preflight.Checks {
			mark := "✓"
			if !c.Passed {
				mark = "✗"
			}
			fmt.Fprintf(w, "    %s %s", mark, c.Name)
			if c.Detail != "" {
				fmt.Fprintf(w, " — %s", c.Detail)
			}
			fmt.Fprintln(w)
		}
		fmt.Fprintln(w, "")
	}

	if len(p.Warnings) > 0 {
		fmt.Fprintln(w, "  Warnings:")
		for _, wmsg := range p.Warnings {
			fmt.Fprintf(w, "    ⚠ %s\n", wmsg)
		}
		fmt.Fprintln(w, "")
	}

	if len(p.Actions) > 0 {
		fmt.Fprintln(w, "  Actions (dry-run — no mutation):")
		for _, a := range p.Actions {
			fmt.Fprintf(w, "    • %s\n", a)
		}
		fmt.Fprintln(w, "")
	}
}

// JSON returns the plan as pretty-printed JSON. Used by --dry-run --json.
func (p *Plan) JSON() ([]byte, error) {
	return json.MarshalIndent(p, "", "  ")
}

// BuildPlan assembles a Plan from a preflight result + detected versions.
// It is the single constructor for Plan so that SchemaVersion and default
// fields are always set consistently.
func BuildPlan(pre *PreflightResult, current, target, origin string) *Plan {
	p := &Plan{
		SchemaVersion:  PlanSchemaVersion,
		CurrentVersion: current,
		TargetVersion:  target,
		InstallOrigin:  origin,
		NeedsUpdate:    current != target && target != "",
		Preflight:      pre,
	}
	// Authoritative architectural reminder (INV-U-001) — render it so the
	// operator always sees the model, not just the outcome.
	p.Actions = append(p.Actions,
		"update reuses the rebuild/lifecycle pipeline (INV-U-001)",
		"no parallel staging / validation / switch logic is executed",
	)
	if pre != nil && !pre.Passed {
		p.Warnings = append(p.Warnings, "preflight failed — apply would abort")
	}
	if target == "" {
		p.Warnings = append(p.Warnings,
			"target version not detected (package-install target detection lands in PR-17)")
	}
	return p
}

// displayVersion returns a placeholder for empty versions so the rendered
// table doesn't print blank cells that look like a bug.
func displayVersion(v string) string {
	if v == "" {
		return "(not detected)"
	}
	return v
}

func displayString(s string) string {
	if s == "" {
		return "(unknown)"
	}
	return s
}

// WriteJSONToFile writes the plan as JSON to dst. Caller is responsible for
// destination path safety. Intended for history/audit records, NOT for
// operator-visible files.
func (p *Plan) WriteJSONToFile(dst string) error {
	data, err := p.JSON()
	if err != nil {
		return err
	}
	return os.WriteFile(filepath.Clean(dst), data, 0600) // #nosec G306 -- history file
}
