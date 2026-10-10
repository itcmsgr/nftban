// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
//
// meta:description="v1.235 (owner 2026-10-10): state.FirewallAuthority against the SHARED case table scripts/ci/data/firewall-authority-cases.tsv (the shell twin nftban_firewall_authority is held to the same table by firewall_authority_v1235_test.sh). Every row is built as real files: services.conf, install_state (a directory = unreadable), installer.lock and a /proc/locks image. Also: the lock check needs the kernel lock table — a PID file alone, a lock on another inode, or a blocked waiter (->) is not a held lock."

package state

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

const testLockPID = "4242"

// buildAuthorityCase writes one table row as files and returns the inputs.
func buildAuthorityCase(t *testing.T, bypass, sw, statefile, st, auth, lock string) AuthorityInputs {
	t.Helper()
	root := t.TempDir()
	in := AuthorityInputs{
		StateDir:    filepath.Join(root, "state"),
		ConfigDir:   filepath.Join(root, "etc"),
		ProcCmdline: filepath.Join(root, "cmdline"),
		ProcLocks:   filepath.Join(root, "locks"),
	}
	must := func(err error) {
		if err != nil {
			t.Fatal(err)
		}
	}
	must(os.MkdirAll(in.StateDir, 0o755))
	must(os.MkdirAll(filepath.Join(in.ConfigDir, "conf.d"), 0o755))
	cmdline := "BOOT_IMAGE=/vmlinuz root=/dev/vda1 ro quiet"
	if bypass == "yes" {
		cmdline += " nftban=disabled"
	}
	must(os.WriteFile(in.ProcCmdline, []byte(cmdline+"\n"), 0o644))
	svc := filepath.Join(in.ConfigDir, "conf.d", "services.conf")
	switch sw {
	case "on":
		must(os.WriteFile(svc, []byte("NFTBAN_ENABLED=true\n"), 0o644))
	case "off":
		must(os.WriteFile(svc, []byte("NFTBAN_ENABLED=false\n"), 0o644))
	case "invalid":
		must(os.WriteFile(svc, []byte("NFTBAN_ENABLED=maybe\n"), 0o644))
	case "unknown":
		must(os.MkdirAll(svc, 0o755)) // exists, cannot be read as a file
	default:
		t.Fatalf("switch column %q", sw)
	}
	stPath := filepath.Join(in.StateDir, StateFileName)
	switch statefile {
	case "present":
		var b strings.Builder
		b.WriteString("# NFTBan Install State — machine-written, do not edit\n")
		if st != "-" {
			b.WriteString("INSTALL_STATE=" + st + "\n")
		}
		a := auth
		if a == "-" {
			a = ""
		}
		b.WriteString("AUTHORITY=" + a + "\n")
		must(os.WriteFile(stPath, []byte(b.String()), 0o640))
	case "unreadable":
		must(os.MkdirAll(stPath, 0o755)) // a read of a directory fails, as root too
	case "absent":
	default:
		t.Fatalf("statefile column %q", statefile)
	}
	locks := "1: POSIX  ADVISORY  WRITE 999 fd:00:12 0 EOF\n"
	switch lock {
	case "live", "stale":
		lp := LockFilePath(in.StateDir)
		must(os.WriteFile(lp, []byte(testLockPID+"\n"), 0o640))
		if lock == "live" {
			fi, err := os.Stat(lp)
			must(err)
			ino := fi.Sys().(*syscall.Stat_t).Ino
			locks += fmt.Sprintf("2: FLOCK  ADVISORY  WRITE %s fd:00:%d 0 EOF\n", testLockPID, ino)
		}
	case "none":
	default:
		t.Fatalf("lock column %q", lock)
	}
	must(os.WriteFile(in.ProcLocks, []byte(locks), 0o644))
	return in
}

func TestFirewallAuthoritySharedCases(t *testing.T) {
	f, err := os.Open(filepath.Join("..", "..", "..", "scripts", "ci", "data", "firewall-authority-cases.tsv"))
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
		c := strings.Split(line, "\t")
		if len(c) != 8 {
			t.Fatalf("malformed case line %q", line)
		}
		in := buildAuthorityCase(t, c[0], c[1], c[2], c[3], c[4], c[5])
		got := FirewallAuthority(in)
		verdict := "DENIED"
		if got.Granted {
			verdict = "GRANTED"
		}
		if verdict != c[6] || got.Reason != c[7] {
			t.Errorf("%s: got %s %s (%s), want %s %s", line, verdict, got.Reason, got.Detail, c[6], c[7])
		}
		n++
	}
	if n < 35 {
		t.Fatalf("only %d cases read — the shared table is incomplete", n)
	}
}

func TestInstallerLockHeldNeedsTheKernelLock(t *testing.T) {
	in := buildAuthorityCase(t, "no", "on", "present", "PREPARE_COMPLETE", "TAKEOVER", "stale")
	lp := LockFilePath(in.StateDir)
	fi, err := os.Stat(lp)
	if err != nil {
		t.Fatal(err)
	}
	ino := fi.Sys().(*syscall.Stat_t).Ino
	for name, locks := range map[string]string{
		"pid file only":       "",
		"other inode":         fmt.Sprintf("1: FLOCK  ADVISORY  WRITE %s fd:00:%d 0 EOF\n", testLockPID, ino+1),
		"other pid":           fmt.Sprintf("1: FLOCK  ADVISORY  WRITE 4243 fd:00:%d 0 EOF\n", ino),
		"posix not flock":     fmt.Sprintf("1: POSIX  ADVISORY  WRITE %s fd:00:%d 0 EOF\n", testLockPID, ino),
		"blocked waiter only": fmt.Sprintf("1: -> FLOCK  ADVISORY  WRITE %s fd:00:%d 0 EOF\n", testLockPID, ino),
	} {
		if err := os.WriteFile(in.ProcLocks, []byte(locks), 0o644); err != nil {
			t.Fatal(err)
		}
		if InstallerLockHeld(in.StateDir, in.ProcLocks) {
			t.Errorf("%s: reported the installer lock as held", name)
		}
	}
	held := fmt.Sprintf("1: FLOCK  ADVISORY  WRITE %s fd:00:%d 0 EOF\n", testLockPID, ino)
	if err := os.WriteFile(in.ProcLocks, []byte(held), 0o644); err != nil {
		t.Fatal(err)
	}
	if !InstallerLockHeld(in.StateDir, in.ProcLocks) {
		t.Error("the kernel holds the lock for the recorded PID: must report held")
	}
}
