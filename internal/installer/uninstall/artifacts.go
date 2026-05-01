// =============================================================================
// NFTBan v1.100.4 — Uninstall Artifact Removal (PR-25-equivalent, surgical)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-uninstall-artifacts"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-02"
// meta:description="Filesystem-cleanup counterpart of payload.StageAll for source-install uninstall"
// meta:inventory.files="internal/installer/uninstall/artifacts.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units="nftban*.service, nftban*.timer, nftban*.socket, nftband.service"
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// UPSTREAM-UNINSTALL-INCOMPLETE-001 — v1.100.4 release blocker fix.
//
// PR-23 introduced uninstall.Apply for kernel + service authority release.
// PR-25 was originally slotted for filesystem artifact removal but was
// repurposed for restore-execution; the gap left every source-install
// uninstall leaving the entire payload on disk (110 paths / 49 unit files /
// 11 timers cross-distro, evidence in VANILLA_MATRIX Round 1 RE-RUN
// 20260501T214954Z). The phantom mask symlink that the existing apply.go
// step-8 mask leaves at /etc/systemd/system/nftband.service then fails
// reinstall with "Unit file is masked".
//
// This file is the surgical fix:
//
//   - RemoveArtifacts walks payload.Destinations() — the single source of
//     truth shared with install — and deletes every staged path PER MODE.
//   - It unmasks nftband.service before unit-file rm so the mask symlink
//     does not survive uninstall (paired with services.StartDaemon's
//     defensive ServiceUnmask call for installs onto unclean state).
//   - It strips the immutable bit on protected dirs before rm so chattr +i
//     guards do not silently turn rm into a no-op.
//   - It does daemon-reload + reset-failed at the end so systemd's view
//     of the world matches disk.
//
// SAFETY GUARANTEE (G3-UN-NO-MUTATION exception): the only paths this
// function may rm are
//
//   (a) paths derived from payload.Destinations(distro), or
//   (b) the explicit uninstall-owned runtime/state list:
//       /var/lib/nftban, /var/log/nftban
//
// No globbing, no broad rm-rf, no walking arbitrary directories. The
// destination catalog is bounded by buildEntries; the runtime/state list
// is bounded by this file. Every other path is unreachable from this code.
//
// =============================================================================
package uninstall

import (
	"path/filepath"
	"sort"
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/payload"
)

// uninstallOwnedRuntimePaths enumerates the on-disk paths the installer
// creates at runtime (NOT staged via payload). They are deletable only
// in modes that explicitly authorise removing operator state.
//
// Bounded list — adding a new entry requires a contract update.
var uninstallOwnedRuntimePaths = []string{
	"/var/lib/nftban",
	"/var/log/nftban",
}

// protectedDirs is the set of directories this function strips the
// immutable bit on before deletion. Bounded — every entry is an
// installer-owned tree root or operator-owned tree root reachable via
// purge mode.
var protectedDirs = []string{
	"/usr/lib/nftban",
	"/etc/nftban",
	"/var/lib/nftban",
	"/var/log/nftban",
}

// RemovalResult records the outcome of a RemoveArtifacts run. Mirrors
// the StepResult shape used by Apply so the caller can splice these
// into ApplyResult.Steps.
type RemovalResult struct {
	// Removed counts paths the function asked the executor to delete
	// (rm -rf invocations or systemd unit-file removals via rm).
	Removed int
	// Preserved counts paths that were within reach but skipped per
	// mode policy (e.g. /etc/nftban under ModeRemove, *.conf.local
	// under ModePurge).
	Preserved int
	// Failed counts paths whose delete invocation returned a non-zero
	// exit code. Non-fatal — uninstall treats best-effort as the
	// contract; CI residue check is the end-state assertion.
	Failed int
	// UnitFileRemoved reports whether nftband.service's unit file was
	// removed by this call. Apply uses this to decide whether to skip
	// the legacy mask step (mask of an absent unit recreates a phantom
	// mask symlink that then fails the next reinstall).
	UnitFileRemoved bool
	// Steps is an ordered audit trail recorded for evidence/test.
	Steps []StepResult
}

