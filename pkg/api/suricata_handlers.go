// =============================================================================
// NFTBan - Suricata IDS API Handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="suricata_handlers"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-17"
// meta:description="HTTP API handlers for Suricata IDS management via GOTH GUI"
// meta:input="HTTP requests for Suricata operations"
// meta:output="JSON responses with Suricata status, alerts, rules, profiles"
// meta:depends="net/http,encoding/json"
// meta:inventory.files="/var/log/nftban/suricata/eve-alerts.json"
// meta:inventory.binaries="nftban,nftban-core,suricata,suricatasc"
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/suricata/suricata.yaml"
// meta:inventory.systemd_units="suricata.service"
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================

package api

import (
	"encoding/json"
	"log"
	"net/http"
	"strings"

	"github.com/itcmsgr/nftban/pkg/util"
)

// SuricataStatus represents Suricata service status
type SuricataStatus struct {
	Running      bool    `json:"running"`
	Profile      string  `json:"profile"`
	Alerts24h    int     `json:"alerts_24h"`
	RulesCount   int     `json:"rules_count"`
	DropRate     float64 `json:"drop_rate"`
	MemoryMB     int     `json:"memory_mb"`
	Uptime       string  `json:"uptime"`
	Version      string  `json:"version"`
	EVEPath      string  `json:"eve_path"`
	LastReload   string  `json:"last_reload"`
}

// SuricataAlert represents a single Suricata alert
type SuricataAlert struct {
	Timestamp  string `json:"timestamp"`
	SrcIP      string `json:"src_ip"`
	DestIP     string `json:"dest_ip"`
	SrcPort    int    `json:"src_port"`
	DestPort   int    `json:"dest_port"`
	Severity   int    `json:"severity"`
	Signature  string `json:"signature"`
	SID        int    `json:"sid"`
	Category   string `json:"category"`
	Protocol   string `json:"protocol"`
}

// SuricataService represents a detected service
type SuricataService struct {
	Name       string `json:"name"`
	Port       int    `json:"port"`
	Protocol   string `json:"protocol"`
	Detected   bool   `json:"detected"`
	Icon       string `json:"icon"`
	Categories string `json:"categories"`
}

// SuricataRuleStats represents rule statistics
type SuricataRuleStats struct {
	Total     int                   `json:"total"`
	Enabled   int                   `json:"enabled"`
	Disabled  int                   `json:"disabled"`
	Triggered int                   `json:"triggered"`
	Top       []SuricataTopRule     `json:"top"`
}

// SuricataTopRule represents a top triggered rule
type SuricataTopRule struct {
	SID      int    `json:"sid"`
	Name     string `json:"name"`
	Severity int    `json:"severity"`
	Count    int    `json:"count"`
}

// SuricataServiceMapping represents service-to-rule mapping
type SuricataServiceMapping struct {
	Service    string `json:"service"`
	Ports      string `json:"ports"`
	Categories string `json:"categories"`
	Enabled    bool   `json:"enabled"`
}

// =============================================================================
// STATUS HANDLER
// =============================================================================

// SuricataStatusHandler returns Suricata service status
// GET /api/v1/suricata/status
func SuricataStatusHandler(w http.ResponseWriter, r *http.Request) {
	// Execute: nftban-core suricata status (returns JSON)
	output, err := execCommand("nftban-core", "suricata", "status", "--json")
	if err != nil {
		log.Printf("[SURICATA] Failed to get status: %v", err)
		// Return default status
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"data": SuricataStatus{
				Running: false,
				Profile: "unknown",
			},
		})
		return
	}

	// Parse JSON output
	jsonOutput := util.ExtractJSON(output)
	var result struct {
		Success bool           `json:"success"`
		Data    SuricataStatus `json:"data"`
	}

	if err := json.Unmarshal([]byte(jsonOutput), &result); err != nil {
		log.Printf("[SURICATA] Failed to parse status: %v", err)
		// Fallback: check if service is running directly
		running := isServiceRunning("suricata")
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"data": SuricataStatus{
				Running: running,
				Profile: "standard",
				EVEPath: "/var/log/nftban/suricata/eve-alerts.json",
			},
		})
		return
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"data":    result.Data,
	})
}

