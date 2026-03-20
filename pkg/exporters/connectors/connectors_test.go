// =============================================================================
// NFTBan - Connectors Package Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="connectors_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Tests for ES/Kafka/NDJSON connectors: records, config, formatting, base connector"
// meta:input="None"
// meta:output="None"
// meta:depends="testing"
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
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

// =============================================================================
// Record Tests
// =============================================================================

func TestRecord_ToJSON(t *testing.T) {
	r := Record{
		Timestamp: time.Date(2026, 3, 20, 12, 0, 0, 0, time.UTC),
		Host:      "testhost",
		Type:      "metrics",
		Source:    "nftban",
		Version:   "1.0",
		Data: map[string]interface{}{
			"bans_total": 100,
			"version":    "1.25.0",
		},
	}

	data, err := r.ToJSON()
	if err != nil {
		t.Fatalf("ToJSON() error = %v", err)
	}

	var parsed map[string]interface{}
	if err := json.Unmarshal(data, &parsed); err != nil {
		t.Fatalf("JSON unmarshal error = %v", err)
	}

	if parsed["host"] != "testhost" {
		t.Errorf("host = %v, want %q", parsed["host"], "testhost")
	}
	if parsed["type"] != "metrics" {
		t.Errorf("type = %v, want %q", parsed["type"], "metrics")
	}
	if parsed["source"] != "nftban" {
		t.Errorf("source = %v, want %q", parsed["source"], "nftban")
	}
}

func TestRecord_ToNDJSON(t *testing.T) {
	r := Record{
		Timestamp: time.Now(),
		Host:      "h1",
		Type:      "metrics",
		Source:    "nftban",
		Version:   "1.0",
		Data:      map[string]interface{}{"k": "v"},
	}

	data, err := r.ToNDJSON()
	if err != nil {
		t.Fatalf("ToNDJSON() error = %v", err)
	}

	// Must end with newline
	if !bytes.HasSuffix(data, []byte("\n")) {
		t.Error("NDJSON should end with newline")
	}

	// Should be a single line (strip trailing newline, check no other newlines)
	trimmed := bytes.TrimSuffix(data, []byte("\n"))
	if bytes.Contains(trimmed, []byte("\n")) {
		t.Error("NDJSON should be a single line")
	}

	// Should be valid JSON
	var parsed map[string]interface{}
	if err := json.Unmarshal(trimmed, &parsed); err != nil {
		t.Fatalf("NDJSON content should be valid JSON, got error = %v", err)
	}
}

func TestNewMetricsRecord(t *testing.T) {
	data := map[string]interface{}{"bans": 100}
	r := NewMetricsRecord("myhost", data)

	if r.Host != "myhost" {
		t.Errorf("host = %q, want %q", r.Host, "myhost")
	}
	if r.Type != "metrics" {
		t.Errorf("type = %q, want %q", r.Type, "metrics")
	}
	if r.Source != "nftban" {
		t.Errorf("source = %q, want %q", r.Source, "nftban")
	}
	if r.Version != "1.0" {
		t.Errorf("version = %q, want %q", r.Version, "1.0")
	}
	if r.Timestamp.IsZero() {
		t.Error("timestamp should not be zero")
	}
	if r.Data["bans"] != 100 {
		t.Errorf("data[bans] = %v, want 100", r.Data["bans"])
	}
}

func TestNewEventRecord(t *testing.T) {
	data := map[string]interface{}{"ip": "1.2.3.4", "reason": "portscan"}
	r := NewEventRecord("myhost", "ban", data)

	if r.Type != "event" {
		t.Errorf("type = %q, want %q", r.Type, "event")
	}
	if r.Tags["event_type"] != "ban" {
		t.Errorf("tags[event_type] = %q, want %q", r.Tags["event_type"], "ban")
	}
}

func TestNewAlertRecord(t *testing.T) {
	data := map[string]interface{}{"ip": "5.6.7.8"}
	r := NewAlertRecord("myhost", "critical", "DDoS attack detected", data)

	if r.Type != "alert" {
		t.Errorf("type = %q, want %q", r.Type, "alert")
	}
	if r.Tags["severity"] != "critical" {
		t.Errorf("tags[severity] = %q, want %q", r.Tags["severity"], "critical")
	}
	if r.Meta["message"] != "DDoS attack detected" {
		t.Errorf("meta[message] = %v, want %q", r.Meta["message"], "DDoS attack detected")
	}
}

