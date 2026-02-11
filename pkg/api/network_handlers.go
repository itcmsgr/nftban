// =============================================================================
// NFTBan v1.0 - Network Monitoring API Handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="network_handlers"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Network monitoring API handlers for bandwidth and interface stats"
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
	"log"
	"net/http"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/pkg/metrics"
)

// NetworkStats represents network bandwidth statistics
type NetworkStats struct {
	Timestamp     time.Time              `json:"timestamp"`
	Interfaces    []InterfaceStats       `json:"interfaces"`
	Total         InterfaceStats         `json:"total"`
	RecentSamples []metrics.Sample       `json:"recent_samples,omitempty"`
}

// InterfaceStats represents stats for a single network interface
type InterfaceStats struct {
	Name          string  `json:"name"`
	RxBytes       uint64  `json:"rx_bytes"`
	TxBytes       uint64  `json:"tx_bytes"`
	RxPackets     uint64  `json:"rx_packets"`
	TxPackets     uint64  `json:"tx_packets"`
	RxMbps        float64 `json:"rx_mbps,omitempty"`
	TxMbps        float64 `json:"tx_mbps,omitempty"`
}

// Connection represents a network connection from ss output
type Connection struct {
	State       string  `json:"state"`
	LocalAddr   string  `json:"local_addr"`
	LocalPort   string  `json:"local_port"`
	PeerAddr    string  `json:"peer_addr"`
	PeerPort    string  `json:"peer_port"`
	Timer       string  `json:"timer,omitempty"`        // Timer name (keepalive, on, off, etc.)
	TimerValue  string  `json:"timer_value,omitempty"`  // Timer value (e.g., "30sec")
	Protocol    string  `json:"protocol"`
	RecvQ       int     `json:"recv_q"`       // Receive queue size
	SendQ       int     `json:"send_q"`       // Send queue size
	UID         string  `json:"uid,omitempty"` // User ID (if available)
	ProcessInfo string  `json:"process,omitempty"` // Process info (if available)
}

// ConnectionStats represents connection statistics
type ConnectionStats struct {
	Timestamp   time.Time    `json:"timestamp"`
	Total       int          `json:"total"`
	ByState     map[string]int `json:"by_state"`
	ByProtocol  map[string]int `json:"by_protocol"`
	Connections []Connection `json:"connections,omitempty"`
}

// BandwidthHandler returns current bandwidth statistics
// GET /api/network/bandwidth
func BandwidthHandler(w http.ResponseWriter, r *http.Request) {
	// Get samples parameter
	samplesStr := r.URL.Query().Get("samples")
	includeSamples := samplesStr != ""

	var sampleCount int
	if samplesStr != "" {
		if count, err := strconv.Atoi(samplesStr); err == nil && count > 0 {
			sampleCount = count
		} else {
			sampleCount = 60 // Default to last 60 samples (10 minutes at 10s interval)
		}
	}

	stats, err := getNetworkStats(includeSamples, sampleCount)
	if err != nil {
		log.Printf("[API] Failed to get network stats: %v", err)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{
			Error: "Failed to get network statistics",
		})
		return
	}

	respondJSON(w, http.StatusOK, stats)
}

// ConnectionsHandler returns current network connections
// GET /api/network/connections?protocol=tcp&limit=100
func ConnectionsHandler(w http.ResponseWriter, r *http.Request) {
	protocol := r.URL.Query().Get("protocol")
	if protocol == "" {
		protocol = "tcp" // Default to TCP
	}

	limitStr := r.URL.Query().Get("limit")
	limit := 100 // Default limit
	if limitStr != "" {
		if l, err := strconv.Atoi(limitStr); err == nil && l > 0 {
			limit = l
		}
	}

	stats, err := getConnectionStats(protocol, limit)
	if err != nil {
		log.Printf("[API] Failed to get connection stats: %v", err)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{
			Error: "Failed to get connection statistics",
		})
		return
	}

	respondJSON(w, http.StatusOK, stats)
}

// getNetworkStats reads /proc/net/dev and returns current statistics
func getNetworkStats(includeSamples bool, sampleCount int) (*NetworkStats, error) {
	cmd := exec.Command("cat", "/proc/net/dev")
	output, err := cmd.Output()
	if err != nil {
		return nil, err
	}

	stats := &NetworkStats{
		Timestamp:  time.Now(),
		Interfaces: []InterfaceStats{},
		Total:      InterfaceStats{Name: "total"},
	}

	scanner := bufio.NewScanner(strings.NewReader(string(output)))

	// Skip first two header lines
	scanner.Scan()
	scanner.Scan()

	for scanner.Scan() {
		line := scanner.Text()
		fields := strings.Fields(line)
		if len(fields) < 10 {
			continue
		}

		// Parse interface name
		iface := strings.TrimSuffix(fields[0], ":")

		// Parse RX stats
		rxBytes, _ := strconv.ParseUint(fields[1], 10, 64)
		rxPackets, _ := strconv.ParseUint(fields[2], 10, 64)

		// Parse TX stats
		txBytes, _ := strconv.ParseUint(fields[9], 10, 64)
		txPackets, _ := strconv.ParseUint(fields[10], 10, 64)

		ifaceStats := InterfaceStats{
			Name:      iface,
			RxBytes:   rxBytes,
			TxBytes:   txBytes,
			RxPackets: rxPackets,
			TxPackets: txPackets,
		}

		stats.Interfaces = append(stats.Interfaces, ifaceStats)

		// Skip loopback for totals
		if iface != "lo" {
			stats.Total.RxBytes += rxBytes
			stats.Total.TxBytes += txBytes
			stats.Total.RxPackets += rxPackets
			stats.Total.TxPackets += txPackets
		}
	}

	// Add recent samples from metrics sampler if requested
	if includeSamples {
		sampler := metrics.GetSampler()
		samples := sampler.GetRecentSamples(sampleCount)
		stats.RecentSamples = samples

		// Calculate current rates from most recent sample
		if len(samples) > 0 {
			lastSample := samples[len(samples)-1]
			stats.Total.RxMbps = lastSample.NetworkRxMbps
			stats.Total.TxMbps = lastSample.NetworkTxMbps
		}
	}

	return stats, nil
}

