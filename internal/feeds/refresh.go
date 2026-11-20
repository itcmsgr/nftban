// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package feeds

// v1.238 part B (owner 2026-11-20): per-feed refresh visibility. Three facts are kept apart:
//
//   - snapshot freshness: the mtime of <feeds>/<feed>.txt, set only when a validated download
//     replaces the snapshot. Expiry (expiry.go) and the stale state are computed from it.
//   - last download outcome: <feeds>/<feed>.status, written only by the downloader
//     (`nftban-core feeds update`) after a real request. A failed request records the failure
//     and never advances the success time; an API test (`feeds abuseipdb test`) writes nothing.
//   - last full-sync outcome: <feeds>/full-sync.status, written only by the daemon at the end of
//     every full sync, whoever asked for it. A failed sync stays visible even when the download
//     before it succeeded.
//
// The records are root:nftban 0640 like the snapshots (fhs-spec /var/lib/nftban/feeds), replaced
// atomically inside the feed directory. They report; they never decide enforcement: the feed
// authority (Evaluate) does. The API key never appears in them.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/user"
	"strconv"
	"strings"
	"time"
)

// SyncRecordName is the daemon's full-sync record in the feed directory. The hyphen keeps it out
// of the feed namespace (feed names are letters, digits and underscores).
const SyncRecordName = "full-sync.status"

// RefreshRecord is the downloader's record for one feed.
type RefreshRecord struct {
	Feed                string         `json:"feed"`
	LastSuccessAt       time.Time      `json:"last_success_at,omitempty"`
	LastSuccessEntries  int            `json:"last_success_entries,omitempty"`
	ProviderGeneratedAt string         `json:"provider_generated_at,omitempty"` // provider's own time, as sent
	LastAttemptAt       time.Time      `json:"last_attempt_at,omitempty"`
	LastAttemptOK       bool           `json:"last_attempt_ok"`
	LastAttemptReason   string         `json:"last_attempt_reason,omitempty"`
	ConsecutiveFailures int            `json:"consecutive_failures,omitempty"`
	FailingSince        time.Time      `json:"failing_since,omitempty"`
	NotBefore           time.Time      `json:"not_before,omitempty"` // provider back-off (429)
	Provider            *ProviderStats `json:"provider,omitempty"`   // provider feeds only
}

// ProviderStats is what a provider feed's last successful download reported (requested values
// kept apart from the effective result), plus the latest quota the provider stated. Quota fields
// are meaningful only when QuotaKnown (unknown is never shown as 0).
type ProviderStats struct {
	RequestedConfidence int       `json:"requested_confidence_minimum,omitempty"`
	RequestedLimit      int       `json:"requested_limit,omitempty"`
	Received            int       `json:"received"`
	Accepted            int       `json:"accepted"`
	Rejected            int       `json:"rejected"`
	MinScore            int       `json:"min_score"` // -1: no entry carried a score
	MaxScore            int       `json:"max_score"`
	QuotaKnown          bool      `json:"quota_known"`
	QuotaLimit          int       `json:"quota_limit,omitempty"`
	QuotaRemaining      int       `json:"quota_remaining,omitempty"`
	QuotaResetAt        time.Time `json:"quota_reset_at,omitempty"`
	QuotaSeenAt         time.Time `json:"quota_seen_at,omitempty"`
}

// SetQuota records a provider quota statement (only when the provider sent one).
func (p *ProviderStats) SetQuota(rl RateLimitInfo, now time.Time) {
	if !rl.Known {
		return
	}
	p.QuotaKnown, p.QuotaLimit, p.QuotaRemaining, p.QuotaResetAt, p.QuotaSeenAt = true, rl.Limit, rl.Remaining, rl.ResetAt, now.UTC()
}

// SyncRecord is the daemon's record of the last full sync.
type SyncRecord struct {
	At           time.Time `json:"at"`
	OK           bool      `json:"ok"`               // the feed sets were applied in full
	Effect       string    `json:"effect,omitempty"` // applied / partial / refused / failed
	Reason       string    `json:"reason,omitempty"`
	Enforced     []string  `json:"enforced,omitempty"`
	Expired      []string  `json:"expired,omitempty"`
	LastOKAt     time.Time `json:"last_ok_at,omitempty"`
	LastOKFeeds  []string  `json:"last_ok_enforced,omitempty"` // enforced feeds of the last OK sync
	FeedsSkipped bool      `json:"feeds_skipped,omitempty"`
}

