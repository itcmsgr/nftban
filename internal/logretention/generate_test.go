// SPDX-License-Identifier: MPL-2.0
// meta:name="logretention-generate-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-07-19"
// meta:description="Gate B Phase-5 transaction tests: successful activation writes bounded+validated policy files (do-not-edit header, generator version) and a generated-state record with per-family forensic floors + prior/active hashes; a failing candidate validation leaves BOTH previous files intact and writes NO state; two-file activation rolls back BOTH files if either fails (no split-brain); an exclusive generation lock prevents concurrent generation; missing logrotate fails safe; deterministic render is byte-identical for identical inputs (DEB/RPM parity); DefaultValidator validates candidates together and rejects a malformed one without touching real logrotate state."
// meta:inventory.files="internal/logretention/generate.go,internal/logretention/render.go"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.binaries="logrotate"
// meta:inventory.privileges="none"
package logretention

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

var fixedNow = time.Date(2026, 7, 19, 12, 0, 0, 0, time.UTC)

func okValidator([]string) (string, error) { return "stub-ok", nil }

func baseOpts(dir string) GenerateOptions {
	return GenerateOptions{
		LogDir:        "/var/log",
		MainPath:      filepath.Join(dir, "logrotate.d", "nftban"),
		SuricataPath:  filepath.Join(dir, "logrotate.d", "nftban-suricata"),
		StatePath:     filepath.Join(dir, "state", "nftban-effective.state.json"),
		Disk:          DiskFacts{Path: "/var/log", TotalBytes: 64 * GiB, AvailBytes: 40 * GiB},
		SourceVersion: "1.222.0-test",
		Reason:        "manual",
		Now:           fixedNow,
		Validator:     okValidator,
	}
}

func TestGenerateActivatesAndWritesState(t *testing.T) {
	dir := t.TempDir()
	st, err := Generate(baseOpts(dir))
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	main := readFile(t, filepath.Join(dir, "logrotate.d", "nftban"))
	if !strings.Contains(main, "GENERATED EFFECTIVE POLICY. DO NOT EDIT") {
		t.Error("main policy missing do-not-edit header")
	}
	if !strings.Contains(main, "generator-version="+GeneratorVersion) {
		t.Error("main policy header missing generator version")
	}
	if !strings.Contains(main, "/var/log/nftban/bans.log") {
		t.Error("main policy missing expected stanza content")
	}
	if strings.Contains(main, "eve-alerts.json") {
		t.Error("suricata stanza leaked into main file")
	}
	suri := readFile(t, filepath.Join(dir, "logrotate.d", "nftban-suricata"))
	if !strings.Contains(suri, "eve-alerts.json") || !strings.Contains(suri, "copytruncate") {
		t.Error("suricata policy missing eve-alerts/copytruncate")
	}
	if strings.Contains(suri, "USR2") {
		t.Error("R1 regression: eve must NOT use USR2 (rule reload != log reopen)")
	}
	if st.UnboundedCount != 0 || st.TheoreticalMaxBytes > st.BudgetBytes {
		t.Errorf("state invariant broken: unbounded=%d max=%d budget=%d", st.UnboundedCount, st.TheoreticalMaxBytes, st.BudgetBytes)
	}
	if !st.ValidationOK || st.PolicyVersion != PolicyVersion || st.GeneratorVersion != GeneratorVersion {
		t.Errorf("state validation/version wrong: %+v", st)
	}
	if st.ActivePolicyHashes["nftban"] == "" || st.ActivePolicyHashes["nftban-suricata"] == "" {
		t.Error("state missing active policy hashes")
	}
	// per-family forensic floor is recorded
	var sawFloor bool
	for _, f := range st.Families {
		if f.ForensicFloorDays > 0 {
			sawFloor = true
		}
	}
	if !sawFloor {
		t.Error("state families missing forensic floor days")
	}
	if _, err := os.Stat(filepath.Join(dir, "state", "nftban-effective.state.json")); err != nil {
		t.Errorf("state file not written: %v", err)
	}
}

func TestGenerateFailSafeOnInvalidCandidate(t *testing.T) {
	dir := t.TempDir()
	mainPath := filepath.Join(dir, "logrotate.d", "nftban")
	suriPath := filepath.Join(dir, "logrotate.d", "nftban-suricata")
	if err := os.MkdirAll(filepath.Dir(mainPath), 0o755); err != nil {
		t.Fatal(err)
	}
	mSent := "# PREVIOUS MAIN - must survive\n"
	sSent := "# PREVIOUS SURICATA - must survive\n"
	_ = os.WriteFile(mainPath, []byte(mSent), 0o644)
	_ = os.WriteFile(suriPath, []byte(sSent), 0o644)

	opts := baseOpts(dir)
	opts.Validator = func([]string) (string, error) { return "stub", errors.New("simulated malformed candidate") }
	if _, err := Generate(opts); err == nil {
		t.Fatal("Generate should have failed on invalid candidate")
	}
	if got := readFile(t, mainPath); got != mSent {
		t.Errorf("main policy modified on failure:\n%s", got)
	}
	if got := readFile(t, suriPath); got != sSent {
		t.Errorf("suricata policy modified on failure:\n%s", got)
	}
	if _, err := os.Stat(filepath.Join(dir, "state", "nftban-effective.state.json")); !os.IsNotExist(err) {
		t.Error("state record written despite failure")
	}
	entries, _ := os.ReadDir(filepath.Dir(mainPath))
	for _, e := range entries {
		if strings.Contains(e.Name(), ".gen-") || strings.HasSuffix(e.Name(), prevSuffix) {
			t.Errorf("leftover temp/backup: %s", e.Name())
		}
	}
}

