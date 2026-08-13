// =============================================================================
// NFTBan - NFTables Manager - Chain creation and drop rule management
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nft"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Chain creation and drop rule management"
// meta:depends="github.com/google/nftables"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================

package setsync

import (
	"fmt"

	"github.com/google/nftables"
	"github.com/google/nftables/expr"
)

// CreateChainIfNotExists creates a chain if it doesn't exist
func (m *NFTManager) CreateChainIfNotExists(table *nftables.Table, chainName string, chainType nftables.ChainType, hook *nftables.ChainHook, priority *nftables.ChainPriority) (*nftables.Chain, error) {
	// INV-NFT-TX-01: private connection, owned for this transaction only.
	conn, errTx := m.txConn()
	if errTx != nil {
		return nil, errTx
	}
	// Try to get existing chain
	chains, err := conn.ListChains()
	if err != nil {
		return nil, fmt.Errorf("failed to list chains: %w", err)
	}

	for _, chain := range chains {
		if chain.Name == chainName && chain.Table.Name == table.Name {
			return chain, nil
		}
	}

	// Create new chain
	chain := &nftables.Chain{
		Name:     chainName,
		Table:    table,
		Type:     chainType,
		Hooknum:  hook,
		Priority: priority,
	}

	conn.AddChain(chain)

	if err := conn.Flush(); err != nil {
		return nil, fmt.Errorf("failed to create chain: %w", err)
	}

	return chain, nil
}

// AddDropRuleForSet adds a rule to drop packets from IPs in a set
func (m *NFTManager) AddDropRuleForSet(chain *nftables.Chain, set *nftables.Set, ipv4 bool) error {
	// INV-NFT-TX-01: private connection, owned for this transaction only.
	conn, errTx := m.txConn()
	if errTx != nil {
		return errTx
	}
	// Build rule: ip saddr @blacklist_ipv4 drop
	var expressions []expr.Any

	if ipv4 {
		// Load IPv4 source address
		expressions = append(expressions,
			&expr.Payload{
				DestRegister: 1,
				Base:         expr.PayloadBaseNetworkHeader,
				Offset:       12, // IPv4 source address offset
				Len:          4,  // IPv4 address length
			},
		)
	} else {
		// Load IPv6 source address
		expressions = append(expressions,
			&expr.Payload{
				DestRegister: 1,
				Base:         expr.PayloadBaseNetworkHeader,
				Offset:       8,  // IPv6 source address offset
				Len:          16, // IPv6 address length
			},
		)
	}

	// Lookup in set
	expressions = append(expressions,
		&expr.Lookup{
			SourceRegister: 1,
			SetName:        set.Name,
			SetID:          set.ID,
		},
	)

	// Drop verdict
	expressions = append(expressions,
		&expr.Verdict{
			Kind: expr.VerdictDrop,
		},
	)

	// Add rule
	rule := &nftables.Rule{
		Table: chain.Table,
		Chain: chain,
		Exprs: expressions,
	}

	conn.AddRule(rule)

	if err := conn.Flush(); err != nil {
		return fmt.Errorf("failed to add drop rule: %w", err)
	}

	return nil
}