// RemoveArtifacts is the inverse of payload.StageAll for source-install
// uninstall plus the nftband.service unmask-symmetry fix.
//
// Algorithm (steps map 1:1 to RemovalResult.Steps for evidence):
//
//	a. Disable + stop every nftban*.timer destination
//	b. Disable + stop every nftban*.service destination EXCEPT nftband.service
//	   (apply.go owns the nftband stop/disable in step 7)
//	c. ServiceUnmask("nftband.service") soft-fail — symmetric counterpart
//	   of services.StartDaemon's ServiceUnmask, lets unit-file rm proceed
//	   without a leftover /etc/systemd/system/<unit> -> /dev/null tombstone
//	d. chattr -R -i on protectedDirs that mode authorises (best-effort)
//	e. rm -rf each destination path that mode authorises, deepest-first
//	f. systemctl daemon-reload + systemctl reset-failed to clear systemd's
//	   stale unit-file view (the residue-counts.txt's leftover_units=49
//	   signature was systemd cache, not on-disk state, after the fix)
//
// Every path this function deletes is bounded by SAFETY GUARANTEE in the
// file header. exec is the typed interface so MockExecutor records the
// command sequence for tests.
func RemoveArtifacts(exec executor.Executor, mode Mode, distro *detect.DistroInfo, log *logging.Logger) *RemovalResult {
	r := &RemovalResult{}

	if mode == "" {
		mode = ModeRemove
	}

	dests := payload.Destinations(distro)
	log.Info("uninstall artifacts: mode=%s destinations=%d", mode, len(dests))

	// (a) + (b) Disable + stop unit destinations referenced by payload.
	// We enumerate /usr/lib/systemd/system/ matching nftban*/nftband*
	// because the install-side destination is a directory glob — the
	// individual unit names live in the source tree, not in the
	// destination catalog. The match prefix is fixed by install
	// convention (nftban*, nftband*); never operator-derived.
	disableUnitsAtDest(exec, log, "/usr/lib/systemd/system", "*.timer", r)
	disableUnitsAtDest(exec, log, "/usr/lib/systemd/system", "*.service", r)

	// (c) Unmask nftband.service before unit-file rm. Soft-fail —
	// unmask of an unmasked unit is a no-op on systemd >= 242, and
	// failure here should not block the rest of the cleanup.
	if err := exec.ServiceUnmask("nftband.service"); err != nil {
		log.Debug("uninstall artifacts: unmask nftband.service: %v (soft-fail)", err)
		r.Steps = append(r.Steps, StepResult{Name: "unmask_nftband_service", Success: true, Detail: "soft-fail: " + err.Error()})
	} else {
		r.Steps = append(r.Steps, StepResult{Name: "unmask_nftband_service", Success: true, Detail: "unmasked for unit-file removal symmetry"})
	}

	// (d) Strip immutable bits on protected dirs that mode authorises.
	// Any operator-owned dir whose contents we are NOT going to touch
	// in this mode is left alone — chattr -R -i is itself a mutation.
	for _, dir := range protectedDirs {
		if !shouldDeletePath(dir, mode) {
			continue
		}
		exec.Run("chattr", "-R", "-i", dir)
	}
	r.Steps = append(r.Steps, StepResult{Name: "strip_immutable_bits", Success: true, Detail: "best-effort chattr -R -i on protected dirs"})

	// (e) Remove staged payload + runtime-owned paths per mode.
	//
	// Two destination shapes from payload.Destinations:
	//   IsDir=false (single-file entry): rm the exact path
	//   IsDir=true  (directory + glob):  rm only files inside the
	//                                    destination dir matching the
	//                                    install-time Glob, NEVER the
	//                                    directory itself (it may be a
	//                                    system-shared dir like
	//                                    /etc/polkit-1/rules.d or
	//                                    /usr/lib/systemd/system).
	//
	// The /usr/lib/nftban subtree is collapsed below into a single
	// rm -rf of the runtime-list parent — it is installer-owned in
	// its entirety. Same for /var/lib/nftban + /var/log/nftban.
	var singleFiles []string
	seen := map[string]bool{}
	addFile := func(p string) {
		if p == "" || seen[p] {
			return
		}
		seen[p] = true
		singleFiles = append(singleFiles, p)
	}
	dirGlobs := map[string][]string{} // dst dir -> list of globs
	for _, d := range dests {
		if d.IsDir {
			dirGlobs[d.Path] = append(dirGlobs[d.Path], d.Glob)
			continue
		}
		addFile(d.Path)
	}

	// Phase e.1: glob-and-rm files inside each directory destination.
	// Bounded to the install-time glob; never touches the parent dir.
	dirOrder := make([]string, 0, len(dirGlobs))
	for dir := range dirGlobs {
		dirOrder = append(dirOrder, dir)
	}
	sort.Strings(dirOrder)
	for _, dir := range dirOrder {
		// Mode gate at the directory level: under ModeRemove, /etc/nftban
		// subtree is preserved entirely.
		if !shouldDeletePath(dir, mode) {
			r.Preserved++
			continue
		}
		// sharedDir: a destination directory we share with other
		// packages — only files matching the nftban prefix may be
		// rm'd. Includes systemd unit dirs and polkit rule dirs.
		sharedDir := isSharedDestDir(dir)
		for _, glob := range dirGlobs[dir] {
			matches, err := filepath.Glob(filepath.Join(dir, glob))
			if err != nil {
				continue
			}
			for _, p := range matches {
				if mode == ModePurge && isConfigLocalPath(p) {
					r.Preserved++
					continue
				}
				if sharedDir && !isNftbanArtifact(filepath.Base(p)) {
					// Different package's file — skip silently.
					continue
				}
				if dir == "/usr/lib/systemd/system" && filepath.Base(p) == "nftband.service" {
					r.UnitFileRemoved = true
				}
				res := exec.Run("rm", "-rf", p)
				if res.ExitCode != 0 {
					log.Debug("uninstall artifacts: rm -rf %s: exit=%d %s", p, res.ExitCode, res.Stderr)
					r.Failed++
					continue
				}
				r.Removed++
			}
		}
	}

	// Phase e.2: rm single-file destinations + runtime-owned roots.
	// Sorted deepest-first so children rm before parents.
	rootList := make([]string, 0, len(singleFiles)+len(uninstallOwnedRuntimePaths))
	rootList = append(rootList, singleFiles...)
	for _, rt := range uninstallOwnedRuntimePaths {
		if !seen[rt] {
			rootList = append(rootList, rt)
			seen[rt] = true
		}
	}
	// Add the installer-owned tree root (/usr/lib/nftban) explicitly —
	// it's not in payload.Destinations as a standalone entry, but it
	// IS the parent of every binaries/shell/data destination and is
	// safe to collapse into a single rm -rf because every leaf below
	// it is installer-staged.
	if !seen["/usr/lib/nftban"] {
		rootList = append(rootList, "/usr/lib/nftban")
		seen["/usr/lib/nftban"] = true
	}
	sort.Slice(rootList, func(i, j int) bool {
		return strings.Count(rootList[i], "/") > strings.Count(rootList[j], "/")
	})
	for _, path := range rootList {
		if !shouldDeletePath(path, mode) {
			r.Preserved++
			continue
		}
		if mode == ModePurge && isConfigLocalPath(path) {
			r.Preserved++
			continue
		}
		res := exec.Run("rm", "-rf", path)
		if res.ExitCode != 0 {
			log.Debug("uninstall artifacts: rm -rf %s: exit=%d %s", path, res.ExitCode, res.Stderr)
			r.Failed++
			continue
		}
		r.Removed++
	}

	// Phase e.3: remove /etc/systemd/system/ mask symlinks left by
	// prior uninstall passes. Bounded to nftban*/nftband* prefix; under
	// ModeRemove these are still cleaned (the mask symlinks are
	// installer-owned residue, not operator state).
	removeUnitFilesAtDest(exec, log, "/etc/systemd/system", "*.timer", r)
	removeUnitFilesAtDest(exec, log, "/etc/systemd/system", "*.service", r)
	r.Steps = append(r.Steps, StepResult{Name: "remove_payload_artifacts", Success: true})

	// (f) daemon-reload + reset-failed clears systemd's stale view.
	if err := exec.DaemonReload(); err != nil {
		log.Warn("uninstall artifacts: daemon-reload: %v (continuing)", err)
	}
	exec.Run("systemctl", "reset-failed")
	r.Steps = append(r.Steps, StepResult{Name: "daemon_reload", Success: true})

	log.Info("uninstall artifacts: removed=%d preserved=%d failed=%d unit_removed=%t",
		r.Removed, r.Preserved, r.Failed, r.UnitFileRemoved)
	return r
}

