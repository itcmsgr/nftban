// =============================================================================
// NFTBan v1.0 - nftband Daemon - Set element add/delete/flush handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftband"
// meta:type="cmd"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Set element add/delete/flush handlers"
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
	"log"
	"path/filepath"
	"strings"

	"github.com/itcmsgr/nftban/pkg/nftbackend"
	"github.com/itcmsgr/nftban/pkg/persistence"
	"github.com/itcmsgr/nftban/pkg/safety"
)

// handleAddElementRequest adds an element to any set
func (d *Daemon) handleAddElementRequest(params map[string]any) SocketResponse {
	table, _ := params["table"].(string)
	set, _ := params["set"].(string)
	element, _ := params["element"].(string)

	if table == "" || set == "" || element == "" {
		return SocketResponse{Success: false, Error: "missing table, set, or element parameter"}
	}
	if !validNFTBanTable(table) {
		return SocketResponse{Success: false, Error: "invalid table: must be 'ip nftban' or 'ip6 nftban'"}
	}
	if !validNFTBanSet(set) {
		return SocketResponse{Success: false, Error: "invalid set: " + set}
	}

	timeout := 0
	if t, ok := params["timeout"].(float64); ok {
		timeout = int(t)
	}

	err := d.backend.AddElement(d.ctx, nftbackend.AddElementRequest{
		Table:   table,
		Set:     set,
		Element: element,
		Timeout: timeout,
	})
	if err != nil {
		return SocketResponse{Success: false, Error: err.Error()}
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"table":   table,
			"set":     set,
			"element": element,
		},
	}
}

// handleDeleteElementRequest removes an element from any set
func (d *Daemon) handleDeleteElementRequest(params map[string]any) SocketResponse {
	table, _ := params["table"].(string)
	set, _ := params["set"].(string)
	element, _ := params["element"].(string)

	if table == "" || set == "" || element == "" {
		return SocketResponse{Success: false, Error: "missing table, set, or element parameter"}
	}
	if !validNFTBanTable(table) {
		return SocketResponse{Success: false, Error: "invalid table: must be 'ip nftban' or 'ip6 nftban'"}
	}
	if !validNFTBanSet(set) {
		return SocketResponse{Success: false, Error: "invalid set: " + set}
	}

	err := d.backend.DeleteElement(d.ctx, nftbackend.DeleteElementRequest{
		Table:   table,
		Set:     set,
		Element: element,
	})
	if err != nil {
		return SocketResponse{Success: false, Error: err.Error()}
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"table":   table,
			"set":     set,
			"element": element,
			"status":  "deleted",
		},
	}
}

// handleFlushSetRequest flushes all elements from a set
func (d *Daemon) handleFlushSetRequest(params map[string]any) SocketResponse {
	table, _ := params["table"].(string)
	set, _ := params["set"].(string)

	if table == "" || set == "" {
		return SocketResponse{Success: false, Error: "missing table or set parameter"}
	}
	if !validNFTBanTable(table) {
		return SocketResponse{Success: false, Error: "invalid table: must be 'ip nftban' or 'ip6 nftban'"}
	}
	if !validNFTBanSet(set) {
		return SocketResponse{Success: false, Error: "invalid set: " + set}
	}

	err := d.backend.FlushSet(d.ctx, nftbackend.FlushSetRequest{
		Table: table,
		Set:   set,
	})
	if err != nil {
		return SocketResponse{Success: false, Error: err.Error()}
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"table":  table,
			"set":    set,
			"status": "flushed",
		},
	}
}

