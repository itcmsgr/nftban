// =============================================================================
// NFTBan - OpQueue apply guard: a decision taken at the moment of application
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="opqueue_apply_guard"
// meta:type="package"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-26"
// meta:description="An ApplyGuard wraps the queue's backend once, so every apply path re-decides an add at application time instead of trusting the enqueue-time decision. A refused element never reaches the backend, so a refusal cannot create a missing set. Used by the BotScan HTTP campaign (campaign_prefix_ipv4): disable, a removed drop rule or a never-ban overlap that appears while an add is queued refuses it."
// meta:inventory.privileges="none"
// =============================================================================

package opqueue

import (
	"errors"
	"fmt"
	"log"
	"sync/atomic"
)

// ErrApplyRefused marks elements an ApplyGuard refused at application time. It is a
// refusal, not a transient failure: the element is dropped, never retried.
var ErrApplyRefused = errors.New("refused at application time")

// ApplyGuard decides, when an add is applied, whether element may enter set (nil = yes).
// It must return nil for every set it does not own.
type ApplyGuard func(set, element string) error

type guardedBackend struct {
	NetlinkBackend
	guard   ApplyGuard
	refused *atomic.Int64 // elements refused at application (QueueStats.ApplyGuardRefused)
}

// AddElements applies the admitted elements and reports the refused ones through the
// truth-bearing contract (applied < len(elements) with an error wrapping ErrApplyRefused).
func (g guardedBackend) AddElements(table, set string, elements []SetElement) (int, error) {
	kept := make([]SetElement, 0, len(elements))
	var first error
	for _, e := range elements {
		if err := g.guard(set, e.Value); err != nil {
			if first == nil {
				first = err
			}
			continue
		}
		kept = append(kept, e)
	}
	if len(kept) == len(elements) {
		return g.NetlinkBackend.AddElements(table, set, elements)
	}
	refused := len(elements) - len(kept)
	if g.refused != nil {
		g.refused.Add(int64(refused))
	}
	log.Printf("[opqueue] apply guard refused %d of %d element(s) for %s: %v", refused, len(elements), set, first)
	n := 0
	if len(kept) > 0 {
		var err error
		if n, err = g.NetlinkBackend.AddElements(table, set, kept); err != nil {
			return n, err
		}
	}
	return n, fmt.Errorf("%w: %d of %d element(s) for %s: %v", ErrApplyRefused, refused, len(elements), set, first)
}

// SetApplyGuard puts guard in front of the backend for every apply path. Call once at
// daemon init, before Start. nil leaves the queue unchanged.
func (q *OpQueue) SetApplyGuard(guard ApplyGuard) {
	if guard == nil {
		return
	}
	q.backend = guardedBackend{NetlinkBackend: q.backend, guard: guard, refused: &q.applyGuardRefused}
}
