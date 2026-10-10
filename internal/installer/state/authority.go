// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
//
// meta:name="installer-state-firewall-authority"
// meta:type="library"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.235 (owner 2026-10-10): may NFTBan write firewall rules on this host right now? ONE decision table, shared with the shell twin nftban_firewall_authority (lib/service_control.sh) through scripts/ci/data/firewall-authority-cases.tsv. A refused install, an interrupted or failed transaction, a released install, the operator's disable and the kernel emergency bypass all deny; only a completed authorized transaction, or the live installer transaction itself, grants."
// meta:inventory.files="/var/lib/nftban/state/install_state,/var/lib/nftban/state/installer.lock,/etc/nftban/conf.d/services.conf,/proc/cmdline,/proc/locks"

package state

import (
	"bufio"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	"github.com/itcmsgr/nftban/internal/configloader"
)

// AuthorityDecision is the answer of FirewallAuthority. Reason is a stable word (it is
// the case-table column and the text operators see); Detail names the state behind it.
type AuthorityDecision struct {
	Granted bool
	Reason  string
	Detail  string
}

// AuthorityInputs are the files the decision reads. Production uses DefaultAuthorityInputs.
type AuthorityInputs struct {
	StateDir    string // install_state + installer.lock
	ConfigDir   string // conf.d/services.conf(.local), the master switch
	ProcCmdline string
	ProcLocks   string
}

// DefaultAuthorityInputs are the installed paths.
func DefaultAuthorityInputs() AuthorityInputs {
	return AuthorityInputs{
		StateDir:    DefaultStateDir,
		ConfigDir:   "/etc/nftban",
		ProcCmdline: "/proc/cmdline",
		ProcLocks:   "/proc/locks",
	}
}

func deny(reason, detail string) AuthorityDecision {
	return AuthorityDecision{Granted: false, Reason: reason, Detail: detail}
}

// FirewallAuthority applies the decision table, in this order:
//
//  1. kernel parameter nftban=disabled                     -> deny emergency-bypass
//  2. NFTBAN_ENABLED off                                   -> deny disabled
//     NFTBAN_ENABLED invalid / unreadable                  -> deny switch-unusable
//  3. install_state absent / unreadable                    -> deny no-install-state / install-state-unreadable
//  4. UNINSTALL_* / RESTORE_*                              -> deny released
//  5. FAILED_AUTHORITY_ABORT                               -> deny refused
//  6. the installer lock is held RIGHT NOW (kernel lock table, not the PID file alone):
//     AUTHORITY FRESH/TAKEOVER/UPDATE                      -> grant transaction
//     otherwise                                            -> deny no-authority-grant
//  7. COMMITTED / APPLIED_UNVERIFIED / DEGRADED with that AUTHORITY -> grant authorized
//     (the state name alone grants nothing)                -> deny no-authority-grant
//  8. a progress state with no live installer               -> deny transaction-interrupted
//  9. FAILED_* / REBUILD_*                                  -> deny needs-repair
//  10. anything else                                        -> deny unknown-state
//
// The authorized transaction needs no COMMITTED: the installer persists AUTHORITY at
// DETECT_COMPLETE before its first mutation and holds the lock until it ends, so its
// own rebuild and daemon start pass at step 6. When it dies the kernel releases the
// lock, and the recorded grant stops counting (step 8/9) until an explicit --repair.
func FirewallAuthority(in AuthorityInputs) AuthorityDecision {
	if cmdlineHasBypass(in.ProcCmdline) {
		return deny("emergency-bypass", "kernel parameter nftban=disabled")
	}
	switch sw, raw, file, _ := configloader.MasterSwitch(in.ConfigDir); sw {
	case configloader.SwitchOn:
	case configloader.SwitchOff:
		return deny("disabled", "NFTBAN_ENABLED=false")
	default:
		return deny("switch-unusable", configloader.SwitchProblem(sw, raw, file))
	}

	sf := NewStateFile(in.StateDir)
	if err := sf.Read(); err != nil {
		if os.IsNotExist(err) {
			return deny("no-install-state", sf.Path())
		}
		return deny("install-state-unreadable", sf.Path())
	}
	st := string(sf.State)
	if !sf.StateFieldPresent() {
		st = "" // the reader's in-memory default is not a recorded state
	}
	detail := "INSTALL_STATE=" + st + " AUTHORITY=" + sf.Authority
	granted := sf.Authority == "FRESH" || sf.Authority == "TAKEOVER" || sf.Authority == "UPDATE"

	switch {
	case strings.HasPrefix(st, "UNINSTALL_"), strings.HasPrefix(st, "RESTORE_"):
		return deny("released", detail)
	case InstallState(st) == StateFailedAbort:
		return deny("refused", detail)
	}
	if InstallerLockHeld(in.StateDir, in.ProcLocks) {
		if granted {
			return AuthorityDecision{Granted: true, Reason: "transaction", Detail: detail}
		}
		return deny("no-authority-grant", detail)
	}
	switch InstallState(st) {
	case StateCommitted, StateAppliedUnverified, StateDegraded:
		if granted {
			return AuthorityDecision{Granted: true, Reason: "authorized", Detail: detail}
		}
		return deny("no-authority-grant", detail)
	case StateFilesInstalled, StateDetectComplete, StatePrepareComplete, StateSwitchComplete, StateServicesComplete:
		return deny("transaction-interrupted", detail)
	}
	if strings.HasPrefix(st, "FAILED_") || strings.HasPrefix(st, "REBUILD_") {
		return deny("needs-repair", detail)
	}
	return deny("unknown-state", detail)
}

func cmdlineHasBypass(path string) bool {
	data, err := os.ReadFile(filepath.Clean(path)) // #nosec G304 -- fixed kernel path (test: temp file)
	if err != nil {
		return false
	}
	for _, w := range strings.Fields(string(data)) {
		if w == "nftban=disabled" {
			return true
		}
	}
	return false
}

// InstallerLockHeld reports whether the installer lock is held right now: the kernel
// lock table (/proc/locks) has a FLOCK on the lock file's inode by the PID the lock file
// names. A PID file alone proves nothing (the kernel releases a dead holder's flock, the
// file keeps its PID); this never takes the lock (a probe would make a concurrent
// installer fail with "another installer is running").
func InstallerLockHeld(stateDir, procLocks string) bool {
	lp := LockFilePath(stateDir)
	fi, err := os.Stat(lp)
	if err != nil {
		return false
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return false
	}
	data, err := os.ReadFile(filepath.Clean(lp)) // #nosec G304 -- LockFilePath
	if err != nil {
		return false
	}
	pid := strings.TrimSpace(string(data))
	if _, err := strconv.Atoi(pid); err != nil || pid == "" {
		return false
	}
	ino := strconv.FormatUint(st.Ino, 10)
	f, err := os.Open(filepath.Clean(procLocks)) // #nosec G304 -- fixed kernel path (test: temp file)
	if err != nil {
		return false
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		// "1: FLOCK  ADVISORY  WRITE 1234 fd:00:5678 0 EOF"; a blocked waiter has "->" as field 2.
		fl := strings.Fields(sc.Text())
		if len(fl) < 6 || fl[1] != "FLOCK" {
			continue
		}
		dev := fl[5]
		if fl[4] == pid && dev[strings.LastIndexByte(dev, ':')+1:] == ino {
			return true
		}
	}
	return false
}
