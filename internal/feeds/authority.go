// =============================================================================
// NFTBan - Feed authority: which feed files are enforced (v1.236)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="feeds-authority"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-23"
// meta:description="ONE decision of which feed files are enforced, used by the daemon full sync, the ruleset content renderer and reporting (design V1236_STAGE2_DESIGN_DRAFT.md §7). Until v1.236 the daemon enforced every .txt in <data>/feeds whatever NFTBAN_FEEDS_ENABLED said, while reload/rebuild followed the master switch: two authorities. Configuration is now the authority (master switch + FEED_<NAME>_ENABLED), except under the defined migration condition, where the v1.235 enforcement is kept and reported (CONFLICT_KEPT) until the operator resolves it. The state survives reboot in <data>/state/feed_authority."
// meta:inventory.files="/var/lib/nftban/state/feed_authority, /var/lib/nftban/feeds/*.txt, /etc/nftban/conf.d/feeds.conf, /etc/nftban/conf.d/feeds.conf.local, /etc/nftban/nftban.conf.local"
// meta:inventory.privileges="none (the state write needs the data dir)"
// =============================================================================

package feeds

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/safety"
)

// Feed-authority states (design §7).
const (
	StateConsistent       = "CONSISTENT"
	StateConflictKept     = "CONFLICT_KEPT"
	StateResolvedEnabled  = "RESOLVED_ENABLED"
	StateResolvedDisabled = "RESOLVED_DISABLED"
)

// Structured reasons, one key and one text each, for status, health and the sync result.
const (
	ReasonConfigConflict  = "feeds_config_conflict"
	ReasonFileNotEnabled  = "feeds_file_not_enabled"
	textConfigConflict    = "feeds loaded but the master switch NFTBAN_FEEDS_ENABLED is off — kept as enforced before the upgrade; choose: nftban feeds enable | nftban feeds disable"
	textFileNotEnabledFmt = "feed file(s) present but the feed is not enabled, not enforced: %s"
)

// StatePath is the durable state file under the data directory.
func StatePath(dataDir string) string { return filepath.Join(dataDir, "state", "feed_authority") }

// Decision is the effective feed authority at one moment.
type Decision struct {
	Master      bool     // NFTBAN_FEEDS_ENABLED
	State       string   // effective state
	Recorded    string   // state read from the file ("" = never evaluated on this host)
	Enforced    []string // feed names (file stems) whose files are loaded
	NotEnabled  []string // files with entries that are not enforced (reported)
	Reasons     []string // structured reason keys
	Texts       []string // one text per reason, same order
	NeedsRecord bool     // the state file must be written (first evaluation, or a change)
}

// EnabledStatus reads FEED_<NAME>_ENABLED (upper-case name) with the config order
// feeds.conf -> feeds.conf.local -> nftban.conf.local (last wins).
func EnabledStatus(configDir string) map[string]bool {
	enabled := make(map[string]bool)
	base := filepath.Join(configDir, "conf.d", "feeds.conf")
	for _, cf := range []string{base, base + ".local", filepath.Join(configDir, "nftban.conf.local")} {
		content, err := os.ReadFile(cf) // #nosec G304 -- fixed config paths
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(content), "\n") {
			line = strings.TrimSpace(line)
			if !strings.HasPrefix(line, "FEED_") || !strings.Contains(line, "_ENABLED=") {
				continue
			}
			parts := strings.SplitN(line, "=", 2)
			if len(parts) != 2 || !strings.HasSuffix(parts[0], "_ENABLED") {
				continue
			}
			name := strings.TrimSuffix(strings.TrimPrefix(parts[0], "FEED_"), "_ENABLED")
			enabled[name] = configValue(parts[1]) == "true"
		}
	}
	return enabled
}

// configValue strips quotes and a trailing comment: "true" # x -> true.
func configValue(raw string) string {
	v := strings.TrimSpace(raw)
	if strings.HasPrefix(v, `"`) {
		if end := strings.Index(v[1:], `"`); end >= 0 {
			return v[1 : end+1]
		}
	}
	if strings.HasPrefix(v, "'") {
		if end := strings.Index(v[1:], "'"); end >= 0 {
			return v[1 : end+1]
		}
	}
	if i := strings.Index(v, "#"); i >= 0 {
		v = v[:i]
	}
	return strings.TrimSpace(v)
}

// FilesWithEntries lists the feed names (file stems) in feedsDir whose file holds at least one
// valid entry. A missing directory is an empty list; any other read error is returned.
func FilesWithEntries(feedsDir string) ([]string, error) {
	names, err := ListAvailableFeeds(feedsDir)
	if err != nil {
		return nil, err
	}
	var out []string
	for _, n := range names {
		has, err := fileHasEntry(filepath.Join(feedsDir, n+".txt"))
		if err != nil {
			return nil, err
		}
		if has {
			out = append(out, n)
		}
	}
	sort.Strings(out)
	return out, nil
}

func fileHasEntry(path string) (bool, error) {
	f, err := os.Open(path) // #nosec G304 -- file under the feeds directory
	if err != nil {
		return false, err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		if ParseFeedLineSilent(sc.Text()) != nil {
			return true, nil
		}
	}
	return false, sc.Err()
}

// ReadState returns the recorded state ("" when the file does not exist). An unreadable or
// malformed file is an error: the caller must not guess (it refuses or reports UNKNOWN).
func ReadState(dataDir string) (string, error) {
	data, err := os.ReadFile(StatePath(dataDir)) // #nosec G304 -- fixed path
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", fmt.Errorf("read %s: %w", StatePath(dataDir), err)
	}
	for _, f := range strings.Fields(string(data)) {
		if v, ok := strings.CutPrefix(f, "STATE="); ok {
			switch v {
			case StateConsistent, StateConflictKept, StateResolvedEnabled, StateResolvedDisabled:
				return v, nil
			}
			return "", fmt.Errorf("%s: unknown state %q", StatePath(dataDir), v)
		}
	}
	return "", fmt.Errorf("%s: no STATE= field", StatePath(dataDir))
}

