// =============================================================================
// NFTBan v1.0 - nftband Daemon - Port element management handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftband"
// meta:type="cmd"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Port element management handlers"
//
// meta:inventory.files="/usr/lib/nftban/bin/nftband"
// meta:inventory.binaries="nftband"
// meta:inventory.env_vars="NFTBAN_CONFIG_DIR, NFTBAN_LOG_DIR"
// meta:inventory.config_files="/etc/nftban/nftban.conf"
// meta:inventory.systemd_units="nftband.service, nftband.socket"
// meta:inventory.network="8080/tcp (HTTP API), /run/nftban/nftband.sock (Unix)"
// meta:inventory.privileges="root"
// =============================================================================

package main

import (
	"fmt"
	"log"
	"strings"

	"github.com/google/nftables"
	"github.com/itcmsgr/nftban/pkg/ports"
)

// handleLoadPortsRequest loads ports into nftables port sets
func (d *Daemon) handleLoadPortsRequest(params map[string]any) SocketResponse {
	_, configDir, _, _ := getDaemonPaths()
	portsDir := configDir + "/ports.d"

	// Load port configuration
	config, err := ports.LoadPortsFromDirectory(portsDir)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to load ports: " + err.Error()}
	}

	if len(config.AllRules) == 0 {
		return SocketResponse{
			Success: true,
			Data: map[string]any{
				"message":       "no port rules configured",
				"tcp_ports_in":  0,
				"tcp_ports_out": 0,
				"udp_ports_in":  0,
				"udp_ports_out": 0,
			},
		}
	}

	// Use backend's shared nftables manager
	nft := d.backend.GetNFTManager()
	if nft == nil {
		return SocketResponse{Success: false, Error: "nftables backend not initialized"}
	}

	// Create IPv4 table and sets
	ipv4Table, err := nft.GetOrCreateTable(nftables.TableFamilyIPv4)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to get IPv4 table: " + err.Error()}
	}

	// Directional port sets for IPv4 (v2.1 schema - NO legacy sets)
	tcpInSetV4, err := nft.GetOrCreatePortSet(ipv4Table, "tcp_ports_in")
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to create IPv4 tcp_ports_in set: " + err.Error()}
	}
	tcpOutSetV4, err := nft.GetOrCreatePortSet(ipv4Table, "tcp_ports_out")
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to create IPv4 tcp_ports_out set: " + err.Error()}
	}
	udpInSetV4, err := nft.GetOrCreatePortSet(ipv4Table, "udp_ports_in")
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to create IPv4 udp_ports_in set: " + err.Error()}
	}
	udpOutSetV4, err := nft.GetOrCreatePortSet(ipv4Table, "udp_ports_out")
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to create IPv4 udp_ports_out set: " + err.Error()}
	}

	// Create IPv6 table and sets
	ipv6Table, err := nft.GetOrCreateTable(nftables.TableFamilyIPv6)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to get IPv6 table: " + err.Error()}
	}

	// Directional port sets for IPv6 (v2.1 schema - NO legacy sets)
	tcpInSetV6, err := nft.GetOrCreatePortSet(ipv6Table, "tcp_ports_in")
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to create IPv6 tcp_ports_in set: " + err.Error()}
	}
	tcpOutSetV6, err := nft.GetOrCreatePortSet(ipv6Table, "tcp_ports_out")
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to create IPv6 tcp_ports_out set: " + err.Error()}
	}
	udpInSetV6, err := nft.GetOrCreatePortSet(ipv6Table, "udp_ports_in")
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to create IPv6 udp_ports_in set: " + err.Error()}
	}
	udpOutSetV6, err := nft.GetOrCreatePortSet(ipv6Table, "udp_ports_out")
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to create IPv6 udp_ports_out set: " + err.Error()}
	}

	// IMPORTANT: Flush all port sets first for idempotent reload
	// This ensures removed ports in config are also removed from nftables
	allPortSets := []*nftables.Set{
		tcpInSetV4, tcpOutSetV4, udpInSetV4, udpOutSetV4,
		tcpInSetV6, tcpOutSetV6, udpInSetV6, udpOutSetV6,
	}
	for _, set := range allPortSets {
		if err := nft.FlushSet(set); err != nil {
			log.Printf("[load_ports] Warning: failed to flush set %s: %v", set.Name, err)
			// Continue anyway - set might be empty
		}
	}

	// Load directional port sets (v2.1 schema)
	if len(config.TCPPortsIn) > 0 {
		if err := nft.AddPortElements(tcpInSetV4, config.TCPPortsIn); err != nil {
			return SocketResponse{Success: false, Error: "failed to add IPv4 TCP input ports: " + err.Error()}
		}
		if err := nft.AddPortElements(tcpInSetV6, config.TCPPortsIn); err != nil {
			return SocketResponse{Success: false, Error: "failed to add IPv6 TCP input ports: " + err.Error()}
		}
	}
	if len(config.TCPPortsOut) > 0 {
		if err := nft.AddPortElements(tcpOutSetV4, config.TCPPortsOut); err != nil {
			return SocketResponse{Success: false, Error: "failed to add IPv4 TCP output ports: " + err.Error()}
		}
		if err := nft.AddPortElements(tcpOutSetV6, config.TCPPortsOut); err != nil {
			return SocketResponse{Success: false, Error: "failed to add IPv6 TCP output ports: " + err.Error()}
		}
	}
	if len(config.UDPPortsIn) > 0 {
		if err := nft.AddPortElements(udpInSetV4, config.UDPPortsIn); err != nil {
			return SocketResponse{Success: false, Error: "failed to add IPv4 UDP input ports: " + err.Error()}
		}
		if err := nft.AddPortElements(udpInSetV6, config.UDPPortsIn); err != nil {
			return SocketResponse{Success: false, Error: "failed to add IPv6 UDP input ports: " + err.Error()}
		}
	}
	if len(config.UDPPortsOut) > 0 {
		if err := nft.AddPortElements(udpOutSetV4, config.UDPPortsOut); err != nil {
			return SocketResponse{Success: false, Error: "failed to add IPv4 UDP output ports: " + err.Error()}
		}
		if err := nft.AddPortElements(udpOutSetV6, config.UDPPortsOut); err != nil {
			return SocketResponse{Success: false, Error: "failed to add IPv6 UDP output ports: " + err.Error()}
		}
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"tcp_ports_in":  len(config.TCPPortsIn),
			"tcp_ports_out": len(config.TCPPortsOut),
			"udp_ports_in":  len(config.UDPPortsIn),
			"udp_ports_out": len(config.UDPPortsOut),
			"total":         len(config.AllRules),
		},
	}
}

