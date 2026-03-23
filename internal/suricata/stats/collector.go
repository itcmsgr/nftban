// =============================================================================
// NFTBan - Suricata EVE Log Collector
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="collector"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Tails eve.json and collects alert statistics"
// meta:input="Suricata eve.json"
// meta:output="Parsed alerts, metrics, cache updates"
// meta:depends="github.com/itcmsgr/nftban/internal/configloader"
// meta:inventory.files="/var/log/nftban/suricata/eve-alerts.json"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package stats

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"time"

	nftbanConfig "github.com/itcmsgr/nftban/internal/configloader"
)

// EveAlert represents a Suricata alert from eve.json
type EveAlert struct {
	Timestamp string `json:"timestamp"`
	EventType string `json:"event_type"`
	SrcIP     string `json:"src_ip"`
	DestIP    string `json:"dest_ip"`
	Alert     struct {
		Signature   string `json:"signature"`
		SignatureID int    `json:"signature_id"`
		Category    string `json:"category"`
		Severity    int    `json:"severity"`
	} `json:"alert"`
}

// Collector manages eve.json parsing and statistics collection
type Collector struct {
	evePath string
	metrics *Metrics
	cache   *Cache
	stopCh  chan struct{}
}

// NewCollector creates a new statistics collector
func NewCollector(cache *Cache) (*Collector, error) {
	// Get eve.json path from distro config
	evePath, err := getEveJSONPath()
	if err != nil {
		return nil, err
	}

	return &Collector{
		evePath: evePath,
		metrics: GetMetrics(),
		cache:   cache,
		stopCh:  make(chan struct{}),
	}, nil
}

// getEveJSONPath returns eve.json path from distro config
func getEveJSONPath() (string, error) {
	distro, err := nftbanConfig.LoadDistroConfig()
	if err != nil {
		return "", err
	}

	evePath := distro.Paths["suricata_eve_log"]
	if evePath == "" {
		// Fallback to NFTBan standard path (alert-only output)
		evePath = "/var/log/nftban/suricata/eve-alerts.json"
	}

	return evePath, nil
}

// Start begins collecting statistics from eve.json
func (c *Collector) Start() error {
	// Check if eve.json exists
	if _, err := os.Stat(c.evePath); os.IsNotExist(err) {
		return fmt.Errorf("eve.json not found: %s (is Suricata running?)", c.evePath)
	}

	fmt.Printf("Starting eve.json collector: %s\n", c.evePath)

	// Start tailing eve.json
	go c.tailEveJSON()

	return nil
}

// Stop stops the collector
func (c *Collector) Stop() {
	close(c.stopCh)
}

// tailEveJSON tails eve.json and processes alerts
func (c *Collector) tailEveJSON() {
	for {
		select {
		case <-c.stopCh:
			return
		default:
			if err := c.processFile(); err != nil {
				fmt.Printf("Error processing eve.json: %v\n", err)
				time.Sleep(5 * time.Second) // Retry delay
			}
		}
	}
}

// processFile reads and processes eve.json
func (c *Collector) processFile() error {
	file, err := os.Open(c.evePath)
	if err != nil {
		return err
	}
	defer file.Close()

	// Seek to end of file (only process new events)
	if _, err := file.Seek(0, io.SeekEnd); err != nil {
		return err
	}

	scanner := bufio.NewScanner(file)
	for {
		select {
		case <-c.stopCh:
			return nil
		default:
			if scanner.Scan() {
				c.processLine(scanner.Text())
			} else {
				// No more data, wait a bit
				time.Sleep(100 * time.Millisecond)
			}
		}
	}
}

// processLine parses and processes a single eve.json line
func (c *Collector) processLine(line string) {
	startTime := time.Now()

	var event EveAlert
	if err := json.Unmarshal([]byte(line), &event); err != nil {
		c.metrics.RecordParseError()
		return
	}

	// Only process alert events
	if event.EventType != "alert" {
		return
	}

	// Extract data
	sid := fmt.Sprintf("%d", event.Alert.SignatureID)
	category := event.Alert.Category
	signature := event.Alert.Signature
	severity := fmt.Sprintf("%d", event.Alert.Severity)
	sourceIP := event.SrcIP

	// Parse timestamp
	timestamp, err := time.Parse(time.RFC3339, event.Timestamp)
	if err != nil {
		timestamp = time.Now()
	}

	// Record metrics
	c.metrics.RecordTrigger(sid, category, signature, float64(timestamp.Unix()), sourceIP)
	c.metrics.RecordSeverity(severity)

	// Update cache
	c.cache.RecordTrigger(sid, category, signature, sourceIP, timestamp)

	// Record processing latency
	c.metrics.ProcessingLatency.Observe(time.Since(startTime).Seconds())
}

// ProcessHistorical processes existing eve.json for historical data
func (c *Collector) ProcessHistorical(maxLines int) error {
	file, err := os.Open(c.evePath)
	if err != nil {
		return err
	}
	defer file.Close()

	fmt.Printf("Processing historical alerts from %s...\n", c.evePath)

	scanner := bufio.NewScanner(file)
	count := 0
	alertCount := 0

	for scanner.Scan() && (maxLines == 0 || count < maxLines) {
		count++
		line := scanner.Text()

		var event EveAlert
		if err := json.Unmarshal([]byte(line), &event); err != nil {
			continue
		}

		// Only process alerts
		if event.EventType != "alert" {
			continue
		}

		alertCount++

		// Extract data
		sid := fmt.Sprintf("%d", event.Alert.SignatureID)
		category := event.Alert.Category
		signature := event.Alert.Signature
		sourceIP := event.SrcIP

		// Parse timestamp
		timestamp, err := time.Parse(time.RFC3339, event.Timestamp)
		if err != nil {
			timestamp = time.Now()
		}

		// Update cache only (not Prometheus, as that would skew metrics)
		c.cache.RecordTrigger(sid, category, signature, sourceIP, timestamp)

		// Progress indicator
		if alertCount%1000 == 0 {
			fmt.Printf("  Processed %d alerts...\n", alertCount)
		}
	}

	if err := scanner.Err(); err != nil {
		return err
	}

	fmt.Printf("✓ Processed %d historical alerts\n", alertCount)
	return nil
}

// GetStats returns current statistics summary
func (c *Collector) GetStats() map[string]interface{} {
	return map[string]interface{}{
		"eve_path":         c.evePath,
		"cache_size":       c.cache.GetSize(),
		"unique_sids":      c.cache.GetUniqueSIDs(),
		"total_triggers":   c.cache.GetTotalTriggers(),
		"unique_sources":   c.cache.GetUniqueSources(),
	}
}
