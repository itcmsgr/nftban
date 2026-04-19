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
)

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