// handleAddPortElementRequest atomically adds port(s) to nftables sets
// Params: ports ([]int), protocol (tcp/udp/both), direction (in/out/both)
func (d *Daemon) handleAddPortElementRequest(params map[string]any) SocketResponse {
	// Parse ports list
	portsRaw, ok := params["ports"].([]any)
	if !ok || len(portsRaw) == 0 {
		// Try single port
		if port, ok := params["port"].(float64); ok {
			portsRaw = []any{port}
		} else {
			return SocketResponse{Success: false, Error: "missing ports parameter"}
		}
	}

	var portsList []int
	for _, p := range portsRaw {
		if pf, ok := p.(float64); ok {
			if pf < 1 || pf > 65535 {
				return SocketResponse{Success: false, Error: fmt.Sprintf("invalid port: %v", p)}
			}
			portsList = append(portsList, int(pf))
		}
	}

	protocol, _ := params["protocol"].(string)
	if protocol == "" {
		protocol = "tcp"
	}
	direction, _ := params["direction"].(string)
	if direction == "" {
		direction = "in"
	}

	// Use backend's shared nftables manager
	nft := d.backend.GetNFTManager()
	if nft == nil {
		return SocketResponse{Success: false, Error: "nftables backend not initialized"}
	}

	// Get tables
	ipv4Table, err := nft.GetOrCreateTable(nftables.TableFamilyIPv4)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to get IPv4 table: " + err.Error()}
	}
	ipv6Table, err := nft.GetOrCreateTable(nftables.TableFamilyIPv6)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to get IPv6 table: " + err.Error()}
	}

	// Determine which sets to update (v2.1 schema - directional only)
	var setNames []string
	switch strings.ToLower(protocol) {
	case "tcp", "t":
		switch strings.ToLower(direction) {
		case "in", "i", "input":
			setNames = []string{"tcp_ports_in"}
		case "out", "o", "output":
			setNames = []string{"tcp_ports_out"}
		case "both", "io", "b", "inout":
			setNames = []string{"tcp_ports_in", "tcp_ports_out"}
		default:
			setNames = []string{"tcp_ports_in"}
		}
	case "udp", "u":
		switch strings.ToLower(direction) {
		case "in", "i", "input":
			setNames = []string{"udp_ports_in"}
		case "out", "o", "output":
			setNames = []string{"udp_ports_out"}
		case "both", "io", "b", "inout":
			setNames = []string{"udp_ports_in", "udp_ports_out"}
		default:
			setNames = []string{"udp_ports_in"}
		}
	case "both", "b":
		switch strings.ToLower(direction) {
		case "in", "i", "input":
			setNames = []string{"tcp_ports_in", "udp_ports_in"}
		case "out", "o", "output":
			setNames = []string{"tcp_ports_out", "udp_ports_out"}
		case "both", "io", "b", "inout":
			setNames = []string{"tcp_ports_in", "tcp_ports_out", "udp_ports_in", "udp_ports_out"}
		default:
			setNames = []string{"tcp_ports_in", "udp_ports_in"}
		}
	default:
		setNames = []string{"tcp_ports_in"}
	}

	added := 0
	for _, setName := range setNames {
		// IPv4
		set, err := nft.GetOrCreatePortSet(ipv4Table, setName)
		if err != nil {
			log.Printf("[add_port_element] Warning: failed to get IPv4 set %s: %v", setName, err)
			continue
		}
		if err := nft.AddPortElements(set, portsList); err != nil {
			log.Printf("[add_port_element] Warning: failed to add to IPv4 %s: %v", setName, err)
		} else {
			added++
		}

		// IPv6
		set, err = nft.GetOrCreatePortSet(ipv6Table, setName)
		if err != nil {
			log.Printf("[add_port_element] Warning: failed to get IPv6 set %s: %v", setName, err)
			continue
		}
		if err := nft.AddPortElements(set, portsList); err != nil {
			log.Printf("[add_port_element] Warning: failed to add to IPv6 %s: %v", setName, err)
		} else {
			added++
		}
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"ports":     portsList,
			"protocol":  protocol,
			"direction": direction,
			"sets":      setNames,
			"added":     added,
		},
	}
}

