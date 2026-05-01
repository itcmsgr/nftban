// =============================================================================
// NFTBan v1.98.x - Installer Payload Staging Tests (PR-14-pre)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-payload-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-19"
// meta:description="Tests for source-install payload staging + idempotency helpers"
// meta:inventory.files="internal/installer/payload/payload_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package payload

import (
	"bufio"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

func newTestLogger() *logging.Logger {
	return logging.New("", false)
}

// TestDestinations_MatchesBuildEntries — public Destinations() must
// be a parallel projection of private buildEntries(). Establishes the
// single-source-of-truth contract that uninstall.RemoveArtifacts
// depends on.
func TestDestinations_MatchesBuildEntries(t *testing.T) {
	for _, distro := range []*detect.DistroInfo{
		nil,
		{ID: "ubuntu"},
		{ID: "debian"},
		{ID: "rocky"},
		{ID: "almalinux"},
	} {
		entries := buildEntries(distro)
		dests := Destinations(distro)
		if len(entries) != len(dests) {
			t.Fatalf("distro=%+v: len(buildEntries)=%d != len(Destinations)=%d",
				distro, len(entries), len(dests))
		}
		for i := range entries {
			if entries[i].dstGlob != dests[i].Path {
				t.Errorf("distro=%+v: index %d Path mismatch: entry=%q dest=%q",
					distro, i, entries[i].dstGlob, dests[i].Path)
			}
			if entries[i].isDir != dests[i].IsDir {
				t.Errorf("distro=%+v: index %d IsDir mismatch", distro, i)
			}
			if entries[i].srcGlob != dests[i].Glob {
				t.Errorf("distro=%+v: index %d Glob mismatch: entry=%q dest=%q",
					distro, i, entries[i].srcGlob, dests[i].Glob)
			}
		}
	}
}

// -----------------------------------------------------------------------------
// idempotency.go tests — no filesystem needed
// -----------------------------------------------------------------------------

func TestIsConfigLocal(t *testing.T) {
	cases := map[string]bool{
		"/etc/nftban/nftban.conf.local":        true,
		"/etc/nftban/conf.d/ddos.conf.local":   true,
		"/etc/nftban/nftban.local.conf":        true,
		"/etc/nftban/nftban.conf":              false,
		"/etc/nftban/conf.d/ddos.conf":         false,
		"/usr/lib/nftban/scripts/foo.sh":       false,
		"nftban.conf.local":                    true,
		"":                                     false,
	}
	for path, want := range cases {
		if got := isConfigLocal(path); got != want {
			t.Errorf("isConfigLocal(%q) = %v, want %v", path, got, want)
		}
	}
}

func TestCopyIfChanged_WritesWhenMissing(t *testing.T) {
	mock := executor.NewMockExecutor()
	content := []byte("hello")
	wrote, err := copyIfChanged(mock, content, "/etc/nftban/nftban.conf", 0640, newTestLogger())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !wrote {
		t.Errorf("expected wrote=true for new file")
	}
	if string(mock.WrittenFiles["/etc/nftban/nftban.conf"]) != "hello" {
		t.Errorf("file content not written correctly")
	}
}

func TestCopyIfChanged_SkipsIdenticalContent(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Files["/etc/nftban/nftban.conf"] = []byte("same")
	wrote, err := copyIfChanged(mock, []byte("same"), "/etc/nftban/nftban.conf", 0640, newTestLogger())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if wrote {
		t.Errorf("expected wrote=false for identical content")
	}
	if _, ok := mock.WrittenFiles["/etc/nftban/nftban.conf"]; ok {
		t.Errorf("WriteFileAtomic was called for identical content")
	}
}

func TestCopyIfChanged_WritesWhenContentDiffers(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Files["/etc/nftban/nftban.conf"] = []byte("old")
	wrote, err := copyIfChanged(mock, []byte("new"), "/etc/nftban/nftban.conf", 0640, newTestLogger())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !wrote {
		t.Errorf("expected wrote=true for different content")
	}
}

func TestCopyIfChanged_RefusesConfLocalDestination(t *testing.T) {
	mock := executor.NewMockExecutor()
	wrote, err := copyIfChanged(mock, []byte("x"), "/etc/nftban/nftban.conf.local", 0640, newTestLogger())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if wrote {
		t.Errorf("copyIfChanged wrote to .conf.local destination — invariant #9 violated")
	}
	if _, ok := mock.WrittenFiles["/etc/nftban/nftban.conf.local"]; ok {
		t.Errorf("WriteFileAtomic called on .conf.local path")
	}
}

func TestShouldPreserveConfig_NoReplaceWithExisting(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Files["/etc/nftban/nftban.conf"] = []byte("operator edits")
	if !shouldPreserveConfig(mock, "/etc/nftban/nftban.conf", policyConfigNoReplace, newTestLogger()) {
		t.Errorf("expected true for existing noreplace config")
	}
}

func TestShouldPreserveConfig_NoReplaceMissing(t *testing.T) {
	mock := executor.NewMockExecutor()
	if shouldPreserveConfig(mock, "/etc/nftban/nftban.conf", policyConfigNoReplace, newTestLogger()) {
		t.Errorf("expected false when destination is missing")
	}
}

func TestShouldPreserveConfig_AlwaysPolicyIgnoresExisting(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Files["/usr/lib/nftban/bin/nftban-core"] = []byte("old binary")
	if shouldPreserveConfig(mock, "/usr/lib/nftban/bin/nftban-core", policyAlways, newTestLogger()) {
		t.Errorf("expected false for policyAlways regardless of existing content")
	}
}

// -----------------------------------------------------------------------------
// payload.go tests — buildEntries table validation
// -----------------------------------------------------------------------------

func TestBuildEntries_CoversCanonicalBinaryPaths(t *testing.T) {
	entries := buildEntries(&detect.DistroInfo{ID: "ubuntu"})
	// Every Go-installer-authored binary destination must be present.
	required := []string{
		"/usr/lib/nftban/bin/nftban-core",
		"/usr/lib/nftban/bin/nftband",
		"/usr/lib/nftban/bin/nftban-validate",
		"/usr/lib/nftban/bin/nftban-installer",
		"/usr/sbin/nftban",
	}
	dsts := make(map[string]bool)
	for _, e := range entries {
		dsts[e.dstGlob] = true
	}
	for _, r := range required {
		if !dsts[r] {
			t.Errorf("buildEntries missing required destination: %s", r)
		}
	}
}

func TestBuildEntries_UserSbinNftbanIsRootNftban0750(t *testing.T) {
	entries := buildEntries(&detect.DistroInfo{ID: "ubuntu"})
	var found bool
	for _, e := range entries {
		if e.dstGlob == "/usr/sbin/nftban" {
			found = true
			if e.mode != 0750 {
				t.Errorf("/usr/sbin/nftban mode = %o, want 0750 (NB-5 match)", e.mode)
			}
		}
	}
	if !found {
		t.Errorf("no entry for /usr/sbin/nftban")
	}
}

func TestBuildEntries_PolkitDestinationPerDistro(t *testing.T) {
	cases := map[string]string{
		"ubuntu":    "/usr/share/polkit-1/rules.d",
		"debian":    "/usr/share/polkit-1/rules.d",
		"almalinux": "/etc/polkit-1/rules.d",
		"centos":    "/etc/polkit-1/rules.d",
		"rocky":     "/etc/polkit-1/rules.d",
	}
	for distroID, wantDst := range cases {
		entries := buildEntries(&detect.DistroInfo{ID: distroID})
		var found bool
		for _, e := range entries {
			if e.srcRel == "packaging/polkit-1/rules.d" {
				found = true
				if e.dstGlob != wantDst {
					t.Errorf("polkit dst for %s = %s, want %s", distroID, e.dstGlob, wantDst)
				}
			}
		}
		if !found {
			t.Errorf("no polkit entry for distro %s", distroID)
		}
	}
}

func TestBuildEntries_AllConfNoReplaceEntriesAreTemplateConfigs(t *testing.T) {
	entries := buildEntries(&detect.DistroInfo{ID: "ubuntu"})
	for _, e := range entries {
		if e.policy != policyConfigNoReplace {
			continue
		}
		// noreplace entries must live under /etc/nftban or be the commands.registry.yml
		if !strings.HasPrefix(e.dstGlob, "/etc/nftban/") {
			t.Errorf("noreplace entry %s not under /etc/nftban/", e.dstGlob)
		}
	}
}

func TestIsDebianFamily(t *testing.T) {
	cases := map[string]bool{
		"debian":    true,
		"ubuntu":    true,
		"UBUNTU":    true,
		"almalinux": false,
		"centos":    false,
		"rocky":     false,
		"":          false,
	}
	for id, want := range cases {
		if got := isDebianFamily(id); got != want {
			t.Errorf("isDebianFamily(%q) = %v, want %v", id, got, want)
		}
	}
}

// -----------------------------------------------------------------------------
// stageEntry / StageAll — real-filesystem integration test
// -----------------------------------------------------------------------------

func TestStageAll_EmptySrcDirReturnsError(t *testing.T) {
	mock := executor.NewMockExecutor()
	err := StageAll(mock, "", &detect.DistroInfo{ID: "ubuntu"}, newTestLogger())
	if err == nil {
		t.Errorf("expected error for empty srcDir")
	}
}

func TestStageAll_NonexistentSrcDirReturnsError(t *testing.T) {
	mock := executor.NewMockExecutor()
	err := StageAll(mock, "/nonexistent/path", &detect.DistroInfo{ID: "ubuntu"}, newTestLogger())
	if err == nil {
		t.Errorf("expected error for nonexistent srcDir")
	}
}

// setupFakeSrcTree builds a minimal source tree with one file per known
// single-file entry we want to exercise. Uses t.TempDir() so it's cleaned
// up automatically.
func setupFakeSrcTree(t *testing.T) string {
	t.Helper()
	srcDir := t.TempDir()

	writeFile := func(rel, content string) {
		p := filepath.Join(srcDir, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(content), 0644); err != nil {
			t.Fatal(err)
		}
	}

	writeFile("bin/nftban-core", "binary-core")
	writeFile("bin/nftband", "binary-daemon")
	writeFile("bin/nftban-validate", "binary-validate")
	writeFile("bin/nftban-installer", "binary-installer")
	writeFile("cli/sbin/nftban", "cli-entry")
	writeFile("install/config/nftban.conf", "base config")
	writeFile("install/config/nftban.logrotate", "logrotate rules")
	writeFile("install/systemd/tmpfiles.d/nftban.conf", "tmpfiles rules")
	return srcDir
}

func TestStageAll_StagesFromRealTree(t *testing.T) {
	srcDir := setupFakeSrcTree(t)

	mock := executor.NewMockExecutor()
	// Mark the srcDir as existing in mock so StageAll passes its FileExists gate.
	mock.Dirs[srcDir] = true
	// Mark individual source files as existing in the mock view too. stageSingleFile
	// uses exec.FileExists before ReadFile.
	for _, rel := range []string{
		"bin/nftban-core", "bin/nftband", "bin/nftban-validate", "bin/nftban-installer",
		"cli/sbin/nftban", "install/config/nftban.conf", "install/config/nftban.logrotate",
		"install/systemd/tmpfiles.d/nftban.conf",
	} {
		abs := filepath.Join(srcDir, rel)
		data, _ := os.ReadFile(abs)
		mock.Files[abs] = data
	}

	if err := StageAll(mock, srcDir, &detect.DistroInfo{ID: "ubuntu"}, newTestLogger()); err != nil {
		t.Fatalf("StageAll returned error: %v", err)
	}

	// Verify critical destinations were written
	critical := []string{
		"/usr/lib/nftban/bin/nftban-core",
		"/usr/lib/nftban/bin/nftband",
		"/usr/lib/nftban/bin/nftban-validate",
		"/usr/lib/nftban/bin/nftban-installer",
		"/usr/sbin/nftban",
		"/etc/nftban/nftban.conf",
		"/etc/logrotate.d/nftban",
		"/usr/lib/tmpfiles.d/nftban.conf",
	}
	for _, dst := range critical {
		if _, ok := mock.WrittenFiles[dst]; !ok {
			t.Errorf("expected %s to be written, but was not", dst)
		}
	}
}

func TestStageAll_OperatorConfigPreserved(t *testing.T) {
	srcDir := setupFakeSrcTree(t)

	mock := executor.NewMockExecutor()
	mock.Dirs[srcDir] = true
	// Pre-seed an existing /etc/nftban/nftban.conf with operator edits
	mock.Files["/etc/nftban/nftban.conf"] = []byte("operator edits here")
	abs := filepath.Join(srcDir, "install/config/nftban.conf")
	data, _ := os.ReadFile(abs)
	mock.Files[abs] = data

	if err := StageAll(mock, srcDir, &detect.DistroInfo{ID: "ubuntu"}, newTestLogger()); err != nil {
		t.Fatalf("StageAll returned error: %v", err)
	}

	// noreplace policy must preserve the existing content — no write.
	if _, wrote := mock.WrittenFiles["/etc/nftban/nftban.conf"]; wrote {
		t.Errorf("operator-edited nftban.conf was overwritten (noreplace policy violated)")
	}
}

// =============================================================================
// PR-P2-6 — VerifyConfigIntegrity tests
// =============================================================================

// validNftbanConf returns a byte slice that satisfies every
// VerifyConfigIntegrity constraint for /etc/nftban/nftban.conf.
// Tests that want to break a single constraint start from this and
// mutate exactly one dimension.
func validNftbanConf() []byte {
	// 512 bytes of realistic content with the SPDX-License-Identifier
	// token — comfortably above the 256-byte minimum.
	body := "# =============================================================================\n"
	body += "# NFTBan - Main Configuration File\n"
	body += "# =============================================================================\n"
	body += "# SPDX-License-Identifier: MPL-2.0\n"
	body += "# Purpose: operator configuration\n"
	body += "# Some amount of pretend configuration follows so this file is\n"
	body += "# comfortably above the integrity minimum-size floor. A real\n"
	body += "# nftban.conf is tens of kilobytes; this stub represents the\n"
	body += "# smallest operator-edited variant we still want to pass.\n"
	for len(body) < 512 {
		body += "# filler line to exceed the integrity minimum-size floor\n"
	}
	return []byte(body)
}

// validNftablesConf returns a byte slice that satisfies every
// VerifyConfigIntegrity constraint for /etc/nftban/nftables.conf.
func validNftablesConf() []byte {
	body := "#!/usr/sbin/nft -f\n"
	body += "# NFTBan firewall ruleset\n"
	body += "# SPDX-License-Identifier: MPL-2.0\n"
	body += "table ip nftban {\n"
	body += "    chain input {\n"
	body += "        type filter hook input priority 0; policy drop;\n"
	body += "    }\n"
	body += "}\n"
	body += "table ip6 nftban {\n"
	body += "    chain input {\n"
	body += "        type filter hook input priority 0; policy drop;\n"
	body += "    }\n"
	body += "}\n"
	for len(body) < 1024 {
		body += "# filler so the rendered file exceeds the integrity floor\n"
	}
	return []byte(body)
}

// seedIntegrityHappyPath populates a mock with both critical configs
// in their happy-path shape. Used as the base for every integrity test.
func seedIntegrityHappyPath(mock *executor.MockExecutor) {
	mock.Files["/etc/nftban/nftban.conf"] = validNftbanConf()
	mock.Files["/etc/nftban/nftables.conf"] = validNftablesConf()
}

func TestVerifyConfigIntegrity_HappyPath(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedIntegrityHappyPath(mock)
	ok, issues := VerifyConfigIntegrity(mock)
	if !ok {
		t.Errorf("happy path should pass; got issues: %+v", issues)
	}
	if len(issues) != 0 {
		t.Errorf("happy path must produce zero issues; got %d", len(issues))
	}
}

func TestVerifyConfigIntegrity_MissingNftbanConf(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedIntegrityHappyPath(mock)
	delete(mock.Files, "/etc/nftban/nftban.conf")

	ok, issues := VerifyConfigIntegrity(mock)
	if ok {
		t.Fatal("missing nftban.conf must fail integrity check")
	}
	var sawMissing bool
	for _, i := range issues {
		if i.Path == "/etc/nftban/nftban.conf" && strings.Contains(i.Reason, "missing") {
			sawMissing = true
		}
	}
	if !sawMissing {
		t.Errorf("expected 'missing' reason for nftban.conf; got %+v", issues)
	}
}

func TestVerifyConfigIntegrity_UndersizedNftbanConf(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedIntegrityHappyPath(mock)
	// Stub shorter than the 256-byte minimum — simulates a truncated
	// file or an empty-stub regression.
	mock.Files["/etc/nftban/nftban.conf"] = []byte("# SPDX-License-Identifier: MPL-2.0\n")

	ok, issues := VerifyConfigIntegrity(mock)
	if ok {
		t.Fatal("undersized nftban.conf must fail integrity check")
	}
	var sawUndersized bool
	for _, i := range issues {
		if i.Path == "/etc/nftban/nftban.conf" && strings.Contains(i.Reason, "undersized") {
			sawUndersized = true
		}
	}
	if !sawUndersized {
		t.Errorf("expected 'undersized' reason for nftban.conf; got %+v", issues)
	}
}

func TestVerifyConfigIntegrity_NftbanConfMissingLicenseToken(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedIntegrityHappyPath(mock)
	// Large enough but stripped of the SPDX header — simulates operator
	// edit that removed license / shipped config overwritten by
	// something unrelated.
	body := make([]byte, 600)
	for i := range body {
		body[i] = '#'
	}
	mock.Files["/etc/nftban/nftban.conf"] = body

	ok, issues := VerifyConfigIntegrity(mock)
	if ok {
		t.Fatal("nftban.conf without SPDX header must fail integrity check")
	}
	var sawMissingToken bool
	for _, i := range issues {
		if i.Path == "/etc/nftban/nftban.conf" && strings.Contains(i.Reason, "SPDX-License-Identifier") {
			sawMissingToken = true
		}
	}
	if !sawMissingToken {
		t.Errorf("expected missing-SPDX token reason for nftban.conf; got %+v", issues)
	}
}

func TestVerifyConfigIntegrity_NftablesConfMissingShebang(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedIntegrityHappyPath(mock)
	// Replace shebang with a comment — file is still large, still has
	// the table declaration, but missing the functional shebang that
	// nftables.service needs to ExecStart it.
	body := strings.Replace(string(validNftablesConf()), "#!/usr/sbin/nft -f", "# NOT A SHEBANG", 1)
	mock.Files["/etc/nftban/nftables.conf"] = []byte(body)

	ok, issues := VerifyConfigIntegrity(mock)
	if ok {
		t.Fatal("nftables.conf without shebang must fail integrity check")
	}
	var sawMissingToken bool
	for _, i := range issues {
		if i.Path == "/etc/nftban/nftables.conf" && strings.Contains(i.Reason, "#!/usr/sbin/nft") {
			sawMissingToken = true
		}
	}
	if !sawMissingToken {
		t.Errorf("expected missing-shebang reason for nftables.conf; got %+v", issues)
	}
}

func TestVerifyConfigIntegrity_NftablesConfMissingTableDecl(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedIntegrityHappyPath(mock)
	// Strip the nftban table declaration — file is large + has shebang
	// but is functionally meaningless (no nftban-owned ruleset).
	body := strings.ReplaceAll(string(validNftablesConf()), "table ip nftban", "table ip other")
	mock.Files["/etc/nftban/nftables.conf"] = []byte(body)

	ok, issues := VerifyConfigIntegrity(mock)
	if ok {
		t.Fatal("nftables.conf without 'table ip nftban' must fail integrity check")
	}
	var sawMissingToken bool
	for _, i := range issues {
		if i.Path == "/etc/nftban/nftables.conf" && strings.Contains(i.Reason, "table ip nftban") {
			sawMissingToken = true
		}
	}
	if !sawMissingToken {
		t.Errorf("expected missing-table-decl reason for nftables.conf; got %+v", issues)
	}
}

// PR-P2-6 scope-lock regression guard: the integrity check set MUST be
// exactly two files (nftban.conf + nftables.conf). Adding a third file
// requires an explicit contract update — this test is the falsifiable
// record that the set is frozen.
func TestCriticalConfigs_FrozenTwoFileSet(t *testing.T) {
	if len(criticalConfigs) != 2 {
		t.Errorf("criticalConfigs must be frozen at 2 entries (nftban.conf + nftables.conf); got %d — a contract update is required to extend the set", len(criticalConfigs))
	}
	wantPaths := map[string]bool{
		"/etc/nftban/nftban.conf": false,
		"/etc/nftban/nftables.conf":      false,
	}
	for _, cc := range criticalConfigs {
		if _, ok := wantPaths[cc.Path]; !ok {
			t.Errorf("unexpected path in criticalConfigs: %q (scope-lock violation)", cc.Path)
			continue
		}
		wantPaths[cc.Path] = true
	}
	for path, seen := range wantPaths {
		if !seen {
			t.Errorf("expected %s in criticalConfigs; not found", path)
		}
	}
}

// =============================================================================
// PR26.5: source-install payload completeness — integration test
// =============================================================================
// Walks the real repo source tree on disk, runs payload.StageAll into a mock,
// and asserts that:
//   1. Every nftban-owned ExecStart path declared by units in install/systemd/
//      (after the v1.100.1b.A GOTH retirements) is present in mock.WrittenFiles.
//   2. Every panel conf.d main.conf (8 panels) lands at its canonical
//      /etc/nftban/conf.d/panels/<name>/main.conf destination.
// These two checks are the dns2 evidence reproducer — they would have failed
// pre-PR26.5 (missing exporters/cron/scripts/helpers categories + missing
// panels category). Together they pin the staging-table contract.

// locatePayloadRepoRoot climbs from this test file's location until it finds
// the repo's go.mod, and returns that absolute path. Used by the source-tree
// integration tests below so they read the real shipped source files instead
// of a synthetic minimal fixture.
func locatePayloadRepoRoot(t *testing.T) string {
	t.Helper()
	_, this, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatalf("runtime.Caller failed")
	}
	dir := filepath.Dir(this)
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatalf("could not locate go.mod above %s", filepath.Dir(this))
		}
		dir = parent
	}
}

