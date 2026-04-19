// =============================================================================
// NFTBan v1.99 PR-18 — Update Apply Contract Audit Harness Self-Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-update-apply-contract-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-19"
// meta:description="Self-tests for the exported ApplyWhitelist + audit harness"
// meta:inventory.files="internal/installer/update/apply_contract_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
//
// The whitelist, forbidden lists, and audit helpers themselves live in
// apply_contract.go (exported — Cmd/nftban-installer tests consume them).
// These tests verify the audit harness behaves correctly so reviewers
// can trust the mechanical enforcement.
//
// =============================================================================
package update

import (
	"strings"
	"testing"
)

func TestApplyContract_WhitelistWellFormed(t *testing.T) {
	if len(ApplyWhitelist) == 0 {
		t.Fatal("ApplyWhitelist is empty — contract lost")
	}
	for cmd := range ApplyWhitelist {
		if cmd == "" {
			t.Error("empty whitelist entry")
		}
		if strings.TrimSpace(cmd) != cmd {
			t.Errorf("whitelist entry has padding: %q", cmd)
		}
	}
}

func TestApplyContract_ForbiddenListsWellFormed(t *testing.T) {
	if len(ApplyForbiddenSubstrings) == 0 {
		t.Fatal("ApplyForbiddenSubstrings is empty — contract lost")
	}
	if len(ApplyForbiddenWritePaths) == 0 {
		t.Fatal("ApplyForbiddenWritePaths is empty — contract lost")
	}
	for _, f := range ApplyForbiddenSubstrings {
		if f.Pattern == "" || f.Why == "" {
			t.Errorf("forbidden substring entry missing fields: %+v", f)
		}
	}
	for _, f := range ApplyForbiddenWritePaths {
		if f.Prefix == "" || f.Why == "" {
			t.Errorf("forbidden write path entry missing fields: %+v", f)
		}
	}
}

func TestApplyAudit_CommandsHappyPath(t *testing.T) {
	cmds := []string{
		"nftban firewall rebuild",
		"nftban-validate --json",
		"nft list table ip nftban",
	}
	v := AuditRecordedCommands(cmds)
	if len(v) != 0 {
		t.Errorf("happy path should have no violations, got: %v", v)
	}
}

func TestApplyAudit_DetectsForbiddenSubstring(t *testing.T) {
	cmds := []string{"nft add table ip forbidden"}
	v := AuditRecordedCommands(cmds)
	if len(v) == 0 {
		t.Error("should flag direct kernel mutation via nft add table")
	}
}

func TestApplyAudit_DetectsNonWhitelistedCommand(t *testing.T) {
	cmds := []string{"curl https://example.com/install.sh"}
	v := AuditRecordedCommands(cmds)
	if len(v) == 0 {
		t.Error("should flag unknown command as non-whitelisted")
	}
}

func TestApplyAudit_DetectsConfLocalWrite(t *testing.T) {
	paths := []string{"/etc/nftban/nftban.conf.local"}
	v := AuditWrittenFiles(paths)
	if len(v) == 0 {
		t.Error("should flag .conf.local write (G3-U5 violation)")
	}
}

func TestApplyAudit_DetectsEtcNftbanWrite(t *testing.T) {
	paths := []string{"/etc/nftban/nftban.conf"}
	v := AuditWrittenFiles(paths)
	if len(v) == 0 {
		t.Error("should flag /etc/nftban write (apply owns no /etc/nftban path)")
	}
}

func TestApplyAudit_DetectsSbinWrite(t *testing.T) {
	paths := []string{"/usr/sbin/nftban"}
	v := AuditWrittenFiles(paths)
	if len(v) == 0 {
		t.Error("should flag /usr/sbin/nftban write (payload stager territory)")
	}
}
