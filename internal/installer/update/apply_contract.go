// =============================================================================
// NFTBan v1.99 PR-18 — Update Apply Contract Audit Harness (Public Surface)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-update-apply-contract"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-19"
// meta:description="Call-path purity audit used by PR-18 contract tests"
// meta:inventory.files="internal/installer/update/apply_contract.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
//
// Pinned contract (apply_contract.md + PR #475 body):
//
//   PR-18 is orchestration-only: update apply may invoke the existing
//   rebuild/lifecycle authority, but may not implement any independent
//   apply, mutation, recovery, validation, or authority-taking behavior.
//
// This file exposes the audit harness the PR-18 tests use to mechanically
// verify that property. Exported (vs test-only) so the main-package
// runUpdateApply tests can pipe their MockExecutor traces through the
// same whitelist/forbidden logic that the update-package contract tests
// use.
//
// =============================================================================

package update

import "strings"

// ApplyWhitelist is the complete set of commands runUpdateApply is allowed
// to invoke. Anything outside this list appearing in a MockExecutor trace
// is a contract violation. Adding to it is a conscious contract change
// and requires a corresponding line in apply_contract.md.
var ApplyWhitelist = map[string]bool{
	// Preflight probes — re-runs the PR-16/PR-17 preflight. Read-only.
	"sh -c command -v nft >/dev/null 2>&1":        true,
	"rpm -q nftban-core":                          true,
	"rpm -q nftban":                               true,
	"dpkg -s nftban-core":                         true,
	"dpkg -s nftban":                              true,
	"rpm -q --queryformat %{VERSION} nftban-core": true,
	"rpm -q --queryformat %{VERSION} nftban":      true,

	// Canonical rebuild entrypoint — the ONLY mutation path. Executed via
	// the nftban CLI so the shell rebuild pipeline stays authoritative
	// (PR-21 will migrate this to a Go call).
	"nftban firewall rebuild": true,

	// Validator gate — read-only; blocks success on failure.
	"nftban-validate --json": true,

	// Post-state kernel/service inspection — read-only. Whitelisted
	// explicitly so a reviewer sees every boundary.
	"nft list table ip nftban":            true,
	"nft list table ip6 nftban":           true,
	"systemctl is-active nftband.service": true,
	"systemctl is-active nftables":        true,
}

// ApplyForbiddenSubstring names a class of calls that must never appear
// anywhere in the recorded command trace, regardless of exact args.
type ApplyForbiddenSubstring struct {
	Pattern string
	Why     string
}

// ApplyForbiddenSubstrings enumerates forbidden command patterns.
var ApplyForbiddenSubstrings = []ApplyForbiddenSubstring{
	{"nft add table", "apply must never add tables directly — rebuild owns kernel mutation"},
	{"nft add chain", "apply must never add chains directly — rebuild owns kernel mutation"},
	{"nft add rule", "apply must never add rules directly — rebuild owns kernel mutation"},
	{"nft flush", "apply must never flush — rebuild's atomic switch handles this"},
	{"nft delete", "apply must never delete kernel objects — rebuild owns teardown"},
	{"systemctl stop", "apply must not stop services — rebuild owns service lifecycle"},
	{"systemctl start", "apply must not start services — rebuild owns service lifecycle"},
	{"systemctl restart", "apply must not restart services — rebuild owns service lifecycle"},
	{"systemctl reload", "apply must not reload services — rebuild owns service lifecycle"},
	{"systemctl enable", "apply must not enable services — authority-taking path"},
	{"systemctl disable", "apply must not disable services — authority-taking path"},
	{"systemctl mask", "apply must not mask services — authority-taking path"},
	{"systemctl unmask", "apply must not unmask services — authority-taking path"},
	{"apt-get remove", "apply must not remove packages — authority-taking path"},
	{"dnf remove", "apply must not remove packages — authority-taking path"},
	{"ufw disable", "apply must not touch external firewalls (INV-U-003)"},
	{"iptables -F", "apply must not flush iptables (INV-U-003)"},
}

// ApplyForbiddenWritePath names a destination prefix that apply must never
// open in write mode.
type ApplyForbiddenWritePath struct {
	Prefix string
	Why    string
}

// ApplyForbiddenWritePaths enumerates forbidden write destinations.
var ApplyForbiddenWritePaths = []ApplyForbiddenWritePath{
	{"/etc/nftban/", "apply must not mutate config — rebuild's render pipeline owns /etc/nftban"},
	{"/usr/lib/nftban/", "apply must not mutate payload — PR-14 payload stager owns /usr/lib/nftban"},
	{"/usr/sbin/nftban", "apply must not replace binaries — payload stager owns /usr/sbin/nftban"},
}

// ApplyForbiddenConfLocalSuffix enforces G3-U5 — apply must never write
// to any *.conf.local file, period. Byte-preservation is tested by
// comparing pre/post contents; this constant makes the rule explicit
// so violations stand out in audit output.
const ApplyForbiddenConfLocalSuffix = ".conf.local"

// AuditRecordedCommands runs the full command-trace audit against a
// whitespace-flattened list of "name arg1 arg2 ..." strings. Used by
// contract tests in this package AND the main-package runUpdateApply
// tests so the exact same rules apply to both surfaces.
//
// Returns a list of violation messages (empty slice = clean).
func AuditRecordedCommands(cmds []string) []string {
	var violations []string
	for _, c := range cmds {
		if _, ok := ApplyWhitelist[c]; !ok {
			violations = append(violations,
				"non-whitelisted command: "+c+
					" — add to ApplyWhitelist only after apply_contract.md is updated")
		}
		for _, f := range ApplyForbiddenSubstrings {
			if strings.Contains(c, f.Pattern) {
				violations = append(violations,
					"forbidden pattern '"+f.Pattern+"' appeared ("+f.Why+") in: "+c)
			}
		}
	}
	return violations
}

// AuditWrittenFiles runs the file-system side of the audit.
func AuditWrittenFiles(paths []string) []string {
	var violations []string
	for _, p := range paths {
		for _, f := range ApplyForbiddenWritePaths {
			if strings.HasPrefix(p, f.Prefix) {
				violations = append(violations,
					"apply wrote to forbidden path: "+p+" — "+f.Why)
			}
		}
		if strings.HasSuffix(p, ApplyForbiddenConfLocalSuffix) {
			violations = append(violations,
				".conf.local byte-preservation violated (G3-U5): "+p)
		}
	}
	return violations
}
