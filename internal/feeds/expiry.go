// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package feeds

// v1.238 D5-1 (owner GO 2026-11-20): opt-in per-feed expiry, part of the ONE feed authority.
//
// FEED_<NAME>_MAX_AGE (Go duration, e.g. "72h"; empty or "0" = no expiry, today's behaviour) is
// read with the same config order as FEED_<NAME>_ENABLED. A feed the authority would enforce whose
// snapshot is older than its MAX_AGE moves from Enforced to Expired:
//   - age = now - mtime of <feeds>/<feed>.txt. The mtime is set only when the protected writer
//     replaces the snapshot after a successful, validated download (temp file written, renamed).
//     A failed request writes nothing; a permission repair (chown/chmod) changes ctime, not mtime;
//     an API test (`nftban feeds abuseipdb test`) never writes the snapshot. None of them resets
//     the age.
//   - MAX_AGE is the age limit for SELECTION: past it the feed is excluded by the authority. Its
//     contribution leaves the kernel sets at the next successful full sync (feeds timer, `feeds update`, enable/
//     disable, rebuild/reload, ...), not at exactly MAX_AGE.
//   - the snapshot stays on disk (status shows it as expired); only the feed's own contribution
//     stops: the full sync builds the feed sets from Enforced only, so addresses that another
//     enforced feed lists, manual bans and every other set are unaffected.
//   - an invalid MAX_AGE is reported and not applied (the feed keeps today's behaviour).
// Every consumer (daemon full sync, ruleset renderer, `feeds effective`/status, manual load) gets
// the same answer through Evaluate.

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Expiry reasons.
const (
	ReasonFeedExpired       = "feed_expired"
	ReasonFeedMaxAgeInvalid = "feed_max_age_invalid"
)

// feedProperty reads FEED_<NAME>_<suffix> (upper-case name) with the config order
// feeds.conf -> feeds.conf.local -> nftban.conf.local (last wins), like EnabledStatus.
func feedProperty(configDir, suffix string) map[string]string {
	out := make(map[string]string)
	root, err := os.OpenRoot(configDir)
	if err != nil {
		return out
	}
	defer func() { _ = root.Close() }()
	base := filepath.Join("conf.d", "feeds.conf")
	for _, cf := range []string{base, base + ".local", "nftban.conf.local"} {
		content, err := root.ReadFile(cf)
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(content), "\n") {
			line = strings.TrimSpace(line)
			if !strings.HasPrefix(line, "FEED_") {
				continue
			}
			parts := strings.SplitN(line, "=", 2)
			if len(parts) != 2 || !strings.HasSuffix(parts[0], "_"+suffix) {
				continue
			}
			name := strings.TrimSuffix(strings.TrimPrefix(parts[0], "FEED_"), "_"+suffix)
			if name == "" {
				continue
			}
			out[name] = configValue(parts[1])
		}
	}
	return out
}

// MaxAgeStatus returns the configured per-feed maximum ages (only feeds with a valid, positive
// MAX_AGE) and the names whose MAX_AGE is set but invalid.
func MaxAgeStatus(configDir string) (map[string]time.Duration, []string) {
	ages := make(map[string]time.Duration)
	var invalid []string
	for name, raw := range feedProperty(configDir, "MAX_AGE") {
		if raw == "" || raw == "0" {
			continue
		}
		d, err := time.ParseDuration(raw)
		if err != nil || d <= 0 {
			invalid = append(invalid, name)
			continue
		}
		ages[name] = d
	}
	return ages, invalid
}

// applyExpiry moves enforced feeds whose snapshot is older than their MAX_AGE to Expired. A
// snapshot that cannot be stat'ed is left as the authority decided (the loader reports it).
func applyExpiry(d *Decision, feedsDir string, maxAge map[string]time.Duration, invalid []string, now time.Time) {
	for _, n := range invalid {
		d.Reasons = append(d.Reasons, ReasonFeedMaxAgeInvalid)
		d.Texts = append(d.Texts, fmt.Sprintf("FEED_%s_MAX_AGE is not a valid duration (e.g. 72h); expiry not applied to %s", n, n))
	}
	if len(maxAge) == 0 {
		return
	}
	kept := d.Enforced[:0:0]
	for _, f := range d.Enforced {
		limit, ok := maxAge[strings.ToUpper(f)]
		if !ok {
			kept = append(kept, f)
			continue
		}
		fi, err := os.Stat(filepath.Join(feedsDir, f+".txt"))
		if err != nil {
			kept = append(kept, f)
			continue
		}
		age := now.Sub(fi.ModTime())
		if age <= limit {
			kept = append(kept, f)
			continue
		}
		d.Expired = append(d.Expired, f)
		d.Reasons = append(d.Reasons, ReasonFeedExpired)
		d.Texts = append(d.Texts, fmt.Sprintf("feed %s expired: last successful refresh %s ago exceeds MAX_AGE %s; excluded by the feed authority until a refresh succeeds; its contribution leaves the kernel sets at the next successful full sync (snapshot kept on disk)",
			f, age.Truncate(time.Minute), limit))
	}
	d.Enforced = kept
}
