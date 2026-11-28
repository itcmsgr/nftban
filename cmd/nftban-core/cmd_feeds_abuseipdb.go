// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package main

// v1.238 part B2: the AbuseIPDB key and the standalone key test. The `nftban feeds abuseipdb`
// menu (cli/lib/nftban/cli/cmd_feeds.sh) is thin and delegates here and to the generic feed
// handlers.
//
//   nftban-core feeds abuseipdb-key set      key on STDIN (never argv), stored root:root 0600
//   nftban-core feeds abuseipdb-key status   absent / ok / unsafe: <reason>; never the key
//   nftban-core feeds abuseipdb-key remove
//   nftban-core feeds abuseipdb-test [--json]  ONE GET /api/v2/check (check quota, not blacklist)
//
// The test never writes the snapshot and never touches the refresh record's success, attempt or
// back-off fields: a passing test cannot make an old enforced list look fresh. v1.239: it records
// only the check-endpoint quota there (feeds.RecordCheckQuota), from which status derives the plan.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/itcmsgr/nftban/internal/feeds"
	"github.com/itcmsgr/nftban/internal/nftbanconf"
)

func abuseIPDBKeyPath(cfg *nftbanconf.Config) string {
	return filepath.Join(cfg.ConfigDir, abuseIPDBKeyName)
}

func cmdFeedsAbuseIPDBKey(cfg *nftbanconf.Config, sub string) error {
	path := abuseIPDBKeyPath(cfg)
	switch sub {
	case "status":
		fmt.Printf("API key file: %s: %s\n", path, feeds.CredentialStatus(path))
		return nil
	case "set":
		if os.Geteuid() != 0 {
			return errors.New("storing the API key needs root")
		}
		b, err := io.ReadAll(io.LimitReader(os.Stdin, 1025))
		if err != nil {
			return errors.New("reading the key from stdin failed")
		}
		if len(b) > 1024 {
			return errors.New("the key on stdin is longer than 1024 bytes")
		}
		if err := feeds.WriteCredentialFile(path, string(b)); err != nil {
			return err
		}
		fmt.Printf("API key stored in %s (root:root 0600; not shown). Check it with: nftban feeds abuseipdb test\n", path)
		return nil
	case "remove":
		if os.Geteuid() != 0 {
			return errors.New("removing the API key needs root")
		}
		if err := feeds.RemoveCredentialFile(path); err != nil {
			return err
		}
		fmt.Printf("API key removed (%s). If the AbuseIPDB feed stays enabled, its next refresh fails and status shows it.\n", path)
		return nil
	default:
		return fmt.Errorf("usage: nftban-core feeds abuseipdb-key <set|status|remove> (set reads the key from stdin)")
	}
}

// keyTestReport is the --json output of the key test.
type keyTestReport struct {
	Endpoint  string `json:"endpoint"`
	Cost      string `json:"cost"`
	OK        bool   `json:"ok"`
	Status    int    `json:"http_status,omitempty"`
	ErrorKind string `json:"error_kind,omitempty"`
	Error     string `json:"error,omitempty"`
	Quota     string `json:"check_quota"`
	NotBefore string `json:"retry_not_before,omitempty"`
	// v1.239: facts from the stated check limit, and what the next download sends
	Plan             string `json:"plan"`
	PlanKnown        bool   `json:"plan_known"`
	EffectiveConfMin int    `json:"effective_confidence_minimum,omitempty"`
	EffectiveLimit   int    `json:"effective_limit,omitempty"`
	PlanMaximum      int    `json:"plan_blacklist_maximum,omitempty"`
	RecordNote       string `json:"record_note,omitempty"`
}

