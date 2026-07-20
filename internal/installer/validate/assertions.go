// =============================================================================
// NFTBan v1.73 - Installer Post-Install Assertions
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-validate-assertions"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Post-install kernel + service + state assertions"
// meta:inventory.files="internal/installer/validate/assertions.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package validate

import (
	"context"
	"fmt"
	"os"
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/fhs"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/panelfw"
	"github.com/itcmsgr/nftban/internal/installer/payload"
	lr "github.com/itcmsgr/nftban/internal/logretention"
)

// AssertionResult holds the outcome of a single assertion.
type AssertionResult struct {
	Name   string
	Passed bool
	Detail string
}

// AssertionOpts carries policy + dependency injections that downstream
// assertions need. New in PR26.2 to thread the panel-survival policy
// through without forcing every existing caller to construct one.
//
// Zero-value AssertionOpts is safe: PanelPolicy defaults to
// panelfw.DefaultPolicy() (RequirePanelSuccess=true, AllowPanelAbsent=true,
// OperatorDisabled=false) when unset, and PanelAdapters defaults to
// the global registry (currently empty in PR26.2).
type AssertionOpts struct {
	// PanelPolicy controls how the panel-survival assertion converts
	// adapter outcomes into a pass/fail verdict. PR26.3+ wires this
	// from the operator's --no-panel flag and any future policy
	// flags through the installer's globalPhaseData.
	PanelPolicy panelfw.PanelPolicy

	// PanelAdapters is an optional adapter slice override. When nil,
	// the assertion uses panelfw.RegisteredAdapters(). Tests pass a
	// fixture-controlled slice (typically containing FakePanelAdapter)
	// to exercise the framework without touching the global registry.
	PanelAdapters []panelfw.PanelAdapter

	// panelPolicySet records whether the caller explicitly set
	// PanelPolicy. Internal — used by RunAssertionsWithOpts to
	// decide between caller-provided and DefaultPolicy(). Exposed
	// via WithPanelPolicy.
	panelPolicySet bool
}

// WithPanelPolicy returns a copy of opts with PanelPolicy set and the
// internal "set" flag enabled, so RunAssertionsWithOpts honors the
// override even when the caller passes a zero-value PanelPolicy.
func (o AssertionOpts) WithPanelPolicy(p panelfw.PanelPolicy) AssertionOpts {
	o.PanelPolicy = p
	o.panelPolicySet = true
	return o
}

// RunAssertions performs all post-install assertions with default
// AssertionOpts (panelfw.DefaultPolicy, empty adapter override).
// Equivalent to RunAssertionsWithOpts(exec, sshPort, log, AssertionOpts{}).
//
// Existing callers stay source-compatible. Production paths that need
// to feed an operator-derived policy use RunAssertionsWithOpts.
func RunAssertions(exec executor.Executor, sshPort int, log *logging.Logger) []AssertionResult {
	return RunAssertionsWithOpts(exec, sshPort, log, AssertionOpts{})
}

