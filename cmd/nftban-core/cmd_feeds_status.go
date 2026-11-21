// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package main

// v1.238 part B (owner 2026-11-20): `nftban-core feeds status [--json]`, the ONE reader of the
// per-feed refresh state. Every other surface formats its JSON. Read-only: it records nothing.
//
// Three facts stay separate:
//   - snapshot freshness (mtime of <feed>.txt; expiry and the stale state use it),
//   - the last download outcome (<feed>.status, written by the downloader),
//   - the last full-sync outcome (full-sync.status, written by the daemon).
//
// Expiry wording (owner): a feed past its MAX_AGE is EXCLUDED BY THE AUTHORITY; it is REMOVED
// FROM THE KERNEL AT THE NEXT SUCCESSFUL FULL SYNC (not at exactly MAX_AGE).

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/feeds"
	"github.com/itcmsgr/nftban/internal/nftbanconf"
)

// Snapshot states.
const (
	feedStateFresh    = "fresh"
	feedStateStale    = "stale"
	feedStateExpired  = "expired"
	feedStateDisabled = "disabled"
	feedStateMissing  = "missing"
)

// feedsTimerUnit runs `nftban feeds update` daily (OnCalendar 03:20, RandomizedDelaySec 15m).
const feedsTimerUnit = "nftban-core-feeds.timer"

type attemptView struct {
	At     *time.Time `json:"at"`
	OK     bool       `json:"ok"`
	Reason string     `json:"reason,omitempty"`
}

type feedStatusView struct {
	Feed                string       `json:"feed"`
	Enabled             bool         `json:"enabled"`
	Format              string       `json:"format,omitempty"`
	State               string       `json:"state"`
	StateText           string       `json:"state_text"`
	LastSuccessAt       *time.Time   `json:"last_success_at"`
	LastSuccessAgeSec   *int64       `json:"last_success_age_seconds"`
	LastSuccessSource   string       `json:"last_success_source,omitempty"` // record / snapshot_mtime
	Entries             *int         `json:"entries,omitempty"`
	ProviderGeneratedAt string       `json:"provider_generated_at,omitempty"`
	LastAttempt         *attemptView `json:"last_attempt"`
	ConsecutiveFailures int          `json:"consecutive_failures"`
	FailingSince        *time.Time   `json:"failing_since,omitempty"`
	NextPermittedRetry  *time.Time   `json:"next_permitted_retry,omitempty"` // only when a back-off/minimum interval applies
	MaxAge              string       `json:"max_age,omitempty"`
	ExpiresAt           *time.Time   `json:"expires_at,omitempty"`
	StaleAfter          string       `json:"stale_after"`
	Enforcement         string       `json:"enforcement"`
	EnforcementText     string       `json:"enforcement_text"`
	RecordError         string       `json:"record_error,omitempty"`
	// provider feeds only
	Credential string               `json:"credential,omitempty"` // absent / ok / unsafe: <reason>; never the key
	Provider   *feeds.ProviderStats `json:"provider,omitempty"`
}

type syncView struct {
	At           *time.Time `json:"at"`
	OK           bool       `json:"ok"`
	Effect       string     `json:"effect,omitempty"`
	Reason       string     `json:"reason,omitempty"`
	LastOKAt     *time.Time `json:"last_ok_at"`
	FeedsSkipped bool       `json:"feeds_skipped,omitempty"`
	Recorded     bool       `json:"recorded"`
	Error        string     `json:"error,omitempty"`
}

type feedsStatusReport struct {
	GeneratedAt     time.Time        `json:"generated_at"`
	Master          bool             `json:"master"`
	Feeds           []feedStatusView `json:"feeds"`
	LastFullSync    syncView         `json:"last_full_sync"`
	NextScheduled   string           `json:"next_scheduled_refresh"`
	ScheduleWindow  string           `json:"schedule_window"`
	AuthorityReason []string         `json:"authority_texts,omitempty"`
	Worst           string           `json:"worst_state"`
	Attention       []attentionItem  `json:"attention"`
}

func tp(t time.Time) *time.Time {
	if t.IsZero() {
		return nil
	}
	u := t.UTC()
	return &u
}

