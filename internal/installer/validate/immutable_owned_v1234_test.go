// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
//
// v1.234 (PR #1439, acceptance 1): SetImmutableFlags records the flags it sets and
// never adopts an immutable flag it cannot prove it set. On v1.233.1 it ran
// `chattr +i` unconditionally and wrote no record, so every later strip had to infer
// ownership from the path — TestSetImmutableFlags_* fail on v1.233.1 (no record
// written, admin-flag case not distinguished).
package validate

import (
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/fhs"
)

const schemaPath = "/usr/lib/nftban/lib/nft_schema.sh"

func immutMock() *executor.MockExecutor {
	m := executor.NewMockExecutor()
	m.ExistingCommands["chattr"] = true
	m.ExistingCommands["lsattr"] = true
	m.Files[fhs.MainConf] = []byte("x")
	m.Files[schemaPath] = []byte("x")
	return m
}

func setAttr(m *executor.MockExecutor, path, attrs, ino, ctime string) {
	m.RunResults["lsattr:-d:"+path] = executor.Result{ExitCode: 0, Stdout: attrs + " " + path + "\n"}
	m.RunResults["stat:-c:%i %Z:"+path] = executor.Result{ExitCode: 0, Stdout: ino + " " + ctime + "\n"}
	m.RunResults["chattr:+i:"+path] = executor.Result{ExitCode: 0}
}

func recordLines(t *testing.T, m *executor.MockExecutor) map[string][]string {
	t.Helper()
	data, ok := m.WrittenFiles[ImmutableOwnedRecord]
	if !ok {
		t.Fatalf("ownership record %s was not written", ImmutableOwnedRecord)
	}
	out := map[string][]string{}
	for _, l := range strings.Split(string(data), "\n") {
		f := strings.Split(l, "\t")
		if len(f) == 5 {
			out[f[0]] = f
		}
	}
	return out
}

func TestSetImmutableFlags_SetsAndRecordsFlagsItSets(t *testing.T) {
	m := immutMock()
	setAttr(m, fhs.MainConf, "--------------e-------", "11", "1790000000")
	setAttr(m, schemaPath, "--------------e-------", "22", "1790000001")
	SetImmutableFlags(m, nolog())
	for _, p := range []string{fhs.MainConf, schemaPath} {
		if !m.CommandCalled("chattr", "+i", p) {
			t.Errorf("chattr +i %s not called", p)
		}
	}
	rec := recordLines(t, m)
	if e := rec[fhs.MainConf]; e == nil || e[1] != "11" || e[2] != "1790000000" || e[3] != "locked" {
		t.Errorf("record for %s = %v, want inode 11 ctime 1790000000 locked", fhs.MainConf, e)
	}
	if e := rec[schemaPath]; e == nil || e[3] != "locked" {
		t.Errorf("record for %s = %v, want locked", schemaPath, e)
	}
}

func TestSetImmutableFlags_AdminFlagIsNeitherTouchedNorRecorded(t *testing.T) {
	m := immutMock()
	setAttr(m, fhs.MainConf, "----i---------e-------", "11", "1790000000") // +i, no proof
	setAttr(m, schemaPath, "--------------e-------", "22", "1790000001")
	SetImmutableFlags(m, nolog())
	if m.CommandCalled("chattr", "+i", fhs.MainConf) || m.CommandCalled("chattr", "-i", fhs.MainConf) {
		t.Errorf("an unproven (administrator) flag must not be touched")
	}
	rec := recordLines(t, m)
	if _, ok := rec[fhs.MainConf]; ok {
		t.Errorf("an unproven flag must not be recorded as NFTBan-owned: %v", rec[fhs.MainConf])
	}
	if _, ok := rec[schemaPath]; !ok {
		t.Errorf("the flag NFTBan set must be recorded")
	}
}

func TestSetImmutableFlags_KeepsProvenRecordEntry(t *testing.T) {
	m := immutMock()
	m.Files[ImmutableOwnedRecord] = []byte(fhs.MainConf + "\t11\t1790000000\tlocked\t1789999999\n")
	setAttr(m, fhs.MainConf, "----i---------e-------", "11", "1790000000")
	setAttr(m, schemaPath, "--------------e-------", "22", "1790000001")
	SetImmutableFlags(m, nolog())
	rec := recordLines(t, m)
	if e := rec[fhs.MainConf]; e == nil || e[4] != "1789999999" {
		t.Errorf("proven entry must be kept unchanged, got %v", e)
	}
	// ctime changed since the record (someone touched the attributes): not proven.
	m2 := immutMock()
	m2.Files[ImmutableOwnedRecord] = []byte(fhs.MainConf + "\t11\t1790000000\tlocked\t1789999999\n")
	setAttr(m2, fhs.MainConf, "----i---------e-------", "11", "1790000500")
	setAttr(m2, schemaPath, "--------------e-------", "22", "1790000001")
	SetImmutableFlags(m2, nolog())
	if _, ok := recordLines(t, m2)[fhs.MainConf]; ok {
		t.Errorf("an entry whose ctime no longer matches must not be kept")
	}
}

func TestSetImmutableFlags_AdoptsPreV1234FlagOnlyWithLogProof(t *testing.T) {
	m := immutMock()
	// ctime 1790000000 = 2026-09-21T14:13:20Z
	m.Files[installerLogPath] = []byte("2026-09-21T14:13:20Z [DEBUG] set immutable: " + fhs.MainConf + "\n")
	setAttr(m, fhs.MainConf, "----i---------e-------", "11", "1790000000")
	setAttr(m, schemaPath, "----i---------e-------", "22", "1790000300") // log line does not match
	SetImmutableFlags(m, nolog())
	rec := recordLines(t, m)
	if _, ok := rec[fhs.MainConf]; !ok {
		t.Errorf("flag proven by installer.log at its ctime must be adopted")
	}
	if _, ok := rec[schemaPath]; ok {
		t.Errorf("flag without a matching installer.log line must not be adopted")
	}
}
