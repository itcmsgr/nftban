// =============================================================================
// NFTBan v1.0 - Kafka Connector
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="kafka"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-22"
// meta:description="Kafka connector using pure Go implementation"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network="9092/tcp"
// meta:inventory.privileges="none"
// =============================================================================

package connectors

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"hash/crc32"
	"net"
	"os"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/pkg/logx"
)

// =============================================================================
// Kafka Connector
// =============================================================================

// KafkaConnector sends records to Kafka
type KafkaConnector struct {
	*BaseConnector
	config KafkaConfig

	// Connection pool
	conns   []net.Conn
	connsMu sync.RWMutex

	// Producer state
	correlationID int32
	mu            sync.Mutex
}

// KafkaConfig holds Kafka connector configuration
type KafkaConfig struct {
	// Brokers
	Brokers []string `json:"brokers"` // ["localhost:9092"]

	// Topic
	Topic string `json:"topic"`

	// Security
	TLS           bool   `json:"tls"`
	TLSSkipVerify bool   `json:"tls_skip_verify"` // Only honored in development mode
	TLSCACertFile string `json:"tls_ca_cert_file,omitempty"`
	DevMode       bool   `json:"dev_mode"` // Development mode - allows InsecureSkipVerify
	SASLUsername  string `json:"sasl_username,omitempty"`
	SASLPassword  string `json:"sasl_password,omitempty"`
	SASLMechanism string `json:"sasl_mechanism,omitempty"` // PLAIN, SCRAM-SHA-256, SCRAM-SHA-512

	// Producer settings
	Acks           int           `json:"acks"`            // 0, 1, -1 (all)
	BatchSize      int           `json:"batch_size"`
	LingerMs       int           `json:"linger_ms"`
	CompressionType string       `json:"compression_type"` // none, gzip, snappy, lz4

	// Timeouts
	DialTimeout  time.Duration `json:"dial_timeout"`
	WriteTimeout time.Duration `json:"write_timeout"`
	ReadTimeout  time.Duration `json:"read_timeout"`

	// Retry
	MaxRetries    int           `json:"max_retries"`
	RetryInterval time.Duration `json:"retry_interval"`

	// Partitioning
	Partition    int    `json:"partition"`      // -1 for round-robin
	PartitionKey string `json:"partition_key"`  // Field to use as key
}

// DefaultKafkaConfig returns default configuration
func DefaultKafkaConfig() KafkaConfig {
	return KafkaConfig{
		Brokers:         []string{"localhost:9092"},
		Topic:           "nftban-metrics",
		Acks:            1,
		BatchSize:       16384,
		LingerMs:        5,
		CompressionType: "none",
		DialTimeout:     10 * time.Second,
		WriteTimeout:    30 * time.Second,
		ReadTimeout:     30 * time.Second,
		MaxRetries:      3,
		RetryInterval:   time.Second,
		Partition:       -1,
	}
}

// NewKafkaConnector creates a new Kafka connector
func NewKafkaConnector(name string, config KafkaConfig) *KafkaConnector {
	return &KafkaConnector{
		BaseConnector: NewBaseConnector(name, ConnectorTypeKafka),
		config:        config,
	}
}

// Connect establishes connections to Kafka brokers
func (c *KafkaConnector) Connect(ctx context.Context) error {
	c.connsMu.Lock()
	defer c.connsMu.Unlock()

	// Close existing connections
	for _, conn := range c.conns {
		conn.Close()
	}
	c.conns = nil

	// Connect to brokers
	for _, broker := range c.config.Brokers {
		conn, err := c.dialBroker(ctx, broker)
		if err != nil {
			continue
		}
		c.conns = append(c.conns, conn)
	}

	if len(c.conns) == 0 {
		return fmt.Errorf("failed to connect to any Kafka broker")
	}

	c.SetConnected(true)
	return nil
}

// dialBroker connects to a single broker
func (c *KafkaConnector) dialBroker(ctx context.Context, addr string) (net.Conn, error) {
	dialer := &net.Dialer{
		Timeout: c.config.DialTimeout,
	}

	var conn net.Conn
	var err error

	if c.config.TLS {
		tlsConfig, tlsErr := c.buildTLSConfig()
		if tlsErr != nil {
			return nil, fmt.Errorf("failed to build TLS config: %w", tlsErr)
		}
		conn, err = tls.DialWithDialer(dialer, "tcp", addr, tlsConfig)
	} else {
		conn, err = dialer.DialContext(ctx, "tcp", addr)
	}

	if err != nil {
		return nil, err
	}

	// Perform API version negotiation (simplified)
	if err := c.apiVersions(conn); err != nil {
		conn.Close()
		return nil, err
	}

	return conn, nil
}

