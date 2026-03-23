// =============================================================================
// NFTBan v1.0 - Generic Connector Interface
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="connector"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-22"
// meta:description="Generic interface for metrics export connectors"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package connectors

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"sync"
	"time"
)

// =============================================================================
// Connector Interface
// =============================================================================

// Connector is the generic interface for all export connectors
type Connector interface {
	// Name returns the connector name
	Name() string

	// Type returns the connector type (elasticsearch, kafka, file, webhook)
	Type() ConnectorType

	// Connect establishes connection to the target
	Connect(ctx context.Context) error

	// Disconnect closes the connection
	Disconnect() error

	// IsConnected returns true if connected
	IsConnected() bool

	// Send sends a batch of records
	Send(ctx context.Context, records []Record) error

	// Status returns connector status
	Status() ConnectorStatus
}

// ConnectorType identifies the connector type
type ConnectorType string

const (
	ConnectorTypeElasticsearch ConnectorType = "elasticsearch"
	ConnectorTypeKafka         ConnectorType = "kafka"
	ConnectorTypeFile          ConnectorType = "file"
	ConnectorTypeWebhook       ConnectorType = "webhook"
	ConnectorTypeNDJSON        ConnectorType = "ndjson"
)

// =============================================================================
// Record Type
// =============================================================================

// Record represents a single data record to export
type Record struct {
	Timestamp time.Time              `json:"timestamp"`
	Host      string                 `json:"host"`
	Type      string                 `json:"type"`      // metrics, discovery, event, alert
	Source    string                 `json:"source"`    // nftban
	Version   string                 `json:"version"`   // schema version
	Data      map[string]interface{} `json:"data"`
	Tags      map[string]string      `json:"tags,omitempty"`
	Meta      map[string]interface{} `json:"meta,omitempty"`
}

// ToJSON converts record to JSON bytes
func (r *Record) ToJSON() ([]byte, error) {
	return json.Marshal(r)
}

// ToNDJSON converts record to NDJSON format (single line)
func (r *Record) ToNDJSON() ([]byte, error) {
	b, err := json.Marshal(r)
	if err != nil {
		return nil, err
	}
	return append(b, '\n'), nil
}

// NewMetricsRecord creates a new metrics record
func NewMetricsRecord(host string, data map[string]interface{}) Record {
	return Record{
		Timestamp: time.Now(),
		Host:      host,
		Type:      "metrics",
		Source:    "nftban",
		Version:   "1.0",
		Data:      data,
	}
}

// NewEventRecord creates a new event record
func NewEventRecord(host, eventType string, data map[string]interface{}) Record {
	return Record{
		Timestamp: time.Now(),
		Host:      host,
		Type:      "event",
		Source:    "nftban",
		Version:   "1.0",
		Data:      data,
		Tags: map[string]string{
			"event_type": eventType,
		},
	}
}

// NewAlertRecord creates a new alert record
func NewAlertRecord(host, severity, message string, data map[string]interface{}) Record {
	return Record{
		Timestamp: time.Now(),
		Host:      host,
		Type:      "alert",
		Source:    "nftban",
		Version:   "1.0",
		Data:      data,
		Tags: map[string]string{
			"severity": severity,
		},
		Meta: map[string]interface{}{
			"message": message,
		},
	}
}

// =============================================================================
// Connector Status
// =============================================================================

// ConnectorStatus represents connector status
type ConnectorStatus struct {
	Name          string        `json:"name"`
	Type          ConnectorType `json:"type"`
	Connected     bool          `json:"connected"`
	LastConnect   time.Time     `json:"last_connect,omitempty"`
	LastSend      time.Time     `json:"last_send,omitempty"`
	LastError     time.Time     `json:"last_error,omitempty"`
	LastErrorMsg  string        `json:"last_error_msg,omitempty"`
	RecordsSent   int64         `json:"records_sent"`
	BytesSent     int64         `json:"bytes_sent"`
	ErrorCount    int64         `json:"error_count"`
	AvgLatencyMs  float64       `json:"avg_latency_ms"`
}

// =============================================================================
// Base Connector
// =============================================================================

// BaseConnector provides common functionality for connectors
type BaseConnector struct {
	name      string
	connType  ConnectorType
	connected bool
	mu        sync.RWMutex

	// Statistics
	lastConnect  time.Time
	lastSend     time.Time
	lastError    time.Time
	lastErrorMsg string
	recordsSent  int64
	bytesSent    int64
	errorCount   int64
	totalLatency int64
	sendCount    int64
}

// NewBaseConnector creates a new base connector
func NewBaseConnector(name string, connType ConnectorType) *BaseConnector {
	return &BaseConnector{
		name:     name,
		connType: connType,
	}
}

// Name returns the connector name
func (b *BaseConnector) Name() string {
	return b.name
}

// Type returns the connector type
func (b *BaseConnector) Type() ConnectorType {
	return b.connType
}

// IsConnected returns true if connected
func (b *BaseConnector) IsConnected() bool {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.connected
}

// SetConnected sets the connected state
func (b *BaseConnector) SetConnected(connected bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.connected = connected
	if connected {
		b.lastConnect = time.Now()
	}
}

// RecordSend records a successful send
func (b *BaseConnector) RecordSend(records int, bytes int64, latency time.Duration) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.lastSend = time.Now()
	b.recordsSent += int64(records)
	b.bytesSent += bytes
	b.totalLatency += latency.Nanoseconds()
	b.sendCount++
}

// RecordError records an error
func (b *BaseConnector) RecordError(err error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.lastError = time.Now()
	b.lastErrorMsg = err.Error()
	b.errorCount++
}