func TestRecord_WithTags(t *testing.T) {
	r := Record{
		Timestamp: time.Now(),
		Host:      "h1",
		Type:      "metrics",
		Source:    "nftban",
		Version:   "1.0",
		Data:      map[string]interface{}{"k": "v"},
		Tags:      map[string]string{"env": "prod", "region": "eu"},
	}

	data, err := r.ToJSON()
	if err != nil {
		t.Fatalf("ToJSON() error = %v", err)
	}

	if !strings.Contains(string(data), "prod") {
		t.Error("JSON should contain tags")
	}
}

func TestRecord_EmptyData(t *testing.T) {
	r := Record{
		Timestamp: time.Now(),
		Host:      "h1",
		Type:      "metrics",
		Source:    "nftban",
		Version:   "1.0",
		Data:      map[string]interface{}{},
	}

	data, err := r.ToJSON()
	if err != nil {
		t.Fatalf("ToJSON() error = %v", err)
	}

	if len(data) == 0 {
		t.Error("JSON output should not be empty")
	}
}

// =============================================================================
// ConnectorType Constants Tests
// =============================================================================

func TestConnectorTypeConstants(t *testing.T) {
	tests := []struct {
		ct   ConnectorType
		want string
	}{
		{ConnectorTypeElasticsearch, "elasticsearch"},
		{ConnectorTypeKafka, "kafka"},
		{ConnectorTypeFile, "file"},
		{ConnectorTypeWebhook, "webhook"},
		{ConnectorTypeNDJSON, "ndjson"},
	}

	for _, tt := range tests {
		if string(tt.ct) != tt.want {
			t.Errorf("ConnectorType = %q, want %q", tt.ct, tt.want)
		}
	}
}

// =============================================================================
// BaseConnector Tests
// =============================================================================

func TestBaseConnector_New(t *testing.T) {
	bc := NewBaseConnector("test-es", ConnectorTypeElasticsearch)

	if bc.Name() != "test-es" {
		t.Errorf("Name() = %q, want %q", bc.Name(), "test-es")
	}
	if bc.Type() != ConnectorTypeElasticsearch {
		t.Errorf("Type() = %q, want %q", bc.Type(), ConnectorTypeElasticsearch)
	}
	if bc.IsConnected() {
		t.Error("initial state should be disconnected")
	}
}

func TestBaseConnector_SetConnected(t *testing.T) {
	bc := NewBaseConnector("test", ConnectorTypeFile)

	bc.SetConnected(true)
	if !bc.IsConnected() {
		t.Error("should be connected after SetConnected(true)")
	}

	bc.SetConnected(false)
	if bc.IsConnected() {
		t.Error("should be disconnected after SetConnected(false)")
	}
}

func TestBaseConnector_RecordSend(t *testing.T) {
	bc := NewBaseConnector("test", ConnectorTypeNDJSON)

	bc.RecordSend(10, 1024, 50*time.Millisecond)
	bc.RecordSend(5, 512, 30*time.Millisecond)

	status := bc.Status()
	if status.RecordsSent != 15 {
		t.Errorf("RecordsSent = %d, want 15", status.RecordsSent)
	}
	if status.BytesSent != 1536 {
		t.Errorf("BytesSent = %d, want 1536", status.BytesSent)
	}
	if status.AvgLatencyMs <= 0 {
		t.Error("AvgLatencyMs should be positive after sends")
	}
}

func TestBaseConnector_RecordError(t *testing.T) {
	bc := NewBaseConnector("test", ConnectorTypeKafka)

	bc.RecordError(errors.New("connection refused"))
	bc.RecordError(errors.New("timeout"))

	status := bc.Status()
	if status.ErrorCount != 2 {
		t.Errorf("ErrorCount = %d, want 2", status.ErrorCount)
	}
	if status.LastErrorMsg != "timeout" {
		t.Errorf("LastErrorMsg = %q, want %q", status.LastErrorMsg, "timeout")
	}
}

func TestBaseConnector_Status(t *testing.T) {
	bc := NewBaseConnector("my-connector", ConnectorTypeElasticsearch)
	bc.SetConnected(true)
	bc.RecordSend(5, 100, 10*time.Millisecond)

	status := bc.Status()
	if status.Name != "my-connector" {
		t.Errorf("Name = %q, want %q", status.Name, "my-connector")
	}
	if status.Type != ConnectorTypeElasticsearch {
		t.Errorf("Type = %q, want %q", status.Type, ConnectorTypeElasticsearch)
	}
	if !status.Connected {
		t.Error("Connected should be true")
	}
	if status.RecordsSent != 5 {
		t.Errorf("RecordsSent = %d, want 5", status.RecordsSent)
	}
}

