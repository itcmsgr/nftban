// =============================================================================
// NFTBan - API Helper Functions
// =============================================================================
// SPDX-License-Identifier: GPL-3.0-or-later
// meta:name="helpers"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Helper functions for JSON responses and IP validation"
// meta:input="None"
// meta:output="None"
// meta:depends="net/http"
// meta:inventory.files=""
// meta:inventory.binaries=""
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
	"net"
	"net/http"
)

// respondJSON sends a JSON response
func respondJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(data); err != nil {
		// Best effort; can't do much if encoding fails
		return
	}
}

// respondError sends an error response
func respondError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]interface{}{
		"success": false,
		"error":   message,
	})
}

// validateIP validates a single IP address
func validateIP(ipStr string) error {
	ip := net.ParseIP(ipStr)
	if ip == nil {
		return fmt.Errorf("invalid IP address: %s", ipStr)
	}
	return nil
}

// validateIPs validates a slice of IP addresses
func validateIPs(ips []string) error {
	for _, ipStr := range ips {
		if err := validateIP(ipStr); err != nil {
			return err
		}
	}
	return nil
}

//nolint:U1000 // Prepared for future validation enhancement
