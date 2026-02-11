// =============================================================================
// NFTBan - Configuration API Handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="handlers_config"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-30"
// meta:description="Configuration file management API handlers"
// meta:input="HTTP requests for config operations"
// meta:output="JSON responses with config data"
// meta:depends="github.com/gorilla/mux"
// meta:inventory.files=""
// meta:inventory.binaries="nftban"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package api

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/user"
	"strconv"
	"strings"

	"github.com/gorilla/mux"
	"github.com/itcmsgr/nftban/pkg/util"
)

// getNFTBanGID returns the GID of the nftban group, with fallback
func getNFTBanGID() int {
	if group, err := user.LookupGroup("nftban"); err == nil {
		if gid, err := strconv.Atoi(group.Gid); err == nil {
			return gid
		}
	}
	return 988 // fallback to common default
}

// configAllowedModules defines valid module names for configuration operations.
// Shared across ConfigGetHandler, ConfigSetHandler, and ConfigResetHandler.
var configAllowedModules = map[string]bool{
	"main":     true,
	"firewall": true,
	"feeds":    true,
	"portscan": true,
	"ddos":     true,
	"geoip":    true,
}

// ConfigFileHandler serves configuration files from /etc/nftban/
func ConfigFileHandler(w http.ResponseWriter, r *http.Request) {
	// Extract config path from URL: /api/v1/config/{path}
	parts := strings.Split(r.URL.Path, "/")
	if len(parts) < 4 {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid config path"})
		return
	}

	// Join remaining parts to support paths like "conf.d/portscan.conf"
	configPath := strings.Join(parts[4:], "/")

	// Base directory for config files - use central config
	baseDir := getConfigDir()

	// Security: Validate config path (prevent directory traversal)
	if strings.Contains(configPath, "..") || strings.HasPrefix(configPath, "/") {
		respondJSON(w, http.StatusForbidden, ErrorResponse{Error: "Invalid config path"})
		return
	}

	// Allowed config files (whitelist)
	allowedFiles := map[string]bool{
		"nftban.conf":                          true,
		"nftban.conf.local":                    true,
		"conf.d/portscan.conf":                 true,
		"conf.d/ddos.conf":                     true,
		"conf.d/feeds.conf":                    true,
		"conf.d/geoip.conf":                    true,
		"conf.d/mail.conf":                     true,
		"conf.d/log.conf":                      true,
		"conf.d/services.conf":                 true,
		"conf.d/banner.conf":                   true,
		"conf.d/cloudflare.conf":               true,
		"conf.d/panels/directadmin/main.conf":  true,
		"conf.d/health.conf":                   true,
		"conf.d/login_alert.conf":              true,
		"conf.d/geoip/main.conf":               true,
		"conf.d/geoban/main.conf":              true,
		"conf.d/nftban-go.conf":                true, // Legacy (deprecated)
		"conf.d/recovery.conf":                 true,
		"conf.d/stats.conf":                    true,
	}

	if !allowedFiles[configPath] {
		respondJSON(w, http.StatusForbidden, ErrorResponse{Error: "Config file not allowed"})
		return
	}

	fullPath := baseDir + "/" + configPath

	// Handle GET request (read file)
	if r.Method == "GET" {
		// Check if file exists
		fileInfo, err := os.Stat(fullPath)
		if err != nil {
			if os.IsNotExist(err) {
				respondJSON(w, http.StatusNotFound, ErrorResponse{Error: "Config file not found"})
			} else {
				respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to access config file"})
			}
			return
		}

		// Read file content
		data, err := os.ReadFile(fullPath)
		if err != nil {
			respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to read config file"})
			return
		}

		// Return config content
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"content":  string(data),
			"size":     fileInfo.Size(),
			"modified": fileInfo.ModTime().Unix(),
			"path":     configPath,
		})
		return
	}

	// Handle POST request (save file)
	if r.Method == "POST" {
		// Only allow editing .local files
		if !strings.Contains(configPath, ".local") {
			respondJSON(w, http.StatusForbidden, ErrorResponse{Error: "Only .local files can be edited"})
			return
		}

		// Parse request body
		var req struct {
			Content string `json:"content"`
		}
		if !DecodeJSONBody(w, r, &req) {
			return
		}

		// Write file (create backup first if file exists)
		if _, err := os.Stat(fullPath); err == nil {
			// Create backup
			backupPath := fullPath + ".backup"
			if _, err := execCommand("cp", fullPath, backupPath); err != nil {
				log.Printf("[WARN] Failed to create backup: %v", err)
			}
		}

		// Write new content
		if err := os.WriteFile(fullPath, []byte(req.Content), 0640); err != nil {
			respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to write config file"})
			return
		}

		// Set proper ownership (nftban:nftban or root:nftban)
		if err := os.Chown(fullPath, 0, getNFTBanGID()); err != nil {
			log.Printf("[WARN] Failed to set ownership: %v", err)
		}

		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"message": "Config file saved successfully",
			"path":    configPath,
		})
		return
	}

	respondJSON(w, http.StatusMethodNotAllowed, ErrorResponse{Error: "Method not allowed"})
}

