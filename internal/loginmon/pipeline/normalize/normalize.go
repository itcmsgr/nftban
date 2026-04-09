// =============================================================================
// NFTBan v1.80 - pipeline normalize
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: normalize
// Purpose: Canonicalize NormalizedEvent fields (IP, username, domain).
//
// meta:name="loginmon_pipeline_normalize"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="normalize"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-09"
// meta:description="Canonicalization helpers — IP, user, domain — stdlib only"
//
// meta:inventory.files="normalize.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

// Package normalize canonicalizes NormalizedEvent fields so downstream
// stages (dedup, aggregate) operate on stable, comparable values.
//
// Canonicalization is intentionally narrow:
//
//   - IPv6 addresses are lowercased and ::ffff:v4 is unwrapped to v4.
//   - Usernames are split into Username + Domain when "@" is present.
//   - Empty strings stay empty (no synthetic placeholders).
//
// No DNS lookups. No remote enrichment. No state. The package is pure-function
// and stdlib-only.
package normalize

import (
	"net/netip"
	"strings"

	"github.com/itcmsgr/nftban/internal/loginmon/pipeline/event"
)

// Canonicalize returns a new NormalizedEvent with canonical IP and identity
// fields. The input is not mutated.
func Canonicalize(e event.NormalizedEvent) event.NormalizedEvent {
	out := e
	out.SrcIP = canonicalizeAddr(e.SrcIP)
	out.DstIP = canonicalizeAddr(e.DstIP)
	out.Username, out.Domain = splitUserDomain(e.Username, e.Domain)
	return out
}

// canonicalizeAddr returns the IP in canonical form. Zero value passes
// through unchanged.
func canonicalizeAddr(a netip.Addr) netip.Addr {
	if !a.IsValid() {
		return a
	}
	// Unwrap ::ffff:v4 to plain v4.
	if a.Is4In6() {
		return a.Unmap()
	}
	return a
}

// splitUserDomain populates Domain from Username if Username contains "@"
// and Domain is empty. If Domain is already set, it is preserved unchanged.
//
// "info@example.gr"  ->  ("info@example.gr", "example.gr")
// "info"             ->  ("info", "")
// "info" + "x.gr"    ->  ("info", "x.gr")  (preserved)
func splitUserDomain(user, domain string) (string, string) {
	if domain != "" {
		return user, domain
	}
	if user == "" {
		return "", ""
	}
	at := strings.LastIndexByte(user, '@')
	if at < 0 {
		return user, ""
	}
	return user, user[at+1:]
}
