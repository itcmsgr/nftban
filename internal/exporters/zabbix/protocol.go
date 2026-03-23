// =============================================================================
// NFTBan v1.0 - Zabbix Trapper Protocol
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="protocol"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-22"
// meta:description="Implementation of the Zabbix trapper (sender) protocol"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network="10051/tcp"
// meta:inventory.privileges="none"
// =============================================================================

package zabbix

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/safeconv"
)

// =============================================================================
// Protocol Constants
// =============================================================================

var (
	// headerBytes is the Zabbix protocol header bytes
	headerBytes = []byte{0x5A, 0x42, 0x58, 0x44, 0x01} // "ZBXD" + 0x01

	// infoRegexp parses the info string from response
	// Format: "processed: X; failed: Y; total: Z; seconds spent: W"
	infoRegexp = regexp.MustCompile(`processed:\s*(\d+);\s*failed:\s*(\d+);\s*total:\s*(\d+);\s*seconds spent:\s*([\d.]+)`)
)

const (
	// headerSize is the total header size (5 bytes header + 8 bytes length)
	headerSize = 13

	// maxResponseSize limits response reading to prevent memory issues
	maxResponseSize = 1024 * 1024 // 1MB
)

// =============================================================================
// Protocol Encoder
// =============================================================================

// Encode creates a Zabbix protocol message from a trapper request
func Encode(req *TrapperRequest) ([]byte, error) {
	// Marshal JSON payload
	payload, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal request: %w", err)
	}

	// Check payload size
	if len(payload) > MaxPayloadSize {
		return nil, fmt.Errorf("payload size %d exceeds maximum %d", len(payload), MaxPayloadSize)
	}

	// Create buffer: header (5) + length (8) + payload
	buf := make([]byte, headerSize+len(payload))

	// Write header
	copy(buf[0:5], headerBytes)

	// Write length (little-endian uint64)
	binary.LittleEndian.PutUint64(buf[5:13], uint64(len(payload)))

	// Write payload
	copy(buf[13:], payload)

	return buf, nil
}

// EncodeMetrics creates a Zabbix protocol message from metrics
func EncodeMetrics(hostname string, metrics []Metric) ([]byte, error) {
	now := time.Now()
	items := make([]TrapperItem, len(metrics))

	for i, m := range metrics {
		ts := m.Timestamp
		if ts.IsZero() {
			ts = now
		}

		items[i] = TrapperItem{
			Host:  hostname,
			Key:   m.Name,
			Value: formatValue(m.Value),
			Clock: ts.Unix(),
			Ns:    ts.Nanosecond(),
		}
	}

	req := &TrapperRequest{
		Request: "sender data",
		Data:    items,
		Clock:   now.Unix(),
		Ns:      now.Nanosecond(),
	}

	return Encode(req)
}

// =============================================================================
// Protocol Decoder
// =============================================================================

// Decode reads and parses a Zabbix protocol response
func Decode(r io.Reader) (*TrapperResponse, error) {
	// Read header
	header := make([]byte, headerSize)
	if _, err := io.ReadFull(r, header); err != nil {
		return nil, fmt.Errorf("failed to read header: %w", err)
	}

	// Validate header
	if !bytes.Equal(header[0:5], headerBytes) {
		return nil, fmt.Errorf("invalid header: expected ZBXD\\x01, got %x", header[0:5])
	}

	// Read payload length
	length := binary.LittleEndian.Uint64(header[5:13])
	if length > maxResponseSize {
		return nil, fmt.Errorf("response size %d exceeds maximum %d", length, maxResponseSize)
	}

	// Read payload
	payload := make([]byte, length)
	if _, err := io.ReadFull(r, payload); err != nil {
		return nil, fmt.Errorf("failed to read payload: %w", err)
	}

	// Parse JSON
	var resp TrapperResponse
	if err := json.Unmarshal(payload, &resp); err != nil {
		return nil, fmt.Errorf("failed to unmarshal response: %w", err)
	}

	return &resp, nil
}