// ConfigGetHandler handles GET /api/v1/config/:module
func ConfigGetHandler(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	module := vars["module"]

	if !configAllowedModules[module] {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid module name"})
		return
	}

	// Execute nftban config get command
	output, err := execNFTBanCommand("config", "get", module, "--json")
	if err != nil {
		log.Printf("[ERROR] Failed to get config for %s: %v", module, err)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to get configuration"})
		return
	}

	// Extract JSON from CLI output (may contain non-JSON prefix/suffix)
	jsonOutput := util.ExtractJSONRobust(output)
	if jsonOutput == "" {
		log.Printf("[ERROR] No valid JSON found in config output for %s: %s", module, output)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Invalid configuration response format"})
		return
	}

	// Parse JSON response
	var configData map[string]interface{}
	if err := json.Unmarshal([]byte(jsonOutput), &configData); err != nil {
		log.Printf("[ERROR] Failed to parse config JSON for %s: %v - Output: %s", module, err, jsonOutput)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to parse configuration"})
		return
	}

	respondJSON(w, http.StatusOK, configData)
}

// ConfigSetHandler handles POST /api/v1/config/:module
func ConfigSetHandler(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	module := vars["module"]

	if !configAllowedModules[module] {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid module name"})
		return
	}

	// Parse request body - expect {"key": "value", "key2": "value2", ...}
	var updates map[string]string
	if !DecodeJSONBody(w, r, &updates) {
		return
	}

	// Apply each update
	var errors []string
	for key, value := range updates {
		keyValue := fmt.Sprintf("%s=%s", key, value)
		_, err := execNFTBanCommand("config", "set", module, keyValue)
		if err != nil {
			errors = append(errors, fmt.Sprintf("%s: %v", key, err))
		}
	}

	if len(errors) > 0 {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{
			Error: fmt.Sprintf("Failed to set some values: %s", strings.Join(errors, "; ")),
		})
		return
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": fmt.Sprintf("Configuration updated for %s", module),
		"updated": len(updates),
	})
}

// ConfigResetHandler handles POST /api/v1/config/:module/reset
func ConfigResetHandler(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	module := vars["module"]

	if !configAllowedModules[module] {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid module name"})
		return
	}

	// Parse request body - accept multiple formats:
	// 1. {"keys": ["KEY1", "KEY2"]} - array of keys
	// 2. {"key": "KEY"} - single key (from frontend)
	// 3. {"reset_all": true} or {"all": true} - reset all
	// 4. empty body - reset all
	var req struct {
		Key      string   `json:"key"`       // single key (frontend format)
		Keys     []string `json:"keys"`      // array of keys
		ResetAll bool     `json:"reset_all"` // reset all flag
		All      bool     `json:"all"`       // alternate reset all flag
	}

	// Decode body - if empty or invalid, treat as reset all
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		// Empty body means reset all
		req.ResetAll = true
	}

	// Handle single key format (convert to array)
	if req.Key != "" && len(req.Keys) == 0 {
		req.Keys = []string{req.Key}
	}

	// Check for reset all (both formats)
	resetAll := req.ResetAll || req.All || (len(req.Keys) == 0 && req.Key == "")

	// Reset all configuration
	if resetAll {
		_, err := execNFTBanCommand("config", "reset-all", module)
		if err != nil {
			respondJSON(w, http.StatusInternalServerError, ErrorResponse{
				Error: fmt.Sprintf("Failed to reset configuration: %v", err),
			})
			return
		}

		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"message": fmt.Sprintf("All %s configuration reset to defaults", module),
		})
		return
	}

	// Reset specific keys
	var errors []string
	for _, key := range req.Keys {
		_, err := execNFTBanCommand("config", "reset", module, key)
		if err != nil {
			errors = append(errors, fmt.Sprintf("%s: %v", key, err))
		}
	}

	if len(errors) > 0 {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{
			Error: fmt.Sprintf("Failed to reset some values: %s", strings.Join(errors, "; ")),
		})
		return
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": fmt.Sprintf("Reset %d configuration values", len(req.Keys)),
		"reset":   len(req.Keys),
	})
}