// RunAssertionsWithOpts is the policy-aware entry point. The new
// panel-survival assertion (PR26.2) consumes opts.PanelPolicy /
// opts.PanelAdapters; every other assertion is unchanged from the
// pre-PR26.2 surface.
func RunAssertionsWithOpts(exec executor.Executor, sshPort int, log *logging.Logger, opts AssertionOpts) []AssertionResult {
	var results []AssertionResult

	results = append(results, assertNftablesActive(exec, log))
	results = append(results, assertNftbanTable(exec, "ip", log))
	results = append(results, assertNftbanTable(exec, "ip6", log))
	results = append(results, assertNftbanChain(exec, log))
	results = append(results, assertSSHInSet(exec, sshPort, log))
	results = append(results, assertNoEmergencyTable(exec, log))
	results = append(results, assertDaemonActive(exec, log))
	results = append(results, assertInstallStateFile(exec, log))
	results = append(results, assertPayloadInventory(exec, log))
	results = append(results, assertConfigIntegrity(exec, log))
	results = append(results, assertLogretentionPolicyReady(log))

	// PR26.1: systemd-payload invariants. One gather call feeds four
	// assertions so we don't walk the unit dirs (or call systemctl)
	// four times. Inventory paths are derived from existing
	// payload.VerifyInventory's required-set; PAYLOAD-INVENTORY-001
	// fails closed when nothing is supplied (every nftban-owned
	// referenced path becomes "unknown"), so the gatherer SHOULD
	// pass a populated set in production.
	in, _ := GatherSystemdPayloadInputs(exec, log, defaultInventoryPaths())
	spr := ValidateInstalledSystemdPayload(in)
	results = append(results,
		assertSystemdExecStartPaths(spr, log),
		assertSystemdTimerPair(spr, log),
		assertSystemdPayloadInventory(spr, log),
		assertFailedUnitsPostInstall(spr, log),
	)
	// v1.174: clear the stale systemd failed-state latch for units classified
	// WARN_PRE_EXISTING_RECOVERED (and ONLY those) — see resetRecoveredPreExistingUnits.
	resetRecoveredPreExistingUnits(exec, log, spr)

	// v1.135 CORE-TIMER-ENABLED-001: critical core timers must be enabled +
	// active/scheduled (or NFTBAN_RECONCILE_CORE_TIMERS=false — intentional).
	tin := GatherTimerInputs(exec, log)
	results = append(results, assertCriticalTimersEnabled(ValidateCriticalTimers(tin), log))

	// PR26.2: PANEL-SURVIVAL-001. The framework runs registered
	// adapters and produces a Fatal verdict per policy; failure
	// blocks StateCommitted via the existing AllPassed gate.
	results = append(results, assertPanelSurvival(exec, log, opts))

	passed := 0
	for _, r := range results {
		if r.Passed {
			passed++
		}
	}
	log.Info("assertions: %d/%d passed", passed, len(results))
	return results
}

// AllPassed returns true if all assertions passed.
func AllPassed(results []AssertionResult) bool {
	for _, r := range results {
		if !r.Passed {
			return false
		}
	}
	return true
}

// FailedNames returns the names of all failed assertions.
func FailedNames(results []AssertionResult) []string {
	var names []string
	for _, r := range results {
		if !r.Passed {
			names = append(names, r.Name)
		}
	}
	return names
}

func assertNftablesActive(exec executor.Executor, log *logging.Logger) AssertionResult {
	active := exec.ServiceActive("nftables")
	r := AssertionResult{Name: "nftables_active", Passed: active}
	if !active {
		r.Detail = "nftables.service not active"
		log.Warn("ASSERT nftables_active: FAIL")
	} else {
		log.Debug("ASSERT nftables_active: PASS")
	}
	return r
}

func assertNftbanTable(exec executor.Executor, family string, log *logging.Logger) AssertionResult {
	name := "nftban_table_" + family
	exists := exec.NftTableExists(family, "nftban")
	r := AssertionResult{Name: name, Passed: exists}
	if !exists {
		r.Detail = family + " nftban table missing from kernel"
		log.Warn("ASSERT %s: FAIL", name)
	} else {
		log.Debug("ASSERT %s: PASS", name)
	}
	return r
}

func assertNftbanChain(exec executor.Executor, log *logging.Logger) AssertionResult {
	// Check for input chain in ip nftban
	res := exec.Run("nft", "list", "chain", "ip", "nftban", "input")
	passed := res.ExitCode == 0
	r := AssertionResult{Name: "nftban_input_chain", Passed: passed}
	if !passed {
		r.Detail = "ip nftban input chain missing"
		log.Warn("ASSERT nftban_input_chain: FAIL")
	} else {
		log.Debug("ASSERT nftban_input_chain: PASS")
	}
	return r
}

func assertSSHInSet(exec executor.Executor, sshPort int, log *logging.Logger) AssertionResult {
	if sshPort <= 0 {
		return AssertionResult{Name: "ssh_in_set", Passed: true, Detail: "no SSH port configured"}
	}

	setData, err := exec.NftListSet("ip", "nftban", "tcp_ports_in")
	if err != nil {
		return AssertionResult{Name: "ssh_in_set", Passed: false, Detail: "cannot list tcp_ports_in: " + err.Error()}
	}

	portStr := fmt.Sprintf("%d", sshPort)
	passed := strings.Contains(setData, portStr)

	r := AssertionResult{Name: "ssh_in_set", Passed: passed}
	if !passed {
		r.Detail = "SSH port " + portStr + " not in ip nftban tcp_ports_in"
		log.Warn("ASSERT ssh_in_set: FAIL — port %d missing", sshPort)
	} else {
		log.Debug("ASSERT ssh_in_set: PASS — port %d present", sshPort)
	}
	return r
}