// Status returns connector status
func (b *BaseConnector) Status() ConnectorStatus {
	b.mu.RLock()
	defer b.mu.RUnlock()

	status := ConnectorStatus{
		Name:         b.name,
		Type:         b.connType,
		Connected:    b.connected,
		LastConnect:  b.lastConnect,
		LastSend:     b.lastSend,
		LastError:    b.lastError,
		LastErrorMsg: b.lastErrorMsg,
		RecordsSent:  b.recordsSent,
		BytesSent:    b.bytesSent,
		ErrorCount:   b.errorCount,
	}

	if b.sendCount > 0 {
		status.AvgLatencyMs = float64(b.totalLatency) / float64(b.sendCount) / 1e6
	}

	return status
}

// =============================================================================
// Connector Manager
// =============================================================================

// Manager manages multiple connectors
type Manager struct {
	connectors map[string]Connector
	mu         sync.RWMutex
	ctx        context.Context
	cancel     context.CancelFunc
}

// NewManager creates a new connector manager
func NewManager() *Manager {
	ctx, cancel := context.WithCancel(context.Background())
	return &Manager{
		connectors: make(map[string]Connector),
		ctx:        ctx,
		cancel:     cancel,
	}
}

// Register registers a connector
func (m *Manager) Register(connector Connector) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	name := connector.Name()
	if _, exists := m.connectors[name]; exists {
		return fmt.Errorf("connector %s already registered", name)
	}

	m.connectors[name] = connector
	return nil
}

// Unregister removes a connector
func (m *Manager) Unregister(name string) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	conn, exists := m.connectors[name]
	if !exists {
		return fmt.Errorf("connector %s not found", name)
	}

	if err := conn.Disconnect(); err != nil {
		return err
	}

	delete(m.connectors, name)
	return nil
}

// Get returns a connector by name
func (m *Manager) Get(name string) (Connector, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	conn, exists := m.connectors[name]
	return conn, exists
}

// List returns all connector names
func (m *Manager) List() []string {
	m.mu.RLock()
	defer m.mu.RUnlock()

	names := make([]string, 0, len(m.connectors))
	for name := range m.connectors {
		names = append(names, name)
	}
	return names
}

// ConnectAll connects all registered connectors
func (m *Manager) ConnectAll(ctx context.Context) map[string]error {
	m.mu.RLock()
	connectors := make(map[string]Connector)
	for name, conn := range m.connectors {
		connectors[name] = conn
	}
	m.mu.RUnlock()

	errors := make(map[string]error)
	var wg sync.WaitGroup
	var mu sync.Mutex

	for name, conn := range connectors {
		wg.Add(1)
		go func(name string, c Connector) {
			defer wg.Done()
			if err := c.Connect(ctx); err != nil {
				mu.Lock()
				errors[name] = err
				mu.Unlock()
			}
		}(name, conn)
	}

	wg.Wait()
	return errors
}

// DisconnectAll disconnects all connectors
func (m *Manager) DisconnectAll() map[string]error {
	m.mu.RLock()
	connectors := make(map[string]Connector)
	for name, conn := range m.connectors {
		connectors[name] = conn
	}
	m.mu.RUnlock()

	errors := make(map[string]error)
	for name, conn := range connectors {
		if err := conn.Disconnect(); err != nil {
			errors[name] = err
		}
	}
	return errors
}

// SendToAll sends records to all connected connectors
func (m *Manager) SendToAll(ctx context.Context, records []Record) map[string]error {
	m.mu.RLock()
	connectors := make(map[string]Connector)
	for name, conn := range m.connectors {
		if conn.IsConnected() {
			connectors[name] = conn
		}
	}
	m.mu.RUnlock()

	errors := make(map[string]error)
	var wg sync.WaitGroup
	var mu sync.Mutex

	for name, conn := range connectors {
		wg.Add(1)
		go func(name string, c Connector) {
			defer wg.Done()
			if err := c.Send(ctx, records); err != nil {
				mu.Lock()
				errors[name] = err
				mu.Unlock()
			}
		}(name, conn)
	}

	wg.Wait()
	return errors
}

// Status returns status for all connectors
func (m *Manager) Status() map[string]ConnectorStatus {
	m.mu.RLock()
	defer m.mu.RUnlock()

	status := make(map[string]ConnectorStatus)
	for name, conn := range m.connectors {
		status[name] = conn.Status()
	}
	return status
}

// Close closes the manager and all connectors
func (m *Manager) Close() error {
	m.cancel()
	errors := m.DisconnectAll()
	if len(errors) > 0 {
		return fmt.Errorf("errors disconnecting: %v", errors)
	}
	return nil
}

// =============================================================================
// Writer Interface
// =============================================================================

// Writer is a simple interface for writing records
type Writer interface {
	Write(ctx context.Context, records []Record) error
	Flush() error
	Close() error
}

// StreamWriter writes records to an io.Writer in NDJSON format
type StreamWriter struct {
	w   io.Writer
	mu  sync.Mutex
}

// NewStreamWriter creates a new stream writer
func NewStreamWriter(w io.Writer) *StreamWriter {
	return &StreamWriter{w: w}
}

// Write writes records in NDJSON format
func (sw *StreamWriter) Write(ctx context.Context, records []Record) error {
	sw.mu.Lock()
	defer sw.mu.Unlock()

	for _, r := range records {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		data, err := r.ToNDJSON()
		if err != nil {
			return err
		}

		if _, err := sw.w.Write(data); err != nil {
			return err
		}
	}

	return nil
}

// Flush flushes the writer if supported
func (sw *StreamWriter) Flush() error {
	if f, ok := sw.w.(interface{ Flush() error }); ok {
		return f.Flush()
	}
	return nil
}

// Close closes the writer if supported
func (sw *StreamWriter) Close() error {
	if c, ok := sw.w.(io.Closer); ok {
		return c.Close()
	}
	return nil
}
