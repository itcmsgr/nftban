// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package feeds

// v1.239 AbuseIPDB reputation lookup (read-only; plan
// NFTBAN_ROADMAP/v1239_release/V1239_ABUSEIPDB_REPORTING_LOOKUP_PLAN.md §5).
//
// ONE GET /api/v2/check?ipAddress=<ip>&maxAgeInDays=<n> for ONE address. The result is
// information: this file never writes a file, never bans, never whitelists and never touches the
// kernel. It reuses the provider client contract of abuseipdb.go / abuseipdb_keytest.go: the key
// only in the `Key` header, `Accept: application/json`, no redirects, a capped body, typed
// key-free *ProviderError (parseRateLimit / notBefore / errorDetail / redactTransport / sanitize).
//
// Targets are validated before any request: one IPv4 or IPv6 address, no CIDR, no zone, and no
// non-public class (netutil.EnforcementClassReject, the shared address-class authority: loopback,
// unspecified, multicast, link-local, RFC 1918 / ULA, CGNAT, documentation, benchmarking,
// reserved). A refused target is never sent.
//
// Rate limiting: a 429 is typed with NotBefore (Retry-After / X-RateLimit-Reset) and the call is
// never retried here. The check endpoint's quota is shared with `feeds abuseipdb test`.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/netip"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/netutil"
)

// Documented maxAgeInDays bounds of the check endpoint [DOCS: 1-365, default 30].
const (
	AbuseIPDBCheckMaxAgeMin     = 1
	AbuseIPDBCheckMaxAgeMax     = 365
	AbuseIPDBCheckMaxAgeDefault = 30
	abuseIPDBCheckMaxBytes      = 64 << 10
)

// AbuseIPDBCheck is one successful lookup, as the provider stated it. Optional provider fields
// stay empty / nil when not sent (never invented).
type AbuseIPDBCheck struct {
	IPAddress            string // canonical form of the address the provider answered for
	IPVersion            int    // 4 or 6 (from the address, not the provider)
	AbuseConfidenceScore int    // 0-100
	TotalReports         int
	NumDistinctUsers     int
	LastReportedAt       string // as sent; "" when the provider sent null (no report in the window)
	CountryCode          string
	UsageType            string
	ISP                  string
	Domain               string
	IsWhitelisted        *bool // provider's own whitelist flag; nil when null/absent
	MaxAgeInDays         int   // the window that was requested
	QueriedAt            time.Time
	RateLimit            RateLimitInfo // the CHECK endpoint's quota
}

// ValidateLookupIP accepts exactly one public IPv4 or IPv6 address and returns it canonical
// (IPv4-mapped IPv6 is unmapped). Refusals name the cause; input is echoed sanitized.
func ValidateLookupIP(s string) (netip.Addr, error) {
	s = strings.TrimSpace(s)
	shown := sanitize(s, "")
	if s == "" {
		return netip.Addr{}, errors.New("abuseipdb lookup: no address given")
	}
	if strings.Contains(s, "/") {
		return netip.Addr{}, fmt.Errorf("abuseipdb lookup refused: %q is a CIDR range; the lookup takes one address", shown)
	}
	a, err := netip.ParseAddr(s)
	if err != nil {
		return netip.Addr{}, fmt.Errorf("abuseipdb lookup refused: %q is not an IPv4 or IPv6 address", shown)
	}
	if a.Zone() != "" {
		return netip.Addr{}, fmt.Errorf("abuseipdb lookup refused: %q carries an interface zone; give the address without %%zone", shown)
	}
	a = a.Unmap()
	if reject, reason := lookupClassReject(a.String()); reject {
		return netip.Addr{}, fmt.Errorf("abuseipdb lookup refused: %s is not publicly routable (%s address); nothing was sent", a, lookupClassText(reason))
	}
	if !a.IsGlobalUnicast() {
		return netip.Addr{}, fmt.Errorf("abuseipdb lookup refused: %s is not a global unicast address; nothing was sent", a)
	}
	return a, nil
}

// lookupClassReject is the shared address-class authority; a variable only so unit tests can
// accept the documentation ranges (tests use documentation addresses exclusively).
var lookupClassReject = netutil.EnforcementClassReject

