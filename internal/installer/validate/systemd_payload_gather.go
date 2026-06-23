// =============================================================================
// NFTBan v1.100.x PR26.1 - Systemd Payload Gather (host-side adapter)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-validate-systemd-payload-gather"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-29"
// meta:description="Adapter that builds SystemdPayloadInputs from a live host"
// meta:inventory.files="internal/installer/validate/systemd_payload_gather.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// Pure validator + tests live in systemd_payload.go. This file holds
// the adapter that pulls live host data through executor.Executor and
// the on-disk filesystem.
//
// =============================================================================

package validate

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// auxiliarySettleAttempts / auxiliarySettleDelay bound the re-poll window that
// lets a transient AUXILIARY-only failure (notably the unified exporter's
// exit-2 during a package swap) self-heal before it is recorded
// (D-EXPORTER-SETTLE-WINDOW, v1.135). A protection-critical failure
// short-circuits the wait immediately. auxiliarySettleDelay is a var so tests
// can drive the settle logic without real sleeping.
const auxiliarySettleAttempts = 3

var auxiliarySettleDelay = 2 * time.Second

// installWindowStart records the wall-clock instant the current installer
// run began. It is set ONCE via SetInstallWindowStart at the very start of
// the run (before any phase executes) and consumed by
// GatherSystemdPayloadInputs to classify pre-existing vs in-window unit
// failures. Zero value => unknown (no downgrade is permitted; fail closed).
// v1.174 D-INSTALL-FAILED-UNITS-STALE-LATCHED-STATE.
var installWindowStart time.Time

// SetInstallWindowStart records the install-window start instant. Call once
// at the very start of the installer run, before the phases execute. The
// validate gatherer reads this when building SystemdPayloadInputs. Note:
// state/file.go INSTALL_TIMESTAMP is the END/write time and must NOT be
// reused as the window start.
func SetInstallWindowStart(t time.Time) { installWindowStart = t }

// liveHealthProbeTimeout bounds the live `nftban health` probe so a hung or
// pathologically slow health run cannot stall install validation. On
// timeout the probe reports known=false (no downgrade — fail closed).
const liveHealthProbeTimeout = 20 * time.Second

// systemdTimestampLayouts lists the layouts accepted when parsing a systemd
// timestamp property value such as "Thu 2026-06-11 03:06:02 UTC". systemd
// renders the weekday + zone abbreviation; a numeric-zone fallback is kept
// for environments that emit one. Empty / unparseable => FailureTimeKnown
// stays false (fatal via the classification rules).
var systemdTimestampLayouts = []string{
	"Mon 2006-01-02 15:04:05 MST",
	"Mon 2006-01-02 15:04:05 -0700",
	"2006-01-02 15:04:05 MST",
	"2006-01-02 15:04:05 -0700",
}

// DefaultUnitDirs is the canonical systemd unit search path for
// nftban-owned units. Both vendor and operator-owned dirs are scanned
// so a unit dropped under /etc/systemd/system is still validated.
var DefaultUnitDirs = []string{
	"/usr/lib/systemd/system",
	"/etc/systemd/system",
}

// DefaultNftbanOwnedPrefixes lists path prefixes considered
// nftban-owned for PAYLOAD-INVENTORY-001.
var DefaultNftbanOwnedPrefixes = []string{
	"/usr/lib/nftban/",
	"/etc/nftban/",
}

// DefaultSystemBinaryPrefixes lists path prefixes that are exempt
// from PAYLOAD-INVENTORY-001 (legitimate to call from a unit even
// though they are not part of the nftban payload).
var DefaultSystemBinaryPrefixes = []string{
	"/usr/bin/",
	"/bin/",
	"/usr/sbin/",
	"/sbin/",
	"/usr/local/bin/",
	"/usr/local/sbin/",
}

