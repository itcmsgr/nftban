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
	"log"
	"os"
	"time"

	"github.com/fsnotify/fsnotify"
	"github.com/itcmsgr/nftban/internal/constants"
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

// ReadEvents continuously reads events from eve.json using inotify when
// available, falling back to polling if inotify setup fails.
func (r *EveReader) ReadEvents(events chan<- *Event, stopChan <-chan struct{}) error {
	// Try inotify first (v1.38.0)
	watcher, err := fsnotify.NewWatcher()
	if err == nil {
		defer watcher.Close()
		if err := watcher.Add(r.path); err == nil {
			log.Printf("[Suricata] Using inotify for %s", r.path)
			return r.readEventsInotify(watcher, events, stopChan)
		}
		watcher.Close()
		log.Printf("[Suricata] inotify watch failed for %s: %v — falling back to polling", r.path, err)
	} else {
		log.Printf("[Suricata] inotify unavailable: %v — falling back to polling", err)
	}

	// Fallback: polling
	return r.readEventsPolling(events, stopChan)
}

// readEventsInotify reads events using inotify file change notifications.
func (r *EveReader) readEventsInotify(watcher *fsnotify.Watcher, events chan<- *Event, stopChan <-chan struct{}) error {
	for {
		select {
		case <-stopChan:
			return nil
		case fsEvent, ok := <-watcher.Events:
			if !ok {
				return nil
			}
			if fsEvent.Op&fsnotify.Write == 0 {
				continue
			}
			r.drainEvents(events, stopChan)
		case err, ok := <-watcher.Errors:
			if !ok {
				return nil
			}
			log.Printf("[Suricata] inotify error: %v — switching to polling", err)
			return r.readEventsPolling(events, stopChan)
		}
	}
}

// readEventsPolling reads events using timer-based polling.
func (r *EveReader) readEventsPolling(events chan<- *Event, stopChan <-chan struct{}) error {
	ticker := time.NewTicker(constants.SuricataEVEPollInterval)
	defer ticker.Stop()

	for {
		select {
		case <-stopChan:
			return nil
		case <-ticker.C:
			r.drainEvents(events, stopChan)
		}
	}
}

// drainEvents reads all available events from the reader and sends them to the channel.
// reopenIfRotated detects log rotation of eve.json and re-syncs the reader so events
// written after a rotate are not silently missed (SURICATA-EVE-ROTATION-MISS). Two cases:
//   - copytruncate: same inode truncated to 0 → our offset is now past EOF → seek to start.
//   - rename+create: r.path now resolves to a different inode → reopen and read from start
//     (the rotated-in file is fresh, so all of its content is new and must be processed).
//
// Best-effort: any stat/open error leaves the current fd in place; the next tick retries.
func (r *EveReader) reopenIfRotated() {
	if r.file == nil {
		return
	}
	cur, err := r.file.Seek(0, io.SeekCurrent)
	if err != nil {
		return
	}
	openInfo, err := r.file.Stat()
	if err != nil {
		return
	}
	// copytruncate: the open fd shrank below our read offset.
	if openInfo.Size() < cur {
		if _, err := r.file.Seek(0, io.SeekStart); err == nil {
			r.reader.Reset(r.file)
		}
		return
	}
	// rename+create: the path now points at a different inode than our open fd.
	pathInfo, err := os.Stat(r.path)
	if err != nil {
		return // path missing mid-rotation; keep current fd, retry next tick
	}
	if !os.SameFile(openInfo, pathInfo) {
		newFile, err := os.Open(r.path) // #nosec G304 -- r.path is the configured eve.json path
		if err != nil {
			return
		}
		r.file.Close()
		r.file = newFile
		r.reader.Reset(r.file) // read the rotated-in file from the start
	}
}

func (r *EveReader) drainEvents(events chan<- *Event, stopChan <-chan struct{}) {
	r.reopenIfRotated()
	for {
		event, err := r.ReadEvent()
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error reading event: %v\n", err)
			return
		}
		if event == nil {
			return // No more data available
		}
		select {
		case events <- event:
		case <-stopChan:
			return
		default:
			fmt.Fprintf(os.Stderr, "Warning: event channel full, dropping event\n")
		}
	}
}
