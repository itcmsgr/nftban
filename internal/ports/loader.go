// =============================================================================
// NFTBan - Port Configuration Loader
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="loader"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Loads port rules from configuration files (PORT/PROTOCOL format)"
// meta:input="Port configuration files"
// meta:output="TCP and UDP port lists"
// meta:depends="bufio,os"
// meta:inventory.files="/etc/nftban/ports.d/*.conf"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package ports

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/itcmsgr/nftban/internal/util"
)

// PortRule represents a single port rule
type PortRule struct {
	Port      int    // Port number (e.g., 22, 80, 443)
	Protocol  string // "T" (TCP), "U" (UDP), or "B" (Both)
	Direction string // "I" (Input), "O" (Output), "IO" (Both) - default "I"
	Source    string // Config file where this rule came from
}

// PortConfig holds all port rules loaded from configuration
type PortConfig struct {
	TCPPorts   []int            // All TCP ports (from T and B rules)
	UDPPorts   []int            // All UDP ports (from U and B rules)
	TCPPortsIn  []int           `json:"tcp_ports_in"`  // TCP ports for input direction
	TCPPortsOut []int           `json:"tcp_ports_out"` // TCP ports for output direction
	UDPPortsIn  []int           `json:"udp_ports_in"`  // UDP ports for input direction
	UDPPortsOut []int           `json:"udp_ports_out"` // UDP ports for output direction
	AllRules  []PortRule       // All rules with metadata
	PortMap   map[int][]string // port -> protocols (for deduplication)
}

// LoadPortsFromDirectory loads all port configuration files from a directory
// Expected format: PORT/PROTOCOL where PROTOCOL is T (TCP), U (UDP), or B (Both)
// Example: 22/T, 53/B, 80/T
func LoadPortsFromDirectory(dir string) (*PortConfig, error) {
	config := &PortConfig{
		TCPPorts: []int{},
		UDPPorts: []int{},
		AllRules: []PortRule{},
		PortMap:  make(map[int][]string),
	}

	// Check if directory exists
	if _, err := os.Stat(dir); os.IsNotExist(err) {
		// No ports directory - return empty config (valid state)
		return config, nil
	}

	// Read all .conf files in directory
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("failed to read ports directory: %w", err)
	}

	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		if !strings.HasSuffix(entry.Name(), ".conf") {
			continue
		}

		filePath := filepath.Join(dir, entry.Name())
		if err := loadPortFile(filePath, config); err != nil {
			fmt.Fprintf(os.Stderr, "Warning: Failed to load port file %s: %v\n", entry.Name(), err)
			continue
		}
	}

	// Deduplicate ports
	config.deduplicatePorts()

	return config, nil
}

// LoadPortsFromFile loads port rules from a single configuration file
func LoadPortsFromFile(filePath string) (*PortConfig, error) {
	config := &PortConfig{
		TCPPorts: []int{},
		UDPPorts: []int{},
		AllRules: []PortRule{},
		PortMap:  make(map[int][]string),
	}

	if err := loadPortFile(filePath, config); err != nil {
		return nil, err
	}

	config.deduplicatePorts()
	return config, nil
}