func assertNoEmergencyTable(exec executor.Executor, log *logging.Logger) AssertionResult {
	exists := exec.NftTableExists("inet", "nftban_install_emergency")
	r := AssertionResult{Name: "no_emergency_table", Passed: !exists}
	if exists {
		r.Detail = "inet nftban_install_emergency table still present"
		log.Warn("ASSERT no_emergency_table: FAIL")
	} else {
		log.Debug("ASSERT no_emergency_table: PASS")
	}
	return r
}

func assertDaemonActive(exec executor.Executor, log *logging.Logger) AssertionResult {
	active := exec.ServiceActive("nftband.service")
	r := AssertionResult{Name: "daemon_active", Passed: active}
	if !active {
		r.Detail = "nftband.service not active"
		log.Warn("ASSERT daemon_active: FAIL")
	} else {
		log.Debug("ASSERT daemon_active: PASS")
	}
	return r
}

func assertInstallStateFile(exec executor.Executor, log *logging.Logger) AssertionResult {
	exists := exec.FileExists(fhs.StateDir + "/install_state")
	r := AssertionResult{Name: "state_file_exists", Passed: exists}
	if !exists {
		r.Detail = "install_state file missing"
		log.Warn("ASSERT state_file_exists: FAIL")
	} else {
		log.Debug("ASSERT state_file_exists: PASS")
	}
	return r
}

// assertPayloadInventory (v1.98.2 R-3, issue #463): material install
// completeness check. Every install (source OR package) must produce the
// canonical set of destinations defined in payload.VerifyInventory. Missing
// entries indicate either a broken payload stage or a tampered install —
// both must surface as a failed assertion rather than a clean COMMITTED.
func assertPayloadInventory(exec executor.Executor, log *logging.Logger) AssertionResult {
	ok, missing := payload.VerifyInventory(exec)
	r := AssertionResult{Name: "payload_inventory_ok", Passed: ok}
	if !ok {
		r.Detail = "missing required payload: " + strings.Join(missing, ", ")
		log.Warn("ASSERT payload_inventory_ok: FAIL — missing %d: %s",
			len(missing), strings.Join(missing, ", "))
	} else {
		log.Debug("ASSERT payload_inventory_ok: PASS")
	}
	return r
}

// assertLogretentionPolicyReady (v1.222.0 DELTA-L1): the POST-GENERATION
// readiness invariant. /etc/logrotate.d/nftban is derived state (removed from the
// static payload inventory), so its presence is NOT proved by
// payload_inventory_ok. This assertion closes the gap: after generation + the
// fail-safe template copy have run, an install may only be COMMITTED when a VALID
// ACTIVE policy exists — the generated policy (state hash matches => generated) OR
// a valid bounded fallback (validates, self-heal pending). A missing / empty /
// invalid / hash-drifted / journal-stuck policy fails here => DEGRADED, never a
// false-clean COMMITTED. Paths are the fixed production defaults (env-overridable
// for tests via NFTBAN_LR_MAIN / NFTBAN_LR_STATE).
// readinessValidator is nil in production — lr.Readiness then uses the real
// logrotate DefaultValidator. Tests set it to a stub so the assertion is
// exercisable without logrotate installed.
var readinessValidator lr.Validator

func assertLogretentionPolicyReady(log *logging.Logger) AssertionResult {
	envOr := func(k, def string) string {
		if v := os.Getenv(k); v != "" {
			return v
		}
		return def
	}
	res := lr.Readiness(lr.ReadinessOptions{
		MainPath:     envOr("NFTBAN_LR_MAIN", "/etc/logrotate.d/nftban"),
		SuricataPath: envOr("NFTBAN_LR_SURICATA", "/etc/logrotate.d/nftban-suricata"),
		StatePath:    envOr("NFTBAN_LR_STATE", "/var/lib/nftban/generated/logrotate/nftban-effective.state.json"),
		TemplatePath: envOr("NFTBAN_LR_TEMPLATE", "/etc/nftban/templates/nftban.logrotate"),
		Validator:    readinessValidator,
	})
	r := AssertionResult{Name: "logretention_policy_ready", Passed: res.Ready()}
	if res.Ready() {
		r.Detail = fmt.Sprintf("%s (source=%s)", res.Verdict, res.PolicySource)
		if res.Verdict == lr.ReadyFallback {
			// truthful COMMITTED_WITH_WARNING: policy present + valid, but it is the
			// bounded fallback, not the generated one — self-heal pending.
			log.Warn("ASSERT logretention_policy_ready: PASS (FALLBACK) — bounded template policy active; generation self-heals on the next maintenance cycle")
		} else {
			log.Debug("ASSERT logretention_policy_ready: PASS — %s", r.Detail)
		}
	} else {
		r.Detail = fmt.Sprintf("%s: %s", res.Verdict, res.Reason)
		log.Warn("ASSERT logretention_policy_ready: FAIL — %s (validation=%s); remediation: %s",
			r.Detail, res.ValidationResult, res.Remediation)
	}
	return r
}

