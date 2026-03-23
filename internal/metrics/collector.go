// =============================================================================
// NFTBan - Prometheus Metrics Collector
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2025 Antonios Voulvoulis <contact@nftban.com>
// meta:name="collector"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Prometheus metrics collector for node_exporter textfile"
// meta:inventory.files="/var/lib/node_exporter/textfile_collector/nftban.prom"
// meta:inventory.binaries="nft"
// meta:inventory.env_vars="NFTBAN_METRICS_FILE,NFTBAN_API_URL"
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network="localhost:8080"
// meta:inventory.privileges="none"
// =============================================================================

// Package metrics provides efficient metrics collection for NFTBan
// This collector replaces slow bash-based metrics with fast Go implementation
package metrics

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/safety"
)

// Collector efficiently gathers NFTBan metrics for Prometheus export
type Collector struct {
	outputFile string
	stateDir   string
	logDir     string
}

// NewCollector creates a new metrics collector
func NewCollector(outputFile, stateDir, logDir string) *Collector {
	return &Collector{
		outputFile: outputFile,
		stateDir:   stateDir,
		logDir:     logDir,
	}
}

// Collect gathers and writes all metrics to the Prometheus textfile
func (c *Collector) Collect() error {
	startTime := time.Now()

	// Create temp file for atomic write (TOCTOU-safe)
	tempFile := c.outputFile + ".tmp"
	f, err := safety.SafeCreate(tempFile, 0644)
	if err != nil {
		return fmt.Errorf("create temp file: %w", err)
	}
	defer f.Close()

	// Write metrics
	if err := c.writeBlockMetrics(f); err != nil {
		return fmt.Errorf("write block metrics: %w", err)
	}

	if err := c.writeBandwidthMetrics(f); err != nil {
		return fmt.Errorf("write bandwidth metrics: %w", err)
	}

	if err := c.writeHealthMetrics(f); err != nil {
		return fmt.Errorf("write health metrics: %w", err)
	}

	if err := c.writeNFTablesMetrics(f); err != nil {
		return fmt.Errorf("write nftables metrics: %w", err)
	}

	if err := c.writeProtocolMetrics(f); err != nil {
		return fmt.Errorf("write protocol metrics: %w", err)
	}

	if err := c.writeExporterMetrics(f, startTime); err != nil {
		return fmt.Errorf("write exporter metrics: %w", err)
	}

	// Atomic rename
	if err := os.Rename(tempFile, c.outputFile); err != nil {
		return fmt.Errorf("atomic rename: %w", err)
	}

	// Set permissions for node_exporter
	if err := os.Chmod(c.outputFile, 0644); err != nil {
		return fmt.Errorf("chmod: %w", err)
	}

	return nil
}

// basicStatsFromAPI holds data from /api/v1/basic-stats endpoint
type basicStatsFromAPI struct {
	BannedIPv4    int64 `json:"banned_ipv4"`
	BannedIPv6    int64 `json:"banned_ipv6"`
	WhitelistIPv4 int64 `json:"whitelist_ipv4"`
	WhitelistIPv6 int64 `json:"whitelist_ipv6"`
	RulesTotal    int64 `json:"rules_total"`
	FeedsActive   int   `json:"feeds_active"`
	FeedsIPs      int64 `json:"feeds_ips"`
}

// tryGetBasicStatsFromAPI attempts to fetch block counts from the API (NO CLI overhead)
// Returns nil if API is unavailable - caller should fall back to CLI
func (c *Collector) tryGetBasicStatsFromAPI() *basicStatsFromAPI {
	apiURL := os.Getenv("NFTBAN_API_URL")
	if apiURL == "" {
		apiURL = "http://127.0.0.1:8080"
	}

	client := &http.Client{Timeout: 2 * time.Second}
	resp, err := client.Get(apiURL + "/api/v1/basic-stats")
	if err != nil {
		return nil
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil
	}

	var result struct {
		Success bool              `json:"success"`
		Data    basicStatsFromAPI `json:"data"`
	}
	if err := json.Unmarshal(body, &result); err != nil || !result.Success {
		return nil
	}

	return &result.Data
}

