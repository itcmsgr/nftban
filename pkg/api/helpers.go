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

// validateCIDR validates a CIDR notation
func validateCIDR(cidrStr string) error {
	_, _, err := net.ParseCIDR(cidrStr)
	if err != nil {
		return fmt.Errorf("invalid CIDR: %s", cidrStr)
	}
	return nil
}
