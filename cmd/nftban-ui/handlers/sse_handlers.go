// =============================================================================
// NFTBan - GOTH GUI SSE Handlers (Server-Sent Events)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="sse_handlers"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-02-06"
// meta:description="Server-Sent Events handlers for real-time dashboard updates"
// meta:input="HTTP requests with SSE upgrade"
// meta:output="SSE event stream (JSON payloads)"
// meta:depends="github.com/itcmsgr/nftban/internal/ui"
// meta:inventory.files=""
// meta:inventory.binaries="nftban-ui"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package handlers

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/itcmsgr/nftban/internal/logutil"
)

// SECURITY FIX: Connection limiting to prevent SSE resource exhaustion attacks
// Maximum number of concurrent SSE connections allowed globally
const maxSSEConnections = 100

// Maximum connections per session (prevents single user from exhausting all slots)
const maxSSEConnectionsPerSession = 3

// sseConnectionCount tracks the current number of active SSE connections
var sseConnectionCount int64

// sseSessionConnections tracks per-session connection counts
// Key: session_id, Value: *int64 (connection count for that session)
var sseSessionConnections sync.Map

// SSEDashboardEvent represents the JSON payload sent via SSE
type SSEDashboardEvent struct {
	// Timestamp of this event
	Timestamp string `json:"timestamp"`

	// Security statistics
	Security SSESecurityStats `json:"security"`

	// System status
	System SSESystemStats `json:"system"`

	// Recent bans (last 5)
	RecentBans []SSERecentBan `json:"recent_bans"`

	// Module status summary
	ModulesSummary SSEModulesSummary `json:"modules_summary"`

	// Network stats
	Network SSENetworkStats `json:"network"`
}

// SSESecurityStats holds security KPIs for SSE
type SSESecurityStats struct {
	BansTotal      int `json:"bans_total"`
	BansIPv4       int `json:"bans_ipv4"`
	BansIPv6       int `json:"bans_ipv6"`
	WhitelistTotal int `json:"whitelist_total"`
	WhitelistIPv4  int `json:"whitelist_ipv4"`
	WhitelistIPv6  int `json:"whitelist_ipv6"`
	EventsLastHour int `json:"events_last_hour"`
	TotalBansEver  int `json:"total_bans_ever"`
}

// SSESystemStats holds system resource stats for SSE
type SSESystemStats struct {
	CPUPercent    float64 `json:"cpu_percent"`
	RAMPercent    float64 `json:"ram_percent"`
	DiskPercent   float64 `json:"disk_percent"`
	LoadAvg1      float64 `json:"load_avg_1"`
	LoadAvg5      float64 `json:"load_avg_5"`
	LoadAvg15     float64 `json:"load_avg_15"`
	NFTBanCPU     float64 `json:"nftban_cpu"`
	NFTBanMemMB   float64 `json:"nftban_mem_mb"`
	PanelMode     string  `json:"panel_mode"`
	UptimeSeconds int64   `json:"uptime_seconds"`
}

// SSERecentBan represents a recent ban for SSE
type SSERecentBan struct {
	IP        string `json:"ip"`
	Country   string `json:"country"`
	Module    string `json:"module"`
	Reason    string `json:"reason"`
	Timestamp string `json:"timestamp"`
}

// SSEModulesSummary holds module status summary for SSE
type SSEModulesSummary struct {
	TotalModules   int `json:"total_modules"`
	ActiveModules  int `json:"active_modules"`
	WarningModules int `json:"warning_modules"`
	ErrorModules   int `json:"error_modules"`
}

// SSENetworkStats holds network statistics for SSE
type SSENetworkStats struct {
	InMbps         float64 `json:"in_mbps"`
	OutMbps        float64 `json:"out_mbps"`
	PacketDropRate int     `json:"packet_drop_rate"`
}

