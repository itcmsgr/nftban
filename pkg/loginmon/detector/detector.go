// =============================================================================
// NFTBan v1.0.30 - High-Performance Login Detector Interface
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
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
	ReasonFTPAuthFail          uint16 = 3001
	ReasonDirectAdminLogin     uint16 = 4001
	ReasonCPanelLogin          uint16 = 4002
	ReasonWordPressXMLRPC      uint16 = 5001
	ReasonWordPressWPLogin     uint16 = 5002
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
	ReasonFTPAuthFail:        "ftp_auth_fail",
	ReasonDirectAdminLogin:   "directadmin_login_fail",
	ReasonCPanelLogin:        "cpanel_login_fail",
	ReasonWordPressXMLRPC:    "wordpress_xmlrpc",
	ReasonWordPressWPLogin:   "wordpress_wp_login",
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
