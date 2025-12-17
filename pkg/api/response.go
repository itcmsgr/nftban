// Package api provides HTTP API handlers for NFTBan
package api

import (
	"encoding/json"
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
	json.NewEncoder(w).Encode(NewDataResponse(data))
}

// JSONSuccess sends a success message with optional data
func JSONSuccess(w http.ResponseWriter, message string, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(NewSuccessResponse(message, data))
}

// JSONError sends an error response with specified status code
func JSONError(w http.ResponseWriter, status int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(NewErrorResponse(msg))
}

// JSONRaw sends a raw response object (for backward compatibility)
func JSONRaw(w http.ResponseWriter, status int, response interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(response)
}

// =============================================================================
// Convenience Error Functions
// =============================================================================

// JSONBadRequest sends 400 Bad Request error
func JSONBadRequest(w http.ResponseWriter, msg string) {
	JSONError(w, http.StatusBadRequest, msg)
}

// JSONUnauthorized sends 401 Unauthorized error
func JSONUnauthorized(w http.ResponseWriter, msg string) {
	JSONError(w, http.StatusUnauthorized, msg)
}

// JSONForbidden sends 403 Forbidden error
func JSONForbidden(w http.ResponseWriter, msg string) {
	JSONError(w, http.StatusForbidden, msg)
}

// JSONNotFound sends 404 Not Found error
func JSONNotFound(w http.ResponseWriter, msg string) {
	JSONError(w, http.StatusNotFound, msg)
}

// JSONConflict sends 409 Conflict error
func JSONConflict(w http.ResponseWriter, msg string) {
	JSONError(w, http.StatusConflict, msg)
}

// JSONInternalError sends 500 Internal Server Error
func JSONInternalError(w http.ResponseWriter, msg string) {
	JSONError(w, http.StatusInternalServerError, msg)
}

// JSONServiceUnavailable sends 503 Service Unavailable error
func JSONServiceUnavailable(w http.ResponseWriter, msg string) {
	JSONError(w, http.StatusServiceUnavailable, msg)
}

// =============================================================================
// Pagination Response Helpers
// =============================================================================

// PaginatedResponse wraps data with pagination info
type PaginatedResponse struct {
	Items      interface{} `json:"items"`
	Page       int         `json:"page"`
	Limit      int         `json:"limit"`
	Total      int         `json:"total"`
	TotalPages int         `json:"total_pages"`
}

// NewPaginatedResponse creates a paginated response
func NewPaginatedResponse(items interface{}, page, limit, total int) PaginatedResponse {
	totalPages := total / limit
	if total%limit > 0 {
		totalPages++
	}
	return PaginatedResponse{
		Items:      items,
		Page:       page,
		Limit:      limit,
		Total:      total,
		TotalPages: totalPages,
	}
}

// JSONPaginated sends a paginated response
func JSONPaginated(w http.ResponseWriter, items interface{}, page, limit, total int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(NewSuccessResponse("", NewPaginatedResponse(items, page, limit, total)))
}