// HandleSSEDashboard provides Server-Sent Events for real-time dashboard updates.
// Events are sent every 5 seconds with security stats, recent bans, and system status.
// Requires authenticated session.
func (h *GOTHHandlers) HandleSSEDashboard(w http.ResponseWriter, r *http.Request) {
	// Validate session first (already done by RequireSession wrapper, but double-check)
	cookie, err := r.Cookie("session_id")
	if err != nil {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}
	sessionID := cookie.Value
	if _, err := h.SessionStore.Get(sessionID); err != nil {
		http.Error(w, "Session expired", http.StatusUnauthorized)
		return
	}

	// SECURITY FIX: Check global connection limit
	// This prevents resource exhaustion attacks via SSE connection flooding
	currentCount := atomic.LoadInt64(&sseConnectionCount)
	if currentCount >= maxSSEConnections {
		log.Printf("[SSE] Global connection limit reached (%d/%d), rejecting from %s",
			currentCount, maxSSEConnections, r.RemoteAddr)
		http.Error(w, "Too many SSE connections", http.StatusTooManyRequests)
		return
	}

	// SECURITY FIX: Check per-session connection limit
	// This prevents a single user from exhausting all connection slots
	sessionCount := getSessionSSECount(sessionID)
	if sessionCount >= maxSSEConnectionsPerSession {
		log.Printf("[SSE] Per-session limit reached for session %s (%d/%d), rejecting",
			logutil.Sanitize(sessionID[:8]), sessionCount, maxSSEConnectionsPerSession)
		http.Error(w, "Too many connections from this session", http.StatusTooManyRequests)
		return
	}

	// Increment both counters
	atomic.AddInt64(&sseConnectionCount, 1)
	incrementSessionSSECount(sessionID)

	// Ensure we decrement when this handler exits
	defer func() {
		atomic.AddInt64(&sseConnectionCount, -1)
		decrementSessionSSECount(sessionID)
	}()

	// Set SSE headers
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no") // Disable nginx buffering

	// Get flusher for streaming
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "SSE not supported", http.StatusInternalServerError)
		return
	}

	// Create context that cancels when client disconnects
	ctx := r.Context()

	// Log connection with current count
	clientIP := r.RemoteAddr
	log.Printf("[SSE] Dashboard connection established from %s (active: %d/%d)",
		clientIP, atomic.LoadInt64(&sseConnectionCount), maxSSEConnections)

	// Send initial event immediately
	if err := h.sendSSEDashboardEvent(w, flusher); err != nil {
		log.Printf("[SSE] Error sending initial event to %s: %v", clientIP, err)
		return
	}

	// Create ticker for 5-second updates
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()

	// Event loop
	for {
		select {
		case <-ctx.Done():
			// Client disconnected
			log.Printf("[SSE] Dashboard connection closed from %s", clientIP)
			return
		case <-ticker.C:
			// Send periodic update
			if err := h.sendSSEDashboardEvent(w, flusher); err != nil {
				log.Printf("[SSE] Error sending event to %s: %v", clientIP, err)
				return
			}
		}
	}
}

// =============================================================================
// SSE Per-Session Connection Tracking Helpers
// =============================================================================

// getSessionSSECount returns the current SSE connection count for a session
func getSessionSSECount(sessionID string) int64 {
	if val, ok := sseSessionConnections.Load(sessionID); ok {
		if p, ok := val.(*int64); ok {
			return atomic.LoadInt64(p)
		}
	}
	return 0
}

// incrementSessionSSECount increments the SSE connection count for a session
func incrementSessionSSECount(sessionID string) {
	// Load or create counter for this session
	actual, _ := sseSessionConnections.LoadOrStore(sessionID, new(int64))
	if p, ok := actual.(*int64); ok {
		atomic.AddInt64(p, 1)
	}
}

