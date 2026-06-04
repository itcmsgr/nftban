// =============================================================================
// NFTBan v1.98.x - Installer Payload Staging Helpers (PR-14-pre)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-payload-idempotency"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-19"
// meta:description="Copy-if-changed + .conf.local / %config(noreplace) semantics"
// meta:inventory.files="internal/installer/payload/idempotency.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// Shared helpers for the payload package:
//   - copyIfChanged:     skip write when src and dst are byte-identical.
//   - isConfigLocal:     filter that refuses to touch .conf.local files.
//   - shouldPreserveCfg: %config(noreplace) semantics for template configs.
//
// These guard the two hardest invariants for source-install payload staging:
//   1. Invariant #9: never read/write .conf.local (override model preserved).
//   2. %config(noreplace) parity: operator-edited template configs preserved.
//
// =============================================================================

package payload

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// overwritePolicy controls when an existing destination is preserved vs replaced.
type overwritePolicy int

const (
	// policyAlways replaces the destination regardless of existing content.
	// Used for product artifacts (binaries, systemd units, polkit rules,
	// logrotate config, bash completion, templates, .default reference files).
	policyAlways overwritePolicy = iota

	// policyConfigNoReplace mimics RPM's %config(noreplace) and DEB's conffile
	// semantics: if the destination exists, preserve it (operator may have
	// edited it). Used for /etc/nftban/nftban.conf, conf.d/*.conf, and the
	// 99-manual.conf templates.
	policyConfigNoReplace

	// policyConfigPreserve (v1.148, V148_CONFIG_PRESERVATION_CONTRACT) is the
	// 3-way "rpm conffile" algorithm for the unified /etc/nftban/conf.d tree:
	// replace an unmodified config with the new default, but PRESERVE an
	// operator-modified one (writing the new default as a .nftban-new sidecar +
	// WARN_CONFIG_LOCAL_PRESERVED). Uses a prior-default baseline under
	// /usr/share/nftban/defaults/conf.d to tell "unmodified" from "edited".
	// PACKAGED DEFAULTS are not USER STATE — never blind-overwrite /etc.
	policyConfigPreserve
)

// configDefaultsBaseDir holds the as-shipped default of each managed config so
// the next update can tell an operator-edited file from an untouched one
// (mirrors how rpm keeps the old %config to drive .rpmnew). v1.148.
const configDefaultsBaseDir = "/usr/share/nftban/defaults"

// configSidecarSuffix is appended to a preserved local config's path to deliver
// the new upstream default for manual review (parity with .rpmnew/.dpkg-dist).
const configSidecarSuffix = ".nftban-new"

// ConfigPreserveAction is the per-file outcome of policyConfigPreserve staging.
type ConfigPreserveAction string

const (
	ConfigInstalled ConfigPreserveAction = "installed" // dst absent → seeded with default
	ConfigUpdated   ConfigPreserveAction = "updated"   // dst == prior default → replaced
	ConfigPreserved ConfigPreserveAction = "preserved" // dst operator-modified → kept; default → sidecar
	ConfigUnchanged ConfigPreserveAction = "unchanged" // dst already == new default → no-op
)

// ConfigPreserveEntry is one row of the config-preservation report (contract §6).
type ConfigPreserveEntry struct {
	Path    string
	Action  ConfigPreserveAction
	Sidecar string // populated when Action==ConfigPreserved
}

// baselinePathFor maps a managed /etc config dst to its defaults-baseline path,
// e.g. /etc/nftban/conf.d/login/main.conf → /usr/share/nftban/defaults/conf.d/login/main.conf.
func baselinePathFor(dst string) string {
	return filepath.Join(configDefaultsBaseDir, strings.TrimPrefix(dst, "/etc/nftban"))
}

