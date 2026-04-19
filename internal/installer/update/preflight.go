// =============================================================================
// NFTBan v1.99 PR-16 — Update Preflight
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-update-preflight"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-19"
// meta:description="Update trigger preflight — authority, service, artifact, deps"
// meta:inventory.files="internal/installer/update/preflight.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// PR-16 closes G3-U4 (preflight enforcement).
//
// Preflight aborts the update BEFORE any mutation if any critical
// precondition is not met:
//
//   P-1 authority       nftban must currently own firewall authority
//   P-2 service         nftband.service must be running (allow DEGRADED
//                       with a warning; abort only on DOWN)
//   P-3 artifact        /usr/lib/nftban/VERSION must exist (we must know
//                       what "current" is before transitioning)
//   P-4 dependencies    nft binary must be present and executable
//   P-5 state locality  no stale in-progress install_state marker
//
// This aligns with INV-U-002 (rollbackability) — we refuse to enter a
// transition we cannot safely reason about.
//
// =============================================================================

package update

import (
	"github.com/itcmsgr/nftban/internal/installer/authority"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// PreflightCheck is one named precondition.
type PreflightCheck struct {
	Name   string `json:"name"`
	Passed bool   `json:"passed"`
	Detail string `json:"detail,omitempty"`
	// Severity is "critical" (abort) or "warning" (continue with warning).
	// Only "critical" failures contribute to Passed=false at the result level.
	Severity string `json:"severity"`
}

// PreflightResult is the aggregate outcome.
type PreflightResult struct {
	Passed bool             `json:"passed"`
	Checks []PreflightCheck `json:"checks"`
}

// Preflight runs all update preconditions and returns an aggregate result.
// Called by phaseDetect when cfg.mode == "upgrade".
//
// The function is READ-ONLY. It must never mutate host state.
//
// origin is the operator-declared install origin ("rpm", "deb", "source",
// or ""). PR-17 uses it for the new P-7 coherence check.
func Preflight(exec executor.Executor, log *logging.Logger, origin string) *PreflightResult {
	res := &PreflightResult{Passed: true}

	// P-1 authority — PR-22B uses the canonical predicate from the
	// authority package. Requires table + chain + active daemon — a
	// weaker check (table-only) used to let a half-installed host pass
	// preflight and then behave inconsistently under apply.
	{
		ok := authority.IsNftbanAuthoritative(exec)
		c := PreflightCheck{
			Name:     "authority_nftban",
			Passed:   ok,
			Severity: "critical",
		}
		if !ok {
			c.Detail = "nftban not authoritative (requires ip nftban table + input chain + active nftband.service) — INV-U-003"
			res.Passed = false
		}
		res.Checks = append(res.Checks, c)
		logCheck(log, c)
	}

	// P-2 service — nftband.service must be at least degraded/running.
	{
		active := exec.ServiceActive("nftband.service")
		c := PreflightCheck{
			Name:     "service_nftband_active",
			Passed:   active,
			Severity: "critical",
		}
		if !active {
			c.Detail = "nftband.service not active — update cannot verify post-state safely"
			res.Passed = false
		}
		res.Checks = append(res.Checks, c)
		logCheck(log, c)
	}

	// P-3 artifact — VERSION file must be readable. Without it we cannot
	// identify the current version, so we cannot reason about the transition.
	{
		has := exec.FileExists("/usr/lib/nftban/VERSION")
		c := PreflightCheck{
			Name:     "artifact_version_file",
			Passed:   has,
			Severity: "critical",
		}
		if !has {
			c.Detail = "/usr/lib/nftban/VERSION missing — cannot identify current version"
			res.Passed = false
		}
		res.Checks = append(res.Checks, c)
		logCheck(log, c)
	}

	// P-4 dependencies — nft must be executable.
	{
		r := exec.Run("sh", "-c", "command -v nft >/dev/null 2>&1")
		ok := r.ExitCode == 0
		c := PreflightCheck{
			Name:     "dependency_nft",
			Passed:   ok,
			Severity: "critical",
		}
		if !ok {
			c.Detail = "nft binary not found in PATH"
			res.Passed = false
		}
		res.Checks = append(res.Checks, c)
		logCheck(log, c)
	}

	// P-5 state locality — if an install_state marker shows an in-progress
	// install, we refuse to start an update on top of it. Let the operator
	// resolve the prior state first.
	{
		stale := isStaleInProgress(exec)
		c := PreflightCheck{
			Name:     "state_no_stale_in_progress",
			Passed:   !stale,
			Severity: "warning", // not critical — warn but allow override
		}
		if stale {
			c.Detail = "install_state marks a prior run as in-progress — investigate before apply"
		}
		res.Checks = append(res.Checks, c)
		logCheck(log, c)
	}

	// P-6 (PR-17) rebuild recovery available — the planning-only check
	// that tells apply (PR-18) whether a clean rollback is reachable.
	// We do NOT execute recovery here; we just report whether the
	// prerequisites exist: terminal prior state + ip nftban table + nft
	// binary. If any is missing, apply must treat rollback as
	// operator-assisted rather than automatic (INV-U-002).
	{
		ok := rebuildRecoveryAvailable(exec)
		c := PreflightCheck{
			Name:     "rebuild_recovery_available",
			Passed:   ok,
			Severity: "warning",
		}
		if !ok {
			c.Detail = "rebuild recovery may require operator intervention on failure — review before apply"
		}
		res.Checks = append(res.Checks, c)
		logCheck(log, c)
	}

	// P-7 (PR-17) install origin coherent — the declared --rpm / --deb /
	// --source flag must match the host's actual install origin. A
	// mismatch (e.g. --rpm on a DEB host) is a hard warning: apply would
	// route through the wrong delivery model. PR-17 detects this early.
	{
		declared := origin
		detected := DetectInstallOrigin(exec, log)
		coherent := declared == "" || detected == "" || declared == detected
		c := PreflightCheck{
			Name:     "install_origin_coherent",
			Passed:   coherent,
			Severity: "warning",
		}
		if !coherent {
			c.Detail = "declared origin (" + declared + ") does not match detected origin (" + detected + ")"
		}
		res.Checks = append(res.Checks, c)
		logCheck(log, c)
	}

	return res
}

// rebuildRecoveryAvailable reports whether the prerequisites for automatic
// rollback via rebuild recovery are present:
//
//   - the prior install_state is terminal (COMMITTED / DEGRADED / FAILED_*)
//   - ip nftban table exists (authority held)
//   - nft binary is present (handled by P-4; we still check here so this
//     predicate is self-contained for callers outside the full preflight)
//
// PR-17 scope: this is metadata only. PR-18 will wire it into the apply
// path via INV-U-002.
func rebuildRecoveryAvailable(exec executor.Executor) bool {
	if !exec.NftTableExists("ip", "nftban") {
		return false
	}
	if r := exec.Run("sh", "-c", "command -v nft >/dev/null 2>&1"); r.ExitCode != 0 {
		return false
	}
	// Prior state must be readable OR absent (absent = fresh recovery is
	// fine). If present but non-terminal (in-progress), recovery is not
	// clean.
	const p = "/var/lib/nftban/state/install_state"
	if !exec.FileExists(p) {
		return true
	}
	data, err := exec.ReadFile(p)
	if err != nil {
		return false
	}
	s := trim(string(data))
	if s == "" {
		return true
	}
	// Same terminal-state list as isStaleInProgress but inverted.
	switch s {
	case "COMMITTED", "DEGRADED",
		"FAILED_SSH_UNKNOWN", "FAILED_AUTHORITY_ABORT", "FAILED_RENDER",
		"FAILED_REBUILD", "FAILED_NO_FIREWALL", "FAILED_TAKEOVER":
		return true
	}
	return false
}

// BuildRecoveryPlan derives the PR-17 recovery metadata from exec state.
// Planning-only: no mutation, no recovery execution.
func BuildRecoveryPlan(exec executor.Executor) *RecoveryPlan {
	r := &RecoveryPlan{
		Mechanism: "rebuild",
	}
	r.Available = rebuildRecoveryAvailable(exec)
	const p = "/var/lib/nftban/state/install_state"
	if !exec.FileExists(p) {
		r.Notes = append(r.Notes,
			"no prior install_state — a fresh recovery is clean (no rollback target)")
	} else {
		data, err := exec.ReadFile(p)
		if err == nil {
			r.Notes = append(r.Notes,
				"prior install_state = "+trim(string(data)))
		}
	}
	if !r.Available {
		r.Notes = append(r.Notes,
			"preconditions for automatic rollback unmet — apply will require operator assist on failure")
	}
	return r
}

// isStaleInProgress returns true if install_state exists AND is not a
// terminal state (COMMITTED / DEGRADED / FAILED_*). We treat an in-progress
// marker as a caution.
func isStaleInProgress(exec executor.Executor) bool {
	const p = "/var/lib/nftban/state/install_state"
	if !exec.FileExists(p) {
		return false
	}
	data, err := exec.ReadFile(p)
	if err != nil {
		return false
	}
	s := trim(string(data))
	switch s {
	case "", "COMMITTED", "DEGRADED",
		"FAILED_SSH_UNKNOWN", "FAILED_AUTHORITY_ABORT", "FAILED_RENDER",
		"FAILED_REBUILD", "FAILED_NO_FIREWALL", "FAILED_TAKEOVER":
		return false
	}
	return true
}

// trim is a tiny wrapper — avoids importing strings just for TrimSpace
// everywhere in this file.
func trim(s string) string {
	start := 0
	end := len(s)
	for start < end && isSpace(s[start]) {
		start++
	}
	for end > start && isSpace(s[end-1]) {
		end--
	}
	return s[start:end]
}

func isSpace(b byte) bool {
	return b == ' ' || b == '\t' || b == '\n' || b == '\r'
}

func logCheck(log *logging.Logger, c PreflightCheck) {
	if c.Passed {
		log.Debug("update-preflight: %-28s PASS", c.Name)
		return
	}
	if c.Severity == "critical" {
		log.Warn("update-preflight: %-28s FAIL — %s", c.Name, c.Detail)
	} else {
		log.Info("update-preflight: %-28s warn — %s", c.Name, c.Detail)
	}
}
