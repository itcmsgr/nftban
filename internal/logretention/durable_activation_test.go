// SPDX-License-Identifier: MPL-2.0
// meta:name="logretention-durable-activation-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-07-20"
// meta:description="Transaction durability + ORDERING + FAULT-INJECTION proofs for the two-file activation. Records an ordered event trace via the fsyncDir + durableRename seams and asserts the load-bearing staging-dir fsync precedes the first target rename and each target rename precedes the target-dir fsync (T1-C). Injects a post-rename dir-fsync failure on the BACKUP rename and proves the previous active policy is never lost (T1-A). Injects a failure of the pre-activation staging fsync and proves NO target is renamed and the previous policy is intact (T1-B). Exercises the recovery finalize path and proves it fsyncs the staging dir."
// meta:inventory.files="internal/logretention/generate.go,internal/logretention/recover.go"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.binaries=""
// meta:inventory.privileges="none"
package logretention

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/itcmsgr/nftban/internal/safety"
)

// tracer swaps the fsyncDir + durableRename seams to record an ordered event
// trace (still performing the real operation) and returns the trace + a restore
// func. Not parallel-safe (mutates package vars).
type tracer struct {
	mu     sync.Mutex
	events []string
}

func (tr *tracer) add(ev string) {
	tr.mu.Lock()
	tr.events = append(tr.events, ev)
	tr.mu.Unlock()
}

func (tr *tracer) trace() []string {
	tr.mu.Lock()
	defer tr.mu.Unlock()
	return append([]string(nil), tr.events...)
}

func installTracer(t *testing.T) (*tracer, func()) {
	t.Helper()
	tr := &tracer{}
	origFsync := fsyncDir
	origRename := durableRename
	fsyncDir = func(dir string) error {
		tr.add("FSYNC_DIR:" + filepath.Base(dir))
		return origFsync(dir)
	}
	durableRename = func(src, dst string) (safety.RenameOutcome, error) {
		tr.add("RENAME:" + filepath.Base(dst))
		return origRename(src, dst)
	}
	return tr, func() { fsyncDir = origFsync; durableRename = origRename }
}

func firstIndex(events []string, pred func(string) bool) int {
	for i, e := range events {
		if pred(e) {
			return i
		}
	}
	return -1
}

func lastIndex(events []string, pred func(string) bool) int {
	idx := -1
	for i, e := range events {
		if pred(e) {
			idx = i
		}
	}
	return idx
}

const stagingBase = ".nftban-logrotate-staging"

func isStagingFsync(e string) bool { return e == "FSYNC_DIR:"+stagingBase }
func isRename(e string) bool       { return strings.HasPrefix(e, "RENAME:") }

// TestGenerateFsyncsStagingAndTargetDirs proves F1: a successful activation
// fsyncs the staging dir AND the target dir.
func TestGenerateFsyncsStagingAndTargetDirs(t *testing.T) {
	dir := t.TempDir()
	tr, restore := installTracer(t)
	defer restore()

	opts := baseOpts(dir)
	if _, err := Generate(opts); err != nil {
		t.Fatalf("Generate: %v", err)
	}
	ev := tr.trace()
	if firstIndex(ev, isStagingFsync) < 0 {
		t.Fatalf("activation did NOT fsync the staging dir (F1 regression); trace=%v", ev)
	}
	if firstIndex(ev, func(e string) bool { return e == "FSYNC_DIR:logrotate.d" }) < 0 {
		t.Fatalf("activation did NOT fsync the target dir; trace=%v", ev)
	}
}

// TestGenerateActivationOrdering (T1-C) proves the load-bearing staging-dir fsync
// precedes the FIRST target rename, and the post-activation target-dir fsync
// follows the LAST rename — so a future reorder (fsync after activation) fails CI.
func TestGenerateActivationOrdering(t *testing.T) {
	dir := t.TempDir()
	tr, restore := installTracer(t)
	defer restore()

	if _, err := Generate(baseOpts(dir)); err != nil {
		t.Fatalf("Generate: %v", err)
	}
	ev := tr.trace()

	stagingFsync := firstIndex(ev, isStagingFsync)
	firstRename := firstIndex(ev, isRename)
	lastRename := lastIndex(ev, isRename)
	targetFsync := firstIndex(ev, func(e string) bool { return e == "FSYNC_DIR:logrotate.d" })

	if stagingFsync < 0 || firstRename < 0 || targetFsync < 0 {
		t.Fatalf("missing events: stagingFsync=%d firstRename=%d targetFsync=%d trace=%v", stagingFsync, firstRename, targetFsync, ev)
	}
	if stagingFsync >= firstRename {
		t.Fatalf("staging fsync (idx %d) must precede the first target rename (idx %d) — F1 ordering broken; trace=%v", stagingFsync, firstRename, ev)
	}
	if targetFsync <= lastRename {
		t.Fatalf("target-dir fsync (idx %d) must follow the last rename (idx %d); trace=%v", targetFsync, lastRename, ev)
	}
}

