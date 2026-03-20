// =============================================================================
// NFTBan - Zabbix Exporter Package Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="zabbix_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Tests for Zabbix exporter: protocol encode/decode, discovery, sender, config, types"
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

package zabbix

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
)

// =============================================================================
// Protocol Encode Tests
// =============================================================================

func TestEncode_BasicRequest(t *testing.T) {
	req := &TrapperRequest{
		Request: "sender data",
		Data: []TrapperItem{
			{Host: "host1", Key: "nftban.test", Value: "42", Clock: 1000, Ns: 0},
		},
		Clock: 1000,
		Ns:    0,
	}

	data, err := Encode(req)
	if err != nil {
		t.Fatalf("Encode() error = %v", err)
	}

	// Verify header bytes
	if !bytes.Equal(data[0:5], headerBytes) {
		t.Errorf("header = %x, want %x", data[0:5], headerBytes)
	}

	// Verify length field
	payloadLen := binary.LittleEndian.Uint64(data[5:13])
	actualPayloadLen := uint64(len(data) - headerSize)
	if payloadLen != actualPayloadLen {
		t.Errorf("payload length = %d, want %d", payloadLen, actualPayloadLen)
	}

	// Verify payload is valid JSON
	var decoded TrapperRequest
	if err := json.Unmarshal(data[13:], &decoded); err != nil {
		t.Fatalf("payload JSON unmarshal error = %v", err)
	}
	if decoded.Request != "sender data" {
		t.Errorf("decoded request = %q, want %q", decoded.Request, "sender data")
	}
	if len(decoded.Data) != 1 {
		t.Fatalf("decoded data len = %d, want 1", len(decoded.Data))
	}
	if decoded.Data[0].Host != "host1" {
		t.Errorf("decoded host = %q, want %q", decoded.Data[0].Host, "host1")
	}
}

func TestEncode_EmptyData(t *testing.T) {
	req := &TrapperRequest{
		Request: "sender data",
		Data:    []TrapperItem{},
	}

	data, err := Encode(req)
	if err != nil {
		t.Fatalf("Encode() error = %v", err)
	}
	if len(data) <= headerSize {
		t.Error("encoded data should be larger than header")
	}
}

func TestEncode_MultipleItems(t *testing.T) {
	items := make([]TrapperItem, 50)
	for i := range items {
		items[i] = TrapperItem{
			Host:  "testhost",
			Key:   fmt.Sprintf("nftban.metric.%d", i),
			Value: fmt.Sprintf("%d", i*10),
			Clock: 1000,
		}
	}

	req := &TrapperRequest{
		Request: "sender data",
		Data:    items,
		Clock:   1000,
	}

	data, err := Encode(req)
	if err != nil {
		t.Fatalf("Encode() error = %v", err)
	}

	// Decode the payload and verify item count
	var decoded TrapperRequest
	if err := json.Unmarshal(data[13:], &decoded); err != nil {
		t.Fatalf("Unmarshal error = %v", err)
	}
	if len(decoded.Data) != 50 {
		t.Errorf("decoded item count = %d, want 50", len(decoded.Data))
	}
}

// =============================================================================
// Protocol Decode Tests
// =============================================================================

func TestDecode_ValidResponse(t *testing.T) {
	// Build a valid protocol message
	payload := []byte(`{"response":"success","info":"processed: 10; failed: 0; total: 10; seconds spent: 0.001"}`)

	buf := &bytes.Buffer{}
	buf.Write(headerBytes)
	lenBuf := make([]byte, 8)
	binary.LittleEndian.PutUint64(lenBuf, uint64(len(payload)))
	buf.Write(lenBuf)
	buf.Write(payload)

	resp, err := Decode(buf)
	if err != nil {
		t.Fatalf("Decode() error = %v", err)
	}
	if resp.Response != "success" {
		t.Errorf("response = %q, want %q", resp.Response, "success")
	}
	if !resp.IsSuccess() {
		t.Error("IsSuccess() = false, want true")
	}
}

func TestDecode_FailureResponse(t *testing.T) {
	payload := []byte(`{"response":"failed","info":"processed: 0; failed: 5; total: 5; seconds spent: 0.000"}`)

	buf := &bytes.Buffer{}
	buf.Write(headerBytes)
	lenBuf := make([]byte, 8)
	binary.LittleEndian.PutUint64(lenBuf, uint64(len(payload)))
	buf.Write(lenBuf)
	buf.Write(payload)

	resp, err := Decode(buf)
	if err != nil {
		t.Fatalf("Decode() error = %v", err)
	}
	if resp.IsSuccess() {
		t.Error("IsSuccess() = true, want false")
	}
}

func TestDecode_InvalidHeader(t *testing.T) {
	buf := bytes.NewBufferString("INVALID_HEADER_DATA_HERE!")
	_, err := Decode(buf)
	if err == nil {
		t.Error("Decode() should return error for invalid header")
	}
}

func TestDecode_TruncatedHeader(t *testing.T) {
	buf := bytes.NewBuffer([]byte{0x5A, 0x42}) // partial header
	_, err := Decode(buf)
	if err == nil {
		t.Error("Decode() should return error for truncated header")
	}
}

func TestDecode_OversizedPayload(t *testing.T) {
	buf := &bytes.Buffer{}
	buf.Write(headerBytes)
	lenBuf := make([]byte, 8)
	// Set length to exceed maxResponseSize (1MB)
	binary.LittleEndian.PutUint64(lenBuf, uint64(maxResponseSize+1))
	buf.Write(lenBuf)

	_, err := Decode(buf)
	if err == nil {
		t.Error("Decode() should return error for oversized payload")
	}
}

func TestEncodeDecode_RoundTrip(t *testing.T) {
	req := &TrapperRequest{
		Request: "sender data",
		Data: []TrapperItem{
			{Host: "h1", Key: "k1", Value: "v1", Clock: 1234, Ns: 5678},
		},
		Clock: 1234,
		Ns:    5678,
	}

	encoded, err := Encode(req)
	if err != nil {
		t.Fatalf("Encode() error = %v", err)
	}

	// Build a "response" message using the same encoding scheme
	// to simulate a server response
	respJSON := []byte(`{"response":"success","info":"processed: 1; failed: 0; total: 1; seconds spent: 0.001"}`)
	respBuf := &bytes.Buffer{}
	respBuf.Write(headerBytes)
	lenBuf := make([]byte, 8)
	binary.LittleEndian.PutUint64(lenBuf, uint64(len(respJSON)))
	respBuf.Write(lenBuf)
	respBuf.Write(respJSON)

	resp, err := Decode(respBuf)
	if err != nil {
		t.Fatalf("Decode() error = %v", err)
	}
	if !resp.IsSuccess() {
		t.Error("response should be success")
	}

	// Verify request payload can be re-parsed
	var decoded TrapperRequest
	if err := json.Unmarshal(encoded[headerSize:], &decoded); err != nil {
		t.Fatalf("re-parse error = %v", err)
	}
	if decoded.Data[0].Key != "k1" {
		t.Errorf("key = %q, want %q", decoded.Data[0].Key, "k1")
	}
}