// buildFeedsStatus assembles the report (pure apart from the reads; nextTimer is injected).
func buildFeedsStatus(configDir, dataDir string, master bool, configs []FeedConfig, now time.Time, nextTimer string) (feedsStatusReport, error) {
	feedsDir := filepath.Join(dataDir, "feeds")
	rep := feedsStatusReport{GeneratedAt: now.UTC(), Master: master, NextScheduled: nextTimer,
		ScheduleWindow: "daily 03:20 + up to 15 min (" + feedsTimerUnit + ", host time zone)"}
	d, err := feeds.Evaluate(configDir, dataDir, master)
	if err != nil {
		return rep, fmt.Errorf("feed authority undecidable: %w", err)
	}
	rep.AuthorityReason = d.Texts
	in := func(list []string, f string) bool {
		for _, x := range list {
			if strings.EqualFold(x, f) {
				return true
			}
		}
		return false
	}
	maxAges, _ := feeds.MaxAgeStatus(configDir)

	srec, sok, serr := feeds.ReadSync(feedsDir)
	rep.LastFullSync = syncView{At: tp(srec.At), OK: srec.OK, Effect: srec.Effect, Reason: srec.Reason,
		LastOKAt: tp(srec.LastOKAt), FeedsSkipped: srec.FeedsSkipped, Recorded: sok}
	if serr != nil {
		rep.LastFullSync.Error = serr.Error()
		if errors.Is(serr, fs.ErrPermission) {
			rep.LastFullSync.Error = recordNeedsRoot
		}
	}

	sort.Slice(configs, func(i, j int) bool { return configs[i].Name < configs[j].Name })
	rank := map[string]int{feedStateFresh: 0, feedStateDisabled: 0, feedStateStale: 1, feedStateMissing: 2, feedStateExpired: 3}
	rep.Worst = feedStateFresh
	for _, fc := range configs {
		name := strings.ToLower(fc.Name)
		v := feedStatusView{Feed: name, Enabled: fc.Enabled, Format: fc.Format}
		sa := feeds.StaleAfter(fc.MinInterval) // the one stale policy (the nftban_feed_stale gauge uses it too)
		v.StaleAfter = sa.String()
		rec, hasRec, rerr := feeds.ReadRefresh(feedsDir, name)
		if rerr != nil {
			v.RecordError = rerr.Error()
			if errors.Is(rerr, fs.ErrPermission) {
				v.RecordError = recordNeedsRoot
			}
		}
		var mtime time.Time
		if fi, err := os.Stat(filepath.Join(feedsDir, name+".txt")); err == nil {
			mtime = fi.ModTime()
		}
		// Snapshot freshness: the snapshot's mtime is the authority (it is what expiry uses).
		// The record's success time is shown when present (it is written right after the same
		// replacement); a snapshot from before v1.238 has only its mtime.
		succ := rec.LastSuccessAt
		v.LastSuccessSource = "record"
		// a snapshot replaced after the record (no record yet, or the shell fallback writer)
		if !mtime.IsZero() && mtime.After(succ.Add(time.Minute)) {
			succ, v.LastSuccessSource = mtime, "snapshot_mtime"
		}
		if succ.IsZero() {
			v.LastSuccessSource = ""
		}
		v.LastSuccessAt = tp(succ)
		if !succ.IsZero() {
			age := int64(now.Sub(succ).Seconds())
			v.LastSuccessAgeSec = &age
		}
		if fc.Format == FeedFormatAbuseIPDB {
			v.Credential = feeds.CredentialStatus(filepath.Join(configDir, abuseIPDBKeyName))
		}
		if hasRec {
			v.Provider = rec.Provider
			if rec.LastSuccessEntries > 0 {
				n := rec.LastSuccessEntries
				v.Entries = &n
			}
			v.ProviderGeneratedAt = rec.ProviderGeneratedAt
			if !rec.LastAttemptAt.IsZero() {
				v.LastAttempt = &attemptView{At: tp(rec.LastAttemptAt), OK: rec.LastAttemptOK, Reason: rec.LastAttemptReason}
			}
			v.ConsecutiveFailures = rec.ConsecutiveFailures
			v.FailingSince = tp(rec.FailingSince)
		}
		if next := feeds.NextPermitted(rec, fc.MinInterval, now); !next.IsZero() {
			v.NextPermittedRetry = tp(next)
		}
		if ma, ok := maxAges[strings.ToUpper(name)]; ok {
			v.MaxAge = ma.String()
			if !mtime.IsZero() {
				v.ExpiresAt = tp(mtime.Add(ma))
			}
		}

		switch {
		case in(d.Expired, name):
			v.State = feedStateExpired
			v.StateText = fmt.Sprintf("expired: last successful refresh older than MAX_AGE %s; excluded by the feed authority; snapshot kept on disk", v.MaxAge)
		case !fc.Enabled || in(d.NotEnabled, name):
			v.State = feedStateDisabled
			v.StateText = "disabled: not enforced"
			if !fc.Enabled {
				break
			}
			v.StateText = "not enforced (feed authority: " + strings.Join(d.Texts, "; ") + ")"
		case mtime.IsZero():
			v.State = feedStateMissing
			v.StateText = "missing: no snapshot on disk yet"
		case now.Sub(mtime) > sa:
			v.State = feedStateStale
			v.StateText = fmt.Sprintf("stale: last successful refresh older than %s (twice the expected interval); still enforced", sa)
		default:
			v.State = feedStateFresh
			v.StateText = "fresh"
			if v.MaxAge != "" {
				v.StateText = "fresh: within the configured maximum age " + v.MaxAge
			}
		}
		if v.LastAttempt != nil && !v.LastAttempt.OK && v.State != feedStateDisabled {
			v.StateText += "; last refresh FAILED, snapshot retained"
		}

		// Enforcement: what the authority decides now, and whether the last successful full sync
		// applied the feed. Feeds share merged kernel sets, so this is never "verified in kernel".
		appliedLast := sok && in(srec.LastOKFeeds, name)
		lastOK := "never"
		if !srec.LastOKAt.IsZero() {
			lastOK = srec.LastOKAt.UTC().Format("2006-01-02 15:04 UTC")
		}
		switch {
		case in(d.Enforced, name) && appliedLast:
			v.Enforcement = "enforced"
			v.EnforcementText = "included in the last successful full sync (" + lastOK + ")"
		case in(d.Enforced, name):
			v.Enforcement = "pending_sync"
			v.EnforcementText = "selected by the feed authority; not yet included in a successful full sync (last successful: " + lastOK + ")"
		case appliedLast:
			v.Enforcement = "pending_removal"
			v.EnforcementText = "excluded by the feed authority; its contribution stays in the kernel sets until the next successful full sync (last successful: " + lastOK + ")"
		default:
			v.Enforcement = "not_enforced"
			v.EnforcementText = "not enforced"
		}
		if rank[v.State] > rank[rep.Worst] {
			rep.Worst = v.State
		}
		rep.Feeds = append(rep.Feeds, v)
	}
	rep.Attention = feedsAttention(rep)
	return rep, nil
}

