// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="safety_cleanup_eligibility"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.237 permanent-ban cleanup repair (design V1237_CLEANUP_REPAIR_DESIGN_2026_11_14 §0/§2B): ONE eligibility calculation used by dry-run, execute and stats. Input: the durable reasons per IP (blacklist.d file membership) and the tracking list. Output: one decision per (IP, automatic reason) plus tracking-only entries, each with an exclusion reason when not eligible. Ambiguous provenance and unreliable or unknown age are never eligible; timestamps are never invented."
// meta:inventory.privileges="none"

package safety

import (
	"sort"
	"strings"
	"time"
)

// AutomaticCleanupSources are the reason sources whose bans may become cleanup candidates
// (automatic permanent bans). Manual, feed and geoban bans never are.
var AutomaticCleanupSources = map[string]bool{
	"persistent": true,
	"login":      true,
	"portscan":   true,
	"ddos":       true,
}

// Exclusion reasons reported for a non-eligible decision.
const (
	ExclManualReason   = "recorded-manual"            // IP is in 99-manual.conf: stays until explicit unban; provenance ambiguous (§0.1)
	ExclProtected      = "protected"                  // never removed automatically
	ExclNotTracked     = "unknown-age-not-tracked"    // no tracking entry: age unknown, never invented
	ExclSourceMismatch = "ambiguous-provenance"       // tracked source differs from the reason file (§0.1)
	ExclBulkTimestamp  = "unreliable-age-bulk-window" // added_at inside a detected bulk timestamp window (§0.2)
	ExclTooYoung       = "younger-than-threshold"
	ExclNoReasonFile   = "tracking-without-reason" // tracked but no reason file holds it (reported only)
	// v1.237 owner condition 2026-11-14: trust is established positively, never by the bulk heuristic.
	ExclLegacyUnverified = "legacy-age-unverified" // no AgeSourceBanTime: provenance/age not established
	ExclRolloutRewrite   = "rollout-rewrite"       // documented re-persist (dns1 2026-10-17), explicit
)

// RolloutRewriteReasonPrefix marks entries re-persisted by the v1.235.1 rollout harness (dns1
// 2026-10-17, 344 entries; design §5). Their age and stored source were overwritten: always ineligible,
// independent of the bulk-window heuristic.
const RolloutRewriteReasonPrefix = "v1235.1-rollout-preserve"

// CleanupDecision is the outcome for one (IP, reason source). For tracking-only entries Source is "".
type CleanupDecision struct {
	IP        string
	Source    string
	AddedAt   time.Time // zero when unknown
	Eligible  bool
	Exclusion string // empty when Eligible
	// FinishPending: an earlier cleanup marked this entry and removed its last durable reason, but did
	// not finish (kernel delete / tracking removal). The next run finishes it (recovery, §0.4).
	FinishPending bool
}

// TimeWindow is a closed interval of detected bulk timestamps.
type TimeWindow struct{ From, To time.Time }

func (w TimeWindow) contains(t time.Time) bool { return !t.Before(w.From) && !t.After(w.To) }

// Bulk-window detection defaults: at least BulkWindowMinEntries tracking entries stamped within
// BulkWindowSpan of each other cannot be individual ban ages (dns1 2026-10-17: 344 within 55 s, a
// re-persist harness). Defined in data, not by a date literal.
const (
	BulkWindowMinEntries = 20
	BulkWindowSpan       = 2 * time.Minute
)

// DetectBulkWindows returns the windows in which at least minEntries added_at values fall within span.
func DetectBulkWindows(state *PermanentBansState, minEntries int, span time.Duration) []TimeWindow {
	if state == nil || minEntries < 2 {
		return nil
	}
	var ts []time.Time
	for _, b := range state.Bans {
		if !b.AddedAt.IsZero() {
			ts = append(ts, b.AddedAt)
		}
	}
	sort.Slice(ts, func(i, j int) bool { return ts[i].Before(ts[j]) })
	var out []TimeWindow
	for i := 0; i < len(ts); {
		j := i
		for j+1 < len(ts) && ts[j+1].Sub(ts[i]) <= span {
			j++
		}
		if j-i+1 >= minEntries {
			w := TimeWindow{From: ts[i], To: ts[j]}
			if n := len(out); n > 0 && !w.From.After(out[n-1].To) {
				out[n-1].To = w.To // merge overlapping windows
			} else {
				out = append(out, w)
			}
			i = j + 1
			continue
		}
		i++
	}
	return out
}

// EvaluateCleanup is the single eligibility calculation (dry-run, execute and stats use it).
// reasons: IP -> sources whose blacklist.d file holds the IP. state: the tracking list.
// thresholdDays: the agreed inactivity period. Decisions are sorted by IP, then source.
func EvaluateCleanup(reasons map[string][]string, state *PermanentBansState, now time.Time, thresholdDays int) []CleanupDecision {
	if state == nil {
		state = &PermanentBansState{Bans: map[string]*PermanentBan{}}
	}
	windows := DetectBulkWindows(state, BulkWindowMinEntries, BulkWindowSpan)
	threshold := now.AddDate(0, 0, -thresholdDays)
	var out []CleanupDecision

	for ip, srcs := range reasons {
		manual := false
		for _, s := range srcs {
			if s == "manual" {
				manual = true
			}
		}
		for _, s := range srcs {
			if !AutomaticCleanupSources[s] {
				continue
			}
			d := CleanupDecision{IP: ip, Source: s}
			tr := state.Bans[ip]
			if tr != nil {
				d.AddedAt = tr.AddedAt
			}
			switch {
			case manual:
				d.Exclusion = ExclManualReason
			case tr != nil && tr.Protected:
				d.Exclusion = ExclProtected
			case tr != nil && strings.HasPrefix(tr.Reason, RolloutRewriteReasonPrefix):
				d.Exclusion = ExclRolloutRewrite
			case tr == nil || tr.AddedAt.IsZero():
				d.Exclusion = ExclNotTracked
			case tr.AgeSource != AgeSourceBanTime:
				d.Exclusion = ExclLegacyUnverified
			case tr.Source != "" && tr.Source != s:
				d.Exclusion = ExclSourceMismatch
			case inAny(windows, tr.AddedAt):
				d.Exclusion = ExclBulkTimestamp
			case !tr.AddedAt.Before(threshold):
				d.Exclusion = ExclTooYoung
			default:
				d.Eligible = true
			}
			out = append(out, d)
		}
	}
	for ip, tr := range state.Bans {
		if len(reasons[ip]) == 0 {
			d := CleanupDecision{IP: ip, Source: tr.CleanupPending, AddedAt: tr.AddedAt, Exclusion: ExclNoReasonFile}
			if tr.CleanupPending != "" && !tr.Protected {
				d.FinishPending = true // only a cleanup-marked entry is ever finished; others are reported
			}
			out = append(out, d)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].IP != out[j].IP {
			return out[i].IP < out[j].IP
		}
		return out[i].Source < out[j].Source
	})
	return out
}

func inAny(ws []TimeWindow, t time.Time) bool {
	for _, w := range ws {
		if w.contains(t) {
			return true
		}
	}
	return false
}
