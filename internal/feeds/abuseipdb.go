// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package feeds

// AbuseIPDB API v2 blacklist provider (v1.238, owner decisions D1-D3, D7;
// NFTBAN_ROADMAP/v1238_release/V1238_ABUSEIPDB_API_CONTRACT.md).
//
// This file is the provider library only: request building, one HTTP fetch, response parsing
// and error typing. It never writes files and never touches the firewall; the feed writer
// (nftban-core writeFeedFile) and the feed authority decide what is stored and enforced.
//
// Contract points implemented here:
//   - the key travels ONLY in the `Key` request header (never in the URL, argv, logs or errors);
//   - `Accept: application/json` (D1: JSON, so a truncated body fails to parse);
//   - the configured confidenceMinimum (25-100) and limit are SENT as requested; the effective
//     result is REPORTED (received/accepted counts, observed score range, generatedAt), never
//     inferred: an observed minimum is not the server's threshold, list length is not the plan (D2);
//   - redirects are never followed (the request carries the key);
//   - HTTP 429 is typed with Retry-After / X-RateLimit-Reset so the caller never retries early;
//   - the body is read with a hard size cap; oversize is refused, not truncated.

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
)

// AbuseIPDBDefaultURL is the documented blacklist endpoint (HTTPS only).
const AbuseIPDBDefaultURL = "https://api.abuseipdb.com/api/v2/blacklist"

// Documented parameter bounds and defaults.
const (
	AbuseIPDBConfidenceMin     = 25
	AbuseIPDBConfidenceMax     = 100
	AbuseIPDBDefaultConfidence = 100
	AbuseIPDBDefaultLimit      = 10000
	AbuseIPDBMaxLimit          = 500000
	// AbuseIPDBDefaultMaxBytes caps the response body (a 500k-entry JSON list is well below this).
	AbuseIPDBDefaultMaxBytes int64 = 64 << 20
)

// AbuseIPDBParams are the administrator-configured request parameters.
type AbuseIPDBParams struct {
	ConfidenceMinimum int
	Limit             int
}

// Validate checks the documented bounds. It never adjusts a value silently.
func (p AbuseIPDBParams) Validate() error {
	if p.ConfidenceMinimum < AbuseIPDBConfidenceMin || p.ConfidenceMinimum > AbuseIPDBConfidenceMax {
		return fmt.Errorf("abuseipdb: confidenceMinimum %d outside %d-%d", p.ConfidenceMinimum, AbuseIPDBConfidenceMin, AbuseIPDBConfidenceMax)
	}
	if p.Limit < 1 || p.Limit > AbuseIPDBMaxLimit {
		return fmt.Errorf("abuseipdb: limit %d outside 1-%d", p.Limit, AbuseIPDBMaxLimit)
	}
	return nil
}

// RateLimitInfo is what the provider's X-RateLimit-* headers said. Known=false: no headers
// (reported as unknown, never as 0).
type RateLimitInfo struct {
	Known     bool
	Limit     int
	Remaining int
	ResetAt   time.Time // zero when not supplied
}

// AbuseIPDBResult is one successful fetch, with the effective result reported separately from
// the requested parameters (D2).
type AbuseIPDBResult struct {
	Requested   AbuseIPDBParams
	Entries     []string // canonical addresses, in response order, de-duplicated
	Received    int      // elements in data[]
	Accepted    int      // len(Entries)
	Rejected    int      // invalid or non-global addresses, duplicates
	MinScore    int      // observed; -1 when no entry carried a score
	MaxScore    int      // observed; -1 when no entry carried a score
	GeneratedAt string   // meta.generatedAt as sent; "" when absent
	RateLimit   RateLimitInfo
}

// Provider error kinds.
const (
	ErrKindAuth        = "auth"         // 401/403: key missing, invalid or not allowed
	ErrKindRateLimited = "rate_limited" // 429: do not retry before NotBefore
	ErrKindClient      = "client"       // other 4xx (parameters)
	ErrKindServer      = "server"       // 5xx
	ErrKindRedirect    = "redirect"     // 3xx: never followed with the key attached
	ErrKindMalformed   = "malformed"    // 200 with a body that is not the documented JSON
	ErrKindOversize    = "oversize"     // body larger than the cap
	ErrKindTransport   = "transport"    // network/TLS/timeout
)