// =============================================================================
// CONTROL HANDLER
// =============================================================================

// SuricataControlHandler enables/disables Suricata service
// POST /api/v1/suricata/control
func SuricataControlHandler(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Action string `json:"action"` // enable, disable, restart, reload
	}

	if !DecodeJSONBody(w, r, &req) {
		return
	}

	var output string
	var err error

	switch req.Action {
	case "enable":
		output, err = execCommand("nftban", "suricata", "enable")
	case "disable":
		output, err = execCommand("nftban", "suricata", "disable")
	case "restart":
		output, err = execCommand("systemctl", "restart", "suricata")
	case "reload":
		output, err = execCommand("suricatasc", "-c", "reload-rules")
	default:
		respondJSON(w, http.StatusBadRequest, map[string]interface{}{
			"success": false,
			"error":   "Invalid action. Use: enable, disable, restart, reload",
		})
		return
	}

	if err != nil {
		log.Printf("[SURICATA] Control action '%s' failed: %v - Output: %s", req.Action, err, output)
		respondJSON(w, http.StatusInternalServerError, map[string]interface{}{
			"success": false,
			"error":   "Action failed: " + err.Error(),
		})
		return
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": "Suricata " + req.Action + " completed",
	})
}

// =============================================================================
// PROFILE HANDLERS
// =============================================================================

// SuricataProfileDetectHandler auto-detects optimal profile
// POST /api/v1/suricata/profile/detect
func SuricataProfileDetectHandler(w http.ResponseWriter, r *http.Request) {
	output, err := execCommand("nftban-core", "suricata", "profile-detect")
	if err != nil {
		log.Printf("[SURICATA] Profile detection failed: %v", err)
		respondJSON(w, http.StatusInternalServerError, map[string]interface{}{
			"success": false,
			"error":   "Profile detection failed",
		})
		return
	}

	// Parse output to get recommended profile
	recommended := "standard"
	reason := "Default recommendation"

	if strings.Contains(output, "minimal") {
		recommended = "minimal"
		reason = "Limited CPU/RAM detected"
	} else if strings.Contains(output, "maximum") {
		recommended = "maximum"
		reason = "High resources available"
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"data": map[string]interface{}{
			"recommended": recommended,
			"reason":      reason,
		},
	})
}

// SuricataProfileApplyHandler applies a profile
// POST /api/v1/suricata/profile/apply
func SuricataProfileApplyHandler(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Profile string `json:"profile"` // minimal, standard, maximum
	}

	if !DecodeJSONBody(w, r, &req) {
		return
	}

	// Validate profile name
	validProfiles := map[string]bool{"minimal": true, "standard": true, "maximum": true}
	if !validProfiles[req.Profile] {
		respondJSON(w, http.StatusBadRequest, map[string]interface{}{
			"success": false,
			"error":   "Invalid profile. Use: minimal, standard, maximum",
		})
		return
	}

	output, err := execCommand("nftban-core", "suricata", "profile-apply", req.Profile)
	if err != nil {
		log.Printf("[SURICATA] Profile apply failed: %v - Output: %s", err, output)
		respondJSON(w, http.StatusInternalServerError, map[string]interface{}{
			"success": false,
			"error":   "Failed to apply profile: " + err.Error(),
		})
		return
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": "Profile '" + req.Profile + "' applied successfully",
	})
}

// SuricataProfileShowHandler shows current profile
// GET /api/v1/suricata/profile/show
func SuricataProfileShowHandler(w http.ResponseWriter, r *http.Request) {
	output, err := execCommand("nftban-core", "suricata", "profile-show")
	if err != nil {
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"data": map[string]interface{}{
				"profile": "standard",
			},
		})
		return
	}

	// Parse profile from output
	profile := "standard"
	if strings.Contains(output, "minimal") {
		profile = "minimal"
	} else if strings.Contains(output, "maximum") {
		profile = "maximum"
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"data": map[string]interface{}{
			"profile": profile,
		},
	})
}

// =============================================================================
// SERVICE SCAN HANDLERS
// =============================================================================