// GatherSystemdPayloadInputs scans the host for nftban-owned systemd
// units, parses them, and assembles the input set used by
// ValidateInstalledSystemdPayload.
//
// inventoryPaths is the staged install's known-path set (typically
// produced by the payload-staging layer). When nil/empty, the
// PAYLOAD-INVENTORY-001 check still functions but its `Paths` set is
// empty — every nftban-owned referenced path will be flagged. Callers
// SHOULD pass a populated set.
func GatherSystemdPayloadInputs(exec executor.Executor, log *logging.Logger, inventoryPaths map[string]bool) (SystemdPayloadInputs, error) {
	in := SystemdPayloadInputs{
		PathExists: func(p string) bool { return exec.FileExists(p) },
		Inventory: PayloadInventory{
			Paths:                inventoryPaths,
			NftbanOwnedPrefixes:  DefaultNftbanOwnedPrefixes,
			SystemBinaryPrefixes: DefaultSystemBinaryPrefixes,
		},
		AllUnitNames: map[string]bool{},
	}

	for _, dir := range DefaultUnitDirs {
		if !exec.FileExists(dir) {
			continue
		}
		entries, err := os.ReadDir(filepath.Clean(dir)) // #nosec G304 -- canonical systemd dirs
		if err != nil {
			if log != nil {
				log.Warn("systemd_payload: read %s: %v", dir, err)
			}
			continue
		}
		for _, e := range entries {
			if e.IsDir() {
				continue
			}
			name := e.Name()
			if !isUnitFilename(name) {
				continue
			}
			in.AllUnitNames[name] = true
			if !IsNftbanUnit(name) {
				continue
			}
			full := filepath.Join(dir, name)
			data, err := exec.ReadFile(full)
			if err != nil {
				if log != nil {
					log.Warn("systemd_payload: read %s: %v", full, err)
				}
				continue
			}
			in.Units = append(in.Units, ParseUnitFile(name, full, string(data)))
		}
	}

	in.FailedNftbanUnits, in.FailedUnitQueryError = listFailedNftbanUnits(exec, log)

	// v1.174 D-INSTALL-FAILED-UNITS-STALE-LATCHED-STATE: hand the pure
	// validator the install-window start and a bounded live-health verdict so
	// it can downgrade a stale pre-existing latch (and ONLY that) to a
	// non-fatal warning. Both are fail-closed: an unset window start or an
	// inconclusive probe leaves the failure fatal.
	in.InstallWindowStart = installWindowStart
	in.InstallWindowStartKnown = !installWindowStart.IsZero()
	in.LiveHealthClean, in.LiveHealthKnown = gatherLiveHealthClean(exec, log)

	return in, nil
}

// gatherLiveHealthClean runs a bounded live `nftban health` text probe and
// reports whether overall health is clean. clean=true requires ALL of:
//   - an "Overall:" line whose value is OK or IDLE (case-insensitive),
//   - a "Findings: none" line, and
//   - no "CRITICAL" anywhere in the output.
//
// known=false (no confident verdict) on: missing nftban binary, non-zero
// exit, context timeout, or output with no parseable "Overall:" line. The
// caller treats known=false as "do not downgrade" (fail closed). Text only
// — deliberately not --json.
func gatherLiveHealthClean(exec executor.Executor, log *logging.Logger) (clean bool, known bool) {
	if !exec.CommandExists("nftban") {
		if log != nil {
			log.Debug("systemd_payload: live-health probe skipped — nftban binary not in PATH (known=false)")
		}
		return false, false
	}
	ctx, cancel := context.WithTimeout(context.Background(), liveHealthProbeTimeout)
	defer cancel()
	res := exec.RunContext(ctx, "nftban", "health")
	if ctx.Err() != nil {
		if log != nil {
			log.Warn("systemd_payload: live-health probe timed out after %s (known=false)", liveHealthProbeTimeout)
		}
		return false, false
	}
	if res.ExitCode != 0 {
		if log != nil {
			log.Debug("systemd_payload: live-health probe exit=%d (known=false)", res.ExitCode)
		}
		return false, false
	}
	return parseLiveHealthClean(res.Stdout)
}