// =============================================================================
// ParseInfoString Tests
// =============================================================================

func TestParseInfoString(t *testing.T) {
	tests := []struct {
		name      string
		info      string
		processed int
		failed    int
		total     int
		seconds   float64
	}{
		{
			name:      "standard success",
			info:      "processed: 10; failed: 0; total: 10; seconds spent: 0.001234",
			processed: 10, failed: 0, total: 10, seconds: 0.001234,
		},
		{
			name:      "with failures",
			info:      "processed: 8; failed: 2; total: 10; seconds spent: 0.500",
			processed: 8, failed: 2, total: 10, seconds: 0.5,
		},
		{
			name:      "large numbers",
			info:      "processed: 100000; failed: 50; total: 100050; seconds spent: 5.123",
			processed: 100000, failed: 50, total: 100050, seconds: 5.123,
		},
		{
			name:      "zero everything",
			info:      "processed: 0; failed: 0; total: 0; seconds spent: 0.000",
			processed: 0, failed: 0, total: 0, seconds: 0,
		},
		{
			name:      "invalid format",
			info:      "something else entirely",
			processed: 0, failed: 0, total: 0, seconds: 0,
		},
		{
			name:      "empty string",
			info:      "",
			processed: 0, failed: 0, total: 0, seconds: 0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := ParseInfoString(tt.info)
			if result.Processed != tt.processed {
				t.Errorf("Processed = %d, want %d", result.Processed, tt.processed)
			}
			if result.Failed != tt.failed {
				t.Errorf("Failed = %d, want %d", result.Failed, tt.failed)
			}
			if result.Total != tt.total {
				t.Errorf("Total = %d, want %d", result.Total, tt.total)
			}
			if result.Seconds != tt.seconds {
				t.Errorf("Seconds = %f, want %f", result.Seconds, tt.seconds)
			}
		})
	}
}

// =============================================================================
// FormatValue / StringValue Tests
// =============================================================================

func TestMetric_StringValue(t *testing.T) {
	tests := []struct {
		name  string
		value interface{}
		want  string
	}{
		{"string", "hello", "hello"},
		{"int", 42, "42"},
		{"int32", int32(100), "100"},
		{"int64", int64(9999), "9999"},
		{"uint", uint(7), "7"},
		{"uint32", uint32(255), "255"},
		{"uint64", uint64(12345678), "12345678"},
		{"float32", float32(3.14), "3.14"},
		{"float64", float64(2.71828), "2.71828"},
		{"bool true", true, "1"},
		{"bool false", false, "0"},
		{"nil via json", nil, "null"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			m := &Metric{Value: tt.value}
			got := m.StringValue()
			if got != tt.want {
				t.Errorf("StringValue() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestFormatValue(t *testing.T) {
	tests := []struct {
		name  string
		value interface{}
		want  string
	}{
		{"string", "test", "test"},
		{"bytes", []byte("data"), "data"},
		{"int", 42, "42"},
		{"int8", int8(7), "7"},
		{"int16", int16(300), "300"},
		{"int32", int32(-1), "-1"},
		{"int64", int64(1234567890), "1234567890"},
		{"uint", uint(100), "100"},
		{"uint8", uint8(255), "255"},
		{"uint16", uint16(65535), "65535"},
		{"uint32", uint32(4294967295), "4294967295"},
		{"uint64", uint64(18446744073709551615), "18446744073709551615"},
		{"float32", float32(1.5), "1.5"},
		{"float64", float64(3.14159), "3.14159"},
		{"bool true", true, "1"},
		{"bool false", false, "0"},
		{"nil", nil, ""},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := formatValue(tt.value)
			if got != tt.want {
				t.Errorf("formatValue(%v) = %q, want %q", tt.value, got, tt.want)
			}
		})
	}
}

// =============================================================================
// BuildKey / ParseKey Tests
// =============================================================================

func TestBuildKey(t *testing.T) {
	tests := []struct {
		name   string
		base   string
		params []string
		want   string
	}{
		{"no params", "nftban.test", nil, "nftban.test"},
		{"empty params", "nftban.test", []string{}, "nftban.test"},
		{"one param", "nftban.module.status", []string{"portscan"}, "nftban.module.status[portscan]"},
		{"two params", "nftban.metric", []string{"a", "b"}, "nftban.metric[a,b]"},
		{"three params", "nftban.x", []string{"1", "2", "3"}, "nftban.x[1,2,3]"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := BuildKey(tt.base, tt.params...)
			if got != tt.want {
				t.Errorf("BuildKey() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestParseKey(t *testing.T) {
	tests := []struct {
		name       string
		key        string
		wantBase   string
		wantParams []string
	}{
		{"no params", "nftban.test", "nftban.test", nil},
		{"one param", "nftban.module.status[portscan]", "nftban.module.status", []string{"portscan"}},
		{"two params", "nftban.metric[a,b]", "nftban.metric", []string{"a", "b"}},
		{"empty brackets", "nftban.test[]", "nftban.test", nil},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			base, params := ParseKey(tt.key)
			if base != tt.wantBase {
				t.Errorf("base = %q, want %q", base, tt.wantBase)
			}
			if tt.wantParams == nil && params != nil {
				t.Errorf("params = %v, want nil", params)
			}
			if tt.wantParams != nil {
				if len(params) != len(tt.wantParams) {
					t.Fatalf("params len = %d, want %d", len(params), len(tt.wantParams))
				}
				for i, p := range params {
					if p != tt.wantParams[i] {
						t.Errorf("params[%d] = %q, want %q", i, p, tt.wantParams[i])
					}
				}
			}
		})
	}
}

func TestBuildParseKey_RoundTrip(t *testing.T) {
	tests := []struct {
		base   string
		params []string
	}{
		{"nftban.module.status", []string{"portscan"}},
		{"nftban.metric", []string{"a", "b", "c"}},
	}

	for _, tt := range tests {
		key := BuildKey(tt.base, tt.params...)
		gotBase, gotParams := ParseKey(key)
		if gotBase != tt.base {
			t.Errorf("round-trip base = %q, want %q", gotBase, tt.base)
		}
		if len(gotParams) != len(tt.params) {
			t.Errorf("round-trip params len = %d, want %d", len(gotParams), len(tt.params))
		}
	}
}

// =============================================================================
// ValidateKey Tests
// =============================================================================

func TestValidateKey(t *testing.T) {
	tests := []struct {
		name    string
		key     string
		wantErr bool
	}{
		{"valid simple", "nftban.test", false},
		{"valid with params", "nftban.module[portscan]", false},
		{"valid with multiple params", "nftban.x[a,b]", false},
		{"valid with hyphens", "nftban.my-key", false},
		{"valid with underscore", "nftban.my_key", false},
		{"empty", "", true},
		{"too long", strings.Repeat("a", 2049), true},
		{"invalid chars space", "nftban test", true},
		{"invalid chars exclamation", "nftban!", true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := ValidateKey(tt.key)
			if (err != nil) != tt.wantErr {
				t.Errorf("ValidateKey(%q) error = %v, wantErr %v", tt.key, err, tt.wantErr)
			}
		})
	}
}

// =============================================================================
// ValidateHostname Tests
// =============================================================================

func TestValidateHostname(t *testing.T) {
	tests := []struct {
		name    string
		host    string
		wantErr bool
	}{
		{"valid", "myhost.example.com", false},
		{"valid short", "h", false},
		{"empty", "", true},
		{"too long", strings.Repeat("x", 129), true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := ValidateHostname(tt.host)
			if (err != nil) != tt.wantErr {
				t.Errorf("ValidateHostname(%q) error = %v, wantErr %v", tt.host, err, tt.wantErr)
			}
		})
	}
}

// =============================================================================
// SplitIntoBatches Tests
// =============================================================================

func TestSplitIntoBatches(t *testing.T) {
	tests := []struct {
		name      string
		count     int
		batchSize int
		wantLen   int
		wantLast  int // size of last batch
	}{
		{"exact fit", 10, 5, 2, 5},
		{"remainder", 11, 5, 3, 1},
		{"single item", 1, 5, 1, 1},
		{"empty", 0, 5, 0, 0},
		{"batch larger than input", 3, 10, 1, 3},
		{"batch size 1", 5, 1, 5, 1},
		{"zero batch size uses default", 5, 0, 1, 5},
		{"negative batch size uses default", 5, -1, 1, 5},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			metrics := make([]Metric, tt.count)
			for i := range metrics {
				metrics[i] = Metric{Name: fmt.Sprintf("m%d", i), Value: i}
			}

			batches := SplitIntoBatches(metrics, tt.batchSize)
			if len(batches) != tt.wantLen {
				t.Errorf("batches count = %d, want %d", len(batches), tt.wantLen)
			}
			if tt.wantLen > 0 && len(batches[len(batches)-1]) != tt.wantLast {
				t.Errorf("last batch size = %d, want %d", len(batches[len(batches)-1]), tt.wantLast)
			}
		})
	}
}

