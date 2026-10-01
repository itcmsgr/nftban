// =============================================================================
// NFTBan - proven ownership of immutable (+i) flags (v1.234, PR #1439)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="installer-immutable-ownership"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-01"
// meta:description="Go twin of cli/lib/nftban/lib/nftban_immutable_owned.sh. NFTBan removes or restores an immutable flag only when its ownership is PROVEN. Accepted evidence, and nothing else: (1) the ownership record /var/lib/nftban/state/immutable-owned has an entry for the path whose inode AND ctime equal the file's current inode and ctime (ctime changes on every later attribute change, and a replaced file has a new inode); (2) for flags set before v1.234 (no record), the LAST 'set immutable: <path>' line in installer.log is timestamped at exactly the file's ctime second. Pre-v1.234 logs carry no inode, so a same-second administrator action is indistinguishable - documented residual. Anything else is administrator-owned: never removed, never restored."
// meta:inventory.files="/var/lib/nftban/state/immutable-owned, /var/log/nftban/installer.log"
// meta:inventory.binaries="lsattr, chattr, stat"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package immutable

import (
	"strconv"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/fhs"
)

// RecordPath is the ownership record of the +i flags NFTBan itself set or cleared.
// Format, one line per file: path TAB inode TAB ctime(epoch s) TAB locked|unlocked TAB written_at.
const RecordPath = fhs.StateDir + "/immutable-owned"

// InstallerLogPath is where installers log "set immutable: <path>".
const InstallerLogPath = "/var/log/nftban/installer.log"

// Candidates are the files NFTBan applies its +i policy to (build/+i-lifecycle-matrix.yaml
// protected_files; validate.SetImmutableFlags). Being a candidate is NOT ownership.
var Candidates = []string{"/etc/nftban/nftban.conf", "/usr/lib/nftban/lib/nft_schema.sh"}

// Entry is one ownership record line.
type Entry struct {
	Path, Ino, Ctime, State, At string
}

// ReadRecord parses the ownership record (missing/unreadable = empty).
func ReadRecord(exec executor.Executor) map[string]Entry {
	out := map[string]Entry{}
	data, err := exec.ReadFile(RecordPath)
	if err != nil {
		return out
	}
	for _, line := range strings.Split(string(data), "\n") {
		f := strings.Split(line, "\t")
		if len(f) != 5 || !strings.HasPrefix(f[0], "/") {
			continue
		}
		out[f[0]] = Entry{f[0], f[1], f[2], f[3], f[4]}
	}
	return out
}

// InoCtime returns the file's inode and ctime (epoch s) via stat(1).
func InoCtime(exec executor.Executor, path string) (string, string, bool) {
	res := exec.Run("stat", "-c", "%i %Z", path)
	if res.ExitCode != 0 {
		return "", "", false
	}
	f := strings.Fields(strings.TrimSpace(res.Stdout))
	if len(f) != 2 {
		return "", "", false
	}
	return f[0], f[1], true
}

// HasImmutable reports (flag present, measured).
func HasImmutable(exec executor.Executor, path string) (bool, bool) {
	res := exec.Run("lsattr", "-d", path)
	if res.ExitCode != 0 {
		return false, false
	}
	f := strings.Fields(res.Stdout)
	if len(f) < 1 {
		return false, false
	}
	return strings.Contains(f[0], "i"), true
}

// LegacyLogProves: the LAST "set immutable: <path>" line in installer.log (exact
// path match) is timestamped at exactly the file's ctime second. A matching line
// that is not the last one, a line one second off, or a line for another path is
// NOT proof (in doubt: refuse).
func LegacyLogProves(exec executor.Executor, path, ctime string) bool {
	ct, err := strconv.ParseInt(ctime, 10, 64)
	if err != nil {
		return false
	}
	data, err := exec.ReadFile(InstallerLogPath)
	if err != nil {
		return false
	}
	const marker = " [DEBUG] set immutable: "
	last := ""
	for _, line := range strings.Split(string(data), "\n") {
		i := strings.Index(line, marker)
		if i < 0 || strings.TrimRight(line[i+len(marker):], " \r") != path {
			continue
		}
		if f := strings.Fields(line); len(f) > 0 {
			last = f[0]
		}
	}
	return last != "" && last == time.Unix(ct, 0).UTC().Format("2006-01-02T15:04:05Z")
}

// ProvenLocked: the CURRENT +i on path was set by NFTBan (record or legacy proof).
func ProvenLocked(exec executor.Executor, path string, rec map[string]Entry) bool {
	ino, ct, ok := InoCtime(exec, path)
	if !ok {
		return false
	}
	if e, in := rec[path]; in {
		// The record knows this path: its entry is the only admissible evidence.
		// A different inode (file replaced) or ctime (attributes changed since)
		// means the current flag is not the one NFTBan set.
		return e.State == "locked" && e.Ino == ino && e.Ctime == ct
	}
	return LegacyLogProves(exec, path, ct)
}

// UnlockOwned removes +i from the given candidates ONLY where ProvenLocked holds.
// Returns (unlocked, notProven): notProven are flags left in place as
// administrator-owned.
func UnlockOwned(exec executor.Executor, candidates []string) (unlocked, notProven []string) {
	rec := ReadRecord(exec)
	for _, p := range candidates {
		if !exec.FileExists(p) {
			continue
		}
		has, measured := HasImmutable(exec, p)
		if !measured || !has {
			continue
		}
		if ProvenLocked(exec, p, rec) && exec.Run("chattr", "-i", p).ExitCode == 0 {
			unlocked = append(unlocked, p)
		} else {
			notProven = append(notProven, p)
		}
	}
	return unlocked, notProven
}

// ListFlagged returns every path under root carrying an immutable or append-only
// flag (lsattr -R -a -d), for reporting what an operation could not remove.
// measured=false when lsattr is unavailable or failed outright.
func ListFlagged(exec executor.Executor, root string) (paths []string, measured bool) {
	res := exec.Run("lsattr", "-R", "-a", "-d", root)
	if res.ExitCode != 0 && strings.TrimSpace(res.Stdout) == "" {
		return nil, false
	}
	var cur string
	for _, line := range strings.Split(res.Stdout, "\n") {
		line = strings.TrimRight(line, " \r")
		if line == "" {
			continue
		}
		if strings.HasSuffix(line, ":") && strings.HasPrefix(line, "/") {
			cur = strings.TrimSuffix(line, ":") // lsattr -R directory header
			continue
		}
		f := strings.SplitN(line, " ", 2)
		if len(f) != 2 {
			continue
		}
		p := f[1]
		if !strings.HasPrefix(p, "/") && cur != "" {
			p = cur + "/" + p
		}
		if strings.ContainsAny(f[0], "ia") && !strings.Contains(f[0], "/") {
			paths = append(paths, p)
		}
	}
	return paths, true
}