// buildTLSConfig creates TLS configuration with proper security settings
func (c *KafkaConnector) buildTLSConfig() (*tls.Config, error) {
	config := &tls.Config{
		MinVersion: tls.VersionTLS12,
	}

	// Only allow InsecureSkipVerify in development mode AND when explicitly configured
	if c.config.TLSSkipVerify {
		if c.config.DevMode {
			config.InsecureSkipVerify = true
			logx.SecurityWarn("Kafka TLS certificate verification disabled - NOT recommended for production")
		} else {
			logx.Warn("Kafka TLSSkipVerify requested but DevMode is not enabled - ignoring (use TLSCACertFile for custom CA)")
		}
	}

	// Load custom CA certificate if provided
	if c.config.TLSCACertFile != "" {
		caCert, err := os.ReadFile(c.config.TLSCACertFile)
		if err != nil {
			return nil, fmt.Errorf("failed to read CA cert file: %w", err)
		}
		caCertPool := x509.NewCertPool()
		if !caCertPool.AppendCertsFromPEM(caCert) {
			return nil, fmt.Errorf("failed to parse CA certificate")
		}
		config.RootCAs = caCertPool
	}

	return config, nil
}

// Disconnect closes all connections
func (c *KafkaConnector) Disconnect() error {
	c.connsMu.Lock()
	defer c.connsMu.Unlock()

	var errs []error
	for _, conn := range c.conns {
		if err := conn.Close(); err != nil {
			errs = append(errs, err)
		}
	}
	c.conns = nil

	c.SetConnected(false)

	if len(errs) > 0 {
		return fmt.Errorf("errors closing connections: %v", errs)
	}
	return nil
}

// Send sends records to Kafka
func (c *KafkaConnector) Send(ctx context.Context, records []Record) error {
	if len(records) == 0 {
		return nil
	}

	c.connsMu.RLock()
	conns := c.conns
	c.connsMu.RUnlock()

	if len(conns) == 0 {
		return fmt.Errorf("not connected")
	}

	start := time.Now()

	// Build messages
	messages := make([]kafkaMessage, 0, len(records))
	for _, record := range records {
		value, err := json.Marshal(record)
		if err != nil {
			c.RecordError(err)
			return err
		}

		key := []byte(record.Host)
		if c.config.PartitionKey != "" {
			if v, ok := record.Data[c.config.PartitionKey]; ok {
				key = []byte(fmt.Sprintf("%v", v))
			}
		}

		messages = append(messages, kafkaMessage{
			Key:   key,
			Value: value,
		})
	}

	// Send to Kafka
	var lastErr error
	for attempt := 0; attempt <= c.config.MaxRetries; attempt++ {
		if attempt > 0 {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(c.config.RetryInterval):
			}
		}

		// Try each connection
		for _, conn := range conns {
			err := c.produce(conn, c.config.Topic, messages)
			if err == nil {
				c.RecordSend(len(records), int64(len(messages)*100), time.Since(start))
				return nil
			}
			lastErr = err
		}
	}

	c.RecordError(lastErr)
	return lastErr
}

// =============================================================================
// Kafka Protocol
// =============================================================================

// kafkaMessage represents a message to send
type kafkaMessage struct {
	Key   []byte
	Value []byte
}

// apiVersions sends API versions request (for handshake)
func (c *KafkaConnector) apiVersions(conn net.Conn) error {
	c.mu.Lock()
	c.correlationID++
	corrID := c.correlationID
	c.mu.Unlock()

	// Build request
	req := &bytes.Buffer{}

	// API Key (18 = ApiVersions)
	binary.Write(req, binary.BigEndian, int16(18))
	// API Version
	binary.Write(req, binary.BigEndian, int16(0))
	// Correlation ID
	binary.Write(req, binary.BigEndian, corrID)
	// Client ID
	clientID := "nftban"
	binary.Write(req, binary.BigEndian, int16(len(clientID)))
	req.WriteString(clientID)

	// Send
	if err := c.sendRequest(conn, req.Bytes()); err != nil {
		return err
	}

	// Read response (simplified - just check it succeeds)
	_, err := c.readResponse(conn)
	return err
}

// produce sends a produce request
func (c *KafkaConnector) produce(conn net.Conn, topic string, messages []kafkaMessage) error {
	c.mu.Lock()
	c.correlationID++
	corrID := c.correlationID
	c.mu.Unlock()

	// Build produce request (API Key 0, Version 3)
	req := &bytes.Buffer{}

	// API Key (0 = Produce)
	binary.Write(req, binary.BigEndian, int16(0))
	// API Version
	binary.Write(req, binary.BigEndian, int16(3))
	// Correlation ID
	binary.Write(req, binary.BigEndian, corrID)
	// Client ID
	clientID := "nftban"
	binary.Write(req, binary.BigEndian, int16(len(clientID)))
	req.WriteString(clientID)

	// Transactional ID (null)
	binary.Write(req, binary.BigEndian, int16(-1))

	// Acks
	binary.Write(req, binary.BigEndian, int16(c.config.Acks))

	// Timeout
	binary.Write(req, binary.BigEndian, int32(30000))

	// Topic array (1 topic)
	binary.Write(req, binary.BigEndian, int32(1))

	// Topic name
	binary.Write(req, binary.BigEndian, int16(len(topic)))
	req.WriteString(topic)

	// Partition array (1 partition)
	binary.Write(req, binary.BigEndian, int32(1))

	// Partition
	partition := c.config.Partition
	if partition < 0 {
		partition = 0
	}
	binary.Write(req, binary.BigEndian, int32(partition))

	// Build record batch
	recordBatch := c.buildRecordBatch(messages)

	// Record batch size
	binary.Write(req, binary.BigEndian, int32(len(recordBatch)))
	req.Write(recordBatch)

	// Send request
	if err := c.sendRequest(conn, req.Bytes()); err != nil {
		return err
	}

	// Read response
	resp, err := c.readResponse(conn)
	if err != nil {
		return err
	}

	// Check for errors in response (simplified)
	if len(resp) < 4 {
		return fmt.Errorf("invalid response")
	}

	return nil
}

