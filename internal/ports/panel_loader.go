// =============================================================================
// NFTBan - Control Panel Port Loader
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="panel_loader"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Loads port configurations for control panels (DirectAdmin, cPanel, Plesk)"
// meta:input="Panel configuration files"
// meta:output="Panel port rules"
// meta:depends="bufio,os"
// meta:inventory.files="/var/lib/nftban/panels/enabled.conf"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/ports.d/panel-*.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package ports

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/itcmsgr/nftban/internal/safety"
)

// PanelConfig represents a control panel's port configuration
type PanelConfig struct {
	Name      string   // Panel name (directadmin, cpanel, plesk)
	Enabled   bool     // Whether panel is enabled
	ConfigFile string  // Path to panel config file
	TCPIn     []int    // TCP input ports
	TCPOut    []int    // TCP output ports (for OUTPUT chain)
	UDPIn     []int    // UDP input ports
	UDPOut    []int    // UDP output ports (for OUTPUT chain)
}

// PanelStateFile location
const PanelStateFile = "/var/lib/nftban/panels/enabled.conf"

// LoadEnabledPanels reads the panel state file and returns enabled panel names
func LoadEnabledPanels() ([]string, error) {
	var enabled []string

	// If state file doesn't exist, return empty list (no panels enabled)
	if _, err := os.Stat(PanelStateFile); os.IsNotExist(err) {
		return enabled, nil
	}

	file, err := os.Open(PanelStateFile)
	if err != nil {
		return nil, fmt.Errorf("failed to open panel state file: %w", err)
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())

		// Skip empty lines and comments
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		// Parse format: panelname=enabled or panelname=disabled
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}

		panelName := strings.TrimSpace(parts[0])
		status := strings.TrimSpace(parts[1])

		if strings.ToLower(status) == "enabled" {
			enabled = append(enabled, panelName)
		}
	}

	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("error reading panel state file: %w", err)
	}

	return enabled, nil
}

// SetPanelEnabled updates the panel state file to enable/disable a panel
func SetPanelEnabled(panelName string, enabled bool) error {
	// Ensure state directory exists
	stateDir := filepath.Dir(PanelStateFile)
	if err := os.MkdirAll(stateDir, 0755); err != nil {
		return fmt.Errorf("failed to create state directory: %w", err)
	}

	// Read existing state
	existingState := make(map[string]string)
	if _, err := os.Stat(PanelStateFile); err == nil {
		file, err := os.Open(PanelStateFile)
		if err != nil {
			return fmt.Errorf("failed to open panel state file: %w", err)
		}
		defer file.Close()

		scanner := bufio.NewScanner(file)
		for scanner.Scan() {
			line := strings.TrimSpace(scanner.Text())
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}

			parts := strings.SplitN(line, "=", 2)
			if len(parts) == 2 {
				existingState[strings.TrimSpace(parts[0])] = strings.TrimSpace(parts[1])
			}
		}

		if err := scanner.Err(); err != nil {
			return fmt.Errorf("error reading panel state file: %w", err)
		}
	}

	// Update state
	status := "disabled"
	if enabled {
		status = "enabled"
	}
	existingState[panelName] = status

	// Write back. v1.171 §4.3d: build the body then atomic-write (temp+fsync+
	// rename, random temp) via the gold helper — torn-on-crash safe and parity
	// with the shell sibling's temp+mv — instead of streaming into os.Create.
	// Byte-for-byte the same content as the previous Fprintln/Fprintf stream.
	var sb strings.Builder
	sb.WriteString("# NFTBan Panel State Configuration\n")
	sb.WriteString("# Format: panelname=enabled|disabled\n")
	sb.WriteString("# This file is automatically managed by 'nftban panel' commands\n")
	sb.WriteString("\n")

	// Write all panels in alphabetical order
	panels := []string{"directadmin", "cpanel", "plesk", "cyberpanel", "cwp", "interworx", "vesta"}
	for _, panel := range panels {
		if state, exists := existingState[panel]; exists {
			fmt.Fprintf(&sb, "%s=%s\n", panel, state)
		}
	}

	if err := safety.SafeWriteFile(PanelStateFile, []byte(sb.String()), 0644); err != nil {
		return fmt.Errorf("failed to write panel state file: %w", err)
	}

	return nil
}

