// SPDX-License-Identifier: MPL-2.0
// meta:name="opqueue/buffer" meta:type="package" meta:version="1.1.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Per-set coalescing buffer for OpQueue"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"

package opqueue

import (
	"errors"
	"log"
	"strings"
	"time"
)

// newSetBuffer creates a new buffer for a set
func newSetBuffer(setName string) *SetBuffer {
	return &SetBuffer{
		setName: setName,
		pending: make(map[string]*PendingOp),
	}
}

// count returns the number of pending operations
func (buf *SetBuffer) count() int {
	buf.mu.Lock()
	defer buf.mu.Unlock()

	if buf.replaceOp != nil {
		return len(buf.replaceOp.Elements)
	}
	if buf.flushPending {
		return 1
	}
	return len(buf.pending) + len(buf.postBarrier)
}

// enqueue adds an operation to the buffer with coalescing
// Returns the delta to add to global pending count
func (buf *SetBuffer) enqueue(op *SetOp) int64 {
	buf.mu.Lock()
	defer buf.mu.Unlock()

	switch op.Type {
	case OpReplaceSet:
		return buf.setReplaceLocked(op)
	case OpFlushSet:
		return buf.setFlushLocked()
	case OpAdd:
		return buf.coalesceAddLocked(op)
	case OpDelete:
		return buf.coalesceDeleteLocked(op)
	default:
		return 0
	}
}

// setReplaceLocked sets up a replace_set operation (barrier)
func (buf *SetBuffer) setReplaceLocked(op *SetOp) int64 {
	oldCount := buf.countLocked()

	// Create barrier: all current pending become pre-barrier (will be discarded)
	buf.barrierGen = buf.currentGen
	buf.currentGen++

	// Discard all pre-barrier ops (they'll be replaced anyway)
	buf.pending = make(map[string]*PendingOp)
	buf.flushPending = false
	buf.replaceOp = op

	newCount := len(op.Elements)
	return int64(newCount - oldCount)
}

// setFlushLocked sets up a flush_set operation (barrier)
func (buf *SetBuffer) setFlushLocked() int64 {
	oldCount := buf.countLocked()

	// Create barrier
	buf.barrierGen = buf.currentGen
	buf.currentGen++

	// Flush discards all pending ops
	buf.pending = make(map[string]*PendingOp)
	buf.replaceOp = nil
	buf.flushPending = true

	// Flush itself is 1 operation
	return int64(1 - oldCount)
}

// coalesceAddLocked handles ADD with TTL=max coalescing
// KEY RULE: TTL = max(existing, new) - NEVER shorten a ban
func (buf *SetBuffer) coalesceAddLocked(op *SetOp) int64 {
	// If barrier is pending and this op was created before barrier, queue for post-barrier
	if buf.replaceOp != nil || buf.flushPending {
		// New ops after barrier will be applied after the barrier operation
		buf.postBarrier = append(buf.postBarrier, op)
		return 1
	}

	existing, exists := buf.pending[op.Element]
	if exists && existing.Type == OpAdd {
		// TTL = max(existing, new)
		// 0 means permanent (infinity), which always wins
		if op.TTL == 0 {
			// New is permanent, wins
			existing.TTL = 0
		} else if existing.TTL != 0 && op.TTL > existing.TTL {
			// Both are temporary, take the longer one
			existing.TTL = op.TTL
		}
		// Keep latest source/reason for audit trail
		existing.Source = op.Source
		existing.Reason = op.Reason
		existing.CreatedAt = time.Now()
		return 0 // No change in count
	}

	// New element or was DELETE (ADD wins over pending DELETE)
	buf.pending[op.Element] = &PendingOp{
		Type:      OpAdd,
		Element:   op.Element,
		TTL:       op.TTL,
		Source:    op.Source,
		Reason:    op.Reason,
		CreatedAt: time.Now(),
	}

	if exists {
		return 0 // Replaced DELETE, no count change
	}
	return 1 // New element
}

// coalesceDeleteLocked handles DELETE coalescing
func (buf *SetBuffer) coalesceDeleteLocked(op *SetOp) int64 {
	// If barrier is pending, queue for post-barrier
	if buf.replaceOp != nil || buf.flushPending {
		buf.postBarrier = append(buf.postBarrier, op)
		return 1
	}

	existing, exists := buf.pending[op.Element]
	if exists {
		if existing.Type == OpAdd {
			// DELETE cancels pending ADD
			delete(buf.pending, op.Element)
			return -1
		}
		// Already DELETE, no change
		return 0
	}

	// New DELETE
	buf.pending[op.Element] = &PendingOp{
		Type:    OpDelete,
		Element: op.Element,
		Source:  op.Source,
	}
	return 1
}

// countLocked returns count while lock is held
func (buf *SetBuffer) countLocked() int {
	if buf.replaceOp != nil {
		return len(buf.replaceOp.Elements)
	}
	if buf.flushPending {
		return 1
	}
	return len(buf.pending) + len(buf.postBarrier)
}

