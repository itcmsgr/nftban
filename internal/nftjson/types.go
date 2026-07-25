// =============================================================================
// NFTBan - nftjson (v1.228.0)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftjson"
// meta:type="package"
// meta:version="1.228.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Shared decode types for `nft -j` output — the single nftables JSON parser surface, so no second parser can drift from the first"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

// Package nftjson holds the shared decode types for `nft -j` output.
//
// This exists so the project has exactly ONE nftables JSON parser surface.
// internal/metrics was the original (and only) consumer; the ban enforcement
// verifier in internal/nftenforce needs the same top-level shapes, and adding a
// second parser would create a second authority that can drift from the first.
//
// Only the shapes actually needed by more than one consumer live here. Consumer
// specific expression types (counters, elements) stay with their consumer.
package nftjson

import "encoding/json"

// Ruleset is the top-level object of `nft -j list ruleset`.
//
// Every entry in NFTables is a single-key object — {"table":…}, {"chain":…},
// {"rule":…}, {"set":…} — so callers decode each RawMessage into the wrapper
// they care about and ignore the rest.
type Ruleset struct {
	NFTables []json.RawMessage `json:"nftables"`
}

// ChainWrapper unwraps a {"chain": {...}} entry.
type ChainWrapper struct {
	Chain *Chain `json:"chain,omitempty"`
}

// Chain is an nftables chain.
//
// Hook is empty for a regular chain and non-empty for a base chain. That
// distinction is the entry point for any reachability analysis: packets only
// enter the ruleset through a base chain with a hook.
type Chain struct {
	Family string `json:"family"`
	Table  string `json:"table"`
	Name   string `json:"name"`
	Type   string `json:"type,omitempty"`
	Hook   string `json:"hook,omitempty"`
	Prio   *int   `json:"prio,omitempty"`
	Policy string `json:"policy,omitempty"`
}

// RuleWrapper unwraps a {"rule": {...}} entry.
type RuleWrapper struct {
	Rule *Rule `json:"rule,omitempty"`
}

// Rule is a single nftables rule. Expr is left raw because the expression
// grammar is open-ended: each consumer decodes only the expressions it
// understands and must decide for itself what an unrecognised one means.
type Rule struct {
	Family  string            `json:"family"`
	Table   string            `json:"table"`
	Chain   string            `json:"chain"`
	Handle  *int              `json:"handle,omitempty"`
	Comment string            `json:"comment,omitempty"`
	Expr    []json.RawMessage `json:"expr"`
}
