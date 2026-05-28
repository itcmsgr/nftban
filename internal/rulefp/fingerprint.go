// =============================================================================
// NFTBan - Ruleset fingerprint (SEC-RULEFP, v1.138 PR-A)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="rulefp"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-27"
// meta:description="Canonical nftban ruleset fingerprint: normalize the nftban table ruleset text (strip volatile counters/handles/timestamps and dynamic-set elements; preserve structural rule text, chains, policies, hooks, priorities) and digest it, so an injected rule or chain-policy flip is detectable while normal counter/ban churn is not. Used by the apply-time baseline capture and the verify-rules mechanism."
// meta:input="nft list table ip/ip6 nftban ruleset text"
// meta:output="normalized text + sha256 digest"
// meta:depends="crypto/sha256,encoding/hex,regexp,strings"
// meta:inventory.files=""
// meta:inventory.binaries="nft"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package rulefp

import (
	"crypto/sha256"
	"encoding/hex"
	"regexp"
	"strings"
)

// Volatile fragments that must NOT contribute to the fingerprint — they change
// during normal operation without any structural rule change.
var (
	// "counter packets 12 bytes 340" → counters tick on every match.
	reCounter = regexp.MustCompile(`packets \d+ bytes \d+`)
	// "last used 1234" / "expires 30s" style volatile time fields.
	reLastUsed = regexp.MustCompile(`\blast used \d+`)
	reExpires  = regexp.MustCompile(`\bexpires \d+[a-z]*`)
	// "# handle 17" — only present with `nft -a`; we fetch without -a, but strip
	// defensively so the digest is stable regardless of how the text was produced.
	reHandle = regexp.MustCompile(`\s*#\s*handle \d+`)
)

// Normalize canonicalizes nftban-table ruleset text for fingerprinting.
//
// It STRIPS volatile content (packet/byte counters, rule handles, last-used /
// expires timers, and the contents of dynamic set/map `elements = { … }` blocks
// — ban/unban churn) while PRESERVING the structural skeleton: table/chain
// declarations, chain type/hook/priority/policy, and every static rule body.
//
// Consequences (the SEC-RULEFP detection contract):
//   - an injected rule (e.g. `ip saddr 1.2.3.4 accept`) is a chain rule line →
//     preserved → digest changes → DETECTED.
//   - a chain-policy flip (`policy drop;` → `policy accept;`) is in the chain
//     header → preserved → digest changes → DETECTED.
//   - counter ticks, banned-IP set churn, and timer drift → stripped → digest
//     UNCHANGED (no false positive).
func Normalize(rulesetText string) string {
	lines := strings.Split(rulesetText, "\n")
	out := make([]string, 0, len(lines))
	inElements := false

	for _, ln := range lines {
		ln = reHandle.ReplaceAllString(ln, "")

		// Inside a multi-line dynamic element block: skip until its closing brace.
		if inElements {
			if strings.Contains(ln, "}") {
				inElements = false
			}
			continue
		}

		if idx := strings.Index(ln, "elements = {"); idx >= 0 {
			prefix := strings.TrimRight(stripVolatile(ln[:idx]), " \t")
			out = append(out, prefix+"elements = { ... }")
			// Multi-line block unless the closing brace is on this same line.
			if !strings.Contains(ln[idx:], "}") {
				inElements = true
			}
			continue
		}

		t := strings.TrimRight(stripVolatile(ln), " \t")
		if strings.TrimSpace(t) == "" {
			continue
		}
		out = append(out, t)
	}

	return strings.Join(out, "\n")
}

func stripVolatile(s string) string {
	s = reCounter.ReplaceAllString(s, "packets 0 bytes 0")
	s = reLastUsed.ReplaceAllString(s, "last used 0")
	s = reExpires.ReplaceAllString(s, "expires 0")
	return s
}

// Digest returns the hex sha256 of the normalized ruleset.
func Digest(rulesetText string) string {
	sum := sha256.Sum256([]byte(Normalize(rulesetText)))
	return hex.EncodeToString(sum[:])
}