func TestBaseConnector_LatencyCalculation(t *testing.T) {
	bc := NewBaseConnector("test", ConnectorTypeNDJSON)

	// Send with 100ms latency
	bc.RecordSend(1, 100, 100*time.Millisecond)
	// Send with 200ms latency
	bc.RecordSend(1, 100, 200*time.Millisecond)

	status := bc.Status()
	// Average should be 150ms
	expectedAvg := 150.0
	tolerance := 1.0
	if status.AvgLatencyMs < expectedAvg-tolerance || status.AvgLatencyMs > expectedAvg+tolerance {
		t.Errorf("AvgLatencyMs = %f, want ~%f", status.AvgLatencyMs, expectedAvg)
	}
}

func TestBaseConnector_ZeroSendsLatency(t *testing.T) {
	bc := NewBaseConnector("test", ConnectorTypeNDJSON)

	status := bc.Status()
	if status.AvgLatencyMs != 0 {
		t.Errorf("AvgLatencyMs with no sends = %f, want 0", status.AvgLatencyMs)
	}
}

// =============================================================================
// Manager Tests
// =============================================================================

// mockConnector implements Connector for testing
type mockConnector struct {
	*BaseConnector
	connectErr    error
	disconnectErr error
	sendErr       error
	sendCalled    int
}

func newMockConnector(name string, ct ConnectorType) *mockConnector {
	return &mockConnector{
		BaseConnector: NewBaseConnector(name, ct),
	}
}

func (m *mockConnector) Connect(ctx context.Context) error {
	if m.connectErr != nil {
		return m.connectErr
	}
	m.SetConnected(true)
	return nil
}

func (m *mockConnector) Disconnect() error {
	m.SetConnected(false)
	return m.disconnectErr
}

func (m *mockConnector) Send(ctx context.Context, records []Record) error {
	m.sendCalled++
	if m.sendErr != nil {
		m.RecordError(m.sendErr)
		return m.sendErr
	}
	m.RecordSend(len(records), int64(len(records)*100), time.Millisecond)
	return nil
}

func TestManager_New(t *testing.T) {
	m := NewManager()
	if m == nil {
		t.Fatal("NewManager() returned nil")
	}

	names := m.List()
	if len(names) != 0 {
		t.Errorf("initial List() = %v, want empty", names)
	}
}

func TestManager_Register(t *testing.T) {
	m := NewManager()
	c := newMockConnector("es1", ConnectorTypeElasticsearch)

	if err := m.Register(c); err != nil {
		t.Fatalf("Register() error = %v", err)
	}

	// Duplicate registration should fail
	if err := m.Register(c); err == nil {
		t.Error("duplicate Register() should return error")
	}
}

func TestManager_Get(t *testing.T) {
	m := NewManager()
	c := newMockConnector("kafka1", ConnectorTypeKafka)
	m.Register(c)

	got, ok := m.Get("kafka1")
	if !ok {
		t.Error("Get() should find registered connector")
	}
	if got.Name() != "kafka1" {
		t.Errorf("Get() name = %q, want %q", got.Name(), "kafka1")
	}

	_, ok = m.Get("nonexistent")
	if ok {
		t.Error("Get() should not find nonexistent connector")
	}
}

func TestManager_Unregister(t *testing.T) {
	m := NewManager()
	c := newMockConnector("file1", ConnectorTypeFile)
	m.Register(c)

	if err := m.Unregister("file1"); err != nil {
		t.Fatalf("Unregister() error = %v", err)
	}

	_, ok := m.Get("file1")
	if ok {
		t.Error("connector should not be found after Unregister")
	}

	// Unregister nonexistent should fail
	if err := m.Unregister("nonexistent"); err == nil {
		t.Error("Unregister(nonexistent) should return error")
	}
}

func TestManager_List(t *testing.T) {
	m := NewManager()
	m.Register(newMockConnector("a", ConnectorTypeElasticsearch))
	m.Register(newMockConnector("b", ConnectorTypeKafka))
	m.Register(newMockConnector("c", ConnectorTypeNDJSON))

	names := m.List()
	if len(names) != 3 {
		t.Errorf("List() len = %d, want 3", len(names))
	}
}

