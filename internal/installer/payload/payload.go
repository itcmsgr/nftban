// =============================================================================
// NFTBan v1.98.x - Installer Payload Staging (PR-14-pre G-14-B..G)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-payload"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-19"
// meta:description="Source-install payload staging from repo/tarball to FHS destinations"
// meta:inventory.files="internal/installer/payload/payload.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// Package installs (RPM/DEB) extract files into FHS destinations via the
// package payload. The Go installer then only enforces FHS permissions on
// already-present files. For source install (cfg.source == true), there is
// no package manager — this package stages the files from a source tree
// (repo clone or extracted tarball) to the canonical destinations.
//
// Scope: gaps G-14-B through G-14-G per V198_PR14_PRE_SOURCE_INSTALL_SPEC.md:
//   G-14-B: Go binaries (nftban-core, nftband, nftban-validate, nftban-installer,
//           /usr/sbin/nftban, /usr/sbin/nftban-ui, /usr/libexec/nftban-ui-auth)
//   G-14-C: Shell scripts (cli/lib/nftban/{cli,core,helpers,lib,data,health}/*)
//   G-14-D: Configs (/etc/nftban/*, patterns.d, templates)
//   G-14-E: Systemd units + tmpfiles.d
//   G-14-F: Polkit rules (distro-conditional destination)
//   G-14-G: Logrotate (canonical — resolves pre-existing source-install drift)
//
// Gating: StageAll is invoked from phasePrepare ONLY when pd.source == true.
// The cfg.source == false path (RPM/DEB) never reaches this code.
//
// UI staging: nftban-ui + nftban-ui-auth + PAM config are included but marked
// with REMOVE-IN-V2.0.0 comments. v2.0.0 PR-D4 removes these mechanically.
//
// =============================================================================

package payload

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// StageAll stages every source-install payload from srcDir to its FHS
// destination. Idempotent: copyIfChanged skips unchanged files, and
// %config(noreplace) entries preserve existing operator-edited content.
//
// srcDir must be the root of a repo clone or extracted release tarball
// (i.e. the directory that contains bin/, cli/, install/, etc.).
//
// Returns an error only on unrecoverable failures. Individual file-copy
// failures are logged and counted; the orchestrator continues so one bad
// entry does not abort the whole staging pass.
func StageAll(exec executor.Executor, srcDir string, distro *detect.DistroInfo, log *logging.Logger) error {
	if srcDir == "" {
		return fmt.Errorf("payload.StageAll: srcDir is empty")
	}
	if !exec.FileExists(srcDir) {
		return fmt.Errorf("payload.StageAll: srcDir does not exist: %s", srcDir)
	}

	log.Info("payload: staging from %s", srcDir)

	entries := buildEntries(distro)
	var wrote, skipped, failed int

	for _, e := range entries {
		if e.uiRemoveInV2 {
			log.Debug("payload: staging UI-related entry (REMOVE-IN-V2.0.0): %s", e.dstGlob)
		}
		ew, es, ef := stageEntry(exec, srcDir, e, log)
		wrote += ew
		skipped += es
		failed += ef
	}

	log.Info("payload: staging complete — wrote=%d skipped=%d failed=%d", wrote, skipped, failed)
	if failed > 0 {
		// Failures are non-fatal during staging — log count for visibility
		// but let phaseValidate catch any downstream breakage.
		log.Warn("payload: %d file(s) failed to stage (non-fatal, see earlier log entries)", failed)
	}
	return nil
}

// entry describes one source-to-destination staging rule.
//
// One entry can represent either a single file pair or a directory with a
// glob pattern — the stageEntry dispatcher inspects isDir and srcGlob to
// pick the right copy path.
type entry struct {
	// srcRel is the source path relative to srcDir. For glob entries it
	// is the source-directory root (e.g. "install/systemd").
	srcRel string

	// srcGlob is the glob pattern within srcRel for multi-file entries
	// (e.g. "*.service", "*.timer"). Empty for single-file entries.
	srcGlob string

	// dstGlob is the destination directory for multi-file entries or the
	// exact destination path for single-file entries.
	dstGlob string

	// mode is the file mode applied at write time.
	mode os.FileMode

	// policy controls overwrite behavior for existing destinations.
	policy overwritePolicy

	// isDir indicates a directory-glob entry (vs single file).
	isDir bool

	// optional indicates the source may be absent without error (e.g. man
	// page files that are not always shipped).
	optional bool

	// uiRemoveInV2 marks UI-related entries that must be removed in v2.0.0
	// as part of PR-D4. CI can grep for this marker pre-decommission.
	//
	// REMOVE-IN-V2.0.0: UI decommission (PR-D4)
	uiRemoveInV2 bool
}