// preloadAllRepoFilesIntoMock walks the repo and pre-populates mock.Files so
// that exec.FileExists / exec.ReadFile succeed for every source path StageAll
// might consult. Skips the test cache + .git + obvious build artifacts.
func preloadAllRepoFilesIntoMock(t *testing.T, mock *executor.MockExecutor, repoRoot string) {
	t.Helper()
	mock.Dirs[repoRoot] = true
	skip := map[string]bool{
		".git":          true,
		"node_modules":  true,
		"build-tmp":     true,
		"gocache":       true,
		"build":         true,
	}
	err := filepath.Walk(repoRoot, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return nil // tolerate transient access errors during walk
		}
		base := filepath.Base(p)
		if info.IsDir() {
			if skip[base] {
				return filepath.SkipDir
			}
			mock.Dirs[p] = true
			return nil
		}
		// Cap file size to avoid loading binaries unnecessarily; staging
		// only needs content for files actually copied.
		if info.Size() > 50*1024*1024 {
			return nil
		}
		data, rerr := os.ReadFile(p)
		if rerr != nil {
			return nil
		}
		mock.Files[p] = data
		return nil
	})
	if err != nil {
		t.Fatalf("walk %s: %v", repoRoot, err)
	}
}

// extractNftbanOwnedExecStartPaths parses one .service unit file and returns
// every ExecStart/Pre/Post path that lives under an nftban-owned prefix. Used
// by the integration test to derive expectations directly from shipped units.
func extractNftbanOwnedExecStartPaths(t *testing.T, unitFile string) []string {
	t.Helper()
	f, err := os.Open(unitFile)
	if err != nil {
		t.Fatalf("open %s: %v", unitFile, err)
	}
	defer f.Close()
	var out []string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		// Match ExecStart / ExecStartPre / ExecStartPost
		var rhs string
		switch {
		case strings.HasPrefix(line, "ExecStart="):
			rhs = strings.TrimPrefix(line, "ExecStart=")
		case strings.HasPrefix(line, "ExecStartPre="):
			rhs = strings.TrimPrefix(line, "ExecStartPre=")
		case strings.HasPrefix(line, "ExecStartPost="):
			rhs = strings.TrimPrefix(line, "ExecStartPost=")
		default:
			continue
		}
		// Strip systemd Exec prefixes
		rhs = strings.TrimLeft(rhs, "-+!@ \t")
		fields := strings.Fields(rhs)
		if len(fields) == 0 {
			continue
		}
		bin := fields[0]
		if !strings.HasPrefix(bin, "/") {
			continue
		}
		// Filter to nftban-owned only
		if isNftbanOwnedPath(bin) {
			out = append(out, bin)
		}
		// Also scan remaining tokens for embedded nftban paths inside
		// shell wrappers (matches systemd_payload's parser policy).
		for _, tok := range fields[1:] {
			tok = strings.Trim(tok, "'\"")
			if strings.HasPrefix(tok, "/") && isNftbanOwnedPath(tok) {
				out = append(out, tok)
			}
		}
	}
	return out
}

