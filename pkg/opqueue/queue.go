// SPDX-License-Identifier: MPL-2.0
// meta:name="opqueue/queue" meta:type="package" meta:version="1.2.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Async operation queue manager for nftables with priority scheduling"
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
	"runtime"
	"sync"
	"sync/atomic"
	"time"

	"github.com/itcmsgr/nftban/pkg/safeconv"
)

// FastOp represents a high-priority operation (ban, unban, flush_source, flush_set)
type FastOp struct {
	SetName string
	Op      *SetOp
}

// BulkJob represents a low-priority bulk operation (replace_set for feeds/geoban)
type BulkJob struct {
	SetName  string
	Elements []string
	Source   string
}

// Scheduler manages priority-based operation scheduling with two lanes
type Scheduler struct {
	fastCh chan FastOp
	bulkCh chan BulkJob

	backend NetlinkBackend
	config  QueueConfig

	// Atomic counters
	fastPending atomic.Int64
	bulkPending atomic.Int64
	totalApplied atomic.Uint64
	totalDropped atomic.Uint64

	// Last flush times
	lastFastFlush atomic.Value // time.Time
	lastBulkFlush atomic.Value // time.Time

	// Running state
	running atomic.Bool
	stopCh  chan struct{}
	wg      sync.WaitGroup
}

// NewScheduler creates a new priority scheduler
func NewScheduler(backend NetlinkBackend, config QueueConfig) *Scheduler {
	s := &Scheduler{
		fastCh:  make(chan FastOp, 10000),      // High-priority buffer
		bulkCh:  make(chan BulkJob, 100),       // Low-priority buffer for bulk jobs
		backend: backend,
		config:  config,
		stopCh:  make(chan struct{}),
	}
	s.lastFastFlush.Store(time.Now())
	s.lastBulkFlush.Store(time.Now())
	return s
}

// Start begins the scheduler workers
func (s *Scheduler) Start(ctx context.Context) {
	if s.running.Load() {
		return
	}
	s.running.Store(true)

	s.wg.Add(2)
	go s.fastWorker(ctx)
	go s.bulkWorker(ctx)
}

// Stop signals the scheduler to stop and waits for workers to finish
func (s *Scheduler) Stop() {
	if !s.running.Load() {
		return
	}

	close(s.stopCh)
	s.running.Store(false)
	s.wg.Wait()
}

// EnqueueFast adds a high-priority operation (ban, unban, flush_source, flush_set)
func (s *Scheduler) EnqueueFast(setName string, op *SetOp) error {
	if !s.running.Load() {
		return ErrQueueStopped
	}

	select {
	case s.fastCh <- FastOp{SetName: setName, Op: op}:
		s.fastPending.Add(1)
		return nil
	default:
		s.totalDropped.Add(1)
		return ErrQueueFull
	}
}

// EnqueueBulk adds a low-priority bulk operation (replace_set)
func (s *Scheduler) EnqueueBulk(setName string, elements []string, source string) error {
	if !s.running.Load() {
		return ErrQueueStopped
	}

	select {
	case s.bulkCh <- BulkJob{SetName: setName, Elements: elements, Source: source}:
		s.bulkPending.Add(1)
		return nil
	default:
		s.totalDropped.Add(1)
		return ErrQueueFull
	}
}

// SchedulerStats returns scheduler statistics
func (s *Scheduler) SchedulerStats() SchedulerStats {
	lastFast, _ := s.lastFastFlush.Load().(time.Time)
	lastBulk, _ := s.lastBulkFlush.Load().(time.Time)
	return SchedulerStats{
		FastPending:   s.fastPending.Load(),
		BulkPending:   s.bulkPending.Load(),
		TotalApplied:  s.totalApplied.Load(),
		TotalDropped:  s.totalDropped.Load(),
		LastFastFlush: lastFast,
		LastBulkFlush: lastBulk,
	}
}

// SchedulerStats holds scheduler statistics
type SchedulerStats struct {
	FastPending   int64
	BulkPending   int64
	TotalApplied  uint64
	TotalDropped  uint64
	LastFastFlush time.Time
	LastBulkFlush time.Time
}