// decrementSessionSSECount decrements the SSE connection count for a session
// and cleans up the entry if count reaches zero
func decrementSessionSSECount(sessionID string) {
	if val, ok := sseSessionConnections.Load(sessionID); ok {
		if p, ok := val.(*int64); ok {
			newCount := atomic.AddInt64(p, -1)
			// Clean up if no more connections for this session
			if newCount <= 0 {
				sseSessionConnections.Delete(sessionID)
			}
		}
	}
}

// sendSSEDashboardEvent sends a single SSE event with current dashboard data
func (h *GOTHHandlers) sendSSEDashboardEvent(w http.ResponseWriter, flusher http.Flusher) error {
	// Gather all data
	event := h.buildSSEDashboardEvent()

	// Marshal to JSON
	data, err := json.Marshal(event)
	if err != nil {
		return fmt.Errorf("failed to marshal SSE event: %w", err)
	}

	// Write SSE format: "data: <json>\n\n"
	_, err = fmt.Fprintf(w, "event: dashboard\ndata: %s\n\n", data)
	if err != nil {
		return fmt.Errorf("failed to write SSE event: %w", err)
	}

	// Flush to send immediately
	flusher.Flush()

	return nil
}

// buildSSEDashboardEvent constructs the SSE event payload from current system state
func (h *GOTHHandlers) buildSSEDashboardEvent() SSEDashboardEvent {
	// Get security stats
	security := h.getSecurity()

	// Get resource stats
	resources := h.getResources()

	// Get identity for panel mode and uptime
	identity := h.getIdentity()

	// Get recent bans
	recentBans := h.getRecentBans()

	// Get modules for summary
	modules := h.getModulesList()

	// Build event
	event := SSEDashboardEvent{
		Timestamp: time.Now().Format("2006-01-02 15:04:05"),
		Security: SSESecurityStats{
			BansTotal:      security.BansTotal,
			BansIPv4:       security.BansIPv4,
			BansIPv6:       security.BansIPv6,
			WhitelistTotal: security.WhitelistTotal,
			WhitelistIPv4:  security.WhitelistIPv4,
			WhitelistIPv6:  security.WhitelistIPv6,
			EventsLastHour: security.EventsLastHour,
			TotalBansEver:  security.TotalBansEver,
		},
		System: SSESystemStats{
			CPUPercent:    resources.CPUPercent,
			RAMPercent:    resources.RAMPercent,
			DiskPercent:   resources.DiskPercent,
			LoadAvg1:      resources.CPULoadAvg1,
			LoadAvg5:      resources.CPULoadAvg5,
			LoadAvg15:     resources.CPULoadAvg15,
			NFTBanCPU:     resources.NFTBanCPU,
			NFTBanMemMB:   resources.NFTBanMemMB,
			PanelMode:     identity.PanelMode,
			UptimeSeconds: identity.UptimeSeconds,
		},
		Network: SSENetworkStats{
			InMbps:         security.NetworkInMbps,
			OutMbps:        security.NetworkOutMbps,
			PacketDropRate: security.PacketDropRate,
		},
	}

	// Convert recent bans (limit to 5 for SSE payload size)
	// Pre-allocate slice to avoid repeated allocations during append
	maxBans := 5
	if len(recentBans) < maxBans {
		maxBans = len(recentBans)
	}
	event.RecentBans = make([]SSERecentBan, 0, maxBans)
	for i := 0; i < maxBans; i++ {
		event.RecentBans = append(event.RecentBans, SSERecentBan{
			IP:        recentBans[i].IP,
			Country:   recentBans[i].Country,
			Module:    recentBans[i].Module,
			Reason:    recentBans[i].Reason,
			Timestamp: recentBans[i].Timestamp,
		})
	}

	// Calculate module summary
	summary := SSEModulesSummary{
		TotalModules: len(modules),
	}
	for _, mod := range modules {
		switch mod.Status {
		case "active":
			summary.ActiveModules++
		case "warning":
			summary.WarningModules++
		case "failed", "error":
			summary.ErrorModules++
		}
	}
	event.ModulesSummary = summary

	return event
}

