// =============================================================================
// NFTBan v1.79.2 - distroconf reader (BUG-15)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: distroconf
// Purpose: Read /etc/nftban/distros/<distro>.conf and expose [paths] as the
//          single source of truth for parser source log file paths.
//
// meta:name="loginmon_distroconf"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="distroconf"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-08"
// meta:description="Central distro config reader for parser path resolution (BUG-15)"
//
// meta:inventory.files="distroconf.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/distros/*.conf,/etc/os-release"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
//
// Package distroconf reads /etc/nftban/distros/<distro>.conf and exposes the
// [paths] section as the authoritative source of log file paths for parser
// sources.
//
// This package implements BUG-15 from the v1.79.2 truth foundation plan:
//
//	the central truth surface (etc/nftban/distros/*.conf) is loaded by Go
//	parsers and consumed via Path() / IsNA() / Resolve() before any
//	authoritative-tool query or hard-coded fallback runs.
//
// INV-CONS-001: there is exactly one source of truth for distro paths.
// Every consumer (parser, validator, doctor, CLI) reads through this package.
//
// Resolution order for any source key:
//
//  1. distroconf.Path(key)         — authoritative for the distro
//  2. authoritative tool query     — e.g. exim -bP log_file_path (caller's job)
//  3. ordered fallback probe       — caller's job
//  4. SourceState = MISSING        — caller's job
//
// This package implements step 1 only. Steps 2-4 belong to the source/parser
// layer.
//
// The "n/a" literal:
//
//	n/a = "this key was considered, the answer is no, do not try fallback"
//	absent key = "no information; caller may fall through"
//
// These two states are intentionally distinct. See IsNA() and Path() docs.
package distroconf

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

// DefaultDir is the canonical location of distro config files.
const DefaultDir = "/etc/nftban/distros"

// DefaultOSReleasePath is the canonical location of the os-release file.
const DefaultOSReleasePath = "/etc/os-release"

// NALiteral is the exact string that means "explicitly not applicable".
// A path key set to this value is treated as DISABLED, not MISSING.
const NALiteral = "n/a"

// Loader holds a parsed distro config for a single host.
//
// Loader is safe for concurrent reads after Load() returns. It is NOT safe
// to modify after construction; treat it as immutable.
type Loader struct {
	mu       sync.RWMutex
	distroID string // e.g. "almalinux-9"
	confPath string // path to the .conf file actually loaded
	ini      iniFile
}

// Load detects the running distro and loads the matching distro conf.
//
// Distro detection order:
//  1. /etc/os-release ID + VERSION_ID
//  2. fallback: read existing files in dir, prefer the one matching ID
//
// Returns an error if no matching distro conf is found. Callers should treat
// load failure as a soft error (the parser falls through to authoritative
// tool queries) but log it as a doctor warning.
func Load(dir string) (*Loader, error) {
	id, err := detectDistro(DefaultOSReleasePath)
	if err != nil {
		return nil, fmt.Errorf("distro detection: %w", err)
	}
	return loadByID(dir, id)
}

// LoadFromFile loads a specific distro conf file. Used for tests and for the
// case where the operator overrides distro detection via NFTBAN_DISTRO_CONF.
func LoadFromFile(path string) (*Loader, error) {
	// #nosec G304 -- path is controlled by loadByID (DefaultDir + detected distro id),
	// or by tests passing fixture paths under testdata/. Not derived from external input.
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", path, err)
	}
	defer f.Close()

	parsed, err := parseINI(f)
	if err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}

	id := strings.TrimSuffix(filepath.Base(path), ".conf")
	return &Loader{
		distroID: id,
		confPath: path,
		ini:      parsed,
	}, nil
}

