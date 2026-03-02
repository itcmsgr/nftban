// =============================================================================
// NFTBan v1.0 - Bandwidth Monitoring API Handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="bandwidth_handlers"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Bandwidth monitoring API handlers reading from Prometheus metrics"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package api

import (
	"bufio"
	"fmt"
	"log"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/pkg/nftbanconf"
)

// getBandwidthMetricsFile returns the bandwidth metrics file path from central config
// NO FALLBACK - path must come from /etc/nftban/nftban.conf
func getBandwidthMetricsFile() string {
	// Use GetPaths() instead of MustLoadPaths() - config already loaded at startup
	paths := nftbanconf.GetPaths()
	return paths.PrometheusBandwidthFile
}

const (
	// Cache TTL - metrics update every 10 seconds
	bandwidthCacheTTL = 10 * time.Second
)

// Cache for bandwidth metrics
var (
	bandwidthCache     *BandwidthMetrics
	bandwidthCacheMux  sync.RWMutex
	bandwidthCacheTime time.Time
)

// Bandwidth response structures matching INTEGRATION_SPEC.md

// BandwidthCurrentResponse - GET /api/v1/bandwidth/current
type BandwidthCurrentResponse struct {
	Timestamp   int64                  `json:"timestamp"`
	Total       BandwidthTotal         `json:"total"`
	Interfaces  []BandwidthInterface   `json:"interfaces"`
	Protocols   map[string]ProtocolStats `json:"protocols"`
	Connections ConnectionCounts       `json:"connections"`
	Peaks5Min   BandwidthPeaks         `json:"peaks_5min"`
}

// BandwidthTotal - total bandwidth across all interfaces
type BandwidthTotal struct {
	RxMbps    float64 `json:"rx_mbps"`
	TxMbps    float64 `json:"tx_mbps"`
	RxBytes   uint64  `json:"rx_bytes"`
	TxBytes   uint64  `json:"tx_bytes"`
	RxPackets uint64  `json:"rx_packets"`
	TxPackets uint64  `json:"tx_packets"`
}

// BandwidthInterface - per-interface stats
type BandwidthInterface struct {
	Name      string  `json:"name"`
	RxMbps    float64 `json:"rx_mbps"`
	TxMbps    float64 `json:"tx_mbps"`
	RxBytes   uint64  `json:"rx_bytes"`
	TxBytes   uint64  `json:"tx_bytes"`
	RxPackets uint64  `json:"rx_packets"`
	TxPackets uint64  `json:"tx_packets"`
	Status    string  `json:"status"`
}

// ProtocolStats - protocol-level statistics
type ProtocolStats struct {
	Bytes   uint64 `json:"bytes"`
	Packets uint64 `json:"packets"`
}

// ConnectionCounts - connection statistics
type ConnectionCounts struct {
	Active      int `json:"active"`
	Established int `json:"established"`
	TimeWait    int `json:"time_wait"`
	CloseWait   int `json:"close_wait"`
}

// BandwidthPeaks - peak bandwidth values
type BandwidthPeaks struct {
	RxMbps    float64 `json:"rx_mbps"`
	TxMbps    float64 `json:"tx_mbps"`
	Timestamp int64   `json:"timestamp,omitempty"`
}

// BandwidthHistoryResponse - GET /api/v1/bandwidth/history
type BandwidthHistoryResponse struct {
	Start        int64             `json:"start"`
	End          int64             `json:"end"`
	Interval     int               `json:"interval"`
	TotalSamples int               `json:"total_samples"`
	Samples      []BandwidthSample `json:"samples"`
}

// BandwidthSample - single bandwidth sample
type BandwidthSample struct {
	Timestamp int64   `json:"timestamp"`
	RxMbps    float64 `json:"rx_mbps"`
	TxMbps    float64 `json:"tx_mbps"`
}