// preserveOrStageConfig implements the V148_CONFIG_PRESERVATION_CONTRACT for one
// file. srcContent is the NEW upstream default. It never blind-overwrites an
// operator-edited /etc file; it refreshes the defaults baseline so the next
// update can compare correctly. .conf.local files are never touched (guarded).
func preserveOrStageConfig(exec executor.Executor, srcContent []byte, dst string, mode os.FileMode, log *logging.Logger) (ConfigPreserveEntry, error) {
	entry := ConfigPreserveEntry{Path: dst}
	if isConfigLocal(dst) {
		log.Debug("payload.preserveOrStageConfig: refusing .conf.local: %s", dst)
		entry.Action = ConfigPreserved
		return entry, nil
	}
	baseline := baselinePathFor(dst)

	// 1. Fresh: target absent → seed the default.
	if !exec.FileExists(dst) {
		if _, err := copyIfChanged(exec, srcContent, dst, mode, log); err != nil {
			return entry, err
		}
		entry.Action = ConfigInstalled
		log.Info("config: installed default %s", dst)
		_ = refreshBaseline(exec, srcContent, baseline, mode, log)
		return entry, nil
	}

	existing, err := exec.ReadFile(dst)
	if err != nil {
		return entry, fmt.Errorf("read %s: %w", dst, err)
	}

	// Already equal to the new default → nothing to do (still refresh baseline).
	if bytes.Equal(existing, srcContent) {
		entry.Action = ConfigUnchanged
		_ = refreshBaseline(exec, srcContent, baseline, mode, log)
		return entry, nil
	}

	// 2. Target == prior packaged default → operator never edited → replace.
	var priorDefault []byte
	if exec.FileExists(baseline) {
		priorDefault, _ = exec.ReadFile(baseline)
	}
	if priorDefault != nil && bytes.Equal(existing, priorDefault) {
		if _, err := copyIfChanged(exec, srcContent, dst, mode, log); err != nil {
			return entry, err
		}
		entry.Action = ConfigUpdated
		log.Info("config: updated %s (was unchanged from prior default)", dst)
		_ = refreshBaseline(exec, srcContent, baseline, mode, log)
		return entry, nil
	}

	// 3. Target differs from prior default (operator-modified, or no baseline) →
	//    PRESERVE local; deliver new default as a sidecar; WARN.
	sidecar := dst + configSidecarSuffix
	if _, err := copyIfChanged(exec, srcContent, sidecar, mode, log); err != nil {
		return entry, fmt.Errorf("write sidecar %s: %w", sidecar, err)
	}
	entry.Action = ConfigPreserved
	entry.Sidecar = sidecar
	log.Warn("WARN_CONFIG_LOCAL_PRESERVED: kept operator-modified %s; new default written to %s (review: diff %s %s)", dst, sidecar, dst, sidecar)
	_ = refreshBaseline(exec, srcContent, baseline, mode, log)
	return entry, nil
}

// refreshBaseline updates the defaults baseline to the new default so the next
// update's "unmodified?" comparison is against the right prior default.
func refreshBaseline(exec executor.Executor, srcContent []byte, baseline string, mode os.FileMode, log *logging.Logger) error {
	_, err := copyIfChanged(exec, srcContent, baseline, mode, log)
	return err
}

// copyIfChanged writes src-content to dst only if the content differs from
// what is already at dst (or if dst does not exist). Returns wrote=true if
// a write actually occurred.
//
// Skips writes when bytes are identical — preserves mtime for unchanged
// files, reduces installer-log noise on re-runs, and makes source-install
// idempotency observable at the file-system level.
//
// The mode is applied on write. Ownership is NOT set here — payload relies
// on fhs.SetPermissions() in phasePrepare to enforce the central FHS
// registry rules after all files are in place.
func copyIfChanged(exec executor.Executor, srcContent []byte, dst string, mode os.FileMode, log *logging.Logger) (wrote bool, err error) {
	// Safety: never stage into a .conf.local path. Invariant #9 violation if
	// this slips through the caller's filtering.
	if isConfigLocal(dst) {
		log.Debug("payload.copyIfChanged: refusing to write .conf.local destination: %s", dst)
		return false, nil
	}

	if exec.FileExists(dst) {
		existing, err := exec.ReadFile(dst)
		if err == nil && bytes.Equal(existing, srcContent) {
			log.Debug("payload: unchanged %s (%d bytes)", dst, len(srcContent))
			return false, nil
		}
	}

	// Defensive MkdirAll: fhs.EnsureDirectories covers the canonical FHS registry
	// but not every payload-destination subdirectory (e.g. /usr/lib/nftban/cli,
	// /usr/lib/nftban/sbin, /etc/nftban/templates). Creating the parent here
	// keeps payload staging self-sufficient. 0755 is a safe default for system
	// directories; fhs.SetPermissions runs after payload and corrects ownership
	// per the canonical registry where entries exist.
	if parent := filepath.Dir(dst); parent != "" && parent != "/" {
		if err := exec.MkdirAll(parent, 0755); err != nil {
			return false, fmt.Errorf("mkdir %s: %w", parent, err)
		}
	}

	if err := exec.WriteFileAtomic(dst, srcContent, mode); err != nil {
		return false, fmt.Errorf("write %s: %w", dst, err)
	}
	log.Debug("payload: wrote %s (%d bytes, mode %o)", dst, len(srcContent), mode)
	return true, nil
}

// isConfigLocal returns true if the path is a .conf.local override file.
// Invariant #9: installer code must never read or write these — they are
// operator-owned.
//
// Matches both:
//   - .conf.local suffix (e.g. nftban.conf.local, ddos.conf.local)
//   - .local.conf suffix (defensive — either spelling is treated as operator
//     territory)
func isConfigLocal(path string) bool {
	return strings.HasSuffix(path, ".conf.local") ||
		strings.HasSuffix(path, ".local.conf")
}

// shouldPreserveConfig implements %config(noreplace) semantics: returns true
// when dst exists and should NOT be overwritten (operator content preserved).
//
// Called only for entries with policyConfigNoReplace. Always returns false
// for policyAlways entries regardless of destination state.
func shouldPreserveConfig(exec executor.Executor, dst string, policy overwritePolicy, log *logging.Logger) bool {
	if policy != policyConfigNoReplace {
		return false
	}
	if !exec.FileExists(dst) {
		return false
	}
	log.Debug("payload: preserving existing config (noreplace semantics): %s", dst)
	return true
}
