// =============================================================================
// NFTBan - FHS fallback permissions must be bounded, never recursive
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="installer-fhs-permissions-bounded-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Regression guard for the FHS fallback permission path. applyPermissions is the installer's FALLBACK, reached when the generated primary script is missing or fails. It previously carried five `chown -R` calls that were strictly WEAKER than the primary path they stand in for: `chown -R nftban:nftban /var/lib/nftban` flattened reports/auditors (root:nftban-auditor 0770/0660 audit-evidence boundary) plus backup/, update-backups/ and pro/ (root:nftban), and `chown -R nftban:nftban /run/nftban` flattened firewall-validate (root:nftban 2750) — while the primary generated script explicitly EXCLUDES the auditor tree and re-applies it separately. Asserts: (a) no ownership/mode command ever carries a recursive flag; (b) the heterogeneous canonical boundaries are applied with their DECLARED owner, not the tree default; (c) every emitted chown target is a path RequiredDirs declares, so the fallback cannot mutate anything outside the canonical skeleton."
// meta:inventory.files="internal/installer/fhs/permissions.go,internal/installer/fhs/paths.go"
// meta:inventory.privileges="none"
// =============================================================================
package fhs

import (
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// runFallback drives applyPermissions with every canonical directory present, so
// the bounded loop actually emits a command for each one.
func runFallback(t *testing.T) []executor.RecordedCommand {
	t.Helper()
	m := executor.NewMockExecutor()
	for _, d := range RequiredDirs {
		m.Dirs[d.Path] = true
	}
	for _, d := range CanonicalLogDirs {
		m.Dirs[d] = true
	}
	m.Dirs[BinDir] = true
	applyPermissions(m, logging.New(t.TempDir()+"/fallback.log", false))
	if len(m.Commands) == 0 {
		t.Fatal("no commands recorded — the fallback did nothing, so this test proves nothing")
	}
	return m.Commands
}

// TestFallbackPermissionsAreNeverRecursive is the core guard. A recursive flag on
// chown/chmod in the fallback is the defect itself.
func TestFallbackPermissionsAreNeverRecursive(t *testing.T) {
	for _, c := range runFallback(t) {
		if c.Name != "chown" && c.Name != "chmod" {
			continue
		}
		for _, a := range c.Args {
			if a == "-R" || a == "--recursive" {
				t.Errorf("recursive ownership/mode mutation in the FALLBACK path: %s %v\n"+
					"  RECOVERY/FALLBACK MUST NOT BE WEAKER THAN PRIMARY.\n"+
					"  The primary generated script uses bounded `find` with explicit exclusions;\n"+
					"  a recursive fallback flattens the canonical matrix it stands in for.", c.Name, c.Args)
			}
		}
	}
}

// TestFallbackPreservesHeterogeneousBoundaries pins the two boundaries the removed
// recursion provably destroyed. These are the motivating defects, named explicitly so
// a future change cannot silently re-flatten them.
func TestFallbackPreservesHeterogeneousBoundaries(t *testing.T) {
	cmds := runFallback(t)

	// owner applied to a given path by the last chown targeting it
	ownerOf := func(path string) (string, bool) {
		owner, found := "", false
		for _, c := range cmds {
			if c.Name == "chown" && len(c.Args) >= 2 && c.Args[len(c.Args)-1] == path {
				owner, found = c.Args[len(c.Args)-2], true
			}
		}
		return owner, found
	}

	for _, tc := range []struct {
		path, wantOwner, why string
	}{
		{DataDir + "/reports/auditors", "root:nftban-auditor",
			"audit-evidence boundary; recursion gave the daemon ownership of its own audit evidence"},
		{DataDir + "/backup", "root:nftban", "root-owned admin root"},
		{DataDir + "/update-backups", "root:nftban", "root-owned admin root"},
		{DataDir + "/pro", "root:nftban", "root-owned admin root"},
		{DataDir, "root:nftban", "data root is root-owned, not daemon-owned"},
	} {
		got, found := ownerOf(tc.path)
		if !found {
			t.Errorf("%s: no chown emitted — canonical boundary not asserted by the fallback (%s)",
				tc.path, tc.why)
			continue
		}
		if got != tc.wantOwner {
			t.Errorf("%s: owner %q, want %q (%s)", tc.path, got, tc.wantOwner, tc.why)
		}
	}

	// /run/nftban/firewall-validate is root:nftban 2750 (setgid). It is owned by
	// systemd-tmpfiles (install/systemd/tmpfiles.d/nftban.conf), which is the correct
	// mechanism for a tmpfs path, so it is deliberately NOT in RequiredDirs and the
	// fallback must not assert it. What the fallback must never do is CLAIM it: the
	// removed `chown -R nftban:nftban /run/nftban` flattened it to the daemon identity.
	// This is therefore a negative assertion, not a positive one.
	for _, c := range cmds {
		if c.Name != "chown" || len(c.Args) < 2 {
			continue
		}
		target := c.Args[len(c.Args)-1]
		if target == RunDir+"/firewall-validate" || target == RunDir {
			if owner := c.Args[len(c.Args)-2]; owner == "nftban:nftban" && target != RunDir {
				t.Errorf("fallback claimed %s as %s — that is the setgid boundary tmpfiles owns",
					target, owner)
			}
		}
	}
}

// TestFallbackTouchesOnlyDeclaredPaths proves the fallback cannot mutate anything
// outside the canonical skeleton. This is what bounds it across mount boundaries:
// `chown -R` traverses bind mounts (measured) and chown has no --one-file-system,
// so the only durable bound is "never recurse, only touch declared paths".
func TestFallbackTouchesOnlyDeclaredPaths(t *testing.T) {
	declared := map[string]bool{
		BinDir: true, NodeExporterDir: true, NftbanCLI: true,
	}
	for _, d := range RequiredDirs {
		declared[d.Path] = true
	}
	for _, d := range CanonicalLogDirs {
		declared[d] = true
	}
	for _, c := range runFallback(t) {
		if c.Name != "chown" && c.Name != "chmod" || len(c.Args) == 0 {
			continue
		}
		target := c.Args[len(c.Args)-1]
		if !declared[target] {
			t.Errorf("fallback mutated a path outside the canonical skeleton: %s %v",
				c.Name, c.Args)
		}
	}
}