// buildEntries constructs the full payload destination table.
//
// The table encodes the destination contract from
// V198_PR14_PRE_SOURCE_INSTALL_SPEC.md §3.2. Distro-conditional entries
// (currently only polkit) branch on distro.ID via distroPolkitDir().
func buildEntries(distro *detect.DistroInfo) []entry {
	polkitDst := "/etc/polkit-1/rules.d"
	if distro != nil && isDebianFamily(distro.ID) {
		// Debian policy: third-party polkit rules go under /usr/share/polkit-1/
		// per packaging/deb/postinst convention (v1.0.19 Bug #18 fix).
		polkitDst = "/usr/share/polkit-1/rules.d"
	}

	return []entry{
		// -----------------------------------------------------------------
		// G-14-B: Go binaries + CLI sbin entries
		// -----------------------------------------------------------------
		{srcRel: "bin/nftban-core", dstGlob: "/usr/lib/nftban/bin/nftban-core", mode: 0755, policy: policyAlways},
		{srcRel: "bin/nftband", dstGlob: "/usr/lib/nftban/bin/nftband", mode: 0755, policy: policyAlways},
		{srcRel: "bin/nftban-validate", dstGlob: "/usr/lib/nftban/bin/nftban-validate", mode: 0755, policy: policyAlways},
		{srcRel: "bin/nftban-installer", dstGlob: "/usr/lib/nftban/bin/nftban-installer", mode: 0755, policy: policyAlways},

		// Canonical privileged CLI binary (NB-5 perms).
		{srcRel: "cli/sbin/nftban", dstGlob: "/usr/sbin/nftban", mode: 0750, policy: policyAlways},

		// Auxiliary CLI helpers.
		{srcRel: "cli/sbin/nftban-apply", dstGlob: "/usr/lib/nftban/sbin/nftban-apply", mode: 0755, policy: policyAlways},
		{srcRel: "cli/sbin/nftban-confirm", dstGlob: "/usr/lib/nftban/sbin/nftban-confirm", mode: 0755, policy: policyAlways},
		{srcRel: "cli/sbin/nftban-panelctl", dstGlob: "/usr/lib/nftban/sbin/nftban-panelctl", mode: 0755, policy: policyAlways},
		{srcRel: "cli/sbin/nftban-queue-processor", dstGlob: "/usr/lib/nftban/sbin/nftban-queue-processor", mode: 0755, policy: policyAlways},
		{srcRel: "cli/sbin/nftban-rollback", dstGlob: "/usr/lib/nftban/sbin/nftban-rollback", mode: 0755, policy: policyAlways},
		{srcRel: "cli/sbin/nftban-service-alert", dstGlob: "/usr/lib/nftban/sbin/nftban-service-alert", mode: 0755, policy: policyAlways},
		{srcRel: "cli/sbin/nftban-botscan-processor", dstGlob: "/usr/lib/nftban/sbin/nftban-botscan-processor", mode: 0755, policy: policyAlways},

		// -----------------------------------------------------------------
		// REMOVE-IN-V2.0.0: UI decommission (PR-D4)
		// -----------------------------------------------------------------
		{srcRel: "bin/nftban-ui", dstGlob: "/usr/sbin/nftban-ui", mode: 0750, policy: policyAlways, uiRemoveInV2: true, optional: true},
		{srcRel: "bin/nftban-ui-auth", dstGlob: "/usr/libexec/nftban-ui-auth", mode: 0755, policy: policyAlways, uiRemoveInV2: true, optional: true},
		// END-REMOVE-IN-V2.0.0

		// -----------------------------------------------------------------
		// G-14-C: Shell payload under /usr/lib/nftban/
		// -----------------------------------------------------------------
		{srcRel: "cli/lib/nftban/cli", srcGlob: "*.sh", dstGlob: "/usr/lib/nftban/cli", mode: 0755, policy: policyAlways, isDir: true},
		{srcRel: "cli/lib/nftban/core", srcGlob: "*.sh", dstGlob: "/usr/lib/nftban/core", mode: 0755, policy: policyAlways, isDir: true},
		{srcRel: "cli/lib/nftban/helpers", srcGlob: "*.sh", dstGlob: "/usr/lib/nftban/helpers", mode: 0755, policy: policyAlways, isDir: true},
		{srcRel: "cli/lib/nftban/lib", srcGlob: "*.sh", dstGlob: "/usr/lib/nftban/lib", mode: 0755, policy: policyAlways, isDir: true},
		{srcRel: "cli/lib/nftban/data", srcGlob: "*", dstGlob: "/usr/lib/nftban/data", mode: 0644, policy: policyAlways, isDir: true},
		{srcRel: "cli/lib/nftban/health", srcGlob: "*.sh", dstGlob: "/usr/lib/nftban/health", mode: 0755, policy: policyAlways, isDir: true},

		// Shipped nftables template (always overwrite — installer-managed,
		// never operator-edited here).
		{srcRel: "cli/lib/nftban/templates/nftables.conf.tpl", dstGlob: "/usr/lib/nftban/templates/nftables.conf.tpl", mode: 0644, policy: policyAlways, optional: true},

		// VERSION file — consumed by cli/lib/nftban/lib/version.sh which is
		// sourced by every CLI subcommand. Package installs stage it via
		// packaging/build_nftban.sh (RPM %install line ~368, DEB ~1837);
		// source install missed it, causing every CLI invocation to crash
		// with "unbound variable" at version.sh:39.
		{srcRel: "VERSION", dstGlob: "/usr/lib/nftban/VERSION", mode: 0644, policy: policyAlways},

		// -----------------------------------------------------------------
		// G-14-D: Configs (/etc/nftban/*)
		// -----------------------------------------------------------------
		// Template configs with %config(noreplace) semantics.
		{srcRel: "install/config/nftban.conf", dstGlob: "/etc/nftban/nftban.conf", mode: 0640, policy: policyConfigNoReplace},
		// nftables.conf is a template with __SSH_PORT__ / __CT_LIMIT_*__
		// placeholders. render.RenderNftablesConf (Prepare step 6) reads
		// this, substitutes, and writes back. Must be staged before render.
		{srcRel: "install/nftables/nftables.conf", dstGlob: "/etc/nftban/nftables.conf", mode: 0640, policy: policyConfigNoReplace},
		{srcRel: "install/config/conf.d", srcGlob: "*.conf", dstGlob: "/etc/nftban/conf.d", mode: 0640, policy: policyConfigNoReplace, isDir: true},

		// Default reference templates (.default files — always overwrite).
		{srcRel: "install/config/conf.d", srcGlob: "*.conf.default", dstGlob: "/etc/nftban/conf.d", mode: 0640, policy: policyAlways, isDir: true},

		// Distro-aware path registry (always overwrite — installer-owned).
		{srcRel: "etc/nftban/distros", srcGlob: "*.conf", dstGlob: "/etc/nftban/distros", mode: 0640, policy: policyAlways, isDir: true},

		// Manual whitelist/blacklist templates (%config(noreplace)).
		// safety.SeedManualWhitelist runs in phaseConfigure after these land.
		{srcRel: "etc/nftban/whitelist.d/99-manual.conf", dstGlob: "/etc/nftban/whitelist.d/99-manual.conf", mode: 0640, policy: policyConfigNoReplace, optional: true},
		{srcRel: "etc/nftban/blacklist.d/99-manual.conf", dstGlob: "/etc/nftban/blacklist.d/99-manual.conf", mode: 0640, policy: policyConfigNoReplace, optional: true},

		// Commands registry.
		{srcRel: "commands.registry.yml", dstGlob: "/etc/nftban/commands.registry.yml", mode: 0644, policy: policyConfigNoReplace, optional: true},

		// -----------------------------------------------------------------
		// G-14-E: Systemd units + tmpfiles.d
		// -----------------------------------------------------------------
		{srcRel: "install/systemd", srcGlob: "*.service", dstGlob: "/usr/lib/systemd/system", mode: 0644, policy: policyAlways, isDir: true},
		{srcRel: "install/systemd", srcGlob: "*.timer", dstGlob: "/usr/lib/systemd/system", mode: 0644, policy: policyAlways, isDir: true},
		{srcRel: "install/systemd", srcGlob: "*.socket", dstGlob: "/usr/lib/systemd/system", mode: 0644, policy: policyAlways, isDir: true},
		{srcRel: "install/systemd/tmpfiles.d/nftban.conf", dstGlob: "/usr/lib/tmpfiles.d/nftban.conf", mode: 0644, policy: policyAlways},

		// -----------------------------------------------------------------
		// G-14-F: Polkit rules (distro-conditional destination)
		// -----------------------------------------------------------------
		{srcRel: "packaging/polkit-1/rules.d", srcGlob: "*.rules", dstGlob: polkitDst, mode: 0644, policy: policyAlways, isDir: true, optional: true},

		// -----------------------------------------------------------------
		// G-14-G: Logrotate — uses the canonical shipped config. Resolves the
		// pre-existing source-install drift where a legacy wildcard logrotate
		// config was auto-generated at install time (see
		// LOG_ROTATION_DOCS_CODE_ALIGNMENT.md).
		// -----------------------------------------------------------------
		{srcRel: "install/config/nftban.logrotate", dstGlob: "/etc/logrotate.d/nftban", mode: 0644, policy: policyAlways},
		{srcRel: "install/config/nftban-suricata.logrotate", dstGlob: "/etc/nftban/templates/nftban-suricata.logrotate", mode: 0644, policy: policyAlways, optional: true},

		// -----------------------------------------------------------------
		// Other shipped artifacts: bash completion, man page (optional)
		// -----------------------------------------------------------------
		{srcRel: "install/bash-completion/nftban", dstGlob: "/usr/share/bash-completion/completions/nftban", mode: 0644, policy: policyAlways, optional: true},
		{srcRel: "install/man/nftban.8", dstGlob: "/usr/share/man/man8/nftban.8", mode: 0644, policy: policyAlways, optional: true},
	}
}