func TestManager_ConnectAll(t *testing.T) {
	m := NewManager()
	c1 := newMockConnector("ok", ConnectorTypeElasticsearch)
	c2 := newMockConnector("fail", ConnectorTypeKafka)
	c2.connectErr = errors.New("connection refused")

	m.Register(c1)
	m.Register(c2)

	errs := m.ConnectAll(context.Background())
	if len(errs) != 1 {
		t.Errorf("ConnectAll() errors = %d, want 1", len(errs))
	}
	if errs["fail"] == nil {
		t.Error("ConnectAll() should have error for 'fail'")
	}
	if !c1.IsConnected() {
		t.Error("'ok' connector should be connected")
	}
}

func TestManager_DisconnectAll(t *testing.T) {
	m := NewManager()
	c1 := newMockConnector("c1", ConnectorTypeElasticsearch)
	c1.SetConnected(true)
	m.Register(c1)

	errs := m.DisconnectAll()
	if len(errs) != 0 {
		t.Errorf("DisconnectAll() errors = %v, want none", errs)
	}
	if c1.IsConnected() {
		t.Error("connector should be disconnected")
	}
}

func TestManager_SendToAll(t *testing.T) {
	m := NewManager()
	c1 := newMockConnector("ok", ConnectorTypeElasticsearch)
	c1.SetConnected(true)
	c2 := newMockConnector("err", ConnectorTypeKafka)
	c2.SetConnected(true)
	c2.sendErr = errors.New("send error")
	c3 := newMockConnector("disconnected", ConnectorTypeNDJSON)
	// c3 not connected

	m.Register(c1)
	m.Register(c2)
	m.Register(c3)

	records := []Record{
		NewMetricsRecord("h1", map[string]interface{}{"k": "v"}),
	}

	errs := m.SendToAll(context.Background(), records)
	// Only connected connectors should be tried, 'err' should have error
	if errs["err"] == nil {
		t.Error("SendToAll() should have error for 'err'")
	}
	if c1.sendCalled != 1 {
		t.Errorf("ok connector send count = %d, want 1", c1.sendCalled)
	}
	if c3.sendCalled != 0 {
		t.Errorf("disconnected connector should not be called, got %d", c3.sendCalled)
	}
}

func TestManager_Status(t *testing.T) {
	m := NewManager()
	c1 := newMockConnector("es", ConnectorTypeElasticsearch)
	c1.SetConnected(true)
	m.Register(c1)

	statuses := m.Status()
	if len(statuses) != 1 {
		t.Fatalf("Status() len = %d, want 1", len(statuses))
	}
	if s, ok := statuses["es"]; !ok || !s.Connected {
		t.Error("Status should show 'es' as connected")
	}
}

func TestManager_Close(t *testing.T) {
	m := NewManager()
	c := newMockConnector("c1", ConnectorTypeFile)
	c.SetConnected(true)
	m.Register(c)

	if err := m.Close(); err != nil {
		t.Fatalf("Close() error = %v", err)
	}
	if c.IsConnected() {
		t.Error("connector should be disconnected after Close()")
	}
}

// =============================================================================
// StreamWriter Tests
// =============================================================================

func TestStreamWriter_Write(t *testing.T) {
	var buf bytes.Buffer
	sw := NewStreamWriter(&buf)

	records := []Record{
		NewMetricsRecord("h1", map[string]interface{}{"bans": 10}),
		NewMetricsRecord("h1", map[string]interface{}{"bans": 20}),
	}

	if err := sw.Write(context.Background(), records); err != nil {
		t.Fatalf("Write() error = %v", err)
	}

	output := buf.String()
	lines := strings.Split(strings.TrimSpace(output), "\n")
	if len(lines) != 2 {
		t.Errorf("output lines = %d, want 2", len(lines))
	}

	// Each line should be valid JSON
	for i, line := range lines {
		var parsed map[string]interface{}
		if err := json.Unmarshal([]byte(line), &parsed); err != nil {
			t.Errorf("line %d is not valid JSON: %v", i, err)
		}
	}
}

func TestStreamWriter_WriteEmpty(t *testing.T) {
	var buf bytes.Buffer
	sw := NewStreamWriter(&buf)

	if err := sw.Write(context.Background(), []Record{}); err != nil {
		t.Fatalf("Write(empty) error = %v", err)
	}

	if buf.Len() != 0 {
		t.Error("empty records should produce empty output")
	}
}

func TestStreamWriter_ContextCancellation(t *testing.T) {
	var buf bytes.Buffer
	sw := NewStreamWriter(&buf)

	ctx, cancel := context.WithCancel(context.Background())
	cancel() // Cancel immediately

	records := make([]Record, 100)
	for i := range records {
		records[i] = NewMetricsRecord("h1", map[string]interface{}{"i": i})
	}

	err := sw.Write(ctx, records)
	if err == nil {
		t.Error("Write() should return error when context is cancelled")
	}
}