// keyTestPlan fills the plan facts from the stated check limit and the configured feed.
func keyTestPlan(cfg *nftbanconf.Config, rep *keyTestReport, rl feeds.RateLimitInfo) {
	plan := feeds.AbuseIPDBPlanFromCheckLimit(rl)
	rep.Plan, rep.PlanKnown, rep.PlanMaximum = plan.Label, plan.Known, plan.BlacklistMax
	if fc, ok := abuseIPDBConfiguredFeed(cfg); ok {
		eff := feeds.EffectiveAbuseIPDBParams(abuseIPDBConfiguredParams(fc), plan)
		rep.EffectiveConfMin, rep.EffectiveLimit = eff.ConfidenceMinimum, eff.Limit
	}
	rep.RecordNote = recordAbuseIPDBCheckQuota(cfg, rl)
}

const keyTestCost = "one request against the check endpoint's daily limit; the separate blacklist download limit is not used"

func cmdFeedsAbuseIPDBTest(cfg *nftbanconf.Config) error {
	rep := keyTestReport{Endpoint: "GET " + feeds.AbuseIPDBCheckURL + "?ipAddress=127.0.0.1&maxAgeInDays=1", Cost: keyTestCost, Quota: "unknown",
		Plan: feeds.AbuseIPDBPlanFromCheckLimit(feeds.RateLimitInfo{}).Label}
	key, err := feeds.ReadCredentialFile(abuseIPDBKeyPath(cfg))
	if err == nil {
		ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
		defer cancel()
		var res *feeds.KeyTestResult
		res, err = feeds.TestAbuseIPDBKey(ctx, nil, "", key)
		if err == nil {
			rep.OK, rep.Status = true, res.Status
			rep.Quota = quotaText(res.RateLimit)
			keyTestPlan(cfg, &rep, res.RateLimit)
		}
	}
	if err != nil {
		rep.Error = err.Error()
		var pe *feeds.ProviderError
		if errors.As(err, &pe) {
			rep.ErrorKind, rep.Status = pe.Kind, pe.Status
			rep.Quota = quotaText(pe.RateLimit)
			if !pe.NotBefore.IsZero() {
				rep.NotBefore = pe.NotBefore.UTC().Format(time.RFC3339)
			}
			keyTestPlan(cfg, &rep, pe.RateLimit)
		}
	}
	if hasFlag("--json") {
		data, jerr := json.Marshal(rep)
		if jerr != nil {
			return jerr
		}
		fmt.Println(string(data))
	} else {
		fmt.Println("AbuseIPDB key test")
		fmt.Printf("  Request: %s\n", rep.Endpoint)
		fmt.Printf("  Cost:    %s\n", rep.Cost)
		if rep.OK {
			fmt.Printf("  Result:  key accepted (HTTP %d)\n", rep.Status)
		} else {
			fmt.Printf("  Result:  FAILED: %s\n", rep.Error)
		}
		fmt.Printf("  Check-endpoint quota: %s\n", rep.Quota)
		fmt.Printf("  Plan:    %s\n", keyTestPlanText(rep))
		if rep.EffectiveLimit > 0 {
			mx := "plan maximum unknown: the configured values are sent"
			if rep.PlanMaximum > 0 {
				mx = fmt.Sprintf("plan maximum %d", rep.PlanMaximum)
			}
			fmt.Printf("  Next download sends: confidence >= %d, limit %d (%s)\n", rep.EffectiveConfMin, rep.EffectiveLimit, mx)
		}
		if rep.RecordNote != "" {
			fmt.Printf("  Check-endpoint quota %s\n", rep.RecordNote)
		}
		fmt.Println("  The test downloads nothing: the feed snapshot and its last successful refresh are unchanged.")
	}
	if !rep.OK {
		return errors.New("AbuseIPDB key test failed")
	}
	return nil
}

func keyTestPlanText(rep keyTestReport) string {
	if rep.PlanKnown {
		return rep.Plan + " (detected from the check endpoint's daily limit)"
	}
	return rep.Plan
}

func quotaText(rl feeds.RateLimitInfo) string {
	if !rl.Known {
		return "unknown (the provider did not state it)"
	}
	s := fmt.Sprintf("%d of %d left", rl.Remaining, rl.Limit)
	if !rl.ResetAt.IsZero() {
		s += ", resets " + rl.ResetAt.UTC().Format("2006-01-02 15:04 UTC")
	}
	return s
}
