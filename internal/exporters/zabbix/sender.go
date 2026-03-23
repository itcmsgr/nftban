// =============================================================================
// NFTBan v1.0 - Zabbix Sender
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="sender"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-22"
// meta:description="Single-target Zabbix trapper sender with retry logic"
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
	"context"
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"net"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"github.com/itcmsgr/nftban/internal/logx"
)

// =============================================================================
// Sender
// =============================================================================

// Sender handles sending metrics to a single Zabbix server
type Sender struct {
	target *Target
	config *Config

	// Connection state
	conn     net.Conn
	connMu   sync.Mutex
	connTime time.Time

	// Statistics
	stats SenderStats

	// TLS config (cached)
	tlsConfig *tls.Config

	// Shutdown
	closed atomic.Bool
}

// SenderStats holds sender statistics
type SenderStats struct {
	SendCount    atomic.Int64
	ErrorCount   atomic.Int64
	MetricsSent  atomic.Int64
	BytesSent    atomic.Int64
	LastSend     atomic.Value // time.Time
	LastError    atomic.Value // string
	TotalLatency atomic.Int64 // nanoseconds
}

// NewSender creates a new sender for the given target
func NewSender(target *Target, config *Config) (*Sender, error) {
	s := &Sender{
		target: target,
		config: config,
	}

	// Initialize TLS config if needed
	if target.TLS != nil && target.TLS.Enabled {
		tlsConfig, err := s.buildTLSConfig()
		if err != nil {
			return nil, fmt.Errorf("failed to build TLS config: %w", err)
		}
		s.tlsConfig = tlsConfig
	}

	return s, nil
}

// =============================================================================
// Connection Management
// =============================================================================

// connect establishes a connection to the Zabbix server
func (s *Sender) connect(ctx context.Context) error {
	s.connMu.Lock()
	defer s.connMu.Unlock()

	// Already connected?
	if s.conn != nil {
		return nil
	}

	addr := fmt.Sprintf("%s:%d", s.target.Address, s.target.Port)
	timeout := s.config.ConnectTimeout
	if timeout == 0 {
		timeout = DefaultTimeout
	}

	// Create dialer with context
	dialer := &net.Dialer{
		Timeout: timeout,
	}

	var conn net.Conn
	var err error

	if s.tlsConfig != nil {
		// TLS connection
		tlsDialer := &tls.Dialer{
			NetDialer: dialer,
			Config:    s.tlsConfig,
		}
		conn, err = tlsDialer.DialContext(ctx, "tcp", addr)
	} else {
		// Plain TCP connection
		conn, err = dialer.DialContext(ctx, "tcp", addr)
	}

	if err != nil {
		return fmt.Errorf("failed to connect to %s: %w", addr, err)
	}

	s.conn = conn
	s.connTime = time.Now()

	return nil
}

// disconnect closes the connection
func (s *Sender) disconnect() {
	s.connMu.Lock()
	defer s.connMu.Unlock()

	if s.conn != nil {
		s.conn.Close()
		s.conn = nil
	}
}

// getConn returns the current connection, connecting if needed
func (s *Sender) getConn(ctx context.Context) (net.Conn, error) {
	s.connMu.Lock()
	conn := s.conn
	s.connMu.Unlock()

	if conn != nil {
		return conn, nil
	}

	if err := s.connect(ctx); err != nil {
		return nil, err
	}

	s.connMu.Lock()
	conn = s.conn
	s.connMu.Unlock()

	return conn, nil
}

