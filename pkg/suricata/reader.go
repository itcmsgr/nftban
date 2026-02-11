// =============================================================================
// NFTBan - Suricata EVE JSON Reader
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="reader"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Reads and parses Suricata eve.json alert entries"
// meta:input="Suricata eve.json file"
// meta:output="Parsed EveAlert structs"
// meta:depends="bufio,encoding/json"
// meta:inventory.files="/var/log/nftban/suricata/eve-alerts.json"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package suricata

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"time"
)

// EveAlert represents a Suricata eve.json alert entry
type EveAlert struct {
	Timestamp string `json:"timestamp"`
	EventType string `json:"event_type"`
	SrcIP     string `json:"src_ip"`
	SrcPort   int    `json:"src_port"`
	DestIP    string `json:"dest_ip"`
	DestPort  int    `json:"dest_port"`
	Proto     string `json:"proto"`
	Alert     struct {
		SignatureID int    `json:"signature_id"`
		Signature   string `json:"signature"`
		Category    string `json:"category"`
		Severity    int    `json:"severity"` // 1=High, 2=Medium, 3=Low, 4=Info
		Action      string `json:"action"`
	} `json:"alert"`
	HTTP *struct {
		Hostname string `json:"hostname"`
		URL      string `json:"url"`
		Method   string `json:"http_method"`
	} `json:"http,omitempty"`
	SSH *struct {
		Client  string `json:"client"`
		Server  string `json:"server"`
		Version string `json:"proto_version"`
	} `json:"ssh,omitempty"`
}

// Event represents a normalized Suricata event for NFTBan processing
type Event struct {
	Timestamp   time.Time
	EventType   string // "alert", "http", "ssh", etc.
	SrcIP       string
	SrcPort     int
	DestIP      string
	DestPort    int
	Proto       string
	SignatureID int
	Signature   string
	Category    string
	Severity    int    // 1=High, 2=Medium, 3=Low, 4=Info
	Filter      string // Matched filter name (e.g., "ssh", "http")
}

// EveReader reads and parses Suricata eve.json log file
type EveReader struct {
	file    *os.File
	reader  *bufio.Reader
	path    string
	matcher *FilterMatcher
}

// NewEveReader creates a new eve.json reader
func NewEveReader(evePath string, matcher *FilterMatcher) (*EveReader, error) {
	file, err := os.Open(evePath)
	if err != nil {
		return nil, fmt.Errorf("failed to open eve.json: %w", err)
	}

	// Seek to end to only process new events
	if _, err := file.Seek(0, io.SeekEnd); err != nil {
		file.Close()
		return nil, fmt.Errorf("failed to seek to end: %w", err)
	}

	return &EveReader{
		file:    file,
		reader:  bufio.NewReader(file),
		path:    evePath,
		matcher: matcher,
	}, nil
}

// Close closes the eve.json file
func (r *EveReader) Close() error {
	if r.file != nil {
		return r.file.Close()
	}
	return nil
}

// ReadEvent reads the next event from eve.json
// Returns nil if no event available (non-blocking)
func (r *EveReader) ReadEvent() (*Event, error) {
	line, err := r.reader.ReadBytes('\n')
	if err != nil {
		if err == io.EOF {
			// No data available right now
			return nil, nil
		}
		return nil, fmt.Errorf("failed to read line: %w", err)
	}

	// Parse JSON
	var raw map[string]interface{}
	if err := json.Unmarshal(line, &raw); err != nil {
		// Skip malformed JSON
		return nil, nil
	}

	// Only process "alert" events
	eventType, ok := raw["event_type"].(string)
	if !ok || eventType != "alert" {
		// Skip non-alert events
		return nil, nil
	}

	// Parse full alert structure
	var alert EveAlert
	if err := json.Unmarshal(line, &alert); err != nil {
		// Skip if can't parse
		return nil, nil
	}

	// Parse timestamp
	timestamp, err := time.Parse(time.RFC3339Nano, alert.Timestamp)
	if err != nil {
		timestamp = time.Now()
	}

	// Match filter
	filterName, _ := r.matcher.GetFilterForEvent(alert.Alert.Signature, alert.Alert.Category)

	// Create normalized event
	event := &Event{
		Timestamp:   timestamp,
		EventType:   alert.EventType,
		SrcIP:       alert.SrcIP,
		SrcPort:     alert.SrcPort,
		DestIP:      alert.DestIP,
		DestPort:    alert.DestPort,
		Proto:       alert.Proto,
		SignatureID: alert.Alert.SignatureID,
		Signature:   alert.Alert.Signature,
		Category:    alert.Alert.Category,
		Severity:    alert.Alert.Severity,
		Filter:      filterName,
	}

	return event, nil
}

// ReadEvents continuously reads events from eve.json
// Sends events to the provided channel
func (r *EveReader) ReadEvents(events chan<- *Event, stopChan <-chan struct{}) error {
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-stopChan:
			return nil
		case <-ticker.C:
			// Try to read an event
			event, err := r.ReadEvent()
			if err != nil {
				// Log error but continue
				fmt.Fprintf(os.Stderr, "Error reading event: %v\n", err)
				continue
			}

			if event != nil {
				// Send event to channel (non-blocking)
				select {
				case events <- event:
				case <-stopChan:
					return nil
				default:
					// Channel full, skip event
					fmt.Fprintf(os.Stderr, "Warning: event channel full, dropping event\n")
				}
			}
		}
	}
}
