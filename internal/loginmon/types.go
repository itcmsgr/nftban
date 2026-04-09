// =============================================================================
// NFTBan v1.0.30 - Login Monitor Types
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: loginmon
// Purpose: Smart login monitoring with risk-based scoring (replaces fail2ban)
//
// meta:name="loginmon_types"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="loginmon"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-12"
// meta:description="Login monitor types and configuration structures"
//
// Architecture:
// - Monitors successful logins (failures added later)
// - Uses GeoIP + reputation feeds + behavioral analysis
// - Detects: new IPs, country changes, bad ASN, credential stuffing
// - Integrates with Suricata + SSH parser + nftban brain
//
// Multi-source correlation with risk scoring for automated threat detection
//
// meta:inventory.files="types.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package loginmon

import (
	"sync"
	"time"

	"github.com/itcmsgr/nftban/internal/constants"
)

// LoginEvent represents a single login attempt (success or failure)
type LoginEvent struct {
	User      string            // Username that logged in
	IP        string            // Source IP address
	Time      time.Time         // When the login occurred
	Service   string            // Service name (ssh, directadmin, webmail, panel, etc.)
	Success   bool              // true = successful login, false = failed attempt
	Method    string            // Auth method (password, publickey, session, etc.)
	Extra     map[string]string // Additional metadata (port, protocol, etc.)
	Timestamp int64             // Unix timestamp for correlation
}

// LoginProfile tracks historical behavior for a single user
type LoginProfile struct {
	User          string               // Username
	LastIP        string               // Last IP this user logged in from
	LastCountry   string               // Last country (from GeoIP)
	LastASN       string               // Last ASN (ISP/provider)
	LastLoginTime time.Time            // Last successful login timestamp
	KnownIPs      map[string]time.Time // All IPs this user has logged in from (IP -> last seen)
	FailedLogins  int                  // Count of recent failed attempts
	TotalLogins   int                  // Total successful logins
	FirstSeen     time.Time            // When we first saw this user
}

// IPProfile tracks login activity from a single IP
type IPProfile struct {
	IP           string               // IP address
	Users        map[string]time.Time // All users that logged in from this IP (user -> last seen)
	FailedLogins int                  // Count of recent failed attempts from this IP
	TotalLogins  int                  // Total successful logins from this IP
	LastCountry  string               // Last known country for this IP
	LastASN      string               // Last known ASN for this IP
	FirstSeen    time.Time            // When we first saw this IP
	LastActivity time.Time            // Last login attempt (success or fail)
}

// LoginState maintains in-memory state for all users and IPs
type LoginState struct {
	Users map[string]*LoginProfile // User -> profile
	IPs   map[string]*IPProfile    // IP -> profile
	_     sync.RWMutex             // Reserved for future concurrent access protection
}

// GeoInfo contains geographic/network information for an IP
type GeoInfo struct {
	Country     string // ISO country code (e.g., "US", "CN", "RU")
	CountryName string // Human-readable country name
	City        string // City name (optional)
	ASN         string // Autonomous System Number (ISP identifier)
	ASNOrg      string // Organization name for the ASN
	IsProxy     bool   // Known proxy/VPN/Tor exit node
	IsTor       bool   // Known Tor exit node
	IsHosting   bool   // Hosting provider (often used for bots)
}

// ReputationInfo contains threat intelligence for an IP
type ReputationInfo struct {
	BadFeeds      int       // Number of threat feeds containing this IP
	SuricataHits  int       // Number of Suricata alerts for this IP
	NFTBanHistory int       // Number of times previously banned by NFTBan
	LastBanTime   time.Time // When this IP was last banned
	BanReason     string    // Reason for last ban (ssh_brute, web_exploit, etc.)
	IsWhitelisted bool      // Is this IP in the whitelist?
}

// RiskScore represents the computed risk level for a login event
type RiskScore struct {
	Score       float64            // Overall risk score (0.0 = safe, 1.0 = maximum risk)
	Factors     map[string]float64 // Individual risk factors and their contributions
	Reason      string             // Human-readable explanation
	Recommended string             // Recommended action (allow, alert, block_short, block_long, block_permanent)
}

// Action represents a decision made by the login monitor
type Action struct {
	Type     string        // Action type: "allow", "alert_only", "block_short", "block_long", "block_permanent"
	IP       string        // IP to act on
	Duration time.Duration // Ban duration (0 = permanent)
	Reason   string        // Why this action was taken
	Risk     float64       // Risk score that triggered this action
	Event    *LoginEvent   // The login event that caused this action
}