// DecodeFromConn reads and parses a response from a network connection
func DecodeFromConn(conn net.Conn, timeout time.Duration) (*TrapperResponse, error) {
	if timeout > 0 {
		if err := conn.SetReadDeadline(time.Now().Add(timeout)); err != nil {
			return nil, fmt.Errorf("failed to set read deadline: %w", err)
		}
	}

	return Decode(conn)
}

// =============================================================================
// Response Parsing
// =============================================================================

// ParseInfoString parses the info field from a trapper response
func ParseInfoString(info string) TrapperInfo {
	result := TrapperInfo{}

	matches := infoRegexp.FindStringSubmatch(info)
	if len(matches) == 5 {
		result.Processed, _ = strconv.Atoi(matches[1])
		result.Failed, _ = strconv.Atoi(matches[2])
		result.Total, _ = strconv.Atoi(matches[3])
		result.Seconds, _ = strconv.ParseFloat(matches[4], 64)
	}

	return result
}

// =============================================================================
// Value Formatting
// =============================================================================

// formatValue converts a value to a string for Zabbix
func formatValue(v interface{}) string {
	switch val := v.(type) {
	case string:
		return val
	case []byte:
		return string(val)
	case int:
		return strconv.Itoa(val)
	case int8:
		return strconv.FormatInt(int64(val), 10)
	case int16:
		return strconv.FormatInt(int64(val), 10)
	case int32:
		return strconv.FormatInt(int64(val), 10)
	case int64:
		return strconv.FormatInt(val, 10)
	case uint:
		return strconv.FormatUint(uint64(val), 10)
	case uint8:
		return strconv.FormatUint(uint64(val), 10)
	case uint16:
		return strconv.FormatUint(uint64(val), 10)
	case uint32:
		return strconv.FormatUint(uint64(val), 10)
	case uint64:
		return strconv.FormatUint(val, 10)
	case float32:
		return strconv.FormatFloat(float64(val), 'f', -1, 32)
	case float64:
		return strconv.FormatFloat(val, 'f', -1, 64)
	case bool:
		if val {
			return "1"
		}
		return "0"
	case nil:
		return ""
	default:
		// Try JSON marshaling for complex types
		b, err := json.Marshal(val)
		if err != nil {
			return fmt.Sprintf("%v", val)
		}
		return string(b)
	}
}

// =============================================================================
// Discovery Data Formatting
// =============================================================================

// FormatDiscoveryData formats discovery data for Zabbix LLD
// Returns JSON in the format: {"data": [{"{#MACRO}": "value", ...}, ...]}
func FormatDiscoveryData(items []map[string]string) (string, error) {
	// Zabbix LLD expects {"data": [...]}
	data := struct {
		Data []map[string]string `json:"data"`
	}{
		Data: items,
	}

	b, err := json.Marshal(data)
	if err != nil {
		return "", fmt.Errorf("failed to marshal discovery data: %w", err)
	}

	return string(b), nil
}

// FormatModuleDiscovery formats module discovery data
func FormatModuleDiscovery(modules []DiscoveredModule) (string, error) {
	items := make([]map[string]string, len(modules))
	for i, m := range modules {
		items[i] = map[string]string{
			"{#MODULE}":  m.Module,
			"{#MODE}":    m.Mode,
			"{#ENABLED}": strconv.Itoa(m.Enabled),
		}
	}
	return FormatDiscoveryData(items)
}

// FormatInterfaceDiscovery formats interface discovery data
func FormatInterfaceDiscovery(interfaces []DiscoveredInterface) (string, error) {
	items := make([]map[string]string, len(interfaces))
	for i, iface := range interfaces {
		items[i] = map[string]string{
			"{#IFACE}": iface.Interface,
			"{#ZONE}":  iface.Zone,
		}
	}
	return FormatDiscoveryData(items)
}

// FormatCountryDiscovery formats country discovery data
func FormatCountryDiscovery(countries []DiscoveredCountry) (string, error) {
	items := make([]map[string]string, len(countries))
	for i, c := range countries {
		items[i] = map[string]string{
			"{#COUNTRY}":      c.Country,
			"{#COUNTRY_NAME}": c.CountryName,
			"{#BLOCKED}":      strconv.Itoa(c.Blocked),
		}
	}
	return FormatDiscoveryData(items)
}

