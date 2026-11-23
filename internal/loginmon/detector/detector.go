// =============================================================================
// NFTBan v1.0.30 - High-Performance Login Detector Interface
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// Package: detector
// Purpose: Signal-based detection with zero-copy hot path
//
// meta:name="detector"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="detector"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-12"
// meta:description="High-performance login detector interface with signal-based detection"
//
// Architecture:
// - bytes.Contains prefilter (SIMD-accelerated) before expensive parsing
// - []byte slicing for zero-copy on non-match lines
// - netip.Addr for modern IPv4/IPv6 handling
// - Modular detector interface for easy extension
//
// Performance Target: 100,000+ lines/sec (100x improvement over regex)
//
// meta:inventory.files="detector.go,ssh.go"
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

// Reason codes for different detection types (stable enum values)
const (
	ReasonSSHFailedPassword    uint16 = 1001
	ReasonSSHInvalidUser       uint16 = 1002
	ReasonSSHPreauth           uint16 = 1003
	ReasonSSHTooManyFailures   uint16 = 1004
	ReasonSSHRootAttempt       uint16 = 1005
	ReasonDovecotAuthFail      uint16 = 2001
	ReasonPostfixSASL          uint16 = 2002
	ReasonEximAuthFail         uint16 = 2003
	ReasonDovecotPamFail       uint16 = 2004
	ReasonFTPAuthFail          uint16 = 3001
	ReasonDirectAdminLogin     uint16 = 4001
	ReasonCPanelLogin          uint16 = 4002
	ReasonWordPressXMLRPC      uint16 = 5001
	ReasonWordPressWPLogin     uint16 = 5002
	ReasonRoundcubeAuthFail    uint16 = 5003
	ReasonPleskLogin           uint16 = 4003
	ReasonGenericAuthFail      uint16 = 9001
)

// ReasonName maps reason codes to human-readable names
var ReasonName = map[uint16]string{
	ReasonSSHFailedPassword:  "ssh_failed_password",
	ReasonSSHInvalidUser:     "ssh_invalid_user",
	ReasonSSHPreauth:         "ssh_preauth_disconnect",
	ReasonSSHTooManyFailures: "ssh_too_many_failures",
	ReasonSSHRootAttempt:     "ssh_root_attempt",
	ReasonDovecotAuthFail:    "dovecot_auth_fail",
	ReasonPostfixSASL:        "postfix_sasl_fail",
	ReasonEximAuthFail:       "exim_auth_fail",
	ReasonDovecotPamFail:     "dovecot_pam_fail",
	ReasonFTPAuthFail:        "ftp_auth_fail",
	ReasonDirectAdminLogin:   "directadmin_login_fail",
	ReasonCPanelLogin:        "cpanel_login_fail",
	ReasonWordPressXMLRPC:    "wordpress_xmlrpc",
	ReasonWordPressWPLogin:   "wordpress_wp_login",
	ReasonRoundcubeAuthFail:  "roundcube_auth_fail",
	ReasonPleskLogin:         "plesk_login_fail",
	ReasonGenericAuthFail:    "generic_auth_fail",
}

// Verdict represents the result of a detection match
type Verdict struct {
	IP         netip.Addr // Parsed IP address (IPv4 or IPv6)
	Reason     uint16     // Stable enum code for the detection reason
	ScoreDelta int16      // Points to add to the IP's risk score (scaled by 100)
	User       string     // Optional: username involved (empty if not extracted)
	Service    string     // Service name (ssh, dovecot, etc.)

	// Success marks a CONFIRMED successful login (v1.238, owner 2026-11-21: a good login must
	// be heard, so one later typo cannot escalate). A success verdict carries no score; the
	// scorer clears the IP's accumulated score (at most once per IP per window) and NEVER
	// lifts an existing ban. Detectors emit it only from a line whose MESSAGE START is the
	// service's success phrase (attacker-chosen usernames appear later in the line), and only
	// after every failure check of that detector has not matched.
	Success bool
}

// messageAfterTag splits a log line at its FIRST ": " into the header/tag and the message:
// syslog "Nov 21 10:01:00 host sshd[1]: <msg>", journal short-iso "2026-...+0200 host
// sshd[1]: <msg>", DirectAdmin "2026:04:04-13:00:00: <msg>", Roundcube "[date]: <msg>". The
// header is written by the logger, never by the client, so a phrase required at the START
// of the message cannot be forged through a username (which always comes later).
func messageAfterTag(line []byte) (tag, msg []byte, ok bool) {
	i := bytes.Index(line, []byte(": "))
	if i < 0 {
		return nil, nil, false
	}
	return line[:i], line[i+2:], true
}

// Detector is the interface for all login failure detectors
// Each detector implements signal-based detection:
// 1. Cheap prefilter (bytes.Contains) to skip non-matching lines
// 2. Precise extraction only on matching lines
type Detector interface {
	// Name returns the detector identifier
	Name() string

	// Detect checks if a log line matches this detector's patterns
	// Returns (verdict, true) if matched, (zero, false) if not
	// The line is passed as []byte to enable zero-copy processing
	Detect(line []byte) (Verdict, bool)
}

// Registry holds all registered detectors
type Registry struct {
	detectors []Detector
}

// NewRegistry creates a new detector registry with default detectors
func NewRegistry() *Registry {
	r := &Registry{
		detectors: make([]Detector, 0, 8),
	}

	// Register default detectors in priority order
	r.Register(NewSSHDetector())
	r.Register(NewMailDetector())
	r.Register(NewFTPDetector())
	r.Register(NewPanelDetector())
	// WebAuth registered AFTER Panel so cPanel /login/ 401 stays PanelDetector-owned
	// (first-match wins). WebAuth owns only generic HTTP basic-auth 401/403 + WordPress
	// wp-login failed-credential (auth_failure); web_abuse stays with BotScan->BotGuard.
	r.Register(NewWebAuthDetector())
	// Roundcube webmail userlogins.log "Failed login for <user> from <IP> …" (v1.186,
	// DirectAdmin-only coverage claim). Owns ONLY webmail interactive auth_failure on
	// the Roundcube userlogins log; tight prefilter cannot match access/mail/ssh lines.
	// Contains a MANDATORY public-IP-only guard (never bans loopback/RFC1918/link-local/
	// ULA/malformed) so the fleet-wide binary is safe on proxied panels that may log
	// 127.0.0.1, and the dovecot rip=localhost webmail mirror is auto-neutralized.
	r.Register(NewRoundcubeDetector())

	return r
}

// Register adds a detector to the registry
func (r *Registry) Register(d Detector) {
	r.detectors = append(r.detectors, d)
}

// Detect runs all registered detectors on a line
// Returns on first match (detectors are ordered by likelihood)
func (r *Registry) Detect(line []byte) (Verdict, bool) {
	for _, d := range r.detectors {
		if v, ok := d.Detect(line); ok {
			return v, true
		}
	}
	return Verdict{}, false
}

// DetectAll runs all detectors and returns all matches
// Useful for hybrid mode where multiple signals may be present
func (r *Registry) DetectAll(line []byte) []Verdict {
	var results []Verdict
	for _, d := range r.detectors {
		if v, ok := d.Detect(line); ok {
			results = append(results, v)
		}
	}
	return results
}

// Detectors returns the list of registered detector names
func (r *Registry) Detectors() []string {
	names := make([]string, len(r.detectors))
	for i, d := range r.detectors {
		names[i] = d.Name()
	}
	return names
}
