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
	// CSF-CLOSE-1/2 (owner doctrine 2026-08-11: CSF_POLICY = REMOVE, NOT RESTORE).
	//
	// hasCSF is decided BEFORE the empty-Service skip below. Previously the
	// `if c.Service == "" { continue }` guard ran first, so a CSF conflict
	// observed only via /etc/csf/csf.conf (SourceConfigFile, Unit "") exited
	// the loop before `hasCSF = true` was ever reached — silently disabling
	// the ENTIRE CSF disarm path (binary, cron, panel) while CSF was still
	// listed in CONFLICTS and shown to the operator. Proven on el9-clean:
	// CONFLICTS=iptables-nft,iptables,CSF with zero neutralization performed
	// and status=PROTECTED.
	//
	// Any credible CSF evidence must reach the removal path. Removal must not
	// depend on obtaining a service name.
	hasCSF := false
	for _, c := range conflicts {
		if c.Name == "CSF" {
			hasCSF = true
		}
	}

	// OWNER RULING 2026-08-12 — CSF takeover is a DESTRUCTIVE REPLACEMENT.
	// The consequence is disclosed BEFORE any mutation, because stopping CSF
	// runs the vendor's own ExecStop (`csf --initdown ; csf --stop`), which
	// flushes the legacy iptables/ip6tables tables. That is CSF's documented
	// shutdown behaviour, not something NFTBan can suppress without leaving
	// CSF running — and NFTBan does not build a capture/replay subsystem to
	// reconstruct arbitrary foreign rules around it.
	//
	//     PRESERVE_ARBITRARY_LEGACY_IPTABLES_ACROSS_CSF_REMOVAL = NOT SUPPORTED
	//
	// What remains forbidden is NFTBan issuing blanket foreign-state flushes
	// of its own (CSF-CLOSE-3) or executing vendor binaries directly.
	// --takeover / force approval IS the deliberate destructive authorization,
	// so no second confirmation is required — only that the operator was told.
	if hasCSF {
		log.Warn("CSF takeover authorized — this REPLACES CSF with NFTBan and is destructive:")
		log.Warn("  · csf.service and lfd.service will be stopped, disabled and masked")
		log.Warn("  · the CSF and LFD executables will be neutralized (renamed .disabled)")
		log.Warn("  · CSF/LFD cron persistence will be removed")
		log.Warn("  · stopping CSF runs its own shutdown, which MAY FLUSH legacy")
		log.Warn("    iptables/ip6tables rules — including unrelated rules coexisting")
		log.Warn("    in those tables. NFTBan does not restore them.")
		log.Warn("  Continue only if replacing CSF with NFTBan is intended.")
	}

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
		maskErr := exec.ServiceMask(c.Service)
		if maskErr != nil {
			log.Warn("mask %s: %v", c.Service, maskErr)
		}
		// PR-P1 / closes #524: clear the stale `failed (Result: signal)`
		// marker so `systemctl --failed` does not show the unit nftban
		// just intentionally tore down. Defensive: only run if mask
		// succeeded — a service we couldn't mask is one we shouldn't
		// reset-failed either. reset-failed errors are cosmetic-only;
		// non-fatal.
		if maskErr == nil {
			if err := exec.ServiceResetFailed(c.Service); err != nil {
				log.Warn("reset-failed %s: %v (cosmetic only)", c.Service, err)
			} else {
				log.Info("cleared stale failed marker for masked conflict service: %s", c.Service)
			}
		}
	}

	// CSF-CLOSE-3 — REMOVED: the blanket legacy-iptables flush.
	//
	// This block previously ran, for both iptables and ip6tables:
	//     -P INPUT/FORWARD/OUTPUT ACCEPT
	//     -t filter/nat/mangle -F   and   -X
	//
	// That is not CSF removal. It destroys EVERY foreign rule in filter, nat
	// and mangle regardless of ownership. Proven on el9-clean across three
	// separate arms: an operator-owned mangle chain (OPERATOR_QOS) and
	// Docker-shaped chains were destroyed alongside CSF's rules, with the
	// installer's own log line `flushed all iptables rules (filter/nat/mangle)`
	// as the causal witness.
	//
	//     HARD REMOVE CSF = YES        HARD FLUSH ALL IPTABLES = NO
	//
	// Ownership is not implied by table name — the same lesson v1.228.11
	// applied to the nft path, which this interface bypassed entirely.
	// CSF-owned kernel state is removed by `csf --stop` inside
	// disarmCSFArtifacts, which unwinds exactly what CSF created and nothing
	// else. Foreign rules NFTBan cannot attribute are left alone.

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

	// CSF-CLOSE-2 CORRECTED 2026-08-12 after package-native runtime validation.
	//
	// This previously ran `csf --stop`, on the assumption that CSF unwinding
	// its own ruleset was "attributable" removal. MEASURED ON el9-clean, IT IS
	// NOT: `csf --stop` flushes filter/nat/mangle wholesale, exactly like the
	// blanket flush CLOSE-3 deleted.
	//
	//     seed OPERATOR_QOS=2, CSF rules=129
	//     csf --stop  ->  OPERATOR_QOS=0, CSF rules=0
	//
	// Delegating the flush to the vendor does not make it attributable — it
	// only changes who issues it. The operator's mangle chain is destroyed
	// either way, which is precisely the hard limit:
	//
	//     HARD REMOVE CSF = YES        HARD FLUSH ALL IPTABLES = NO
	//
	// So NO vendor stop is invoked. CSF's kernel rules are left in place and
	// become INERT once every execution plane below is neutralized: services
	// masked, both binaries renamed, cron persistence removed. CSF cannot
	// re-arm them, and nothing NFTBan cannot attribute is destroyed.
	//
	// Residual (stated, not hidden): stale CSF rules may remain in the legacy
	// iptables tables until an operator clears them deliberately. That is a
	// cosmetic residue with no authority behind it — strictly preferable to
	// destroying operator state we did not create.

	// Remove CSF/LFD cron persistence. CSF-CLOSE-2 widened this beyond the
	// original two files: el9-clean runtime showed /etc/cron.d/csf_update
	// (`csf -u`, daily) surviving every takeover, and the TESTING="1" mode
	// writes a ROOT flush job into /etc/crontab itself — a re-entry surface
	// with zero prior coverage (repo-wide grep for /etc/crontab: 0 hits).
	for _, cronFile := range []string{
		"/etc/cron.d/lfd-cron",
		"/etc/cron.d/csf-cron",
		"/etc/cron.d/csf_update",
	} {
		if exec.FileExists(cronFile) {
			res := exec.Run("rm", "-f", cronFile)
			if res.ExitCode == 0 {
				log.Info("removed CSF cron: %s", cronFile)
			} else {
				log.Warn("failed to remove %s: %s", cronFile, res.Stderr)
			}
		}
	}

	// /etc/crontab is shared with the distro and operator, so this strips ONLY
	// lines invoking the CSF binaries — never the file, never unrelated jobs.
	// (`ATTRIBUTION BEFORE NEUTRALIZATION`: same rule applied to nft tables in
	// v1.228.11 and to iptables in CSF-CLOSE-3.)
	if exec.FileExists("/etc/crontab") {
		if data, err := exec.ReadFile("/etc/crontab"); err == nil {
			var kept []string
			removed := 0
			for _, line := range strings.Split(string(data), "\n") {
				if strings.Contains(line, "/usr/sbin/csf") || strings.Contains(line, "/usr/sbin/lfd") {
					removed++
					continue
				}
				kept = append(kept, line)
			}
			if removed > 0 {
				if err := exec.WriteFileAtomic("/etc/crontab", []byte(strings.Join(kept, "\n")), 0644); err != nil {
					log.Warn("could not strip %d CSF line(s) from /etc/crontab: %v", removed, err)
				} else {
					log.Info("removed %d CSF persistence line(s) from /etc/crontab", removed)
				}
			}
		}
	}

	// Neutralize BOTH CSF executables. lfd was previously left executable even
	// though takeover masks lfd.service — leaving a re-entry path whenever the
	// unit could be re-enabled. Renaming (not deleting) keeps the payload on
	// disk as audit/troubleshooting evidence; it carries no restore contract
	// (CSF_RESTORE_SUPPORT = REMOVED, owner doctrine 2026-08-11).
	for _, bin := range []string{"/usr/sbin/csf", "/usr/sbin/lfd"} {
		if exec.FileExists(bin) {
			res := exec.Run("mv", bin, bin+".disabled")
			if res.ExitCode == 0 {
				log.Info("disabled CSF binary: %s -> %s.disabled", bin, bin)
			} else {
				log.Warn("failed to disable %s: %s", bin, res.Stderr)
			}
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
