// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package feeds

// v1.239 AbuseIPDB plan detection and request adaptation (owner 2026-11-28: "we create the
// mechanism"; facts only). The plan is a detected fact read from the daily limits the provider
// states for the key (X-RateLimit-Limit): the check endpoint's (key test, reputation lookup), or
// the blacklist endpoint's as a fallback. It lives only in the existing refresh record
// (ProviderStats); no config key, no new file, and nothing here writes the configuration.
//
// The blacklist request adapts: limit = min(configured, plan maximum), and on a plan whose
// blacklist is served at full confidence only, confidenceMinimum = max(configured, 100). An
// unknown plan sends the configured values unchanged (the v1.238 behaviour).

import (
	"strconv"
	"time"
)

// AbuseIPDBPlan is what a stated daily limit identifies.
type AbuseIPDBPlan struct {
	Known        bool
	Label        string // "Standard", "Basic", ...; "unknown (...)" when not identified
	SourceLimit  int    // the X-RateLimit-Limit it was derived from; 0 when none was stated
	BlacklistMax int    // largest blacklist the plan serves; 0 when unknown
	// FullConfidenceOnly: the plan's blacklist is served at confidenceMinimum 100 only.
	FullConfidenceOnly bool
}

// Plan sources (where the limit was read).
const (
	PlanSourceCheck     = "check endpoint"
	PlanSourceBlacklist = "blacklist endpoint"
)

type abuseIPDBPlanRow struct {
	check, blacklist int
	label            string
	blacklistMax     int
	fullConfOnly     bool
}

// abuseIPDBPlans is the AbuseIPDB APIv2 documentation's "API Daily Rate Limits" table
// (docs.abuseipdb.com; values as supplied by the owner/lead 2026-11-28, not re-fetched in this
// change): daily requests per endpoint, and the blacklist size each plan serves.
//
//	plan        check/day  blacklist/day  blacklist entries  confidenceMinimum
//	Standard    1000       5              10,000             100 only
//	Webmaster   3000       10             10,000             100 only
//	Supporter   5000       20             10,000             100 only
//	Basic       10000      100            100,000            as requested
//	Premium     50000      500            500,000            as requested
var abuseIPDBPlans = []abuseIPDBPlanRow{
	{1000, 5, "Standard", 10000, true},
	{3000, 10, "Webmaster", 10000, true},
	{5000, 20, "Supporter", 10000, true},
	{10000, 100, "Basic", 100000, false},
	{50000, 500, "Premium", AbuseIPDBMaxLimit, false},
}

func planFromLimit(rl RateLimitInfo, blacklist bool) AbuseIPDBPlan {
	if !rl.Known || rl.Limit <= 0 {
		return AbuseIPDBPlan{Label: "unknown (no limit stated)"}
	}
	for _, r := range abuseIPDBPlans {
		if (!blacklist && rl.Limit == r.check) || (blacklist && rl.Limit == r.blacklist) {
			return AbuseIPDBPlan{Known: true, Label: r.label, SourceLimit: rl.Limit, BlacklistMax: r.blacklistMax, FullConfidenceOnly: r.fullConfOnly}
		}
	}
	return AbuseIPDBPlan{Label: "unknown (limit " + strconv.Itoa(rl.Limit) + ")", SourceLimit: rl.Limit}
}

// AbuseIPDBPlanFromCheckLimit maps the check endpoint's daily limit (any other value: unknown).
func AbuseIPDBPlanFromCheckLimit(rl RateLimitInfo) AbuseIPDBPlan { return planFromLimit(rl, false) }

// AbuseIPDBPlanFromBlacklistLimit maps the blacklist endpoint's daily limit (the fallback).
func AbuseIPDBPlanFromBlacklistLimit(rl RateLimitInfo) AbuseIPDBPlan { return planFromLimit(rl, true) }

// DetectedAbuseIPDBPlan is the plan the record supports: the check quota first, the blacklist
// quota as a fallback. source/seenAt are empty/zero when the plan is unknown.
func DetectedAbuseIPDBPlan(p *ProviderStats) (plan AbuseIPDBPlan, source string, seenAt time.Time) {
	if p == nil || (!p.CheckQuotaKnown && !p.QuotaKnown) {
		return AbuseIPDBPlan{Label: "unknown (no daily limit seen yet)"}, "", time.Time{}
	}
	var fallback AbuseIPDBPlan
	if p.CheckQuotaKnown {
		plan = AbuseIPDBPlanFromCheckLimit(RateLimitInfo{Known: true, Limit: p.CheckQuotaLimit})
		if plan.Known {
			return plan, PlanSourceCheck, p.CheckQuotaSeenAt
		}
		fallback = plan
	}
	if p.QuotaKnown {
		plan = AbuseIPDBPlanFromBlacklistLimit(RateLimitInfo{Known: true, Limit: p.QuotaLimit})
		if plan.Known || !p.CheckQuotaKnown {
			return plan, PlanSourceBlacklist, p.QuotaSeenAt
		}
	}
	return fallback, PlanSourceCheck, p.CheckQuotaSeenAt
}

// EffectiveAbuseIPDBParams returns what is sent for the configured parameters on this plan. The
// configured values are never modified (value receiver); an unknown plan returns them unchanged.
func EffectiveAbuseIPDBParams(configured AbuseIPDBParams, plan AbuseIPDBPlan) AbuseIPDBParams {
	eff := configured
	if !plan.Known {
		return eff
	}
	if plan.BlacklistMax > 0 && eff.Limit > plan.BlacklistMax {
		eff.Limit = plan.BlacklistMax
	}
	if plan.FullConfidenceOnly && eff.ConfidenceMinimum < AbuseIPDBConfidenceMax {
		eff.ConfidenceMinimum = AbuseIPDBConfidenceMax
	}
	return eff
}