// =============================================================================
// FormatDiscoveryData Tests
// =============================================================================

func TestFormatDiscoveryData(t *testing.T) {
	items := []map[string]string{
		{"{#MODULE}": "portscan", "{#MODE}": "active"},
		{"{#MODULE}": "ddos", "{#MODE}": "passive"},
	}

	result, err := FormatDiscoveryData(items)
	if err != nil {
		t.Fatalf("FormatDiscoveryData() error = %v", err)
	}

	// Verify JSON structure
	var parsed struct {
		Data []map[string]string `json:"data"`
	}
	if err := json.Unmarshal([]byte(result), &parsed); err != nil {
		t.Fatalf("JSON parse error = %v", err)
	}
	if len(parsed.Data) != 2 {
		t.Errorf("data len = %d, want 2", len(parsed.Data))
	}
	if parsed.Data[0]["{#MODULE}"] != "portscan" {
		t.Errorf("first module = %q, want %q", parsed.Data[0]["{#MODULE}"], "portscan")
	}
}

func TestFormatDiscoveryData_Empty(t *testing.T) {
	result, err := FormatDiscoveryData([]map[string]string{})
	if err != nil {
		t.Fatalf("FormatDiscoveryData() error = %v", err)
	}

	var parsed struct {
		Data []map[string]string `json:"data"`
	}
	if err := json.Unmarshal([]byte(result), &parsed); err != nil {
		t.Fatalf("JSON parse error = %v", err)
	}
	if len(parsed.Data) != 0 {
		t.Errorf("data len = %d, want 0", len(parsed.Data))
	}
}

func TestFormatModuleDiscovery(t *testing.T) {
	modules := []DiscoveredModule{
		{Module: "portscan", Mode: "active", Enabled: 1},
		{Module: "ddos", Mode: "passive", Enabled: 0},
	}

	result, err := FormatModuleDiscovery(modules)
	if err != nil {
		t.Fatalf("FormatModuleDiscovery() error = %v", err)
	}
	if !strings.Contains(result, "portscan") {
		t.Error("result should contain 'portscan'")
	}
	if !strings.Contains(result, `"{#ENABLED}"`) || !strings.Contains(result, `"1"`) {
		t.Error("result should contain enabled status")
	}
}

func TestFormatInterfaceDiscovery(t *testing.T) {
	interfaces := []DiscoveredInterface{
		{Interface: "eth0", Zone: "public"},
	}

	result, err := FormatInterfaceDiscovery(interfaces)
	if err != nil {
		t.Fatalf("FormatInterfaceDiscovery() error = %v", err)
	}
	if !strings.Contains(result, "eth0") {
		t.Error("result should contain 'eth0'")
	}
}

func TestFormatCountryDiscovery(t *testing.T) {
	countries := []DiscoveredCountry{
		{Country: "CN", CountryName: "China", Blocked: 1},
		{Country: "US", CountryName: "United States", Blocked: 0},
	}

	result, err := FormatCountryDiscovery(countries)
	if err != nil {
		t.Fatalf("FormatCountryDiscovery() error = %v", err)
	}
	if !strings.Contains(result, "CN") || !strings.Contains(result, "China") {
		t.Error("result should contain country data")
	}
}

func TestFormatFeedDiscovery(t *testing.T) {
	feeds := []DiscoveredFeed{
		{Feed: "spamhaus", URL: "https://example.com/drop.txt", Enabled: 1},
	}

	result, err := FormatFeedDiscovery(feeds)
	if err != nil {
		t.Fatalf("FormatFeedDiscovery() error = %v", err)
	}
	if !strings.Contains(result, "spamhaus") {
		t.Error("result should contain feed name")
	}
}

func TestFormatTimerDiscovery(t *testing.T) {
	timers := []DiscoveredTimer{
		{Timer: "nftban-sync", Duration: "60s"},
	}

	result, err := FormatTimerDiscovery(timers)
	if err != nil {
		t.Fatalf("FormatTimerDiscovery() error = %v", err)
	}
	if !strings.Contains(result, "nftban-sync") {
		t.Error("result should contain timer name")
	}
}

// =============================================================================
// Config Tests
// =============================================================================

func TestDefaultConfig(t *testing.T) {
	cfg := DefaultConfig()

	if cfg.Enabled {
		t.Error("default config should be disabled")
	}
	if cfg.Hostname == "" {
		t.Error("default hostname should not be empty")
	}
	if cfg.Interval != 60*time.Second {
		t.Errorf("default interval = %v, want 60s", cfg.Interval)
	}
	if cfg.BatchSize != 100 {
		t.Errorf("default batch_size = %d, want 100", cfg.BatchSize)
	}
	if cfg.RetryCount != 3 {
		t.Errorf("default retry_count = %d, want 3", cfg.RetryCount)
	}
	if cfg.LogLevel != "info" {
		t.Errorf("default log_level = %q, want %q", cfg.LogLevel, "info")
	}
	if !cfg.BufferEnabled {
		t.Error("default buffer should be enabled")
	}
	if !cfg.DiscoveryEnabled {
		t.Error("default discovery should be enabled")
	}
}

