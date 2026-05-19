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
//           /usr/sbin/nftban)
//   G-14-C: Shell scripts (cli/lib/nftban/{cli,core,helpers,lib,data,health}/*)
//   G-14-D: Configs (/etc/nftban/*, patterns.d, templates)
//   G-14-E: Systemd units + tmpfiles.d
//   G-14-F: Polkit rules (distro-conditional destination)
//   G-14-G: Logrotate (canonical — resolves pre-existing source-install drift)
//
// Gating: StageAll is invoked from phasePrepare ONLY when pd.source == true.
// The cfg.source == false path (RPM/DEB) never reaches this code.
//
// =============================================================================

package payload

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
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

	type catTally struct{ wrote, skipped, failed int }
	catTotals := map[string]*catTally{}
	var wrote, skipped, failed, requiredFailed int

	for _, e := range entries {
		ew, es, ef := stageEntry(exec, srcDir, e, log)
		wrote += ew
		skipped += es
		failed += ef

		cat := e.category
		if cat == "" {
			cat = "other"
		}
		t, ok := catTotals[cat]
		if !ok {
			t = &catTally{}
			catTotals[cat] = t
		}
		t.wrote += ew
		t.skipped += es
		t.failed += ef

		if ef > 0 && !e.optional {
			requiredFailed += ef
		}
	}

	// R-3 (issue #463): emit INFO-level category summary so installer log
	// review does not require debug verbosity.
	cats := make([]string, 0, len(catTotals))
	for c := range catTotals {
		cats = append(cats, c)
	}
	sort.Strings(cats)
	for _, c := range cats {
		t := catTotals[c]
		log.Info("payload: category=%-12s wrote=%-4d skipped=%-4d failed=%d",
			c, t.wrote, t.skipped, t.failed)
	}
	log.Info("payload: staging complete — wrote=%d skipped=%d failed=%d", wrote, skipped, failed)

	// R-3 (issue #463): required-artifact failures are surfaced at WARN
	// level so log review catches them. The hard escalation happens in
	// phaseValidate via the payload_inventory_ok assertion, which checks
	// end-state destinations rather than mid-stage counters. End-state
	// checks survive scenarios where an operator pre-staged files or
	// where retry semantics fill gaps.
	if requiredFailed > 0 {
		log.Warn("payload: %d required file(s) failed to stage — payload_inventory_ok will catch material gaps", requiredFailed)
	}
	if failed > requiredFailed {
		log.Warn("payload: %d optional file(s) also failed to stage (non-fatal)", failed-requiredFailed)
	}
	return nil
}

// VerifyInventory asserts that every canonical required destination is
// materially present after install. Called by the post-install assertion
// suite (validate.assertPayloadInventory). It does not checksum every
// staged file — it proves material install completeness per v1.98.2 R-3.
//
// Scope: destinations that every install (source OR package) must produce.
// Optional/distro-conditional artifacts (man, polkit, completions) are
// intentionally excluded.
func VerifyInventory(exec executor.Executor) (ok bool, missing []string) {
	required := []string{
		// Canonical privileged CLI + installer
		"/usr/sbin/nftban",
		"/usr/lib/nftban/bin/nftban-core",
		"/usr/lib/nftban/bin/nftband",
		"/usr/lib/nftban/bin/nftban-validate",
		"/usr/lib/nftban/bin/nftban-installer",

		// Version file — every CLI subcommand sources version.sh which
		// reads this. Absence crashes every shell entry point (v1.98.1 P0).
		"/usr/lib/nftban/VERSION",

		// Operator-facing config + firewall template
		"/etc/nftban/nftban.conf",
		"/etc/nftban/nftables.conf",

		// Canonical logrotate (addresses source-install drift)
		"/etc/logrotate.d/nftban",
	}

	for _, p := range required {
		if !exec.FileExists(p) {
			missing = append(missing, p)
		}
	}

	// Also assert that the key shell payload roots exist AND are non-empty.
	// A present-but-empty directory would silently break the CLI without a
	// file-level signal.
	shellDirs := []string{
		"/usr/lib/nftban/cli",
		"/usr/lib/nftban/core",
		"/usr/lib/nftban/lib",
		"/usr/lib/nftban/helpers",
		"/usr/lib/nftban/data",
		"/usr/lib/nftban/health",
	}
	for _, d := range shellDirs {
		if !exec.FileExists(d) {
			missing = append(missing, d+" (dir)")
			continue
		}
		if empty, err := dirIsEmpty(d); err == nil && empty {
			missing = append(missing, d+" (empty)")
		}
	}

	return len(missing) == 0, missing
}

