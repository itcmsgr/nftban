// =============================================================================
// NFTBan v1.0 - Login Monitor Types
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: loginmon
// Purpose: Smart login monitoring with risk-based scoring (replaces fail2ban)
//
// Architecture:
// - Monitors successful logins (failures added later)
// - Uses GeoIP + reputation feeds + behavioral analysis
// - Detects: new IPs, country changes, bad ASN, credential stuffing
// - Integrates with Suricata + SSH parser + nftban brain
//
// This is what fail2ban CANNOT do: multi-source correlation with risk scoring
// =============================================================================

package loginmon

import (
	"sync"
	"time"
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
	IP            string               // IP address
	Users         map[string]time.Time // All users that logged in from this IP (user -> last seen)
	FailedLogins  int                  // Count of recent failed attempts from this IP
	TotalLogins   int                  // Total successful logins from this IP
	LastCountry   string               // Last known country for this IP
	LastASN       string               // Last known ASN for this IP
	FirstSeen     time.Time            // When we first saw this IP
	LastActivity  time.Time            // Last login attempt (success or fail)
}

// LoginState maintains in-memory state for all users and IPs
type LoginState struct {
	Users map[string]*LoginProfile // User -> profile
	IPs   map[string]*IPProfile    // IP -> profile
	mu    sync.RWMutex             // Protect concurrent access
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
	Score       float64           // Overall risk score (0.0 = safe, 1.0 = maximum risk)
	Factors     map[string]float64 // Individual risk factors and their contributions
	Reason      string            // Human-readable explanation
	Recommended string            // Recommended action (allow, alert, block_short, block_long, block_permanent)
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

	// Risk thresholds
	BlockHighRisk   float64 // Block if risk >= this (default: 0.8)
	BlockMediumRisk float64 // Block if risk >= this (default: 0.6)
	AlertRisk       float64 // Alert if risk >= this (default: 0.4)

	// Ban durations
	HighRiskDuration   time.Duration // Ban duration for high risk (default: 24h)
	MediumRiskDuration time.Duration // Ban duration for medium risk (default: 1h)
	LowRiskDuration    time.Duration // Ban duration for low risk (default: 10m)

	// Behavioral analysis
	NewIPWeight       float64 // Risk weight for new IP (default: 0.3)
	NewCountryWeight  float64 // Risk weight for new country (default: 0.3)
	BadReputationWeight float64 // Risk weight for bad reputation (default: 0.4)
	MultipleUsersWeight float64 // Risk weight for multiple users from same IP (default: 0.2)

	// Time windows
	FailureWindow     time.Duration // Window to count failed attempts (default: 10m)
	ProfileRetention  time.Duration // How long to keep user profiles (default: 30d)

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
		BlockHighRisk:       0.8,
		BlockMediumRisk:     0.6,
		AlertRisk:           0.4,
		HighRiskDuration:    24 * time.Hour,
		MediumRiskDuration:  1 * time.Hour,
		LowRiskDuration:     10 * time.Minute,
		NewIPWeight:         0.3,
		NewCountryWeight:    0.3,
		BadReputationWeight: 0.4,
		MultipleUsersWeight: 0.2,
		FailureWindow:       10 * time.Minute,
		ProfileRetention:    30 * 24 * time.Hour,
		MaxFailedAttempts:   5,
		MaxUsersPerIP:       3,
	}
}