func TestDefaultTargetConfig(t *testing.T) {
	tc := DefaultTargetConfig("primary", "10.0.0.1")

	if tc.Name != "primary" {
		t.Errorf("name = %q, want %q", tc.Name, "primary")
	}
	if tc.Address != "10.0.0.1" {
		t.Errorf("address = %q, want %q", tc.Address, "10.0.0.1")
	}
	if tc.Port != DefaultPort {
		t.Errorf("port = %d, want %d", tc.Port, DefaultPort)
	}
	if !tc.Enabled {
		t.Error("default target should be enabled")
	}
}

func TestConfig_Validate_Disabled(t *testing.T) {
	cfg := &Config{Enabled: false}
	if err := cfg.Validate(); err != nil {
		t.Errorf("disabled config should not fail validation, got %v", err)
	}
}

func TestConfig_Validate_NoTargets(t *testing.T) {
	cfg := DefaultConfig()
	cfg.Enabled = true

	err := cfg.Validate()
	if err == nil {
		t.Error("enabled config with no targets should fail")
	}
	if !strings.Contains(err.Error(), "at least one target") {
		t.Errorf("error should mention targets, got %q", err.Error())
	}
}

func TestConfig_Validate_IntervalTooSmall(t *testing.T) {
	cfg := DefaultConfig()
	cfg.Enabled = true
	cfg.Targets = []TargetConfig{DefaultTargetConfig("t1", "127.0.0.1")}
	cfg.Interval = 5 * time.Second

	err := cfg.Validate()
	if err == nil {
		t.Error("interval < 10s should fail validation")
	}
	if !strings.Contains(err.Error(), "interval must be at least 10 seconds") {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestConfig_Validate_IntervalTooLarge(t *testing.T) {
	cfg := DefaultConfig()
	cfg.Enabled = true
	cfg.Targets = []TargetConfig{DefaultTargetConfig("t1", "127.0.0.1")}
	cfg.Interval = 2 * time.Hour

	err := cfg.Validate()
	if err == nil {
		t.Error("interval > 1 hour should fail validation")
	}
}

func TestConfig_Validate_BatchSizeBounds(t *testing.T) {
	tests := []struct {
		name      string
		batchSize int
		wantErr   bool
	}{
		{"too small", 0, true},
		{"minimum", 1, false},
		{"normal", 100, false},
		{"maximum", 10000, false},
		{"too large", 10001, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := DefaultConfig()
			cfg.Enabled = true
			cfg.Targets = []TargetConfig{DefaultTargetConfig("t1", "127.0.0.1")}
			cfg.BatchSize = tt.batchSize

			err := cfg.Validate()
			if (err != nil) != tt.wantErr {
				t.Errorf("Validate() error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}

func TestConfig_Validate_InvalidLogLevel(t *testing.T) {
	cfg := DefaultConfig()
	cfg.Enabled = true
	cfg.Targets = []TargetConfig{DefaultTargetConfig("t1", "127.0.0.1")}
	cfg.LogLevel = "trace"

	err := cfg.Validate()
	if err == nil {
		t.Error("invalid log level should fail validation")
	}
}

func TestConfig_Validate_ValidLogLevels(t *testing.T) {
	for _, level := range []string{"debug", "info", "warn", "error"} {
		cfg := DefaultConfig()
		cfg.Enabled = true
		cfg.Targets = []TargetConfig{DefaultTargetConfig("t1", "127.0.0.1")}
		cfg.LogLevel = level

		err := cfg.Validate()
		if err != nil {
			t.Errorf("log level %q should be valid, got %v", level, err)
		}
	}
}

func TestConfig_Validate_RetryCountBounds(t *testing.T) {
	tests := []struct {
		name    string
		count   int
		wantErr bool
	}{
		{"negative", -1, true},
		{"zero", 0, false},
		{"normal", 3, false},
		{"max", 10, false},
		{"too high", 11, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := DefaultConfig()
			cfg.Enabled = true
			cfg.Targets = []TargetConfig{DefaultTargetConfig("t1", "127.0.0.1")}
			cfg.RetryCount = tt.count

			err := cfg.Validate()
			if (err != nil) != tt.wantErr {
				t.Errorf("Validate() error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}

func TestTargetConfig_Validate(t *testing.T) {
	tests := []struct {
		name    string
		target  TargetConfig
		wantErr bool
	}{
		{
			name:    "valid IP",
			target:  TargetConfig{Name: "t1", Address: "10.0.0.1", Port: 10051},
			wantErr: false,
		},
		{
			name:    "valid hostname",
			target:  TargetConfig{Name: "t1", Address: "zabbix.example.com", Port: 10051},
			wantErr: false,
		},
		{
			name:    "missing name",
			target:  TargetConfig{Address: "10.0.0.1", Port: 10051},
			wantErr: true,
		},
		{
			name:    "missing address",
			target:  TargetConfig{Name: "t1", Port: 10051},
			wantErr: true,
		},
		{
			name:    "invalid port zero",
			target:  TargetConfig{Name: "t1", Address: "10.0.0.1", Port: 0},
			wantErr: true,
		},
		{
			name:    "invalid port too high",
			target:  TargetConfig{Name: "t1", Address: "10.0.0.1", Port: 70000},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.target.Validate()
			if (err != nil) != tt.wantErr {
				t.Errorf("Validate() error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}

func TestConfig_GetEnabledTargets(t *testing.T) {
	cfg := &Config{
		Targets: []TargetConfig{
			{Name: "low-prio", Enabled: true, Priority: 3, Address: "a", Port: 10051},
			{Name: "disabled", Enabled: false, Priority: 1, Address: "b", Port: 10051},
			{Name: "high-prio", Enabled: true, Priority: 1, Address: "c", Port: 10051},
			{Name: "mid-prio", Enabled: true, Priority: 2, Address: "d", Port: 10051},
		},
	}

	enabled := cfg.GetEnabledTargets()
	if len(enabled) != 3 {
		t.Fatalf("enabled count = %d, want 3", len(enabled))
	}
	// Should be sorted by priority
	if enabled[0].Name != "high-prio" {
		t.Errorf("first enabled = %q, want %q", enabled[0].Name, "high-prio")
	}
	if enabled[1].Name != "mid-prio" {
		t.Errorf("second enabled = %q, want %q", enabled[1].Name, "mid-prio")
	}
	if enabled[2].Name != "low-prio" {
		t.Errorf("third enabled = %q, want %q", enabled[2].Name, "low-prio")
	}
}

func TestConfig_ApplyDefaults(t *testing.T) {
	cfg := &Config{
		Targets: []TargetConfig{
			{Name: "t1", Address: "10.0.0.1"},
		},
	}
	cfg.ApplyDefaults()

	if cfg.Hostname == "" {
		t.Error("hostname should be set after ApplyDefaults")
	}
	if cfg.Interval != 60*time.Second {
		t.Errorf("interval = %v, want 60s", cfg.Interval)
	}
	if cfg.Targets[0].Port != DefaultPort {
		t.Errorf("target port = %d, want %d", cfg.Targets[0].Port, DefaultPort)
	}
	if cfg.LogLevel != "info" {
		t.Errorf("log_level = %q, want %q", cfg.LogLevel, "info")
	}
}

func TestTargetConfig_ToTarget(t *testing.T) {
	tc := TargetConfig{
		Name:    "primary",
		Address: "10.0.0.1",
		Port:    10051,
		Enabled: true,
	}

	target := tc.ToTarget()
	if target.Name != "primary" {
		t.Errorf("name = %q, want %q", target.Name, "primary")
	}
	if target.TLS != nil {
		t.Error("TLS should be nil when not enabled")
	}
}

func TestTargetConfig_ToTarget_WithTLS(t *testing.T) {
	tc := TargetConfig{
		Name:    "secure",
		Address: "10.0.0.1",
		Port:    10051,
		TLS: TLSTargetConfig{
			Enabled:  true,
			CertFile: "/path/cert",
			KeyFile:  "/path/key",
			CAFile:   "/path/ca",
		},
	}

	target := tc.ToTarget()
	if target.TLS == nil {
		t.Fatal("TLS should not be nil when enabled")
	}
	if !target.TLS.Enabled {
		t.Error("TLS.Enabled should be true")
	}
	if target.TLS.CertFile != "/path/cert" {
		t.Errorf("CertFile = %q, want %q", target.TLS.CertFile, "/path/cert")
	}
}

// =============================================================================
// Type Tests
// =============================================================================

func TestTrapperResponse_IsSuccess(t *testing.T) {
	tests := []struct {
		response string
		want     bool
	}{
		{"success", true},
		{"failed", false},
		{"error", false},
		{"", false},
	}

	for _, tt := range tests {
		resp := &TrapperResponse{Response: tt.response}
		if got := resp.IsSuccess(); got != tt.want {
			t.Errorf("IsSuccess(%q) = %v, want %v", tt.response, got, tt.want)
		}
	}
}

func TestBatch_Size(t *testing.T) {
	b := &Batch{
		Metrics: make([]Metric, 5),
	}
	if b.Size() != 5 {
		t.Errorf("Size() = %d, want 5", b.Size())
	}
}

func TestBatch_ToTrapperRequest(t *testing.T) {
	ts := time.Date(2026, 3, 20, 12, 0, 0, 0, time.UTC)
	b := &Batch{
		Metrics: []Metric{
			{Name: "nftban.test", Value: 42},
			{Name: "nftban.version", Value: "1.25.0"},
		},
		Host:      "testhost",
		Timestamp: ts,
	}

	req := b.ToTrapperRequest()
	if req.Request != "sender data" {
		t.Errorf("Request = %q, want %q", req.Request, "sender data")
	}
	if len(req.Data) != 2 {
		t.Fatalf("Data len = %d, want 2", len(req.Data))
	}
	if req.Data[0].Host != "testhost" {
		t.Errorf("Data[0].Host = %q, want %q", req.Data[0].Host, "testhost")
	}
	if req.Data[0].Key != "nftban.test" {
		t.Errorf("Data[0].Key = %q, want %q", req.Data[0].Key, "nftban.test")
	}
	if req.Data[0].Value != "42" {
		t.Errorf("Data[0].Value = %q, want %q", req.Data[0].Value, "42")
	}
	if req.Clock != ts.Unix() {
		t.Errorf("Clock = %d, want %d", req.Clock, ts.Unix())
	}
}

func TestSendError(t *testing.T) {
	// Error without cause
	e1 := &SendError{Target: "primary", Message: "connection refused"}
	if !strings.Contains(e1.Error(), "primary") {
		t.Error("error should contain target name")
	}
	if !strings.Contains(e1.Error(), "connection refused") {
		t.Error("error should contain message")
	}
	if e1.Unwrap() != nil {
		t.Error("Unwrap should return nil when no cause")
	}

	// Error with cause
	cause := errors.New("timeout")
	e2 := &SendError{Target: "secondary", Message: "send failed", Cause: cause}
	if !strings.Contains(e2.Error(), "secondary") {
		t.Error("error should contain target name")
	}
	if !strings.Contains(e2.Error(), "timeout") {
		t.Error("error should contain cause")
	}
	if e2.Unwrap() != cause {
		t.Error("Unwrap should return the cause")
	}
}

func TestDiscoveryError(t *testing.T) {
	// Without cause
	e1 := &DiscoveryError{Key: "nftban.discovery.modules", Message: "not found"}
	if !strings.Contains(e1.Error(), "modules") {
		t.Error("error should contain key")
	}
	if e1.Unwrap() != nil {
		t.Error("Unwrap should return nil when no cause")
	}

	// With cause
	cause := errors.New("network error")
	e2 := &DiscoveryError{Key: "nftban.discovery.feeds", Message: "refresh failed", Cause: cause}
	if !strings.Contains(e2.Error(), "feeds") {
		t.Error("error should contain key")
	}
	if e2.Unwrap() != cause {
		t.Error("Unwrap should return the cause")
	}
}

// =============================================================================
// EncodeMetrics Tests
// =============================================================================

func TestEncodeMetrics(t *testing.T) {
	metrics := []Metric{
		{Name: "nftban.bans.total", Value: int64(100), Timestamp: time.Now()},
		{Name: "nftban.version", Value: "1.25.0", Timestamp: time.Now()},
	}

	data, err := EncodeMetrics("testhost", metrics)
	if err != nil {
		t.Fatalf("EncodeMetrics() error = %v", err)
	}

	// Verify header
	if !bytes.Equal(data[0:5], headerBytes) {
		t.Error("invalid header")
	}

	// Verify payload
	var req TrapperRequest
	if err := json.Unmarshal(data[headerSize:], &req); err != nil {
		t.Fatalf("JSON unmarshal error = %v", err)
	}
	if len(req.Data) != 2 {
		t.Errorf("data len = %d, want 2", len(req.Data))
	}
	if req.Data[0].Host != "testhost" {
		t.Errorf("host = %q, want %q", req.Data[0].Host, "testhost")
	}
}

// =============================================================================
// isValidHostname Tests
// =============================================================================

func TestIsValidHostname(t *testing.T) {
	tests := []struct {
		name     string
		hostname string
		want     bool
	}{
		{"simple", "myhost", true},
		{"fqdn", "host.example.com", true},
		{"with hyphens", "my-host.example.com", true},
		{"single char", "a", true},
		{"empty", "", false},
		{"starts with hyphen", "-host", false},
		{"ends with hyphen", "host-", false},
		{"dot only", ".", false},
		{"double dot", "host..com", false},
		{"too long label", strings.Repeat("a", 64), false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := isValidHostname(tt.hostname)
			if got != tt.want {
				t.Errorf("isValidHostname(%q) = %v, want %v", tt.hostname, got, tt.want)
			}
		})
	}
}

// =============================================================================
// Discovery Manager Tests (with mock source)
// =============================================================================

// mockMetricsSource implements MetricsSource for testing
type mockMetricsSource struct {
	discovery DiscoveryInfo
}

func (m *mockMetricsSource) GetDaemonInfo() DaemonInfo {
	return DaemonInfo{Version: "1.25.0", Mode: "normal", PID: 1234, StartTime: time.Now()}
}
func (m *mockMetricsSource) GetRuntimeMetrics() RuntimeInfo {
	return RuntimeInfo{HeapAlloc: 1024, Goroutines: 10}
}
func (m *mockMetricsSource) GetBanStats() BanStats {
	return BanStats{Total: 100, ActiveCount: 50}
}
func (m *mockMetricsSource) GetEventStats() EventStats {
	return EventStats{Total: 500, RatePerSec: 1.5}
}
func (m *mockMetricsSource) GetIPCStats() IPCStats {
	return IPCStats{Requests: 1000}
}
func (m *mockMetricsSource) GetModuleStatus() map[string]ModuleInfo {
	return map[string]ModuleInfo{
		"portscan": {Name: "portscan", Enabled: true, Status: 1},
	}
}
func (m *mockMetricsSource) GetWatchdogStatus() WatchdogInfo {
	return WatchdogInfo{Status: 1, Mode: "normal"}
}
func (m *mockMetricsSource) GetNFTablesStats() NFTablesInfo {
	return NFTablesInfo{RulesTotal: 50, SetsTotal: 10}
}
func (m *mockMetricsSource) GetFeedStats() FeedStats {
	return FeedStats{Enabled: 5, Loaded: 5}
}
func (m *mockMetricsSource) GetGeoIPStats() GeoIPStats {
	return GeoIPStats{DatabaseAge: 5}
}
func (m *mockMetricsSource) GetSuricataStats() SuricataInfo {
	return SuricataInfo{Enabled: true}
}
func (m *mockMetricsSource) GetAPIStats() APIStats {
	return APIStats{RequestsTotal: 100}
}
func (m *mockMetricsSource) GetDiscoveryData() DiscoveryInfo {
	return m.discovery
}

func TestDiscoveryManager_GetUnknownKey(t *testing.T) {
	source := &mockMetricsSource{}
	cfg := DefaultConfig()
	dm := NewDiscoveryManager(source, cfg)

	_, err := dm.Get("nftban.discovery.unknown")
	if err == nil {
		t.Error("Get() should return error for unknown key")
	}
}

func TestDiscoveryManager_RefreshModules(t *testing.T) {
	source := &mockMetricsSource{
		discovery: DiscoveryInfo{
			Modules: []ModuleDiscovery{
				{Name: "portscan", Mode: "active", Enabled: true},
				{Name: "ddos", Mode: "passive", Enabled: false},
			},
		},
	}
	cfg := DefaultConfig()
	dm := NewDiscoveryManager(source, cfg)

	dm.RefreshModules()

	data, err := dm.Get(DiscoveryKeyModules)
	if err != nil {
		t.Fatalf("Get(modules) error = %v", err)
	}
	if !strings.Contains(data, "portscan") {
		t.Error("module data should contain 'portscan'")
	}
}

func TestDiscoveryManager_GetAll(t *testing.T) {
	source := &mockMetricsSource{
		discovery: DiscoveryInfo{
			Modules:    []ModuleDiscovery{{Name: "m1", Enabled: true}},
			Interfaces: []InterfaceDiscovery{{Name: "eth0", Zone: "public"}},
			Feeds:      []FeedDiscovery{{Name: "spamhaus", URL: "http://example.com", Enabled: true}},
		},
	}
	cfg := DefaultConfig()
	dm := NewDiscoveryManager(source, cfg)

	dm.RefreshAll()

	all := dm.GetAll()
	if len(all) == 0 {
		t.Error("GetAll() should return cached data after RefreshAll()")
	}
}

func TestDiscoveryManager_GetStatus(t *testing.T) {
	source := &mockMetricsSource{
		discovery: DiscoveryInfo{
			Modules: []ModuleDiscovery{{Name: "m1", Enabled: true}},
		},
	}
	cfg := DefaultConfig()
	dm := NewDiscoveryManager(source, cfg)

	dm.RefreshModules()

	statuses := dm.GetStatus()
	if len(statuses) == 0 {
		t.Error("GetStatus() should return non-empty after refresh")
	}
	found := false
	for _, s := range statuses {
		if s.Key == DiscoveryKeyModules {
			found = true
			if s.Items != 1 {
				t.Errorf("items = %d, want 1", s.Items)
			}
		}
	}
	if !found {
		t.Error("GetStatus should include modules key")
	}
}

func TestDiscoveryManager_ToMetrics(t *testing.T) {
	source := &mockMetricsSource{
		discovery: DiscoveryInfo{
			Modules: []ModuleDiscovery{{Name: "m1", Enabled: true}},
			Feeds:   []FeedDiscovery{{Name: "f1", Enabled: true}},
		},
	}
	cfg := DefaultConfig()
	dm := NewDiscoveryManager(source, cfg)

	dm.RefreshAll()

	metrics := dm.ToMetrics()
	if len(metrics) == 0 {
		t.Error("ToMetrics() should return metrics after RefreshAll()")
	}
	for _, m := range metrics {
		if m.Type != MetricTypeDiscovery {
			t.Errorf("metric type = %q, want %q", m.Type, MetricTypeDiscovery)
		}
	}
}

func TestDiscoveryManager_NilSource(t *testing.T) {
	cfg := DefaultConfig()
	dm := NewDiscoveryManager(nil, cfg)

	// Should not panic
	dm.RefreshAll()
	dm.RefreshModules()
	dm.RefreshInterfaces()
	dm.RefreshCountries()
	dm.RefreshFeeds()
	dm.RefreshTimers()
}

func TestDiscoveryManager_StartStop(t *testing.T) {
	source := &mockMetricsSource{}
	cfg := DefaultConfig()
	cfg.DiscoveryEnabled = true
	cfg.DiscoveryInterval = 100 * time.Millisecond

	dm := NewDiscoveryManager(source, cfg)
	dm.Start()

	// Give it a moment to run at least once
	time.Sleep(50 * time.Millisecond)

	dm.Stop()
}

func TestDiscoveryManager_StartDisabled(t *testing.T) {
	source := &mockMetricsSource{}
	cfg := DefaultConfig()
	cfg.DiscoveryEnabled = false

	dm := NewDiscoveryManager(source, cfg)
	dm.Start() // Should be a no-op
	dm.Stop()
}

// =============================================================================
// Discovery Metrics Generation Tests
// =============================================================================

func TestDiscoveryManager_GenerateModuleMetrics(t *testing.T) {
	source := &mockMetricsSource{}
	cfg := DefaultConfig()
	dm := NewDiscoveryManager(source, cfg)

	modules := map[string]ModuleStatus{
		"portscan": {Status: 1, Events: 100, Bans: 50, Errors: 0, Latency: 1.5},
		"ddos":     {Status: 0, Events: 200, Bans: 10, Errors: 5, Latency: 2.0},
	}

	metrics := dm.GenerateModuleMetrics(modules)
	// 5 metrics per module * 2 modules = 10
	if len(metrics) != 10 {
		t.Errorf("metrics count = %d, want 10", len(metrics))
	}
}

func TestDiscoveryManager_GenerateCountryMetrics(t *testing.T) {
	source := &mockMetricsSource{}
	cfg := DefaultConfig()
	dm := NewDiscoveryManager(source, cfg)

	countries := map[string]CountryStats{
		"CN": {ActiveBans: 100, Bans24h: 50, UniqueIPs: 80},
	}

	metrics := dm.GenerateCountryMetrics(countries)
	// 3 metrics per country
	if len(metrics) != 3 {
		t.Errorf("metrics count = %d, want 3", len(metrics))
	}
}

func TestDiscoveryManager_GenerateFeedMetrics(t *testing.T) {
	source := &mockMetricsSource{}
	cfg := DefaultConfig()
	dm := NewDiscoveryManager(source, cfg)

	feeds := map[string]FeedStatus{
		"spamhaus": {Status: 1, IPCount: 5000, LastUpdate: time.Now()},
	}

	metrics := dm.GenerateFeedMetrics(feeds)
	// 4 metrics per feed
	if len(metrics) != 4 {
		t.Errorf("metrics count = %d, want 4", len(metrics))
	}
}

func TestDiscoveryManager_GenerateInterfaceMetrics(t *testing.T) {
	source := &mockMetricsSource{}
	cfg := DefaultConfig()
	dm := NewDiscoveryManager(source, cfg)

	interfaces := map[string]InterfaceStats{
		"eth0": {BytesIn: 1000, BytesOut: 2000, Dropped: 5},
	}

	metrics := dm.GenerateInterfaceMetrics(interfaces)
	// 3 metrics per interface
	if len(metrics) != 3 {
		t.Errorf("metrics count = %d, want 3", len(metrics))
	}
}

func TestDiscoveryManager_GenerateTimerMetrics(t *testing.T) {
	source := &mockMetricsSource{}
	cfg := DefaultConfig()
	dm := NewDiscoveryManager(source, cfg)

	timers := map[string]TimerStats{
		"ban-1h": {ActiveCount: 10, ExpiresIn1h: 3},
	}

	metrics := dm.GenerateTimerMetrics(timers)
	// 2 metrics per timer
	if len(metrics) != 2 {
		t.Errorf("metrics count = %d, want 2", len(metrics))
	}
}

// =============================================================================
// Collector Tests
// =============================================================================

func TestCollector_Collect_NilSource(t *testing.T) {
	c := NewCollector(nil)
	snapshot := c.Collect()
	if snapshot == nil {
		t.Fatal("Collect() should return non-nil snapshot even with nil source")
	}
	if snapshot.Timestamp.IsZero() {
		t.Error("timestamp should be set")
	}
}

func TestCollector_Collect_WithSource(t *testing.T) {
	source := &mockMetricsSource{
		discovery: DiscoveryInfo{
			Modules: []ModuleDiscovery{{Name: "portscan", Enabled: true}},
		},
	}
	c := NewCollector(source)
	snapshot := c.Collect()

	if snapshot.Daemon.Version != "1.25.0" {
		t.Errorf("version = %q, want %q", snapshot.Daemon.Version, "1.25.0")
	}
	if snapshot.Bans.Total != 100 {
		t.Errorf("bans total = %d, want 100", snapshot.Bans.Total)
	}
	if snapshot.Events.Total != 500 {
		t.Errorf("events total = %d, want 500", snapshot.Events.Total)
	}
	if snapshot.Modules.Enabled != 1 {
		t.Errorf("modules enabled = %d, want 1", snapshot.Modules.Enabled)
	}
}

func TestCollector_GetLastSnapshot(t *testing.T) {
	source := &mockMetricsSource{}
	c := NewCollector(source)

	// Before collect, should be nil
	if c.GetLastSnapshot() != nil {
		t.Error("GetLastSnapshot() should be nil before Collect()")
	}

	c.Collect()

	if c.GetLastSnapshot() == nil {
		t.Error("GetLastSnapshot() should not be nil after Collect()")
	}
}

func TestCollector_GetLastCollectTime(t *testing.T) {
	source := &mockMetricsSource{}
	c := NewCollector(source)

	if !c.GetLastCollectTime().IsZero() {
		t.Error("GetLastCollectTime() should be zero before Collect()")
	}

	before := time.Now()
	c.Collect()
	after := time.Now()

	lastCollect := c.GetLastCollectTime()
	if lastCollect.Before(before) || lastCollect.After(after) {
		t.Error("GetLastCollectTime() should be between before and after Collect()")
	}
}

// =============================================================================
// MetricsSnapshot.ToMetrics Tests
// =============================================================================

func TestMetricsSnapshot_ToMetrics_Count(t *testing.T) {
	snapshot := &MetricsSnapshot{
		Timestamp: time.Now(),
		Daemon:    DaemonMetrics{Version: "1.25.0", Status: 1},
		Bans:      BanMetrics{Total: 100},
	}

	metrics := snapshot.ToMetrics()
	// Should generate a large number of metrics (all categories)
	if len(metrics) < 50 {
		t.Errorf("metrics count = %d, want at least 50", len(metrics))
	}
}

func TestMetricsSnapshot_ToMetrics_ContainsExpectedKeys(t *testing.T) {
	snapshot := &MetricsSnapshot{
		Timestamp: time.Now(),
		Daemon:    DaemonMetrics{Version: "1.25.0"},
		Bans:      BanMetrics{Total: 100},
		Events:    EventMetrics{Total: 500},
	}

	metrics := snapshot.ToMetrics()

	expectedKeys := []string{
		"nftban.version",
		"nftban.bans.total",
		"nftban.events.total",
		"nftban.memory.heap",
		"nftban.watchdog.status",
		"nftban.feeds.enabled",
		"nftban.server.hostname",
		"nftban.filter.total",
	}

	metricMap := make(map[string]bool)
	for _, m := range metrics {
		metricMap[m.Name] = true
	}

	for _, key := range expectedKeys {
		if !metricMap[key] {
			t.Errorf("missing expected metric key: %q", key)
		}
	}
}

// =============================================================================
// Multi-Sender Target Health Tests
// =============================================================================

func TestTargetHealth_InitialState(t *testing.T) {
	th := &TargetHealth{Name: "test", Healthy: true}
	if !th.Healthy {
		t.Error("initial state should be healthy")
	}
	if th.ConsecFailures != 0 {
		t.Error("initial ConsecFailures should be 0")
	}
}

// =============================================================================
// MultiSendResult Tests
// =============================================================================

func TestMultiSendResult(t *testing.T) {
	result := &MultiSendResult{
		Success:     true,
		Results:     map[string]*TargetResult{},
		TotalSent:   2,
		TotalFailed: 1,
	}

	if !result.Success {
		t.Error("Success should be true")
	}
	if result.TotalSent != 2 {
		t.Errorf("TotalSent = %d, want 2", result.TotalSent)
	}
}

// =============================================================================
// Send Mode Constants Tests
// =============================================================================

func TestSendModeConstants(t *testing.T) {
	if SendModeAll != "all" {
		t.Errorf("SendModeAll = %q, want %q", SendModeAll, "all")
	}
	if SendModePrimary != "primary" {
		t.Errorf("SendModePrimary = %q, want %q", SendModePrimary, "primary")
	}
	if SendModeFailover != "failover" {
		t.Errorf("SendModeFailover = %q, want %q", SendModeFailover, "failover")
	}
}

// =============================================================================
// Helper Function Tests
// =============================================================================

func TestBoolToInt(t *testing.T) {
	if boolToInt(true) != 1 {
		t.Error("boolToInt(true) should be 1")
	}
	if boolToInt(false) != 0 {
		t.Error("boolToInt(false) should be 0")
	}
}

func TestIsAlphanumeric(t *testing.T) {
	tests := []struct {
		c    byte
		want bool
	}{
		{'a', true}, {'z', true}, {'A', true}, {'Z', true},
		{'0', true}, {'9', true},
		{'-', false}, {'_', false}, {' ', false}, {'.', false},
	}

	for _, tt := range tests {
		if got := isAlphanumeric(tt.c); got != tt.want {
			t.Errorf("isAlphanumeric(%q) = %v, want %v", tt.c, got, tt.want)
		}
	}
}

func TestIsValidKeyChar(t *testing.T) {
	validChars := "abcABC012_.-[],xyz"
	for _, c := range validChars {
		if !isValidKeyChar(byte(c)) {
			t.Errorf("isValidKeyChar(%q) should be true", c)
		}
	}

	invalidChars := " !@#$%^&*()+={}"
	for _, c := range invalidChars {
		if isValidKeyChar(byte(c)) {
			t.Errorf("isValidKeyChar(%q) should be false", c)
		}
	}
}

// =============================================================================
// Sender Status Tests
// =============================================================================

func TestSenderStatus_Defaults(t *testing.T) {
	status := SenderStatus{}
	if status.Connected {
		t.Error("default Connected should be false")
	}
	if status.SendCount != 0 {
		t.Error("default SendCount should be 0")
	}
}

// =============================================================================
// Exporter Status Tests
// =============================================================================

func TestExporterStatus_Defaults(t *testing.T) {
	status := ExporterStatus{}
	if status.Enabled {
		t.Error("default Enabled should be false")
	}
	if status.Running {
		t.Error("default Running should be false")
	}
}

// =============================================================================
// Context Cancellation (sender closed) Test
// =============================================================================

func TestSender_ClosedBehavior(t *testing.T) {
	target := &Target{
		Name:    "test",
		Address: "127.0.0.1",
		Port:    10051,
		Enabled: true,
	}
	cfg := DefaultConfig()
	cfg.Hostname = "testhost"

	sender, err := NewSender(target, cfg)
	if err != nil {
		t.Fatalf("NewSender() error = %v", err)
	}

	// Close the sender
	if err := sender.Close(); err != nil {
		t.Fatalf("Close() error = %v", err)
	}

	// Double-close should be fine
	if err := sender.Close(); err != nil {
		t.Fatalf("second Close() error = %v", err)
	}

	// Send should fail after close
	_, err = sender.Send(context.Background(), []Metric{{Name: "test", Value: 1}})
	if err == nil {
		t.Error("Send() should return error after Close()")
	}
}

func TestSender_Status(t *testing.T) {
	target := &Target{
		Name:    "test-target",
		Address: "127.0.0.1",
		Port:    10051,
		Enabled: true,
	}
	cfg := DefaultConfig()
	cfg.Hostname = "testhost"

	sender, err := NewSender(target, cfg)
	if err != nil {
		t.Fatalf("NewSender() error = %v", err)
	}
	defer sender.Close()

	status := sender.Status()
	if status.Target != "test-target" {
		t.Errorf("target = %q, want %q", status.Target, "test-target")
	}
	if status.Connected {
		t.Error("should not be connected initially")
	}
	if status.SendCount != 0 {
		t.Error("initial send count should be 0")
	}
}

func TestSender_Target(t *testing.T) {
	target := &Target{Name: "t1", Address: "127.0.0.1", Port: 10051}
	cfg := DefaultConfig()
	cfg.Hostname = "h1"

	sender, err := NewSender(target, cfg)
	if err != nil {
		t.Fatalf("NewSender() error = %v", err)
	}
	defer sender.Close()

	if sender.Target().Name != "t1" {
		t.Errorf("Target().Name = %q, want %q", sender.Target().Name, "t1")
	}
}

func TestSender_SendEmptyMetrics(t *testing.T) {
	target := &Target{Name: "t1", Address: "127.0.0.1", Port: 10051}
	cfg := DefaultConfig()
	cfg.Hostname = "h1"

	sender, err := NewSender(target, cfg)
	if err != nil {
		t.Fatalf("NewSender() error = %v", err)
	}
	defer sender.Close()

	resp, err := sender.Send(context.Background(), []Metric{})
	if err != nil {
		t.Fatalf("Send(empty) error = %v", err)
	}
	if !resp.IsSuccess() {
		t.Error("empty metrics should return success")
	}
}

// =============================================================================
// Constants Tests
// =============================================================================

func TestProtocolConstants(t *testing.T) {
	if ProtocolHeader != "ZBXD\x01" {
		t.Errorf("ProtocolHeader = %q, want %q", ProtocolHeader, "ZBXD\x01")
	}
	if DefaultPort != 10051 {
		t.Errorf("DefaultPort = %d, want 10051", DefaultPort)
	}
	if MaxPayloadSize != 64*1024*1024 {
		t.Errorf("MaxPayloadSize = %d, want %d", MaxPayloadSize, 64*1024*1024)
	}
	if DefaultTimeout != 30*time.Second {
		t.Errorf("DefaultTimeout = %v, want 30s", DefaultTimeout)
	}
	if DefaultInterval != 60*time.Second {
		t.Errorf("DefaultInterval = %v, want 60s", DefaultInterval)
	}
	if DefaultBatchSize != 100 {
		t.Errorf("DefaultBatchSize = %d, want 100", DefaultBatchSize)
	}
}

func TestMetricTypeConstants(t *testing.T) {
	if MetricTypeGauge != "gauge" {
		t.Errorf("MetricTypeGauge = %q, want %q", MetricTypeGauge, "gauge")
	}
	if MetricTypeCounter != "counter" {
		t.Errorf("MetricTypeCounter = %q, want %q", MetricTypeCounter, "counter")
	}
	if MetricTypeText != "text" {
		t.Errorf("MetricTypeText = %q, want %q", MetricTypeText, "text")
	}
	if MetricTypeDiscovery != "discovery" {
		t.Errorf("MetricTypeDiscovery = %q, want %q", MetricTypeDiscovery, "discovery")
	}
}

func TestDiscoveryKeyConstants(t *testing.T) {
	keys := map[string]string{
		"modules":    DiscoveryKeyModules,
		"interfaces": DiscoveryKeyInterfaces,
		"countries":  DiscoveryKeyCountries,
		"feeds":      DiscoveryKeyFeeds,
		"timers":     DiscoveryKeyTimers,
	}

	for name, key := range keys {
		if !strings.HasPrefix(key, "nftban.discovery.") {
			t.Errorf("discovery key %q = %q, should start with nftban.discovery.", name, key)
		}
	}
}