// LoadPanelConfig loads port configuration for a specific panel by reading its bash config file
func LoadPanelConfig(configDir, panelName string) (*PanelConfig, error) {
	panelConfigPath := filepath.Join(configDir, "conf.d", "panels", panelName, "main.conf")

	// Check if config file exists
	if _, err := os.Stat(panelConfigPath); os.IsNotExist(err) {
		return nil, fmt.Errorf("panel config not found: %s", panelConfigPath)
	}

	// Parse bash config file to extract port variables
	// We use bash to source the file and output the variables
	config := &PanelConfig{
		Name:       panelName,
		Enabled:    true,
		ConfigFile: panelConfigPath,
		TCPIn:      []int{},
		TCPOut:     []int{},
		UDPIn:      []int{},
		UDPOut:     []int{},
	}

	// Uppercase panel name for variable prefix
	panelUpper := strings.ToUpper(panelName)

	// Variable names to extract
	varNames := map[string]*[]int{
		fmt.Sprintf("NFTBAN_%s_TCP_IN", panelUpper):  &config.TCPIn,
		fmt.Sprintf("NFTBAN_%s_TCP_OUT", panelUpper): &config.TCPOut,
		fmt.Sprintf("NFTBAN_%s_UDP_IN", panelUpper):  &config.UDPIn,
		fmt.Sprintf("NFTBAN_%s_UDP_OUT", panelUpper): &config.UDPOut,
	}

	// Extract each variable using bash
	for varName, portList := range varNames {
		// VULN-20: quote path via $1 to prevent injection
		bashCmd := fmt.Sprintf("source \"$1\" && echo \"${%s:-}\"", varName)
		cmd := exec.Command("bash", "-c", bashCmd, "_", panelConfigPath)
		output, err := cmd.Output()
		if err != nil {
			// Variable might not be defined - that's OK, skip it
			continue
		}

		portString := strings.TrimSpace(string(output))
		if portString == "" {
			continue
		}

		// Parse comma-separated port list (may contain ranges)
		ports, err := parsePortList(portString)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Warning: Failed to parse %s: %v\n", varName, err)
			continue
		}

		*portList = ports
	}

	return config, nil
}

// LoadAllPanelPorts loads port configuration for all enabled panels
func LoadAllPanelPorts(configDir string) (*PortConfig, error) {
	combined := &PortConfig{
		TCPPorts: []int{},
		UDPPorts: []int{},
		AllRules: []PortRule{},
		PortMap:  make(map[int][]string),
	}

	// Get enabled panels
	enabledPanels, err := LoadEnabledPanels()
	if err != nil {
		return nil, fmt.Errorf("failed to load enabled panels: %w", err)
	}

	if len(enabledPanels) == 0 {
		// No panels enabled - return empty config
		return combined, nil
	}

	// Load each enabled panel's config
	for _, panelName := range enabledPanels {
		panelCfg, err := LoadPanelConfig(configDir, panelName)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Warning: Failed to load panel config for %s: %v\n", panelName, err)
			continue
		}

		// Add TCP IN ports (input chain)
		for _, port := range panelCfg.TCPIn {
			rule := PortRule{
				Port:      port,
				Protocol:  "T",
				Direction: "I",
				Source:    fmt.Sprintf("panel:%s", panelName),
			}
			combined.AllRules = append(combined.AllRules, rule)
			combined.PortMap[port] = append(combined.PortMap[port], "T")
		}

		// Add TCP OUT ports (output chain) - v1.18.2: Full bidirectional support
		for _, port := range panelCfg.TCPOut {
			rule := PortRule{
				Port:      port,
				Protocol:  "T",
				Direction: "O",
				Source:    fmt.Sprintf("panel:%s", panelName),
			}
			combined.AllRules = append(combined.AllRules, rule)
			combined.PortMap[port] = append(combined.PortMap[port], "T")
		}

		// Add UDP IN ports (input chain)
		for _, port := range panelCfg.UDPIn {
			rule := PortRule{
				Port:      port,
				Protocol:  "U",
				Direction: "I",
				Source:    fmt.Sprintf("panel:%s", panelName),
			}
			combined.AllRules = append(combined.AllRules, rule)
			combined.PortMap[port] = append(combined.PortMap[port], "U")
		}

		// Add UDP OUT ports (output chain) - v1.18.2: Full bidirectional support
		for _, port := range panelCfg.UDPOut {
			rule := PortRule{
				Port:      port,
				Protocol:  "U",
				Direction: "O",
				Source:    fmt.Sprintf("panel:%s", panelName),
			}
			combined.AllRules = append(combined.AllRules, rule)
			combined.PortMap[port] = append(combined.PortMap[port], "U")
		}
	}

	// Deduplicate
	combined.deduplicatePorts()

	return combined, nil
}

