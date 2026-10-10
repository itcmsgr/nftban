// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="master_switch_test"
// meta:type="test"
// meta:description="v1.235 K2 (owner 2026-10-08): the ONE NFTBAN_ENABLED contract. ParseSwitch is asserted against the SHARED case table scripts/ci/data/master-switch-cases.tsv (the shell readers are asserted against the same table by row486_disable_bypass_v1235_test E9). MasterSwitch: absent key keeps the documented default (on); services.conf.local overrides services.conf; an INVALID declaration is reported with its value and file."

package configloader

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseSwitchSharedCases(t *testing.T) {
	f, err := os.Open(filepath.Join("..", "..", "scripts", "ci", "data", "master-switch-cases.tsv"))
	if err != nil {
		t.Fatalf("shared case table: %v", err)
	}
	defer f.Close()
	n := 0
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, "\t", 2)
		if len(parts) != 2 {
			t.Fatalf("malformed case line %q", line)
		}
		in := parts[0]
		if in == "<EMPTY>" {
			in = ""
		}
		if got := ParseSwitch(in); string(got) != parts[1] {
			t.Errorf("ParseSwitch(%q) = %s, want %s", in, got, parts[1])
		}
		n++
	}
	if n < 30 {
		t.Fatalf("only %d cases read from the shared table", n)
	}
}

func TestMasterSwitchFiles(t *testing.T) {
	dir := t.TempDir()
	conf := filepath.Join(dir, "conf.d")
	if err := os.MkdirAll(conf, 0o755); err != nil {
		t.Fatal(err)
	}
	if st, _, _, known := MasterSwitch(dir); st != SwitchOn || !known {
		t.Fatalf("absent key: got %s known=%v, want on (documented default)", st, known)
	}
	_ = os.WriteFile(filepath.Join(conf, "services.conf"), []byte("NFTBAN_ENABLED=\"true\"\n"), 0o644)
	_ = os.WriteFile(filepath.Join(conf, "services.conf.local"), []byte("NFTBAN_ENABLED=flase\n"), 0o644)
	st, raw, file, known := MasterSwitch(dir)
	if st != SwitchInvalid || raw != "flase" || file != filepath.Join(conf, "services.conf.local") || !known {
		t.Fatalf("local invalid: got (%s,%q,%q,%v)", st, raw, file, known)
	}
	_ = os.WriteFile(filepath.Join(conf, "services.conf.local"), []byte("NFTBAN_ENABLED=off\n"), 0o644)
	if st, _, _, _ := MasterSwitch(dir); st != SwitchOff {
		t.Fatalf("local off overrides main true: got %s", st)
	}
	// K2-c: a services.conf.local that EXISTS but cannot be read (a directory: EISDIR even for
	// root) is UNKNOWN, wins over main "true", and names the file.
	local := filepath.Join(conf, "services.conf.local")
	_ = os.Remove(local)
	if err := os.Mkdir(local, 0o755); err != nil {
		t.Fatal(err)
	}
	st, _, file, known = MasterSwitch(dir)
	if st != SwitchUnknown || known || file != local {
		t.Fatalf("unreadable local: got (%s,%q,%v), want (unknown,%q,false)", st, file, known, local)
	}
	if p := SwitchProblem(st, "", file); p != "UNKNOWN ("+local+" exists but could not be read: make it a readable file)" {
		t.Fatalf("SwitchProblem(unknown) = %q", p)
	}
	// Owner 2026-10-08: a REAL read failure of a regular file, for root too: /proc/self/mem is a
	// regular file whose read at offset 0 fails (EIO) for every process. Precondition proven here.
	if _, err := os.ReadFile("/proc/self/mem"); err == nil {
		t.Skip("precondition: /proc/self/mem is readable here (NOT_EXECUTED)")
	}
	_ = os.Remove(local)
	if err := os.Symlink("/proc/self/mem", local); err != nil {
		t.Fatal(err)
	}
	if st, _, file, known = MasterSwitch(dir); st != SwitchUnknown || known || file != local {
		t.Fatalf("read failure (EIO): got (%s,%q,%v), want (unknown,%q,false)", st, file, known, local)
	}
}
