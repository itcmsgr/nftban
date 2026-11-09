// =============================================================================
// NFTBan v1.236 - feed authority decision table
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="feeds-authority-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-23"
// meta:description="Decide: master on enforces enabled feeds and reports files of disabled feeds; master off honours an intentional disable; the migration condition keeps every file (CONFLICT_KEPT) and stays until resolved; RESOLVED_* recorded states hold; Evaluate reads switches, files and state from disk; a malformed state file is an error."
// meta:inventory.files="internal/feeds/authority_v1236_test.go"
// meta:inventory.privileges="none"
// =============================================================================
package feeds

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func TestDecideMasterOnEnforcesEnabledReportsOthers(t *testing.T) {
	d := Decide(true, map[string]bool{"TOR_EXITS": true, "SPAMHAUS": false}, []string{"spamhaus", "tor_exits"}, "")
	if d.State != StateConsistent || !reflect.DeepEqual(d.Enforced, []string{"tor_exits"}) {
		t.Fatalf("got state=%s enforced=%v", d.State, d.Enforced)
	}
	if !reflect.DeepEqual(d.NotEnabled, []string{"spamhaus"}) || !reflect.DeepEqual(d.Reasons, []string{ReasonFileNotEnabled}) {
		t.Fatalf("a file of a disabled feed must be reported: notEnabled=%v reasons=%v", d.NotEnabled, d.Reasons)
	}
	if !d.NeedsRecord {
		t.Fatal("first evaluation must be recorded")
	}
}

func TestDecideMigrationConditionKeepsEveryFile(t *testing.T) {
	d := Decide(false, map[string]bool{"TOR_EXITS": true}, []string{"spamhaus", "tor_exits"}, "")
	if d.State != StateConflictKept || !reflect.DeepEqual(d.Enforced, []string{"spamhaus", "tor_exits"}) {
		t.Fatalf("migration must keep the v1.235 enforcement (every file): state=%s enforced=%v", d.State, d.Enforced)
	}
	if !reflect.DeepEqual(d.Reasons, []string{ReasonConfigConflict}) || !d.NeedsRecord {
		t.Fatalf("CONFLICT_KEPT must be reported and recorded: %+v", d)
	}
	// Once recorded it persists although nothing else changed, and needs no new record.
	d2 := Decide(false, map[string]bool{"TOR_EXITS": true}, []string{"spamhaus", "tor_exits"}, StateConflictKept)
	if d2.State != StateConflictKept || d2.NeedsRecord {
		t.Fatalf("recorded CONFLICT_KEPT must hold without a rewrite: %+v", d2)
	}
}

func TestDecideIntentionalDisableHonoured(t *testing.T) {
	// Evaluated before (CONSISTENT recorded), master now off: nothing is enforced.
	d := Decide(false, map[string]bool{"TOR_EXITS": true}, []string{"tor_exits"}, StateConsistent)
	if d.State != StateConsistent || len(d.Enforced) != 0 {
		t.Fatalf("a master-off after the first evaluation is a disable: %+v", d)
	}
	// nftban feeds disable: never re-kept, even with per-feed switches on and files present.
	d = Decide(false, map[string]bool{"TOR_EXITS": true}, []string{"tor_exits"}, StateResolvedDisabled)
	if d.State != StateResolvedDisabled || len(d.Enforced) != 0 {
		t.Fatalf("RESOLVED_DISABLED must hold: %+v", d)
	}
}

func TestDecideNoMigrationWithoutFilesOrSwitches(t *testing.T) {
	if d := Decide(false, map[string]bool{"TOR_EXITS": true}, nil, ""); d.State != StateConsistent || len(d.Enforced) != 0 {
		t.Fatalf("no files: not a migration host: %+v", d)
	}
	if d := Decide(false, map[string]bool{"TOR_EXITS": false}, []string{"tor_exits"}, ""); d.State != StateConsistent || len(d.Enforced) != 0 {
		t.Fatalf("no per-feed switch on: not a migration host: %+v", d)
	}
}

func TestDecideResolvedEnabledHolds(t *testing.T) {
	d := Decide(true, map[string]bool{"TOR_EXITS": true}, []string{"tor_exits"}, StateResolvedEnabled)
	if d.State != StateResolvedEnabled || d.NeedsRecord || !reflect.DeepEqual(d.Enforced, []string{"tor_exits"}) {
		t.Fatalf("RESOLVED_ENABLED must hold: %+v", d)
	}
}

func TestEvaluateFromDiskAndStateRoundTrip(t *testing.T) {
	cfg, data := t.TempDir(), t.TempDir()
	if err := os.MkdirAll(filepath.Join(cfg, "conf.d"), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cfg, "conf.d", "feeds.conf"), []byte("FEED_TOR_EXITS_ENABLED=\"false\"\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	// nftban.conf.local wins over feeds.conf.
	if err := os.WriteFile(filepath.Join(cfg, "nftban.conf.local"), []byte("FEED_TOR_EXITS_ENABLED=\"true\" # operator\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(data, "feeds"), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(data, "feeds", "tor_exits.txt"), []byte("# header\n23.129.97.1\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(data, "feeds", "empty.txt"), []byte("# nothing\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	d, err := Evaluate(cfg, data, false)
	if err != nil {
		t.Fatal(err)
	}
	if d.State != StateConflictKept || !reflect.DeepEqual(d.Enforced, []string{"tor_exits"}) {
		t.Fatalf("want CONFLICT_KEPT with tor_exits (empty.txt has no entry): %+v", d)
	}
	if err := WriteState(data, d.State, ReasonConfigConflict, time.Unix(0, 0)); err != nil {
		t.Fatal(err)
	}
	if got, err := ReadState(data); err != nil || got != StateConflictKept {
		t.Fatalf("round trip: %q %v", got, err)
	}
}

// A fresh install with feed files left behind never meets the migration condition.
func TestFreshInstallNeverMigrates(t *testing.T) {
	data := t.TempDir()
	if err := os.MkdirAll(filepath.Join(data, "state"), 0o750); err != nil {
		t.Fatal(err)
	}
	// The installer writes exactly this line on --mode=install.
	if err := os.WriteFile(StatePath(data), StateLine(StateConsistent, ReasonFreshInstall, time.Unix(0, 0)), 0o640); err != nil {
		t.Fatal(err)
	}
	rec, err := ReadState(data)
	if err != nil || rec != StateConsistent {
		t.Fatalf("fresh-install line must parse: %q %v", rec, err)
	}
	d := Decide(false, map[string]bool{"TOR_EXITS": true}, []string{"tor_exits"}, rec)
	if d.State != StateConsistent || len(d.Enforced) != 0 {
		t.Fatalf("leftover files must not enable feeds on a fresh install: %+v", d)
	}
}

func TestReadStateMalformedIsError(t *testing.T) {
	data := t.TempDir()
	if err := os.MkdirAll(filepath.Join(data, "state"), 0o750); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(StatePath(data), []byte("STATE=MAYBE\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadState(data); err == nil {
		t.Fatal("an unknown recorded state must be an error, never a guess")
	}
}
