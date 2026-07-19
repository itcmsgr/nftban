// SPDX-License-Identifier: MPL-2.0
// meta:name="logretention-recover"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-07-19"
// meta:description="Z1 crash-consistency recovery for the two-phase logrotate-policy activation. A crash between the main and suricata renames would leave the on-disk policy set SPLIT (one file new, one old). Recover() reads the durable activation journal and DETERMINISTICALLY drives the set to a uniform all-new (roll-forward, completing the already-validated intent) or all-old (roll-back, when candidates are no longer available) state — never eventual-consistency-via-next-regeneration. Idempotent and safe to call before every consumer: generate, status (must not report ACTIVE_MATCH over a pending journal), and the maintenance step that triggers logrotate. Because every file mutation is an atomic rename, each target is only ever fully-old or fully-new (no torn content), so the current on-disk hash classifies it unambiguously against the journal."
// meta:depends="encoding/json,os,path/filepath"
// meta:inventory.files="internal/logretention/recover.go"
// meta:inventory.env_vars=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.binaries=""
// meta:inventory.config_files=""
// meta:inventory.privileges="root to repair (renames under /etc/logrotate.d); read-only detection needs only read on the staging dir"
package logretention

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// Recovery action strings (stable; asserted by tests and surfaced in status).
const (
	RecoverNone           = "none"          // no journal present — nothing to do
	RecoverAlreadyWhole   = "already_whole" // journal present but the set is already uniform
	RecoverRolledFwd      = "rolled_forward"
	RecoverRolledBack     = "rolled_back"
	RecoverDiscardedStale = "discarded_stale" // legacy/corrupt journal — safe to drop (see note)
)

// RecoverResult reports what Recover observed and did.
type RecoverResult struct {
	JournalFound bool     // an activation journal existed
	Action       string   // one of the Recover* constants
	Targets      []string // targets named by the journal
	FromState    string   // "uniform_new" | "uniform_old" | "split" (as found)
}

// PendingActivation reports, read-only, whether an interrupted activation is
// still pending (a journal exists). Callers that cannot write (non-root status)
// use this to refuse to report ACTIVE_MATCH over an unrepaired split.
func PendingActivation(mainPath string) bool {
	_, err := os.Stat(journalPathIn(stagingDirFor(mainPath)))
	return err == nil
}

// Recover completes or unwinds an interrupted activation so the on-disk policy
// set is uniform. It is a no-op (JournalFound=false) when no journal exists.
// Requires write access to the target directory + staging dir to repair.
func Recover(mainPath string) (RecoverResult, error) {
	stagingDir := stagingDirFor(mainPath)
	journalPath := journalPathIn(stagingDir)

	data, err := os.ReadFile(journalPath) // #nosec G304 -- generator-owned staging journal path
	if err != nil {
		if os.IsNotExist(err) {
			return RecoverResult{Action: RecoverNone}, nil
		}
		return RecoverResult{}, fmt.Errorf("logretention: read activation journal: %w", err)
	}
	// A journal is written + fsync'd BEFORE the first target is renamed. So an
	// unparseable journal, or one from a different (legacy/pre-Z1 or future)
	// version whose entry semantics we cannot trust, necessarily corresponds to a
	// crash that happened no later than journal creation — i.e. NO target was
	// mutated yet. Discarding it is therefore safe (equivalent to a roll-back to
	// the untouched set) and, critically, never bricks generation on upgrade.
	var j activationJournal
	if err := json.Unmarshal(data, &j); err != nil || j.Version != activationJournalVersion {
		if derr := os.Remove(journalPath); derr != nil && !os.IsNotExist(derr) {
			return RecoverResult{JournalFound: true}, fmt.Errorf("logretention: discard stale journal %s: %w", journalPath, derr)
		}
		_ = removeDirContents(stagingDir)
		return RecoverResult{JournalFound: true, Action: RecoverDiscardedStale}, nil
	}

	res := RecoverResult{JournalFound: true}
	newCount := 0
	for _, e := range j.Entries {
		res.Targets = append(res.Targets, e.Target)
		if hashFileOrEmpty(e.Target) == e.CandidateHash {
			newCount++
		}
	}
	n := len(j.Entries)
	switch {
	case n == 0:
		res.FromState = "uniform_new"
	case newCount == n:
		res.FromState = "uniform_new"
	case newCount == 0:
		res.FromState = "uniform_old"
	default:
		res.FromState = "split"
	}

	// Already uniform-new: the transaction reached all targets; just finalize.
	if n == 0 || newCount == n {
		if err := finalizeRecovery(stagingDir, journalPath, j); err != nil {
			return res, err
		}
		res.Action = RecoverAlreadyWhole
		return res, nil
	}

	// Prefer ROLL-FORWARD: the candidates were validated together, so completing
	// the intended activation is the correct outcome — provided every not-yet-new
	// target still has its staged candidate intact.
	if canRollForward(j) {
		if err := rollForward(j); err != nil {
			return res, err
		}
		if err := finalizeRecovery(stagingDir, journalPath, j); err != nil {
			return res, err
		}
		res.Action = RecoverRolledFwd
		return res, nil
	}

	// Fall back to ROLL-BACK: restore every already-new target to its pre-image so
	// the set is uniform-old. Requires the backups (present until the whole set is
	// activated, which is exactly the split window).
	if canRollBack(j) {
		if err := rollBack(j); err != nil {
			return res, err
		}
		if err := finalizeRecovery(stagingDir, journalPath, j); err != nil {
			return res, err
		}
		res.Action = RecoverRolledBack
		return res, nil
	}

	return res, errors.New("logretention: interrupted activation is unrepairable (neither all candidates nor all backups are available); manual inspection required")
}