// BandwidthInterfacesResponse - GET /api/v1/bandwidth/interfaces
type BandwidthInterfacesResponse struct {
	Timestamp  int64                        `json:"timestamp"`
	Interfaces []BandwidthInterfaceDetailed `json:"interfaces"`
}

// BandwidthInterfaceDetailed - detailed interface information
type BandwidthInterfaceDetailed struct {
	Name         string            `json:"name"`
	Status       string            `json:"status"`
	MAC          string            `json:"mac,omitempty"`
	IP           string            `json:"ip,omitempty"`
	RxMbps       float64           `json:"rx_mbps"`
	TxMbps       float64           `json:"tx_mbps"`
	RxBytes      uint64            `json:"rx_bytes"`
	TxBytes      uint64            `json:"tx_bytes"`
	RxPackets    uint64            `json:"rx_packets"`
	TxPackets    uint64            `json:"tx_packets"`
	Errors       int               `json:"errors"`
	Drops        int               `json:"drops"`
	History5Min  []BandwidthSample `json:"history_5min,omitempty"`
}

// BandwidthMetrics - internal structure for caching parsed metrics
type BandwidthMetrics struct {
	Timestamp   time.Time
	Interfaces  map[string]*BandwidthInterface
	TotalRxMbps float64
	TotalTxMbps float64
	Protocols   map[string]*ProtocolStats
	Connections ConnectionCounts
	Peaks       BandwidthPeaks
}

// Metric parsing regex patterns
var (
	metricPatternInterface  = regexp.MustCompile(`nftban_network_(rx|tx)_(bytes|packets|mbps)\{interface="([^"]+)"\}\s+([0-9.]+)`)
	metricPatternTotal      = regexp.MustCompile(`nftban_network_total_(rx|tx)_mbps\s+([0-9.]+)`)
	metricPatternProtocol   = regexp.MustCompile(`nftban_protocol_(bytes|packets)\{protocol="([^"]+)"\}\s+([0-9.]+)`)
	metricPatternConnection = regexp.MustCompile(`nftban_connections_(\w+)\s+([0-9]+)`)
	metricPatternPeak       = regexp.MustCompile(`nftban_bandwidth_peak_(rx|tx)_mbps\s+([0-9.]+)`)
)

// BandwidthCurrentHandler - GET /api/v1/bandwidth/current
func BandwidthCurrentHandler(w http.ResponseWriter, r *http.Request) {
	metrics, err := getBandwidthMetrics()
	if err != nil {
		log.Printf("[API] Failed to get bandwidth metrics: %v", err)
		respondJSON(w, http.StatusInternalServerError, map[string]string{
			"error":   "Bandwidth data unavailable",
			"message": "Exporter not running or metrics file missing",
			"code":    "BANDWIDTH_UNAVAILABLE",
		})
		return
	}

	// Build response
	response := BandwidthCurrentResponse{
		Timestamp: metrics.Timestamp.Unix(),
		Total: BandwidthTotal{
			RxMbps: metrics.TotalRxMbps,
			TxMbps: metrics.TotalTxMbps,
		},
		Interfaces:  make([]BandwidthInterface, 0, len(metrics.Interfaces)),
		Protocols:   make(map[string]ProtocolStats),
		Connections: metrics.Connections,
		Peaks5Min:   metrics.Peaks,
	}

	// Add interfaces
	var totalRxBytes, totalTxBytes, totalRxPackets, totalTxPackets uint64
	for _, iface := range metrics.Interfaces {
		response.Interfaces = append(response.Interfaces, *iface)
		totalRxBytes += iface.RxBytes
		totalTxBytes += iface.TxBytes
		totalRxPackets += iface.RxPackets
		totalTxPackets += iface.TxPackets
	}

	response.Total.RxBytes = totalRxBytes
	response.Total.TxBytes = totalTxBytes
	response.Total.RxPackets = totalRxPackets
	response.Total.TxPackets = totalTxPackets

	// Add protocols
	for proto, stats := range metrics.Protocols {
		response.Protocols[proto] = *stats
	}

	respondJSON(w, http.StatusOK, response)
}

