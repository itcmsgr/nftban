// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package main

// v1.239 (PROPOSED, plan V1239_ABUSEIPDB_REPORTING_LOOKUP_PLAN.md §5): read-only AbuseIPDB
// reputation lookup of ONE address.
//
//   nftban-core feeds abuseipdb-check <ip> [--json] [--max-age-days N]
//
// ONE GET /api/v2/check (the check endpoint's daily limit, shared with abuseipdb-test). The key is
// the existing credential file (abuseIPDBKeyPath). The target is validated before the key is read.
// A lookup is information only: it never bans, unbans or whitelists and writes no kernel state;
// the only thing it records is the check-endpoint quota in the AbuseIPDB feed status record
// (feeds.RecordCheckQuota; status shows it). No retry: a 429 prints when the next lookup is allowed.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/netip"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/feeds"
	"github.com/itcmsgr/nftban/internal/nftbanconf"
)

const abuseIPDBCheckUsage = "usage: nftban-core feeds abuseipdb-check <ip> [--json] [--max-age-days N] (N 1-365, default 30)"

const abuseIPDBCheckEffect = "none: a lookup is information only; it never bans, unbans or whitelists an address and writes no kernel state (only the check-endpoint quota is recorded for feeds status)"

// abuseIPDBCheckReport is the --json output (and the source of the text output).
type abuseIPDBCheckReport struct {
	Source           string `json:"source"`
	Endpoint         string `json:"endpoint"`
	Cost             string `json:"cost"`
	InformationOnly  bool   `json:"information_only"`
	Effect           string `json:"effect"`
	IP               string `json:"ip"`
	MaxAgeInDays     int    `json:"max_age_in_days"`
	QueriedAt        string `json:"queried_at,omitempty"`
	OK               bool   `json:"ok"`
	IPVersion        int    `json:"ip_version,omitempty"`
	Score            *int   `json:"abuse_confidence_score,omitempty"`
	TotalReports     *int   `json:"total_reports,omitempty"`
	DistinctUsers    *int   `json:"num_distinct_users,omitempty"`
	LastReportedAt   string `json:"last_reported_at,omitempty"`
	CountryCode      string `json:"country_code,omitempty"`
	ISP              string `json:"isp,omitempty"`
	UsageType        string `json:"usage_type,omitempty"`
	Domain           string `json:"domain,omitempty"`
	ProviderListed   *bool  `json:"provider_whitelisted,omitempty"`
	Status           int    `json:"http_status,omitempty"`
	ErrorKind        string `json:"error_kind,omitempty"`
	Error            string `json:"error,omitempty"`
	Quota            string `json:"check_quota"`
	NextAllowedAfter string `json:"next_lookup_not_before,omitempty"`
	RecordNote       string `json:"record_note,omitempty"`
	rl               feeds.RateLimitInfo
}

const abuseIPDBCheckCost = "one request against the check endpoint's daily limit (shared with the key test); the blacklist download limit is not used"

// parseAbuseIPDBCheckArgs reads the arguments after `feeds abuseipdb-check`.
func parseAbuseIPDBCheckArgs(args []string) (ip string, maxAge int, asJSON bool, err error) {
	maxAge = feeds.AbuseIPDBCheckMaxAgeDefault
	for i := 0; i < len(args); i++ {
		switch a := args[i]; {
		case a == "--json":
			asJSON = true
		case a == "--max-age-days":
			if i+1 >= len(args) {
				return "", 0, false, errors.New("--max-age-days needs a value\n" + abuseIPDBCheckUsage)
			}
			i++
			n, cerr := strconv.Atoi(args[i])
			if cerr != nil || n < feeds.AbuseIPDBCheckMaxAgeMin || n > feeds.AbuseIPDBCheckMaxAgeMax {
				return "", 0, false, fmt.Errorf("--max-age-days must be a whole number %d-%d\n%s", feeds.AbuseIPDBCheckMaxAgeMin, feeds.AbuseIPDBCheckMaxAgeMax, abuseIPDBCheckUsage)
			}
			maxAge = n
		case strings.HasPrefix(a, "-"):
			return "", 0, false, fmt.Errorf("unknown option %q\n%s", a, abuseIPDBCheckUsage)
		case ip != "":
			return "", 0, false, errors.New("one address per lookup\n" + abuseIPDBCheckUsage)
		default:
			ip = a
		}
	}
	if ip == "" {
		return "", 0, false, errors.New(abuseIPDBCheckUsage)
	}
	return ip, maxAge, asJSON, nil
}