// Config contains configuration for the login monitor
type Config struct {
	// Module control
	Enabled bool // Whether the module is enabled (default: true)

	// v1.80 Phase B: Go pipeline feature flag.
	// When true, the Go pipeline runs DirectAdmin parser IN ADDITION to the
	// legacy tail -F watcher. Both paths produce events; dedup prevents
	// double-counting. When false (default), only the legacy path runs.
	// Set via PIPELINE_ENABLED=true in main.conf.local.
	PipelineEnabled bool

	// ==========================================================================
	// SCORER THRESHOLDS (configurable via /etc/nftban/conf.d/login/scorer.conf)
	// ==========================================================================

	// Ban thresholds - score needed to trigger ban (scale: 0-100)
	// Example: ThresholdTempBan=45 means ban when score >= 45
	ThresholdTempBan   int32 // Score to trigger temp ban (default: 45)
	ThresholdEscalate  int32 // Score to escalate ban (default: 65)
	ThresholdPermanent int32 // Score for permanent ban (default: 100)

	// Ban durations
	TempBanDuration   time.Duration   // Initial temp ban (default: 15m)
	EscalateDurations []time.Duration // Escalation ladder: 2h, 4h, 12h, 24h

	// Score decay (reduces score over time if no new failures)
	ScoreDecayInterval time.Duration // How often to decay scores (default: 5m)
	ScoreDecayAmount   int32         // Points to decay per interval (default: 5)

	// IP retention (how long to remember an IP after last activity)
	IPRetentionDuration time.Duration // How long to keep IP data (default: 24h)

	// ==========================================================================
	// PER-SERVICE SCORE DELTAS (configurable via /etc/nftban/conf.d/login/*.conf)
	// ==========================================================================
	// How many points to add per detection for each service/reason

	// SSH scores
	SSHFailedPassword int16 // Score for "Failed password" (default: 10)
	SSHInvalidUser    int16 // Score for invalid user attempt (default: 15)
	SSHPreauth        int16 // Score for preauth disconnect (default: 20)
	SSHTooMany        int16 // Score for "too many failures" (default: 30)
	SSHRootAttempt    int16 // Bonus score for root attempts (default: 10)

	// Mail scores
	DovecotAuthFail int16 // Score for Dovecot native auth failure (default: 15)
	DovecotPamFail  int16 // Score for Dovecot PAM auth failure (default: 15)
	PostfixSASL     int16 // Score for Postfix SASL failure (default: 15)
	EximAuthFail    int16 // Score for Exim auth failure (default: 15)

	// FTP scores
	FTPAuthFail int16 // Score for FTP auth failure (default: 15)

	// Panel scores
	DirectAdminLogin int16 // Score for DirectAdmin login failure (default: 20)
	CPanelLogin      int16 // Score for cPanel login failure (default: 20)
	PleskLogin       int16 // Score for Plesk login failure (default: 20)

	// WordPress scores
	WordPressXMLRPC  int16 // Score for WordPress xmlrpc attack (default: 25)
	WordPressWPLogin int16 // Score for wp-login brute force (default: 20)

	// ==========================================================================
	// LEGACY RISK-BASED CONFIG (for compatibility)
	// ==========================================================================

	// Risk thresholds
	BlockHighRisk   float64 // Block if risk >= this (default: 0.8)
	BlockMediumRisk float64 // Block if risk >= this (default: 0.6)
	AlertRisk       float64 // Alert if risk >= this (default: 0.4)

	// Ban durations (risk-based)
	HighRiskDuration   time.Duration // Ban duration for high risk (default: 24h)
	MediumRiskDuration time.Duration // Ban duration for medium risk (default: 1h)
	LowRiskDuration    time.Duration // Ban duration for low risk (default: 10m)

	// Behavioral analysis weights
	NewIPWeight         float64 // Risk weight for new IP (default: 0.3)
	NewCountryWeight    float64 // Risk weight for new country (default: 0.3)
	BadReputationWeight float64 // Risk weight for bad reputation (default: 0.4)
	MultipleUsersWeight float64 // Risk weight for multiple users from same IP (default: 0.2)

	// Time windows
	FailureWindow    time.Duration // Window to count failed attempts (default: 10m)
	ProfileRetention time.Duration // How long to keep user profiles (default: 30d)

	// Thresholds
	MaxFailedAttempts int // Max failed attempts before blocking (default: 5)
	MaxUsersPerIP     int // Max different users from same IP before suspicious (default: 3)
}

// NewLoginState creates a new login monitor state
func NewLoginState() *LoginState {
	return &LoginState{
		Users: make(map[string]*LoginProfile),
		IPs:   make(map[string]*IPProfile),
	}
}

// DefaultConfig returns default configuration
func DefaultConfig() *Config {
	return &Config{
		Enabled: true,

		// Scorer thresholds
		ThresholdTempBan:    45,
		ThresholdEscalate:   65,
		ThresholdPermanent:  100,
		TempBanDuration:     constants.LoginmonTempBanDuration,
		EscalateDurations:   []time.Duration{2 * time.Hour, 4 * time.Hour, 12 * time.Hour, 24 * time.Hour},
		ScoreDecayInterval:  constants.LoginmonScoreDecayInterval,
		ScoreDecayAmount:    5,
		IPRetentionDuration: constants.LoginmonIPRetention,

		// Per-service score deltas (defaults)
		SSHFailedPassword: 10,
		SSHInvalidUser:    15,
		SSHPreauth:        20,
		SSHTooMany:        30,
		SSHRootAttempt:    10,
		DovecotAuthFail:   15,
		DovecotPamFail:    15,
		PostfixSASL:       15,
		EximAuthFail:      15,
		FTPAuthFail:       15,
		DirectAdminLogin:  20,
		CPanelLogin:       20,
		PleskLogin:        20,
		WordPressXMLRPC:   25,
		WordPressWPLogin:  20,

		// Legacy risk-based defaults
		BlockHighRisk:       0.8,
		BlockMediumRisk:     0.6,
		AlertRisk:           0.4,
		HighRiskDuration:    constants.LoginmonHighRiskDuration,
		MediumRiskDuration:  constants.LoginmonMediumRiskDuration,
		LowRiskDuration:     constants.LoginmonLowRiskDuration,
		NewIPWeight:         0.3,
		NewCountryWeight:    0.3,
		BadReputationWeight: 0.4,
		MultipleUsersWeight: 0.2,
		FailureWindow:       constants.LoginmonFailureWindow,
		ProfileRetention:    constants.LoginmonProfileRetention,
		MaxFailedAttempts:   5,
		MaxUsersPerIP:       3,
	}
}
