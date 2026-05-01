// =============================================================================
// NFTBan v1.75.1 - Installer Takeover Operations
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-switchop-takeover"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Disable conflicting firewalls during takeover with CSF panel disarm"
// meta:inventory.files="internal/installer/switchop/takeover.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package switchop

import (
	"path/filepath"
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// DisableConflicts stops, disables, and masks all conflicting firewalls.
// For CSF conflicts on DirectAdmin servers, also disarms CustomBuild so
// that `./build update` does not re-enable CSF.
func DisableConflicts(exec executor.Executor, conflicts []detect.Conflict, panel detect.PanelType, log *logging.Logger) error {
	hasCSF := false
	for _, c := range conflicts {
		if c.Service == "" {
			continue
		}
		log.Info("disabling conflicting service: %s (%s)", c.Name, c.Service)

		if err := exec.ServiceStop(c.Service); err != nil {
			log.Warn("stop %s: %v", c.Service, err)
		}
		if err := exec.ServiceDisable(c.Service); err != nil {
			log.Warn("disable %s: %v", c.Service, err)
		}
		if err := exec.ServiceMask(c.Service); err != nil {
			log.Warn("mask %s: %v", c.Service, err)
		}
		if c.Name == "CSF" {
			hasCSF = true
		}
	}

	// Flush legacy iptables rules (reset policies, flush all tables, delete chains)
	for _, cmd := range []string{"iptables", "ip6tables"} {
		if exec.CommandExists(cmd) {
			// Reset policies to ACCEPT before flushing (prevents DROP lockout)
			for _, chain := range []string{"INPUT", "FORWARD", "OUTPUT"} {
				exec.Run(cmd, "-P", chain, "ACCEPT")
			}
			// Flush and delete chains in all tables
			for _, table := range []string{"filter", "nat", "mangle"} {
				exec.Run(cmd, "-t", table, "-F")
				exec.Run(cmd, "-t", table, "-X")
			}
			log.Info("flushed all %s rules (filter/nat/mangle)", cmd)
		}
	}

	// Disarm panel CSF management (prevents re-enable on panel update)
	if hasCSF {
		disarmCSFArtifacts(exec, log)
		disarmPanelCSF(exec, panel, log)
	}

	return nil
}

// disarmCSFArtifacts removes CSF cron jobs and disables the CSF binary to prevent
// ghost iptables rules from being recreated after service masking.
//
// PR-26-code-C addition: BEFORE removing the cron files, write a
// cron-backup manifest under /var/lib/nftban/state/csf-cron-backup/
// so the §31 A.4 restore path can later reverse this removal with
// fidelity (sha256 + mode + uid + gid + size). The manifest writer
// is best-effort — its failure does NOT block the rm; the rm is the
// install-time invariant. Hosts installed before PR-26-code-C ship
// without a manifest; A.4 stays soft-skip on those hosts (graceful
// migration per §42.2 lock).
//
// §50 ordering lock: the writer in this commit lands in the same PR
// as the A.4 reader in restore_deps_csf.go::mutateToCSFTarget — the
// reader will refuse to act on a manifest absent or corrupt; A.4
// stays skip-only on pre-PR-26 hosts.
func disarmCSFArtifacts(exec executor.Executor, log *logging.Logger) {
	// PR-26-code-C: capture the cron-backup manifest BEFORE removal.
	// Writer failures are logged but non-fatal — the rm path below
	// MUST execute regardless, because nftban takeover correctness
	// requires the cron files to be gone.
	if _, err := WriteCronBackupManifest(exec, log); err != nil {
		log.Warn("cron-backup manifest writer: %v (continuing with cron rm; A.4 restore will soft-skip on this host)", err)
	}

	// Remove CSF/LFD cron jobs (lfd-cron runs "csf --lfd restart" daily)
	for _, cronFile := range []string{"/etc/cron.d/lfd-cron", "/etc/cron.d/csf-cron"} {
		if exec.FileExists(cronFile) {
			res := exec.Run("rm", "-f", cronFile)
			if res.ExitCode == 0 {
				log.Info("removed CSF cron: %s", cronFile)
			} else {
				log.Warn("failed to remove %s: %s", cronFile, res.Stderr)
			}
		}
	}

	// Disable CSF binary (rename to .disabled to prevent accidental execution)
	csfBin := "/usr/sbin/csf"
	if exec.FileExists(csfBin) {
		res := exec.Run("mv", csfBin, csfBin+".disabled")
		if res.ExitCode == 0 {
			log.Info("disabled CSF binary: %s -> %s.disabled", csfBin, csfBin)
		} else {
			log.Warn("failed to disable CSF binary: %s", res.Stderr)
		}
	}

	// NOTE: Ghost nft tables (ip filter, ip nat, etc.) are cleaned by
	// CleanGhostTables() which runs after DisableConflicts in the phase pipeline.
}

// disarmPanelCSF prevents the hosting panel from re-enabling CSF after masking.
//
// DirectAdmin: runs `custombuild/build set csf no` to set csf=no in options.conf.
// Also audits DA custom scripts for CSF/iptables references (informational WARN).
// PR26.6.1 addition: also flips DirectAdmin's runtime services.status watchdog
// `lfd=ON` → `lfd=OFF` so dataskq stops trying to restart the masked lfd unit
// (PANEL-WATCHDOG-COHERENCE-001). See disarmDAWatchdog for details.
//
// cPanel/Plesk: CSF is standalone — service masking is sufficient.
func disarmPanelCSF(exec executor.Executor, panel detect.PanelType, log *logging.Logger) {
	if panel != detect.PanelDirectAdmin {
		log.Debug("panel %s — CSF masking is sufficient, no custombuild disarm needed", panel)
		return
	}
	// PR26.6.1: clear the DA runtime watchdog so dataskq no longer
	// emits perpetual "Unit lfd.service is masked." failures every
	// minute. Best-effort — failure here does not break takeover.
	disarmDAWatchdog(exec, log)

	buildCmd := filepath.Join(detect.PathDirectAdmin, "custombuild", "build")
	if !exec.FileExists(buildCmd) {
		log.Warn("DirectAdmin custombuild not found at %s — cannot disarm CSF", buildCmd)
		return
	}

	// Set csf=no in custombuild options
	log.Info("disarming DirectAdmin CustomBuild CSF management")
	res := exec.Run(buildCmd, "set", "csf", "no")
	log.CmdResult("custombuild build set csf no", res.ExitCode, res.Stderr)

	if res.ExitCode != 0 {
		log.Warn("custombuild set csf no failed (exit %d) — manual action may be needed", res.ExitCode)
		return
	}

	// Verify: check options.conf for csf=no
	optionsPath := filepath.Join(detect.PathDirectAdmin, "custombuild", "options.conf")
	data, err := exec.ReadFile(optionsPath)
	if err != nil {
		log.Warn("cannot verify options.conf: %v", err)
		return
	}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "csf=") {
			val := strings.TrimPrefix(line, "csf=")
			if val == "no" {
				log.Info("verified: custombuild options.conf csf=no")
			} else {
				log.Warn("custombuild options.conf has csf=%s — expected 'no'", val)
			}
			break
		}
	}

	// Audit DA custom scripts for CSF/iptables references (informational)
	customDir := filepath.Join(detect.PathDirectAdmin, "scripts", "custom")
	if exec.FileExists(customDir) {
		res := exec.Run("grep", "-rl", "-E", "csf|lfd|iptables", customDir)
		if res.ExitCode == 0 && strings.TrimSpace(res.Stdout) != "" {
			for _, f := range strings.Split(strings.TrimSpace(res.Stdout), "\n") {
				if f != "" {
					log.Warn("DA custom script references CSF/iptables: %s (manual review recommended)", f)
				}
			}
		}
	}
}