// stageEntry copies a single entry (file or directory glob) to its destination.
// Returns (wrote, skipped, failed) counters for the orchestrator.
func stageEntry(exec executor.Executor, srcDir string, e entry, log *logging.Logger) (wrote, skipped, failed int) {
	if e.isDir {
		return stageGlob(exec, srcDir, e, log)
	}
	return stageSingleFile(exec, srcDir, e, log)
}

// stageSingleFile handles one source→dest file pair.
func stageSingleFile(exec executor.Executor, srcDir string, e entry, log *logging.Logger) (wrote, skipped, failed int) {
	srcPath := filepath.Join(srcDir, e.srcRel)

	if !exec.FileExists(srcPath) {
		if e.optional {
			log.Debug("payload: optional source missing, skipping: %s", srcPath)
			return 0, 1, 0
		}
		log.Warn("payload: required source missing: %s", srcPath)
		return 0, 0, 1
	}

	if shouldPreserveConfig(exec, e.dstGlob, e.policy, log) {
		return 0, 1, 0
	}

	content, err := exec.ReadFile(srcPath)
	if err != nil {
		log.Warn("payload: read %s: %v", srcPath, err)
		return 0, 0, 1
	}

	w, err := copyIfChanged(exec, content, e.dstGlob, e.mode, log)
	if err != nil {
		log.Warn("payload: %v", err)
		return 0, 0, 1
	}
	if w {
		return 1, 0, 0
	}
	return 0, 1, 0
}

