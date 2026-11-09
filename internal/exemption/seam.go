// NFTBan - fixed-snapshot constructor for the never-ban exemption resolver
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
//
// meta:name="exemption_seam"
// meta:type="core"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-31"
// meta:description="v1.236: the exemption resolver moved out of internal/nftbackend so the daemon and the daemon-independent ruleset renderer share one never-ban implementation. Packages that consume the resolver (internal/nftbackend) built fixed snapshots from its private fields in their tests; these two functions are that construction, exported. They read no source and change no behaviour of a resolver built with NewResolver."
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package exemption

import (
	"net/netip"
	"time"
)

// NewSnapshot returns a resolver that holds a fixed, already-loaded snapshot of the given
// exact addresses and CIDR ranges. No source is read and, within its TTL (one hour), no
// refresh happens. Unparseable entries are skipped. For consumers that need a
// deterministic never-ban authority.
func NewSnapshot(exact, cidrs []string) *Resolver {
	r := &Resolver{ttl: time.Hour, loaded: true, loadedAt: time.Now(), exact: map[string]struct{}{}}
	for _, e := range exact {
		if a, err := netip.ParseAddr(e); err == nil {
			r.exact[a.Unmap().String()] = struct{}{}
		}
	}
	for _, c := range cidrs {
		if p, err := netip.ParsePrefix(c); err == nil {
			r.prefixes = append(r.prefixes, p)
		}
	}
	return r
}

// SetSourceError records a required-source failure on the current snapshot, as Refresh
// does when a required source cannot be read. AdmitPrefix then refuses; IsExempt and
// SubtractExempt keep their fail-safe behaviour. "" clears it.
func (r *Resolver) SetSourceError(msg string) {
	r.mu.Lock()
	r.sourceErr = msg
	r.mu.Unlock()
}