// isNftbanOwnedPath mirrors the canonical nftban path-ownership prefixes used
// by the systemd_payload validator. Kept private to this test file to avoid
// pulling the validate package (which imports payload — would create a cycle
// if reversed).
func isNftbanOwnedPath(p string) bool {
	return strings.HasPrefix(p, "/usr/lib/nftban/") ||
		strings.HasPrefix(p, "/etc/nftban/") ||
		p == "/usr/sbin/nftban"
}

// seedStubBuiltBinaries seeds stub source files for the four Go binaries
// that StageAll expects under bin/<name>. CI runners produce a clean source
// checkout without prebuilt binaries — preloadAllRepoFilesIntoMock therefore
// cannot pre-load them. This helper closes that test-environment gap so the
// integration tests don't depend on a prior `./build.sh` invocation.
//
// Production correctness is unaffected: payload.StageAll's binary entries
// remain category=binaries, srcRel=bin/<name>. On real installs the build
// step produces these files; in tests we pretend they exist (with arbitrary
// content) so the subsequent staging copy-or-skip succeeds.
func seedStubBuiltBinaries(t *testing.T, mock *executor.MockExecutor, repoRoot string) {
	t.Helper()
	for _, name := range []string{"nftban-core", "nftband", "nftban-validate", "nftban-installer"} {
		p := filepath.Join(repoRoot, "bin", name)
		mock.Files[p] = []byte("stub-binary")
		mock.Dirs[filepath.Dir(p)] = true
	}
}