// TestBackupPostRenameFsyncFailurePreservesPreimage (T1-A) injects a
// RenameLandedNotDurable outcome on the BACKUP rename (the rename lands but the
// dir fsync "fails") and proves the previous active policy is restored, never
// lost, and no state is written.
func TestBackupPostRenameFsyncFailurePreservesPreimage(t *testing.T) {
	dir := t.TempDir()
	opts := baseOpts(dir)
	opts.SuricataPath = "" // single target keeps the failure on the main backup

	const preserve = "PRESERVE-ME-PREVIOUS-POLICY\n"
	writeFileT(t, opts.MainPath, preserve) // an EXISTING policy → a backup rename happens

	origRename := durableRename
	injected := false
	durableRename = func(src, dst string) (safety.RenameOutcome, error) {
		if strings.HasSuffix(dst, prevSuffix) && !injected {
			injected = true
			// Let the rename LAND, then report a non-durable dir fsync failure.
			if err := os.Rename(src, dst); err != nil {
				return safety.RenameFailed, err
			}
			return safety.RenameLandedNotDurable, errors.New("injected: dir fsync failed after backup rename landed")
		}
		return origRename(src, dst)
	}
	defer func() { durableRename = origRename }()

	_, err := Generate(opts)
	if err == nil {
		t.Fatal("expected Generate to fail on the injected backup fsync error")
	}
	got, rerr := os.ReadFile(opts.MainPath)
	if rerr != nil {
		t.Fatalf("previous policy LOST — MainPath unreadable after backup fsync failure: %v (T1-A data-loss regression)", rerr)
	}
	if string(got) != preserve {
		t.Fatalf("previous policy not restored: MainPath = %q, want %q (T1-A)", got, preserve)
	}
	if _, serr := os.Stat(opts.StatePath); serr == nil {
		t.Fatalf("state was written despite a failed activation")
	}
}

// TestBackupRestoreFailurePreservesEvidenceForRecover (T1-A restore-failure path)
// injects BOTH a post-rename fsync failure on the backup AND a failure of the
// in-line restore, and proves that cleanup is skipped (journal + staged evidence
// preserved) and a subsequent Recover() drives the set to a uniform valid state.
func TestBackupRestoreFailurePreservesEvidenceForRecover(t *testing.T) {
	dir := t.TempDir()
	opts := baseOpts(dir)
	opts.SuricataPath = ""

	const preserve = "PREVIOUS-POLICY-EVIDENCE\n"
	writeFileT(t, opts.MainPath, preserve)

	origRename := durableRename
	backupInjected := false
	durableRename = func(src, dst string) (safety.RenameOutcome, error) {
		if strings.HasSuffix(dst, prevSuffix) && !backupInjected {
			backupInjected = true // backup: land, then report non-durable
			if err := os.Rename(src, dst); err != nil {
				return safety.RenameFailed, err
			}
			return safety.RenameLandedNotDurable, errors.New("injected: backup dir fsync failed")
		}
		if dst == opts.MainPath && backupInjected {
			// restore (bak -> target): simulate an outright failure — the pre-image
			// stays only at bak, so evidence MUST be preserved for Recover().
			return safety.RenameFailed, errors.New("injected: restore rename failed")
		}
		return origRename(src, dst)
	}
	defer func() { durableRename = origRename }()

	if _, err := Generate(opts); err == nil {
		t.Fatal("expected Generate to fail on injected backup+restore failure")
	}
	// Evidence must NOT have been destroyed by cleanup (preserveStaging path).
	if _, jerr := os.Stat(journalPathIn(stagingDirFor(opts.MainPath))); jerr != nil {
		t.Fatalf("recovery evidence (journal) was destroyed by cleanup after an unresolved backup failure: %v (T1-A)", jerr)
	}

	// Recover() must resolve the interrupted activation to a uniform valid state.
	durableRename = origRename // stop injecting for recovery
	res, rerr := Recover(opts.MainPath)
	if rerr != nil {
		t.Fatalf("Recover could not resolve the preserved interrupted activation: %v", rerr)
	}
	if res.Action == RecoverNone {
		t.Fatalf("Recover found no journal to resolve (evidence lost)")
	}
	if _, jerr := os.Stat(journalPathIn(stagingDirFor(opts.MainPath))); !os.IsNotExist(jerr) {
		t.Fatalf("journal not cleared after recovery: %v", jerr)
	}
	got, mrerr := os.ReadFile(opts.MainPath)
	if mrerr != nil || len(got) == 0 {
		t.Fatalf("after recovery the active policy is missing/empty (read err=%v, len=%d)", mrerr, len(got))
	}
}

