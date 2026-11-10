// =============================================================================
// NFTBan v1.237 - boot-content restoration verifier for the validator
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="ruleset_bootverify"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-11-10"
// meta:description="Registers the validator's BootContentVerifier (BUG-STATUS-PROTECTED-DURING-BOOT-SET-LOAD-WINDOW): the durable content rendered exactly as nftban-boot-content renders it, with nothing carried, and kernel set keys from the existing reader. Lives here because the validator cannot import the renderer (internal/metrics imports the validator)."
// meta:inventory.binaries="nft"
// meta:inventory.privileges="root or CAP_NET_ADMIN (kernel set read; called only after a failed boot load)"
// =============================================================================

package ruleset

import (
	"fmt"

	"github.com/itcmsgr/nftban/internal/exemption"
	"github.com/itcmsgr/nftban/internal/nftbanconf"
	"github.com/itcmsgr/nftban/internal/validator"
)

// RegisterBootContentVerifier wires the validator's restoration check in this binary. Every
// binary that produces a validator verdict calls it once at start.
func RegisterBootContentVerifier() {
	validator.SetBootContentVerifier(validator.BootContentVerifier{
		Expected:   durableBanKeys,
		KernelKeys: kernelKeys,
	})
}

// durableBanKeys renders the durable content as boot-content does (same renderer, same
// config, same never-ban authority) with an empty kernel reader: nothing is carried.
func durableBanKeys() (map[string][]string, error) {
	cfg, err := nftbanconf.Load()
	if err != nil {
		return nil, fmt.Errorf("config: %w", err)
	}
	empty := func(string, string) ([]Element, error) { return nil, nil }
	res, err := Render(Options{
		ConfigDir:   cfg.ConfigDir,
		DataDir:     cfg.DataDir,
		FeedsMaster: cfg.FeedsEnabled,
	}, empty, exemption.NewExemption(cfg.ConfigDir))
	if err != nil {
		return nil, err
	}
	return res.Keys, nil
}

func kernelKeys(family, set string) ([]string, error) {
	els, err := NftSetReader(family, set)
	if err != nil {
		return nil, err
	}
	keys := make([]string, 0, len(els))
	for _, e := range els {
		keys = append(keys, e.Key)
	}
	return keys, nil
}