// assertConfigIntegrity (v1.100 PR-P2-6): minimum-sanity integrity check
// on the critical config files that the rest of the install depends on.
//
// Complements assertPayloadInventory:
//   - inventory checks presence — "the file exists"
//   - integrity checks minimum viability — "the file is not empty /
//     truncated and still carries its required header tokens"
//
// Scope lock (per PR-P2-6 contract): minimum-size + required-token only.
// No checksum, no signature, no semantic parse. The fixed two-file set
// (nftban.conf + nftables.conf) lives in payload.criticalConfigs; adding
// a file or a signal type requires an explicit contract update.
func assertConfigIntegrity(exec executor.Executor, log *logging.Logger) AssertionResult {
	ok, issues := payload.VerifyConfigIntegrity(exec)
	r := AssertionResult{Name: "config_integrity_ok", Passed: ok}
	if !ok {
		parts := make([]string, 0, len(issues))
		for _, i := range issues {
			parts = append(parts, i.Path+": "+i.Reason)
		}
		r.Detail = "config integrity issues: " + strings.Join(parts, "; ")
		log.Warn("ASSERT config_integrity_ok: FAIL — %d issue(s): %s",
			len(issues), strings.Join(parts, "; "))
	} else {
		log.Debug("ASSERT config_integrity_ok: PASS")
	}
	return r
}

// PR26.1 assertions ----------------------------------------------------------
//
// These four assertions implement, respectively:
//
//	SYSTEMD-EXECSTART-001         systemd_execstart_paths_ok
//	SYSTEMD-TIMER-PAIR-001        systemd_timer_pair_ok
//	PAYLOAD-INVENTORY-001         systemd_payload_inventory_ok
//	FAILED-UNIT-POSTINSTALL-001   failed_units_postinstall_ok
//
// All four are derived from a single SystemdPayloadValidationResult
// computed once per RunAssertions pass. Each contributes a distinct
// AssertionResult so FailedNames pinpoints which invariant fired.

func assertSystemdExecStartPaths(spr SystemdPayloadValidationResult, log *logging.Logger) AssertionResult {
	r := AssertionResult{Name: "systemd_execstart_paths_ok", Passed: spr.ExecStartOK()}
	if r.Passed {
		log.Debug("ASSERT systemd_execstart_paths_ok: PASS")
		return r
	}
	parts := make([]string, 0, len(spr.MissingExecPaths))
	for _, m := range spr.MissingExecPaths {
		parts = append(parts, m.UnitFile+":"+m.Directive+"="+m.Path)
	}
	r.Detail = "missing ExecStart paths: " + strings.Join(parts, "; ")
	log.Warn("ASSERT systemd_execstart_paths_ok: FAIL — %d missing: %s",
		len(spr.MissingExecPaths), strings.Join(parts, "; "))
	return r
}

func assertSystemdTimerPair(spr SystemdPayloadValidationResult, log *logging.Logger) AssertionResult {
	r := AssertionResult{Name: "systemd_timer_pair_ok", Passed: spr.TimerPairOK()}
	if r.Passed {
		log.Debug("ASSERT systemd_timer_pair_ok: PASS")
		return r
	}
	parts := make([]string, 0, len(spr.MissingTimerTargets))
	for _, m := range spr.MissingTimerTargets {
		parts = append(parts, m.TimerUnit+"->"+m.TargetUnit)
	}
	r.Detail = "timers activate missing services: " + strings.Join(parts, "; ")
	log.Warn("ASSERT systemd_timer_pair_ok: FAIL — %d unpaired: %s",
		len(spr.MissingTimerTargets), strings.Join(parts, "; "))
	return r
}