// ConfigIntegrityIssue describes one minimum-sanity failure on a
// critical config file. PR-P2-6 scope: minimum-size + required-header/
// token check only — not a full integrity/checksum framework.
type ConfigIntegrityIssue struct {
	Path   string
	Reason string
}

// criticalConfig describes one file that VerifyConfigIntegrity probes.
// Each entry is intentionally bounded — this is a sanity guard, not a
// validation system.
type criticalConfig struct {
	// Path is the on-disk location to probe.
	Path string
	// MinSize is the minimum byte count the file MUST have. Set to a
	// conservative floor so legitimate operator edits pass but
	// trivially-broken files (empty / truncated / stub) fail.
	MinSize int
	// RequiredTokens are plain substrings — EVERY one must appear in
	// the file. Tokens are chosen to be the most stable parts of the
	// shipped template so normal operator editing does not break them.
	RequiredTokens []string
}

// criticalConfigs is the frozen PR-P2-6 sanity check set. Adding a
// new entry requires a contract update — the set is deliberately
// minimal (nftban.conf + nftables.conf), per the PR-P2-6 contract
// seed's explicit "do not expand into validation framework" rule.
var criticalConfigs = []criticalConfig{
	{
		Path:    "/etc/nftban/nftban.conf",
		MinSize: 256, // Shipped template is ~450 lines (~15KB); 256
		// bytes is a conservative floor that catches empty / 2-line
		// stub / truncated-to-preamble regressions without false-
		// positive on aggressively-edited operator configs.
		RequiredTokens: []string{
			// License header is present in every shipped config file
			// and no responsible operator edit would strip it.
			"SPDX-License-Identifier",
		},
	},
	{
		Path:    "/etc/nftban/nftables.conf",
		MinSize: 512, // Shipped template renders to ~830 lines (~25KB)
		// after SSH-port / CT-limit substitutions; 512 bytes is a
		// conservative floor that catches render-output truncation or
		// accidental overwrite with a placeholder.
		RequiredTokens: []string{
			// Shebang is functionally required — without it the file
			// cannot be executed by nftables.service's ExecStart.
			"#!/usr/sbin/nft",
			// At least one nftban-owned table declaration must be
			// present, otherwise the firewall ruleset is meaningless.
			"table ip nftban",
		},
	},
}

// VerifyConfigIntegrity runs the PR-P2-6 sanity checks on the set of
// critical config files. Each file must exist, meet a minimum byte
// count, and contain every required token/header. Returns a list of
// every failing check so the caller can surface all issues at once
// rather than first-fails-wins.
//
// Scope lock (PR-P2-6, 2026-04-20):
//   - Presence + minimum size + required-substring only
//   - No checksums, no signatures, no semantic config parsing
//   - Fixed list of two critical files (nftban.conf + nftables.conf)
//
// Adding a new file or a new signal beyond min-size/required-token
// requires an explicit contract update; this function deliberately
// does NOT grow into a validation framework.
func VerifyConfigIntegrity(exec executor.Executor) (ok bool, issues []ConfigIntegrityIssue) {
	for _, cc := range criticalConfigs {
		if !exec.FileExists(cc.Path) {
			issues = append(issues, ConfigIntegrityIssue{
				Path: cc.Path, Reason: "file missing (presence check failed)",
			})
			continue
		}
		data, err := exec.ReadFile(cc.Path)
		if err != nil {
			issues = append(issues, ConfigIntegrityIssue{
				Path: cc.Path, Reason: "unreadable: " + err.Error(),
			})
			continue
		}
		if len(data) < cc.MinSize {
			issues = append(issues, ConfigIntegrityIssue{
				Path: cc.Path,
				Reason: fmt.Sprintf("undersized: %d bytes < minimum %d (file appears truncated or stub)",
					len(data), cc.MinSize),
			})
			// Size failure is sufficient to declare the file broken;
			// skip token checks on a truncated file to avoid noise.
			continue
		}
		text := string(data)
		for _, tok := range cc.RequiredTokens {
			if !strings.Contains(text, tok) {
				issues = append(issues, ConfigIntegrityIssue{
					Path:   cc.Path,
					Reason: "missing required token/header: " + tok,
				})
			}
		}
	}
	return len(issues) == 0, issues
}

