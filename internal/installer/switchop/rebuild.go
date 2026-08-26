// =============================================================================
// NFTBan v1.73 - Installer Firewall Rebuild
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-switchop-rebuild"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Run nftban firewall rebuild as a MANDATORY convergence step. No outer deadline: the step scales with host firewall state (lab2 ~35s vs srv3 ~453s) and an arbitrary constant killed legitimate convergences. Interruption is its own verdict class and is FATAL to the install — a killed rebuild is not DEGRADED, it is CONVERGENCE DID NOT COMPLETE."
// meta:inventory.files="internal/installer/switchop/rebuild.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package switchop

import (
	"context"
	"fmt"
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/fhs"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// lastNonEmptyLine returns the last non-empty, trimmed line of s, or "".
// Used to recover a degraded-rebuild reason when the shell emits it to stdout
// (marker line) rather than stderr.
func lastNonEmptyLine(s string) string {
	lines := strings.Split(s, "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if t := strings.TrimSpace(lines[i]); t != "" {
			return t
		}
	}
	return ""
}

// ⛔ v1.229.11 LANE 6A — THE 60-SECOND OUTER TIMEOUT IS GONE, NOT RAISED.
//
// It was `const rebuildTimeout = 60 * time.Second`, applied to a step whose
// duration scales with the host's firewall state:
//
//	lab2  ~35 s      inside the limit, so the defect was invisible there
//	srv3  ~453 s     killed at 60 s, EVERY upgrade
//
// That is more than an order of magnitude, and no constant is correct across it.
// Raising 60 to 600 would only move the threshold to the next larger host.
//
//	A PACKAGE MANAGER KILLING A LEGITIMATE CONVERGENCE BECAUSE THE HOST HAS A
//	LARGE FIREWALL STATE IS DANGEROUS. LONG DOES NOT MEAN HUNG.
//
// Boundedness belongs to the rebuild's own internal operations, which are
// individually bounded and report progress, not to an arbitrary outer clock
// that cannot know the size of the work it is interrupting.