// handleDeletePortElementRequest atomically removes port(s) from nftables sets
// Params: ports ([]int), protocol (tcp/udp/both), direction (in/out/both)
func (d *Daemon) handleDeletePortElementRequest(params map[string]any) SocketResponse {
	// Parse ports list
	portsRaw, ok := params["ports"].([]any)
	if !ok || len(portsRaw) == 0 {
		// Try single port
		if port, ok := params["port"].(float64); ok {
			portsRaw = []any{port}
		} else {
			return SocketResponse{Success: false, Error: "missing ports parameter"}
		}
	}

	var portsList []int
	for _, p := range portsRaw {
		if pf, ok := p.(float64); ok {
			if pf < 1 || pf > 65535 {
				return SocketResponse{Success: false, Error: fmt.Sprintf("invalid port: %v", p)}
			}
			portsList = append(portsList, int(pf))
		}
	}

	protocol, _ := params["protocol"].(string)
	if protocol == "" {
		protocol = "tcp"
	}
	direction, _ := params["direction"].(string)
	if direction == "" {
		direction = "in"
	}

	// Use backend's shared nftables manager
	nft := d.backend.GetNFTManager()
	if nft == nil {
		return SocketResponse{Success: false, Error: "nftables backend not initialized"}
	}

	// Get tables
	ipv4Table, err := nft.GetOrCreateTable(nftables.TableFamilyIPv4)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to get IPv4 table: " + err.Error()}
	}
	ipv6Table, err := nft.GetOrCreateTable(nftables.TableFamilyIPv6)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to get IPv6 table: " + err.Error()}
	}

	// Determine which sets to update (v2.1 schema - directional only)
	var setNames []string
	switch strings.ToLower(protocol) {
	case "tcp", "t":
		switch strings.ToLower(direction) {
		case "in", "i", "input":
			setNames = []string{"tcp_ports_in"}
		case "out", "o", "output":
			setNames = []string{"tcp_ports_out"}
		case "both", "io", "b", "inout":
			setNames = []string{"tcp_ports_in", "tcp_ports_out"}
		default:
			setNames = []string{"tcp_ports_in"}
		}
	case "udp", "u":
		switch strings.ToLower(direction) {
		case "in", "i", "input":
			setNames = []string{"udp_ports_in"}
		case "out", "o", "output":
			setNames = []string{"udp_ports_out"}
		case "both", "io", "b", "inout":
			setNames = []string{"udp_ports_in", "udp_ports_out"}
		default:
			setNames = []string{"udp_ports_in"}
		}
	case "both", "b":
		switch strings.ToLower(direction) {
		case "in", "i", "input":
			setNames = []string{"tcp_ports_in", "udp_ports_in"}
		case "out", "o", "output":
			setNames = []string{"tcp_ports_out", "udp_ports_out"}
		case "both", "io", "b", "inout":
			setNames = []string{"tcp_ports_in", "tcp_ports_out", "udp_ports_in", "udp_ports_out"}
		default:
			setNames = []string{"tcp_ports_in", "udp_ports_in"}
		}
	default:
		setNames = []string{"tcp_ports_in"}
	}

	deleted := 0
	for _, setName := range setNames {
		// IPv4 - use GetPortSet (not GetOrCreatePortSet) to avoid creating empty sets
		set, err := nft.GetPortSet(ipv4Table, setName)
		if err != nil {
			log.Printf("[delete_port_element] Warning: failed to get IPv4 set %s: %v", setName, err)
			continue
		}
		if set == nil {
			// Set doesn't exist - nothing to delete (idempotent)
			continue
		}
		if err := nft.DeletePortElements(set, portsList); err != nil {
			log.Printf("[delete_port_element] Warning: failed to delete from IPv4 %s: %v", setName, err)
		} else {
			deleted++
		}

		// IPv6 - use GetPortSet (not GetOrCreatePortSet) to avoid creating empty sets
		set, err = nft.GetPortSet(ipv6Table, setName)
		if err != nil {
			log.Printf("[delete_port_element] Warning: failed to get IPv6 set %s: %v", setName, err)
			continue
		}
		if set == nil {
			// Set doesn't exist - nothing to delete (idempotent)
			continue
		}
		if err := nft.DeletePortElements(set, portsList); err != nil {
			log.Printf("[delete_port_element] Warning: failed to delete from IPv6 %s: %v", setName, err)
		} else {
			deleted++
		}
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"ports":     portsList,
			"protocol":  protocol,
			"direction": direction,
			"sets":      setNames,
			"deleted":   deleted,
		},
	}
}