// loadByID resolves a distro id to a conf file.
//
// Distro confs are named by SERIES (major version) only:
//
//   almalinux-9.conf      covers AlmaLinux 9.0, 9.1, ..., 9.99
//   almalinux-10.conf     covers AlmaLinux 10.x
//   ubuntu-22.conf        covers Ubuntu 22.04, 22.10, ...
//   ubuntu-24.conf        covers Ubuntu 24.04, 24.10, ...
//   debian-12.conf        covers Debian 12.x
//   centos-stream-9.conf  covers CentOS Stream 9.x
//
// The id passed in is already stripped to its series form by detectDistro
// (e.g. "9.7" -> "9", "24.04" -> "24"), so loadByID does only:
//
//   1. exact:        <id>.conf
//   2. forward-fit:  highest <family>-*.conf overall (when host runs a series
//                    newer than anything we ship — e.g. AlmaLinux 11 before we
//                    ship almalinux-11.conf, falls back to almalinux-10.conf)
//
// No per-host stripping rules. No family-level wildcards. Patch versions are
// invisible to the loader because detectDistro discards them.
func loadByID(dir, id string) (*Loader, error) {
	exact := filepath.Join(dir, id+".conf")
	if _, err := os.Stat(exact); err == nil {
		return LoadFromFile(exact)
	}

	// Forward-fit: pick the highest <family>-*.conf available.
	// family = everything before the last "-N" suffix in id.
	family := familyOf(id)
	tried := []string{exact}
	if family != "" {
		if newest := findHighestSeriesConf(dir, family); newest != "" {
			tried = append(tried, newest)
			if _, err := os.Stat(newest); err == nil {
				return LoadFromFile(newest)
			}
		}
	}

	return nil, fmt.Errorf("no distro conf for %q in %s (tried %v)", id, dir, tried)
}

// familyOf returns the family portion of an id like "almalinux-9" -> "almalinux"
// or "centos-stream-9" -> "centos-stream". The split point is the last dash
// whose right side is a positive integer (the series number).
//
// Returns "" if id has no series suffix (e.g. "fedora" alone).
func familyOf(id string) string {
	for i := len(id) - 1; i > 0; i-- {
		if id[i] != '-' {
			continue
		}
		tail := id[i+1:]
		if isPositiveInt(tail) {
			return id[:i]
		}
	}
	return ""
}

// findHighestSeriesConf scans dir for <family>-N.conf where N is a positive
// integer and returns the path with the highest N. Returns "" if no matches.
//
// Used as the forward-fit fallback: when a host runs a series newer than
// anything we ship, give it the newest known series as the closest match.
func findHighestSeriesConf(dir, family string) string {
	if family == "" {
		return ""
	}
	matches, err := filepath.Glob(filepath.Join(dir, family+"-*.conf"))
	if err != nil || len(matches) == 0 {
		return ""
	}
	bestPath := ""
	bestN := -1
	prefix := family + "-"
	for _, m := range matches {
		base := filepath.Base(m)
		raw := strings.TrimSuffix(strings.TrimPrefix(base, prefix), ".conf")
		if !isPositiveInt(raw) {
			// Skip non-integer series (would catch e.g. malformed filenames).
			continue
		}
		n := atoi(raw)
		if n > bestN {
			bestN = n
			bestPath = m
		}
	}
	return bestPath
}

// seriesOf strips a version string to its leading integer component.
//
//   "9"     -> "9"
//   "9.7"   -> "9"
//   "24.04" -> "24"
//   "12.5"  -> "12"
//   ""      -> ""
//   "abc"   -> ""
//
// This is the canonical detect-time transform: the loader sees series-only
// ids, never patch versions.
func seriesOf(version string) string {
	if version == "" {
		return ""
	}
	end := 0
	for end < len(version) && version[end] >= '0' && version[end] <= '9' {
		end++
	}
	return version[:end]
}

// isPositiveInt reports whether s is a non-empty string of digits with at
// least one non-zero digit (to reject "" and "0").
func isPositiveInt(s string) bool {
	if s == "" {
		return false
	}
	hasNonZero := false
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return false
		}
		if c != '0' {
			hasNonZero = true
		}
	}
	return hasNonZero
}

// atoi parses a positive-integer string with no validation. Caller must
// have verified the string is digits-only via isPositiveInt.
func atoi(s string) int {
	n := 0
	for i := 0; i < len(s); i++ {
		n = n*10 + int(s[i]-'0')
	}
	return n
}

// DistroID returns the detected distro identifier (e.g. "almalinux-9").
func (l *Loader) DistroID() string {
	if l == nil {
		return ""
	}
	return l.distroID
}

// ConfPath returns the absolute path of the loaded conf file.
func (l *Loader) ConfPath() string {
	if l == nil {
		return ""
	}
	return l.confPath
}