// PR26.5 R1: every nftban-owned ExecStart path declared by the shipped
// install/systemd/*.service unit files MUST be staged by payload.StageAll.
// dns2 evidence (2026-04-30) failed exactly this — exporter/cron/scripts/
// helper destinations referenced by units were not in the staging table.
func TestStageAll_AllUnitNftbanOwnedExecStartPathsStaged_PR26_5(t *testing.T) {
	repoRoot := locatePayloadRepoRoot(t)

	mock := executor.NewMockExecutor()
	preloadAllRepoFilesIntoMock(t, mock, repoRoot)
	// CI runners ship a clean checkout without prebuilt binaries; seed
	// stubs so the binary staging entries succeed and we can verify the
	// end-state-on-mock invariant the test was written to enforce.
	seedStubBuiltBinaries(t, mock, repoRoot)

	if err := StageAll(mock, repoRoot, &detect.DistroInfo{ID: "rocky"}, newTestLogger()); err != nil {
		t.Fatalf("StageAll: %v", err)
	}

	// Build the set of expected destination paths from every shipped unit.
	unitFiles, err := filepath.Glob(filepath.Join(repoRoot, "install/systemd/*.service"))
	if err != nil {
		t.Fatalf("glob units: %v", err)
	}
	if len(unitFiles) == 0 {
		t.Fatalf("no unit files found under install/systemd/")
	}

	missing := map[string][]string{} // path -> []unit
	for _, unit := range unitFiles {
		paths := extractNftbanOwnedExecStartPaths(t, unit)
		for _, p := range paths {
			// Skip /usr/sbin/nftban — staged via cli-bin, not under
			// /usr/lib/nftban/ — covered by other tests.
			if p == "/usr/sbin/nftban" {
				if _, ok := mock.WrittenFiles[p]; ok {
					continue
				}
				missing[p] = append(missing[p], filepath.Base(unit))
				continue
			}
			if _, ok := mock.WrittenFiles[p]; !ok {
				missing[p] = append(missing[p], filepath.Base(unit))
			}
		}
	}
	if len(missing) > 0 {
		for path, units := range missing {
			t.Errorf("ExecStart destination not staged: %s  (referenced by: %s)",
				path, strings.Join(units, ", "))
		}
	}
}

