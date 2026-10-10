// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="nftband-authority"
// meta:type="cmd"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.235 (owner 2026-10-10): nftband runs only with granted firewall authority (state.FirewallAuthority, the decision table shared with the shell). --authority-check is the unit's ExecCondition; main() checks again before the backend exists (it creates the NFTBan tables); WriteGate re-checks before every kernel write so a running daemon stops writing when authority is withdrawn."

package main

import (
	"fmt"
	"log"
	"path/filepath"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/internal/installer/state"
	nftsync "github.com/itcmsgr/nftban/internal/setsync"
)

func authorityInputs() state.AuthorityInputs {
	_, configDir, dataDir, _ := getDaemonPaths()
	in := state.DefaultAuthorityInputs()
	in.ConfigDir = configDir
	in.StateDir = filepath.Join(dataDir, "state")
	return in
}

func authorityText(d state.AuthorityDecision) string {
	if d.Granted {
		return fmt.Sprintf("firewall authority GRANTED (%s: %s)", d.Reason, d.Detail)
	}
	return fmt.Sprintf("firewall authority NOT granted (%s: %s) — nftband does not run and NFTBan writes no firewall rules", d.Reason, d.Detail)
}

// authorityRecheck bounds how long a withdrawn authority can go unnoticed by a running daemon.
const authorityRecheck = 2 * time.Second

// installWriteGate makes every kernel write of this process ask the shared decision first
// (cached for authorityRecheck: bans can arrive in bursts).
func installWriteGate(in state.AuthorityInputs) {
	var (
		mu   sync.Mutex
		at   time.Time
		last state.AuthorityDecision
	)
	nftsync.WriteGate = func() error {
		mu.Lock()
		defer mu.Unlock()
		if at.IsZero() || time.Since(at) >= authorityRecheck {
			d := state.FirewallAuthority(in)
			if !d.Granted && (at.IsZero() || last.Granted) {
				log.Printf("%s", authorityText(d)) // once per withdrawal, not per write
			}
			last, at = d, time.Now()
		}
		if !last.Granted {
			return fmt.Errorf("refused: %s", authorityText(last))
		}
		return nil
	}
}