// writeBlockMetrics writes ban/block count metrics
// Tries API first (NO CLI overhead), falls back to nft CLI if unavailable
func (c *Collector) writeBlockMetrics(f *os.File) error {
	var ipv4Count, ipv6Count, wlIPv4, wlIPv6 int

	// Try API first (from shared state - NO CLI)
	if stats := c.tryGetBasicStatsFromAPI(); stats != nil {
		ipv4Count = int(stats.BannedIPv4)
		ipv6Count = int(stats.BannedIPv6)
		wlIPv4 = int(stats.WhitelistIPv4)
		wlIPv6 = int(stats.WhitelistIPv6)
	} else {
		// Fallback to nft CLI
		nftSets, err := c.getNFTablesSets()
		if err != nil {
			return err
		}

		ipv4Count = c.countSetElements(nftSets, "ip", "nftban", "blacklist_ipv4")
		ipv6Count = c.countSetElements(nftSets, "ip6", "nftban", "blacklist_ipv6")
		wlIPv4 = c.countSetElements(nftSets, "ip", "nftban", "whitelist_ipv4")
		wlIPv6 = c.countSetElements(nftSets, "ip6", "nftban", "whitelist_ipv6")
	}

	totalBlocks := ipv4Count + ipv6Count

	fmt.Fprintf(f, "# HELP nftban_blocks_total Total number of blocked IPs (permanent + temporary)\n")
	fmt.Fprintf(f, "# TYPE nftban_blocks_total gauge\n")
	fmt.Fprintf(f, "nftban_blocks_total %d\n\n", totalBlocks)

	fmt.Fprintf(f, "# HELP nftban_blocks_ipv4 Number of blocked IPv4 addresses\n")
	fmt.Fprintf(f, "# TYPE nftban_blocks_ipv4 gauge\n")
	fmt.Fprintf(f, "nftban_blocks_ipv4 %d\n\n", ipv4Count)

	fmt.Fprintf(f, "# HELP nftban_blocks_ipv6 Number of blocked IPv6 addresses\n")
	fmt.Fprintf(f, "# TYPE nftban_blocks_ipv6 gauge\n")
	fmt.Fprintf(f, "nftban_blocks_ipv6 %d\n\n", ipv6Count)

	fmt.Fprintf(f, "# HELP nftban_whitelist_ipv4 Number of whitelisted IPv4 addresses\n")
	fmt.Fprintf(f, "# TYPE nftban_whitelist_ipv4 gauge\n")
	fmt.Fprintf(f, "nftban_whitelist_ipv4 %d\n\n", wlIPv4)

	fmt.Fprintf(f, "# HELP nftban_whitelist_ipv6 Number of whitelisted IPv6 addresses\n")
	fmt.Fprintf(f, "# TYPE nftban_whitelist_ipv6 gauge\n")
	fmt.Fprintf(f, "nftban_whitelist_ipv6 %d\n\n", wlIPv6)

	return nil
}

// writeBandwidthMetrics writes network bandwidth metrics
func (c *Collector) writeBandwidthMetrics(f *os.File) error {
	interfaces, err := c.getNetworkInterfaces()
	if err != nil {
		return err
	}

	var totalRxBytes, totalTxBytes uint64

	for _, iface := range interfaces {
		stats, err := c.getInterfaceStats(iface)
		if err != nil {
			continue
		}

		totalRxBytes += stats.RxBytes
		totalTxBytes += stats.TxBytes

		fmt.Fprintf(f, "nftban_network_rx_bytes{interface=\"%s\"} %d\n", iface, stats.RxBytes)
		fmt.Fprintf(f, "nftban_network_tx_bytes{interface=\"%s\"} %d\n", iface, stats.TxBytes)
		fmt.Fprintf(f, "nftban_network_rx_packets{interface=\"%s\"} %d\n", iface, stats.RxPackets)
		fmt.Fprintf(f, "nftban_network_tx_packets{interface=\"%s\"} %d\n", iface, stats.TxPackets)
	}

	fmt.Fprintf(f, "\n# HELP nftban_network_total_rx_bytes Total receive bytes\n")
	fmt.Fprintf(f, "# TYPE nftban_network_total_rx_bytes counter\n")
	fmt.Fprintf(f, "nftban_network_total_rx_bytes %d\n\n", totalRxBytes)

	fmt.Fprintf(f, "# HELP nftban_network_total_tx_bytes Total transmit bytes\n")
	fmt.Fprintf(f, "# TYPE nftban_network_total_tx_bytes counter\n")
	fmt.Fprintf(f, "nftban_network_total_tx_bytes %d\n\n", totalTxBytes)

	return nil
}

// writeHealthMetrics writes component health status
func (c *Collector) writeHealthMetrics(f *os.File) error {
	components := []string{"nftables", "ssh", "polkit"}

	fmt.Fprintf(f, "# HELP nftban_health_status Component health status (0=OK, 1=WARN, 2=ERROR, 3=CRITICAL)\n")
	fmt.Fprintf(f, "# TYPE nftban_health_status gauge\n")

	for _, comp := range components {
		status := c.getHealthStatus(comp)
		fmt.Fprintf(f, "nftban_health_status{component=\"%s\"} %d\n", comp, status)
	}
	fmt.Fprintln(f)

	return nil
}