// daServicesStatusPath is the canonical DirectAdmin runtime
// service-monitor configuration. dataskq reads this file every minute
// and runs service-watchdog for each `<svc>=ON` line.
const daServicesStatusPath = "/usr/local/directadmin/data/admin/services.status"

// disarmDAWatchdog flips DirectAdmin's runtime watchdog setting for
// lfd from ON to OFF after takeover masks lfd.service.
//
// PR26.6.1 invariant — PANEL-WATCHDOG-COHERENCE-001:
//
//	When takeover intentionally disarms an external firewall service
//	that a panel monitors, takeover must also update the panel's
//	runtime service-monitor configuration so the panel does not
//	continuously attempt to restart the disarmed service.
//
// Without this, dns2 evidence (2026-04-30 → 2026-05-01) showed
// dataskq emitting `error=service "lfd": Unit lfd.service is masked.`
// every 60 seconds for 14+ hours. The lfd binary is preserved on
// disk and the systemd mask is intact — the loop is purely a
// false-failure-noise issue, but it is high-volume and obscures
// real failures in the journal.
//
// Behavior:
//   - Idempotent: re-running on a host where lfd=OFF already is a no-op.
//   - Best-effort: file absent → no-op + debug log; read/write failure
//     → warn + continue. Takeover does not abort on watchdog disarm.
//   - Surgical: only the `^lfd=ON` line is edited; all other watchdog
//     entries (dovecot, exim, named, mysqld, etc.) are preserved
//     byte-for-byte. The match is anchored to the line start to avoid
//     accidentally matching an inline comment or substring.
//   - DA-only: this helper runs only when panel == DirectAdmin (caller
//     gates it). cPanel/Plesk have separate service-monitor mechanisms
//     handled in their own future PRs.
//
// Out of scope (deferred to restore-coherence work): re-enabling the
// watchdog (`lfd=OFF` → `lfd=ON`) on full §32 CSF restore. The forward
// direction is the immediate operational fix; the reverse is part of
// the broader restore-coherence track.
func disarmDAWatchdog(exec executor.Executor, log *logging.Logger) {
	if !exec.FileExists(daServicesStatusPath) {
		log.Debug("DA services.status not present at %s — watchdog disarm skipped", daServicesStatusPath)
		return
	}
	data, err := exec.ReadFile(daServicesStatusPath)
	if err != nil {
		log.Warn("DA watchdog: read %s: %v", daServicesStatusPath, err)
		return
	}

	original := string(data)
	updated, changed := flipLfdWatchdogOff(original)
	if !changed {
		log.Debug("DA watchdog: lfd already OFF (or absent) in %s — no change", daServicesStatusPath)
		return
	}

	if err := exec.WriteFileAtomic(daServicesStatusPath, []byte(updated), 0644); err != nil {
		log.Warn("DA watchdog: write %s: %v (dataskq may continue emitting masked-lfd noise)", daServicesStatusPath, err)
		return
	}
	log.Info("DA services.status: lfd watchdog disabled (PANEL-WATCHDOG-COHERENCE-001)")
}

// flipLfdWatchdogOff replaces every `^lfd=ON` line with `lfd=OFF`,
// preserving line endings and all other content byte-for-byte.
// Returns (newContent, didChange). Pure function — no I/O — so the
// edit logic is unit-testable independently of executor mocking.
//
// Match anchors to start-of-line on purpose: a substring match would
// risk hitting comment lines like `# lfd=ON disabled in 2024-12 ...`
// that should not be rewritten. Only the canonical setting line at
// column zero is flipped.
func flipLfdWatchdogOff(content string) (string, bool) {
	const target = "lfd=ON"
	const replacement = "lfd=OFF"
	if !strings.Contains(content, target) {
		return content, false
	}
	changed := false
	lines := strings.Split(content, "\n")
	for i, line := range lines {
		if line == target {
			lines[i] = replacement
			changed = true
		}
	}
	if !changed {
		return content, false
	}
	return strings.Join(lines, "\n"), true
}