func lookupClassText(reason string) string {
	switch reason {
	case "private-or-ula":
		return "private (RFC 1918) or unique-local (fc00::/7)"
	case "reserved-doc-or-cgnat":
		return "documentation, benchmarking, reserved or shared (CGNAT)"
	case "":
		return "non-public"
	default:
		return reason
	}
}

// CheckAbuseIPDB validates ip (ValidateLookupIP) and performs one lookup. client may be nil (30 s
// client); baseURL "" uses AbuseIPDBCheckURL; maxAgeDays 0 uses AbuseIPDBCheckMaxAgeDefault.
func CheckAbuseIPDB(ctx context.Context, client *http.Client, baseURL, key, ip string, maxAgeDays int) (*AbuseIPDBCheck, error) {
	a, err := ValidateLookupIP(ip)
	if err != nil {
		return nil, err
	}
	return CheckAbuseIPDBAddr(ctx, client, baseURL, key, a, maxAgeDays)
}

// CheckAbuseIPDBAddr performs one lookup for an address the caller already validated with
// ValidateLookupIP. It refuses only what can never be queried (invalid or zoned address).
// Errors are key-free; non-transport failures are *ProviderError.
func CheckAbuseIPDBAddr(ctx context.Context, client *http.Client, baseURL, key string, a netip.Addr, maxAgeDays int) (*AbuseIPDBCheck, error) {
	if key == "" {
		return nil, errors.New("abuseipdb: no API key")
	}
	if !a.IsValid() || a.Zone() != "" {
		return nil, errors.New("abuseipdb lookup: invalid address")
	}
	a = a.Unmap()
	if maxAgeDays == 0 {
		maxAgeDays = AbuseIPDBCheckMaxAgeDefault
	}
	if maxAgeDays < AbuseIPDBCheckMaxAgeMin || maxAgeDays > AbuseIPDBCheckMaxAgeMax {
		return nil, fmt.Errorf("abuseipdb lookup: maxAgeInDays %d outside %d-%d", maxAgeDays, AbuseIPDBCheckMaxAgeMin, AbuseIPDBCheckMaxAgeMax)
	}
	if baseURL == "" {
		baseURL = AbuseIPDBCheckURL
	}
	u, err := url.Parse(baseURL)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil {
		return nil, errors.New("abuseipdb: check endpoint must be an https URL without credentials")
	}
	q := url.Values{} // fresh: nothing from configuration (e.g. a key) can reach the URL
	q.Set("ipAddress", a.String())
	q.Set("maxAgeInDays", strconv.Itoa(maxAgeDays))
	u.RawQuery = q.Encode()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, errors.New("abuseipdb: cannot build request")
	}
	req.Header.Set("Key", key)
	req.Header.Set("Accept", "application/json")
	c := http.Client{Timeout: 30 * time.Second}
	if client != nil {
		c = *client
	}
	c.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	queried := time.Now().UTC()
	resp, err := c.Do(req)
	if err != nil {
		return nil, &ProviderError{Kind: ErrKindTransport, Detail: redactTransport(err, key)}
	}
	defer func() { _ = resp.Body.Close() }()
	rl := parseRateLimit(resp.Header)
	body, err := io.ReadAll(io.LimitReader(resp.Body, abuseIPDBCheckMaxBytes+1))
	if err != nil {
		return nil, &ProviderError{Kind: ErrKindTransport, Status: resp.StatusCode, Detail: "reading the response failed", RateLimit: rl}
	}
	if len(body) > abuseIPDBCheckMaxBytes {
		return nil, &ProviderError{Kind: ErrKindOversize, Status: resp.StatusCode, Detail: fmt.Sprintf("response larger than %d bytes", abuseIPDBCheckMaxBytes), RateLimit: rl}
	}
	switch {
	case resp.StatusCode == http.StatusOK:
		res, perr := ParseAbuseIPDBCheck(body, a)
		if perr != nil {
			return nil, &ProviderError{Kind: ErrKindMalformed, Status: resp.StatusCode, Detail: sanitize(perr.Error(), key), RateLimit: rl}
		}
		res.MaxAgeInDays, res.QueriedAt, res.RateLimit = maxAgeDays, queried, rl
		return res, nil
	case resp.StatusCode >= 300 && resp.StatusCode < 400:
		return nil, &ProviderError{Kind: ErrKindRedirect, Status: resp.StatusCode, Detail: "redirect not followed (the request carries the key)", RateLimit: rl}
	case resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden:
		return nil, &ProviderError{Kind: ErrKindAuth, Status: resp.StatusCode, Detail: errorDetail(body, key), RateLimit: rl}
	case resp.StatusCode == http.StatusTooManyRequests:
		return nil, &ProviderError{Kind: ErrKindRateLimited, Status: resp.StatusCode, Detail: errorDetail(body, key),
			NotBefore: notBefore(resp.Header, rl, time.Now()), RateLimit: rl}
	case resp.StatusCode >= 500:
		return nil, &ProviderError{Kind: ErrKindServer, Status: resp.StatusCode, Detail: errorDetail(body, key), RateLimit: rl}
	default:
		return nil, &ProviderError{Kind: ErrKindClient, Status: resp.StatusCode, Detail: errorDetail(body, key), RateLimit: rl}
	}
}

