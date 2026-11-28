// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package main

// v1.239 (owner 2026-11-28, facts only): the AbuseIPDB plan detected from the key's daily limits,
// the check-endpoint (lookup) quota, and the effective blacklist request. Everything comes from
// the existing refresh record (feeds.ProviderStats) and the configured values; no new file, no
// config key, nothing written to the configuration.

import (
	"fmt"
	"io"
	"path/filepath"
	"time"

	"github.com/itcmsgr/nftban/internal/feeds"
	"github.com/itcmsgr/nftban/internal/nftbanconf"
)

// abuseIPDBStatusView is the status JSON's "abuseipdb" object (facts only).
type abuseIPDBStatusView struct {
	Plan               string     `json:"plan"`
	PlanKnown          bool       `json:"plan_known"`
	PlanSource         string     `json:"plan_source,omitempty"` // check endpoint / blacklist endpoint
	PlanSourceLimit    int        `json:"plan_source_daily_limit,omitempty"`
	PlanSeenAt         *time.Time `json:"plan_seen_at,omitempty"`
	PlanBlacklistMax   int        `json:"plan_blacklist_maximum,omitempty"`
	ConfiguredLimit    int        `json:"configured_limit"`
	ConfiguredConfMin  int        `json:"configured_confidence_minimum"`
	EffectiveLimit     int        `json:"effective_limit"`
	EffectiveConfMin   int        `json:"effective_confidence_minimum"`
	LookupQuotaKnown   bool       `json:"lookup_quota_known"`
	LookupQuotaLimit   int        `json:"lookup_quota_limit,omitempty"`
	LookupQuotaLeft    int        `json:"lookup_quota_remaining,omitempty"`
	LookupQuotaResetAt *time.Time `json:"lookup_quota_reset_at,omitempty"`
	LookupQuotaSeenAt  *time.Time `json:"lookup_quota_seen_at,omitempty"`
}

func abuseIPDBStatusFor(fc FeedConfig, prov *feeds.ProviderStats) *abuseIPDBStatusView {
	plan, src, seen := feeds.DetectedAbuseIPDBPlan(prov)
	conf := abuseIPDBConfiguredParams(fc)
	eff := feeds.EffectiveAbuseIPDBParams(conf, plan)
	v := &abuseIPDBStatusView{Plan: plan.Label, PlanKnown: plan.Known, PlanSource: src, PlanSourceLimit: plan.SourceLimit,
		PlanSeenAt: tp(seen), PlanBlacklistMax: plan.BlacklistMax,
		ConfiguredLimit: conf.Limit, ConfiguredConfMin: conf.ConfidenceMinimum,
		EffectiveLimit: eff.Limit, EffectiveConfMin: eff.ConfidenceMinimum}
	if prov != nil && prov.CheckQuotaKnown {
		v.LookupQuotaKnown, v.LookupQuotaLimit, v.LookupQuotaLeft = true, prov.CheckQuotaLimit, prov.CheckQuotaRemaining
		v.LookupQuotaResetAt, v.LookupQuotaSeenAt = tp(prov.CheckQuotaResetAt), tp(prov.CheckQuotaSeenAt)
	}
	return v
}

func utcMinute(t time.Time) string { return t.UTC().Format("2006-01-02 15:04 UTC") }

// printAbuseIPDBPlanLines prints the three status lines in the status block's style.
func printAbuseIPDBPlanLines(w io.Writer, v *abuseIPDBStatusView) {
	if v == nil {
		return
	}
	plan := v.Plan
	if v.PlanSource != "" && v.PlanSeenAt != nil {
		plan += fmt.Sprintf(" (detected from the key's daily limits: %s %d/day, as of %s)", v.PlanSource, v.PlanSourceLimit, utcMinute(*v.PlanSeenAt))
	}
	_, _ = fmt.Fprintf(w, "  Plan:                    %s\n", plan)
	lq := "unknown (no key test or lookup recorded yet)"
	if v.LookupQuotaKnown {
		lq = fmt.Sprintf("%d of %d left", v.LookupQuotaLeft, v.LookupQuotaLimit)
		if v.LookupQuotaResetAt != nil {
			lq += ", resets " + utcMinute(*v.LookupQuotaResetAt)
		}
		if v.LookupQuotaSeenAt != nil {
			lq += " (as of " + utcMinute(*v.LookupQuotaSeenAt) + ")"
		}
	}
	_, _ = fmt.Fprintf(w, "  Lookup quota:            %s\n", lq)
	mx := "plan maximum unknown: the configured values are sent"
	if v.PlanBlacklistMax > 0 {
		mx = fmt.Sprintf("plan maximum %d", v.PlanBlacklistMax)
	}
	eff := fmt.Sprintf("confidence >= %d, limit %d (%s)", v.EffectiveConfMin, v.EffectiveLimit, mx)
	if v.EffectiveConfMin != v.ConfiguredConfMin || v.EffectiveLimit != v.ConfiguredLimit {
		eff += fmt.Sprintf("; configured confidence >= %d, limit %d", v.ConfiguredConfMin, v.ConfiguredLimit)
	}
	_, _ = fmt.Fprintf(w, "  Effective request:       %s\n", eff)
}

// recordAbuseIPDBCheckQuota stores the check-endpoint quota for status (key test, lookup). It
// returns "" when recorded or nothing was stated, else a short key-free reason.
func recordAbuseIPDBCheckQuota(cfg *nftbanconf.Config, rl feeds.RateLimitInfo) string {
	if !rl.Known {
		return ""
	}
	if err := feeds.RecordCheckQuota(filepath.Join(cfg.DataDir, "feeds"), "abuseipdb", rl, time.Now()); err != nil {
		return "not recorded for status: " + err.Error()
	}
	return ""
}

// abuseIPDBConfiguredFeed returns the configured AbuseIPDB feed (ok=false when none is configured
// or the configuration is unreadable).
func abuseIPDBConfiguredFeed(cfg *nftbanconf.Config) (FeedConfig, bool) {
	_, feedsConfig, _ := getFeedsPaths(cfg)
	configs, err := parseFeedsConfig(feedsConfig)
	if err != nil {
		return FeedConfig{}, false
	}
	for _, fc := range configs {
		if fc.Format == FeedFormatAbuseIPDB {
			return fc, true
		}
	}
	return FeedConfig{}, false
}
