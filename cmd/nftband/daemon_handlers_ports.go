// =============================================================================
// NFTBan v1.0 - nftband Daemon - Port element management handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
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
// meta:inventory.network="9580/tcp (HTTP API), /run/nftban/nftband.sock (Unix)"
// meta:inventory.privileges="root"
// =============================================================================

package main

import (
	"fmt"
	"log"
	"strings"

	"github.com/google/nftables"
)

// loadPortsRetiredError is the answer to the retired load_ports IPC method.
//
// v1.235 B1 (SEC-LOAD-PORTS-TRUSTS-CALLER-SUPPLIED-SSH-AUTHORITY; v1.234 plan
// L494 ruling): load_ports flushed all eight port sets and re-added only ports.d,
// with no SSH floor, so a wrong or partial ports.d removed the SSH port from the
// live firewall (lockout surface). The method stays RECOGNISED so an old client
// gets this explanation instead of "unknown method", but it no longer touches any
// set. Port sets are rendered by `nftban firewall rebuild`, which derives the SSH
// ports itself.
const loadPortsRetiredError = "load_ports is retired (v1.235): it flushed every port set and reloaded ports.d without an SSH floor. Use: nftban firewall rebuild"

// handleLoadPortsRetired refuses the retired load_ports method without side effects.
func (d *Daemon) handleLoadPortsRetired() SocketResponse {
	log.Printf("[load_ports] refused: method retired in v1.235; use 'nftban firewall rebuild'")
	return SocketResponse{Success: false, Error: loadPortsRetiredError}
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