// loadPortFile loads ports from a single file into the config
func loadPortFile(filePath string, config *PortConfig) error {
	file, err := os.Open(filePath)
	if err != nil {
		return err
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	lineNum := 0

	for scanner.Scan() {
		lineNum++
		line := strings.TrimSpace(scanner.Text())

		// Skip empty lines and comments
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		// Skip INI section headers like [ports], [description]
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			continue
		}

		// Handle inline comments
		if idx := strings.Index(line, "#"); idx >= 0 {
			line = strings.TrimSpace(line[:idx])
		}

		// Skip lines that don't start with a digit (port numbers always start with digits)
		// This handles [description] section fields like "name = ...", "priority = ..."
		if len(line) == 0 || (line[0] < '0' || line[0] > '9') {
			// Warn about non-port lines that aren't obvious metadata (helps catch INI-format mistakes)
			fmt.Fprintf(os.Stderr, "Warning: Skipping non-port line at %s:%d: %s\n", filePath, lineNum, line)
			continue
		}

		// Handle INI-style format: "22/tcp = input" -> extract "22/tcp"
		// Also handles simple format: "22/T"
		if idx := strings.Index(line, "="); idx >= 0 {
			line = strings.TrimSpace(line[:idx])
		}

		// Parse format: PORT/PROTOCOL or PORT|PROTOCOL
		// Examples: 22/T, 53/B, 80/T, 22/tcp, 53/udp, 10051|T, 10050|B
		var parts []string
		if strings.Contains(line, "|") {
			parts = strings.Split(line, "|")
		} else {
			parts = strings.Split(line, "/")
		}
		if len(parts) < 2 || len(parts) > 3 {
			fmt.Fprintf(os.Stderr, "Warning: Invalid port format at %s:%d: %s (expected PORT/PROTOCOL or PORT/PROTOCOL/DIRECTION)\n",
				filePath, lineNum, line)
			continue
		}

		portStr := strings.TrimSpace(parts[0])
		protocolRaw := strings.ToLower(strings.TrimSpace(parts[1]))

		// Normalize protocol names: tcp->T, udp->U, both->B
		var protocol string
		switch protocolRaw {
		case "t", "tcp":
			protocol = "T"
		case "u", "udp":
			protocol = "U"
		case "b", "both":
			protocol = "B"
		default:
			fmt.Fprintf(os.Stderr, "Warning: Invalid protocol at %s:%d: %s (expected T/tcp, U/udp, or B/both)\n",
				filePath, lineNum, protocolRaw)
			continue
		}

		// Parse direction if provided (3rd part), default to "I" (input)
		direction := "I"
		if len(parts) >= 3 {
			dirRaw := strings.ToUpper(strings.TrimSpace(parts[2]))
			switch dirRaw {
			case "I", "IN", "INPUT":
				direction = "I"
			case "O", "OUT", "OUTPUT":
				direction = "O"
			case "IO", "INOUT", "BOTH":
				direction = "IO"
			default:
				fmt.Fprintf(os.Stderr, "Warning: Invalid direction at %s:%d: %s (expected I, O, or IO)\n",
					filePath, lineNum, dirRaw)
				continue
			}
		}

		// Check for port range (e.g., 35000-35999/T)
		if strings.Contains(portStr, "-") {
			// Port ranges not supported yet - skip with warning
			fmt.Fprintf(os.Stderr, "Warning: Port ranges not yet supported at %s:%d: %s\n",
				filePath, lineNum, line)
			continue
		}

		// Parse port number
		port, err := strconv.Atoi(portStr)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Warning: Invalid port number at %s:%d: %s\n",
				filePath, lineNum, portStr)
			continue
		}

		// Validate port range
		if port < 1 || port > 65535 {
			fmt.Fprintf(os.Stderr, "Warning: Port out of range (1-65535) at %s:%d: %d\n",
				filePath, lineNum, port)
			continue
		}

		// Protocol already validated and normalized in switch above

		// Create rule
		rule := PortRule{
			Port:      port,
			Protocol:  protocol,
			Direction: direction,
			Source:    filePath,
		}
		config.AllRules = append(config.AllRules, rule)

		// Add to port map for deduplication tracking
		config.PortMap[port] = append(config.PortMap[port], protocol)
	}

	if err := scanner.Err(); err != nil {
		return fmt.Errorf("error reading file: %w", err)
	}

	return nil
}