// flush extracts and applies pending ops, returns post-barrier ops for re-enqueue
// This is called by the worker goroutine
func (buf *SetBuffer) flush(backend NetlinkBackend, maxBatchSize int) FlushResult {
	buf.mu.Lock()

	// Snapshot all state
	replaceOp := buf.replaceOp
	flushPending := buf.flushPending
	pending := buf.pending
	postBarrier := buf.postBarrier
	setName := buf.setName

	// Clear buffer (while holding lock)
	buf.replaceOp = nil
	buf.flushPending = false
	buf.pending = make(map[string]*PendingOp)
	buf.postBarrier = nil
	buf.barrierGen = 0

	buf.mu.Unlock()
	// Lock released - no more buffer access in this function

	result := FlushResult{
		SetName:     setName,
		PostBarrier: postBarrier, // Return for external re-enqueue
	}

	// Nothing to do?
	if replaceOp == nil && !flushPending && len(pending) == 0 {
		return result
	}

	// Determine table based on set name
	table := "nftban"

	// Apply in order:
	// 1. If replace: flush + bulk add
	// 2. Else if flush pending: just flush
	// 3. Apply pending adds/deletes
	if replaceOp != nil {
		result.Applied = buf.applyReplace(backend, table, setName, replaceOp, maxBatchSize)
		if result.Applied < 0 {
			result.Err = errors.New("replace_set failed")
			result.Applied = 0
		} else {
			result.WasReplace = true
			result.Adds = result.Applied
		}
	} else if flushPending {
		if err := backend.FlushSet(table, setName); err != nil {
			log.Printf("[opqueue] Flush %s failed: %v", setName, err)
			result.Err = err
		} else {
			result.Applied = 1
			result.WasFlush = true
		}
	}

	// Apply pending individual ops
	if len(pending) > 0 {
		adds, deletes := buf.applyPendingCounted(backend, table, setName, pending, maxBatchSize)
		result.Applied += adds + deletes
		result.Adds += adds
		result.Deletes += deletes
	}

	return result
}

// applyReplace applies a replace_set operation: flush + bulk add
func (buf *SetBuffer) applyReplace(backend NetlinkBackend, table, setName string, op *SetOp, maxBatchSize int) int {
	// Step 1: Flush existing
	if err := backend.FlushSet(table, setName); err != nil {
		log.Printf("[opqueue] replace_set flush %s failed: %v", setName, err)
		return -1
	}

	if len(op.Elements) == 0 {
		return 0
	}

	// Step 2: Bulk add in batches
	isIPv6 := strings.HasSuffix(setName, "_ipv6")
	elements := make([]SetElement, 0, len(op.Elements))
	for _, e := range op.Elements {
		elements = append(elements, SetElement{
			Value:  e,
			TTL:    0, // Feeds/geoban are permanent
			IsIPv6: isIPv6,
		})
	}

	// Batch by maxBatchSize
	applied := 0
	for i := 0; i < len(elements); i += maxBatchSize {
		end := i + maxBatchSize
		if end > len(elements) {
			end = len(elements)
		}
		batch := elements[i:end]

		if err := backend.AddElements(table, setName, batch); err != nil {
			log.Printf("[opqueue] replace_set add %s batch %d failed: %v", setName, i/maxBatchSize, err)
		} else {
			applied += len(batch)
		}
	}

	log.Printf("[opqueue] replace_set %s: %d elements applied", setName, applied)
	return applied
}

// applyPending applies individual add/delete operations
// applyPending applies individual add/delete operations (legacy, calls applyPendingCounted)
func (buf *SetBuffer) applyPending(backend NetlinkBackend, table, setName string, pending map[string]*PendingOp, maxBatchSize int) int {
	adds, deletes := buf.applyPendingCounted(backend, table, setName, pending, maxBatchSize)
	return adds + deletes
}

// applyPendingCounted applies individual add/delete operations and returns separate counts
func (buf *SetBuffer) applyPendingCounted(backend NetlinkBackend, table, setName string, pending map[string]*PendingOp, maxBatchSize int) (adds, deletes int) {
	isIPv6 := strings.HasSuffix(setName, "_ipv6")

	var toAdd, toDelete []SetElement

	for _, op := range pending {
		elem := SetElement{
			Value:  op.Element,
			TTL:    op.TTL,
			IsIPv6: isIPv6,
		}
		switch op.Type {
		case OpAdd:
			toAdd = append(toAdd, elem)
		case OpDelete:
			toDelete = append(toDelete, elem)
		}
	}

	// Apply deletes first (in batches)
	for i := 0; i < len(toDelete); i += maxBatchSize {
		end := i + maxBatchSize
		if end > len(toDelete) {
			end = len(toDelete)
		}
		if err := backend.DeleteElements(table, setName, toDelete[i:end]); err != nil {
			log.Printf("[opqueue] delete %s batch failed: %v", setName, err)
		} else {
			deletes += end - i
		}
	}

	// Then adds
	for i := 0; i < len(toAdd); i += maxBatchSize {
		end := i + maxBatchSize
		if end > len(toAdd) {
			end = len(toAdd)
		}
		if err := backend.AddElements(table, setName, toAdd[i:end]); err != nil {
			log.Printf("[opqueue] add %s batch failed: %v", setName, err)
		} else {
			adds += end - i
		}
	}

	return adds, deletes
}
