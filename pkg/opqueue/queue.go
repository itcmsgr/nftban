// SPDX-License-Identifier: MPL-2.0
// meta:name="opqueue/queue" meta:type="package" meta:version="1.1.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Async operation queue manager for nftables"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"

package opqueue

import (
	"context"
	"errors"
	"log"
	"sync"
	"sync/atomic"
	"time"
)

// Errors
var (
	ErrQueueFull    = errors.New("operation queue is full")
	ErrQueueStopped = errors.New("operation queue is stopped")
)

// OpQueue manages all set buffers with async flush workers
type OpQueue struct {
	mu sync.RWMutex

	// Per-set buffers
	buffers map[string]*SetBuffer

	// Async channels
	flushCh chan string        // Signal to flush specific set
	stopCh  chan struct{}      // Stop signal

	// Backend for netlink operations
	backend NetlinkBackend

	// Configuration
	config QueueConfig

	// Atomic counters (no locking needed for reads)
	pendingCount atomic.Int64
	totalQueued  atomic.Uint64
	totalApplied atomic.Uint64
	totalDropped atomic.Uint64

	// Last flush time
	lastFlushTime atomic.Value // time.Time

	// Running state
	running atomic.Bool
}

// NewOpQueue creates a new operation queue
func NewOpQueue(backend NetlinkBackend, config QueueConfig) *OpQueue {
	q := &OpQueue{
		buffers: make(map[string]*SetBuffer),
		flushCh: make(chan string, 100), // Buffered to avoid blocking
		stopCh:  make(chan struct{}),
		backend: backend,
		config:  config,
	}
	q.lastFlushTime.Store(time.Now())
	return q
}

// Start begins the async flush worker
func (q *OpQueue) Start(ctx context.Context) {
	if q.running.Load() {
		return
	}
	q.running.Store(true)

	go q.flushWorker(ctx)
}

// Stop signals the queue to stop and drains remaining operations
func (q *OpQueue) Stop() {
	if !q.running.Load() {
		return
	}

	close(q.stopCh)
	q.running.Store(false)
}

// QueueDepth returns total pending operations - O(1), no locks
func (q *OpQueue) QueueDepth() int64 {
	return q.pendingCount.Load()
}

// Stats returns queue statistics
func (q *OpQueue) Stats() QueueStats {
	lastFlush, _ := q.lastFlushTime.Load().(time.Time)
	return QueueStats{
		PendingCount:  q.pendingCount.Load(),
		TotalQueued:   q.totalQueued.Load(),
		TotalApplied:  q.totalApplied.Load(),
		TotalDropped:  q.totalDropped.Load(),
		LastFlushTime: lastFlush,
	}
}

// EnqueueBan adds a ban operation (async, non-blocking)
func (q *OpQueue) EnqueueBan(setName string, element string, ttl uint32, source, reason string) error {
	op := &SetOp{
		Type:    OpAdd,
		Element: element,
		TTL:     ttl,
		Source:  source,
		Reason:  reason,
	}
	return q.enqueue(setName, op)
}

// EnqueueUnban adds an unban operation (async, non-blocking)
func (q *OpQueue) EnqueueUnban(setName string, element string, source string) error {
	op := &SetOp{
		Type:    OpDelete,
		Element: element,
		Source:  source,
	}
	return q.enqueue(setName, op)
}

// EnqueueReplace adds a replace_set operation (async, non-blocking)
func (q *OpQueue) EnqueueReplace(setName string, elements []string, source string) error {
	op := &SetOp{
		Type:     OpReplaceSet,
		Elements: elements,
		Source:   source,
	}
	return q.enqueue(setName, op)
}

// EnqueueFlush adds a flush_set operation (async, non-blocking)
func (q *OpQueue) EnqueueFlush(setName string) error {
	op := &SetOp{
		Type: OpFlushSet,
	}
	return q.enqueue(setName, op)
}

// enqueue adds an operation to the appropriate buffer
func (q *OpQueue) enqueue(setName string, op *SetOp) error {
	if !q.running.Load() {
		return ErrQueueStopped
	}

	// Fast path check without locks (atomic)
	if q.pendingCount.Load() >= q.config.MaxQueueDepth {
		q.totalDropped.Add(1)
		return ErrQueueFull
	}

	buf := q.getOrCreateBuffer(setName)

	// Buffer handles coalescing and counter updates
	delta := buf.enqueue(op)
	q.pendingCount.Add(delta)
	q.totalQueued.Add(1)

	// Check threshold for immediate flush
	if buf.count() >= q.config.FlushThreshold {
		q.triggerFlush(setName)
	}

	return nil
}

// getOrCreateBuffer gets or creates a buffer for a set
func (q *OpQueue) getOrCreateBuffer(setName string) *SetBuffer {
	q.mu.Lock()
	defer q.mu.Unlock()

	if buf, ok := q.buffers[setName]; ok {
		return buf
	}

	buf := newSetBuffer(setName)
	q.buffers[setName] = buf
	return buf
}

// getBuffer returns a buffer if it exists
func (q *OpQueue) getBuffer(setName string) *SetBuffer {
	q.mu.RLock()
	defer q.mu.RUnlock()
	return q.buffers[setName]
}

// triggerFlush signals the worker to flush a specific set
func (q *OpQueue) triggerFlush(setName string) {
	select {
	case q.flushCh <- setName:
	default:
		// Channel full, worker will flush on next tick anyway
	}
}

// flushWorker is the async goroutine that applies operations to netlink
func (q *OpQueue) flushWorker(ctx context.Context) {
	ticker := time.NewTicker(q.config.FlushInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			q.flushAllFinal()
			return
		case <-q.stopCh:
			q.flushAllFinal()
			return
		case setName := <-q.flushCh:
			q.flushSetWithReenqueue(setName)
		case <-ticker.C:
			q.flushAllWithReenqueue()
		}
	}
}

// flushSetWithReenqueue flushes a single set and re-enqueues post-barrier ops
func (q *OpQueue) flushSetWithReenqueue(setName string) {
	buf := q.getBuffer(setName)
	if buf == nil {
		return
	}

	// Get count before flush for counter adjustment
	countBefore := buf.count()

	// Flush returns post-barrier ops to re-enqueue
	result := buf.flush(q.backend, q.config.MaxBatchSize)

	// Update counters
	q.pendingCount.Add(-int64(countBefore))
	q.totalApplied.Add(uint64(result.Applied))
	q.lastFlushTime.Store(time.Now())

	// Re-enqueue post-barrier ops EXTERNALLY (not inside flush)
	for _, op := range result.PostBarrier {
		// This is a fresh enqueue, goes to current buffer state
		if err := q.enqueue(setName, op); err != nil {
			log.Printf("[opqueue] Failed to re-enqueue post-barrier op: %v", err)
		}
	}

	if result.Err != nil {
		log.Printf("[opqueue] Flush %s failed: %v", setName, result.Err)
	}
}

// flushAllWithReenqueue flushes all buffers
func (q *OpQueue) flushAllWithReenqueue() {
	q.mu.RLock()
	setNames := make([]string, 0, len(q.buffers))
	for name := range q.buffers {
		setNames = append(setNames, name)
	}
	q.mu.RUnlock()

	for _, name := range setNames {
		q.flushSetWithReenqueue(name)
	}
}

// flushAllFinal drains all remaining operations on shutdown
func (q *OpQueue) flushAllFinal() {
	log.Printf("[opqueue] Draining queue on shutdown...")
	q.flushAllWithReenqueue()
	log.Printf("[opqueue] Queue drained, applied %d total operations", q.totalApplied.Load())
}