// fastWorker drains fastCh and applies operations in batches
func (s *Scheduler) fastWorker(ctx context.Context) {
	defer s.wg.Done()

	ticker := time.NewTicker(s.config.FlushInterval)
	defer ticker.Stop()

	batch := make([]FastOp, 0, s.config.FlushThreshold)

	for {
		select {
		case <-ctx.Done():
			s.drainFastBatch(batch)
			return
		case <-s.stopCh:
			s.drainFastBatch(batch)
			return
		case op := <-s.fastCh:
			batch = append(batch, op)
			if len(batch) >= s.config.FlushThreshold {
				s.applyFastBatch(batch)
				batch = batch[:0]
			}
		case <-ticker.C:
			if len(batch) > 0 {
				s.applyFastBatch(batch)
				batch = batch[:0]
			}
		}
	}
}

// applyFastBatch applies a batch of fast operations
func (s *Scheduler) applyFastBatch(batch []FastOp) {
	if len(batch) == 0 {
		return
	}

	// Group operations by set
	bySet := make(map[string][]*SetOp)
	for _, op := range batch {
		bySet[op.SetName] = append(bySet[op.SetName], op.Op)
	}

	table := "nftban"
	applied := 0

	for setName, ops := range bySet {
		for _, op := range ops {
			switch op.Type {
			case OpAdd:
				elem := SetElement{
					Value:  op.Element,
					TTL:    op.TTL,
					IsIPv6: isIPv6Set(setName),
				}
				if err := s.backend.AddElements(table, setName, []SetElement{elem}); err != nil {
					log.Printf("[scheduler] fast add %s failed: %v", setName, err)
				} else {
					applied++
				}
			case OpDelete:
				elem := SetElement{
					Value:  op.Element,
					IsIPv6: isIPv6Set(setName),
				}
				if err := s.backend.DeleteElements(table, setName, []SetElement{elem}); err != nil {
					log.Printf("[scheduler] fast delete %s failed: %v", setName, err)
				} else {
					applied++
				}
			case OpFlushSet:
				if err := s.backend.FlushSet(table, setName); err != nil {
					log.Printf("[scheduler] fast flush %s failed: %v", setName, err)
				} else {
					applied++
				}
			}
		}
	}

	s.fastPending.Add(-int64(len(batch)))
	s.totalApplied.Add(safeconv.ToUint64OrZero(applied))
	s.lastFastFlush.Store(time.Now())
}

// drainFastBatch applies remaining fast operations on shutdown
func (s *Scheduler) drainFastBatch(batch []FastOp) {
	// First apply any already-batched ops
	s.applyFastBatch(batch)

	// Drain remaining from channel
	for {
		select {
		case op := <-s.fastCh:
			s.applyFastBatch([]FastOp{op})
		default:
			return
		}
	}
}

// bulkWorker processes replace_set jobs, yielding to fast lane after each batch
func (s *Scheduler) bulkWorker(ctx context.Context) {
	defer s.wg.Done()

	for {
		select {
		case <-ctx.Done():
			s.drainBulkJobs()
			return
		case <-s.stopCh:
			s.drainBulkJobs()
			return
		case job := <-s.bulkCh:
			s.processBulkJob(ctx, job)
		}
	}
}

