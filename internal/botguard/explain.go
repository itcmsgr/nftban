// =============================================================================
// NFTBan v1.191.0 - HTTP Bot Guard: Read-only decision-cache explain/query API
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: botguard
// Purpose: v1.191 8B (increment 6A) — daemon-side READ-ONLY explain/query for an IP's
//          TEMPORARY BotGuard decision-cache state. Side-effect-free (Peek only): never
//          creates, transitions, refreshes, enqueues, or enforces anything. Reports ONLY
//          temporary cache state and makes NO durable whitelist/blacklist claim — durable
//          nft-set truth is a separate concern (shell/direct-nft, increment 6B). No CLI
//          surfaces are wired here.
//
// meta:name="botguard_explain"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="botguard"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-16"
// meta:description="Read-only explain/query model + method for the BotGuard temporary decision cache"
// meta:inventory.files="explain.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package botguard

import (
	"context"
	"net/netip"
	"time"

	"github.com/itcmsgr/nftban/internal/botguard/decisioncache"
)

// ExplainSource identifies this read-only report as coming from the temporary cache.
const ExplainSource = "botguard_decision_cache"

// ExplainResponse is the READ-ONLY explanation of an IP's TEMPORARY BotGuard decision-cache
// state. It deliberately carries ONLY temporary cache state. It exposes NO durable
// whitelist/blacklist booleans and makes no safe/not-banned claim — DurableAuthority is
// always "not_evaluated", and absence is explicitly not proof of anything (see Note).
type ExplainResponse struct {
	IP               string `json:"ip"`
	Family           string `json:"family,omitempty"`
	RequestClass     string `json:"request_class,omitempty"`
	Host             string `json:"host,omitempty"`
	State            string `json:"state"`     // temporary state; "unknown" when absent; "unavailable" when degraded
	Temporary        bool   `json:"temporary"` // always true — this API never reports durable state
	Present          bool   `json:"present"`   // a live cache entry exists for this IP
	Reason           string `json:"reason,omitempty"`
	EvidenceSummary  string `json:"evidence_summary,omitempty"`
	FirstSeen        string `json:"first_seen,omitempty"` // RFC3339, display only
	LastSeen         string `json:"last_seen,omitempty"`  // RFC3339, display only
	ExpiresAt        string `json:"expires_at,omitempty"` // RFC3339, display only
	TTLRemainingMS   int64  `json:"ttl_remaining_ms"`
	CacheAvailable   bool   `json:"cache_available"`   // false on nil cache / context error / degrade
	DurableAuthority string `json:"durable_authority"` // always "not_evaluated" — no durable claim here
	Source           string `json:"source"`            // ExplainSource
	Note             string `json:"note,omitempty"`
}

const explainNote = "temporary BotGuard cache only; absence is NOT proof of not-banned; durable whitelist/blacklist truth is separate"

// ExplainIP returns the TEMPORARY decision-cache state for ip. It is READ-ONLY and
// side-effect-free: it uses Peek (no purge, no transition, no TTL refresh, no enqueue, no
// enforcement) and never reports or claims durable authority. It honors the context budget and
// DEGRADES (CacheAvailable=false, State="unavailable") on a nil cache or a context error,
// WITHOUT implying the IP is safe/not-banned.
func (m *Module) ExplainIP(ctx context.Context, ip netip.Addr) ExplainResponse {
	ip = ip.Unmap()
	resp := ExplainResponse{
		IP:               ip.String(),
		Temporary:        true,
		State:            string(decisioncache.StateUnknown),
		DurableAuthority: "not_evaluated",
		Source:           ExplainSource,
		Note:             explainNote,
	}

	// Degrade cleanly on a cancelled/expired context — never imply safe.
	if ctx != nil && ctx.Err() != nil {
		resp.CacheAvailable = false
		resp.State = "unavailable"
		return resp
	}
	if m.decisionCache == nil {
		resp.CacheAvailable = false
		resp.State = "unavailable"
		return resp
	}

	resp.CacheAvailable = true
	// Exact single-IP lookup via Peek (read-only; expired entries report absent, not purged).
	rec, ok := m.decisionCache.Peek(ip)
	if !ok {
		resp.Present = false // State stays "unknown" — absent, NOT "safe"
		return resp
	}

	resp.Present = true
	resp.Family = rec.Family
	resp.RequestClass = rec.RequestClass
	resp.Host = rec.Host
	resp.State = string(rec.State)
	resp.Reason = rec.Reason
	resp.EvidenceSummary = rec.EvidenceSummary
	if !rec.FirstSeen.IsZero() {
		resp.FirstSeen = rec.FirstSeen.Format(time.RFC3339)
	}
	if !rec.LastSeen.IsZero() {
		resp.LastSeen = rec.LastSeen.Format(time.RFC3339)
	}
	if !rec.ExpiresAt.IsZero() {
		resp.ExpiresAt = rec.ExpiresAt.Format(time.RFC3339)
	}
	if rem, live := m.decisionCache.TTLRemaining(ip); live {
		resp.TTLRemainingMS = rem.Milliseconds()
	}
	return resp
}