// PR26.5 R2: every panel's canonical conf.d main.conf must be staged.
// PR26.4's panelfw adapters (DirectAdmin currently, cPanel/Plesk/etc. in
// PR26.7+) consume these via internal/ports/panel_loader.LoadPanelConfig.
// dns2 evidence failed `panel_survival_ok` because the DirectAdmin entry
// was missing from the staging table.
func TestStageAll_AllPanelConfDStaged_PR26_5(t *testing.T) {
	repoRoot := locatePayloadRepoRoot(t)

	mock := executor.NewMockExecutor()
	preloadAllRepoFilesIntoMock(t, mock, repoRoot)
	// Seed stub binaries so StageAll's binary entries succeed on CI runners
	// that don't have prebuilt binaries in bin/. Doesn't affect this test's
	// assertions (they check /etc/nftban/conf.d/panels/* destinations, not
	// /usr/lib/nftban/bin/*) but keeps StageAll's overall completeness behavior
	// consistent across tests.
	seedStubBuiltBinaries(t, mock, repoRoot)

	if err := StageAll(mock, repoRoot, &detect.DistroInfo{ID: "rocky"}, newTestLogger()); err != nil {
		t.Fatalf("StageAll: %v", err)
	}

	// 8 first-class panels per V190_PANELS audit.
	panels := []string{
		"directadmin",
		"cpanel",
		"plesk",
		"cyberpanel",
		"cwp",
		"interworx",
		"vesta",
		"generic",
	}
	for _, p := range panels {
		dst := "/etc/nftban/conf.d/panels/" + p + "/main.conf"
		// Only assert if the source file exists in the repo (skip
		// gracefully on test forks that prune some panels).
		src := filepath.Join(repoRoot, "etc/nftban/conf.d/panels", p, "main.conf")
		if _, err := os.Stat(src); err != nil {
			t.Logf("source absent for panel %s — skipping (%v)", p, err)
			continue
		}
		if _, ok := mock.WrittenFiles[dst]; !ok {
			t.Errorf("panel conf.d not staged: %s (source: %s)", dst, src)
		}
	}
}

