// =============================================================================
// NFTBan v1.191.0 - HTTP Bot Guard: Structured Batch-Signal Accessors
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: botguard
// Purpose: v1.191 8B (Amendment B) — resolve request_class/family from the STRUCTURED
//          batch-signal fields only; never infer class by grepping the free-text Reasons.
//
// meta:name="botguard_batchsignal"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="botguard"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-16"
// meta:description="Structured request-class/family accessors for BotScan batch signals"
// meta:inventory.files="batchsignal.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package botguard

import "net/netip"

// validRequestClasses is the locked taxonomy carried by batch signals (design §2/§2.5).
var validRequestClasses = map[string]struct{}{
	"static":        {},
	"static404":     {},
	"eshop_fanout":  {},
	"admin_ajax":    {},
	"dynamic_abuse": {},
	"login_api":     {},
	"scanner":       {},
	"mixed":         {},
}

// NormalizedRequestClass returns the structured RequestClass when present and valid,
// otherwise "mixed". It NEVER consults Reasons (no fragile free-text classification).
func (s *BatchSignal) NormalizedRequestClass() string {
	if s == nil {
		return "mixed"
	}
	if _, ok := validRequestClasses[s.RequestClass]; ok {
		return s.RequestClass
	}
	return "mixed"
}

// ResolvedFamily returns the explicit Family when valid ("ipv4"/"ipv6"); otherwise it
// derives the family from the IP as a fallback only; otherwise "unknown".
func (s *BatchSignal) ResolvedFamily() string {
	if s == nil {
		return "unknown"
	}
	switch s.Family {
	case "ipv4", "ipv6":
		return s.Family
	}
	if addr, err := netip.ParseAddr(s.IP); err == nil {
		switch {
		case addr.Is4() || addr.Is4In6():
			return "ipv4"
		case addr.Is6():
			return "ipv6"
		}
	}
	return "unknown"
}