// buildTLSConfig creates TLS configuration from target settings
func (s *Sender) buildTLSConfig() (*tls.Config, error) {
	tlsCfg := s.target.TLS
	if tlsCfg == nil {
		return nil, nil
	}

	config := &tls.Config{
		MinVersion: tls.VersionTLS12,
	}

	// Only allow InsecureSkipVerify in development mode AND when explicitly configured
	if tlsCfg.SkipVerify {
		if tlsCfg.DevMode {
			config.InsecureSkipVerify = true
			logx.SecurityWarn("Zabbix TLS certificate verification disabled for target %s - NOT recommended for production", s.target.Name)
		} else {
			logx.Warn("Zabbix TLS SkipVerify requested for target %s but DevMode is not enabled - ignoring (use CAFile for custom CA)", s.target.Name)
		}
	}

	// Load CA certificate
	if tlsCfg.CAFile != "" {
		caCert, err := os.ReadFile(tlsCfg.CAFile)
		if err != nil {
			return nil, fmt.Errorf("failed to read CA file: %w", err)
		}
		caCertPool := x509.NewCertPool()
		if !caCertPool.AppendCertsFromPEM(caCert) {
			return nil, fmt.Errorf("failed to parse CA certificate")
		}
		config.RootCAs = caCertPool
	}

	// Load client certificate
	if tlsCfg.CertFile != "" && tlsCfg.KeyFile != "" {
		cert, err := tls.LoadX509KeyPair(tlsCfg.CertFile, tlsCfg.KeyFile)
		if err != nil {
			return nil, fmt.Errorf("failed to load client certificate: %w", err)
		}
		config.Certificates = []tls.Certificate{cert}
	}

	return config, nil
}

// =============================================================================
// Send Operations
// =============================================================================

// Send sends metrics to the Zabbix server
func (s *Sender) Send(ctx context.Context, metrics []Metric) (*TrapperResponse, error) {
	if s.closed.Load() {
		return nil, fmt.Errorf("sender is closed")
	}

	if len(metrics) == 0 {
		return &TrapperResponse{Response: "success", Info: "processed: 0; failed: 0; total: 0"}, nil
	}

	// Determine hostname
	hostname := s.target.Hostname
	if hostname == "" {
		hostname = s.config.Hostname
	}

	// Encode metrics
	data, err := EncodeMetrics(hostname, metrics)
	if err != nil {
		return nil, fmt.Errorf("failed to encode metrics: %w", err)
	}

	// Send with retry
	var resp *TrapperResponse
	var lastErr error
	retries := s.config.RetryCount
	if retries == 0 {
		retries = 1
	}

	for attempt := 0; attempt < retries; attempt++ {
		if attempt > 0 {
			// Wait before retry
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-time.After(s.config.RetryInterval):
			}
			// Reconnect on retry
			s.disconnect()
		}

		resp, lastErr = s.sendOnce(ctx, data)
		if lastErr == nil {
			break
		}

		// Record error
		s.stats.ErrorCount.Add(1)
		s.stats.LastError.Store(lastErr.Error())
	}

	if lastErr != nil {
		return nil, lastErr
	}

	// Update statistics
	s.stats.SendCount.Add(1)
	s.stats.MetricsSent.Add(int64(len(metrics)))
	s.stats.BytesSent.Add(int64(len(data)))
	s.stats.LastSend.Store(time.Now())

	return resp, nil
}

// sendOnce performs a single send attempt
func (s *Sender) sendOnce(ctx context.Context, data []byte) (*TrapperResponse, error) {
	start := time.Now()

	// Get connection
	conn, err := s.getConn(ctx)
	if err != nil {
		return nil, err
	}

	// Set write deadline
	timeout := s.config.SendTimeout
	if timeout == 0 {
		timeout = DefaultTimeout
	}
	if err := conn.SetWriteDeadline(time.Now().Add(timeout)); err != nil {
		s.disconnect()
		return nil, fmt.Errorf("failed to set write deadline: %w", err)
	}

	// Write data
	if _, err := conn.Write(data); err != nil {
		s.disconnect()
		return nil, fmt.Errorf("failed to write data: %w", err)
	}

	// Read response
	resp, err := DecodeFromConn(conn, timeout)
	if err != nil {
		s.disconnect()
		return nil, fmt.Errorf("failed to read response: %w", err)
	}

	// Update latency stats
	latency := time.Since(start)
	s.stats.TotalLatency.Add(latency.Nanoseconds())

	// Close connection after each request (Zabbix trapper protocol)
	s.disconnect()

	return resp, nil
}