// Family returns the distro family ("rhel" or "debian") from the [distro]
// section. Returns "" if not set.
func (l *Loader) Family() string {
	if l == nil {
		return ""
	}
	l.mu.RLock()
	defer l.mu.RUnlock()
	if l.ini == nil {
		return ""
	}
	if d, ok := l.ini["distro"]; ok {
		return d["family"]
	}
	return ""
}

// Path returns the value of [paths]<key>.
//
// Returns "" in two distinct cases:
//
//   - the key is absent entirely (caller should fall through to next layer)
//   - the key is set to "n/a" (caller should treat as DISABLED, not MISSING)
//
// Use IsNA() to distinguish. Most callers should use Resolve() instead, which
// returns a Resolution struct that distinguishes all four outcomes.
func (l *Loader) Path(key string) string {
	if l == nil {
		return ""
	}
	l.mu.RLock()
	defer l.mu.RUnlock()
	if l.ini == nil {
		return ""
	}
	paths, ok := l.ini["paths"]
	if !ok {
		return ""
	}
	v := paths[key]
	if v == NALiteral {
		return ""
	}
	return v
}

// IsNA reports whether [paths]<key> is explicitly set to "n/a".
//
// Returns false if the key is absent entirely. This is the critical
// distinction:
//
//	IsNA == true   → operator declared this source impossible on this distro
//	IsNA == false && Path() == ""   → key absent, fall through to next layer
//	IsNA == false && Path() != ""   → resolved by distroconf
func (l *Loader) IsNA(key string) bool {
	if l == nil {
		return false
	}
	l.mu.RLock()
	defer l.mu.RUnlock()
	if l.ini == nil {
		return false
	}
	if paths, ok := l.ini["paths"]; ok {
		return paths[key] == NALiteral
	}
	return false
}

// HasKey reports whether the key is present in [paths] at all (regardless of
// value, including n/a).
func (l *Loader) HasKey(key string) bool {
	if l == nil {
		return false
	}
	l.mu.RLock()
	defer l.mu.RUnlock()
	if l.ini == nil {
		return false
	}
	if paths, ok := l.ini["paths"]; ok {
		_, exists := paths[key]
		return exists
	}
	return false
}

// Resolution is the structured result of looking up a path key.
//
// It collapses the four possible outcomes into one type so callers can switch
// on Outcome cleanly without juggling Path() / IsNA() / HasKey().
type Resolution struct {
	Key      string     // the key that was looked up
	Outcome  ResolutionOutcome
	Path     string     // resolved absolute path; empty unless Outcome == Resolved
	DistroID string     // which distro the lookup was against
	Reason   string     // human-readable explanation
}

// ResolutionOutcome is the discriminator for Resolution.
type ResolutionOutcome int

const (
	// Resolved means the key was present with a real path value.
	// Caller should bind to Resolution.Path.
	Resolved ResolutionOutcome = iota

	// NotApplicable means the key was set to "n/a" — operator declared the
	// source impossible on this distro. Caller should mark the source as
	// DISABLED with no warning.
	NotApplicable

	// Absent means the key is not declared in this distro conf at all.
	// Caller should fall through to authoritative tool query, then hard-coded
	// fallback, then MISSING.
	Absent

	// LoaderUnavailable means distroconf itself failed to load (no conf file
	// for this host). Caller should fall through as if Absent, but log a
	// doctor warning.
	LoaderUnavailable
)

// String renders the outcome for logs and tests.
func (o ResolutionOutcome) String() string {
	switch o {
	case Resolved:
		return "resolved"
	case NotApplicable:
		return "n/a"
	case Absent:
		return "absent"
	case LoaderUnavailable:
		return "loader_unavailable"
	default:
		return "unknown"
	}
}

