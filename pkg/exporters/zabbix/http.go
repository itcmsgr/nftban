// =============================================================================
// NFTBan v1.0 - Zabbix HTTP Endpoint
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="http"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-22"
// meta:description="HTTP endpoint for exposing metrics and status"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package zabbix

import (
	"encoding/json"
	"net/http"
	"time"
)

// =============================================================================
// HTTP Handler
// =============================================================================

// HTTPHandler provides HTTP endpoints for the Zabbix exporter
type HTTPHandler struct {
	exporter *Exporter
}

// NewHTTPHandler creates a new HTTP handler
func NewHTTPHandler(exporter *Exporter) *HTTPHandler {
	return &HTTPHandler{
		exporter: exporter,
	}
}

// RegisterRoutes registers HTTP routes with a mux
func (h *HTTPHandler) RegisterRoutes(mux *http.ServeMux) {
	mux.HandleFunc("/api/v1/metrics", h.HandleMetrics)
	mux.HandleFunc("/api/v1/metrics/zabbix", h.HandleZabbixMetrics)
	mux.HandleFunc("/api/v1/zabbix/status", h.HandleStatus)
	mux.HandleFunc("/api/v1/zabbix/discovery", h.HandleDiscovery)
	mux.HandleFunc("/api/v1/zabbix/health", h.HandleHealth)
}

// =============================================================================
// Metrics Endpoint
// =============================================================================

// HandleMetrics handles GET /api/v1/metrics
// Returns current metrics snapshot as JSON
func (h *HTTPHandler) HandleMetrics(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	snapshot := h.exporter.CollectNow()
	if snapshot == nil {
		http.Error(w, "Failed to collect metrics", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-NFTBan-Timestamp", snapshot.Timestamp.Format(time.RFC3339))

	if err := json.NewEncoder(w).Encode(snapshot); err != nil {
		http.Error(w, "Failed to encode response", http.StatusInternalServerError)
		return
	}
}

// HandleZabbixMetrics handles GET /api/v1/metrics/zabbix
// Returns metrics in Zabbix-friendly format (flat key-value pairs)
func (h *HTTPHandler) HandleZabbixMetrics(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	snapshot := h.exporter.CollectNow()
	if snapshot == nil {
		http.Error(w, "Failed to collect metrics", http.StatusInternalServerError)
		return
	}

	metrics := snapshot.ToMetrics()

	// Convert to simple key-value format
	result := make(map[string]interface{})
	result["timestamp"] = snapshot.Timestamp.Unix()
	result["timestamp_iso"] = snapshot.Timestamp.Format(time.RFC3339)

	data := make(map[string]interface{})
	for _, m := range metrics {
		data[m.Name] = m.Value
	}
	result["data"] = data

	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(result); err != nil {
		http.Error(w, "Failed to encode response", http.StatusInternalServerError)
		return
	}
}

// =============================================================================
// Status Endpoint
// =============================================================================

// HandleStatus handles GET /api/v1/zabbix/status
// Returns exporter status and statistics
func (h *HTTPHandler) HandleStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	status := h.exporter.Status()

	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(status); err != nil {
		http.Error(w, "Failed to encode response", http.StatusInternalServerError)
		return
	}
}

// =============================================================================
// Discovery Endpoint
// =============================================================================

// HandleDiscovery handles GET /api/v1/zabbix/discovery
// Returns discovery data for LLD
func (h *HTTPHandler) HandleDiscovery(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Get specific discovery key from query param
	key := r.URL.Query().Get("key")

	discovery := h.exporter.Discovery()

	if key != "" {
		// Return specific discovery data
		data, err := discovery.Get(key)
		if err != nil {
			http.Error(w, err.Error(), http.StatusNotFound)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(data))
		return
	}

	// Return all discovery data
	allData := discovery.GetAll()

	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(allData); err != nil {
		http.Error(w, "Failed to encode response", http.StatusInternalServerError)
		return
	}
}

// =============================================================================
// Health Endpoint
// =============================================================================

// HandleHealth handles GET /api/v1/zabbix/health
// Returns target health status
func (h *HTTPHandler) HandleHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	sender := h.exporter.Sender()
	if sender == nil {
		http.Error(w, "Sender not configured", http.StatusServiceUnavailable)
		return
	}

	health := sender.GetHealth()

	// Calculate overall health
	overall := "healthy"
	healthyCount := 0
	for _, h := range health {
		if h.Healthy {
			healthyCount++
		}
	}
	if healthyCount == 0 {
		overall = "unhealthy"
	} else if healthyCount < len(health) {
		overall = "degraded"
	}

	response := struct {
		Overall string                    `json:"overall"`
		Targets map[string]TargetHealth   `json:"targets"`
	}{
		Overall: overall,
		Targets: health,
	}

	w.Header().Set("Content-Type", "application/json")

	if err := json.NewEncoder(w).Encode(response); err != nil {
		http.Error(w, "Failed to encode response", http.StatusInternalServerError)
		return
	}
}

// =============================================================================
// NDJSON Endpoint (for streaming)
// =============================================================================

// HandleNDJSON handles GET /api/v1/metrics/ndjson
// Returns metrics in NDJSON format (one JSON object per line)
func (h *HTTPHandler) HandleNDJSON(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	snapshot := h.exporter.CollectNow()
	if snapshot == nil {
		http.Error(w, "Failed to collect metrics", http.StatusInternalServerError)
		return
	}

	metrics := snapshot.ToMetrics()

	w.Header().Set("Content-Type", "application/x-ndjson")

	enc := json.NewEncoder(w)
	for _, m := range metrics {
		record := map[string]interface{}{
			"timestamp": snapshot.Timestamp.Format(time.RFC3339),
			"host":      snapshot.Server.Hostname,
			"key":       m.Name,
			"value":     m.Value,
			"type":      m.Type,
		}
		if err := enc.Encode(record); err != nil {
			return
		}
	}
}

// =============================================================================
// Middleware
// =============================================================================

// WithAuth wraps a handler with basic authentication
func WithAuth(handler http.HandlerFunc, username, password string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if username == "" && password == "" {
			handler(w, r)
			return
		}

		user, pass, ok := r.BasicAuth()
		if !ok || user != username || pass != password {
			w.Header().Set("WWW-Authenticate", `Basic realm="NFTBan Zabbix Exporter"`)
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}

		handler(w, r)
	}
}

// BUG-H6 FIX: Removed unused WithCORS function that had Access-Control-Allow-Origin: *
// If CORS support is needed in the future, use a configurable origin whitelist.

// =============================================================================
// Response Types
// =============================================================================

// MetricsResponse is the response for /api/v1/metrics
type MetricsResponse struct {
	Timestamp time.Time              `json:"timestamp"`
	Host      string                 `json:"host"`
	Metrics   map[string]interface{} `json:"metrics"`
}

// DiscoveryResponse is the response for /api/v1/zabbix/discovery
type DiscoveryResponse struct {
	Key       string          `json:"key"`
	Data      json.RawMessage `json:"data"`
	UpdatedAt time.Time       `json:"updated_at"`
}

// HealthResponse is the response for /api/v1/zabbix/health
type HealthResponse struct {
	Overall string                  `json:"overall"`
	Targets map[string]TargetHealth `json:"targets"`
}