// SendBatch sends a batch of metrics
func (s *Sender) SendBatch(ctx context.Context, batch *Batch) (*TrapperResponse, error) {
	return s.Send(ctx, batch.Metrics)
}

// SendRequest sends a pre-built trapper request
func (s *Sender) SendRequest(ctx context.Context, req *TrapperRequest) (*TrapperResponse, error) {
	if s.closed.Load() {
		return nil, fmt.Errorf("sender is closed")
	}

	data, err := Encode(req)
	if err != nil {
		return nil, fmt.Errorf("failed to encode request: %w", err)
	}

	var resp *TrapperResponse
	var lastErr error
	retries := s.config.RetryCount
	if retries == 0 {
		retries = 1
	}

	for attempt := 0; attempt < retries; attempt++ {
		if attempt > 0 {
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-time.After(s.config.RetryInterval):
			}
			s.disconnect()
		}

		resp, lastErr = s.sendOnce(ctx, data)
		if lastErr == nil {
			break
		}

		s.stats.ErrorCount.Add(1)
		s.stats.LastError.Store(lastErr.Error())
	}

	if lastErr != nil {
		return nil, lastErr
	}

	s.stats.SendCount.Add(1)
	s.stats.MetricsSent.Add(int64(len(req.Data)))
	s.stats.BytesSent.Add(int64(len(data)))
	s.stats.LastSend.Store(time.Now())

	return resp, nil
}

// =============================================================================
// Discovery
// =============================================================================

// SendDiscovery sends discovery data for LLD
func (s *Sender) SendDiscovery(ctx context.Context, key string, data string) (*TrapperResponse, error) {
	metric := Metric{
		Name:      key,
		Value:     data,
		Type:      MetricTypeDiscovery,
		Timestamp: time.Now(),
	}

	return s.Send(ctx, []Metric{metric})
}

// =============================================================================
// Status & Lifecycle
// =============================================================================

// Status returns the current sender status
func (s *Sender) Status() SenderStatus {
	status := SenderStatus{
		Target:      s.target.Name,
		SendCount:   s.stats.SendCount.Load(),
		ErrorCount:  s.stats.ErrorCount.Load(),
		MetricsSent: s.stats.MetricsSent.Load(),
		BytesSent:   s.stats.BytesSent.Load(),
	}

	// Connection status
	s.connMu.Lock()
	status.Connected = s.conn != nil
	s.connMu.Unlock()

	// Last send time
	if v := s.stats.LastSend.Load(); v != nil {
		if t, ok := v.(time.Time); ok {
			status.LastSend = t
		}
	}

	// Last error
	if v := s.stats.LastError.Load(); v != nil {
		if s, ok := v.(string); ok {
			status.LastError = s
		}
	}

	// Calculate average latency
	if status.SendCount > 0 {
		totalLatency := s.stats.TotalLatency.Load()
		status.AvgLatencyMs = float64(totalLatency) / float64(status.SendCount) / 1e6
	}

	return status
}

// Target returns the sender's target configuration
func (s *Sender) Target() *Target {
	return s.target
}

// Close closes the sender
func (s *Sender) Close() error {
	if s.closed.Swap(true) {
		return nil // Already closed
	}

	s.disconnect()
	return nil
}

// =============================================================================
// Testing Helpers
// =============================================================================

// TestConnection tests connectivity to the Zabbix server
func (s *Sender) TestConnection(ctx context.Context) error {
	if err := s.connect(ctx); err != nil {
		return err
	}
	s.disconnect()
	return nil
}

// SendTestMetric sends a test metric to verify the connection
func (s *Sender) SendTestMetric(ctx context.Context) (*TrapperResponse, error) {
	metric := Metric{
		Name:      "nftban.test",
		Value:     1,
		Type:      MetricTypeGauge,
		Timestamp: time.Now(),
	}

	return s.Send(ctx, []Metric{metric})
}

// Ping sends a minimal request to check server responsiveness
func (s *Sender) Ping(ctx context.Context) (time.Duration, error) {
	start := time.Now()

	if err := s.connect(ctx); err != nil {
		return 0, err
	}
	defer s.disconnect()

	return time.Since(start), nil
}