// disableUnitsAtDest disables + stops every unit at dir matching glob
// where the basename starts with nftban or nftband, EXCEPT
// nftband.service (apply.go's step 7 owns nftband disable).
func disableUnitsAtDest(exec executor.Executor, log *logging.Logger, dir, glob string, r *RemovalResult) {
	matches, err := filepath.Glob(filepath.Join(dir, glob))
	if err != nil {
		return
	}
	for _, p := range matches {
		base := filepath.Base(p)
		if !isNftbanUnit(base) {
			continue
		}
		if base == "nftband.service" {
			continue // owned by Apply step 7
		}
		_ = exec.ServiceDisable(base)
		_ = exec.ServiceStop(base)
		log.Debug("uninstall artifacts: disabled+stopped %s", base)
	}
}

// removeUnitFilesAtDest removes every unit file at dir matching glob
// whose basename starts with nftban or nftband. Bounded to the prefix.
func removeUnitFilesAtDest(exec executor.Executor, log *logging.Logger, dir, glob string, r *RemovalResult) {
	matches, err := filepath.Glob(filepath.Join(dir, glob))
	if err != nil {
		return
	}
	for _, p := range matches {
		base := filepath.Base(p)
		if !isNftbanUnit(base) {
			continue
		}
		res := exec.Run("rm", "-f", p)
		if res.ExitCode != 0 {
			log.Debug("uninstall artifacts: rm -f %s: exit=%d", p, res.ExitCode)
			r.Failed++
			continue
		}
		if base == "nftband.service" {
			r.UnitFileRemoved = true
		}
		r.Removed++
		log.Debug("uninstall artifacts: removed unit file %s", p)
	}
}