// writeNFTablesMetrics writes nftables-specific metrics
func (c *Collector) writeNFTablesMetrics(f *os.File) error {
	// Count rules efficiently
	ruleCount, err := c.countNFTablesRules()
	if err != nil {
		ruleCount = 0
	}

	fmt.Fprintf(f, "# HELP nftban_nftables_rules_total Total number of nftables rules\n")
	fmt.Fprintf(f, "# TYPE nftban_nftables_rules_total gauge\n")
	fmt.Fprintf(f, "nftban_nftables_rules_total %d\n\n", ruleCount)

	return nil
}

// writeProtocolMetrics writes TCP/UDP/ICMP statistics
func (c *Collector) writeProtocolMetrics(f *os.File) error {
	// Parse /proc/net/snmp for protocol stats
	tcpStats, udpStats := c.getProtocolStats()

	fmt.Fprintf(f, "# HELP nftban_protocol_segments Total segments per protocol\n")
	fmt.Fprintf(f, "# TYPE nftban_protocol_segments counter\n")
	fmt.Fprintf(f, "nftban_protocol_segments{protocol=\"tcp\"} %d\n", tcpStats.InSegs+tcpStats.OutSegs)
	fmt.Fprintf(f, "nftban_protocol_segments{protocol=\"udp\"} %d\n\n", udpStats.InDatagrams+udpStats.OutDatagrams)

	// Connection stats from /proc/net/sockstat
	connStats := c.getConnectionStats()
	fmt.Fprintf(f, "# HELP nftban_connections_active Active TCP connections\n")
	fmt.Fprintf(f, "# TYPE nftban_connections_active gauge\n")
	fmt.Fprintf(f, "nftban_connections_active %d\n\n", connStats.TCP)

	return nil
}

// writeExporterMetrics writes metadata about the exporter itself
func (c *Collector) writeExporterMetrics(f *os.File, startTime time.Time) error {
	duration := time.Since(startTime).Seconds()

	fmt.Fprintf(f, "# HELP nftban_exporter_duration_seconds Time taken to collect metrics\n")
	fmt.Fprintf(f, "# TYPE nftban_exporter_duration_seconds gauge\n")
	fmt.Fprintf(f, "nftban_exporter_duration_seconds %.6f\n\n", duration)

	fmt.Fprintf(f, "# HELP nftban_exporter_last_success_timestamp Unix timestamp of last successful collection\n")
	fmt.Fprintf(f, "# TYPE nftban_exporter_last_success_timestamp gauge\n")
	fmt.Fprintf(f, "nftban_exporter_last_success_timestamp %d\n\n", time.Now().Unix())

	fmt.Fprintf(f, "# HELP nftban_exporter_backend Type of exporter backend (1=go, 0=bash)\n")
	fmt.Fprintf(f, "# TYPE nftban_exporter_backend gauge\n")
	fmt.Fprintf(f, "nftban_exporter_backend 1\n\n")

	return nil
}

// =============================================================================
// Helper functions
// =============================================================================

// getNFTablesSets retrieves all nftables sets in one efficient JSON call
func (c *Collector) getNFTablesSets() (map[string]interface{}, error) {
	cmd := exec.Command("nft", "-j", "list", "ruleset")
	output, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("nft list ruleset: %w", err)
	}

	var result map[string]interface{}
	if err := json.Unmarshal(output, &result); err != nil {
		return nil, fmt.Errorf("unmarshal nft json: %w", err)
	}

	return result, nil
}

// countSetElements counts elements in a specific nftables set
func (c *Collector) countSetElements(nftSets map[string]interface{}, family, table, setName string) int {
	// This is a simplified implementation - actual implementation would parse
	// the JSON structure from nft -j output
	// For now, fall back to direct nft command (still better than bash grep/awk)
	cmd := exec.Command("nft", "list", "set", family, table, setName)
	output, err := cmd.Output()
	if err != nil {
		return 0
	}

	// Count elements (lines containing IP addresses or ranges)
	count := 0
	scanner := bufio.NewScanner(strings.NewReader(string(output)))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if strings.Contains(line, ".") || strings.Contains(line, ":") {
			count++
		}
	}

	return count
}

// InterfaceStats represents network interface statistics
type InterfaceStats struct {
	RxBytes   uint64
	RxPackets uint64
	TxBytes   uint64
	TxPackets uint64
}