// getConnectionStats uses ss command to get connection statistics
// Optimized with -o flag to include timer information
func getConnectionStats(protocol string, limit int) (*ConnectionStats, error) {
	// Build ss command based on protocol
	// -t: TCP, -u: UDP, -a: all states, -n: numeric, -o: show timer info
	// Using -o flag speeds up parsing and includes timer values directly
	var cmd *exec.Cmd
	switch protocol {
	case "tcp":
		cmd = exec.Command("ss", "-tano")
	case "udp":
		cmd = exec.Command("ss", "-uano")
	case "all":
		cmd = exec.Command("ss", "-tuano")
	default:
		cmd = exec.Command("ss", "-tano")
	}

	output, err := cmd.Output()
	if err != nil {
		return nil, err
	}

	stats := &ConnectionStats{
		Timestamp:   time.Now(),
		ByState:     make(map[string]int),
		ByProtocol:  make(map[string]int),
		Connections: make([]Connection, 0, limit), // Pre-allocate capacity
	}

	scanner := bufio.NewScanner(strings.NewReader(string(output)))

	// Skip header line
	scanner.Scan()

	connectionCount := 0
	for scanner.Scan() && connectionCount < limit {
		line := scanner.Text()
		fields := strings.Fields(line)
		if len(fields) < 5 {
			continue
		}

		// Parse connection
		// Format with -o flag:
		// State Recv-Q Send-Q Local_Address:Port Peer_Address:Port timer:(name,value,retransmissions)
		// Example: ESTAB 0 0 192.168.1.100:22 192.168.1.1:54321 timer:(keepalive,30sec,0)

		conn := Connection{
			State:    fields[0],
			Protocol: "tcp", // Will be determined from context
		}

		// Parse Recv-Q and Send-Q
		if recvQ, err := strconv.Atoi(fields[1]); err == nil {
			conn.RecvQ = recvQ
		}
		if sendQ, err := strconv.Atoi(fields[2]); err == nil {
			conn.SendQ = sendQ
		}

		// Parse local address:port
		localAddr := fields[3]
		if idx := strings.LastIndex(localAddr, ":"); idx != -1 {
			conn.LocalAddr = localAddr[:idx]
			conn.LocalPort = localAddr[idx+1:]
		}

		// Parse peer address:port
		peerAddr := fields[4]
		if idx := strings.LastIndex(peerAddr, ":"); idx != -1 {
			conn.PeerAddr = peerAddr[:idx]
			conn.PeerPort = peerAddr[idx+1:]
		}

		// Parse timer information (field 5+)
		// Format: timer:(name,value,retrans) or timer:(name,value)
		// Examples:
		//   timer:(keepalive,30sec,0)
		//   timer:(on,238ms,0)
		//   timer:(off)
		for i := 5; i < len(fields); i++ {
			field := fields[i]

			// Check for timer
			if strings.HasPrefix(field, "timer:(") {
				timerInfo := strings.TrimPrefix(field, "timer:(")
				timerInfo = strings.TrimSuffix(timerInfo, ")")
				parts := strings.Split(timerInfo, ",")

				if len(parts) > 0 {
					conn.Timer = parts[0] // Timer name (keepalive, on, off, etc.)
				}
				if len(parts) > 1 {
					conn.TimerValue = parts[1] // Timer value (30sec, 238ms, etc.)
				}
			}

			// Check for uid
			if strings.HasPrefix(field, "uid:") {
				conn.UID = strings.TrimPrefix(field, "uid:")
			}

			// Check for process info
			if strings.HasPrefix(field, "users:") {
				conn.ProcessInfo = strings.TrimPrefix(field, "users:")
			}
		}

		// Determine protocol from state or context
		if conn.State == "UNCONN" {
			conn.Protocol = "udp"
		} else {
			conn.Protocol = "tcp"
		}

		stats.Connections = append(stats.Connections, conn)
		stats.ByState[conn.State]++
		stats.ByProtocol[conn.Protocol]++
		stats.Total++
		connectionCount++
	}

	return stats, nil
}

// MetricsSamplesHandler returns recent metric samples
// GET /api/network/metrics/samples?count=60
func MetricsSamplesHandler(w http.ResponseWriter, r *http.Request) {
	countStr := r.URL.Query().Get("count")
	count := 60 // Default to last 60 samples (10 minutes)

	if countStr != "" {
		if c, err := strconv.Atoi(countStr); err == nil && c > 0 {
			count = c
		}
	}

	sampler := metrics.GetSampler()
	samples := sampler.GetRecentSamples(count)

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"count":   len(samples),
		"samples": samples,
	})
}
