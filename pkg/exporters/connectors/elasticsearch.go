// =============================================================================
// NFTBan v1.0 - Elasticsearch Connector
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="elasticsearch"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-22"
// meta:description="Elasticsearch connector with bulk API and index templates"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network="9200/tcp"
// meta:inventory.privileges="none"
// =============================================================================

package connectors

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/pkg/logx"
)

// =============================================================================
// Elasticsearch Connector
// =============================================================================

// ElasticsearchConnector sends records to Elasticsearch
type ElasticsearchConnector struct {
	*BaseConnector
	config ESConfig
	client *http.Client
	mu     sync.RWMutex
}

// ESConfig holds Elasticsearch connector configuration
type ESConfig struct {
	// Connection
	Addresses []string `json:"addresses"` // ["http://localhost:9200"]
	Username  string   `json:"username,omitempty"`
	Password  string   `json:"password,omitempty"`
	APIKey    string   `json:"api_key,omitempty"`

	// TLS
	TLS           bool   `json:"tls"`
	TLSSkipVerify bool   `json:"tls_skip_verify"` // Only honored in development mode
	CACert        string `json:"ca_cert,omitempty"`
	DevMode       bool   `json:"dev_mode"` // Development mode - allows InsecureSkipVerify

	// Index settings
	Index         string `json:"index"`          // Index name or pattern
	IndexPattern  string `json:"index_pattern"`  // e.g., "nftban-metrics-%{+yyyy.MM.dd}"
	Pipeline      string `json:"pipeline,omitempty"`

	// Bulk settings
	BulkSize      int           `json:"bulk_size"`       // Max docs per bulk request
	FlushInterval time.Duration `json:"flush_interval"`  // Max time between flushes

	// Timeouts
	Timeout       time.Duration `json:"timeout"`

	// Retry
	MaxRetries    int           `json:"max_retries"`
	RetryInterval time.Duration `json:"retry_interval"`
}

// DefaultESConfig returns default configuration
func DefaultESConfig() ESConfig {
	return ESConfig{
		Addresses:     []string{"http://localhost:9200"},
		Index:         "nftban-metrics",
		IndexPattern:  "nftban-metrics-%Y.%m.%d",
		BulkSize:      1000,
		FlushInterval: 5 * time.Second,
		Timeout:       30 * time.Second,
		MaxRetries:    3,
		RetryInterval: time.Second,
	}
}

// NewElasticsearchConnector creates a new Elasticsearch connector
func NewElasticsearchConnector(name string, config ESConfig) *ElasticsearchConnector {
	return &ElasticsearchConnector{
		BaseConnector: NewBaseConnector(name, ConnectorTypeElasticsearch),
		config:        config,
	}
}

// Connect establishes connection to Elasticsearch
func (c *ElasticsearchConnector) Connect(ctx context.Context) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	// Create HTTP client
	transport := &http.Transport{
		MaxIdleConns:        100,
		MaxIdleConnsPerHost: 10,
		IdleConnTimeout:     90 * time.Second,
	}

	if c.config.TLS || c.config.TLSSkipVerify {
		tlsConfig, err := c.buildTLSConfig()
		if err != nil {
			return fmt.Errorf("failed to build TLS config: %w", err)
		}
		transport.TLSClientConfig = tlsConfig
	}

	c.client = &http.Client{
		Transport: transport,
		Timeout:   c.config.Timeout,
	}

	// Test connection
	if err := c.ping(ctx); err != nil {
		return fmt.Errorf("failed to connect to Elasticsearch: %w", err)
	}

	c.SetConnected(true)
	return nil
}