// getNetworkInterfaces returns list of active network interfaces
func (c *Collector) getNetworkInterfaces() ([]string, error) {
	// Read /proc/net/dev
	f, err := os.Open("/proc/net/dev")
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var interfaces []string
	scanner := bufio.NewScanner(f)

	// Skip header lines
	scanner.Scan()
	scanner.Scan()

	for scanner.Scan() {
		line := scanner.Text()
		parts := strings.Split(line, ":")
		if len(parts) < 2 {
			continue
		}

		iface := strings.TrimSpace(parts[0])

		// Skip loopback and virtual interfaces
		if iface == "lo" || strings.HasPrefix(iface, "docker") ||
		   strings.HasPrefix(iface, "veth") || strings.HasPrefix(iface, "br-") {
			continue
		}

		interfaces = append(interfaces, iface)
	}

	return interfaces, nil
}

// getInterfaceStats retrieves stats for a network interface
func (c *Collector) getInterfaceStats(iface string) (*InterfaceStats, error) {
	f, err := os.Open("/proc/net/dev")
	if err != nil {
		return nil, err
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.Contains(line, iface+":") {
			continue
		}

		parts := strings.Split(line, ":")
		if len(parts) < 2 {
			continue
		}

		fields := strings.Fields(parts[1])
		if len(fields) < 10 {
			continue
		}

		stats := &InterfaceStats{}
		stats.RxBytes, _ = strconv.ParseUint(fields[0], 10, 64)
		stats.RxPackets, _ = strconv.ParseUint(fields[1], 10, 64)
		stats.TxBytes, _ = strconv.ParseUint(fields[8], 10, 64)
		stats.TxPackets, _ = strconv.ParseUint(fields[9], 10, 64)

		return stats, nil
	}

	return nil, fmt.Errorf("interface %s not found", iface)
}

// getHealthStatus checks component health
func (c *Collector) getHealthStatus(component string) int {
	// 0=OK, 1=WARN, 2=ERROR, 3=CRITICAL

	switch component {
	case "nftables":
		if c.isServiceActive("nftables") {
			return 0
		}
		return 2
	case "ssh":
		if c.isServiceActive("sshd") || c.isServiceActive("ssh") {
			return 0
		}
		return 2
	case "polkit":
		if c.isServiceActive("polkit") || c.isServiceActive("polkitd") {
			return 0
		}
		return 1 // WARN, not critical
	default:
		return 2
	}
}

// isServiceActive checks if a systemd service is active
func (c *Collector) isServiceActive(service string) bool {
	cmd := exec.Command("systemctl", "is-active", service)
	output, err := cmd.Output()
	if err != nil {
		return false
	}
	return strings.TrimSpace(string(output)) == "active"
}

// countNFTablesRules counts total nftables rules
func (c *Collector) countNFTablesRules() (int, error) {
	cmd := exec.Command("nft", "list", "ruleset")
	output, err := cmd.Output()
	if err != nil {
		return 0, err
	}

	count := 0
	scanner := bufio.NewScanner(strings.NewReader(string(output)))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if strings.HasPrefix(line, "ip ") || strings.HasPrefix(line, "ip6 ") {
			count++
		}
	}

	return count, nil
}

// TCPStats represents TCP protocol statistics
type TCPStats struct {
	InSegs  uint64
	OutSegs uint64
}

// UDPStats represents UDP protocol statistics
type UDPStats struct {
	InDatagrams  uint64
	OutDatagrams uint64
}

// getProtocolStats retrieves TCP/UDP statistics from /proc/net/snmp
func (c *Collector) getProtocolStats() (*TCPStats, *UDPStats) {
	tcp := &TCPStats{}
	udp := &UDPStats{}

	f, err := os.Open("/proc/net/snmp")
	if err != nil {
		return tcp, udp
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()

		if strings.HasPrefix(line, "Tcp:") && !strings.Contains(line, "RtoAlgorithm") {
			fields := strings.Fields(line)
			if len(fields) > 10 {
				tcp.InSegs, _ = strconv.ParseUint(fields[10], 10, 64)
				tcp.OutSegs, _ = strconv.ParseUint(fields[11], 10, 64)
			}
		}

		if strings.HasPrefix(line, "Udp:") && !strings.Contains(line, "InDatagrams") {
			fields := strings.Fields(line)
			if len(fields) > 2 {
				udp.InDatagrams, _ = strconv.ParseUint(fields[1], 10, 64)
				udp.OutDatagrams, _ = strconv.ParseUint(fields[4], 10, 64)
			}
		}
	}

	return tcp, udp
}

// ConnectionStats represents connection statistics
type ConnectionStats struct {
	TCP int
}

// getConnectionStats retrieves connection statistics
func (c *Collector) getConnectionStats() *ConnectionStats {
	stats := &ConnectionStats{}

	f, err := os.Open("/proc/net/sockstat")
	if err != nil {
		return stats
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "TCP: inuse") {
			fields := strings.Fields(line)
			if len(fields) > 2 {
				stats.TCP, _ = strconv.Atoi(fields[2])
			}
		}
	}

	return stats
}
