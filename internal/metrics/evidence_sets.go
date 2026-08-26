// =============================================================================
// NFTBan v1.88 - Set Element Evidence Collector (M87-3)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="evidence_sets"
// meta:type="package"
// meta:version="1.88.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-15"
// meta:description="Collects set element counts for Phase 1 evidence"
// meta:inventory.files="internal/metrics/evidence_sets.go"
// meta:inventory.binaries="nft"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
//
// Collects per-set element counts using nft JSON output.
// Returns structured SetInfo (exists + count) per set.
// =============================================================================
package metrics

import (
	"context"
	"encoding/json"
	"os/exec"
	"time"

	"github.com/itcmsgr/nftban/internal/procenv"
)

// SetInfo holds element count for a kernel set.
// Three states:
//
//	Exists=true, Count>=0, Unknown=false → collected successfully
//	Exists=false, Count=0, Unknown=false → confirmed absent
//	Unknown=true → collection failure/timeout/parse error; absence not known
type SetInfo struct {
	Exists  bool `json:"exists"`
	Count   int  `json:"count"`
	Unknown bool `json:"unknown,omitempty"`
}

// Phase1Sets defines the sets collected in Phase 1.
var Phase1Sets = map[string][]string{
	"ip": {
		"blacklist_manual_ipv4", "blacklist_ipv4",
		"http_bot_suspect", "http_bot_pending", "http_bot_allow",
		"http_bot_grey", "http_bot_ban", "http_bot_emergency",
	},
	"ip6": {
		"blacklist_manual_ipv6", "blacklist_ipv6",
		"http_bot_suspect6", "http_bot_pending6", "http_bot_allow6",
		"http_bot_grey6", "http_bot_ban6", "http_bot_emergency6",
	},
}

// CollectSetElements returns element counts for Phase 1 sets.
// Keys use stable format: "<family>:<set_name>".
func CollectSetElements(ctx context.Context) map[string]SetInfo {
	sets := make(map[string]SetInfo)

	for family, setNames := range Phase1Sets {
		for _, name := range setNames {
			key := family + ":" + name
			count, exists, unknown := countSetElementsJSON(ctx, family, name)
			sets[key] = SetInfo{Exists: exists, Count: count, Unknown: unknown}
		}
	}

	return sets
}

// countSetElementsJSON counts elements in a set using nft JSON output.
// Returns (count, exists, unknown):
//
//	count>0, exists=true, unknown=false → set present with elements
//	count=0, exists=true, unknown=false → set present, empty
//	count=0, exists=false, unknown=false → set confirmed absent
//	count=0, exists=false, unknown=true → collection failed
func countSetElementsJSON(ctx context.Context, family, name string) (count int, exists bool, unknown bool) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()

	output, err := nftListSet(ctx, family, name)
	if err != nil {
		// Command failure: could be absent OR could be timeout/permission.
		// nft exits non-zero for missing sets — but also for other errors.
		// Mark as unknown so callers don't treat failure as confirmed absence.
		return 0, false, true
	}

	c, found, decodeFailed := parseSetElementCount(output)
	if decodeFailed {
		// v1.229.11: the response could not be decoded. That is an OBSERVATION
		// FAILURE, not an absence — surface it as unknown so no consumer renders
		// it as CONFIRMED-ABSENT.
		return 0, false, true
	}
	if !found {
		// Fully decoded, no set object for this name → confirmed absent
		return 0, false, false
	}
	return c, true, false
}

// nftListSet runs nft -j list set for a specific family and set name.
func nftListSet(ctx context.Context, family, name string) ([]byte, error) {
	// Use string literals for family to satisfy gosec G204.
	// Set name is from our own Phase1Sets constant, not user input.
	var cmd *exec.Cmd
	switch family {
	case "ip":
		cmd = procenv.CommandContext(ctx, "nft", "-j", "list", "set", "ip", "nftban", name) // #nosec G204
	case "ip6":
		cmd = procenv.CommandContext(ctx, "nft", "-j", "list", "set", "ip6", "nftban", name) // #nosec G204
	default:
		return nil, nil
	}
	return cmd.Output()
}

// parseSetElementCount extracts element count from nft JSON set output.
// Returns (count, found):
//
//	found=true → a set object was present in the JSON
//	found=false → no set object found (set absent or parse mismatch)
//
// parseSetElementCount returns (count, found, decodeFailed).
//
// v1.229.11 (OPEN_NFT_PARSER_FAILURE_TRUTH_TAIL): this used to return only
// (int, bool). A json.Unmarshal FAILURE and a VALID response containing no set
// object both returned (0, false), and the caller rendered that as
// exists=false, unknown=false — i.e. CONFIRMED-ABSENT. A decode error was
// therefore published as positive evidence that a set does not exist, which for
// an enforcement set reads as proof of no protection.
//
//	A DECODE ERROR IS UNKNOWN — NEVER CONFIRMED-ABSENT.
//	INSTRUMENT FAILURE IS NOT SUBJECT STATE.
//
// Mirrors the three-valued contract already used by
// internal/validator/module_health.go:989 (countSetElementsStateReal); this is
// application of an existing in-tree pattern, not a new one.
func parseSetElementCount(data []byte) (count int, found bool, decodeFailed bool) {
	var result struct {
		NFTables []json.RawMessage `json:"nftables"`
	}
	if err := json.Unmarshal(data, &result); err != nil {
		// Malformed output. We learned NOTHING about the set.
		return 0, false, true
	}

	// An element we cannot decode is also a failed observation, not an absence.
	// Recorded rather than skipped: previously `continue` swallowed it and the
	// loop could fall through to the confirmed-absent return below.
	sawUndecodable := false
	for _, raw := range result.NFTables {
		var setWrapper struct {
			Set *struct {
				Elem []json.RawMessage `json:"elem"`
			} `json:"set,omitempty"`
		}
		if err := json.Unmarshal(raw, &setWrapper); err != nil {
			sawUndecodable = true
			continue
		}
		if setWrapper.Set == nil {
			continue // a valid non-set object (metainfo, table, ...) — not evidence either way
		}
		// Set object found — count elements (may legitimately be 0)
		return len(setWrapper.Set.Elem), true, false
	}

	if sawUndecodable {
		// We could not read part of the response, so "no set here" is not a
		// conclusion we are entitled to draw.
		return 0, false, true
	}

	// Fully decoded, no set object for this name → CONFIRMED absent.
	return 0, false, false
}