type abuseIPDBCheckBody struct {
	Data *struct {
		IPAddress            *string `json:"ipAddress"`
		IsWhitelisted        *bool   `json:"isWhitelisted"`
		AbuseConfidenceScore *int    `json:"abuseConfidenceScore"`
		CountryCode          *string `json:"countryCode"`
		UsageType            *string `json:"usageType"`
		ISP                  *string `json:"isp"`
		Domain               *string `json:"domain"`
		TotalReports         *int    `json:"totalReports"`
		NumDistinctUsers     *int    `json:"numDistinctUsers"`
		LastReportedAt       *string `json:"lastReportedAt"`
	} `json:"data"`
}

// ParseAbuseIPDBCheck parses the documented check body {"data":{...}}. The answered address must
// be the one asked for; abuseConfidenceScore (0-100), totalReports and numDistinctUsers are
// required. Text fields are sanitized (printable ASCII, capped).
func ParseAbuseIPDBCheck(body []byte, want netip.Addr) (*AbuseIPDBCheck, error) {
	var b abuseIPDBCheckBody
	dec := json.NewDecoder(strings.NewReader(string(body)))
	if err := dec.Decode(&b); err != nil {
		return nil, errors.New("response is not valid JSON")
	}
	if dec.More() {
		return nil, errors.New("trailing data after the JSON document")
	}
	d := b.Data
	if d == nil {
		return nil, errors.New("response has no data object")
	}
	if d.IPAddress == nil {
		return nil, errors.New("response has no ipAddress")
	}
	got, err := netip.ParseAddr(strings.TrimSpace(*d.IPAddress))
	if err != nil || got.Unmap() != want.Unmap() {
		return nil, errors.New("response is for a different address than the one asked for")
	}
	if d.AbuseConfidenceScore == nil || *d.AbuseConfidenceScore < 0 || *d.AbuseConfidenceScore > 100 {
		return nil, errors.New("response has no abuseConfidenceScore in 0-100")
	}
	if d.TotalReports == nil || *d.TotalReports < 0 || d.NumDistinctUsers == nil || *d.NumDistinctUsers < 0 {
		return nil, errors.New("response has no totalReports / numDistinctUsers")
	}
	a := want.Unmap()
	res := &AbuseIPDBCheck{
		IPAddress:            a.String(),
		IPVersion:            6,
		AbuseConfidenceScore: *d.AbuseConfidenceScore,
		TotalReports:         *d.TotalReports,
		NumDistinctUsers:     *d.NumDistinctUsers,
		LastReportedAt:       optText(d.LastReportedAt),
		CountryCode:          optText(d.CountryCode),
		UsageType:            optText(d.UsageType),
		ISP:                  optText(d.ISP),
		Domain:               optText(d.Domain),
		IsWhitelisted:        d.IsWhitelisted,
	}
	if a.Is4() {
		res.IPVersion = 4
	}
	return res, nil
}

func optText(p *string) string {
	if p == nil {
		return ""
	}
	return sanitize(strings.TrimSpace(*p), "")
}