func assertSystemdPayloadInventory(spr SystemdPayloadValidationResult, log *logging.Logger) AssertionResult {
	r := AssertionResult{Name: "systemd_payload_inventory_ok", Passed: spr.PayloadInventoryOK()}
	if r.Passed {
		log.Debug("ASSERT systemd_payload_inventory_ok: PASS")
		return r
	}
	parts := make([]string, 0, len(spr.UnknownPayloadRefs))
	for _, m := range spr.UnknownPayloadRefs {
		parts = append(parts, m.UnitFile+":"+m.Path)
	}
	r.Detail = "nftban-owned paths not in payload inventory: " + strings.Join(parts, "; ")
	log.Warn("ASSERT systemd_payload_inventory_ok: FAIL — %d unknown: %s",
		len(spr.UnknownPayloadRefs), strings.Join(parts, "; "))
	return r
}

// assertCriticalTimersEnabled — CORE-TIMER-ENABLED-001 (v1.135). A critical
// core timer (e.g. nftban-maintenance.timer) that is not enabled + active must
// DEGRADE the install, not land COMMITTED. NFTBAN_RECONCILE_CORE_TIMERS=false
// is an intentional opt-out (Skipped → PASS). The Detail names the timer(s) so
// it reaches FAILURE_REASON via phaseValidate.
func assertCriticalTimersEnabled(tvr TimerValidationResult, log *logging.Logger) AssertionResult {
	r := AssertionResult{Name: "core_timers_active_or_scheduled_ok", Passed: tvr.OK}
	if r.Passed {
		if tvr.Skipped {
			log.Debug("ASSERT core_timers_active_or_scheduled_ok: PASS (NFTBAN_RECONCILE_CORE_TIMERS=false — intentional)")
		} else {
			log.Debug("ASSERT core_timers_active_or_scheduled_ok: PASS")
		}
		return r
	}
	r.Detail = "critical core timer(s) not enabled+active: " + strings.Join(tvr.Missing, ", ")
	log.Warn("ASSERT core_timers_active_or_scheduled_ok: FAIL — %s", r.Detail)
	return r
}

