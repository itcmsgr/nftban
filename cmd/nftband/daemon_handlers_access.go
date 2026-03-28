// =============================================================================
// NFTBan v1.41.0 - nftband Daemon - Per-IP port access handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftband"
// meta:type="cmd"
// meta:version="1.41.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Per-IP port access IPC handlers (concat set management)"
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
	"time"

	"github.com/google/nftables"
	"github.com/itcmsgr/nftban/internal/metrics"
)

// handleAccessAllowRequest grants per-IP port access via concat sets
// Params: ip (string), port (int), protocol (tcp|udp), timeout (int seconds, 0=permanent)
func (d *Daemon) handleAccessAllowRequest(params map[string]any) SocketResponse {
	ip, _ := params["ip"].(string)
	if ip == "" {
		return SocketResponse{Success: false, Error: "missing ip parameter"}
	}

	portFloat, ok := params["port"].(float64)
	if !ok || portFloat < 1 || portFloat > 65535 {
		return SocketResponse{Success: false, Error: "invalid port parameter (must be 1-65535)"}
	}
	port := int(portFloat)

	protocol, _ := params["protocol"].(string)
	if protocol == "" {
		protocol = "tcp"
	}
	protocol = strings.ToLower(protocol)
	if protocol != "tcp" && protocol != "udp" {
		return SocketResponse{Success: false, Error: "invalid protocol (must be tcp or udp)"}
	}

	timeoutFloat, _ := params["timeout"].(float64)
	timeout := time.Duration(int(timeoutFloat)) * time.Second

	// Determine IP family
	isIPv4 := !strings.Contains(ip, ":")

	nft := d.backend.GetNFTManager()
	if nft == nil {
		return SocketResponse{Success: false, Error: "nftables backend not initialized"}
	}

	// Select the correct concat set
	var setName string
	var family nftables.TableFamily
	if isIPv4 {
		family = nftables.TableFamilyIPv4
		if protocol == "tcp" {
			setName = "port_allow_tcp_ipv4"
		} else {
			setName = "port_allow_udp_ipv4"
		}
	} else {
		family = nftables.TableFamilyIPv6
		if protocol == "tcp" {
			setName = "port_allow_tcp_ipv6"
		} else {
			setName = "port_allow_udp_ipv6"
		}
	}

	table, err := nft.GetOrCreateTable(family)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to get table: " + err.Error()}
	}

	set, err := nft.GetOrCreateConcatSet(table, setName, isIPv4)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to get concat set: " + err.Error()}
	}

	if err := nft.AddConcatIPPort(set, ip, port, timeout); err != nil {
		return SocketResponse{Success: false, Error: "failed to add access rule: " + err.Error()}
	}

	familyLabel := "ipv4"
	if !isIPv4 {
		familyLabel = "ipv6"
	}
	log.Printf("[ACCESS] Allowed %s port %d/%s for %s (timeout=%v)", familyLabel, port, protocol, ip, timeout)
	metrics.RecordIPCRequest("access_allow", true, 0)

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"ip":       ip,
			"port":     port,
			"protocol": protocol,
			"timeout":  int(timeoutFloat),
			"family":   familyLabel,
			"set":      setName,
		},
	}
}

// handleAccessRevokeRequest revokes per-IP port access from concat sets
// Params: ip (string), port (int), protocol (tcp|udp)
func (d *Daemon) handleAccessRevokeRequest(params map[string]any) SocketResponse {
	ip, _ := params["ip"].(string)
	if ip == "" {
		return SocketResponse{Success: false, Error: "missing ip parameter"}
	}

	portFloat, ok := params["port"].(float64)
	if !ok || portFloat < 1 || portFloat > 65535 {
		return SocketResponse{Success: false, Error: fmt.Sprintf("invalid port parameter: %v", params["port"])}
	}
	port := int(portFloat)

	protocol, _ := params["protocol"].(string)
	if protocol == "" {
		protocol = "tcp"
	}
	protocol = strings.ToLower(protocol)
	if protocol != "tcp" && protocol != "udp" {
		return SocketResponse{Success: false, Error: "invalid protocol (must be tcp or udp)"}
	}

	isIPv4 := !strings.Contains(ip, ":")

	nft := d.backend.GetNFTManager()
	if nft == nil {
		return SocketResponse{Success: false, Error: "nftables backend not initialized"}
	}

	var setName string
	var family nftables.TableFamily
	if isIPv4 {
		family = nftables.TableFamilyIPv4
		if protocol == "tcp" {
			setName = "port_allow_tcp_ipv4"
		} else {
			setName = "port_allow_udp_ipv4"
		}
	} else {
		family = nftables.TableFamilyIPv6
		if protocol == "tcp" {
			setName = "port_allow_tcp_ipv6"
		} else {
			setName = "port_allow_udp_ipv6"
		}
	}

	table, err := nft.GetOrCreateTable(family)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to get table: " + err.Error()}
	}

	set, err := nft.GetOrCreateConcatSet(table, setName, isIPv4)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to get concat set: " + err.Error()}
	}

	if err := nft.DeleteConcatIPPort(set, ip, port); err != nil {
		return SocketResponse{Success: false, Error: "failed to revoke access: " + err.Error()}
	}

	familyLabel := "ipv4"
	if !isIPv4 {
		familyLabel = "ipv6"
	}
	log.Printf("[ACCESS] Revoked %s port %d/%s from %s", familyLabel, port, protocol, ip)
	metrics.RecordIPCRequest("access_revoke", true, 0)

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"ip":       ip,
			"port":     port,
			"protocol": protocol,
			"family":   familyLabel,
			"set":      setName,
		},
	}
}