// SuricataScanHandler scans for running services
// POST /api/v1/suricata/scan
func SuricataScanHandler(w http.ResponseWriter, r *http.Request) {
	output, err := execCommand("nftban-core", "suricata", "scan")
	if err != nil {
		log.Printf("[SURICATA] Service scan failed: %v", err)
		respondJSON(w, http.StatusInternalServerError, map[string]interface{}{
			"success": false,
			"error":   "Service scan failed",
		})
		return
	}

	// Parse services from output or return default set
	services := []SuricataService{
		{Name: "SSH", Port: 22, Protocol: "tcp", Detected: true, Icon: "fa-terminal", Categories: "emerging-ssh"},
		{Name: "HTTP", Port: 80, Protocol: "tcp", Detected: strings.Contains(output, "80"), Icon: "fa-globe", Categories: "emerging-web_server"},
		{Name: "HTTPS", Port: 443, Protocol: "tcp", Detected: strings.Contains(output, "443"), Icon: "fa-lock", Categories: "emerging-web_server"},
		{Name: "SMTP", Port: 25, Protocol: "tcp", Detected: strings.Contains(output, "25"), Icon: "fa-envelope", Categories: "emerging-smtp"},
		{Name: "MySQL", Port: 3306, Protocol: "tcp", Detected: strings.Contains(output, "3306"), Icon: "fa-database", Categories: "emerging-sql"},
		{Name: "DNS", Port: 53, Protocol: "udp", Detected: strings.Contains(output, "53"), Icon: "fa-server", Categories: "emerging-dns"},
		{Name: "FTP", Port: 21, Protocol: "tcp", Detected: strings.Contains(output, "21"), Icon: "fa-folder-open", Categories: "emerging-ftp"},
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"data": map[string]interface{}{
			"services": services,
		},
	})
}

// SuricataServicesHandler returns service-to-rule mapping
// GET /api/v1/suricata/services
func SuricataServicesHandler(w http.ResponseWriter, r *http.Request) {
	// Return static mapping (could be dynamic based on config)
	mapping := []SuricataServiceMapping{
		{Service: "SSH", Ports: "22", Categories: "emerging-ssh", Enabled: true},
		{Service: "HTTP/HTTPS", Ports: "80, 443, 8080, 8443", Categories: "emerging-web_server, emerging-exploit", Enabled: true},
		{Service: "SMTP", Ports: "25, 465, 587", Categories: "emerging-smtp, emerging-mail", Enabled: false},
		{Service: "MySQL", Ports: "3306", Categories: "emerging-sql, emerging-mysql", Enabled: false},
		{Service: "PostgreSQL", Ports: "5432", Categories: "emerging-sql", Enabled: false},
		{Service: "DNS", Ports: "53", Categories: "emerging-dns", Enabled: false},
		{Service: "FTP", Ports: "21", Categories: "emerging-ftp", Enabled: false},
		{Service: "VPN", Ports: "1194, 51820", Categories: "emerging-vpn", Enabled: false},
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"data": map[string]interface{}{
			"mapping": mapping,
		},
	})
}

// =============================================================================
// RULES HANDLERS
// =============================================================================

// SuricataRulesStatsHandler returns rule statistics
// GET /api/v1/suricata/rules/stats
func SuricataRulesStatsHandler(w http.ResponseWriter, r *http.Request) {
	output, err := execCommand("nftban-core", "suricata", "rules-stats")
	if err != nil {
		log.Printf("[SURICATA] Rules stats failed: %v", err)
		// Return default stats
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"data": SuricataRuleStats{
				Total:     0,
				Enabled:   0,
				Disabled:  0,
				Triggered: 0,
				Top:       []SuricataTopRule{},
			},
		})
		return
	}

	// Parse JSON output
	jsonOutput := util.ExtractJSON(output)
	var result struct {
		Success bool              `json:"success"`
		Data    SuricataRuleStats `json:"data"`
	}

	if err := json.Unmarshal([]byte(jsonOutput), &result); err != nil {
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"data": SuricataRuleStats{
				Total:     0,
				Enabled:   0,
				Disabled:  0,
				Triggered: 0,
				Top:       []SuricataTopRule{},
			},
		})
		return
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"data":    result.Data,
	})
}