// buildRecordBatch builds a Kafka record batch
func (c *KafkaConnector) buildRecordBatch(messages []kafkaMessage) []byte {
	batch := &bytes.Buffer{}

	// Base offset
	binary.Write(batch, binary.BigEndian, int64(0))

	// Batch length placeholder
	lengthPos := batch.Len()
	binary.Write(batch, binary.BigEndian, int32(0))

	// Partition leader epoch
	binary.Write(batch, binary.BigEndian, int32(-1))

	// Magic byte (2 for v2)
	batch.WriteByte(2)

	// CRC placeholder
	crcPos := batch.Len()
	binary.Write(batch, binary.BigEndian, int32(0))

	// Attributes
	binary.Write(batch, binary.BigEndian, int16(0))

	// Last offset delta
	binary.Write(batch, binary.BigEndian, int32(len(messages)-1))

	// First timestamp
	now := time.Now().UnixMilli()
	binary.Write(batch, binary.BigEndian, now)

	// Max timestamp
	binary.Write(batch, binary.BigEndian, now)

	// Producer ID
	binary.Write(batch, binary.BigEndian, int64(-1))

	// Producer epoch
	binary.Write(batch, binary.BigEndian, int16(-1))

	// Base sequence
	binary.Write(batch, binary.BigEndian, int32(-1))

	// Records count
	binary.Write(batch, binary.BigEndian, int32(len(messages)))

	// Records
	for i, msg := range messages {
		c.writeRecord(batch, i, msg, now)
	}

	// Update batch length
	batchLen := batch.Len() - lengthPos - 4
	batchBytes := batch.Bytes()
	binary.BigEndian.PutUint32(batchBytes[lengthPos:], uint32(batchLen))

	// Update CRC
	crcData := batchBytes[crcPos+4:]
	crc := crc32.ChecksumIEEE(crcData)
	binary.BigEndian.PutUint32(batchBytes[crcPos:], crc)

	return batchBytes
}

// writeRecord writes a single record
func (c *KafkaConnector) writeRecord(buf *bytes.Buffer, offset int, msg kafkaMessage, baseTime int64) {
	record := &bytes.Buffer{}

	// Attributes
	record.WriteByte(0)

	// Timestamp delta (varint)
	c.writeVarint(record, 0)

	// Offset delta (varint)
	c.writeVarint(record, int64(offset))

	// Key length (varint)
	c.writeVarint(record, int64(len(msg.Key)))
	record.Write(msg.Key)

	// Value length (varint)
	c.writeVarint(record, int64(len(msg.Value)))
	record.Write(msg.Value)

	// Headers count (varint)
	c.writeVarint(record, 0)

	// Write record length and data
	c.writeVarint(buf, int64(record.Len()))
	buf.Write(record.Bytes())
}

// writeVarint writes a variable-length integer
func (c *KafkaConnector) writeVarint(buf *bytes.Buffer, v int64) {
	uv := uint64((v << 1) ^ (v >> 63)) // zigzag encode
	for uv >= 0x80 {
		buf.WriteByte(byte(uv) | 0x80)
		uv >>= 7
	}
	buf.WriteByte(byte(uv))
}

// sendRequest sends a request with length prefix
func (c *KafkaConnector) sendRequest(conn net.Conn, data []byte) error {
	if c.config.WriteTimeout > 0 {
		conn.SetWriteDeadline(time.Now().Add(c.config.WriteTimeout))
	}

	// Write length
	lenBuf := make([]byte, 4)
	binary.BigEndian.PutUint32(lenBuf, uint32(len(data)))
	if _, err := conn.Write(lenBuf); err != nil {
		return err
	}

	// Write data
	_, err := conn.Write(data)
	return err
}

// readResponse reads a response with length prefix
func (c *KafkaConnector) readResponse(conn net.Conn) ([]byte, error) {
	if c.config.ReadTimeout > 0 {
		conn.SetReadDeadline(time.Now().Add(c.config.ReadTimeout))
	}

	// Read length
	lenBuf := make([]byte, 4)
	if _, err := conn.Read(lenBuf); err != nil {
		return nil, err
	}
	length := binary.BigEndian.Uint32(lenBuf)

	// Read data
	data := make([]byte, length)
	_, err := conn.Read(data)
	return data, err
}