// deduplicatePorts processes all rules and creates deduplicated TCP/UDP port lists
func (c *PortConfig) deduplicatePorts() {
	tcpSet := make(map[int]bool)
	udpSet := make(map[int]bool)
	tcpInSet := make(map[int]bool)
	tcpOutSet := make(map[int]bool)
	udpInSet := make(map[int]bool)
	udpOutSet := make(map[int]bool)

	for _, rule := range c.AllRules {
		// Add to general TCP/UDP sets (backwards compatibility)
		switch rule.Protocol {
		case "T": // TCP only
			tcpSet[rule.Port] = true
		case "U": // UDP only
			udpSet[rule.Port] = true
		case "B": // Both TCP and UDP
			tcpSet[rule.Port] = true
			udpSet[rule.Port] = true
		}

		// Add to directional sets based on Direction field
		switch rule.Direction {
		case "I": // Input only
			switch rule.Protocol {
			case "T":
				tcpInSet[rule.Port] = true
			case "U":
				udpInSet[rule.Port] = true
			case "B":
				tcpInSet[rule.Port] = true
				udpInSet[rule.Port] = true
			}
		case "O": // Output only
			switch rule.Protocol {
			case "T":
				tcpOutSet[rule.Port] = true
			case "U":
				udpOutSet[rule.Port] = true
			case "B":
				tcpOutSet[rule.Port] = true
				udpOutSet[rule.Port] = true
			}
		case "IO": // Both directions
			switch rule.Protocol {
			case "T":
				tcpInSet[rule.Port] = true
				tcpOutSet[rule.Port] = true
			case "U":
				udpInSet[rule.Port] = true
				udpOutSet[rule.Port] = true
			case "B":
				tcpInSet[rule.Port] = true
				tcpOutSet[rule.Port] = true
				udpInSet[rule.Port] = true
				udpOutSet[rule.Port] = true
			}
		}
	}

	// Convert sets to slices (general ports for backwards compatibility)
	for port := range tcpSet {
		c.TCPPorts = append(c.TCPPorts, port)
	}
	for port := range udpSet {
		c.UDPPorts = append(c.UDPPorts, port)
	}

	// Convert directional sets to slices
	for port := range tcpInSet {
		c.TCPPortsIn = append(c.TCPPortsIn, port)
	}
	for port := range tcpOutSet {
		c.TCPPortsOut = append(c.TCPPortsOut, port)
	}
	for port := range udpInSet {
		c.UDPPortsIn = append(c.UDPPortsIn, port)
	}
	for port := range udpOutSet {
		c.UDPPortsOut = append(c.UDPPortsOut, port)
	}
}

// GetTCPPorts returns all TCP ports (from T and B rules)
func (c *PortConfig) GetTCPPorts() []int {
	return c.TCPPorts
}

// GetUDPPorts returns all UDP ports (from U and B rules)
func (c *PortConfig) GetUDPPorts() []int {
	return c.UDPPorts
}

// GetAllPorts returns all unique ports regardless of protocol
func (c *PortConfig) GetAllPorts() []int {
	portSet := make(map[int]bool)
	for _, port := range c.TCPPorts {
		portSet[port] = true
	}
	for _, port := range c.UDPPorts {
		portSet[port] = true
	}

	var ports []int
	for port := range portSet {
		ports = append(ports, port)
	}
	return ports
}

// AddPortToFile adds a port rule to a configuration file
func AddPortToFile(filePath string, port int, protocol string) error {
	// Validate inputs
	if port < 1 || port > 65535 {
		return fmt.Errorf("port out of range (1-65535): %d", port)
	}

	protocol = strings.ToUpper(protocol)
	if protocol != "T" && protocol != "U" && protocol != "B" {
		return fmt.Errorf("invalid protocol: %s (expected T, U, or B)", protocol)
	}

	// Check if port already exists
	if util.FileExists(filePath) {
		existing, err := LoadPortsFromFile(filePath)
		if err != nil {
			return fmt.Errorf("failed to check existing ports: %w", err)
		}

		// Check if this exact rule already exists
		for _, rule := range existing.AllRules {
			if rule.Port == port && rule.Protocol == protocol {
				return nil // Already exists, nothing to do
			}
		}
	}

	// Open file for appending
	f, err := os.OpenFile(filePath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0640)
	if err != nil {
		return fmt.Errorf("failed to open file: %w", err)
	}
	defer f.Close()

	// Write port rule
	_, err = fmt.Fprintf(f, "%d/%s\n", port, protocol)
	if err != nil {
		return fmt.Errorf("failed to write port rule: %w", err)
	}

	return nil
}

// RemovePortFromFile removes a port rule from a configuration file
func RemovePortFromFile(filePath string, port int) error {
	if !util.FileExists(filePath) {
		return fmt.Errorf("file does not exist: %s", filePath)
	}

	// Read entire file
	content, err := os.ReadFile(filePath)
	if err != nil {
		return fmt.Errorf("failed to read file: %w", err)
	}

	// Filter out lines matching this port
	lines := strings.Split(string(content), "\n")
	var newLines []string
	portStr := fmt.Sprintf("%d/", port)

	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		// Keep line if it doesn't start with this port number
		if !strings.HasPrefix(trimmed, portStr) {
			newLines = append(newLines, line)
		}
	}

	// Write back
	newContent := strings.Join(newLines, "\n")
	if err := os.WriteFile(filePath, []byte(newContent), 0640); err != nil {
		return fmt.Errorf("failed to write file: %w", err)
	}

	return nil
}

