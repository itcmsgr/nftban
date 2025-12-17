// =============================================================================
// NFTBan v1.0 - Event Bus
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: eventbus
// Purpose: Central event distribution for inter-module communication
//
// Architecture:
// - All modules publish events to the bus
// - Subscribers receive events asynchronously
// - Supports type-specific and wildcard subscriptions
// - Thread-safe for concurrent access
//
// Usage:
//
//	bus := eventbus.New()
//	bus.Subscribe(eventbus.EventBan, func(e eventbus.Event) {
//	    log.Printf("IP %s was banned: %s", e.IP, e.Message)
//	})
//	bus.Publish(eventbus.Event{Type: eventbus.EventBan, IP: "1.2.3.4"})
//
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
	EventHealthCheck EventType = "health_check"
	EventModuleStart EventType = "module_start"
	EventModuleStop  EventType = "module_stop"
	EventError       EventType = "error"

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

// Bus is the central event distributor
type Bus struct {
	subscriptions []Subscription
	mu            sync.RWMutex
	closed        bool

	// Metrics
	published   int64
	delivered   int64
	errors      int64
	metricsMu   sync.Mutex
}

// New creates a new event bus
func New() *Bus {
	return &Bus{
		subscriptions: make([]Subscription, 0),
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
// Handlers are called asynchronously in goroutines
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

	// Dispatch to matching handlers
	for _, sub := range subs {
		if sub.eventType == "" || sub.eventType == e.Type {
			b.metricsMu.Lock()
			b.delivered++
			b.metricsMu.Unlock()

			// Call handler in goroutine for async delivery
			go func(h Handler, ev Event) {
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

// Close stops the bus from accepting new events
func (b *Bus) Close() {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.closed = true
}

// Stats returns bus statistics
type Stats struct {
	Subscriptions int   `json:"subscriptions"`
	Published     int64 `json:"published"`
	Delivered     int64 `json:"delivered"`
	Errors        int64 `json:"errors"`
}

// Stats returns current bus statistics
func (b *Bus) Stats() Stats {
	b.mu.RLock()
	subCount := len(b.subscriptions)
	b.mu.RUnlock()

	b.metricsMu.Lock()
	defer b.metricsMu.Unlock()

	return Stats{
		Subscriptions: subCount,
		Published:     b.published,
		Delivered:     b.delivered,
		Errors:        b.errors,
	}
}

// generateID creates a random 8-byte hex ID
func generateID() string {
	b := make([]byte, 8)
	rand.Read(b)
	return hex.EncodeToString(b)
}