// buildTLSConfig creates TLS configuration with proper security settings
func (c *ElasticsearchConnector) buildTLSConfig() (*tls.Config, error) {
	config := &tls.Config{
		MinVersion: tls.VersionTLS12,
	}

	// Only allow InsecureSkipVerify in development mode AND when explicitly configured
	if c.config.TLSSkipVerify {
		if c.config.DevMode {
			config.InsecureSkipVerify = true
			logx.SecurityWarn("Elasticsearch TLS certificate verification disabled - NOT recommended for production")
		} else {
			logx.Warn("Elasticsearch TLSSkipVerify requested but DevMode is not enabled - ignoring (use CACert for custom CA)")
		}
	}

	// Load custom CA certificate if provided
	if c.config.CACert != "" {
		caCert, err := os.ReadFile(c.config.CACert)
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

// Disconnect closes the connection
func (c *ElasticsearchConnector) Disconnect() error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.client != nil {
		c.client.CloseIdleConnections()
		c.client = nil
	}

	c.SetConnected(false)
	return nil
}

// Send sends records to Elasticsearch using bulk API
func (c *ElasticsearchConnector) Send(ctx context.Context, records []Record) error {
	if len(records) == 0 {
		return nil
	}

	c.mu.RLock()
	client := c.client
	c.mu.RUnlock()

	if client == nil {
		return fmt.Errorf("not connected")
	}

	start := time.Now()

	// Build bulk request body
	var buf bytes.Buffer
	for _, record := range records {
		// Action line
		index := c.resolveIndex(record.Timestamp)
		action := map[string]interface{}{
			"index": map[string]interface{}{
				"_index": index,
			},
		}
		if c.config.Pipeline != "" {
			action["index"].(map[string]interface{})["pipeline"] = c.config.Pipeline
		}

		actionLine, err := json.Marshal(action)
		if err != nil {
			c.RecordError(err)
			return err
		}
		buf.Write(actionLine)
		buf.WriteByte('\n')

		// Document line
		docLine, err := json.Marshal(record)
		if err != nil {
			c.RecordError(err)
			return err
		}
		buf.Write(docLine)
		buf.WriteByte('\n')
	}

	// Send bulk request
	resp, err := c.doBulkRequest(ctx, buf.Bytes())
	if err != nil {
		c.RecordError(err)
		return err
	}

	// Check response
	if resp.Errors {
		// Count errors
		errorCount := 0
		for _, item := range resp.Items {
			if item.Index.Error != nil {
				errorCount++
			}
		}
		if errorCount > 0 {
			err := fmt.Errorf("bulk request had %d errors", errorCount)
			c.RecordError(err)
			return err
		}
	}

	c.RecordSend(len(records), int64(buf.Len()), time.Since(start))
	return nil
}

// =============================================================================
// HTTP Operations
// =============================================================================

// ping tests the connection
func (c *ElasticsearchConnector) ping(ctx context.Context) error {
	for _, addr := range c.config.Addresses {
		req, err := http.NewRequestWithContext(ctx, "GET", addr, nil)
		if err != nil {
			continue
		}

		c.addAuth(req)

		resp, err := c.client.Do(req)
		if err != nil {
			continue
		}
		resp.Body.Close()

		if resp.StatusCode == http.StatusOK {
			return nil
		}
	}

	return fmt.Errorf("no healthy Elasticsearch nodes")
}

// doBulkRequest sends a bulk request
func (c *ElasticsearchConnector) doBulkRequest(ctx context.Context, body []byte) (*BulkResponse, error) {
	var lastErr error

	for attempt := 0; attempt <= c.config.MaxRetries; attempt++ {
		if attempt > 0 {
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-time.After(c.config.RetryInterval):
			}
		}

		for _, addr := range c.config.Addresses {
			url := strings.TrimSuffix(addr, "/") + "/_bulk"

			req, err := http.NewRequestWithContext(ctx, "POST", url, bytes.NewReader(body))
			if err != nil {
				lastErr = err
				continue
			}

			req.Header.Set("Content-Type", "application/x-ndjson")
			c.addAuth(req)

			resp, err := c.client.Do(req)
			if err != nil {
				lastErr = err
				continue
			}

			defer resp.Body.Close()

			if resp.StatusCode >= 400 {
				bodyBytes, _ := io.ReadAll(resp.Body)
				lastErr = fmt.Errorf("bulk request failed: %s - %s", resp.Status, string(bodyBytes))
				continue
			}

			var bulkResp BulkResponse
			if err := json.NewDecoder(resp.Body).Decode(&bulkResp); err != nil {
				lastErr = err
				continue
			}

			return &bulkResp, nil
		}
	}

	return nil, lastErr
}

// addAuth adds authentication to request
func (c *ElasticsearchConnector) addAuth(req *http.Request) {
	if c.config.APIKey != "" {
		req.Header.Set("Authorization", "ApiKey "+c.config.APIKey)
	} else if c.config.Username != "" {
		req.SetBasicAuth(c.config.Username, c.config.Password)
	}
}

