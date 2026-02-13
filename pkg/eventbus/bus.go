// =============================================================================
// NFTBan v1.0 - Event Bus
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="bus"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Central event distribution for inter-module communication"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package eventbus

import (
	"crypto/rand"
	"encoding/hex"
	"sync"
	"time"
)

// EventType categorizes events for routing
type EventType string

const (
	// Ban/Unban events
	EventBan   EventType = "ban"
	EventUnban EventType = "unban"

	// Login events
	EventLoginFail    EventType = "login_fail"
	EventLoginFailed  EventType = "login_failed"  // Alias for consistency
	EventLoginSuccess EventType = "login_success"
	EventLoginAlert   EventType = "login_alert"

	// Security detection events
	EventSuricataAlert EventType = "suricata_alert"
	EventDDoSDetected  EventType = "ddos_detected"
	EventPortscan      EventType = "portscan_detected"

	// Feed events
	EventFeedSync   EventType = "feed_sync"
	EventFeedUpdate EventType = "feed_update"

	// System events
	EventHealthCheck  EventType = "health_check"
	EventModuleStart  EventType = "module_start"
	EventModuleStop   EventType = "module_stop"
	EventConfigReload EventType = "config_reload"
	EventError        EventType = "error"

	// GeoIP events
	EventGeoIPUpdate EventType = "geoip_update"
	EventCountryBan  EventType = "country_ban"
)

// Severity levels for events
type Severity int

const (
	SeverityDebug Severity = iota
	SeverityInfo
	SeverityWarning
	SeverityCritical
)

// String returns human-readable severity
func (s Severity) String() string {
	switch s {
	case SeverityDebug:
		return "DEBUG"
	case SeverityInfo:
		return "INFO"
	case SeverityWarning:
		return "WARNING"
	case SeverityCritical:
		return "CRITICAL"
	default:
		return "UNKNOWN"
	}
}

// Event is the universal event structure passed between modules
type Event struct {
	ID        string         `json:"id"`        // Unique event ID
	Type      EventType      `json:"type"`      // Event type for routing
	Severity  Severity       `json:"severity"`  // Severity level
	Timestamp time.Time      `json:"timestamp"` // When event occurred
	Source    string         `json:"source"`    // Module that generated event
	IP        string         `json:"ip"`        // Related IP address (if any)
	User      string         `json:"user"`      // Related username (if any)
	Message   string         `json:"message"`   // Human-readable message
	Data      map[string]any `json:"data"`      // Additional structured data
}

// NewEvent creates a new event with auto-generated ID and timestamp
func NewEvent(eventType EventType, source string) Event {
	return Event{
		ID:        generateID(),
		Type:      eventType,
		Severity:  SeverityInfo,
		Timestamp: time.Now(),
		Source:    source,
		Data:      make(map[string]any),
	}
}

// WithIP sets the IP field
func (e Event) WithIP(ip string) Event {
	e.IP = ip
	return e
}

// WithUser sets the User field
func (e Event) WithUser(user string) Event {
	e.User = user
	return e
}

// WithMessage sets the Message field
func (e Event) WithMessage(msg string) Event {
	e.Message = msg
	return e
}

// WithSeverity sets the Severity field
func (e Event) WithSeverity(sev Severity) Event {
	e.Severity = sev
	return e
}

// WithData adds a key-value pair to Data
func (e Event) WithData(key string, value any) Event {
	if e.Data == nil {
		e.Data = make(map[string]any)
	}
	e.Data[key] = value
	return e
}

// Handler is a function that receives events
type Handler func(Event)

// Subscription represents a registered handler
type Subscription struct {
	id        string
	eventType EventType // Empty string means all events
	handler   Handler
}

// Default worker pool settings
const (
	DefaultWorkerCount = 16    // Number of worker goroutines
	DefaultQueueSize   = 1024  // Size of event dispatch queue
)

// dispatchJob represents a handler invocation to be executed by a worker
type dispatchJob struct {
	handler Handler
	event   Event
}

// Bus is the central event distributor
type Bus struct {
	subscriptions []Subscription
	mu            sync.RWMutex
	closed        bool

	// Worker pool
	workers    int
	jobQueue   chan dispatchJob
	workerWg   sync.WaitGroup
	workerOnce sync.Once

	// Metrics
	published   int64
	delivered   int64
	dropped     int64  // Events dropped due to full queue
	errors      int64
	metricsMu   sync.Mutex
}

// New creates a new event bus with default worker pool settings
func New() *Bus {
	return NewWithConfig(DefaultWorkerCount, DefaultQueueSize)
}

// NewWithConfig creates a new event bus with custom worker pool settings
func NewWithConfig(workers, queueSize int) *Bus {
	if workers <= 0 {
		workers = DefaultWorkerCount
	}
	if queueSize <= 0 {
		queueSize = DefaultQueueSize
	}

	b := &Bus{
		subscriptions: make([]Subscription, 0),
		workers:       workers,
		jobQueue:      make(chan dispatchJob, queueSize),
	}

	// Start worker pool
	b.startWorkers()

	return b
}

// startWorkers initializes the worker goroutines
func (b *Bus) startWorkers() {
	b.workerOnce.Do(func() {
		for i := 0; i < b.workers; i++ {
			b.workerWg.Add(1)
			go b.worker()
		}
	})
}

// worker processes jobs from the queue
func (b *Bus) worker() {
	defer b.workerWg.Done()

	for job := range b.jobQueue {
		func() {
			defer func() {
				if r := recover(); r != nil {
					b.metricsMu.Lock()
					b.errors++
					b.metricsMu.Unlock()
				}
			}()
			job.handler(job.event)
		}()
	}
}