// recordNeedsRoot replaces a permission error on a refresh or sync record (0640 root:nftban).
const recordNeedsRoot = "not readable by this user (needs root or the nftban group)"

// attentionItem is one line `nftban status` and `nftban health` print (they format this list and
// keep no feed thresholds of their own). Key is stable; Text is for operators.
type attentionItem struct {
	Key  string `json:"key"`
	Feed string `json:"feed,omitempty"`
	Text string `json:"text"`
}

// feedsAttention lists what needs an operator: per enabled feed the snapshot state, the last
// download outcome and the key, and separately the last full-sync outcome. A failed download is
// listed even when the snapshot is still fresh; a failed sync even when every download succeeded.
func feedsAttention(rep feedsStatusReport) []attentionItem {
	out := []attentionItem{}
	add := func(key, feed, text string) { out = append(out, attentionItem{Key: key, Feed: feed, Text: text}) }
	// Records the caller may not read (0640 root:nftban) are one line, not one per feed.
	needRoot := rep.LastFullSync.Error == recordNeedsRoot
	for _, v := range rep.Feeds {
		if !v.Enabled {
			continue
		}
		switch v.State {
		case feedStateExpired:
			where := "contribution excluded from the last successful sync" // the same addresses may still be banned by another feed or reason
			if v.Enforcement == "pending_removal" {
				where = "its contribution stays in the kernel sets until the next successful full sync"
			}
			add("feed_expired", v.Feed, "feed "+v.Feed+" expired (past MAX_AGE "+v.MaxAge+"): excluded by the feed authority; "+where)
		case feedStateStale:
			add("feed_stale", v.Feed, "feed "+v.Feed+" stale: last successful refresh older than "+v.StaleAfter+"; still enforced")
		case feedStateMissing:
			add("feed_missing", v.Feed, "feed "+v.Feed+" enabled but no snapshot on disk yet")
		}
		if a := v.LastAttempt; a != nil && !a.OK {
			last := "never"
			if v.LastSuccessAt != nil {
				last = v.LastSuccessAt.Format("2006-01-02 15:04 UTC")
			}
			add("feed_refresh_failed", v.Feed, fmt.Sprintf("feed %s: last refresh failed at %s (%s; %d in a row); last successful %s; snapshot retained",
				v.Feed, a.At.Format("2006-01-02 15:04 UTC"), a.Reason, v.ConsecutiveFailures, last))
		}
		if v.Credential != "" && v.Credential != "ok" && !strings.HasPrefix(v.Credential, "unknown") {
			add("feed_credential", v.Feed, "feed "+v.Feed+": API key "+v.Credential+" (nftban feeds abuseipdb key set)")
		}
		switch v.RecordError {
		case "":
		case recordNeedsRoot:
			needRoot = true
		default:
			add("feed_record_unreadable", v.Feed, "feed "+v.Feed+": "+v.RecordError)
		}
	}
	s := rep.LastFullSync
	switch {
	case needRoot:
		add("feeds_records_need_root", "", "refresh state "+recordNeedsRoot+"; run as root for the full feed state")
	case s.Error != "":
		add("feeds_sync_record_unreadable", "", "last full sync record unreadable: "+s.Error)
	case s.Recorded && !s.OK:
		last := "never"
		if s.LastOKAt != nil {
			last = s.LastOKAt.Format("2006-01-02 15:04 UTC")
		}
		at := "unknown time"
		if s.At != nil {
			at = s.At.Format("2006-01-02 15:04 UTC")
		}
		add("feeds_sync_failed", "", fmt.Sprintf("last full sync failed at %s (%s: %s); last successful full sync %s", at, s.Effect, s.Reason, last))
	}
	return out
}

