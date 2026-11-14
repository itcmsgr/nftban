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

// RemoveIPFromSourceIf removes ip from the ONE reason file of source, holding that file's sibling lock
// (the boundary PersistBan uses) for the whole re-check + rewrite. recheck runs under the lock,
// immediately before removal; if it returns false, nothing is changed and its reason is returned.
// Every other reason file of the IP is left untouched (per-reason removal, design §0.4).
// The rewrite is the existing atomic temp+rename; an interruption leaves the file either unchanged
// or without the line, never partial.
func RemoveIPFromSourceIf(configDir, ip, source string, recheck func() (bool, string)) (removed bool, skip string, err error) {
	name, ok := FileForSource(source)
	if !ok {
		return false, "", fmt.Errorf("unknown source %q: no reason file", source)
	}
	path := filepath.Join(configDir, "blacklist.d", name)
	unlock, err := lockSibling(path)
	if err != nil {
		return false, "", err
	}
	defer unlock()
	if recheck != nil {
		if allowed, why := recheck(); !allowed {
			return false, why, nil
		}
	}
	removed, err = removeIPFromFileLocked(path, ip)
	return removed, "", err
}
