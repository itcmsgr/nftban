// =============================================================================
// NFTBan - Suricata Inline Exception Mode
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="inline"
// meta:type="package"
// meta:version="1.92.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-16"
// meta:description="Inline Exception Mode: narrow allowlist for first-request protection"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/modules/inline_exceptions.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================

package suricata

import (
	"fmt"
	"strconv"
	"strings"
)

// InlineConfig holds the inline exception mode configuration.
// Parsed from /etc/nftban/modules/inline_exceptions.conf.
type InlineConfig struct {
	Enabled    bool   // INLINE_EXCEPTION_ENABLED (default: false)
	DryRun    bool   // INLINE_EXCEPTION_DRY_RUN (default: false)
	MaxSIDs   int    // INLINE_EXCEPTION_MAX_SIDS (default: 50, hard max: 200)
	RequireEVE bool  // INLINE_REQUIRE_EVE (default: true)
	KillSwitch bool  // NFTBAN_INLINE_DISABLE (global override, default: false)

	// Approved SIDs — explicit allowlist only (INV-S-008, INV-S-009)
	AllowedSIDs []InlineApprovedSID

	// Category gates — SID must also have its category enabled
	CategorySQLi       bool // INLINE_CATEGORY_SQLI
	CategoryExploit    bool // INLINE_CATEGORY_EXPLOIT
	CategoryMalwareHTTP bool // INLINE_CATEGORY_MALWARE_HTTP
	CategoryAuthBypass bool // INLINE_CATEGORY_AUTH_BYPASS

	// Follow-up action after inline drop
	FollowupAction   string // observe | ban_short | ban_long | ban_permanent
	FollowupDuration int    // seconds (default: 86400 = 24h)
}

// InlineApprovedSID represents a single approved SID for inline exception.
type InlineApprovedSID struct {
	SID           int
	Category      string
	Justification string
}

// DefaultInlineConfig returns the default (disabled) inline config.
func DefaultInlineConfig() *InlineConfig {
	return &InlineConfig{
		Enabled:          false,
		DryRun:           false,
		MaxSIDs:          InlineExceptionMaxSIDsDefault,
		RequireEVE:       true,
		KillSwitch:       false,
		AllowedSIDs:      nil,
		CategorySQLi:     false,
		CategoryExploit:  false,
		CategoryMalwareHTTP: false,
		CategoryAuthBypass:  false,
		FollowupAction:   "ban_long",
		FollowupDuration: 86400,
	}
}

// Validate checks the inline config against invariants.
// Returns nil if valid, error describing the violation otherwise.
func (c *InlineConfig) Validate() error {
	// INV-S-013: kill switch overrides everything
	if c.KillSwitch {
		if c.Enabled {
			return fmt.Errorf("%s violation: NFTBAN_INLINE_DISABLE=true but INLINE_EXCEPTION_ENABLED=true — kill switch takes precedence", InvGlobalKillSwitch)
		}
		return nil
	}

	if !c.Enabled {
		return nil // disabled — nothing to validate
	}

	// INV-S-009: SID cap
	if len(c.AllowedSIDs) > c.MaxSIDs {
		return fmt.Errorf("%s violation: %d SIDs in allowlist exceeds max %d",
			InvInlineSIDCap, len(c.AllowedSIDs), c.MaxSIDs)
	}
	if c.MaxSIDs > InlineExceptionMaxSIDsHard {
		return fmt.Errorf("%s violation: MAX_SIDS=%d exceeds hard maximum %d",
			InvInlineSIDCap, c.MaxSIDs, InlineExceptionMaxSIDsHard)
	}

	// INV-S-010: EVE required
	if !c.RequireEVE {
		return fmt.Errorf("%s violation: INLINE_REQUIRE_EVE must be true — inline drops without EVE recording are forbidden",
			InvInlineRequiresEVE)
	}

	// INV-S-008: every SID must have its category enabled
	for _, sid := range c.AllowedSIDs {
		if !c.categoryEnabled(sid.Category) {
			return fmt.Errorf("%s violation: SID %d category %q is not enabled",
				InvInlineAllowlistOnly, sid.SID, sid.Category)
		}
	}

	// Validate follow-up action
	switch c.FollowupAction {
	case "observe", "ban_short", "ban_long", "ban_permanent":
		// valid
	default:
		return fmt.Errorf("invalid INLINE_FOLLOWUP_ACTION: %q (must be observe|ban_short|ban_long|ban_permanent)", c.FollowupAction)
	}

	return nil
}

// IsEffectivelyEnabled returns true only if inline mode is enabled AND
// kill switch is off AND at least one SID is approved.
func (c *InlineConfig) IsEffectivelyEnabled() bool {
	return c.Enabled && !c.KillSwitch && len(c.AllowedSIDs) > 0
}

// IsSIDApproved checks if a specific SID is in the allowlist AND its
// category is enabled (double-gate).
func (c *InlineConfig) IsSIDApproved(sid int) bool {
	if !c.IsEffectivelyEnabled() {
		return false
	}
	for _, s := range c.AllowedSIDs {
		if s.SID == sid && c.categoryEnabled(s.Category) {
			return true
		}
	}
	return false
}

func (c *InlineConfig) categoryEnabled(cat string) bool {
	switch strings.ToLower(cat) {
	case "sqli":
		return c.CategorySQLi
	case "exploit":
		return c.CategoryExploit
	case "malware_http", "malware-http":
		return c.CategoryMalwareHTTP
	case "auth_bypass", "auth-bypass":
		return c.CategoryAuthBypass
	default:
		return false
	}
}

// ParseApprovedSID parses "SID:category:justification" format.
func ParseApprovedSID(s string) (InlineApprovedSID, error) {
	parts := strings.SplitN(s, ":", 3)
	if len(parts) < 2 {
		return InlineApprovedSID{}, fmt.Errorf("invalid SID format %q — expected SID:category:justification", s)
	}
	sid, err := strconv.Atoi(strings.TrimSpace(parts[0]))
	if err != nil {
		return InlineApprovedSID{}, fmt.Errorf("invalid SID number %q: %w", parts[0], err)
	}
	cat := strings.TrimSpace(parts[1])
	just := ""
	if len(parts) > 2 {
		just = strings.TrimSpace(parts[2])
	}
	return InlineApprovedSID{SID: sid, Category: cat, Justification: just}, nil
}