// FormatFeedDiscovery formats feed discovery data
func FormatFeedDiscovery(feeds []DiscoveredFeed) (string, error) {
	items := make([]map[string]string, len(feeds))
	for i, f := range feeds {
		items[i] = map[string]string{
			"{#FEED}":    f.Feed,
			"{#URL}":     f.URL,
			"{#ENABLED}": strconv.Itoa(f.Enabled),
		}
	}
	return FormatDiscoveryData(items)
}

// FormatTimerDiscovery formats timer discovery data
func FormatTimerDiscovery(timers []DiscoveredTimer) (string, error) {
	items := make([]map[string]string, len(timers))
	for i, t := range timers {
		items[i] = map[string]string{
			"{#TIMER}":    t.Timer,
			"{#DURATION}": t.Duration,
		}
	}
	return FormatDiscoveryData(items)
}

// =============================================================================
// Batch Helpers
// =============================================================================

// SplitIntoBatches splits metrics into batches of the specified size
func SplitIntoBatches(metrics []Metric, batchSize int) [][]Metric {
	if batchSize <= 0 {
		batchSize = DefaultBatchSize
	}

	var batches [][]Metric
	for i := 0; i < len(metrics); i += batchSize {
		end := i + batchSize
		if end > len(metrics) {
			end = len(metrics)
		}
		batches = append(batches, metrics[i:end])
	}

	return batches
}

// =============================================================================
// Key Helpers
// =============================================================================

// BuildKey constructs a Zabbix item key with parameters
// Example: BuildKey("nftban.module.status", "portscan") -> "nftban.module.status[portscan]"
func BuildKey(base string, params ...string) string {
	if len(params) == 0 {
		return base
	}

	var sb strings.Builder
	sb.WriteString(base)
	sb.WriteByte('[')
	for i, p := range params {
		if i > 0 {
			sb.WriteByte(',')
		}
		sb.WriteString(p)
	}
	sb.WriteByte(']')

	return sb.String()
}

// ParseKey extracts the base key and parameters from a Zabbix item key
// Example: ParseKey("nftban.module.status[portscan]") -> ("nftban.module.status", ["portscan"])
func ParseKey(key string) (string, []string) {
	idx := strings.IndexByte(key, '[')
	if idx == -1 {
		return key, nil
	}

	base := key[:idx]
	paramsStr := strings.TrimSuffix(key[idx+1:], "]")

	if paramsStr == "" {
		return base, nil
	}

	params := strings.Split(paramsStr, ",")
	return base, params
}

// =============================================================================
// Validation
// =============================================================================

// ValidateKey checks if a key is valid for Zabbix
func ValidateKey(key string) error {
	if len(key) == 0 {
		return fmt.Errorf("key cannot be empty")
	}
	if len(key) > 2048 {
		return fmt.Errorf("key length %d exceeds maximum 2048", len(key))
	}

	// Keys can contain: a-z, A-Z, 0-9, _, ., -, and [] for parameters
	for i, c := range key {
		// Use safeconv for rune->byte (non-ASCII automatically invalid)
		b := safeconv.RuneToByteOrDefault(c, 0)
		if !isValidKeyChar(b) {
			return fmt.Errorf("invalid character '%c' at position %d", c, i)
		}
	}

	return nil
}

func isValidKeyChar(c byte) bool {
	return (c >= 'a' && c <= 'z') ||
		(c >= 'A' && c <= 'Z') ||
		(c >= '0' && c <= '9') ||
		c == '_' || c == '.' || c == '-' ||
		c == '[' || c == ']' || c == ','
}

// ValidateHostname checks if a hostname is valid for Zabbix
func ValidateHostname(hostname string) error {
	if len(hostname) == 0 {
		return fmt.Errorf("hostname cannot be empty")
	}
	if len(hostname) > 128 {
		return fmt.Errorf("hostname length %d exceeds maximum 128", len(hostname))
	}
	return nil
}