// parseLiveHealthClean parses the text output of `nftban health` and applies
// the conservative clean/known rules described on gatherLiveHealthClean.
// Pure function so it is unit-testable without an executor.
// parseLiveHealthClean reads `nftban health` text output and decides whether the
// system is healthy enough to downgrade a PRE_EXISTING failed-unit latch.
//
// Uses the real four-axis health vocabulary (cli/lib/nftban/cli/cmd_health.sh):
//   - Overall: OK / IDLE / PROTECTED are ALL healthy — PROTECTED is the NORMAL
//     active-protection state and MUST count as clean, else the v1.174 downgrade
//     never fires on a protecting host. DOWN / DEGRADED / WARN / other = not clean.
//   - Findings: "none" OR "none (N INFO finding(s) hidden ...)" are BOTH clean —
//     hidden INFO findings are informational, not problems.
//   - Any CRITICAL / FAIL / ERROR token anywhere → unambiguously not clean.
//   - Missing Overall OR missing Findings → unknown verdict → fail-safe.
func parseLiveHealthClean(out string) (clean bool, known bool) {
	up := strings.ToUpper(out)
	if strings.Contains(up, "CRITICAL") || strings.Contains(up, "FAIL") || strings.Contains(up, "ERROR") {
		// Unambiguous not-clean (covers Truth: FAILED, CRITICAL findings, errors).
		return false, true
	}
	overallSeen := false
	overallHealthy := false
	findingsSeen := false
	findingsClean := false
	for _, line := range strings.Split(out, "\n") {
		t := strings.TrimSpace(line)
		lower := strings.ToLower(t)
		if strings.HasPrefix(lower, "overall:") {
			overallSeen = true
			fields := strings.Fields(strings.ToUpper(strings.TrimSpace(t[len("overall:"):])))
			if len(fields) > 0 {
				switch fields[0] {
				case "OK", "IDLE", "PROTECTED":
					overallHealthy = true
				}
			}
			continue
		}
		if strings.HasPrefix(lower, "findings:") {
			findingsSeen = true
			val := strings.ToLower(strings.TrimSpace(t[len("findings:"):]))
			// "none" or "none (N INFO finding(s) hidden ...)" — INFO-only is clean.
			if val == "none" || strings.HasPrefix(val, "none ") || strings.HasPrefix(val, "none(") {
				findingsClean = true
			}
		}
	}
	if !overallSeen || !findingsSeen {
		// Need both axes to form a verdict — fail safe to unknown.
		return false, false
	}
	return overallHealthy && findingsClean, true
}

// isUnitFilename returns true for systemd unit filenames we care about.
func isUnitFilename(name string) bool {
	switch filepath.Ext(name) {
	case ".service", ".timer", ".socket":
		return true
	}
	return false
}

// listFailedNftbanUnits queries systemctl for failed units and returns
// only the nftban-owned ones plus a query-error string.
//
// Fails closed: a non-zero exit, missing systemctl, or unreadable
// output produces a non-empty queryErr so FAILED-UNIT-POSTINSTALL-001
// surfaces the enumeration failure as an assertion failure instead of
// silently returning an empty list and false-passing.
func listFailedNftbanUnits(exec executor.Executor, log *logging.Logger) (findings []FailedUnitFinding, queryErr string) {
	findings, queryErr = queryFailedNftbanUnitsOnce(exec, log)
	if queryErr != "" {
		return findings, queryErr
	}
	// v1.135 D-EXPORTER-SETTLE-WINDOW: when the only failures are auxiliary,
	// give them a bounded settle window to self-heal (the exporter's exit-2
	// during a package swap recovers within seconds). A protection-critical
	// failure is never waited on.
	findings = settleAuxiliaryFailures(findings,
		func() ([]FailedUnitFinding, string) { return queryFailedNftbanUnitsOnce(exec, log) },
		auxiliarySettleAttempts,
		func() { time.Sleep(auxiliarySettleDelay) },
		log)
	return findings, ""
}