// ProviderError is a typed, key-free failure.
type ProviderError struct {
	Kind      string
	Status    int       // HTTP status; 0 for transport errors
	Detail    string    // provider's error detail, sanitized and capped; never contains the key
	NotBefore time.Time // rate_limited: earliest allowed retry (zero when unknown)
	RateLimit RateLimitInfo
}

func (e *ProviderError) Error() string {
	var b strings.Builder
	fmt.Fprintf(&b, "abuseipdb: %s", e.Kind)
	if e.Status != 0 {
		fmt.Fprintf(&b, " (HTTP %d)", e.Status)
	}
	if e.Detail != "" {
		fmt.Fprintf(&b, ": %s", e.Detail)
	}
	if !e.NotBefore.IsZero() {
		fmt.Fprintf(&b, "; retry not before %s", e.NotBefore.UTC().Format(time.RFC3339))
	}
	return b.String()
}

// BuildAbuseIPDBRequest builds the GET request. baseURL must be https. The key is set only as the
// `Key` header.
func BuildAbuseIPDBRequest(ctx context.Context, baseURL, key string, p AbuseIPDBParams) (*http.Request, error) {
	if err := p.Validate(); err != nil {
		return nil, err
	}
	if key == "" {
		return nil, errors.New("abuseipdb: no API key")
	}
	u, err := url.Parse(baseURL)
	if err != nil || u.Scheme != "https" || u.Host == "" {
		return nil, errors.New("abuseipdb: endpoint must be an https URL")
	}
	if u.User != nil {
		return nil, errors.New("abuseipdb: endpoint must not carry credentials")
	}
	q := u.Query()
	q.Del("key") // never let a key reach the URL, even from configuration
	q.Del("Key")
	q.Set("confidenceMinimum", strconv.Itoa(p.ConfidenceMinimum))
	q.Set("limit", strconv.Itoa(p.Limit))
	u.RawQuery = q.Encode()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, errors.New("abuseipdb: cannot build request")
	}
	req.Header.Set("Key", key)
	req.Header.Set("Accept", "application/json")
	return req, nil
}