// nextFeedsTimer asks systemd (read-only) when the feeds timer elapses next; "" when unknown.
func nextFeedsTimer() string {
	out, err := exec.Command("systemctl", "show", feedsTimerUnit, "-p", "NextElapseUSecRealtime", "--value").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func cmdFeedsStatus(feedsConfig string, cfg *nftbanconf.Config) error {
	configs, err := parseFeedsConfig(feedsConfig)
	if err != nil {
		return fmt.Errorf("failed to parse feeds config: %w", err)
	}
	rep, err := buildFeedsStatus(cfg.ConfigDir, cfg.DataDir, cfg.FeedsEnabled, configs, time.Now(), nextFeedsTimer())
	if err != nil {
		return err
	}
	if only := flagValue("--feed"); only != "" {
		kept := rep.Feeds[:0]
		for _, v := range rep.Feeds {
			if strings.EqualFold(v.Feed, only) {
				kept = append(kept, v)
			}
		}
		if len(kept) == 0 {
			return fmt.Errorf("unknown feed: %s (list: nftban feeds list)", only)
		}
		rep.Feeds = kept
		rep.Attention = feedsAttention(rep)
	}
	if hasFlag("--json") {
		data, err := json.Marshal(rep)
		if err != nil {
			return err
		}
		fmt.Println(string(data))
		return nil
	}
	printFeedsStatus(rep, hasFlag("--all") || flagValue("--feed") != "")
	return nil
}

// flagValue returns the argument after flag ("" when absent).
func flagValue(flag string) string {
	for i, a := range os.Args {
		if a == flag && i+1 < len(os.Args) {
			return os.Args[i+1]
		}
	}
	return ""
}

func fmtTime(t *time.Time, now time.Time) string {
	if t == nil {
		return "never"
	}
	d := now.Sub(*t)
	rel := d.Round(time.Minute).String() + " ago"
	if d < 0 {
		rel = "in " + (-d).Round(time.Minute).String()
	}
	return t.Format("2006-01-02 15:04 UTC") + " (" + rel + ")"
}

// printFeedsStatus prints the per-feed blocks; disabled feeds only with --all.
func printFeedsStatus(rep feedsStatusReport, all bool) {
	now := rep.GeneratedAt
	shown := 0
	for _, v := range rep.Feeds {
		if v.State == feedStateDisabled && !v.Enabled && !all {
			continue
		}
		shown++
		head := strings.ToUpper(v.Feed) + " — " + v.State
		if v.LastAttempt != nil && !v.LastAttempt.OK {
			head = strings.ToUpper(v.Feed) + " — refresh failed: " + v.LastAttempt.Reason
		}
		fmt.Println(head)
		fmt.Printf("  Last successful refresh: %s\n", fmtTime(v.LastSuccessAt, now))
		if v.LastSuccessSource == "snapshot_mtime" {
			fmt.Println("                           (from the snapshot time: refreshed without a refresh record)")
		}
		if v.ProviderGeneratedAt != "" {
			fmt.Printf("  Provider generated at:   %s (provider time)\n", v.ProviderGeneratedAt)
		}
		if v.LastAttempt != nil {
			res := "succeeded"
			if !v.LastAttempt.OK {
				res = fmt.Sprintf("FAILED (%d in a row)", v.ConsecutiveFailures)
			}
			fmt.Printf("  Last attempt:            %s, %s\n", fmtTime(v.LastAttempt.At, now), res)
		}
		if v.Credential != "" {
			fmt.Printf("  API key:                 %s\n", v.Credential)
		}
		if p := v.Provider; p != nil {
			if p.Received > 0 || p.Accepted > 0 {
				score := "unknown"
				if p.MinScore >= 0 {
					score = fmt.Sprintf("%d-%d", p.MinScore, p.MaxScore)
				}
				fmt.Printf("  Last download:           requested confidence >= %d, limit %d; received %d, accepted %d, rejected %d; score %s\n",
					p.RequestedConfidence, p.RequestedLimit, p.Received, p.Accepted, p.Rejected, score)
			}
			quota := "unknown (the provider did not state it)"
			if p.QuotaKnown {
				quota = fmt.Sprintf("%d of %d left", p.QuotaRemaining, p.QuotaLimit)
				if !p.QuotaResetAt.IsZero() {
					quota += ", resets " + p.QuotaResetAt.UTC().Format("2006-01-02 15:04 UTC")
				}
				quota += " (as of " + p.QuotaSeenAt.UTC().Format("2006-01-02 15:04 UTC") + ")"
			}
			fmt.Printf("  Download quota:          %s\n", quota)
		}
		fmt.Printf("  Snapshot:                %s\n", v.StateText)
		if v.ExpiresAt != nil && v.State != feedStateExpired {
			fmt.Printf("  Expiry:                  excluded by the authority after %s; its contribution leaves the kernel sets at the next successful full sync\n", v.ExpiresAt.Format("2006-01-02 15:04 UTC"))
		}
		fmt.Printf("  Enforcement:             %s\n", v.EnforcementText)
		if v.NextPermittedRetry != nil {
			fmt.Printf("  Next permitted request:  %s\n", fmtTime(v.NextPermittedRetry, now))
		}
		if v.Enabled {
			next := rep.NextScheduled
			if next == "" {
				next = rep.ScheduleWindow
			}
			fmt.Printf("  Next scheduled refresh:  %s\n", next)
		}
		if v.RecordError != "" {
			fmt.Printf("  ⚠️  %s\n", v.RecordError)
		}
		fmt.Println()
	}
	if shown == 0 {
		fmt.Println("No enabled feeds (nftban feeds list; --all shows disabled feeds).")
		fmt.Println()
	}
	s := rep.LastFullSync
	switch {
	case s.Error != "":
		fmt.Printf("Last full sync: unreadable record (%s)\n", s.Error)
	case !s.Recorded:
		fmt.Println("Last full sync: not recorded yet (recorded by the daemon from v1.238)")
	case s.OK:
		fmt.Printf("Last full sync: %s, feed sets applied\n", fmtTime(s.At, now))
	default:
		fmt.Printf("Last full sync: %s, FAILED (%s: %s); last successful: %s\n", fmtTime(s.At, now), s.Effect, s.Reason, fmtTime(s.LastOKAt, now))
	}
}
