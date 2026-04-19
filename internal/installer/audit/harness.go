// =============================================================================
// NFTBan v1.100 PR-22B — Lifecycle Purity Audit Harness
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-audit-harness"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-19"
// meta:description="Reusable purity-check helpers for dry-run / observational paths"
// meta:inventory.files="internal/installer/audit/harness.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
//
// Per audit item 12 ("A post-repair verification harness"): a small
// reusable harness that each lifecycle mode can use to assert that a
// dry-run / observational invocation produced:
//
//   - zero writes through the executor interface
//   - zero MkdirAll calls through the executor
//   - zero mutation-flavored commands in the executor trace
//   - zero new files in the caller-supplied state directory
//
// Check* methods return []string violation messages (empty when clean);
// Assert* methods call them and report via t.Errorf. Self-tests can
// exercise Check* directly without needing to implement testing.TB
// (which has an unexported method and cannot be satisfied outside the
// testing package).
//
// =============================================================================
package audit

import (
	"os"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
)

// ForbiddenCommandPatterns is the shared deny-list used by the
// mutation-command check. Substring-matched against the joined form
// of "command-name arg1 arg2 …".
//
// Mirrors the CI structural-grep patterns but operates at runtime — a
// dynamically-constructed argument (which source grep cannot see) is
// still caught here.
var ForbiddenCommandPatterns = []string{
	// nftables mutation
	"nft add",
	"nft create",
	"nft delete",
	"nft flush",
	// systemd lifecycle
	"systemctl start",
	"systemctl stop",
	"systemctl restart",
	"systemctl reload",
	"systemctl enable",
	"systemctl disable",
	"systemctl mask",
	"systemctl unmask",
	// external firewall binaries
	"ufw ",
	"firewall-cmd",
	"iptables-restore",
	"ip6tables-restore",
	"csf ",
	// package manager removal
	"apt-get remove",
	"apt-get purge",
	"dnf remove",
	"dnf erase",
	"rpm -e",
	"dpkg --remove",
	"dpkg --purge",
	// user/group removal
	"userdel",
	"groupdel",
}

// PurityHarness bundles a MockExecutor and a temp state directory into
// an assertion kit for observational-path tests.
type PurityHarness struct {
	Exec     *executor.MockExecutor
	StateDir string
}

// NewPurityHarness creates a harness for a specific run.
func NewPurityHarness(exec *executor.MockExecutor, stateDir string) *PurityHarness {
	return &PurityHarness{Exec: exec, StateDir: stateDir}
}

// CheckExecutorWrites returns one violation message per executor write
// recorded (zero when clean).
func (h *PurityHarness) CheckExecutorWrites() []string {
	var out []string
	for path := range h.Exec.WrittenFiles {
		out = append(out, "executor.WriteFileAtomic("+path+")")
	}
	return out
}

// CheckDirectoryCreations returns one violation message per executor
// MkdirAll recorded (zero when clean).
func (h *PurityHarness) CheckDirectoryCreations() []string {
	var out []string
	for path := range h.Exec.Dirs {
		out = append(out, "executor.MkdirAll("+path+")")
	}
	return out
}

// CheckMutationCommands returns one violation per forbidden command in
// the recorded trace (zero when clean).
func (h *PurityHarness) CheckMutationCommands() []string {
	var out []string
	for _, cmd := range h.Exec.Commands {
		joined := cmd.Name + " " + strings.Join(cmd.Args, " ")
		for _, forbid := range ForbiddenCommandPatterns {
			if strings.Contains(joined, forbid) {
				out = append(out, "forbidden command "+joined+" (pattern "+forbid+")")
			}
		}
	}
	return out
}

// CheckStateDirEntries returns one violation per file/dir in the
// harness-owned state directory (zero when clean). Catches direct
// os.WriteFile / os.MkdirAll calls that bypass the mock executor —
// exactly the class that escaped PR-22's original review.
func (h *PurityHarness) CheckStateDirEntries() []string {
	entries, err := os.ReadDir(h.StateDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return []string{"read state dir " + h.StateDir + ": " + err.Error()}
	}
	var out []string
	for _, e := range entries {
		out = append(out, "state-dir entry: "+e.Name())
	}
	return out
}

// AssertNoExecutorWrites fails the test for each executor write.
func (h *PurityHarness) AssertNoExecutorWrites(t testing.TB) {
	t.Helper()
	for _, v := range h.CheckExecutorWrites() {
		t.Errorf("observational path: %s", v)
	}
}

// AssertNoDirectoryCreations fails the test for each MkdirAll.
func (h *PurityHarness) AssertNoDirectoryCreations(t testing.TB) {
	t.Helper()
	for _, v := range h.CheckDirectoryCreations() {
		t.Errorf("observational path: %s", v)
	}
}

// AssertNoMutationCommands fails the test for each forbidden command.
func (h *PurityHarness) AssertNoMutationCommands(t testing.TB) {
	t.Helper()
	for _, v := range h.CheckMutationCommands() {
		t.Errorf("observational path: %s", v)
	}
}

// AssertNoStateDirEntries fails the test for each entry in the state
// directory.
func (h *PurityHarness) AssertNoStateDirEntries(t testing.TB) {
	t.Helper()
	for _, v := range h.CheckStateDirEntries() {
		t.Errorf("observational path: %s", v)
	}
}

// AssertAllPurity runs every assertion in one call — the common case.
func (h *PurityHarness) AssertAllPurity(t testing.TB) {
	t.Helper()
	h.AssertNoExecutorWrites(t)
	h.AssertNoDirectoryCreations(t)
	h.AssertNoMutationCommands(t)
	h.AssertNoStateDirEntries(t)
}