// TestStagingFsyncFailureAbortsBeforeAnyRename (T1-B) fails the load-bearing
// pre-activation staging fsync and proves NO target rename occurs and the target
// is untouched.
func TestStagingFsyncFailureAbortsBeforeAnyRename(t *testing.T) {
	dir := t.TempDir()
	opts := baseOpts(dir)

	origFsync := fsyncDir
	origRename := durableRename
	renameCount := 0
	firedStagingFail := false
	fsyncDir = func(d string) error {
		if filepath.Base(d) == stagingBase && !firedStagingFail {
			firedStagingFail = true
			return errors.New("injected: staging dir fsync failed")
		}
		return origFsync(d)
	}
	durableRename = func(src, dst string) (safety.RenameOutcome, error) {
		renameCount++
		return origRename(src, dst)
	}
	defer func() { fsyncDir = origFsync; durableRename = origRename }()

	_, err := Generate(opts)
	if err == nil {
		t.Fatal("expected Generate to fail when the pre-activation staging fsync fails")
	}
	if renameCount != 0 {
		t.Fatalf("a target rename occurred (%d) despite the load-bearing staging fsync failing — T1-B invariant broken", renameCount)
	}
	if _, serr := os.Stat(opts.MainPath); serr == nil {
		t.Fatalf("MainPath was created/activated despite the staging fsync failure")
	}
	if _, serr := os.Stat(opts.StatePath); serr == nil {
		t.Fatalf("state was written despite the staging fsync failure")
	}
}

// TestRecoverFinalizeFsyncsStaging (T1-C recovery path) plants a uniform-new
// interrupted activation (journal present, both targets already new) and proves
// Recover() finalizes AND fsyncs the staging dir, then clears the journal.
func TestRecoverFinalizeFsyncsStaging(t *testing.T) {
	sc := newScene(t)
	// Both targets already hold the NEW content (crash after both renames, before
	// the journal was dropped).
	writeFileT(t, sc.mainPath, sc.newMain)
	writeFileT(t, sc.suriPath, sc.newSuri)
	sc.writeJournal(t, sc.entries(true, true))

	tr, restore := installTracer(t)
	defer restore()

	res, err := Recover(sc.mainPath)
	if err != nil {
		t.Fatalf("Recover: %v", err)
	}
	if res.Action != RecoverAlreadyWhole {
		t.Fatalf("Action = %q; want %q", res.Action, RecoverAlreadyWhole)
	}
	if firstIndex(tr.trace(), isStagingFsync) < 0 {
		t.Fatalf("finalizeRecovery did NOT fsync the staging dir; trace=%v", tr.trace())
	}
	if _, statErr := os.Stat(journalPathIn(sc.stagingDir)); !os.IsNotExist(statErr) {
		t.Fatalf("journal not cleared after recovery; stat err=%v", statErr)
	}
	if fileContent(sc.mainPath) != sc.newMain || fileContent(sc.suriPath) != sc.newSuri {
		t.Fatalf("targets not uniform-new after recovery")
	}
}

// TestRecoverNoJournalIsNoop keeps the no-op path covered.
func TestRecoverNoJournalIsNoop(t *testing.T) {
	dir := t.TempDir()
	if _, err := Generate(baseOpts(dir)); err != nil {
		t.Fatalf("seed Generate: %v", err)
	}
	res, err := Recover(baseOpts(dir).MainPath)
	if err != nil {
		t.Fatalf("Recover no-op: %v", err)
	}
	if res.JournalFound {
		t.Fatalf("expected no pending journal after a clean Generate; got %+v", res)
	}
}