// isNew reports whether the on-disk target already holds the new candidate.
func isNew(e journalEntry) bool { return hashFileOrEmpty(e.Target) == e.CandidateHash }

func canRollForward(j activationJournal) bool {
	for _, e := range j.Entries {
		if isNew(e) {
			continue
		}
		// Not yet new -> its staged candidate must still exist and match.
		if hashFileOrEmpty(e.CandidatePath) != e.CandidateHash {
			return false
		}
	}
	return true
}

func canRollBack(j activationJournal) bool {
	for _, e := range j.Entries {
		if !isNew(e) {
			continue
		}
		// Already new -> to undo it we need its pre-image. If the target existed
		// before (PrevHash != ""), the backup must be present and match; if it did
		// not exist before, undo is a delete (always possible).
		if e.PrevHash == "" {
			continue
		}
		if hashFileOrEmpty(e.BackupPath) != e.PrevHash {
			return false
		}
	}
	return true
}

// rollForward renames each not-yet-new candidate into its target (atomic),
// backing up any surviving old target first so a re-crash still rolls back.
func rollForward(j activationJournal) error {
	for _, e := range j.Entries {
		if isNew(e) {
			continue
		}
		if _, err := os.Stat(e.Target); err == nil {
			// An old target is present (candidate never landed) — preserve its
			// pre-image if we haven't already, then replace it.
			if hashFileOrEmpty(e.BackupPath) != e.PrevHash {
				_ = os.Rename(e.Target, e.BackupPath)
			} else {
				_ = os.Remove(e.Target)
			}
		}
		if err := os.Rename(e.CandidatePath, e.Target); err != nil {
			return fmt.Errorf("logretention: roll-forward %s: %w", e.Target, err)
		}
	}
	return nil
}

// rollBack restores each already-new target to its pre-image (or removes it if it
// did not exist before), yielding a uniform-old set.
func rollBack(j activationJournal) error {
	for _, e := range j.Entries {
		if !isNew(e) {
			continue
		}
		if e.PrevHash == "" {
			if err := os.Remove(e.Target); err != nil && !os.IsNotExist(err) {
				return fmt.Errorf("logretention: roll-back remove %s: %w", e.Target, err)
			}
			continue
		}
		if err := os.Rename(e.BackupPath, e.Target); err != nil {
			return fmt.Errorf("logretention: roll-back restore %s: %w", e.Target, err)
		}
	}
	return nil
}

// finalizeRecovery removes the journal + staging contents and fsyncs the target
// directory so the recovered uniform state is durable.
func finalizeRecovery(stagingDir, journalPath string, j activationJournal) error {
	// Drop the journal first: once removed, a re-crash sees no pending activation.
	if err := os.Remove(journalPath); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("logretention: clear journal: %w", err)
	}
	if len(j.Entries) > 0 {
		fsyncDir(filepath.Dir(j.Entries[0].Target))
	}
	_ = removeDirContents(stagingDir)
	return nil
}
