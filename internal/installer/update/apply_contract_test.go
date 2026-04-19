// =============================================================================
// NFTBan v1.99 PR-18 — Update Apply Contract Tests (Call-Path Purity)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-update-apply-contract-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-19"
// meta:description="PR-18 call-path purity tests — land before orchestration code"
// meta:inventory.files="internal/installer/update/apply_contract_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
//
// Contract pinned in apply_contract.md and the PR-18 body:
//
//   PR-18 is orchestration-only: update apply may invoke the existing
//   rebuild/lifecycle authority, but may not implement any independent
//   apply, mutation, recovery, validation, or authority-taking behavior.
//
// These tests fail if apply ever grows an apply-owned mutation path. They
// land BEFORE runUpdateApply itself so the invariants are enforced from
// the very first implementation commit.
//
// The tests here describe what apply MUST and MUST NOT call. They do NOT
// test "it works" — that's the job of integration tests in CI. The contract
// tests are a mechanical purity check: apply's command recorder contains
// ONLY whitelisted calls.
//
// =============================================================================

package update

import (
	"strings"
	"testing"
)

// Whitelisted commands that runUpdateApply is allowed to invoke. Anything
// outside this list in the mock's RecordedCommands is a contract violation.
//
// KEEP THIS LIST SHORT. Adding to it is a conscious contract change and
// requires a corresponding line in apply_contract.md.
var applyWhitelist = map[string]bool{
	// Preflight probes — re-runs the PR-16/PR-17 preflight. Read-only.
	"sh -c command -v nft >/dev/null 2>&1": true,
	"rpm -q nftban-core":                   true,
	"rpm -q nftban":                        true,
	"dpkg -s nftban-core":                  true,
	"dpkg -s nftban":                       true,
	"rpm -q --queryformat %{VERSION} nftban-core": true,
	"rpm -q --queryformat %{VERSION} nftban":      true,

	// Canonical rebuild entrypoint — the ONLY mutation path. Executed via
	// the nftban CLI so the shell rebuild pipeline stays authoritative
	// (PR-21 will migrate this to a Go call).
	"nftban firewall rebuild": true,

	// Validator gate — read-only; blocks success on failure.
	"nftban-validate --json": true,

	// Post-state kernel inspection — read-only; NOT mutation.
	// These are legitimate for convergence proofs (G3-U9). They are
	// whitelisted explicitly so a reviewer sees every boundary.
	"nft list table ip nftban":  true,
	"nft list table ip6 nftban": true,
	"systemctl is-active nftband.service": true,
	"systemctl is-active nftables":        true,
}

// applyForbiddenSubstrings captures classes of calls that must never appear
// anywhere in the recorded command list, regardless of exact args. Each
// entry represents a category of forbidden-by-contract invocation.
var applyForbiddenSubstrings = []struct {
	pattern string
	why     string
}{
	{"nft add table", "apply must never add tables directly — rebuild owns kernel mutation"},
	{"nft add chain", "apply must never add chains directly — rebuild owns kernel mutation"},
	{"nft add rule", "apply must never add rules directly — rebuild owns kernel mutation"},
	{"nft flush", "apply must never flush — rebuild's atomic switch handles this"},
	{"nft delete", "apply must never delete kernel objects — rebuild owns teardown"},
	{"systemctl stop", "apply must not stop services — rebuild owns service lifecycle"},
	{"systemctl disable", "apply must not disable services — authority-taking path"},
	{"systemctl mask", "apply must not mask services — authority-taking path"},
	{"apt-get remove", "apply must not remove packages — authority-taking path"},
	{"dnf remove", "apply must not remove packages — authority-taking path"},
	{"ufw disable", "apply must not touch external firewalls (INV-U-003)"},
	{"iptables -F", "apply must not flush iptables (INV-U-003)"},
}

// applyForbiddenWritePaths captures file-system destinations that apply
// must never open in write mode. Enforced by inspecting WrittenFiles on
// the MockExecutor.
var applyForbiddenWritePaths = []struct {
	prefix string
	why    string
}{
	{"/etc/nftban/", "apply must not mutate config — rebuild's render pipeline owns /etc/nftban"},
	{"/usr/lib/nftban/", "apply must not mutate payload — PR-14 payload stager owns /usr/lib/nftban"},
	{"/usr/sbin/nftban", "apply must not replace binaries — payload stager owns /usr/sbin/nftban"},
}

// Note: .conf.local is a subset of /etc/nftban/ and so is already forbidden
// by the broader rule above. We keep it explicit below for operator clarity.

// applyForbiddenConfLocal is the G3-U5 assertion — .conf.local bytes
// must never be touched by apply, period.
var applyForbiddenConfLocalSuffix = ".conf.local"

// -----------------------------------------------------------------------------
// These tests are scaffolding — runUpdateApply does not yet exist.
// When step 2 lands, these tests become live purity checks that run on
// every recorded-command trace from a runUpdateApply execution.
//
// For now we verify the whitelist/forbidden lists themselves are well-formed
// so the contract surface is reviewable from commit 1.
// -----------------------------------------------------------------------------