// WriteState records the state durably (safety.SafeWriteFile: temp + fsync + rename + dir
// fsync), so the decision survives a crash or a power loss right after it is taken.
func WriteState(dataDir, state, reason string, now time.Time) error {
	path := StatePath(dataDir)
	if err := os.MkdirAll(filepath.Dir(path), 0750); err != nil { // #nosec G301
		return err
	}
	line := fmt.Sprintf("STATE=%s SINCE=%s", state, now.UTC().Format(time.RFC3339))
	if reason != "" {
		line += " REASON=" + reason
	}
	return safety.SafeWriteFile(path, []byte(line+"\n"), 0640)
}

// RecordFreshInstall records CONSISTENT on a fresh install when no state exists yet, so a
// fresh host can never meet the migration condition — not even with feed files left behind
// by an earlier removal. Called by the installer for --mode=install only; an upgrade leaves
// the state absent so the first evaluation applies the migration rule. Returns whether it wrote.
func RecordFreshInstall(dataDir string, now time.Time) (bool, error) {
	recorded, err := ReadState(dataDir)
	if err != nil {
		return false, err
	}
	if recorded != "" {
		return false, nil
	}
	return true, WriteState(dataDir, StateConsistent, "fresh_install", now)
}

// Decide is the feed authority (pure). files = feed names with entries; perFeed keyed by the
// upper-case name; recorded = the state on disk ("" = none).
//
//   - master on: enforce the per-feed-enabled feeds that have a file (CONSISTENT, or the recorded
//     RESOLVED_ENABLED).
//   - master off, recorded CONFLICT_KEPT: keep every file with entries (until resolved).
//   - master off, nothing recorded (first evaluation by v1.236+ on this host) and >=1 per-feed
//     switch on and >=1 file with entries: the migration condition — CONFLICT_KEPT, keep every file
//     with entries (exactly the v1.235 enforcement). A fresh install cannot meet it: with the master
//     switch off the downloader writes no feed file, so its first evaluation records CONSISTENT.
//   - master off otherwise: enforce nothing (an intentional disable is honoured).
//
// Files with entries that are not enforced are reported, never dropped silently.
func Decide(master bool, perFeed map[string]bool, files []string, recorded string) Decision {
	d := Decision{Master: master, Recorded: recorded}
	anyOn := false
	for _, on := range perFeed {
		if on {
			anyOn = true
			break
		}
	}
	switch {
	case master:
		d.State = StateConsistent
		if recorded == StateResolvedEnabled {
			d.State = StateResolvedEnabled
		}
		for _, f := range files {
			if perFeed[strings.ToUpper(f)] {
				d.Enforced = append(d.Enforced, f)
			} else {
				d.NotEnabled = append(d.NotEnabled, f)
			}
		}
	case recorded == StateConflictKept, recorded == "" && anyOn && len(files) > 0:
		d.State = StateConflictKept
		d.Enforced = append(d.Enforced, files...)
	default:
		d.State = StateConsistent
		if recorded == StateResolvedDisabled {
			d.State = StateResolvedDisabled
		}
		d.NotEnabled = append(d.NotEnabled, files...)
	}
	if d.State == StateConflictKept {
		d.Reasons = append(d.Reasons, ReasonConfigConflict)
		d.Texts = append(d.Texts, textConfigConflict)
	}
	if len(d.NotEnabled) > 0 && master {
		d.Reasons = append(d.Reasons, ReasonFileNotEnabled)
		d.Texts = append(d.Texts, fmt.Sprintf(textFileNotEnabledFmt, strings.Join(d.NotEnabled, ", ")))
	}
	d.NeedsRecord = recorded == "" || recorded != d.State && d.State == StateConflictKept
	return d
}

// Evaluate gathers the inputs from disk and decides. master = NFTBAN_FEEDS_ENABLED as loaded
// by nftbanconf (base + nftban.conf.local).
func Evaluate(configDir, dataDir string, master bool) (Decision, error) {
	recorded, err := ReadState(dataDir)
	if err != nil {
		return Decision{}, err
	}
	files, err := FilesWithEntries(filepath.Join(dataDir, "feeds"))
	if err != nil {
		return Decision{}, fmt.Errorf("feed files: %w", err)
	}
	return Decide(master, EnabledStatus(configDir), files, recorded), nil
}

// LoadEnforcedFeeds loads only the named feed files (Decision.Enforced) into the four sets
// LoadAllFeeds returns. A listed file that cannot be read is an error.
func LoadEnforcedFeeds(feedsDir string, names []string) (map[string]bool, map[string]bool, map[string]bool, map[string]bool, error) {
	ipv4Set := make(map[string]bool, 10000)
	ipv6Set := make(map[string]bool, 1000)
	ipv4CIDRSet := make(map[string]bool, 50000)
	ipv6CIDRSet := make(map[string]bool, 1000)
	for _, n := range names {
		if _, _, _, _, err := loadFeedFile(filepath.Join(feedsDir, n+".txt"), ipv4Set, ipv6Set, ipv4CIDRSet, ipv6CIDRSet); err != nil {
			return nil, nil, nil, nil, fmt.Errorf("feed %s: %w", n, err)
		}
	}
	return ipv4Set, ipv6Set, ipv4CIDRSet, ipv6CIDRSet, nil
}