// Rebuild runs "nftban firewall rebuild" and returns an error if it fails.
// Shell rebuild exit code contract (authoritative — do not redefine):
//
//	0 = PROTECTED (all checks passed)
//	1 = DEGRADED  (firewall operational, some module checks failed)
//	2 = FAILED    (rollback happened)
//	3 = FATAL     (rollback also failed)
//
// Exit 1 (DEGRADED) is expected during upgrade: module-scoped chains
// require the daemon to be running, which may not be the case yet.
// Only exit 2+ is treated as a fatal rebuild failure.
func Rebuild(exec executor.Executor, log *logging.Logger) error {
	log.Info("running nftban firewall rebuild (no outer deadline; bounded by its own operations)")

	// v1.228.5: PASS the execution context explicitly. This rebuild runs BEFORE
	// services.StartDaemon (phaseConfigure), and AddSessionWhitelist writes
	// 00-session.conf AFTER it — so the durable whitelist cannot be verified here
	// even if the daemon happened to be reachable. --install-context tells the
	// rebuild to DEFER that projection rather than treat the expected daemon
	// absence as a failure. services.SyncWhitelist is the convergence authority.
	// Context is passed, never inferred: `systemctl is-active` cannot distinguish
	// "operator stopped it" from "installer has not started it yet".
	res := exec.RunContext(context.Background(), fhs.NftbanCLI, "firewall", "rebuild", "--install-context")
	log.CmdResult("nftban firewall rebuild --install-context", res.ExitCode, res.Stderr)

	// ⛔ INTERRUPTION IS CLASSIFIED FIRST, AND IT IS FATAL.
	//
	//	completed successfully          -> continue install
	//	explicitly non-fatal condition  -> DEGRADED, protection contract intact
	//	timeout / killed / incomplete   -> INSTALL FAILURE
	//
	// A killed rebuild is not "some module chain might be missing". It is
	// CONVERGENCE DID NOT COMPLETE, and the installer must not carry on as
	// though the result were acceptably degraded.
	if res.TimedOut {
		if err := exec.WriteFileAtomic(fhs.InstallFailedMarker, []byte("NFTBAN_INSTALL_FAILED=1\n"), 0644); err != nil {
			log.Warn("failed to write install-failed marker: %v", err)
		}
		return fmt.Errorf("nftban firewall rebuild was INTERRUPTED before completion — convergence did not complete; the generation was not advanced and the host retains its last completed convergence")
	}
	// A process that died by signal without a deadline is equally incomplete:
	// it never chose an exit code, so it never reported a verdict.
	if res.ExitCode < 0 {
		if err := exec.WriteFileAtomic(fhs.InstallFailedMarker, []byte("NFTBAN_INSTALL_FAILED=1\n"), 0644); err != nil {
			log.Warn("failed to write install-failed marker: %v", err)
		}
		return fmt.Errorf("nftban firewall rebuild did not produce an exit status (killed, or not executable): %s", res.Stderr)
	}

	if res.ExitCode == 1 {
		// DEGRADED: firewall base schema is loaded but module chains may be
		// missing (daemon was down during module re-enable). This is recoverable
		// — module chains will be re-created when daemon starts with modules enabled.
		//
		// v1.151 BUG-REBUILD-DEGRADED-EMPTY-REASON: the recoverable exit-1 case emits
		// its reason to stdout (marker), not stderr, so res.Stderr was empty → the log
		// read "DEGRADED (exit 1): " (blank). Recover a real reason (stderr → last
		// stdout line → static explanation) so the operator is never told "DEGRADED"
		// with no cause during the most safety-critical Switch phase.
		reason := strings.TrimSpace(res.Stderr)
		if reason == "" {
			reason = lastNonEmptyLine(res.Stdout)
		}
		if reason == "" {
			reason = "base schema loaded; module chains deferred to daemon start"
		}
		log.Warn("firewall rebuild DEGRADED (exit 1): %s", reason)
		log.Warn("module chains may be absent — will be created on daemon start")
		// Continue — do not fail the install for a degraded rebuild
	} else if res.ExitCode >= 2 {
		// FAILED or FATAL: real rebuild failure, rollback may have happened
		if err := exec.WriteFileAtomic(fhs.InstallFailedMarker, []byte("NFTBAN_INSTALL_FAILED=1\n"), 0644); err != nil {
			log.Warn("failed to write install-failed marker: %v", err)
		}
		return fmt.Errorf("nftban firewall rebuild failed (exit %d): %s", res.ExitCode, res.Stderr)
	}

	// v1.151 BUG-REBUILD-DEGRADED-EMPTY-REASON: never log "completed (exit 1)" — that
	// contradicts the DEGRADED warning above and reads as a FAILED takeover, tempting
	// the operator to Ctrl+C / rollback at the worst moment when it actually recovered.
	if res.ExitCode == 0 {
		log.Info("firewall rebuild completed")
	} else {
		log.Info("firewall rebuild finished DEGRADED (exit %d) — module chains deferred to daemon start (recovery expected)", res.ExitCode)
	}

	// Write schema version file (G7 parity with shell postinst).
	// The shell postinst wrote: echo "$CURRENT_SCHEMA" > /etc/nftban/.schema_version
	// We use the installed version as the schema identifier.
	versionData, err := exec.ReadFile(fhs.VersionFile)
	if err == nil {
		version := string(versionData)
		// Trim whitespace/newlines
		for len(version) > 0 && (version[len(version)-1] == '\n' || version[len(version)-1] == '\r' || version[len(version)-1] == ' ') {
			version = version[:len(version)-1]
		}
		if err := exec.WriteFileAtomic(fhs.SchemaVersionFile, []byte(version+"\n"), 0640); err != nil {
			log.Warn("write schema version: %v", err)
		} else {
			log.Debug("wrote schema version %s to %s", version, fhs.SchemaVersionFile)
		}
	}

	return nil
}