func TestApplyContract_WhitelistWellFormed(t *testing.T) {
	if len(applyWhitelist) == 0 {
		t.Fatal("applyWhitelist is empty — contract lost")
	}
	// Every entry must be a plausible command (non-empty, no leading/
	// trailing whitespace).
	for cmd := range applyWhitelist {
		if cmd == "" {
			t.Error("empty whitelist entry")
		}
		if strings.TrimSpace(cmd) != cmd {
			t.Errorf("whitelist entry has padding: %q", cmd)
		}
	}
}

func TestApplyContract_ForbiddenListsWellFormed(t *testing.T) {
	if len(applyForbiddenSubstrings) == 0 {
		t.Fatal("applyForbiddenSubstrings is empty — contract lost")
	}
	if len(applyForbiddenWritePaths) == 0 {
		t.Fatal("applyForbiddenWritePaths is empty — contract lost")
	}
	for _, f := range applyForbiddenSubstrings {
		if f.pattern == "" || f.why == "" {
			t.Errorf("forbidden substring entry missing fields: %+v", f)
		}
	}
	for _, f := range applyForbiddenWritePaths {
		if f.prefix == "" || f.why == "" {
			t.Errorf("forbidden write path entry missing fields: %+v", f)
		}
	}
}

// auditRecordedCommands runs the complete contract audit against a slice
// of "name + args" command strings. It is the test-harness that step 2
// (runUpdateApply implementation) will call with MockExecutor.Commands
// flattened to strings. Kept public within the package so the apply
// tests can reuse it.
//
// Returns a list of violation messages (empty slice = clean).
func auditRecordedCommands(cmds []string) []string {
	var violations []string

	for _, c := range cmds {
		if _, ok := applyWhitelist[c]; !ok {
			// Unknown command — not in whitelist. Reject with context.
			violations = append(violations,
				"non-whitelisted command: "+c+
					" — add to applyWhitelist only after apply_contract.md is updated")
		}
		for _, f := range applyForbiddenSubstrings {
			if strings.Contains(c, f.pattern) {
				violations = append(violations,
					"forbidden pattern '"+f.pattern+"' appeared ("+f.why+") in: "+c)
			}
		}
	}
	return violations
}

// auditWrittenFiles runs the file-system side of the audit. Takes the
// MockExecutor's WrittenFiles keys (destination paths) and reports
// violations.
func auditWrittenFiles(paths []string) []string {
	var violations []string
	for _, p := range paths {
		for _, f := range applyForbiddenWritePaths {
			if strings.HasPrefix(p, f.prefix) {
				violations = append(violations,
					"apply wrote to forbidden path: "+p+" — "+f.why)
			}
		}
		if strings.HasSuffix(p, applyForbiddenConfLocalSuffix) {
			violations = append(violations,
				".conf.local byte-preservation violated (G3-U5): "+p)
		}
	}
	return violations
}

// -----------------------------------------------------------------------------
// Self-tests for the audit harness itself so reviewers can trust it.
// -----------------------------------------------------------------------------

func TestApplyAudit_CommandsHappyPath(t *testing.T) {
	cmds := []string{
		"nftban firewall rebuild",
		"nftban-validate --json",
		"nft list table ip nftban",
	}
	v := auditRecordedCommands(cmds)
	if len(v) != 0 {
		t.Errorf("happy path should have no violations, got: %v", v)
	}
}

func TestApplyAudit_DetectsForbiddenSubstring(t *testing.T) {
	cmds := []string{"nft add table ip forbidden"}
	v := auditRecordedCommands(cmds)
	if len(v) == 0 {
		t.Error("should flag direct kernel mutation via nft add table")
	}
}

func TestApplyAudit_DetectsNonWhitelistedCommand(t *testing.T) {
	cmds := []string{"curl https://example.com/install.sh"}
	v := auditRecordedCommands(cmds)
	if len(v) == 0 {
		t.Error("should flag unknown command as non-whitelisted")
	}
}

func TestApplyAudit_DetectsConfLocalWrite(t *testing.T) {
	paths := []string{"/etc/nftban/nftban.conf.local"}
	v := auditWrittenFiles(paths)
	if len(v) == 0 {
		t.Error("should flag .conf.local write (G3-U5 violation)")
	}
}

func TestApplyAudit_DetectsEtcNftbanWrite(t *testing.T) {
	paths := []string{"/etc/nftban/nftban.conf"}
	v := auditWrittenFiles(paths)
	if len(v) == 0 {
		t.Error("should flag /etc/nftban write (apply owns no /etc/nftban path)")
	}
}

func TestApplyAudit_DetectsSbinWrite(t *testing.T) {
	paths := []string{"/usr/sbin/nftban"}
	v := auditWrittenFiles(paths)
	if len(v) == 0 {
		t.Error("should flag /usr/sbin/nftban write (payload stager territory)")
	}
}