// dirIsEmpty reports whether dir exists and contains no regular entries.
// dir is always one of the canonical FHS paths declared in VerifyInventory —
// no user-controlled input reaches this function.
func dirIsEmpty(dir string) (bool, error) {
	f, err := os.Open(filepath.Clean(dir)) // #nosec G304 -- canonical FHS path from VerifyInventory
	if err != nil {
		return false, err
	}
	defer f.Close()
	names, err := f.Readdirnames(1)
	if err != nil && !errors.Is(err, io.EOF) {
		return false, err
	}
	return len(names) == 0, nil
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

	// category groups entries for the INFO-level staging summary
	// (v1.98.2 R-3). Empty defaults to "other" at tally time.
	category string
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
		{category: "binaries", srcRel: "bin/nftban-core", dstGlob: "/usr/lib/nftban/bin/nftban-core", mode: 0755, policy: policyAlways},
		{category: "binaries", srcRel: "bin/nftband", dstGlob: "/usr/lib/nftban/bin/nftband", mode: 0755, policy: policyAlways},
		{category: "binaries", srcRel: "bin/nftban-validate", dstGlob: "/usr/lib/nftban/bin/nftban-validate", mode: 0755, policy: policyAlways},
		{category: "binaries", srcRel: "bin/nftban-installer", dstGlob: "/usr/lib/nftban/bin/nftban-installer", mode: 0755, policy: policyAlways},

		// Canonical privileged CLI binary (NB-5 perms).
		{category: "cli-bin", srcRel: "cli/sbin/nftban", dstGlob: "/usr/sbin/nftban", mode: 0750, policy: policyAlways},

		// Auxiliary CLI helpers.
		{category: "cli-bin", srcRel: "cli/sbin/nftban-apply", dstGlob: "/usr/lib/nftban/sbin/nftban-apply", mode: 0755, policy: policyAlways},
		{category: "cli-bin", srcRel: "cli/sbin/nftban-confirm", dstGlob: "/usr/lib/nftban/sbin/nftban-confirm", mode: 0755, policy: policyAlways},
		{category: "cli-bin", srcRel: "cli/sbin/nftban-panelctl", dstGlob: "/usr/lib/nftban/sbin/nftban-panelctl", mode: 0755, policy: policyAlways},
		{category: "cli-bin", srcRel: "cli/sbin/nftban-queue-processor", dstGlob: "/usr/lib/nftban/sbin/nftban-queue-processor", mode: 0755, policy: policyAlways},
		{category: "cli-bin", srcRel: "cli/sbin/nftban-rollback", dstGlob: "/usr/lib/nftban/sbin/nftban-rollback", mode: 0755, policy: policyAlways},
		{category: "cli-bin", srcRel: "cli/sbin/nftban-service-alert", dstGlob: "/usr/lib/nftban/sbin/nftban-service-alert", mode: 0755, policy: policyAlways},
		{category: "cli-bin", srcRel: "cli/sbin/nftban-botscan-processor", dstGlob: "/usr/lib/nftban/sbin/nftban-botscan-processor", mode: 0755, policy: policyAlways},

		// -----------------------------------------------------------------
		// G-14-C: Shell payload under /usr/lib/nftban/
		// -----------------------------------------------------------------
		{category: "shell", srcRel: "cli/lib/nftban/cli", srcGlob: "*.sh", dstGlob: "/usr/lib/nftban/cli", mode: 0755, policy: policyAlways, isDir: true},
		{category: "shell", srcRel: "cli/lib/nftban/core", srcGlob: "*.sh", dstGlob: "/usr/lib/nftban/core", mode: 0755, policy: policyAlways, isDir: true},
		{category: "shell", srcRel: "cli/lib/nftban/helpers", srcGlob: "*.sh", dstGlob: "/usr/lib/nftban/helpers", mode: 0755, policy: policyAlways, isDir: true},
		{category: "shell", srcRel: "cli/lib/nftban/lib", srcGlob: "*.sh", dstGlob: "/usr/lib/nftban/lib", mode: 0755, policy: policyAlways, isDir: true},
		{category: "data", srcRel: "cli/lib/nftban/data", srcGlob: "*", dstGlob: "/usr/lib/nftban/data", mode: 0644, policy: policyAlways, isDir: true},
		{category: "shell", srcRel: "cli/lib/nftban/health", srcGlob: "*.sh", dstGlob: "/usr/lib/nftban/health", mode: 0755, policy: policyAlways, isDir: true},

		// PR26.5: source-install payload completeness — close the gaps surfaced
		// by the dns2 evidence run (2026-04-30). systemd unit ExecStart paths
		// referenced these destinations; pre-PR26.5 source install did not stage
		// them, causing PR26.1 systemd_execstart_paths_ok to fail.
		// G-14-C continued: shell payload destinations referenced by units.
		{category: "shell", srcRel: "cli/lib/nftban/exporters", srcGlob: "*.sh", dstGlob: "/usr/lib/nftban/exporters", mode: 0755, policy: policyAlways, isDir: true},
		{category: "shell", srcRel: "cli/lib/nftban/cron", srcGlob: "*.sh", dstGlob: "/usr/lib/nftban/cron", mode: 0755, policy: policyAlways, isDir: true},
		// Top-level scripts/ — referenced by nftban-soak.service.
		{category: "shell", srcRel: "scripts", srcGlob: "*.sh", dstGlob: "/usr/lib/nftban/scripts", mode: 0755, policy: policyAlways, isDir: true},
		// install/helpers/ ships the firewall-init-with-delay.sh helper which is
		// distinct from the cli/lib/nftban/helpers/ tree above. Both flatten into
		// /usr/lib/nftban/helpers/.
		{category: "shell", srcRel: "install/helpers", srcGlob: "*.sh", dstGlob: "/usr/lib/nftban/helpers", mode: 0755, policy: policyAlways, isDir: true, optional: true},

		// Shipped nftables template (always overwrite — installer-managed,
		// never operator-edited here).
		{category: "templates", srcRel: "cli/lib/nftban/templates/nftables.conf.tpl", dstGlob: "/usr/lib/nftban/templates/nftables.conf.tpl", mode: 0644, policy: policyAlways, optional: true},

		// VERSION file — consumed by cli/lib/nftban/lib/version.sh which is
		// sourced by every CLI subcommand. Package installs stage it via
		// packaging/build_nftban.sh (RPM %install line ~368, DEB ~1837);
		// source install missed it, causing every CLI invocation to crash
		// with "unbound variable" at version.sh:39.
		{category: "version", srcRel: "VERSION", dstGlob: "/usr/lib/nftban/VERSION", mode: 0644, policy: policyAlways},

		// -----------------------------------------------------------------
		// G-14-D: Configs (/etc/nftban/*)
		// -----------------------------------------------------------------
		// Template configs with %config(noreplace) semantics.
		{category: "configs", srcRel: "install/config/nftban.conf", dstGlob: "/etc/nftban/nftban.conf", mode: 0640, policy: policyConfigNoReplace},
		// nftables.conf is a template with __SSH_PORT__ / __CT_LIMIT_*__
		// placeholders. render.RenderNftablesConf (Prepare step 6) reads
		// this, substitutes, and writes back. Must be staged before render.
		{category: "configs", srcRel: "install/nftables/nftables.conf", dstGlob: "/etc/nftban/nftables.conf", mode: 0640, policy: policyConfigNoReplace},
		{category: "configs", srcRel: "install/config/conf.d", srcGlob: "*.conf", dstGlob: "/etc/nftban/conf.d", mode: 0640, policy: policyConfigNoReplace, isDir: true},

		// Default reference templates (.default files — always overwrite).
		{category: "configs", srcRel: "install/config/conf.d", srcGlob: "*.conf.default", dstGlob: "/etc/nftban/conf.d", mode: 0640, policy: policyAlways, isDir: true},

		// Distro-aware path registry (always overwrite — installer-owned).
		{category: "configs", srcRel: "etc/nftban/distros", srcGlob: "*.conf", dstGlob: "/etc/nftban/distros", mode: 0640, policy: policyAlways, isDir: true},

		// PR26.5: panel canonical port-declaration configs. Source-of-truth for
		// PR26.4's DirectAdmin adapter (and future PR26.7 cPanel / PR26.8 Plesk
		// adapters) via internal/ports/panel_loader.LoadPanelConfig. Per the
		// V190_PANELS audit there are 8 first-class panels; staging is a static
		// set of 8 single-file entries (one per panel) so future panel removals
		// require an explicit edit to this list.
		{category: "panels", srcRel: "etc/nftban/conf.d/panels/directadmin/main.conf", dstGlob: "/etc/nftban/conf.d/panels/directadmin/main.conf", mode: 0640, policy: policyConfigNoReplace, optional: true},
		{category: "panels", srcRel: "etc/nftban/conf.d/panels/cpanel/main.conf", dstGlob: "/etc/nftban/conf.d/panels/cpanel/main.conf", mode: 0640, policy: policyConfigNoReplace, optional: true},
		{category: "panels", srcRel: "etc/nftban/conf.d/panels/plesk/main.conf", dstGlob: "/etc/nftban/conf.d/panels/plesk/main.conf", mode: 0640, policy: policyConfigNoReplace, optional: true},
		{category: "panels", srcRel: "etc/nftban/conf.d/panels/cyberpanel/main.conf", dstGlob: "/etc/nftban/conf.d/panels/cyberpanel/main.conf", mode: 0640, policy: policyConfigNoReplace, optional: true},
		{category: "panels", srcRel: "etc/nftban/conf.d/panels/cwp/main.conf", dstGlob: "/etc/nftban/conf.d/panels/cwp/main.conf", mode: 0640, policy: policyConfigNoReplace, optional: true},
		{category: "panels", srcRel: "etc/nftban/conf.d/panels/interworx/main.conf", dstGlob: "/etc/nftban/conf.d/panels/interworx/main.conf", mode: 0640, policy: policyConfigNoReplace, optional: true},
		{category: "panels", srcRel: "etc/nftban/conf.d/panels/vesta/main.conf", dstGlob: "/etc/nftban/conf.d/panels/vesta/main.conf", mode: 0640, policy: policyConfigNoReplace, optional: true},
		{category: "panels", srcRel: "etc/nftban/conf.d/panels/generic/main.conf", dstGlob: "/etc/nftban/conf.d/panels/generic/main.conf", mode: 0640, policy: policyConfigNoReplace, optional: true},

		// Manual whitelist/blacklist templates (%config(noreplace)).
		// safety.SeedManualWhitelist runs in phaseConfigure after these land.
		{category: "configs", srcRel: "etc/nftban/whitelist.d/99-manual.conf", dstGlob: "/etc/nftban/whitelist.d/99-manual.conf", mode: 0640, policy: policyConfigNoReplace, optional: true},
		{category: "configs", srcRel: "etc/nftban/blacklist.d/99-manual.conf", dstGlob: "/etc/nftban/blacklist.d/99-manual.conf", mode: 0640, policy: policyConfigNoReplace, optional: true},

		// Commands registry.
		{category: "configs", srcRel: "commands.registry.yml", dstGlob: "/etc/nftban/commands.registry.yml", mode: 0644, policy: policyConfigNoReplace, optional: true},

		// -----------------------------------------------------------------
		// G-14-E: Systemd units + tmpfiles.d
		// -----------------------------------------------------------------
		{category: "systemd", srcRel: "install/systemd", srcGlob: "*.service", dstGlob: "/usr/lib/systemd/system", mode: 0644, policy: policyAlways, isDir: true},
		{category: "systemd", srcRel: "install/systemd", srcGlob: "*.timer", dstGlob: "/usr/lib/systemd/system", mode: 0644, policy: policyAlways, isDir: true},
		{category: "systemd", srcRel: "install/systemd", srcGlob: "*.socket", dstGlob: "/usr/lib/systemd/system", mode: 0644, policy: policyAlways, isDir: true},
		{category: "systemd", srcRel: "install/systemd/tmpfiles.d/nftban.conf", dstGlob: "/usr/lib/tmpfiles.d/nftban.conf", mode: 0644, policy: policyAlways},

		// -----------------------------------------------------------------
		// G-14-F: Polkit rules (distro-conditional destination)
		// -----------------------------------------------------------------
		{category: "polkit", srcRel: "packaging/polkit-1/rules.d", srcGlob: "*.rules", dstGlob: polkitDst, mode: 0644, policy: policyAlways, isDir: true, optional: true},

		// -----------------------------------------------------------------
		// G-14-G: Logrotate — uses the canonical shipped config. Resolves the
		// pre-existing source-install drift where a legacy wildcard logrotate
		// config was auto-generated at install time (see
		// LOG_ROTATION_DOCS_CODE_ALIGNMENT.md).
		// -----------------------------------------------------------------
		{category: "logrotate", srcRel: "install/config/nftban.logrotate", dstGlob: "/etc/logrotate.d/nftban", mode: 0644, policy: policyAlways},
		{category: "logrotate", srcRel: "install/config/nftban-suricata.logrotate", dstGlob: "/etc/nftban/templates/nftban-suricata.logrotate", mode: 0644, policy: policyAlways, optional: true},

		// -----------------------------------------------------------------
		// Other shipped artifacts: bash completion (optional)
		// -----------------------------------------------------------------
		{category: "docs", srcRel: "install/bash-completion/nftban", dstGlob: "/usr/share/bash-completion/completions/nftban", mode: 0644, policy: policyAlways, optional: true},
	}
}