// handleApplyRulesetRequest applies a ruleset from file
func (d *Daemon) handleApplyRulesetRequest(params map[string]any) SocketResponse {
	filePath, _ := params["file"].(string)
	check, _ := params["check"].(bool)

	if filePath == "" {
		return SocketResponse{Success: false, Error: "missing file parameter"}
	}

	// Security: reject path traversal attempts before any further processing
	if strings.Contains(filePath, "..") {
		return SocketResponse{Success: false, Error: "path traversal not allowed"}
	}

	// Security: restrict ruleset paths to allowed directories
	absPath := filepath.Clean(filePath)
	var err error
	absPath, err = filepath.Abs(absPath)
	if err != nil {
		return SocketResponse{Success: false, Error: "invalid file path: " + err.Error()}
	}
	// Double-check after Clean/Abs (defense-in-depth)
	if strings.Contains(absPath, "..") {
		return SocketResponse{Success: false, Error: "path traversal not allowed"}
	}
	runDir, configDir, dataDir, _ := getDaemonPaths()
	if !strings.HasPrefix(absPath, dataDir+"/") &&
		!strings.HasPrefix(absPath, configDir+"/") &&
		!strings.HasPrefix(absPath, runDir+"/") {
		return SocketResponse{Success: false, Error: "file path must be within " + dataDir + "/, " + configDir + "/, or " + runDir + "/"}
	}

	err = d.backend.ApplyRuleset(d.ctx, nftbackend.ApplyRulesetRequest{
		FilePath: absPath,
		Check:    check,
	})
	if err != nil {
		return SocketResponse{Success: false, Error: err.Error()}
	}

	action := "applied"
	if check {
		action = "validated"
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"file":   filePath,
			"status": action,
		},
	}
}

// handleCheckRequest checks if an IP is banned
func (d *Daemon) handleCheckRequest(params map[string]any) SocketResponse {
	ip, _ := params["ip"].(string)

	if ip == "" {
		return SocketResponse{Success: false, Error: "missing ip parameter"}
	}

	banned, set, err := d.backend.CheckIP(d.ctx, ip)
	if err != nil {
		return SocketResponse{Success: false, Error: err.Error()}
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"ip":     ip,
			"banned": banned,
			"set":    set,
		},
	}
}

// handlePersistBanRequest adds an IP to persistent blacklist files
func (d *Daemon) handlePersistBanRequest(params map[string]any) SocketResponse {
	ip, _ := params["ip"].(string)
	if ip == "" {
		return SocketResponse{Success: false, Error: "missing ip parameter"}
	}

	reason, _ := params["reason"].(string)
	source, _ := params["source"].(string)
	if source == "" {
		source = "manual"
	}

	// Get config directory
	_, configDir, _, _ := getDaemonPaths()

	// Persist the ban
	result, filename, err := persistence.PersistBan(configDir, ip, reason, source)
	if err != nil {
		return SocketResponse{Success: false, Error: err.Error()}
	}

	// Track permanent ban for protect/evict functionality
	// This enables 'nftban protect' and 'nftban cleanup' commands to work
	if err := safety.TrackPermanentBan(ip, reason, source, false); err != nil {
		log.Printf("[PERSIST] Warning: failed to track permanent ban for %s: %v", ip, err)
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"ip":       ip,
			"result":   string(result),
			"filename": filename,
		},
	}
}

// handleUnpersistBanRequest removes an IP from all persistent blacklist files
func (d *Daemon) handleUnpersistBanRequest(params map[string]any) SocketResponse {
	ip, _ := params["ip"].(string)
	if ip == "" {
		return SocketResponse{Success: false, Error: "missing ip parameter"}
	}

	// Get config directory
	_, configDir, _, _ := getDaemonPaths()

	// Remove from all blacklist files
	filesModified, err := persistence.UnpersistBan(configDir, ip)
	if err != nil {
		return SocketResponse{Success: false, Error: err.Error()}
	}

	// Remove from permanent ban tracking
	if err := safety.RemovePermanentBan(ip); err != nil {
		log.Printf("[UNPERSIST] Warning: failed to remove permanent ban tracking for %s: %v", ip, err)
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"ip":             ip,
			"files_modified": filesModified,
		},
	}
}