// processBulkJob applies a replace_set operation in batches, yielding between batches
func (s *Scheduler) processBulkJob(ctx context.Context, job BulkJob) {
	table := "nftban"
	setName := job.SetName

	// Step 1: Flush existing set
	if err := s.backend.FlushSet(table, setName); err != nil {
		log.Printf("[scheduler] bulk flush %s failed: %v", setName, err)
		s.bulkPending.Add(-1)
		return
	}

	if len(job.Elements) == 0 {
		s.bulkPending.Add(-1)
		s.lastBulkFlush.Store(time.Now())
		return
	}

	// Step 2: Add elements in batches, yielding between each
	isIPv6 := isIPv6Set(setName)
	applied := 0

	for i := 0; i < len(job.Elements); i += s.config.MaxBatchSize {
		// Check for stop signal
		select {
		case <-ctx.Done():
			log.Printf("[scheduler] bulk job %s interrupted at %d/%d", setName, i, len(job.Elements))
			s.bulkPending.Add(-1)
			return
		case <-s.stopCh:
			log.Printf("[scheduler] bulk job %s interrupted at %d/%d", setName, i, len(job.Elements))
			s.bulkPending.Add(-1)
			return
		default:
		}

		// Yield to fast lane before processing next batch
		s.yieldToFastLane(ctx)

		end := i + s.config.MaxBatchSize
		if end > len(job.Elements) {
			end = len(job.Elements)
		}

		batch := make([]SetElement, 0, end-i)
		for _, e := range job.Elements[i:end] {
			batch = append(batch, SetElement{
				Value:  e,
				TTL:    0, // Bulk ops (feeds/geoban) are permanent
				IsIPv6: isIPv6,
			})
		}

		if err := s.backend.AddElements(table, setName, batch); err != nil {
			log.Printf("[scheduler] bulk add %s batch %d failed: %v", setName, i/s.config.MaxBatchSize, err)
		} else {
			applied += len(batch)
		}
	}

	s.bulkPending.Add(-1)
	s.totalApplied.Add(safeconv.ToUint64OrZero(applied))
	s.lastBulkFlush.Store(time.Now())
	log.Printf("[scheduler] bulk replace_set %s: %d elements applied", setName, applied)
}

// yieldToFastLane yields CPU time to allow fast lane operations to proceed
func (s *Scheduler) yieldToFastLane(ctx context.Context) {
	if len(s.fastCh) > 0 {
		// Fast lane has pending work - sleep briefly to let it proceed
		time.Sleep(2 * time.Millisecond)
	} else {
		// No fast work pending - just yield the scheduler
		runtime.Gosched()
	}
}

// drainBulkJobs processes remaining bulk jobs on shutdown
func (s *Scheduler) drainBulkJobs() {
	for {
		select {
		case job := <-s.bulkCh:
			// Process without yielding on shutdown
			s.processBulkJobDirect(job)
		default:
			return
		}
	}
}

// processBulkJobDirect applies a bulk job without yielding (for shutdown)
func (s *Scheduler) processBulkJobDirect(job BulkJob) {
	table := "nftban"
	setName := job.SetName

	if err := s.backend.FlushSet(table, setName); err != nil {
		log.Printf("[scheduler] bulk flush %s failed: %v", setName, err)
		s.bulkPending.Add(-1)
		return
	}

	if len(job.Elements) == 0 {
		s.bulkPending.Add(-1)
		return
	}

	isIPv6 := isIPv6Set(setName)
	applied := 0

	for i := 0; i < len(job.Elements); i += s.config.MaxBatchSize {
		end := i + s.config.MaxBatchSize
		if end > len(job.Elements) {
			end = len(job.Elements)
		}

		batch := make([]SetElement, 0, end-i)
		for _, e := range job.Elements[i:end] {
			batch = append(batch, SetElement{
				Value:  e,
				TTL:    0,
				IsIPv6: isIPv6,
			})
		}

		if err := s.backend.AddElements(table, setName, batch); err != nil {
			log.Printf("[scheduler] bulk add %s batch %d failed: %v", setName, i/s.config.MaxBatchSize, err)
		} else {
			applied += len(batch)
		}
	}

	s.bulkPending.Add(-1)
	s.totalApplied.Add(safeconv.ToUint64OrZero(applied))
	log.Printf("[scheduler] bulk replace_set %s: %d elements applied (shutdown)", setName, applied)
}

// isIPv6Set returns true if the set name indicates an IPv6 set
func isIPv6Set(setName string) bool {
	return len(setName) > 5 && setName[len(setName)-5:] == "_ipv6"
}