func assertFailedUnitsPostInstall(spr SystemdPayloadValidationResult, log *logging.Logger) AssertionResult {
	r := AssertionResult{Name: "failed_units_postinstall_ok", Passed: spr.FailedUnitsOK()}
	if r.Passed {
		// v1.174 D-INSTALL-FAILED-UNITS-STALE-LATCHED-STATE: a protection-
		// critical unit that was ALREADY failed before this install window
		// AND whose live `nftban health` probe is clean is a stale latch, not
		// a fresh break. The assertion still PASSES (install COMMITTED-with-
		// warning, not DEGRADED), but the recovered units are surfaced so the
		// operator can reset-failed them. A newly-failed unit, or a pre-
		// existing one with live health not clean/unknown, is in FailedUnits
		// and would have failed FailedUnitsOK() above (fail safe → DEGRADED).
		if len(spr.FailedUnitsPreExistingRecovered) > 0 {
			rec := make([]string, 0, len(spr.FailedUnitsPreExistingRecovered))
			for _, f := range spr.FailedUnitsPreExistingRecovered {
				rec = append(rec, f.Unit+"("+f.Detail+")")
			}
			r.Detail = "WARN_PRE_EXISTING_RECOVERED: pre-existing failed unit(s), live health clean — non-fatal: " + strings.Join(rec, "; ")
			log.Warn("ASSERT failed_units_postinstall_ok: PASS — WARN_PRE_EXISTING_RECOVERED (pre-existing failed unit(s), live health clean): %s",
				strings.Join(rec, "; "))
			return r
		}
		// v1.201 (A2 + stale-oneshot/SOAK): cadence oneshot(s) whose failed latch
		// was a transient (the v1.198.3 watchdog/update-swap EXEC-203 class) and
		// re-ran CLEAN under the host-side gated re-verify — non-fatal, surfaced
		// honestly. A re-run that still failed would NOT be here (it stays in
		// FailedUnits → DEGRADED).
		if len(spr.FailedUnitsTransientRecovered) > 0 {
			tr := make([]string, 0, len(spr.FailedUnitsTransientRecovered))
			for _, f := range spr.FailedUnitsTransientRecovered {
				tr = append(tr, f.Unit+"("+f.Detail+")")
			}
			r.Detail = "WARN_TRANSIENT_RECOVERED: cadence oneshot(s) re-ran clean after a transient latch — non-fatal: " + strings.Join(tr, "; ")
			log.Warn("ASSERT failed_units_postinstall_ok: PASS — WARN_TRANSIENT_RECOVERED (cadence oneshot re-ran clean; gated re-verify): %s",
				strings.Join(tr, "; "))
			return r
		}
		// v1.135 D-EXPORTER-SETTLE-WINDOW: a failed auxiliary (metrics/
		// observability) unit does NOT fail this assertion, but it IS
		// surfaced as a non-fatal warning so operators still see it.
		if len(spr.FailedAuxiliaryUnits) > 0 {
			aux := make([]string, 0, len(spr.FailedAuxiliaryUnits))
			for _, f := range spr.FailedAuxiliaryUnits {
				aux = append(aux, f.Unit+"("+f.Detail+")")
			}
			r.Detail = "auxiliary (non-protection) units degraded — non-fatal: " + strings.Join(aux, "; ")
			log.Warn("ASSERT failed_units_postinstall_ok: PASS — auxiliary units degraded (non-fatal): %s",
				strings.Join(aux, "; "))
			return r
		}
		log.Debug("ASSERT failed_units_postinstall_ok: PASS")
		return r
	}
	// Fail-closed query error takes precedence — surfaces the
	// enumeration failure rather than misreporting "no failed units".
	if spr.FailedUnitQueryError != "" {
		r.Detail = "failed-unit enumeration error: " + spr.FailedUnitQueryError
		log.Warn("ASSERT failed_units_postinstall_ok: FAIL — %s", spr.FailedUnitQueryError)
		return r
	}
	parts := make([]string, 0, len(spr.FailedUnits))
	for _, f := range spr.FailedUnits {
		parts = append(parts, f.Unit+"("+f.Detail+")")
	}
	r.Detail = "nftban units in failed state: " + strings.Join(parts, "; ")
	log.Warn("ASSERT failed_units_postinstall_ok: FAIL — %d failed: %s",
		len(spr.FailedUnits), strings.Join(parts, "; "))
	return r
}

// resetRecoveredPreExistingUnits issues a BOUNDED `systemctl reset-failed` for
// exactly the nftban units classified WARN_PRE_EXISTING_RECOVERED — i.e. units
// that (a) failed strictly before the install window, (b) on a host whose live
// nftban health is known-clean, and (c) had no in-window failure. Those three
// conditions are already proven by membership in spr.FailedUnitsPreExistingRecovered
// (ValidateInstalledSystemdPayload), so clearing exactly that set is safe and keeps
// the fail-safe rule intact: IN_WINDOW / unknown-timestamp / unknown-or-unhealthy-
// live-health units are NOT in this bucket and stay DEGRADED (they remain in
// spr.FailedUnits). Without this, v1.174 leaves install_state COMMITTED-with-warning
// but `systemctl --failed` polluted, so the next diagnostic/support/operator check
// still distrusts the host.
//
// Contract: always an explicit unit name (never a blanket `reset-failed`), never a
// non-nftban unit. A reset-failed error is NON-FATAL — the host is already proven
// healthy, so failing to clear cosmetic systemd state must not re-poison the
// install; it is logged WARN and the install stays COMMITTED-with-warning.
func resetRecoveredPreExistingUnits(exec executor.Executor, log *logging.Logger, spr SystemdPayloadValidationResult) {
	for _, f := range spr.FailedUnitsPreExistingRecovered {
		if !IsNftbanUnit(f.Unit) { // defense-in-depth; the bucket is already nftban-only
			continue
		}
		if err := exec.ServiceResetFailed(f.Unit); err != nil {
			log.Warn("reset-failed %s (WARN_PRE_EXISTING_RECOVERED) failed: %v — leaving cosmetic systemd failed-state; install stays COMMITTED-with-warning", f.Unit, err)
			continue
		}
		log.Info("reset-failed %s: cleared stale pre-existing systemd failed-state latch (failure pre-dates the install window; live health clean)", f.Unit)
	}
}