// TestActivateWithRollbackRestoresBoth drives the private two-file activation
// with a broken second candidate; BOTH previous files must be restored.
func TestActivateWithRollbackRestoresBoth(t *testing.T) {
	dir := t.TempDir()
	mainPath := filepath.Join(dir, "nftban")
	suriPath := filepath.Join(dir, "nftban-suricata")
	mSent, sSent := "OLD-MAIN\n", "OLD-SURI\n"
	_ = os.WriteFile(mainPath, []byte(mSent), 0o644)
	_ = os.WriteFile(suriPath, []byte(sSent), 0o644)

	goodTmp, _ := writeTemp(mainPath, "NEW-MAIN\n")
	candidates := map[string]string{
		mainPath: goodTmp,
		suriPath: filepath.Join(dir, "does-not-exist-temp"), // rename will fail
	}
	targets := []genTarget{{mainPath, "main"}, {suriPath, "suricata"}}
	if err := activateWithRollback(targets, candidates); err == nil {
		t.Fatal("expected activation failure on broken second candidate")
	}
	if got := readFile(t, mainPath); got != mSent {
		t.Errorf("main NOT rolled back: %q", got)
	}
	if got := readFile(t, suriPath); got != sSent {
		t.Errorf("suricata NOT preserved: %q", got)
	}
	// no .prev backups left dangling
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), prevSuffix) {
			t.Errorf("dangling backup after rollback: %s", e.Name())
		}
	}
	_ = os.Remove(goodTmp)
}

func TestConcurrentGeneratorLock(t *testing.T) {
	lock := filepath.Join(t.TempDir(), "gen.lock")
	unlock1, err := acquireLock(lock)
	if err != nil {
		t.Fatalf("first lock: %v", err)
	}
	if _, err := acquireLock(lock); err == nil {
		t.Error("second concurrent lock should have failed")
	}
	unlock1()
	unlock2, err := acquireLock(lock)
	if err != nil {
		t.Errorf("lock after release should succeed: %v", err)
	}
	unlock2()
}

func TestGenerateRefusesWhenLockHeld(t *testing.T) {
	dir := t.TempDir()
	opts := baseOpts(dir)
	opts.LockPath = filepath.Join(dir, "gen.lock")
	unlock, err := acquireLock(opts.LockPath)
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	if _, err := Generate(opts); err == nil {
		t.Error("Generate should refuse while the generation lock is held")
	}
}

func TestGenerateFailSafeMissingLogrotate(t *testing.T) {
	saved := os.Getenv("PATH")
	t.Cleanup(func() { _ = os.Setenv("PATH", saved) })
	_ = os.Setenv("PATH", "")
	if _, err := DefaultValidator([]string{filepath.Join(t.TempDir(), "cand")}); err == nil {
		t.Error("DefaultValidator should fail when logrotate is not on PATH")
	}
}

func TestDeterministicByteEquivalence(t *testing.T) {
	d1, d2 := t.TempDir(), t.TempDir()
	if _, err := Generate(baseOpts(d1)); err != nil {
		t.Fatal(err)
	}
	if _, err := Generate(baseOpts(d2)); err != nil {
		t.Fatal(err)
	}
	a := readFile(t, filepath.Join(d1, "logrotate.d", "nftban"))
	b := readFile(t, filepath.Join(d2, "logrotate.d", "nftban"))
	if a != b {
		t.Error("generated main policy is not byte-identical for identical inputs")
	}
}

func TestDefaultValidatorRealLogrotate(t *testing.T) {
	if _, err := exec.LookPath("logrotate"); err != nil {
		t.Skip("logrotate not installed")
	}
	me := currentUserGroup(t)
	dir := t.TempDir()
	logfile := filepath.Join(dir, "sample.log")
	_ = os.WriteFile(logfile, []byte("x\n"), 0o644)

	good := filepath.Join(dir, "good.conf")
	_ = os.WriteFile(good, []byte(logfile+" {\n    weekly\n    rotate 4\n    size 10M\n    compress\n    missingok\n    notifempty\n    copytruncate\n    create 0640 "+me+"\n}\n"), 0o644)
	if _, err := DefaultValidator([]string{good}); err != nil {
		t.Errorf("valid candidate rejected by real logrotate: %v", err)
	}

	bad := filepath.Join(dir, "bad.conf")
	_ = os.WriteFile(bad, []byte(logfile+" {\n    this-is-not-a-directive 99\n    rotate abc\n}\n"), 0o644)
	if _, err := DefaultValidator([]string{bad}); err == nil {
		t.Error("malformed candidate passed real logrotate validation")
	}
}

func readFile(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("read %s: %v", p, err)
	}
	return string(b)
}

func currentUserGroup(t *testing.T) string {
	t.Helper()
	u, err := exec.Command("id", "-un").Output()
	if err != nil {
		t.Skip("cannot resolve current user")
	}
	g, err := exec.Command("id", "-gn").Output()
	if err != nil {
		t.Skip("cannot resolve current group")
	}
	return strings.TrimSpace(string(u)) + " " + strings.TrimSpace(string(g))
}