// resolveIndex resolves the index name for a timestamp
func (c *ElasticsearchConnector) resolveIndex(t time.Time) string {
	if c.config.IndexPattern != "" {
		// Simple pattern replacement
		index := c.config.IndexPattern
		index = strings.ReplaceAll(index, "%Y", t.Format("2006"))
		index = strings.ReplaceAll(index, "%m", t.Format("01"))
		index = strings.ReplaceAll(index, "%d", t.Format("02"))
		index = strings.ReplaceAll(index, "%H", t.Format("15"))
		return index
	}
	return c.config.Index
}

// =============================================================================
// Response Types
// =============================================================================

// BulkResponse represents Elasticsearch bulk API response
type BulkResponse struct {
	Took   int  `json:"took"`
	Errors bool `json:"errors"`
	Items  []BulkResponseItem `json:"items"`
}

// BulkResponseItem represents a single item in bulk response
type BulkResponseItem struct {
	Index BulkResponseItemDetail `json:"index"`
}

// BulkResponseItemDetail contains details for a bulk item
type BulkResponseItemDetail struct {
	Index   string           `json:"_index"`
	ID      string           `json:"_id"`
	Version int              `json:"_version"`
	Result  string           `json:"result"`
	Status  int              `json:"status"`
	Error   *BulkItemError   `json:"error,omitempty"`
}

// BulkItemError represents an error for a bulk item
type BulkItemError struct {
	Type   string `json:"type"`
	Reason string `json:"reason"`
}

// =============================================================================
// Index Template
// =============================================================================

// CreateIndexTemplate creates an index template for NFTBan metrics
func (c *ElasticsearchConnector) CreateIndexTemplate(ctx context.Context) error {
	template := map[string]interface{}{
		"index_patterns": []string{"nftban-*"},
		"template": map[string]interface{}{
			"settings": map[string]interface{}{
				"number_of_shards":   1,
				"number_of_replicas": 0,
				"index.lifecycle.name": "nftban-policy",
			},
			"mappings": map[string]interface{}{
				"properties": map[string]interface{}{
					"timestamp": map[string]string{"type": "date"},
					"host":      map[string]string{"type": "keyword"},
					"type":      map[string]string{"type": "keyword"},
					"source":    map[string]string{"type": "keyword"},
					"version":   map[string]string{"type": "keyword"},
					"data": map[string]interface{}{
						"type":    "object",
						"dynamic": true,
					},
					"tags": map[string]interface{}{
						"type":    "object",
						"dynamic": true,
					},
					"meta": map[string]interface{}{
						"type":    "object",
						"dynamic": true,
					},
				},
			},
		},
	}

	body, err := json.Marshal(template)
	if err != nil {
		return err
	}

	for _, addr := range c.config.Addresses {
		url := strings.TrimSuffix(addr, "/") + "/_index_template/nftban"

		req, err := http.NewRequestWithContext(ctx, "PUT", url, bytes.NewReader(body))
		if err != nil {
			continue
		}

		req.Header.Set("Content-Type", "application/json")
		c.addAuth(req)

		resp, err := c.client.Do(req)
		if err != nil {
			continue
		}
		resp.Body.Close()

		if resp.StatusCode == http.StatusOK || resp.StatusCode == http.StatusCreated {
			return nil
		}
	}

	return fmt.Errorf("failed to create index template")
}

// =============================================================================
// Health Check
// =============================================================================

// Health returns cluster health
func (c *ElasticsearchConnector) Health(ctx context.Context) (string, error) {
	c.mu.RLock()
	client := c.client
	c.mu.RUnlock()

	if client == nil {
		return "", fmt.Errorf("not connected")
	}

	for _, addr := range c.config.Addresses {
		url := strings.TrimSuffix(addr, "/") + "/_cluster/health"

		req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
		if err != nil {
			continue
		}

		c.addAuth(req)

		resp, err := client.Do(req)
		if err != nil {
			continue
		}
		defer resp.Body.Close()

		var health struct {
			Status string `json:"status"`
		}

		if err := json.NewDecoder(resp.Body).Decode(&health); err != nil {
			continue
		}

		return health.Status, nil
	}

	return "", fmt.Errorf("failed to get cluster health")
}
