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
// meta:inventory.network="9580/tcp (HTTP API), /run/nftban/nftband.sock (Unix)"
// meta:inventory.privileges="root"
// =============================================================================

package main

import (
	"fmt"
	"log"
	"path/filepath"
	"strings"

	"github.com/itcmsgr/nftban/internal/nftbackend"
	"github.com/itcmsgr/nftban/internal/persistence"
	"github.com/itcmsgr/nftban/internal/rulefp"
	"github.com/itcmsgr/nftban/internal/safety"
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

	// L3a — never-ban invariant on the generic add path (handler-level reject for clear
	// operator/API feedback). The backend enforces the same as defense-in-depth, so this
	// is a UX layer, not the sole guard. Enforcement sets + single exempt IP only.
	if nftbackend.IsEnforcementSet(set) {
		if exempt, reason := d.backend.IsExempt(element); exempt {
			log.Printf("[ADD_ELEMENT] REFUSED (never-ban exempt: %s) set=%s ip=%s — protected IP NOT added to enforcement set", reason, set, element)
			return SocketResponse{Success: false, Error: fmt.Sprintf("refused: never-ban exempt (%s) — %s not added to enforcement set %s", reason, element, set)}
		}
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

	// SEC-RULEFP (v1.138): on a trusted successful apply (NOT a dry-run --check),
	// (re)capture the ruleset fingerprint baseline. Capture failure is logged but
	// MUST NOT fail the apply nor corrupt active firewall state — the ruleset is
	// already applied; verify-rules would just report BASELINE_MISSING until the
	// next successful capture. Never captured on a verify path (no self-heal).
	if !check {
		if cerr := rulefp.CaptureLive(d.ctx, rulefp.BaselineFile); cerr != nil {
			log.Printf("[RULEFP] baseline capture after apply failed (non-fatal): %v", cerr)
		}
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