// stageGlob handles a directory entry with a glob pattern (e.g. *.service).
// Uses filepath.Glob on the real filesystem — srcDir is a real repo tree.
func stageGlob(exec executor.Executor, srcDir string, e entry, log *logging.Logger) (wrote, skipped, failed int) {
	srcRoot := filepath.Join(srcDir, e.srcRel)

	if !exec.FileExists(srcRoot) {
		if e.optional {
			log.Debug("payload: optional source dir missing: %s", srcRoot)
			return 0, 1, 0
		}
		log.Warn("payload: required source dir missing: %s", srcRoot)
		return 0, 0, 1
	}

	matches, err := filepath.Glob(filepath.Join(srcRoot, e.srcGlob))
	if err != nil {
		log.Warn("payload: glob %s/%s: %v", srcRoot, e.srcGlob, err)
		return 0, 0, 1
	}

	for _, match := range matches {
		// Skip directories — glob may return subdirs for patterns like "*"
		info, err := os.Stat(match)
		if err != nil || info.IsDir() {
			continue
		}

		// Skip .conf.local files defensively (invariant #9).
		if isConfigLocal(match) {
			log.Debug("payload: skipping .conf.local source file: %s", match)
			continue
		}

		base := filepath.Base(match)
		dstPath := filepath.Join(e.dstGlob, base)

		// Apply %config(noreplace) semantics per-file.
		if shouldPreserveConfig(exec, dstPath, e.policy, log) {
			skipped++
			continue
		}

		content, err := exec.ReadFile(match)
		if err != nil {
			log.Warn("payload: read %s: %v", match, err)
			failed++
			continue
		}

		w, err := copyIfChanged(exec, content, dstPath, e.mode, log)
		if err != nil {
			log.Warn("payload: %v", err)
			failed++
			continue
		}
		if w {
			wrote++
		} else {
			skipped++
		}
	}
	return wrote, skipped, failed
}

// isDebianFamily matches detect.DistroInfo.ID values that use Debian's
// third-party polkit rules location (/usr/share/polkit-1/rules.d/).
func isDebianFamily(id string) bool {
	switch strings.ToLower(id) {
	case "debian", "ubuntu":
		return true
	default:
		return false
	}
}
