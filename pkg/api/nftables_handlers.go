// =============================================================================
// NFTBan - NFTables API Handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftables_handlers"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="HTTP API handlers for nftables ruleset viewing and validation"
// meta:input="HTTP requests for ruleset operations"
// meta:output="JSON responses with ruleset data and validation results"
// meta:depends="github.com/itcmsgr/nftban/pkg/nftables"
// meta:inventory.files=""
// meta:inventory.binaries="nftban"
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/nftables.conf.backup"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package api

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/pkg/nftables"
)

// NFTablesRulesetHandler returns the current nftables ruleset
func NFTablesRulesetHandler(w http.ResponseWriter, r *http.Request) {
	// Use nftban nftables list command (architectural compliance)
	output, err := execNFTBanCommand("nftables", "list")
	if err != nil {
		log.Printf("[ERROR] Failed to get nftables ruleset: %v", err)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to get nftables ruleset"})
		return
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"data": map[string]interface{}{
			"ruleset":   strings.TrimSpace(output),
			"timestamp": time.Now().Unix(),
		},
	})
}

// NFTablesValidateHandler validates the nftables hierarchy
func NFTablesValidateHandler(w http.ResponseWriter, r *http.Request) {
	// Use nftban firewall validate with JSON output (architectural compliance)
	output, err := execNFTBanCommand("firewall", "validate", "--json")
	if err != nil {
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"data": map[string]interface{}{
				"valid":  false,
				"issues": []string{"Failed to validate nftables: " + err.Error()},
			},
		})
		return
	}

	// Parse JSON output from nftban firewall validate
	var result map[string]interface{}
	if err := json.Unmarshal([]byte(output), &result); err != nil {
		// Fallback to manual validation if JSON parsing fails
		output, err = execNFTBanCommand("nftables", "list")
		if err != nil {
			respondJSON(w, http.StatusOK, map[string]interface{}{
				"success": true,
				"data": map[string]interface{}{
					"valid":  false,
					"issues": []string{"Failed to get nftables ruleset: " + err.Error()},
				},
			})
			return
		}
	} else {
		// Return the parsed JSON result directly
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"data":    result,
		})
		return
	}

	ruleset := strings.TrimSpace(output)
	issues := []string{}
	warnings := []string{}

	// Check if nftban tables exist (v0.7.3: ip nftban + ip6 nftban)
	hasIPv4Table := strings.Contains(ruleset, "table "+nftables.TableIPv4)
	hasIPv6Table := strings.Contains(ruleset, "table "+nftables.TableIPv6)
	hasOldInetTable := strings.Contains(ruleset, "table inet nftban")

	if !hasIPv4Table && !hasIPv6Table && !hasOldInetTable {
		issues = append(issues, "NFTBan tables not found - NFTBan may not be properly initialized")
	} else if hasOldInetTable && !hasIPv4Table {
		warnings = append(warnings, "Old 'inet nftban' table detected - consider migrating to v0.7.3 dual-table architecture ("+nftables.TableIPv4+" + "+nftables.TableIPv6+")")
	} else if hasIPv4Table {
		// v0.7.3 architecture detected
		if !hasIPv6Table {
			warnings = append(warnings, "IPv4 table found but IPv6 table missing - IPv6 traffic not protected")
		}
	}

	// Check for required chains
	requiredChains := []string{"input", "output", "forward"}
	for _, chain := range requiredChains {
		if !strings.Contains(ruleset, "chain "+chain) {
			warnings = append(warnings, "Chain '"+chain+"' not found in nftban table")
		}
	}

	// Check for nftban rules in other tables (bad practice)
	lines := strings.Split(ruleset, "\n")
	inNFTBanTable := false
	currentTable := ""
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "table ") {
			if strings.Contains(line, "nftban") {
				inNFTBanTable = true
				currentTable = "nftban"
			} else {
				inNFTBanTable = false
				if strings.Contains(line, "inet") {
					parts := strings.Fields(line)
					if len(parts) >= 3 {
						currentTable = parts[2]
					}
				}
			}
		}
		if !inNFTBanTable && currentTable != "" && currentTable != "nftban" {
			if strings.Contains(line, "banned") || strings.Contains(line, "whitelist") || strings.Contains(line, "geoban") {
				warnings = append(warnings, "NFTBan-related rule found in '"+currentTable+"' table - should be in nftban table only")
			}
		}
	}

	valid := len(issues) == 0

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"data": map[string]interface{}{
			"valid":    valid,
			"issues":   issues,
			"warnings": warnings,
		},
	})
}

// NFTablesSaveHandler saves the current nftables ruleset to a backup file
// v1.19.0: Add size limit (R36) and fix permissions to 0640
func NFTablesSaveHandler(w http.ResponseWriter, r *http.Request) {
	// v1.19.0: Limit request body to 10MB to prevent DoS (R36)
	const maxBackupSize = 10 * 1024 * 1024 // 10MB
	r.Body = http.MaxBytesReader(w, r.Body, maxBackupSize)

	var req struct {
		Ruleset string `json:"ruleset"`
	}

	if !DecodeJSONBody(w, r, &req) {
		return
	}

	// v1.19.0: Reject empty or oversized rulesets
	if len(req.Ruleset) == 0 {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Ruleset cannot be empty"})
		return
	}

	// Save to backup file - use central config
	configDir := getConfigDir()
	backupPath := configDir + "/nftables.conf.backup"
	timestamp := time.Now().Format("20060102_150405")
	backupPathWithTime := configDir + "/backups/nftables_" + timestamp + ".conf"

	// Create backups directory if it doesn't exist
	os.MkdirAll(configDir+"/backups", 0750)

	// Save with timestamp — v1.19.0: permissions 0640 (R36)
	if err := os.WriteFile(backupPathWithTime, []byte(req.Ruleset), 0640); err != nil {
		log.Printf("[ERROR] Failed to save nftables backup: %v", err)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to save backup: " + err.Error()})
		return
	}

	// Also save to standard backup path — v1.19.0: permissions 0640
	if err := os.WriteFile(backupPath, []byte(req.Ruleset), 0640); err != nil {
		log.Printf("[WARN] Failed to save to standard backup path: %v", err)
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"data": map[string]interface{}{
			"path":      backupPathWithTime,
			"timestamp": timestamp,
		},
	})
}
