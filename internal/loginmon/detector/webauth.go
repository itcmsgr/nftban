// =============================================================================
// NFTBan v1.179.0 - High-Performance Web Auth Detector (HTTP basic-auth + WordPress login)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: detector
// Purpose: Signal-based AUTHENTICATION-failure detection from web access logs.
//
// meta:name="webauth_detector"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="detector"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-13"
// meta:description="Signal-based web authentication-failure detection (HTTP basic-auth 401 only, WordPress wp-login.php failed credential). OWNS the auth_failure event class on web access logs only — per LOG_SOURCE_OWNERSHIP_AND_MODULE_BOUNDARY_AUDIT.md. Explicitly does NOT own web_abuse events (403 forbidden/deny, xmlrpc floods, wp-login high-rate floods, scanner/probe paths, bad bots) — those belong to BotScan->BotGuard. cPanel /login/ 401 stays owned by PanelDetector (registered first; first-match wins)."
//
// Detection patterns (combined/common access-log format: IP is the first token):
//   - WordPress failed credential: POST /wp-login.php with HTTP 200 (success = 302 redirect;
//     a 200 re-renders the login form = failed). xmlrpc.php is EXCLUDED (web_abuse).
//   - HTTP basic-auth failure: 401 Unauthorized ONLY (apache/nginx). 403 Forbidden is
//     web_abuse (authz deny / scanner / WAF block) — NOT matched. xmlrpc.php EXCLUDED.
//
// meta:inventory.files="webauth.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package detector

import (
	"bytes"
	"net/netip"
)

// Score deltas (REST_401_SCORING_DECISION = CONSERVATIVE_DEFAULT, operator 2026-06-13).
// wp-login failed-credential is a high-confidence auth attack → higher score. Generic/REST
// HTTP 401 is real auth_failure but noisier (logged-out browser/plugin REST 401s) → LOWER
// score so a few incidental 401s do NOT ban quickly, while sustained probing still
// accumulates. Ban threshold (scorer TempBan=45) is unchanged: wp-login 20×3=60 → ~3 hits;
// http-401 8×6=48 → ~6 sustained hits. (Future: make these config-tunable via the module.)
const (
	scoreWPLoginFail = 20 // POST /wp-login.php failed-credential
	scoreHTTP401     = 8  // generic/REST HTTP 401 (conservative)
)

// WebAuthDetector detects authentication failures in web access logs.
// It owns ONLY the auth_failure event class; web_abuse (xmlrpc/floods/scanners/403)
// is intentionally left to BotScan -> BotGuard.
type WebAuthDetector struct {
	sigWpLogin   []byte // "/wp-login.php" (matched in the REQUEST LINE only)
	sigXmlrpc    []byte // "/xmlrpc.php" — EXCLUDED (web_abuse, BotScan-owned)
	sigPost      []byte // "POST " (matched in the REQUEST LINE only)
	sigLoginPath []byte // "/login/" — cPanel access_log path owned by PanelDetector
}

// NewWebAuthDetector creates a new web-auth detector.
func NewWebAuthDetector() *WebAuthDetector {
	return &WebAuthDetector{
		sigWpLogin:   []byte("/wp-login.php"),
		sigXmlrpc:    []byte("/xmlrpc.php"),
		sigPost:      []byte("POST "),
		sigLoginPath: []byte("/login/"),
	}
}

// Name returns the detector identifier.
func (d *WebAuthDetector) Name() string {
	return "webauth"
}

// extractAccessLogIP returns the IP at the start of a combined/common access-log
// line ("IP - user [date] \"...\" status ..."). Handles IPv4 and IPv6.
func extractAccessLogIP(line []byte) (netip.Addr, bool) {
	sp := bytes.IndexByte(line, ' ')
	if sp <= 0 {
		return netip.Addr{}, false
	}
	addr, err := netip.ParseAddr(string(line[:sp]))
	if err != nil {
		return netip.Addr{}, false
	}
	return addr, true
}

// parseRequestAndStatus STRUCTURALLY extracts the request-line content (between the
// first pair of double-quotes: `METHOD path HTTP/x`) and the HTTP status code (the
// numeric token immediately after the request line's closing quote) from a combined
// access-log line: `IP - user [date] "REQUEST" STATUS SIZE "ref" "ua"`.
// This avoids substring pitfalls: the SIZE field can never be read as the status, and
// method/path are checked in the REQUEST LINE only (not the referer/UA). Returns
// (request, status, true) or (nil, 0, false) if the line isn't a parseable access log.
func parseRequestAndStatus(line []byte) (request []byte, status int, ok bool) {
	q1 := bytes.IndexByte(line, '"')
	if q1 < 0 {
		return nil, 0, false
	}
	rel := bytes.IndexByte(line[q1+1:], '"')
	if rel < 0 {
		return nil, 0, false
	}
	q2 := q1 + 1 + rel // index of the closing quote
	req := line[q1+1 : q2]
	// status = first numeric token after the closing quote
	i := q2 + 1
	for i < len(line) && line[i] == ' ' {
		i++
	}
	start := i
	for i < len(line) && line[i] >= '0' && line[i] <= '9' {
		i++
	}
	if i == start {
		return req, 0, false
	}
	n := 0
	for _, c := range line[start:i] {
		n = n*10 + int(c-'0')
	}
	return req, n, true
}

// Detect matches AUTH-failure events only. web_abuse is excluded by design.
func (d *WebAuthDetector) Detect(line []byte) (Verdict, bool) {
	req, status, ok := parseRequestAndStatus(line)
	if !ok {
		return Verdict{}, false
	}
	// xmlrpc (in the REQUEST) is web_abuse (BotScan -> BotGuard), never auth_failure.
	if bytes.Contains(req, d.sigXmlrpc) {
		return Verdict{}, false
	}

	// WordPress failed credential: POST /wp-login.php (in the REQUEST line) with HTTP
	// status 200 (success = 302 redirect; a 200 re-renders the login form = failed).
	// Status is parsed structurally so the bytes-sent field can't be mistaken for it,
	// and method/path are checked in the request line so a referer/UA mentioning
	// /wp-login.php can't false-match. High-rate FLOODS are web_abuse (BotScan), not here.
	if status == 200 && bytes.Contains(req, d.sigPost) && bytes.Contains(req, d.sigWpLogin) {
		if addr, ok := extractAccessLogIP(line); ok {
			return Verdict{IP: addr, Reason: ReasonWordPressWPLogin, ScoreDelta: scoreWPLoginFail, Service: "wordpress"}, true
		}
	}

	// HTTP basic-auth failure: status 401 ONLY. 403 Forbidden is NOT matched — it is
	// authorization/deny (scanner probes, WAF/IP blocks) = web_abuse (BotScan->BotGuard);
	// matching it would make LoginMon a second BotScan. cPanel /login/ 401 stays
	// PanelDetector-owned (registered first); the /login/ guard keeps this correct even
	// if called out of order. Conservative score (REST 401 is noisy — see scoreHTTP401).
	if status == 401 && !bytes.Contains(req, d.sigLoginPath) {
		if addr, ok := extractAccessLogIP(line); ok {
			return Verdict{IP: addr, Reason: ReasonGenericAuthFail, ScoreDelta: scoreHTTP401, Service: "http-auth"}, true
		}
	}

	return Verdict{}, false
}
