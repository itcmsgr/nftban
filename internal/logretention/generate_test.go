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
	"syscall"
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

// Z3: a second generation with identical inputs must rewrite NOTHING — the policy
// file keeps its inode + mtime (no churn), the state file keeps its mtime, and
// Generate reports Unchanged. This is the 15-minute maintenance-timer case.
func TestGenerateUnchangedIsNoWrite(t *testing.T) {
	dir := t.TempDir()
	mainPath := filepath.Join(dir, "logrotate.d", "nftban")
	statePath := filepath.Join(dir, "state", "nftban-effective.state.json")

	first, err := Generate(baseOpts(dir))
	if err != nil {
		t.Fatalf("first Generate: %v", err)
	}
	if first.Unchanged {
		t.Fatal("first generation must not be reported Unchanged")
	}
	inoA, mtimeA := inodeMtime(t, mainPath)
	stMtimeA := statMtime(t, statePath)

	// identical inputs, later wall clock — must still be a no-op.
	opts := baseOpts(dir)
	opts.Now = fixedNow.Add(30 * time.Minute)
	second, err := Generate(opts)
	if err != nil {
		t.Fatalf("second Generate: %v", err)
	}
	if !second.Unchanged {
		t.Error("second generation with identical inputs must be Unchanged (no rewrite)")
	}
	inoB, mtimeB := inodeMtime(t, mainPath)
	if inoA != inoB {
		t.Errorf("policy inode changed on unchanged run: %d -> %d (file was rewritten)", inoA, inoB)
	}
	if !mtimeA.Equal(mtimeB) {
		t.Errorf("policy mtime changed on unchanged run: %v -> %v", mtimeA, mtimeB)
	}
	if stMtimeB := statMtime(t, statePath); !stMtimeA.Equal(stMtimeB) {
		t.Errorf("state file mtime changed on unchanged run: %v -> %v (state churn)", stMtimeA, stMtimeB)
	}

	// staging must be clean (no leftover temps/journal from the skipped run).
	staging := filepath.Join(dir, "logrotate.d", ".nftban-logrotate-staging")
	if se, _ := os.ReadDir(staging); len(se) != 0 {
		t.Errorf("staging not clean after unchanged run: %d entries", len(se))
	}
}

func inodeMtime(t *testing.T, path string) (uint64, time.Time) {
	t.Helper()
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		t.Skip("inode not available on this platform")
	}
	return st.Ino, fi.ModTime()
}

func statMtime(t *testing.T, path string) time.Time {
	t.Helper()
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	return fi.ModTime()
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
	// R4: the logrotate SCAN dir must never contain scratch (temp/backup/journal);
	// those live only in the .nftban-logrotate-staging subdir, which is cleaned on
	// failure.
	entries, _ := os.ReadDir(filepath.Dir(mainPath))
	for _, e := range entries {
		if strings.Contains(e.Name(), ".gen-") || strings.HasSuffix(e.Name(), prevSuffix) || e.Name() == "activation.journal" {
			t.Errorf("scratch leaked into the logrotate scan dir: %s", e.Name())
		}
	}
	staging := filepath.Join(filepath.Dir(mainPath), ".nftban-logrotate-staging")
	if se, _ := os.ReadDir(staging); len(se) != 0 {
		t.Errorf("staging dir not cleaned after failure: %d entries", len(se))
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

	staging := filepath.Join(dir, ".staging")
	if err := os.MkdirAll(staging, 0o700); err != nil {
		t.Fatal(err)
	}
	goodTmp, _ := writeStaged(staging, "nftban", "NEW-MAIN\n")
	candidates := map[string]string{
		mainPath: goodTmp,
		suriPath: filepath.Join(staging, "does-not-exist-temp"), // rename will fail
	}
	targets := []genTarget{{mainPath, "main"}, {suriPath, "suricata"}}
	if _, err := activateWithRollback(targets, candidates, staging); err == nil {
		t.Fatal("expected activation failure on broken second candidate")
	}
	if got := readFile(t, mainPath); got != mSent {
		t.Errorf("main NOT rolled back: %q", got)
	}
	if got := readFile(t, suriPath); got != sSent {
		t.Errorf("suricata NOT preserved: %q", got)
	}
	// backups live in staging (NOT the logrotate scan dir); none dangling after rollback
	for _, d := range []string{dir, staging} {
		entries, _ := os.ReadDir(d)
		for _, e := range entries {
			if strings.HasSuffix(e.Name(), prevSuffix) {
				t.Errorf("dangling backup after rollback in %s: %s", d, e.Name())
			}
		}
	}
	_ = os.Remove(goodTmp)
}

func TestGenerateScanDirCleanAndStaged(t *testing.T) {
	dir := t.TempDir()
	if _, err := Generate(baseOpts(dir)); err != nil {
		t.Fatal(err)
	}
	scan := filepath.Join(dir, "logrotate.d")
	entries, _ := os.ReadDir(scan)
	names := map[string]bool{}
	for _, e := range entries {
		names[e.Name()] = true
		if strings.Contains(e.Name(), ".gen-") || strings.HasSuffix(e.Name(), prevSuffix) || e.Name() == "activation.journal" {
			t.Errorf("R4: scratch in the logrotate scan dir: %s", e.Name())
		}
	}
	if !names["nftban"] || !names["nftban-suricata"] {
		t.Error("activated policy files missing from scan dir")
	}
	// staging is a dot-subdir (not a regular file logrotate would parse) and empty
	staging := filepath.Join(scan, ".nftban-logrotate-staging")
	if se, _ := os.ReadDir(staging); len(se) != 0 {
		t.Errorf("staging not cleaned after success: %d entries", len(se))
	}
}

func TestGenerateRecoversFromLeftoverJournal(t *testing.T) {
	dir := t.TempDir()
	staging := filepath.Join(dir, "logrotate.d", ".nftban-logrotate-staging")
	if err := os.MkdirAll(staging, 0o700); err != nil {
		t.Fatal(err)
	}
	// simulate a crash mid-activation: a stale journal + a stale staged temp
	_ = os.WriteFile(filepath.Join(staging, "activation.journal"), []byte(`{"x":"y"}`), 0o600)
	_ = os.WriteFile(filepath.Join(staging, "nftban.gen-STALE"), []byte("junk"), 0o644)
	if _, err := Generate(baseOpts(dir)); err != nil {
		t.Fatalf("Generate should self-heal from a leftover journal: %v", err)
	}
	// journal + stale temp cleared; policy activated
	if _, err := os.Stat(filepath.Join(staging, "activation.journal")); !os.IsNotExist(err) {
		t.Error("stale journal not cleared after recovery")
	}
	if se, _ := os.ReadDir(staging); len(se) != 0 {
		t.Errorf("staging not clean after recovery: %d entries", len(se))
	}
	if _, err := os.Stat(filepath.Join(dir, "logrotate.d", "nftban")); err != nil {
		t.Error("policy not activated after recovery")
	}
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