// PR26.5 R3: regression guard for the original dns2 ExecStart-staging
// failures. After PR26.5, the four destinations below MUST be present in
// mock.WrittenFiles. They map to the four "shell payload" categories added
// to buildEntries: exporters, cron, scripts, install/helpers.
func TestStageAll_PR26_5_NewShellCategoriesStaged(t *testing.T) {
	repoRoot := locatePayloadRepoRoot(t)

	mock := executor.NewMockExecutor()
	preloadAllRepoFilesIntoMock(t, mock, repoRoot)
	// Stub binaries (CI-runner consistency). See helper doc.
	seedStubBuiltBinaries(t, mock, repoRoot)

	if err := StageAll(mock, repoRoot, &detect.DistroInfo{ID: "rocky"}, newTestLogger()); err != nil {
		t.Fatalf("StageAll: %v", err)
	}

	mustHave := []string{
		"/usr/lib/nftban/exporters/nftban_unified_exporter.sh",
		"/usr/lib/nftban/cron/maintenance.sh",
		"/usr/lib/nftban/scripts/nftban-soak-check.sh",
		"/usr/lib/nftban/helpers/firewall-init-with-delay.sh",
	}
	for _, dst := range mustHave {
		if _, ok := mock.WrittenFiles[dst]; !ok {
			t.Errorf("PR26.5 staging gap not closed: %s missing from WrittenFiles", dst)
		}
	}
}
