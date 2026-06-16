// =============================================================================
// NFTBan v1.21.0 - HTTP Bot Guard: Automated Crawler Detection & Protection
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: botguard
// Purpose: Types and state model for HTTP bot classification
//
// meta:name="botguard_types"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="botguard"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-14"
// meta:description="Core types for kernel-native HTTP bot detection and classification"
//
// Architecture:
//   Kernel (per-packet) → Go (60s/40s classification) → Shell (10min batch)
//   Kernel DETECTS (suspect set), Go DECIDES (allow/ban/grey), Kernel ENFORCES
//
// meta:inventory.files="types.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package botguard

import (
	"net/netip"
	"time"
)

// IPState represents the classification state for an IP address.
// State machine: UNKNOWN → PENDING → ALLOW|GREY|BAN|EMERGENCY
type IPState int

const (
	StateUnknown   IPState = iota // Not yet seen by Go classifier
	StatePending                  // Awaiting classification (light throttle)
	StateAllow                    // Verified allowed crawler (bypass throttle)
	StateGrey                     // Suspicious, throttled via penalty ladder
	StateBan                      // Denied/malicious bot (full drop)
	StateEmergency                // Emergency pressure block (immediate drop)
)

// String returns the human-readable state name.
func (s IPState) String() string {
	switch s {
	case StateUnknown:
		return "unknown"
	case StatePending:
		return "pending"
	case StateAllow:
		return "allow"
	case StateGrey:
		return "grey"
	case StateBan:
		return "ban"
	case StateEmergency:
		return "emergency"
	default:
		return "invalid"
	}
}

// SetName returns the nftables set name for this state (IPv4).
// Returns empty string for states that don't map to a set.
func (s IPState) SetName() string {
	switch s {
	case StatePending:
		return "http_bot_pending"
	case StateAllow:
		return "http_bot_allow"
	case StateGrey:
		return "http_bot_grey"
	case StateBan:
		return "http_bot_ban"
	case StateEmergency:
		return "http_bot_emergency"
	default:
		return ""
	}
}

// SetName6 returns the nftables set name for this state (IPv6).
func (s IPState) SetName6() string {
	name := s.SetName()
	if name == "" {
		return ""
	}
	return name + "6"
}

// VerifyStatus represents the result of an FCrDNS verification.
type VerifyStatus int

const (
	VerifyNone     VerifyStatus = iota // Not yet verified
	VerifyVerified                     // FCrDNS confirmed: rDNS matches allowed domain + fwd confirms
	VerifyFailed                       // FCrDNS failed: rDNS does not match or fwd mismatch
	VerifyTimeout                      // DNS lookup timed out
	VerifyNoRDNS                       // No reverse DNS record found
)

// String returns the human-readable verify status name.
func (v VerifyStatus) String() string {
	switch v {
	case VerifyNone:
		return "none"
	case VerifyVerified:
		return "verified"
	case VerifyFailed:
		return "failed"
	case VerifyTimeout:
		return "timeout"
	case VerifyNoRDNS:
		return "no_rdns"
	default:
		return "invalid"
	}
}

// BotConfig describes an allowed or known crawler identity.
// Loaded from allowed_crawlers.conf (pipe-delimited).
type BotConfig struct {
	Name       string   // e.g. "GOOGLEBOT"
	Domains    []string // Suffix match domains (e.g. ["googlebot.com", "google.com"])
	VerifyMode string   // Verification method: "fcrdns"
	MaxConn    int      // Max concurrent connections allowed
	MaxRate    string   // nft rate string (e.g. "80/second")
	Burst      int      // nft burst value
}

// ClassifyResult is the decision returned by the Classifier.
type ClassifyResult struct {
	State   IPState      // Target state (allow, ban, grey, pending)
	Reason  string       // Why this decision was made
	BotName string       // Identified bot name (if any)
	Verify  VerifyStatus // FCrDNS verification result
}

// IPRecord tracks the classification state and history for one IP.
type IPRecord struct {
	IP         netip.Addr   // Parsed IP address (IPv4 or IPv6)
	State      IPState      // Current classification
	Score      int32        // Accumulated threat score
	FirstSeen  time.Time    // When first detected as suspect
	LastSeen   time.Time    // Last time seen in suspect set
	ExpiresAt  time.Time    // When current state expires
	HitCount   int64        // Number of times seen in suspect set
	Reasons    []string     // Why this IP was flagged (for logging)
	BotName    string       // Identified bot name (empty if unknown)
	VerifiedAt time.Time    // When FCrDNS verification completed (zero if not verified)
	VerifyStatus VerifyStatus // Result of FCrDNS verification
}

// IsIPv6 returns true if this record tracks an IPv6 address.
func (r *IPRecord) IsIPv6() bool {
	return r.IP.Is6()
}

// Expired returns true if the record has expired.
func (r *IPRecord) Expired() bool {
	if r.ExpiresAt.IsZero() {
		return false
	}
	return time.Now().After(r.ExpiresAt)
}

// GuardStats holds runtime statistics for the bot guard module.
type GuardStats struct {
	TickCount        int64         // Total classification ticks
	SuspectsFound    int64         // Total unique IPs found in suspect set
	Classified       int64         // Total IPs classified
	AllowCount       int64         // IPs classified as allow
	GreyCount        int64         // IPs classified as grey
	BanCount         int64         // IPs classified as ban
	EmergencyCount   int64         // IPs classified as emergency
	PendingCount     int64         // IPs currently pending
	TrackedIPs       int64         // Currently tracked IPs in state map
	LastTickDuration time.Duration // Duration of last tick
	LastTickTime     time.Time     // When last tick completed
	PressureMode     bool          // Whether currently in pressure mode
	VerifyEnqueued        int64         // IPs enqueued for FCrDNS verification
	VerifyCompleted       int64         // FCrDNS verifications completed
	VerifyVerified        int64         // IPs that passed FCrDNS
	VerifyFailed          int64         // IPs that failed FCrDNS
	BatchSignalsProcessed int64         // Batch signals consumed from Clock 3
}

// BatchSignal represents a signal from the shell botscan (Clock 3).
// Written as JSONL to /var/lib/nftban/botguard/batch_signals.jsonl
type BatchSignal struct {
	IP      string   `json:"ip"`      // IP address
	Score   int      `json:"score"`   // Behavioral score (0-100)
	Reasons []string `json:"reasons"` // Why flagged (e.g., "404_flood", "wp_probe")
	Action  string   `json:"action"`  // "ban", "grey", "allow_demote", "allow_extend"
	TS      int64    `json:"ts"`      // Unix timestamp
	// v1.191 8B (Amendment B): structured, additive fields. Old signal lines omit them
	// and stay valid (json omitempty + the Normalized*/Resolved* accessors default safely).
	// The daemon MUST use these structured fields, never text-grep Reasons (see batchsignal.go).
	Family       string `json:"family,omitempty"`        // "ipv4"|"ipv6" (fallback: derived from IP)
	RequestClass string `json:"request_class,omitempty"` // taxonomy (default/invalid -> "mixed")
	Confidence   int    `json:"confidence,omitempty"`    // 0-100, optional
}