// defaultInventoryPaths returns the set of nftban-owned paths the
// staged install is known to populate. Mirrors payload.VerifyInventory's
// canonical required set, expressed as a set instead of a slice.
//
// Kept local to validate/ so the systemd-payload assertion does not
// import payload.buildEntries (which would couple validation against
// the full destination table). The set is intentionally narrow: a
// missing path here surfaces as a PAYLOAD-INVENTORY-001 finding with
// actionable detail (the unit file + path), prompting the operator
// to either expand this set or stop the unit from referencing the
// path. Either is a deliberate decision — not a silent pass.
func defaultInventoryPaths() map[string]bool {
	return map[string]bool{
		// CLI shim + Go binaries
		"/usr/sbin/nftban":                     true,
		"/usr/lib/nftban/bin/nftban-core":      true,
		"/usr/lib/nftban/bin/nftband":          true,
		"/usr/lib/nftban/bin/nftban-validate":  true,
		"/usr/lib/nftban/bin/nftban-installer": true,
		// Shell-side privileged helpers (cli/sbin/* → /usr/lib/nftban/sbin/)
		"/usr/lib/nftban/sbin/nftban-apply":             true,
		"/usr/lib/nftban/sbin/nftban-confirm":           true,
		"/usr/lib/nftban/sbin/nftban-queue-processor":   true,
		"/usr/lib/nftban/sbin/nftban-rollback":          true,
		"/usr/lib/nftban/sbin/nftban-service-alert":     true,
		"/usr/lib/nftban/sbin/nftban-botscan-processor": true,
		"/usr/lib/nftban/sbin/nftban-botscan-collector": true,
		// PR26.5: shell payload destinations referenced by installed
		// systemd units. Each lives at the corresponding source-side
		// path under cli/lib/nftban/{core,cron,exporters} or scripts/
		// or install/helpers/, and is staged by payload.StageAll.
		// Without these entries `systemd_payload_inventory_ok` falsely
		// flags legitimate staged shell payload as "unknown".
		"/usr/lib/nftban/core/nftban_rebuild_recovery.sh":      true,
		"/usr/lib/nftban/cron/maintenance.sh":                  true,
		"/usr/lib/nftban/exporters/nftban_unified_exporter.sh": true,
		"/usr/lib/nftban/helpers/firewall-init-with-delay.sh":  true,
		// v1.131.4 (D-D13-PAYLOAD-INVENTORY-MISS): ExecStart of the V130/V131
		// D13 unit nftban-firewall-validate.service. Added by #687/#689 but
		// omitted here, so systemd_payload_inventory_ok flagged it "unknown"
		// → install_state DEGRADED on every install carrying the validate unit.
		"/usr/lib/nftban/helpers/firewall_validate_run.sh": true,
		"/usr/lib/nftban/scripts/nftban-soak-check.sh":     true,
	}
}

// PR26.2: PANEL-SURVIVAL-001 -------------------------------------------------
//
// assertPanelSurvival evaluates the registered (or test-injected)
// panel adapters under opts.PanelPolicy and converts the result into
// an AssertionResult. Failure → AllPassed false → StateCommitted
// blocked (via the existing gate at cmd/nftban-installer/phases.go).
//
// PR26.2 ships with an empty adapter registry. With no adapters and
// the default policy (AllowPanelAbsent=true), this assertion always
// passes. PR26.3 wires the first adapter (DirectAdmin) and the
// production policy gains the operator-flag-derived OperatorDisabled
// override.
func assertPanelSurvival(exec executor.Executor, log *logging.Logger, opts AssertionOpts) AssertionResult {
	policy := opts.PanelPolicy
	if !opts.panelPolicySet {
		policy = panelfw.DefaultPolicy()
	}

	adapters := opts.PanelAdapters
	if adapters == nil {
		adapters = panelfw.RegisteredAdapters()
	}

	result := panelfw.EvaluateAdapters(context.Background(), exec, log, adapters, policy)

	r := AssertionResult{Name: "panel_survival_ok", Passed: !result.Fatal}
	if result.Fatal {
		r.Detail = result.Reason
		log.Warn("ASSERT panel_survival_ok: FAIL — %s", result.Reason)
		return r
	}
	if result.Detection.Detected {
		log.Debug("ASSERT panel_survival_ok: PASS — panel=%s reachable=%v",
			string(result.Detection.ID), result.ReachableAfter)
	} else {
		log.Debug("ASSERT panel_survival_ok: PASS — no panel detected")
	}
	return r
}
