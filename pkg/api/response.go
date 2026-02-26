// =============================================================================
// NFTBan - Standardized API Response Types
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="response"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Standardized JSON response types and helpers for API endpoints"
// meta:input="None"
// meta:output="JSON response structures"
// meta:depends="net/http"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

// Package api provides HTTP API handlers for NFTBan
package api

import (
	"encoding/json"
	"log"
	"net/http"
	"time"
)

// =============================================================================
// Standardized API Response Types
// =============================================================================
// Purpose: Ensure all API endpoints return consistent JSON structure
// This makes frontend integration reliable and predictable
// =============================================================================

// APIResponse is the standard JSON envelope for all API responses
type APIResponse struct {
	Success   bool        `json:"success"`
	Message   string      `json:"message,omitempty"`
	Error     string      `json:"error,omitempty"`
	Data      interface{} `json:"data,omitempty"`
	Timestamp int64       `json:"timestamp"`
}

// NewSuccessResponse creates a success response with optional data
func NewSuccessResponse(message string, data interface{}) APIResponse {
	return APIResponse{
		Success:   true,
		Message:   message,
		Data:      data,
		Timestamp: time.Now().Unix(),
	}
}

// NewErrorResponse creates an error response
func NewErrorResponse(err string) APIResponse {
	return APIResponse{
		Success:   false,
		Error:     err,
		Timestamp: time.Now().Unix(),
	}
}

// NewDataResponse creates a success response with just data (no message)
func NewDataResponse(data interface{}) APIResponse {
	return APIResponse{
		Success:   true,
		Data:      data,
		Timestamp: time.Now().Unix(),
	}
}

// =============================================================================
// JSON Response Writers
// =============================================================================

// JSON sends a successful response with data
func JSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(NewDataResponse(data)); err != nil {
		log.Printf("[WARN] failed to encode JSON response: %v", err)
	}
}

// JSONSuccess sends a success message with optional data
func JSONSuccess(w http.ResponseWriter, message string, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	if err := json.NewEncoder(w).Encode(NewSuccessResponse(message, data)); err != nil {
		log.Printf("[WARN] failed to encode JSON response: %v", err)
	}
}

// JSONError sends an error response with specified status code
func JSONError(w http.ResponseWriter, status int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(NewErrorResponse(msg)); err != nil {
		log.Printf("[WARN] failed to encode JSON error response: %v", err)
	}
}

// JSONRaw sends a raw response object (for backward compatibility)
func JSONRaw(w http.ResponseWriter, status int, response interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(response); err != nil {
		log.Printf("[WARN] failed to encode JSON response: %v", err)
	}
}