// EnqueueBulkFromFile performs a streaming replace_set operation
// Instead of loading all elements into memory, this:
// 1. Flushes the set immediately
// 2. Reads the file in batches and adds elements directly
// Memory usage is O(batch_size) instead of O(n)
//
// This is a SYNCHRONOUS operation because it needs to stream from the file.
// The file can be deleted after this function returns.
func (s *Scheduler) EnqueueBulkFromFile(ctx context.Context, setName, filePath, source string, batchConfig StreamingBatchConfig) (int, error) {
	if !s.running.Load() {
		return 0, ErrQueueStopped
	}

	// Open file with security checks
	reader, err := SecureOpenElementsFile(filePath, batchConfig)
	if err != nil {
		return 0, err
	}
	defer reader.Close()

	table := "nftban"

	// Step 1: Flush existing set elements
	if err := s.backend.FlushSet(table, setName); err != nil {
		return 0, err
	}

	// Step 2: Stream elements from file and add in batches
	isIPv6 := isIPv6Set(setName)
	totalApplied := 0

	err = reader.StreamElements(func(batch []string, batchNum int) error {
		// Check for stop signal
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-s.stopCh:
			return ErrQueueStopped
		default:
		}

		// Yield to fast lane before processing next batch
		s.yieldToFastLane(ctx)

		// Convert to SetElement
		elements := make([]SetElement, len(batch))
		for i, e := range batch {
			elements[i] = SetElement{
				Value:  e,
				TTL:    0, // Feeds/geoban are permanent
				IsIPv6: isIPv6,
			}
		}

		// Add batch to set
		if err := s.backend.AddElements(table, setName, elements); err != nil {
			log.Printf("[scheduler] streaming bulk %s batch %d failed: %v", setName, batchNum, err)
			// Continue with other batches
		} else {
			totalApplied += len(elements)
		}
		return nil
	})

	if err != nil {
		return totalApplied, err
	}

	// Update stats
	s.totalApplied.Add(safeconv.ToUint64OrZero(totalApplied))
	s.lastBulkFlush.Store(time.Now())

	log.Printf("[scheduler] streaming bulk replace_set %s: %d elements applied", setName, totalApplied)

	return totalApplied, nil
}

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

// EnqueueReplaceFromFile performs a streaming replace_set operation
// Instead of loading all elements into memory, this:
// 1. Flushes the set immediately
// 2. Reads the file in batches and adds elements directly
// Memory usage is O(batch_size) instead of O(n)
//
// This is a SYNCHRONOUS operation (unlike EnqueueReplace) because
// it needs to stream from the file. The file can be deleted after return.
func (q *OpQueue) EnqueueReplaceFromFile(setName, filePath, source string, batchConfig StreamingBatchConfig) (int, error) {
	if !q.running.Load() {
		return 0, ErrQueueStopped
	}

	// Open file with security checks
	reader, err := SecureOpenElementsFile(filePath, batchConfig)
	if err != nil {
		return 0, err
	}
	defer reader.Close()

	// Get or create buffer and flush any pending ops for this set
	buf := q.getOrCreateBuffer(setName)
	countBefore := buf.count()
	if countBefore > 0 {
		// Flush pending ops first (they'll be discarded by replace anyway)
		result := buf.flush(q.backend, q.config.MaxBatchSize)
		q.pendingCount.Add(-int64(countBefore))
		q.totalApplied.Add(safeconv.ToUint64OrZero(result.Applied))
	}

	// Determine table
	table := "nftban"

	// Step 1: Flush existing set elements
	if err := q.backend.FlushSet(table, setName); err != nil {
		return 0, err
	}

	// Step 2: Stream elements from file and add in batches
	isIPv6 := isIPv6Set(setName)
	totalApplied := 0

	err = reader.StreamElements(func(batch []string, batchNum int) error {
		// Convert to SetElement
		elements := make([]SetElement, len(batch))
		for i, e := range batch {
			elements[i] = SetElement{
				Value:  e,
				TTL:    0, // Feeds/geoban are permanent
				IsIPv6: isIPv6,
			}
		}

		// Add batch to set
		if err := q.backend.AddElements(table, setName, elements); err != nil {
			log.Printf("[opqueue] streaming replace_set %s batch %d failed: %v", setName, batchNum, err)
			// Continue with other batches
		} else {
			totalApplied += len(elements)
		}
		return nil
	})

	if err != nil {
		return totalApplied, err
	}

	// Update stats
	q.totalApplied.Add(safeconv.ToUint64OrZero(totalApplied))
	q.lastFlushTime.Store(time.Now())

	log.Printf("[opqueue] streaming replace_set %s: %d elements applied", setName, totalApplied)

	return totalApplied, nil
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
	q.totalApplied.Add(safeconv.ToUint64OrZero(result.Applied))
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
