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
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

func newTestLogger() *logging.Logger {
	return logging.New("", false)
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

func TestBuildEntries_UIRemoveInV2MarkersPresent(t *testing.T) {
	entries := buildEntries(&detect.DistroInfo{ID: "ubuntu"})
	var uiCount int
	for _, e := range entries {
		if e.uiRemoveInV2 {
			uiCount++
		}
	}
	// Expected: nftban-ui binary + nftban-ui-auth libexec (2 UI binaries).
	if uiCount < 2 {
		t.Errorf("expected at least 2 UI entries marked REMOVE-IN-V2.0.0, got %d", uiCount)
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