// FileOwner is the owner of files in the feed directory: root:nftban (ok=false: no nftban group,
// the file stays with the writer's owner). A variable so tests can run unprivileged.
var FileOwner = func() (uid, gid int, ok bool) {
	grp, err := user.LookupGroup("nftban")
	if err != nil {
		return 0, 0, false
	}
	g, err := strconv.Atoi(grp.Gid)
	if err != nil {
		return 0, 0, false
	}
	return 0, g, true
}

// WriteFeedDirFile replaces dir/name with data as owner 0640, correct at creation. Everything
// happens inside dir through os.Root (no path leaves it, no link is followed out of it). The temp
// file is created exclusively with mode 0600 (a stale temp entry is unlinked first: the link
// itself, never a target), owned through its descriptor, only then widened to 0640, synced, and
// renamed over the target (rename replaces a link at the target, never its target).
func WriteFeedDirFile(dir, name string, data []byte, owner func() (int, int, bool)) error {
	if name == "" || strings.ContainsAny(name, `/\`) {
		return fmt.Errorf("invalid file name %q", name)
	}
	tmpName := name + ".tmp"
	root, err := os.OpenRoot(dir)
	if err != nil {
		return fmt.Errorf("failed to open feeds directory: %w", err)
	}
	defer func() { _ = root.Close() }()
	if err := root.Remove(tmpName); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("failed to clear stale temp file: %w", err)
	}
	out, err := root.OpenFile(tmpName, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return fmt.Errorf("failed to create output file: %w", err)
	}
	discard := func() { _ = root.Remove(tmpName) }
	fail := func(e error) error {
		_ = out.Close()
		discard()
		return e
	}
	if owner != nil {
		if uid, gid, ok := owner(); ok {
			if err := out.Chown(uid, gid); err != nil {
				return fail(fmt.Errorf("chown feed file: %w", err))
			}
		}
	}
	if err := out.Chmod(0o640); err != nil {
		return fail(fmt.Errorf("chmod feed file: %w", err))
	}
	if _, err := out.Write(data); err != nil {
		return fail(fmt.Errorf("write failed: %w", err))
	}
	if err := out.Sync(); err != nil {
		return fail(fmt.Errorf("sync failed: %w", err))
	}
	if err := out.Close(); err != nil {
		discard()
		return fmt.Errorf("close failed: %w", err)
	}
	if err := root.Rename(tmpName, name); err != nil {
		discard()
		return fmt.Errorf("failed to save feed file: %w", err)
	}
	return nil
}

func recordName(feed string) string { return strings.ToLower(feed) + ".status" }

func readJSON(feedsDir, name string, v any) error {
	root, err := os.OpenRoot(feedsDir)
	if err != nil {
		return err
	}
	defer func() { _ = root.Close() }()
	data, err := root.ReadFile(name)
	if err != nil {
		return err
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	return dec.Decode(v)
}

func writeJSON(feedsDir, name string, v any) error {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return WriteFeedDirFile(feedsDir, name, append(data, '\n'), FileOwner)
}

// ReadRefresh returns the feed's record; ok=false when none exists yet (never refreshed by v1.238+).
// An unreadable or corrupt record is an error, never an empty record.
func ReadRefresh(feedsDir, feed string) (RefreshRecord, bool, error) {
	var r RefreshRecord
	err := readJSON(feedsDir, recordName(feed), &r)
	if os.IsNotExist(err) {
		return RefreshRecord{Feed: strings.ToLower(feed)}, false, nil
	}
	if err != nil {
		return RefreshRecord{Feed: strings.ToLower(feed)}, false, fmt.Errorf("refresh record %s: %w", recordName(feed), err)
	}
	return r, true, nil
}

// ReadSync returns the daemon's last full-sync record; ok=false when none exists yet.
func ReadSync(feedsDir string) (SyncRecord, bool, error) {
	var s SyncRecord
	err := readJSON(feedsDir, SyncRecordName, &s)
	if os.IsNotExist(err) {
		return SyncRecord{}, false, nil
	}
	if err != nil {
		return SyncRecord{}, false, fmt.Errorf("sync record: %w", err)
	}
	return s, true, nil
}

// Transitions reported (and logged) once, when they happen.
const (
	TransitionNone     = ""
	TransitionFailure  = "failure"  // first failed attempt after a success (or the first ever)
	TransitionRecovery = "recovery" // first success after one or more failures
	TransitionExpired  = "expired"  // the authority stopped enforcing the feed (MAX_AGE)
)

// RecordSuccess records a validated snapshot replacement (call it after the rename). It returns
// the transition (recovery or none).
func RecordSuccess(feedsDir, feed string, entries int, providerGeneratedAt string, prov *ProviderStats, now time.Time) (string, error) {
	prev, _, err := ReadRefresh(feedsDir, feed)
	if err != nil {
		prev = RefreshRecord{} // a corrupt record is replaced by a correct one
	}
	tr := TransitionNone
	if prev.ConsecutiveFailures > 0 {
		tr = TransitionRecovery
	}
	r := RefreshRecord{
		Feed:                strings.ToLower(feed),
		LastSuccessAt:       now.UTC(),
		LastSuccessEntries:  entries,
		ProviderGeneratedAt: providerGeneratedAt,
		LastAttemptAt:       now.UTC(),
		LastAttemptOK:       true,
		Provider:            prov,
	}
	return tr, writeJSON(feedsDir, recordName(feed), r)
}

// RecordFailure records a failed request. The success time, entries and provider time are kept
// from the previous record: a failure never makes an old snapshot look fresh. notBefore is the
// provider's back-off (zero when none). reason must be key-free (provider errors are sanitized).
func RecordFailure(feedsDir, feed, reason string, notBefore time.Time, rl RateLimitInfo, now time.Time) (string, error) {
	prev, _, err := ReadRefresh(feedsDir, feed)
	if err != nil {
		prev = RefreshRecord{}
	}
	tr := TransitionNone
	if prev.ConsecutiveFailures == 0 {
		tr = TransitionFailure
	}
	r := prev
	r.Feed = strings.ToLower(feed)
	r.LastAttemptAt = now.UTC()
	r.LastAttemptOK = false
	r.LastAttemptReason = reason
	r.ConsecutiveFailures = prev.ConsecutiveFailures + 1
	if r.FailingSince.IsZero() {
		r.FailingSince = now.UTC()
	}
	r.NotBefore = time.Time{}
	if !notBefore.IsZero() {
		r.NotBefore = notBefore.UTC()
	}
	if rl.Known {
		p := ProviderStats{MinScore: -1, MaxScore: -1}
		if prev.Provider != nil {
			p = *prev.Provider // the last success's figures stay; only the quota is new
		}
		p.SetQuota(rl, now)
		r.Provider = &p
	}
	return tr, writeJSON(feedsDir, recordName(feed), r)
}

// NextPermitted is the earliest time a new request may be sent: the provider's back-off and the
// feed's minimum interval after the last successful refresh. Zero when a request may go now.
func NextPermitted(r RefreshRecord, minInterval time.Duration, now time.Time) time.Time {
	next := time.Time{}
	if r.NotBefore.After(now) {
		next = r.NotBefore
	}
	if minInterval > 0 && !r.LastSuccessAt.IsZero() {
		if t := r.LastSuccessAt.Add(minInterval); t.After(now) && t.After(next) {
			next = t
		}
	}
	return next
}

// WriteSync records one full sync (daemon only). prev carries the last OK sync forward so a failed
// sync never hides when the feed sets were last applied. It returns the feeds that became expired
// with this sync (for a once-only log line).
func WriteSync(feedsDir string, s SyncRecord) ([]string, error) {
	prev, _, err := ReadSync(feedsDir)
	if err != nil {
		prev = SyncRecord{}
	}
	s.At = s.At.UTC()
	if s.OK {
		s.LastOKAt = s.At
		s.LastOKFeeds = s.Enforced
	} else {
		s.LastOKAt = prev.LastOKAt
		s.LastOKFeeds = prev.LastOKFeeds
	}
	was := make(map[string]bool, len(prev.Expired))
	for _, f := range prev.Expired {
		was[f] = true
	}
	var newly []string
	for _, f := range s.Expired {
		if !was[f] {
			newly = append(newly, f)
		}
	}
	return newly, writeJSON(feedsDir, SyncRecordName, s)
}
