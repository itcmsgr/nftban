// =============================================================================
// NFTBan v1.87 - Chain Presence Evidence Collector (M87-4)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="evidence_chains"
// meta:type="package"
// meta:version="1.87.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-15"
// meta:description="Collects chain presence for Phase 1 evidence"
// meta:inventory.files="internal/metrics/evidence_chains.go"
// meta:inventory.binaries="nft"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
//
// Collects chain presence per family. Returns ChainInfo (exists bool).
// =============================================================================
package metrics

import (
	"context"
	"os/exec"
	"strings"
	"time"
)

// ChainInfo holds presence information for a kernel chain.
// Three states:
//   Exists=true, Unknown=false → confirmed present
//   Exists=false, Unknown=false → confirmed absent
//   Unknown=true → collection failure; absence not known
type ChainInfo struct {
	Exists  bool `json:"exists"`
	Unknown bool `json:"unknown,omitempty"`
}

// Phase1Chains defines the chains checked in Phase 1.
var Phase1Chains = []string{
	"input", "forward", "output",
	"ddos_sanity", "ddos_penalty", "ddos_prefix", "ddos_protection",
	"portscan_detection", "http_bot_guard",
}

// CollectChainPresence checks which chains exist per family.
// Keys use stable format: "<family>:<chain_name>".
// If collection fails for a family, all chains in that family are marked Unknown.
func CollectChainPresence(ctx context.Context) map[string]ChainInfo {
	chains := make(map[string]ChainInfo)

	for _, family := range []string{"ip", "ip6"} {
		existing, failed := listChains(ctx, family)
		for _, chain := range Phase1Chains {
			key := family + ":" + chain
			if failed {
				// Collection failed → unknown, not absent
				chains[key] = ChainInfo{Exists: false, Unknown: true}
			} else {
				_, exists := existing[chain]
				chains[key] = ChainInfo{Exists: exists}
			}
		}
	}

	return chains
}

// listChains returns a set of chain names present in a given family.
// Returns (chains, failed): failed=true means command error, not empty result.
func listChains(ctx context.Context, family string) (map[string]bool, bool) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()

	output, err := nftListChains(ctx, family)
	if err != nil {
		return nil, true // collection failed
	}

	result := make(map[string]bool)
	for _, line := range strings.Split(string(output), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "chain ") {
			parts := strings.Fields(line)
			if len(parts) >= 2 {
				result[parts[1]] = true
			}
		}
	}
	return result, false
}

// nftListChains runs nft list chains for a specific family.
func nftListChains(ctx context.Context, family string) ([]byte, error) {
	switch family {
	case "ip":
		return exec.CommandContext(ctx, "nft", "list", "chains", "ip", "nftban").Output() // #nosec G204
	case "ip6":
		return exec.CommandContext(ctx, "nft", "list", "chains", "ip6", "nftban").Output() // #nosec G204
	default:
		return nil, nil
	}
}