// parsePortList parses a comma-separated port list (may contain ranges)
// Examples: "22,80,443", "20,21,22,35000-35999"
func parsePortList(portString string) ([]int, error) {
	var ports []int

	parts := strings.Split(portString, ",")
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}

		// Check for range (e.g., "35000-35999")
		if strings.Contains(part, "-") {
			rangeParts := strings.SplitN(part, "-", 2)
			if len(rangeParts) != 2 {
				return nil, fmt.Errorf("invalid port range: %s", part)
			}

			start, err := strconv.Atoi(strings.TrimSpace(rangeParts[0]))
			if err != nil {
				return nil, fmt.Errorf("invalid port range start: %s", rangeParts[0])
			}

			end, err := strconv.Atoi(strings.TrimSpace(rangeParts[1]))
			if err != nil {
				return nil, fmt.Errorf("invalid port range end: %s", rangeParts[1])
			}

			// Validate range
			if start < 1 || start > 65535 || end < 1 || end > 65535 {
				return nil, fmt.Errorf("port range out of bounds (1-65535): %s", part)
			}
			if start > end {
				return nil, fmt.Errorf("invalid port range (start > end): %s", part)
			}

			// Expand range (but limit to prevent DoS)
			rangeSize := end - start + 1
			if rangeSize > 10000 {
				return nil, fmt.Errorf("port range too large (>10000 ports): %s", part)
			}

			for p := start; p <= end; p++ {
				ports = append(ports, p)
			}
		} else {
			// Single port
			port, err := strconv.Atoi(part)
			if err != nil {
				return nil, fmt.Errorf("invalid port number: %s", part)
			}

			if port < 1 || port > 65535 {
				return nil, fmt.Errorf("port out of range (1-65535): %d", port)
			}

			ports = append(ports, port)
		}
	}

	return ports, nil
}

// LoadAllPorts loads ports from BOTH ports.d/ directory AND enabled panel configs
func LoadAllPorts(configDir string) (*PortConfig, error) {
	// Load custom ports from ports.d/
	portsDir := filepath.Join(configDir, "ports.d")
	customPorts, err := LoadPortsFromDirectory(portsDir)
	if err != nil {
		return nil, fmt.Errorf("failed to load custom ports: %w", err)
	}

	// Load panel ports from enabled panels
	panelPorts, err := LoadAllPanelPorts(configDir)
	if err != nil {
		return nil, fmt.Errorf("failed to load panel ports: %w", err)
	}

	// Merge both sources
	combined := &PortConfig{
		TCPPorts: []int{},
		UDPPorts: []int{},
		AllRules: []PortRule{},
		PortMap:  make(map[int][]string),
	}

	// Add custom ports
	combined.AllRules = append(combined.AllRules, customPorts.AllRules...)
	for port, protocols := range customPorts.PortMap {
		combined.PortMap[port] = append(combined.PortMap[port], protocols...)
	}

	// Add panel ports
	combined.AllRules = append(combined.AllRules, panelPorts.AllRules...)
	for port, protocols := range panelPorts.PortMap {
		combined.PortMap[port] = append(combined.PortMap[port], protocols...)
	}

	// Deduplicate
	combined.deduplicatePorts()

	return combined, nil
}
