// =============================================================================
// NFTBan - API Helper Functions
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="helpers"
// meta:type="package"
// meta:version="1.0.0"
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
	"html"
	"net/http"
	"strings"

	"github.com/itcmsgr/nftban/pkg/netutil"
)

// DecodeJSONBody decodes JSON request body into target struct
// Returns false and sends error response if decoding fails
func DecodeJSONBody(w http.ResponseWriter, r *http.Request, target interface{}) bool {
	if err := json.NewDecoder(r.Body).Decode(target); err != nil {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid request body: " + err.Error()})
		return false
	}
	return true
}

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

// sanitizeError escapes error messages for safe JSON/HTML output (R35-R37 v1.19.12)
// Prevents XSS when error messages are rendered in HTML contexts
//
//nolint:U1000 // Exported for use by handlers - will be wired in upcoming PR
func sanitizeError(err error) string {
	if err == nil {
		return ""
	}
	// Escape HTML special chars and truncate to prevent DoS
	msg := html.EscapeString(err.Error())
	if len(msg) > 512 {
		msg = msg[:512] + "..."
	}
	return msg
}

// sanitizeErrorMsg escapes a string error message for safe JSON/HTML output
//
//nolint:U1000 // Exported for use by handlers - will be wired in upcoming PR
func sanitizeErrorMsg(msg string) string {
	// Strip filesystem paths that might leak system info
	msg = stripSensitivePaths(msg)
	// Escape HTML special chars
	msg = html.EscapeString(msg)
	if len(msg) > 512 {
		msg = msg[:512] + "..."
	}
	return msg
}

// stripSensitivePaths removes full filesystem paths from error messages
//
//nolint:U1000 // Helper for sanitizeErrorMsg
func stripSensitivePaths(msg string) string {
	// Replace common sensitive path prefixes with generic placeholders
	sensitivePatterns := []string{
		"/etc/nftban/",
		"/var/lib/nftban/",
		"/var/log/nftban/",
		"/usr/lib/nftban/",
	}
	for _, p := range sensitivePatterns {
		if strings.Contains(msg, p) {
			msg = strings.ReplaceAll(msg, p, "[nftban]/")
		}
	}
	return msg
}

// validateIP validates a single IP address using the shared netutil.IsValidIP function
func validateIP(ipStr string) error {
	if !netutil.IsValidIP(ipStr) {
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