// Resolve performs a structured lookup and returns one of the four outcomes.
//
// This is the canonical entry point for parsers. It produces the exact data
// the parser needs to log its initialization line:
//
//	loginmon: <source>: <key>=<path> resolved_by=distroconf
//	loginmon: <source>: state=DISABLED reason=n/a in distro conf
//	loginmon: <source>: distroconf=absent (falling through to authoritative)
func (l *Loader) Resolve(key string) Resolution {
	r := Resolution{Key: key}
	if l == nil {
		r.Outcome = LoaderUnavailable
		r.Reason = "distroconf loader is nil (load failed at startup)"
		return r
	}
	r.DistroID = l.distroID

	if l.IsNA(key) {
		r.Outcome = NotApplicable
		r.Reason = fmt.Sprintf("[paths] %s = n/a in %s", key, filepath.Base(l.confPath))
		return r
	}
	if !l.HasKey(key) {
		r.Outcome = Absent
		r.Reason = fmt.Sprintf("[paths] %s not declared in %s", key, filepath.Base(l.confPath))
		return r
	}
	p := l.Path(key)
	if p == "" {
		// HasKey true and IsNA false but Path empty: corrupt entry, treat as Absent
		r.Outcome = Absent
		r.Reason = fmt.Sprintf("[paths] %s present but empty in %s", key, filepath.Base(l.confPath))
		return r
	}
	r.Outcome = Resolved
	r.Path = p
	r.Reason = fmt.Sprintf("distroconf:%s", filepath.Base(l.confPath))
	return r
}

// detectDistro reads /etc/os-release and returns the canonical distro id
// in SERIES form: "<normalized_id>-<series>".
//
// The series is the leading integer of VERSION_ID:
//
//   AlmaLinux 9.7   -> "almalinux-9"
//   AlmaLinux 10    -> "almalinux-10"
//   Ubuntu 24.04    -> "ubuntu-24"
//   Ubuntu 24.10    -> "ubuntu-24"     (same series)
//   Debian 12.5     -> "debian-12"
//   Rocky 9.4       -> "rocky-9"
//   Fedora 43       -> "fedora-43"
//   CentOS Stream 9 -> "centos-9"      (see note below)
//
// Patch versions are dropped at detection time. The loader never sees them.
// This means a single conf file (e.g. almalinux-9.conf) covers the entire
// series, and adding support for a new patch release is a no-op.
//
// Note on CentOS Stream: /etc/os-release on CentOS Stream reports ID="centos"
// (not "centos-stream"), so detectDistro returns "centos-9" or "centos-10".
// The centos-stream-*.conf variants in etc/nftban/distros/ are reachable only
// when an operator explicitly overrides distro detection. This is acceptable
// for v1.79.2 because plain CentOS and CentOS Stream share the same path
// conventions for the keys we care about (auth_log, maillog, exim_log, etc.).
func detectDistro(osReleasePath string) (string, error) {
	// #nosec G304 -- only caller passes the package constant DefaultOSReleasePath
	// (/etc/os-release). Path parameter exists for test injection only.
	f, err := os.Open(osReleasePath)
	if err != nil {
		return "", fmt.Errorf("open %s: %w", osReleasePath, err)
	}
	defer f.Close()

	parsed, err := parseOSRelease(f)
	if err != nil {
		return "", err
	}
	id := parsed["ID"]
	if id == "" {
		return "", fmt.Errorf("os-release: ID field missing")
	}
	id = normalizeDistroID(id)

	series := seriesOf(parsed["VERSION_ID"])
	if series == "" {
		return id, nil
	}
	return id + "-" + series, nil
}

// normalizeDistroID applies the same normalization rules as
// nftban_distro_config.sh so the conf filenames match.
func normalizeDistroID(id string) string {
	switch id {
	case "centos-stream":
		return "centos-stream"
	case "rhel", "redhat":
		return "rhel"
	case "alma", "almalinux":
		return "almalinux"
	default:
		return id
	}
}

// parseOSRelease reads a freedesktop os-release file. It supports the subset
// of the format relevant to distro detection: KEY=value, KEY="value with spaces".
// Comments and blank lines are ignored.
func parseOSRelease(r interface{ Read([]byte) (int, error) }) (map[string]string, error) {
	out := make(map[string]string)
	buf := make([]byte, 0, 4096)
	tmp := make([]byte, 4096)
	for {
		n, err := r.Read(tmp)
		if n > 0 {
			buf = append(buf, tmp[:n]...)
		}
		if err != nil {
			break
		}
	}
	for _, line := range strings.Split(string(buf), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || line[0] == '#' {
			continue
		}
		eq := strings.IndexByte(line, '=')
		if eq < 0 {
			continue
		}
		k := strings.TrimSpace(line[:eq])
		v := strings.TrimSpace(line[eq+1:])
		v = strings.Trim(v, `"'`)
		out[k] = v
	}
	return out, nil
}