// Subscribe registers a handler for a specific event type
// Returns a subscription ID that can be used to unsubscribe
func (b *Bus) Subscribe(eventType EventType, handler Handler) string {
	b.mu.Lock()
	defer b.mu.Unlock()

	id := generateID()
	b.subscriptions = append(b.subscriptions, Subscription{
		id:        id,
		eventType: eventType,
		handler:   handler,
	})

	return id
}

// SubscribeAll registers a handler for ALL events
// Useful for logging, metrics, GUI updates
func (b *Bus) SubscribeAll(handler Handler) string {
	b.mu.Lock()
	defer b.mu.Unlock()

	id := generateID()
	b.subscriptions = append(b.subscriptions, Subscription{
		id:        id,
		eventType: "", // Empty means all
		handler:   handler,
	})

	return id
}

// SubscribeMultiple registers a handler for multiple event types
func (b *Bus) SubscribeMultiple(eventTypes []EventType, handler Handler) []string {
	ids := make([]string, len(eventTypes))
	for i, et := range eventTypes {
		ids[i] = b.Subscribe(et, handler)
	}
	return ids
}

// Unsubscribe removes a subscription by ID
func (b *Bus) Unsubscribe(id string) bool {
	b.mu.Lock()
	defer b.mu.Unlock()

	for i, sub := range b.subscriptions {
		if sub.id == id {
			// Remove by swapping with last and truncating
			b.subscriptions[i] = b.subscriptions[len(b.subscriptions)-1]
			b.subscriptions = b.subscriptions[:len(b.subscriptions)-1]
			return true
		}
	}
	return false
}

// Publish sends an event to all matching subscribers
// Handlers are called asynchronously via the worker pool
// Non-blocking: if the queue is full, the event dispatch is dropped (backpressure)
func (b *Bus) Publish(e Event) {
	b.mu.RLock()
	if b.closed {
		b.mu.RUnlock()
		return
	}

	// Ensure event has ID and timestamp
	if e.ID == "" {
		e.ID = generateID()
	}
	if e.Timestamp.IsZero() {
		e.Timestamp = time.Now()
	}

	// Copy subscriptions to avoid holding lock during handler execution
	subs := make([]Subscription, len(b.subscriptions))
	copy(subs, b.subscriptions)
	b.mu.RUnlock()

	b.metricsMu.Lock()
	b.published++
	b.metricsMu.Unlock()

	// Dispatch to matching handlers via worker pool
	for _, sub := range subs {
		if sub.eventType == "" || sub.eventType == e.Type {
			job := dispatchJob{handler: sub.handler, event: e}

			// Non-blocking send with backpressure
			select {
			case b.jobQueue <- job:
				b.metricsMu.Lock()
				b.delivered++
				b.metricsMu.Unlock()
			default:
				// Queue full - drop this dispatch (backpressure)
				b.metricsMu.Lock()
				b.dropped++
				b.metricsMu.Unlock()
			}
		}
	}
}

// PublishSync sends an event and waits for all handlers to complete
// Use sparingly - blocks the caller
func (b *Bus) PublishSync(e Event) {
	b.mu.RLock()
	if b.closed {
		b.mu.RUnlock()
		return
	}

	if e.ID == "" {
		e.ID = generateID()
	}
	if e.Timestamp.IsZero() {
		e.Timestamp = time.Now()
	}

	subs := make([]Subscription, len(b.subscriptions))
	copy(subs, b.subscriptions)
	b.mu.RUnlock()

	b.metricsMu.Lock()
	b.published++
	b.metricsMu.Unlock()

	var wg sync.WaitGroup
	for _, sub := range subs {
		if sub.eventType == "" || sub.eventType == e.Type {
			b.metricsMu.Lock()
			b.delivered++
			b.metricsMu.Unlock()

			wg.Add(1)
			go func(h Handler, ev Event) {
				defer wg.Done()
				defer func() {
					if r := recover(); r != nil {
						b.metricsMu.Lock()
						b.errors++
						b.metricsMu.Unlock()
					}
				}()
				h(ev)
			}(sub.handler, e)
		}
	}
	wg.Wait()
}

// Close stops the bus from accepting new events and shuts down workers
func (b *Bus) Close() {
	b.mu.Lock()
	if b.closed {
		b.mu.Unlock()
		return
	}
	b.closed = true
	b.mu.Unlock()

	// Close job queue to signal workers to exit
	close(b.jobQueue)

	// Wait for all workers to finish processing
	b.workerWg.Wait()
}

// Stats returns bus statistics
type Stats struct {
	Subscriptions int   `json:"subscriptions"`
	Workers       int   `json:"workers"`
	QueueSize     int   `json:"queue_size"`
	QueueUsed     int   `json:"queue_used"`
	Published     int64 `json:"published"`
	Delivered     int64 `json:"delivered"`
	Dropped       int64 `json:"dropped"`  // Events dropped due to backpressure
	Errors        int64 `json:"errors"`
}

// Stats returns current bus statistics
func (b *Bus) Stats() Stats {
	b.mu.RLock()
	subCount := len(b.subscriptions)
	closed := b.closed
	b.mu.RUnlock()

	var queueUsed, queueSize int
	if !closed && b.jobQueue != nil {
		queueUsed = len(b.jobQueue)
		queueSize = cap(b.jobQueue)
	}

	b.metricsMu.Lock()
	defer b.metricsMu.Unlock()

	return Stats{
		Subscriptions: subCount,
		Workers:       b.workers,
		QueueSize:     queueSize,
		QueueUsed:     queueUsed,
		Published:     b.published,
		Delivered:     b.delivered,
		Dropped:       b.dropped,
		Errors:        b.errors,
	}
}

// generateID creates a random 8-byte hex ID
func generateID() string {
	b := make([]byte, 8)
	rand.Read(b)
	return hex.EncodeToString(b)
}