// hasProtectionCriticalFailure reports whether any finding is a non-auxiliary
// (protection-critical) nftban unit. These are never waited on during settle.
func hasProtectionCriticalFailure(fs []FailedUnitFinding) bool {
	for _, f := range fs {
		if IsNftbanUnit(f.Unit) && !IsAuxiliaryUnit(f.Unit) {
			return true
		}
	}
	return false
}

// settleAuxiliaryFailures re-polls failed units up to maxAttempts total polls
// (the first poll is the passed-in initial set) WHILE the only failures are
// auxiliary, sleeping between polls, to let a transient auxiliary failure
// recover. It returns as soon as: nothing is failing, a protection-critical
// unit is failing (fail fast — do not wait), a requery errors (keep what we
// had), or attempts are exhausted. Pure logic with injected requery+sleep so
// it is fully unit-testable without real time or systemctl.
func settleAuxiliaryFailures(
	initial []FailedUnitFinding,
	requery func() ([]FailedUnitFinding, string),
	maxAttempts int,
	sleep func(),
	log *logging.Logger,
) []FailedUnitFinding {
	cur := initial
	for attempt := 1; attempt < maxAttempts; attempt++ {
		if len(cur) == 0 {
			return cur
		}
		if hasProtectionCriticalFailure(cur) {
			return cur
		}
		// Only auxiliary failures remain — wait and re-poll.
		if log != nil {
			log.Debug("systemd_payload: auxiliary-only failure(s) present; settle re-poll %d/%d",
				attempt, maxAttempts-1)
		}
		sleep()
		next, qerr := requery()
		if qerr != "" {
			return cur
		}
		cur = next
	}
	return cur
}

func queryFailedNftbanUnitsOnce(exec executor.Executor, log *logging.Logger) (findings []FailedUnitFinding, queryErr string) {
	if !exec.CommandExists("systemctl") {
		queryErr = "systemctl binary not available — cannot enumerate failed units"
		if log != nil {
			log.Warn("systemd_payload: %s", queryErr)
		}
		return nil, queryErr
	}
	res := exec.Run("systemctl", "list-units", "--state=failed", "--no-legend", "--plain", "--all")
	if res.ExitCode != 0 {
		queryErr = fmt.Sprintf("systemctl list-units --state=failed exit=%d stderr=%q",
			res.ExitCode, strings.TrimSpace(res.Stderr))
		if log != nil {
			log.Warn("systemd_payload: %s", queryErr)
		}
		return nil, queryErr
	}
	for _, line := range strings.Split(strings.TrimSpace(res.Stdout), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		// Format: UNIT LOAD ACTIVE SUB DESCRIPTION
		fields := strings.Fields(line)
		if len(fields) < 4 {
			continue
		}
		unit := fields[0]
		if !IsNftbanUnit(unit) {
			continue
		}
		finding := FailedUnitFinding{
			Unit:   unit,
			Active: fields[2],
			Sub:    fields[3],
			Detail: strings.Join(fields[4:], " "),
		}
		// v1.174 D-INSTALL-FAILED-UNITS-STALE-LATCHED-STATE: capture the
		// unit's last-failure timestamp so the validator can classify it as
		// pre-existing vs in-window. Parse error => FailureTimeKnown stays
		// false (fail closed → fatal).
		finding.FailureTime, finding.FailureTimeKnown = queryUnitFailureTime(exec, unit, log)
		// v1.201 (A2 + stale-oneshot/SOAK): for a cadence oneshot
		// (watchdog/soak/maintenance) attempt the GATED live re-verify — clear the
		// latch and run once; the latch is recoverable ONLY if that fresh run is
		// clean (no-mask). The classifier consults OwnedWindowReverify{Done,Clean}.
		if isCadenceReverifiableOneshot(unit) {
			finding.OwnedWindowReverifyDone, finding.OwnedWindowReverifyClean = reverifyCadenceOneshot(exec, unit, log)
		}
		findings = append(findings, finding)
	}
	return findings, ""
}