func newAbuseIPDBCheckReport(ip string, maxAge int) abuseIPDBCheckReport {
	return abuseIPDBCheckReport{
		Source:          "AbuseIPDB (API v2 check endpoint)",
		Endpoint:        "GET " + feeds.AbuseIPDBCheckURL + "?ipAddress=" + ip + "&maxAgeInDays=" + strconv.Itoa(maxAge),
		Cost:            abuseIPDBCheckCost,
		InformationOnly: true,
		Effect:          abuseIPDBCheckEffect,
		IP:              ip,
		MaxAgeInDays:    maxAge,
		Quota:           "unknown",
	}
}

func cmdFeedsAbuseIPDBCheck(cfg *nftbanconf.Config) error {
	var args []string
	if len(os.Args) > 3 {
		args = os.Args[3:]
	}
	ipArg, maxAge, asJSON, err := parseAbuseIPDBCheckArgs(args)
	if err != nil {
		return err
	}
	addr, verr := feeds.ValidateLookupIP(ipArg)
	if verr != nil {
		rep := newAbuseIPDBCheckReport("", maxAge)
		rep.Endpoint, rep.Cost, rep.ErrorKind, rep.Error = "none (refused before any request)", "none", "refused_target", verr.Error()
		return finishAbuseIPDBCheck(os.Stdout, rep, asJSON)
	}
	key, kerr := feeds.ReadCredentialFile(abuseIPDBKeyPath(cfg))
	if kerr != nil {
		rep := newAbuseIPDBCheckReport(addr.String(), maxAge)
		rep.Endpoint, rep.Cost, rep.ErrorKind, rep.Error = "none (no usable API key)", "none", "no_key", kerr.Error()
		return finishAbuseIPDBCheck(os.Stdout, rep, asJSON)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	rep := runAbuseIPDBCheck(ctx, nil, "", key, addr, maxAge)
	rep.RecordNote = recordAbuseIPDBCheckQuota(cfg, rep.rl)
	return finishAbuseIPDBCheck(os.Stdout, rep, asJSON)
}

// runAbuseIPDBCheck performs the one request for a validated address and builds the report.
func runAbuseIPDBCheck(ctx context.Context, client *http.Client, baseURL, key string, addr netip.Addr, maxAge int) abuseIPDBCheckReport {
	rep := newAbuseIPDBCheckReport(addr.String(), maxAge)
	queried := time.Now().UTC()
	res, err := feeds.CheckAbuseIPDBAddr(ctx, client, baseURL, key, addr, maxAge)
	if err != nil {
		rep.QueriedAt = queried.Format(time.RFC3339)
		rep.Error = err.Error()
		var pe *feeds.ProviderError
		if errors.As(err, &pe) {
			rep.ErrorKind, rep.Status = pe.Kind, pe.Status
			rep.Quota = quotaText(pe.RateLimit)
			rep.rl = pe.RateLimit
			if !pe.NotBefore.IsZero() {
				rep.NextAllowedAfter = pe.NotBefore.UTC().Format(time.RFC3339)
			}
		}
		return rep
	}
	rep.OK, rep.Status = true, http.StatusOK
	rep.QueriedAt = res.QueriedAt.UTC().Format(time.RFC3339)
	rep.IPVersion = res.IPVersion
	score, total, users := res.AbuseConfidenceScore, res.TotalReports, res.NumDistinctUsers
	rep.Score, rep.TotalReports, rep.DistinctUsers = &score, &total, &users
	rep.LastReportedAt = res.LastReportedAt
	rep.CountryCode, rep.ISP, rep.UsageType, rep.Domain = res.CountryCode, res.ISP, res.UsageType, res.Domain
	rep.ProviderListed = res.IsWhitelisted
	rep.Quota = quotaText(res.RateLimit)
	rep.rl = res.RateLimit
	if res.RateLimit.Known && res.RateLimit.Remaining == 0 && !res.RateLimit.ResetAt.IsZero() {
		rep.NextAllowedAfter = res.RateLimit.ResetAt.UTC().Format(time.RFC3339)
	}
	return rep
}

func finishAbuseIPDBCheck(w io.Writer, rep abuseIPDBCheckReport, asJSON bool) error {
	if asJSON {
		data, err := json.Marshal(rep)
		if err != nil {
			return err
		}
		_, _ = fmt.Fprintln(w, string(data))
	} else {
		printAbuseIPDBCheck(w, rep)
	}
	if !rep.OK {
		return errors.New("AbuseIPDB lookup failed")
	}
	return nil
}

func printAbuseIPDBCheck(w io.Writer, rep abuseIPDBCheckReport) {
	p := func(format string, a ...any) { _, _ = fmt.Fprintf(w, format+"\n", a...) }
	p("AbuseIPDB reputation lookup (information only)")
	if rep.IP != "" {
		p("  Address:        %s", rep.IP)
	}
	p("  Source:         %s", rep.Source)
	p("  Request:        %s", rep.Endpoint)
	p("  Cost:           %s", rep.Cost)
	if rep.QueriedAt != "" {
		p("  Queried at:     %s", rep.QueriedAt)
	}
	if !rep.OK {
		p("  Result:         FAILED: %s", rep.Error)
		if rep.NextAllowedAfter != "" {
			p("  Next lookup allowed: not before %s", rep.NextAllowedAfter)
		} else if rep.ErrorKind == feeds.ErrKindRateLimited {
			p("  Next lookup allowed: unknown (the provider did not state it); do not retry soon")
		}
	} else {
		p("  Confidence:     %d of 100 (AbuseIPDB abuseConfidenceScore)", *rep.Score)
		p("  Reports:        %d from %d distinct users in the last %d days", *rep.TotalReports, *rep.DistinctUsers, rep.MaxAgeInDays)
		if rep.LastReportedAt != "" {
			p("  Last reported:  %s (provider time)", rep.LastReportedAt)
		} else {
			p("  Last reported:  no report in the last %d days", rep.MaxAgeInDays)
		}
		p("  Country:        %s", orNotStated(rep.CountryCode))
		p("  ISP:            %s", orNotStated(rep.ISP))
		p("  Usage type:     %s", orNotStated(rep.UsageType))
		p("  Domain:         %s", orNotStated(rep.Domain))
		switch {
		case rep.ProviderListed == nil:
			p("  AbuseIPDB whitelist: not stated")
		case *rep.ProviderListed:
			p("  AbuseIPDB whitelist: yes (AbuseIPDB's own list; not the NFTBan whitelist)")
		default:
			p("  AbuseIPDB whitelist: no (AbuseIPDB's own list; not the NFTBan whitelist)")
		}
		if rep.NextAllowedAfter != "" {
			p("  Next lookup allowed: not before %s (quota used up)", rep.NextAllowedAfter)
		}
	}
	p("  Check-endpoint quota: %s", rep.Quota)
	if rep.RecordNote != "" {
		p("  Check-endpoint quota %s", rep.RecordNote)
	}
	p("  Effect: %s.", rep.Effect)
}

func orNotStated(s string) string {
	if s == "" {
		return "not stated"
	}
	return s
}