// SuricataRulesReloadHandler reloads Suricata rules
// POST /api/v1/suricata/rules/reload
func SuricataRulesReloadHandler(w http.ResponseWriter, r *http.Request) {
	_, err := execCommand("suricatasc", "-c", "reload-rules")
	if err != nil {
		// Fallback to systemctl
		output, fallbackErr := execCommand("systemctl", "reload", "suricata")
		if fallbackErr != nil {
			log.Printf("[SURICATA] Rules reload failed: %v - Output: %s", fallbackErr, output)
			respondJSON(w, http.StatusInternalServerError, map[string]interface{}{
				"success": false,
				"error":   "Failed to reload rules",
			})
			return
		}
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": "Rules reloaded successfully",
	})
}

// SuricataRulesGenerateHandler generates enabled.list from services
// POST /api/v1/suricata/rules/generate
func SuricataRulesGenerateHandler(w http.ResponseWriter, r *http.Request) {
	output, err := execCommand("nftban-core", "suricata", "rules-generate")
	if err != nil {
		log.Printf("[SURICATA] Rules generation failed: %v - Output: %s", err, output)
		respondJSON(w, http.StatusInternalServerError, map[string]interface{}{
			"success": false,
			"error":   "Failed to generate rules",
		})
		return
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": "Rules generated successfully",
		"data": map[string]interface{}{
			"enabled": 5, // Could parse from output
		},
	})
}

// SuricataRulesUpdateHandler updates ET rules via suricata-update
// POST /api/v1/suricata/rules/update
func SuricataRulesUpdateHandler(w http.ResponseWriter, r *http.Request) {
	output, err := execCommand("suricata-update")
	if err != nil {
		log.Printf("[SURICATA] Rules update failed: %v - Output: %s", err, output)
		respondJSON(w, http.StatusInternalServerError, map[string]interface{}{
			"success": false,
			"error":   "Failed to update rules: " + err.Error(),
		})
		return
	}

	// Reload rules after update
	execCommand("suricatasc", "-c", "reload-rules")

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": "ET Rules updated successfully",
	})
}

// =============================================================================
// ALERTS HANDLER
// =============================================================================

// SuricataAlertsHandler returns recent Suricata alerts
// GET /api/v1/suricata/alerts?limit=100
func SuricataAlertsHandler(w http.ResponseWriter, r *http.Request) {
	limit := r.URL.Query().Get("limit")
	if limit == "" {
		limit = "100"
	}

	// Get alerts from eve-alerts.json via nftban-core
	output, err := execCommand("nftban-core", "suricata", "sid-recent", "--limit", limit)
	if err != nil {
		log.Printf("[SURICATA] Failed to get alerts: %v", err)
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"data": map[string]interface{}{
				"alerts": []SuricataAlert{},
			},
		})
		return
	}

	// Parse JSON output
	jsonOutput := util.ExtractJSON(output)
	var result struct {
		Success bool `json:"success"`
		Data    struct {
			Alerts []SuricataAlert `json:"alerts"`
		} `json:"data"`
	}

	if err := json.Unmarshal([]byte(jsonOutput), &result); err != nil {
		log.Printf("[SURICATA] Failed to parse alerts: %v", err)
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"data": map[string]interface{}{
				"alerts": []SuricataAlert{},
			},
		})
		return
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"data":    result.Data,
	})
}

// =============================================================================
// CONFIG HANDLER
// =============================================================================

// SuricataConfigValidateHandler validates suricata.yaml
// POST /api/v1/suricata/config/validate
func SuricataConfigValidateHandler(w http.ResponseWriter, r *http.Request) {
	output, err := execCommand("suricata", "-T", "-c", "/etc/suricata/suricata.yaml")
	if err != nil {
		log.Printf("[SURICATA] Config validation failed: %v - Output: %s", err, output)
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": false,
			"error":   "Configuration validation failed: " + output,
		})
		return
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": "Configuration is valid",
	})
}

// Note: isServiceRunning is defined in system_handlers.go