// FetchAbuseIPDB performs one request. client may be nil (a 60 s client is used). Redirects are
// never followed. maxBytes <= 0 uses AbuseIPDBDefaultMaxBytes.
func FetchAbuseIPDB(ctx context.Context, client *http.Client, baseURL, key string, p AbuseIPDBParams, maxBytes int64) (*AbuseIPDBResult, error) {
	req, err := BuildAbuseIPDBRequest(ctx, baseURL, key, p)
	if err != nil {
		return nil, err
	}
	if maxBytes <= 0 {
		maxBytes = AbuseIPDBDefaultMaxBytes
	}
	c := http.Client{Timeout: 60 * time.Second}
	if client != nil {
		c = *client
	}
	c.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	resp, err := c.Do(req)
	if err != nil {
		return nil, &ProviderError{Kind: ErrKindTransport, Detail: redactTransport(err, key)}
	}
	defer func() { _ = resp.Body.Close() }()
	rl := parseRateLimit(resp.Header)
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxBytes+1))
	if err != nil {
		return nil, &ProviderError{Kind: ErrKindTransport, Status: resp.StatusCode, Detail: "reading the response failed", RateLimit: rl}
	}
	if int64(len(body)) > maxBytes {
		return nil, &ProviderError{Kind: ErrKindOversize, Status: resp.StatusCode, Detail: fmt.Sprintf("response larger than %d bytes", maxBytes), RateLimit: rl}
	}
	switch {
	case resp.StatusCode == http.StatusOK:
		res, perr := ParseAbuseIPDBBlacklist(body)
		if perr != nil {
			return nil, &ProviderError{Kind: ErrKindMalformed, Status: resp.StatusCode, Detail: perr.Error(), RateLimit: rl}
		}
		res.Requested = p
		res.RateLimit = rl
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

type abuseIPDBEntry struct {
	IPAddress            *string `json:"ipAddress"`
	AbuseConfidenceScore *int    `json:"abuseConfidenceScore"`
}

type abuseIPDBBody struct {
	Meta *struct {
		GeneratedAt string `json:"generatedAt"`
	} `json:"meta"`
	Data *[]abuseIPDBEntry `json:"data"`
}

// ParseAbuseIPDBBlacklist parses the documented JSON body: {"meta":{"generatedAt":...},
// "data":[{"ipAddress":..., "abuseConfidenceScore":..., ...}]}. A body without a data array
// (truncated, HTML, error object) is malformed. Invalid, non-global and duplicate addresses are
// counted as rejected, never stored.
func ParseAbuseIPDBBlacklist(body []byte) (*AbuseIPDBResult, error) {
	var b abuseIPDBBody
	dec := json.NewDecoder(strings.NewReader(string(body)))
	if err := dec.Decode(&b); err != nil {
		return nil, errors.New("response is not valid JSON")
	}
	if dec.More() {
		return nil, errors.New("trailing data after the JSON document")
	}
	if b.Data == nil {
		return nil, errors.New("response has no data array")
	}
	res := &AbuseIPDBResult{MinScore: -1, MaxScore: -1}
	if b.Meta != nil {
		res.GeneratedAt = b.Meta.GeneratedAt
	}
	seen := make(map[netip.Addr]bool, len(*b.Data))
	for _, e := range *b.Data {
		res.Received++
		if e.IPAddress == nil {
			res.Rejected++
			continue
		}
		a, err := netip.ParseAddr(strings.TrimSpace(*e.IPAddress))
		if err != nil || a.Zone() != "" {
			res.Rejected++
			continue
		}
		a = a.Unmap()
		if !a.IsGlobalUnicast() || a.IsPrivate() || seen[a] {
			res.Rejected++
			continue
		}
		seen[a] = true
		res.Entries = append(res.Entries, a.String())
		if s := e.AbuseConfidenceScore; s != nil {
			if res.MinScore < 0 || *s < res.MinScore {
				res.MinScore = *s
			}
			if *s > res.MaxScore {
				res.MaxScore = *s
			}
		}
	}
	res.Accepted = len(res.Entries)
	return res, nil
}

func parseRateLimit(h http.Header) RateLimitInfo {
	var r RateLimitInfo
	if v, err := strconv.Atoi(strings.TrimSpace(h.Get("X-RateLimit-Limit"))); err == nil {
		r.Limit, r.Known = v, true
	}
	if v, err := strconv.Atoi(strings.TrimSpace(h.Get("X-RateLimit-Remaining"))); err == nil {
		r.Remaining, r.Known = v, true
	} else if r.Known {
		r.Remaining = -1
	}
	if v, err := strconv.ParseInt(strings.TrimSpace(h.Get("X-RateLimit-Reset")), 10, 64); err == nil && v > 0 {
		r.ResetAt = time.Unix(v, 0).UTC()
	}
	return r
}

// notBefore: the later of Retry-After (seconds) and X-RateLimit-Reset; zero when neither is given
// (the caller then applies its own minimum interval).
func notBefore(h http.Header, rl RateLimitInfo, now time.Time) time.Time {
	var t time.Time
	if v, err := strconv.Atoi(strings.TrimSpace(h.Get("Retry-After"))); err == nil && v >= 0 {
		t = now.Add(time.Duration(v) * time.Second)
	}
	if rl.ResetAt.After(t) {
		t = rl.ResetAt
	}
	return t
}

// errorDetail extracts errors[0].detail from a JSON error body, sanitized: printable ASCII only,
// capped, the key removed. Never echoes raw bodies.
func errorDetail(body []byte, key string) string {
	var e struct {
		Errors []struct {
			Detail string `json:"detail"`
		} `json:"errors"`
	}
	if json.Unmarshal(body, &e) != nil || len(e.Errors) == 0 {
		return ""
	}
	return sanitize(e.Errors[0].Detail, key)
}

func redactTransport(err error, key string) string {
	var ue *url.Error
	if errors.As(err, &ue) {
		err = ue.Err // drop the URL (it carries no key, but keep messages short and stable)
	}
	return sanitize(err.Error(), key)
}

func sanitize(s, key string) string {
	if key != "" {
		s = strings.ReplaceAll(s, key, "[REDACTED]")
	}
	var b strings.Builder
	for _, r := range s {
		if r >= 0x20 && r < 0x7f {
			b.WriteRune(r)
		}
		if b.Len() >= 200 {
			break
		}
	}
	return b.String()
}
