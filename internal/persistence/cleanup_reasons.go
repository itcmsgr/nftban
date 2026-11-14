// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="persistence_cleanup_reasons"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.237 permanent-ban cleanup repair (design V1237_CLEANUP_REPAIR_DESIGN_2026_11_14 §0): read the durable reason files of blacklist.d (one source per file via fileMapping), and remove ONE IP from ONE reason file under that file's sibling lock, only if a caller-supplied re-check still allows it. Reuses the existing persistence lock and atomic rewrite; no second mechanism."
// meta:inventory.files="/etc/nftban/blacklist.d"
// meta:inventory.privileges="root"

package persistence

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// FileForSource returns the blacklist.d file name of a known source, and whether the source is known.
// Unlike PersistBan, an unknown source is NOT mapped to the manual file: cleanup never guesses provenance.
func FileForSource(source string) (string, bool) {
	m, ok := fileMapping[source]
	if !ok {
		return "", false
	}
	return m.filename, true
}

// KnownSources returns the sources of fileMapping, sorted.
func KnownSources() []string {
	out := make([]string, 0, len(fileMapping))
	for s := range fileMapping {
		out = append(out, s)
	}
	sort.Strings(out)
	return out
}

// ReasonsForAll reads every known reason file once and returns, per IP (first field of a
// non-comment line), the sorted list of sources whose file holds it. A missing file holds nothing.
// File membership proves persistence, not original provenance (design §0.1); callers decide what
// an ambiguous combination means.
func ReasonsForAll(configDir string) (map[string][]string, error) {
	dir := filepath.Join(configDir, "blacklist.d")
	out := map[string][]string{}
	for _, src := range KnownSources() {
		name, _ := FileForSource(src)
		ips, err := readIPs(filepath.Join(dir, name))
		if err != nil {
			return nil, fmt.Errorf("read %s: %w", name, err)
		}
		for _, ip := range ips {
			out[ip] = append(out[ip], src)
		}
	}
	for ip := range out {
		sort.Strings(out[ip])
	}
	return out, nil
}

func readIPs(path string) ([]string, error) {
	f, err := os.Open(filepath.Clean(path))
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	defer f.Close()
	var ips []string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		t := strings.TrimSpace(sc.Text())
		if t == "" || strings.HasPrefix(t, "#") {
			continue
		}
		if fields := strings.Fields(t); len(fields) > 0 {
			ips = append(ips, fields[0])
		}
	}
	return ips, sc.Err()
}

// LockAllReasons takes the sibling lock of EVERY known reason file, in KnownSources order (a fixed
// order, so two holders cannot deadlock). This is the shared write boundary of the cleanup repair
// (owner condition 2026-11-14): eligibility, protection and the remaining reasons are re-validated, and
// the removal is done, while no reason file can change. PersistBan on any reason file waits until
// unlock. While holding the set, the caller must use only the *Locked functions (a second flock on
// another descriptor of the same lockfile would block on itself).
func LockAllReasons(configDir string) (func(), error) {
	dir := filepath.Join(configDir, "blacklist.d")
	if err := os.MkdirAll(dir, 0750); err != nil {
		return nil, fmt.Errorf("failed to create blacklist.d: %w", err)
	}
	var unlocks []func()
	release := func() {
		for i := len(unlocks) - 1; i >= 0; i-- {
			unlocks[i]()
		}
	}
	for _, src := range KnownSources() {
		name, _ := FileForSource(src)
		u, err := lockSibling(filepath.Join(dir, name))
		if err != nil {
			release()
			return nil, err
		}
		unlocks = append(unlocks, u)
	}
	return release, nil
}

// WithAllReasonLocks runs fn while holding LockAllReasons: the shared write boundary for tracking
// updates (TrackPermanentBan / protect / unprotect / cleanup), so a concurrent protect or new reason
// is serialized with a cleanup re-check and removal. fn must not call PersistBan / UnpersistBan.
func WithAllReasonLocks(configDir string, fn func() error) error {
	unlock, err := LockAllReasons(configDir)
	if err != nil {
		return err
	}
	defer unlock()
	return fn()
}

// ReasonsForIP returns the sorted sources whose reason file holds ip.
func ReasonsForIP(configDir, ip string) ([]string, error) {
	dir := filepath.Join(configDir, "blacklist.d")
	var out []string
	for _, src := range KnownSources() {
		name, _ := FileForSource(src)
		ips, err := readIPs(filepath.Join(dir, name))
		if err != nil {
			return nil, fmt.Errorf("read %s: %w", name, err)
		}
		for _, x := range ips {
			if x == ip {
				out = append(out, src)
				break
			}
		}
	}
	return out, nil
}

// RemoveIPFromSourceLocked removes ip from the ONE reason file of source. The caller holds
// LockAllReasons. Every other reason file is untouched (per-reason removal, design §0.4). The rewrite
// is the existing atomic temp+rename: an interruption leaves the file unchanged or without the line.
// An unknown source is an error, never mapped to the manual file.
func RemoveIPFromSourceLocked(configDir, ip, source string) (bool, error) {
	name, ok := FileForSource(source)
	if !ok {
		return false, fmt.Errorf("unknown source %q: no reason file", source)
	}
	return removeIPFromFileLocked(filepath.Join(configDir, "blacklist.d", name), ip)
}