// Destination is a public, read-only catalog entry describing one
// staged-payload destination. Returned by Destinations.
//
// Establishes a single source of truth between install (StageAll) and
// uninstall (uninstall.RemoveArtifacts) so the two paths stay coherent
// under future evolution of the destination set.
type Destination struct {
	// Path is the destination filesystem path. For directory-glob
	// entries (IsDir=true) it is the directory; for single-file entries
	// it is the exact destination file.
	Path string

	// IsDir reports whether Path is a directory containing files
	// matching Glob (true) or a single-file destination (false).
	IsDir bool

	// Glob is the glob pattern within Path when IsDir is true (e.g.
	// "*.service", "*.conf"). Empty for single-file entries.
	Glob string

	// Category groups entries (binaries, shell, configs, systemd,
	// polkit, logrotate, docs, ...).
	Category string

	// Optional reports whether absence of the source is non-fatal at
	// install time. Uninstall treats every destination uniformly —
	// presence is checked before delete in either case.
	Optional bool

	// Mode is the file mode applied at install. Carried for symmetry;
	// uninstall does not use it.
	Mode os.FileMode
}

// Destinations returns the public, read-only destination catalog
// derived from buildEntries. Same set, same distro-conditional polkit
// branch — uninstall walks this list to identify every path the
// installer staged.
//
// This is a snapshot, not a live view: the slice is freshly allocated
// per call and safe for the caller to sort/filter without affecting
// other callers or future Destinations() calls.
func Destinations(distro *detect.DistroInfo) []Destination {
	entries := buildEntries(distro)
	out := make([]Destination, 0, len(entries))
	for _, e := range entries {
		out = append(out, Destination{
			Path:     e.dstGlob,
			IsDir:    e.isDir,
			Glob:     e.srcGlob,
			Category: e.category,
			Optional: e.optional,
			Mode:     e.mode,
		})
	}
	return out
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
