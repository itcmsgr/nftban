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

	return in, nil
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
		findings = append(findings, FailedUnitFinding{
			Unit:   unit,
			Active: fields[2],
			Sub:    fields[3],
			Detail: strings.Join(fields[4:], " "),
		})
	}
	return findings, ""
}