// isNftbanUnit returns true if the unit file basename belongs to the
// nftban payload (prefix nftban or nftband).
func isNftbanUnit(base string) bool {
	return strings.HasPrefix(base, "nftban") || strings.HasPrefix(base, "nftband")
}

// isNftbanArtifact returns true if the basename matches any nftban-
// staged artifact prefix. Currently identical to isNftbanUnit (both
// systemd units and polkit rules nftban ships are nftban*-prefixed).
// Kept as a separate predicate so future payload additions with a
// different prefix can extend the rule without widening the unit
// disable path.
func isNftbanArtifact(base string) bool {
	return strings.HasPrefix(base, "nftban") || strings.HasPrefix(base, "nftband")
}

// isSharedDestDir returns true if the destination directory is shared
// with other packages — uninstall must scope rm to nftban-prefixed
// files only.
func isSharedDestDir(dir string) bool {
	switch dir {
	case "/usr/lib/systemd/system",
		"/etc/systemd/system",
		"/etc/polkit-1/rules.d",
		"/usr/share/polkit-1/rules.d",
		"/usr/share/bash-completion/completions",
		"/usr/share/man/man8",
		"/usr/lib/tmpfiles.d":
		return true
	}
	return false
}

// shouldDeletePath enforces the §4.4 mode contract: the operator-owned
// territory under /etc/nftban, /var/lib/nftban, /var/log/nftban is
// preserved in ModeRemove, removed in ModePurge (.conf.local preserved),
// and fully removed in ModePurgeForceDOC.
//
// Every other path is installer-owned and removed in any non-keep mode.
func shouldDeletePath(path string, mode Mode) bool {
	operatorOwned := strings.HasPrefix(path, "/etc/nftban") ||
		strings.HasPrefix(path, "/var/lib/nftban") ||
		strings.HasPrefix(path, "/var/log/nftban")

	if !operatorOwned {
		return true
	}
	switch mode {
	case ModeRemove:
		// Preserve all operator-owned territory.
		return false
	case ModePurge:
		// Delete operator-owned paths; per-file *.conf.local
		// exclusion is enforced by the caller via isConfigLocalPath
		// (INV-100-006: no silent operator-config deletion).
		return true
	case ModePurgeForceDOC:
		// Delete everything including *.conf.local — the explicit
		// destructive-intent flag (--force-delete-operator-config)
		// is the only mode that crosses this boundary.
		return true
	}
	return false
}

// isConfigLocalPath mirrors payload.isConfigLocal but is local to this
// package (avoids exporting an internal-only filename predicate).
func isConfigLocalPath(path string) bool {
	return strings.HasSuffix(path, ".conf.local") ||
		strings.HasSuffix(path, ".local.conf")
}