// BandwidthHistoryHandler - GET /api/v1/bandwidth/history?minutes=5
func BandwidthHistoryHandler(w http.ResponseWriter, r *http.Request) {
	// Parse minutes parameter
	minutesStr := r.URL.Query().Get("minutes")
	minutes := 5 // Default 5 minutes
	if minutesStr != "" {
		if m, err := strconv.Atoi(minutesStr); err == nil && m > 0 && m <= 60 {
			minutes = m
		}
	}

	// TODO: Implement history tracking
	// For now, return empty samples
	now := time.Now()
	response := BandwidthHistoryResponse{
		Start:        now.Add(-time.Duration(minutes) * time.Minute).Unix(),
		End:          now.Unix(),
		Interval:     10, // 10-second intervals
		TotalSamples: 0,
		Samples:      []BandwidthSample{},
	}

	respondJSON(w, http.StatusOK, response)
}

// BandwidthInterfacesHandler - GET /api/v1/bandwidth/interfaces
func BandwidthInterfacesHandler(w http.ResponseWriter, r *http.Request) {
	metrics, err := getBandwidthMetrics()
	if err != nil {
		log.Printf("[API] Failed to get bandwidth metrics: %v", err)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{
			Error: "Failed to get interface statistics",
		})
		return
	}

	// Build response
	response := BandwidthInterfacesResponse{
		Timestamp:  metrics.Timestamp.Unix(),
		Interfaces: make([]BandwidthInterfaceDetailed, 0, len(metrics.Interfaces)),
	}

	// Get additional interface details from /sys/class/net
	for _, iface := range metrics.Interfaces {
		detailed := BandwidthInterfaceDetailed{
			Name:      iface.Name,
			Status:    iface.Status,
			RxMbps:    iface.RxMbps,
			TxMbps:    iface.TxMbps,
			RxBytes:   iface.RxBytes,
			TxBytes:   iface.TxBytes,
			RxPackets: iface.RxPackets,
			TxPackets: iface.TxPackets,
			Errors:    0, // TODO: Get from /proc/net/dev
			Drops:     0, // TODO: Get from /proc/net/dev
		}

		// Try to get MAC address
		if mac, err := readFile(fmt.Sprintf("/sys/class/net/%s/address", iface.Name)); err == nil {
			detailed.MAC = strings.TrimSpace(mac)
		}

		// Try to get IP address (simplified - just first IPv4)
		// TODO: More robust IP detection
		detailed.IP = getInterfaceIP(iface.Name)

		response.Interfaces = append(response.Interfaces, detailed)
	}

	respondJSON(w, http.StatusOK, response)
}

// BandwidthConnectionsHandler - GET /api/v1/bandwidth/connections?limit=10
func BandwidthConnectionsHandler(w http.ResponseWriter, r *http.Request) {
	// Use existing ConnectionsHandler logic
	// The limit parameter is handled by ConnectionsHandler
	ConnectionsHandler(w, r)
}