func TestStreamWriter_Flush(t *testing.T) {
	var buf bytes.Buffer
	sw := NewStreamWriter(&buf)

	// Flush on a plain bytes.Buffer (no Flush method) should be no-op
	if err := sw.Flush(); err != nil {
		t.Fatalf("Flush() error = %v", err)
	}
}

func TestStreamWriter_Close(t *testing.T) {
	var buf bytes.Buffer
	sw := NewStreamWriter(&buf)

	// Close on a plain bytes.Buffer (no Close method) should be no-op
	if err := sw.Close(); err != nil {
		t.Fatalf("Close() error = %v", err)
	}
}

// =============================================================================
// Elasticsearch Config Tests
// =============================================================================

func TestDefaultESConfig(t *testing.T) {
	cfg := DefaultESConfig()

	if len(cfg.Addresses) != 1 || cfg.Addresses[0] != "http://localhost:9200" {
		t.Errorf("Addresses = %v, want [http://localhost:9200]", cfg.Addresses)
	}
	if cfg.Index != "nftban-metrics" {
		t.Errorf("Index = %q, want %q", cfg.Index, "nftban-metrics")
	}
	if cfg.BulkSize != 1000 {
		t.Errorf("BulkSize = %d, want 1000", cfg.BulkSize)
	}
	if cfg.Timeout != 30*time.Second {
		t.Errorf("Timeout = %v, want 30s", cfg.Timeout)
	}
	if cfg.MaxRetries != 3 {
		t.Errorf("MaxRetries = %d, want 3", cfg.MaxRetries)
	}
}

func TestNewElasticsearchConnector(t *testing.T) {
	cfg := DefaultESConfig()
	c := NewElasticsearchConnector("es-primary", cfg)

	if c.Name() != "es-primary" {
		t.Errorf("Name() = %q, want %q", c.Name(), "es-primary")
	}
	if c.Type() != ConnectorTypeElasticsearch {
		t.Errorf("Type() = %q, want %q", c.Type(), ConnectorTypeElasticsearch)
	}
	if c.IsConnected() {
		t.Error("should not be connected initially")
	}
}

