// =============================================================================
// NFTBan v1.186.0 - Roundcube webmail auth-failure detector (DirectAdmin-only claim)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: detector
//
// meta:name="roundcube_detector"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="detector"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-14"
// meta:description="Signal-based Roundcube webmail interactive auth-failure detection from the Roundcube userlogins.log (log_logins=true). OWNS ONLY the webmail auth_failure event class on that log (source=roundcube, reason 5003) — disjoint from dovecot IMAP/POP3 brute (which logs webmail-proxied logins as rip=localhost = wrong IP), from WebAuth (HTTP 401/wp-login), and from BotScan web_abuse. Matches ONLY 'Failed login for ... from <IP> ...'; 'Successful login ...' never produces a verdict. Contains a MANDATORY public-IP-only guard: never bans loopback/RFC1918/link-local/ULA/multicast/unspecified/malformed IPs, so the fleet-wide binary is safe on proxied panels (cPanel/Plesk) that may log 127.0.0.1, and the dovecot rip=localhost webmail mirror is auto-neutralized. v1.186 claims DirectAdmin/OpenLiteSpeed coverage only (Gate-0 captured); cPanel (per-user log discovery) and Plesk are deferred."
//
// Captured DA sample format (2026-06-14):
//   [14-Jun-2026 10:54:37 +0000]: <0a1b2c3d> Failed login for user@dom from 192.0.2.122 in session 0a1b2c3d4e5f6789 (error: 0)
//   Successful variant (NEVER matched): Successful login for user (ID: 1) from <IP> in session <sid>
//
// meta:inventory.files="roundcube.go"
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

// scoreRoundcubeAuthFail — a failed webmail login is a real credential attempt
// (same risk class as an SSH failed-password, scoreDelta 15). With the scorer
// TempBan threshold at 45, ~3 sustained failures in-window ban; isolated typos do
// not. (Future: make config-tunable via the module, like the webauth scores.)
const scoreRoundcubeAuthFail = 15

// RoundcubeDetector detects webmail interactive auth failures in the Roundcube
// userlogins.log. It owns ONLY the auth_failure event class on that log.
type RoundcubeDetector struct {
	sigFailed    []byte // "Failed login for " — the only line shape we match
	sigSuccess   []byte // "Successful login" — explicit non-match (defense-in-depth)
	sigFrom      []byte // " from " — precedes the client IP
	sigInSession []byte // " in session" — the IP is the token immediately before this
}

// NewRoundcubeDetector creates a new Roundcube webmail-auth detector.
func NewRoundcubeDetector() *RoundcubeDetector {
	return &RoundcubeDetector{
		sigFailed:    []byte("Failed login for "),
		sigSuccess:   []byte("Successful login"),
		sigFrom:      []byte(" from "),
		sigInSession: []byte(" in session"),
	}
}

// Name returns the detector identifier.
func (d *RoundcubeDetector) Name() string {
	return "roundcube"
}

// isPublicLoginIP reports whether addr is a public, bannable client address.
// MANDATORY guard (v1.186): a webmail source must NEVER ban a non-routable IP —
// loopback (127.0.0.0/8, ::1), RFC1918 + RFC4193 ULA (IsPrivate), link-local
// (169.254/16, fe80::/10), multicast, or unspecified. IsGlobalUnicast() already
// excludes loopback/link-local/multicast/unspecified; !IsPrivate() excludes
// RFC1918 and ULA. Invalid addrs are rejected by the !IsValid check.
func isPublicLoginIP(addr netip.Addr) bool {
	return addr.IsValid() && addr.IsGlobalUnicast() && !addr.IsPrivate()
}

// roundcubeExtractIP returns the client IP token from a Roundcube userlogins line.
// Primary anchor: the token immediately before " in session" (the format is
// "... from <IP> in session <sid> ..."), which is robust to a username containing
// " from ". On a proxied panel that logs "from 127.0.0.1 (X-Forwarded-For: <ip>)"
// the token before " in session" is the parenthetical close → ParseAddr fails →
// no verdict (safe no-op; cPanel/Plesk real-IP extraction is deferred to v1.186.x).
func (d *RoundcubeDetector) roundcubeExtractIP(line []byte) (netip.Addr, bool) {
	var tok []byte
	if si := bytes.Index(line, d.sigInSession); si > 0 {
		seg := line[:si]
		if sp := bytes.LastIndexByte(seg, ' '); sp >= 0 && sp+1 < len(seg) {
			tok = seg[sp+1:]
		}
	}
	if len(tok) == 0 {
		// Fallback: first whitespace-delimited token after " from ".
		fi := bytes.Index(line, d.sigFrom)
		if fi < 0 {
			return netip.Addr{}, false
		}
		rest := line[fi+len(d.sigFrom):]
		if end := bytes.IndexByte(rest, ' '); end >= 0 {
			tok = rest[:end]
		} else {
			tok = rest
		}
	}
	addr, err := netip.ParseAddr(string(tok))
	if err != nil {
		return netip.Addr{}, false
	}
	return addr, true
}

// Detect matches ONLY Roundcube failed-login events with a PUBLIC client IP.
func (d *RoundcubeDetector) Detect(line []byte) (Verdict, bool) {
	// Prefilter: only failed webmail logins. "Successful login for ..." does not
	// contain "Failed login for "; the explicit success check is defense-in-depth so
	// a success line can NEVER produce a verdict (hard stop).
	if !bytes.Contains(line, d.sigFailed) {
		return Verdict{}, false
	}
	if bytes.Contains(line, d.sigSuccess) {
		return Verdict{}, false
	}

	addr, ok := d.roundcubeExtractIP(line)
	if !ok {
		return Verdict{}, false // malformed / unparseable IP → no ban (hard stop)
	}

	// MANDATORY public-IP-only guard.
	if !isPublicLoginIP(addr) {
		return Verdict{}, false
	}

	// Username (best-effort): between "Failed login for " and " from ".
	user := ""
	if ui := bytes.Index(line, d.sigFailed); ui >= 0 {
		useg := line[ui+len(d.sigFailed):]
		if uf := bytes.Index(useg, d.sigFrom); uf > 0 {
			user = string(useg[:uf])
		}
	}

	return Verdict{
		IP:         addr,
		Reason:     ReasonRoundcubeAuthFail,
		ScoreDelta: scoreRoundcubeAuthFail,
		User:       user,
		Service:    "roundcube",
	}, true
}