// reverifyCadenceOneshot performs the v1.201 GATED re-verify for a cadence
// oneshot in a failed latch: reset the failed-state, issue one fresh
// `systemctl start`, and report clean ONLY when that run succeeds AND the unit
// is no longer failed. This is the no-mask gate — a unit whose re-run still
// fails returns clean=false and stays FATAL (DEGRADED). The reset-failed +
// start are bounded to exactly the cadence-oneshot stems and are the only
// side-effects; nothing is hidden on assumption. done=true always (attempted).
func reverifyCadenceOneshot(exec executor.Executor, unit string, log *logging.Logger) (done, clean bool) {
	_ = exec.ServiceResetFailed(unit) // clear the latch so the start is not blocked; non-fatal
	startErr := exec.ServiceStart(unit)
	// `systemctl is-failed <unit>` exits 0 when the unit is in failed state.
	stillFailed := false
	if r := exec.Run("systemctl", "is-failed", unit); r.ExitCode == 0 {
		stillFailed = true
	}
	clean = startErr == nil && !stillFailed
	if log != nil {
		if clean {
			log.Info("v1.201 re-verify: %s cadence oneshot re-ran CLEAN — transient latch recovered (reset-failed + fresh start ok)", unit)
		} else {
			log.Warn("v1.201 re-verify: %s cadence oneshot re-run did NOT clean (start_err=%v still_failed=%v) — keeping FATAL (no-mask)", unit, startErr, stillFailed)
		}
	}
	return true, clean
}

// queryUnitFailureTime asks systemd for a unit's last-failure timestamp via
// `systemctl show` and returns the most recent of InactiveEnterTimestamp /
// ExecMainExitTimestamp. Robust by design: any error, missing property, or
// unparseable value yields known=false so the unit is treated as a hard
// failure (fail closed).
func queryUnitFailureTime(exec executor.Executor, unit string, log *logging.Logger) (time.Time, bool) {
	res := exec.Run("systemctl", "show",
		"-p", "InactiveEnterTimestamp",
		"-p", "ExecMainExitTimestamp",
		unit)
	if res.ExitCode != 0 {
		if log != nil {
			log.Debug("systemd_payload: systemctl show %s exit=%d (failure-time unknown)", unit, res.ExitCode)
		}
		return time.Time{}, false
	}
	var best time.Time
	bestKnown := false
	for _, line := range strings.Split(res.Stdout, "\n") {
		line = strings.TrimSpace(line)
		eq := strings.IndexByte(line, '=')
		if eq < 0 {
			continue
		}
		key := strings.TrimSpace(line[:eq])
		if key != "InactiveEnterTimestamp" && key != "ExecMainExitTimestamp" {
			continue
		}
		val := strings.TrimSpace(line[eq+1:])
		if val == "" {
			continue
		}
		t, ok := parseSystemdTimestamp(val)
		if !ok {
			continue
		}
		if !bestKnown || t.After(best) {
			best = t
			bestKnown = true
		}
	}
	if !bestKnown && log != nil {
		log.Debug("systemd_payload: no parseable failure timestamp for %s (failure-time unknown)", unit)
	}
	return best, bestKnown
}

// parseSystemdTimestamp parses a systemd timestamp property value (e.g.
// "Thu 2026-06-11 03:06:02 UTC") against systemdTimestampLayouts. Empty or
// unparseable input returns ok=false.
func parseSystemdTimestamp(s string) (time.Time, bool) {
	s = strings.TrimSpace(s)
	if s == "" {
		return time.Time{}, false
	}
	for _, layout := range systemdTimestampLayouts {
		if t, err := time.Parse(layout, s); err == nil {
			return t, true
		}
	}
	return time.Time{}, false
}