// getBandwidthMetrics reads and parses the Prometheus metrics file
func getBandwidthMetrics() (*BandwidthMetrics, error) {
	// Check cache
	bandwidthCacheMux.RLock()
	if bandwidthCache != nil && time.Since(bandwidthCacheTime) < bandwidthCacheTTL {
		defer bandwidthCacheMux.RUnlock()
		return bandwidthCache, nil
	}
	bandwidthCacheMux.RUnlock()

	// Read metrics file from central config path
	file, err := os.Open(getBandwidthMetricsFile())
	if err != nil {
		return nil, fmt.Errorf("failed to open metrics file: %w", err)
	}
	defer file.Close()

	metrics := &BandwidthMetrics{
		Timestamp:  time.Now(),
		Interfaces: make(map[string]*BandwidthInterface),
		Protocols:  make(map[string]*ProtocolStats),
	}

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()

		// Skip comments and empty lines
		if strings.HasPrefix(line, "#") || strings.TrimSpace(line) == "" {
			continue
		}

		// Parse interface metrics
		if matches := metricPatternInterface.FindStringSubmatch(line); len(matches) == 5 {
			direction := matches[1] // rx or tx
			metric := matches[2]    // bytes, packets, mbps
			iface := matches[3]
			value := matches[4]

			// Initialize interface if needed
			if metrics.Interfaces[iface] == nil {
				metrics.Interfaces[iface] = &BandwidthInterface{
					Name:   iface,
					Status: "up", // Assume up if we have metrics
				}
			}

			// Parse and set value
			if metric == "bytes" {
				if v, err := strconv.ParseUint(value, 10, 64); err == nil {
					if direction == "rx" {
						metrics.Interfaces[iface].RxBytes = v
					} else {
						metrics.Interfaces[iface].TxBytes = v
					}
				}
			} else if metric == "packets" {
				if v, err := strconv.ParseUint(value, 10, 64); err == nil {
					if direction == "rx" {
						metrics.Interfaces[iface].RxPackets = v
					} else {
						metrics.Interfaces[iface].TxPackets = v
					}
				}
			} else if metric == "mbps" {
				if v, err := strconv.ParseFloat(value, 64); err == nil {
					if direction == "rx" {
						metrics.Interfaces[iface].RxMbps = v
					} else {
						metrics.Interfaces[iface].TxMbps = v
					}
				}
			}
			continue
		}

		// Parse total bandwidth
		if matches := metricPatternTotal.FindStringSubmatch(line); len(matches) == 3 {
			direction := matches[1]
			value := matches[2]
			if v, err := strconv.ParseFloat(value, 64); err == nil {
				if direction == "rx" {
					metrics.TotalRxMbps = v
				} else {
					metrics.TotalTxMbps = v
				}
			}
			continue
		}

		// Parse protocol metrics
		if matches := metricPatternProtocol.FindStringSubmatch(line); len(matches) == 4 {
			metric := matches[1]  // bytes or packets
			protocol := matches[2]
			value := matches[3]

			// Initialize protocol if needed
			if metrics.Protocols[protocol] == nil {
				metrics.Protocols[protocol] = &ProtocolStats{}
			}

			// Parse and set value
			if v, err := strconv.ParseUint(value, 10, 64); err == nil {
				if metric == "bytes" {
					metrics.Protocols[protocol].Bytes = v
				} else {
					metrics.Protocols[protocol].Packets = v
				}
			}
			continue
		}

		// Parse connection metrics
		if matches := metricPatternConnection.FindStringSubmatch(line); len(matches) == 3 {
			connType := matches[1]
			value := matches[2]
			if v, err := strconv.Atoi(value); err == nil {
				switch connType {
				case "active":
					metrics.Connections.Active = v
				case "established":
					metrics.Connections.Established = v
				case "time_wait":
					metrics.Connections.TimeWait = v
				case "close_wait":
					metrics.Connections.CloseWait = v
				}
			}
			continue
		}

		// Parse peak bandwidth
		if matches := metricPatternPeak.FindStringSubmatch(line); len(matches) == 3 {
			direction := matches[1]
			value := matches[2]
			if v, err := strconv.ParseFloat(value, 64); err == nil {
				if direction == "rx" {
					metrics.Peaks.RxMbps = v
				} else {
					metrics.Peaks.TxMbps = v
				}
			}
			continue
		}
	}

	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("error reading metrics file: %w", err)
	}

	// Update cache
	bandwidthCacheMux.Lock()
	bandwidthCache = metrics
	bandwidthCacheTime = time.Now()
	bandwidthCacheMux.Unlock()

	return metrics, nil
}

// Helper function to read a file
func readFile(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

// Helper function to get interface IP (simplified)
func getInterfaceIP(iface string) string {
	// This is a simplified implementation
	// TODO: Use proper network interface APIs
	return ""
}
