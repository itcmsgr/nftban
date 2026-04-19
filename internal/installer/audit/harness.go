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
// The harness is intentionally narrow. It does NOT run orchestrators
// itself — it is an assertion kit. Callers run their own dry-run under
// a MockExecutor and then pipe the results through the harness.
//
// Usage:
//
//	mock := executor.NewMockExecutor()
//	stateDir := t.TempDir()
//	// ... run the observational orchestrator ...
//	h := audit.NewPurityHarness(mock, stateDir)
//	h.AssertNoExecutorWrites(t)
//	h.AssertNoMutationCommands(t)
//	h.AssertNoStateDirEntries(t)
//
// Any new mode (install-refuse, update-dry-run, uninstall-dry-run,
// future modes) should use the same harness so the assertion shape does
// not drift.
// =============================================================================
package audit

import (
	"os"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
)

// ForbiddenCommandPatterns is the shared deny-list used by
// AssertNoMutationCommands. Substring-matched against the joined form
// of "command-name arg1 arg2 …".
//
// The list mirrors the CI G3-UN-NO-MUTATION / G3-U5..U10 grep patterns
// but operates at runtime — a command constructed dynamically (which
// source grep cannot see) is still caught here.
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

// AssertNoExecutorWrites fails the test if the mock recorded any call to
// WriteFileAtomic (recorded as entries in Exec.WrittenFiles).
func (h *PurityHarness) AssertNoExecutorWrites(t *testing.T) {
	t.Helper()
	if n := len(h.Exec.WrittenFiles); n != 0 {
		var names []string
		for k := range h.Exec.WrittenFiles {
			names = append(names, k)
		}
		t.Errorf("observational path made %d executor writes (contract: zero): %v", n, names)
	}
}

// AssertNoDirectoryCreations fails the test if the mock recorded any
// MkdirAll.
func (h *PurityHarness) AssertNoDirectoryCreations(t *testing.T) {
	t.Helper()
	if n := len(h.Exec.Dirs); n != 0 {
		var names []string
		for k := range h.Exec.Dirs {
			names = append(names, k)
		}
		t.Errorf("observational path made %d executor MkdirAll calls (contract: zero): %v", n, names)
	}
}

// AssertNoMutationCommands fails the test if any recorded command
// matches one of the forbidden substrings.
func (h *PurityHarness) AssertNoMutationCommands(t *testing.T) {
	t.Helper()
	for _, cmd := range h.Exec.Commands {
		joined := cmd.Name + " " + strings.Join(cmd.Args, " ")
		for _, forbid := range ForbiddenCommandPatterns {
			if strings.Contains(joined, forbid) {
				t.Errorf("forbidden mutation command %q (matched pattern %q) in observational-path trace", joined, forbid)
			}
		}
	}
}

// AssertNoStateDirEntries fails the test if any files or directories
// exist under the harness-owned state directory. This catches direct
// os.WriteFile / os.MkdirAll calls that bypass the mock executor —
// exactly the class that escaped PR-22's original review.
func (h *PurityHarness) AssertNoStateDirEntries(t *testing.T) {
	t.Helper()
	entries, err := os.ReadDir(h.StateDir)
	if err != nil {
		// Non-existent state dir is fine for a purely observational run.
		if os.IsNotExist(err) {
			return
		}
		t.Fatalf("read state dir %s: %v", h.StateDir, err)
	}
	if len(entries) != 0 {
		var names []string
		for _, e := range entries {
			names = append(names, e.Name())
		}
		t.Errorf("observational path created files in state dir %s: %v", h.StateDir, names)
	}
}

// AssertAllPurity runs every assertion in one call — the common case.
func (h *PurityHarness) AssertAllPurity(t *testing.T) {
	t.Helper()
	h.AssertNoExecutorWrites(t)
	h.AssertNoDirectoryCreations(t)
	h.AssertNoMutationCommands(t)
	h.AssertNoStateDirEntries(t)
}