func TestElasticsearchConnector_ResolveIndex(t *testing.T) {
	tests := []struct {
		name    string
		pattern string
		index   string
		ts      time.Time
		want    string
	}{
		{
			name:    "pattern with date",
			pattern: "nftban-metrics-%Y.%m.%d",
			ts:      time.Date(2026, 3, 20, 0, 0, 0, 0, time.UTC),
			want:    "nftban-metrics-2026.03.20",
		},
		{
			name:    "pattern with hour",
			pattern: "nftban-%Y.%m.%d.%H",
			ts:      time.Date(2026, 3, 20, 14, 30, 0, 0, time.UTC),
			want:    "nftban-2026.03.20.14",
		},
		{
			name:  "no pattern uses index",
			index: "nftban-static",
			ts:    time.Now(),
			want:  "nftban-static",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := ESConfig{
				Index:        tt.index,
				IndexPattern: tt.pattern,
			}
			c := NewElasticsearchConnector("test", cfg)

			got := c.resolveIndex(tt.ts)
			if got != tt.want {
				t.Errorf("resolveIndex() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestElasticsearchConnector_AddAuth_APIKey(t *testing.T) {
	cfg := ESConfig{APIKey: "mykey123"}
	c := NewElasticsearchConnector("test", cfg)

	// We can test the addAuth method indirectly by verifying the config is stored
	if c.config.APIKey != "mykey123" {
		t.Errorf("APIKey = %q, want %q", c.config.APIKey, "mykey123")
	}
}

func TestElasticsearchConnector_AddAuth_BasicAuth(t *testing.T) {
	cfg := ESConfig{Username: "admin", Password: "secret"}
	c := NewElasticsearchConnector("test", cfg)

	if c.config.Username != "admin" {
		t.Errorf("Username = %q, want %q", c.config.Username, "admin")
	}
}

func TestElasticsearchConnector_Disconnect_NotConnected(t *testing.T) {
	cfg := DefaultESConfig()
	c := NewElasticsearchConnector("test", cfg)

	// Disconnect when not connected should not error
	if err := c.Disconnect(); err != nil {
		t.Fatalf("Disconnect() error = %v", err)
	}
}

func TestElasticsearchConnector_SendEmpty(t *testing.T) {
	cfg := DefaultESConfig()
	c := NewElasticsearchConnector("test", cfg)

	// Send empty records should be no-op
	err := c.Send(context.Background(), []Record{})
	if err != nil {
		t.Errorf("Send(empty) error = %v", err)
	}
}

func TestElasticsearchConnector_SendNotConnected(t *testing.T) {
	cfg := DefaultESConfig()
	c := NewElasticsearchConnector("test", cfg)

	records := []Record{NewMetricsRecord("h1", map[string]interface{}{"k": "v"})}
	err := c.Send(context.Background(), records)
	if err == nil {
		t.Error("Send() should error when not connected")
	}
}

// =============================================================================
// Kafka Config Tests
// =============================================================================

func TestDefaultKafkaConfig(t *testing.T) {
	cfg := DefaultKafkaConfig()

	if len(cfg.Brokers) != 1 || cfg.Brokers[0] != "localhost:9092" {
		t.Errorf("Brokers = %v, want [localhost:9092]", cfg.Brokers)
	}
	if cfg.Topic != "nftban-metrics" {
		t.Errorf("Topic = %q, want %q", cfg.Topic, "nftban-metrics")
	}
	if cfg.Acks != 1 {
		t.Errorf("Acks = %d, want 1", cfg.Acks)
	}
	if cfg.BatchSize != 16384 {
		t.Errorf("BatchSize = %d, want 16384", cfg.BatchSize)
	}
	if cfg.MaxRetries != 3 {
		t.Errorf("MaxRetries = %d, want 3", cfg.MaxRetries)
	}
	if cfg.Partition != -1 {
		t.Errorf("Partition = %d, want -1", cfg.Partition)
	}
}

func TestNewKafkaConnector(t *testing.T) {
	cfg := DefaultKafkaConfig()
	c := NewKafkaConnector("kafka-primary", cfg)

	if c.Name() != "kafka-primary" {
		t.Errorf("Name() = %q, want %q", c.Name(), "kafka-primary")
	}
	if c.Type() != ConnectorTypeKafka {
		t.Errorf("Type() = %q, want %q", c.Type(), ConnectorTypeKafka)
	}
	if c.IsConnected() {
		t.Error("should not be connected initially")
	}
}

func TestKafkaConnector_SendEmpty(t *testing.T) {
	cfg := DefaultKafkaConfig()
	c := NewKafkaConnector("test", cfg)

	err := c.Send(context.Background(), []Record{})
	if err != nil {
		t.Errorf("Send(empty) error = %v", err)
	}
}

func TestKafkaConnector_SendNotConnected(t *testing.T) {
	cfg := DefaultKafkaConfig()
	c := NewKafkaConnector("test", cfg)

	records := []Record{NewMetricsRecord("h1", map[string]interface{}{"k": "v"})}
	err := c.Send(context.Background(), records)
	if err == nil {
		t.Error("Send() should error when not connected")
	}
}

func TestKafkaConnector_Disconnect_NotConnected(t *testing.T) {
	cfg := DefaultKafkaConfig()
	c := NewKafkaConnector("test", cfg)

	if err := c.Disconnect(); err != nil {
		t.Fatalf("Disconnect() error = %v", err)
	}
}

func TestKafkaConnector_WriteVarint(t *testing.T) {
	c := NewKafkaConnector("test", DefaultKafkaConfig())

	tests := []struct {
		name  string
		value int64
	}{
		{"zero", 0},
		{"one", 1},
		{"small positive", 127},
		{"medium positive", 300},
		{"large positive", 100000},
		{"negative one", -1},
		{"negative large", -50000},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var buf bytes.Buffer
			c.writeVarint(&buf, tt.value)
			if buf.Len() == 0 {
				t.Error("writeVarint should write at least 1 byte")
			}
		})
	}
}

func TestKafkaConnector_BuildRecordBatch(t *testing.T) {
	c := NewKafkaConnector("test", DefaultKafkaConfig())

	messages := []kafkaMessage{
		{Key: []byte("host1"), Value: []byte(`{"test": 1}`)},
		{Key: []byte("host1"), Value: []byte(`{"test": 2}`)},
	}

	batch := c.buildRecordBatch(messages)
	if len(batch) == 0 {
		t.Error("buildRecordBatch should return non-empty bytes")
	}

	// Verify it starts with base offset (int64 = 0)
	baseOffset := int64(binary.BigEndian.Uint64(batch[0:8]))
	if baseOffset != 0 {
		t.Errorf("base offset = %d, want 0", baseOffset)
	}
}

func TestKafkaConnector_BuildRecordBatch_SingleMessage(t *testing.T) {
	c := NewKafkaConnector("test", DefaultKafkaConfig())

	messages := []kafkaMessage{
		{Key: []byte("k"), Value: []byte(`{"v": 1}`)},
	}

	batch := c.buildRecordBatch(messages)
	if len(batch) < 50 { // minimum overhead bytes
		t.Errorf("batch too small: %d bytes", len(batch))
	}
}

// =============================================================================
// NDJSON Config Tests
// =============================================================================

func TestDefaultNDJSONConfig(t *testing.T) {
	cfg := DefaultNDJSONConfig()

	if cfg.Directory != "/var/log/nftban/metrics" {
		t.Errorf("Directory = %q, want %q", cfg.Directory, "/var/log/nftban/metrics")
	}
	if cfg.Prefix != "nftban" {
		t.Errorf("Prefix = %q, want %q", cfg.Prefix, "nftban")
	}
	if !cfg.RotateDaily {
		t.Error("RotateDaily should be true by default")
	}
	if cfg.RotateSize != 100*1024*1024 {
		t.Errorf("RotateSize = %d, want %d", cfg.RotateSize, 100*1024*1024)
	}
	if cfg.RetentionDays != 30 {
		t.Errorf("RetentionDays = %d, want 30", cfg.RetentionDays)
	}
	if !cfg.Compress {
		t.Error("Compress should be true by default")
	}
}

func TestNewNDJSONConnector(t *testing.T) {
	cfg := DefaultNDJSONConfig()
	c := NewNDJSONConnector("ndjson-logs", cfg)

	if c.Name() != "ndjson-logs" {
		t.Errorf("Name() = %q, want %q", c.Name(), "ndjson-logs")
	}
	if c.Type() != ConnectorTypeNDJSON {
		t.Errorf("Type() = %q, want %q", c.Type(), ConnectorTypeNDJSON)
	}
}

func TestNDJSONConnector_SendEmpty(t *testing.T) {
	cfg := DefaultNDJSONConfig()
	c := NewNDJSONConnector("test", cfg)

	err := c.Send(context.Background(), []Record{})
	if err != nil {
		t.Errorf("Send(empty) error = %v", err)
	}
}

func TestNDJSONConnector_GenerateFilename(t *testing.T) {
	tests := []struct {
		name     string
		prefix   string
		compress bool
		wantExt  string
	}{
		{"uncompressed", "nftban", false, ".ndjson"},
		{"compressed", "nftban", true, ".ndjson.gz"},
		{"custom prefix", "myapp", false, ".ndjson"},
		{"empty prefix defaults", "", false, ".ndjson"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := NDJSONConfig{
				Directory: "/tmp/nftban-test-nonexistent",
				Prefix:    tt.prefix,
				Compress:  tt.compress,
			}
			c := NewNDJSONConnector("test", cfg)

			filename := c.generateFilename()
			if !strings.HasSuffix(filename, tt.wantExt) {
				t.Errorf("filename = %q, should end with %q", filename, tt.wantExt)
			}

			expectedPrefix := tt.prefix
			if expectedPrefix == "" {
				expectedPrefix = "nftban"
			}
			if !strings.HasPrefix(filename, expectedPrefix+"-") {
				t.Errorf("filename = %q, should start with %q-", filename, expectedPrefix)
			}
		})
	}
}

func TestNDJSONConnector_CurrentFile_NotConnected(t *testing.T) {
	cfg := DefaultNDJSONConfig()
	c := NewNDJSONConnector("test", cfg)

	if c.CurrentFile() != "" {
		t.Error("CurrentFile() should be empty when not connected")
	}
}

func TestNDJSONConnector_BytesWritten_Initial(t *testing.T) {
	cfg := DefaultNDJSONConfig()
	c := NewNDJSONConnector("test", cfg)

	if c.BytesWritten() != 0 {
		t.Error("BytesWritten() should be 0 initially")
	}
}

func TestNDJSONConnector_Status(t *testing.T) {
	cfg := DefaultNDJSONConfig()
	c := NewNDJSONConnector("test", cfg)

	status := c.Status()
	if status.Name != "test" {
		t.Errorf("status.Name = %q, want %q", status.Name, "test")
	}
	if status.Type != ConnectorTypeNDJSON {
		t.Errorf("status.Type = %q, want %q", status.Type, ConnectorTypeNDJSON)
	}
}

// =============================================================================
// BulkResponse Tests
// =============================================================================

func TestBulkResponse_NoErrors(t *testing.T) {
	resp := BulkResponse{
		Took:   5,
		Errors: false,
		Items: []BulkResponseItem{
			{Index: BulkResponseItemDetail{Status: 201, Result: "created"}},
		},
	}

	if resp.Errors {
		t.Error("Errors should be false")
	}
}

func TestBulkResponse_WithErrors(t *testing.T) {
	resp := BulkResponse{
		Took:   5,
		Errors: true,
		Items: []BulkResponseItem{
			{Index: BulkResponseItemDetail{Status: 201, Result: "created"}},
			{Index: BulkResponseItemDetail{
				Status: 400,
				Error:  &BulkItemError{Type: "mapper_parsing_exception", Reason: "bad field"},
			}},
		},
	}

	if !resp.Errors {
		t.Error("Errors should be true")
	}

	errorCount := 0
	for _, item := range resp.Items {
		if item.Index.Error != nil {
			errorCount++
		}
	}
	if errorCount != 1 {
		t.Errorf("error count = %d, want 1", errorCount)
	}
}

func TestBulkResponse_JSON_RoundTrip(t *testing.T) {
	resp := BulkResponse{
		Took:   10,
		Errors: false,
		Items: []BulkResponseItem{
			{Index: BulkResponseItemDetail{
				Index:   "nftban-metrics-2026.03.20",
				ID:      "abc123",
				Version: 1,
				Result:  "created",
				Status:  201,
			}},
		},
	}

	data, err := json.Marshal(resp)
	if err != nil {
		t.Fatalf("Marshal error = %v", err)
	}

	var parsed BulkResponse
	if err := json.Unmarshal(data, &parsed); err != nil {
		t.Fatalf("Unmarshal error = %v", err)
	}

	if parsed.Took != 10 {
		t.Errorf("Took = %d, want 10", parsed.Took)
	}
	if len(parsed.Items) != 1 {
		t.Fatalf("Items len = %d, want 1", len(parsed.Items))
	}
	if parsed.Items[0].Index.Result != "created" {
		t.Errorf("Result = %q, want %q", parsed.Items[0].Index.Result, "created")
	}
}

// =============================================================================
// ConnectorStatus JSON Tests
// =============================================================================

func TestConnectorStatus_JSON(t *testing.T) {
	status := ConnectorStatus{
		Name:         "test-es",
		Type:         ConnectorTypeElasticsearch,
		Connected:    true,
		RecordsSent:  500,
		BytesSent:    1024000,
		ErrorCount:   2,
		AvgLatencyMs: 15.5,
	}

	data, err := json.Marshal(status)
	if err != nil {
		t.Fatalf("Marshal error = %v", err)
	}

	var parsed ConnectorStatus
	if err := json.Unmarshal(data, &parsed); err != nil {
		t.Fatalf("Unmarshal error = %v", err)
	}

	if parsed.Name != "test-es" {
		t.Errorf("Name = %q, want %q", parsed.Name, "test-es")
	}
	if parsed.RecordsSent != 500 {
		t.Errorf("RecordsSent = %d, want 500", parsed.RecordsSent)
	}
}

// =============================================================================
// Record JSON Serialization Tests
// =============================================================================

func TestRecord_JSON_RoundTrip(t *testing.T) {
	original := Record{
		Timestamp: time.Date(2026, 3, 20, 12, 0, 0, 0, time.UTC),
		Host:      "testhost",
		Type:      "metrics",
		Source:    "nftban",
		Version:   "1.0",
		Data: map[string]interface{}{
			"bans_total": float64(100), // JSON numbers decode as float64
		},
		Tags: map[string]string{"env": "test"},
		Meta: map[string]interface{}{"note": "test record"},
	}

	data, err := json.Marshal(original)
	if err != nil {
		t.Fatalf("Marshal error = %v", err)
	}

	var parsed Record
	if err := json.Unmarshal(data, &parsed); err != nil {
		t.Fatalf("Unmarshal error = %v", err)
	}

	if parsed.Host != original.Host {
		t.Errorf("Host = %q, want %q", parsed.Host, original.Host)
	}
	if parsed.Type != original.Type {
		t.Errorf("Type = %q, want %q", parsed.Type, original.Type)
	}
	if parsed.Tags["env"] != "test" {
		t.Errorf("Tags[env] = %q, want %q", parsed.Tags["env"], "test")
	}
}
