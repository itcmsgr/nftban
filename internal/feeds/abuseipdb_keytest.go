// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package feeds

// v1.238 part B2: `nftban feeds abuseipdb test` (owner 2026-11-20: standalone, reused by setup).
//
// Endpoint and cost: ONE GET /api/v2/check?ipAddress=127.0.0.1&maxAgeInDays=1. AbuseIPDB counts
// daily limits per endpoint [DOCS: check 1,000/day on the Standard (free) plan], so the test does
// not use a blacklist request. Live L1 (2026-11-21, lab4, one blacklist request): quota reported
// for this key: 10 (X-RateLimit-Limit on the blacklist endpoint). User-facing text states no
// number; status shows the quota the provider reports. The check quota was not measured (the
// owner skipped the key-test call).
//
// The test proves only that the key is accepted. It never writes the snapshot, the refresh record
// or anything else: a successful test cannot make an old enforced list look fresh.

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/url"
	"time"
)

// AbuseIPDBCheckURL is the endpoint the key test calls.
const AbuseIPDBCheckURL = "https://api.abuseipdb.com/api/v2/check"

// KeyTestResult is a successful key test.
type KeyTestResult struct {
	Status    int
	RateLimit RateLimitInfo // the CHECK endpoint's quota (not the blacklist's)
}

// TestAbuseIPDBKey sends the one test request. Errors are *ProviderError (key-free).
func TestAbuseIPDBKey(ctx context.Context, client *http.Client, baseURL, key string) (*KeyTestResult, error) {
	if key == "" {
		return nil, errors.New("abuseipdb: no API key")
	}
	if baseURL == "" {
		baseURL = AbuseIPDBCheckURL
	}
	u, err := url.Parse(baseURL)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil {
		return nil, errors.New("abuseipdb: test endpoint must be an https URL without credentials")
	}
	q := url.Values{}
	q.Set("ipAddress", "127.0.0.1")
	q.Set("maxAgeInDays", "1")
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
	resp, err := c.Do(req)
	if err != nil {
		return nil, &ProviderError{Kind: ErrKindTransport, Detail: redactTransport(err, key)}
	}
	defer func() { _ = resp.Body.Close() }()
	rl := parseRateLimit(resp.Header)
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	switch {
	case resp.StatusCode == http.StatusOK:
		return &KeyTestResult{Status: resp.StatusCode, RateLimit: rl}, nil
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
