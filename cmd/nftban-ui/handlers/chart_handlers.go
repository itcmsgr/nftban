// =============================================================================
// NFTBan - GOTH GUI Chart API Handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="chart_handlers"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-02-05"
// meta:description="Chart API endpoints for dashboard visualizations"
// meta:input="HTTP requests"
// meta:output="JSON chart data"
// meta:depends=""
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
	"net/http"
	"time"
)

// ChartDataResponse represents the standard chart data format
type ChartDataResponse struct {
	Labels   []string  `json:"labels"`
	Values   []int64   `json:"values,omitempty"`
	Inbound  []float64 `json:"inbound,omitempty"`
	Outbound []float64 `json:"outbound,omitempty"`
}

// HandleChartTraffic returns traffic chart data (24h)
func (h *GOTHHandlers) HandleChartTraffic(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	history := h.getTrafficHistory()

	resp := ChartDataResponse{
		Labels:   make([]string, 0, len(history)),
		Inbound:  make([]float64, 0, len(history)),
		Outbound: make([]float64, 0, len(history)),
	}

	for _, sample := range history {
		resp.Labels = append(resp.Labels, sample.Timestamp)
		resp.Inbound = append(resp.Inbound, sample.RxMbps)
		resp.Outbound = append(resp.Outbound, sample.TxMbps)
	}

	// If no history, generate 24-hour labels with zeros
	if len(resp.Labels) == 0 {
		now := time.Now()
		for i := 23; i >= 0; i-- {
			resp.Labels = append(resp.Labels, now.Add(-time.Duration(i)*time.Hour).Format("15:04"))
			resp.Inbound = append(resp.Inbound, 0)
			resp.Outbound = append(resp.Outbound, 0)
		}
	}

	json.NewEncoder(w).Encode(resp)
}

// HandleChartBans returns ban distribution chart data
func (h *GOTHHandlers) HandleChartBans(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	resp := ChartDataResponse{
		Labels: []string{"Temporary", "Permanent", "Feed-based", "GeoIP"},
		Values: []int64{0, 0, 0, 0},
	}

	// Get ban breakdown from metrics cache
	// (state.BasicSnapshot only has totals, not breakdown by type)
	metricsData := h.getMetricsData()
	resp.Values[0] = int64(metricsData.Security.BansTemporary)
	resp.Values[1] = int64(metricsData.Security.BansPermanent)
	resp.Values[2] = int64(metricsData.Security.BansFeed)
	resp.Values[3] = int64(metricsData.Security.BansGeoIP)

	json.NewEncoder(w).Encode(resp)
}

// HandleChartCountries returns top blocked countries chart data
func (h *GOTHHandlers) HandleChartCountries(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	countries := h.getDroppedByCountry()

	resp := ChartDataResponse{
		Labels: make([]string, 0, len(countries)),
		Values: make([]int64, 0, len(countries)),
	}

	for _, c := range countries {
		label := c.Name
		if label == "" {
			label = c.Code
		}
		resp.Labels = append(resp.Labels, label)
		resp.Values = append(resp.Values, c.Blocked)
	}

	// If no data, return sample placeholder
	if len(resp.Labels) == 0 {
		resp.Labels = []string{"No data"}
		resp.Values = []int64{0}
	}

	json.NewEncoder(w).Encode(resp)
}

// HandleChartPortscan returns portscan activity chart data
func (h *GOTHHandlers) HandleChartPortscan(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	ports := h.getDroppedByPort()

	resp := ChartDataResponse{
		Labels: make([]string, 0, len(ports)),
		Values: make([]int64, 0, len(ports)),
	}

	// Port number to service name mapping
	portNames := map[int]string{
		22: "SSH", 23: "Telnet", 25: "SMTP", 80: "HTTP", 443: "HTTPS",
		3306: "MySQL", 3389: "RDP", 5432: "PostgreSQL", 6379: "Redis",
		8080: "HTTP-Alt", 21: "FTP", 53: "DNS", 445: "SMB", 1433: "MSSQL",
	}

	for _, p := range ports {
		label := portNames[p.Port]
		if label == "" {
			label = fmt.Sprintf("%d/%s", p.Port, p.Protocol)
		}
		resp.Labels = append(resp.Labels, label)
		resp.Values = append(resp.Values, p.Blocked)
	}

	// If no data, return placeholder
	if len(resp.Labels) == 0 {
		resp.Labels = []string{"No scans detected"}
		resp.Values = []int64{0}
	}

	json.NewEncoder(w).Encode(resp)
}

// HandleChartBansTimeline returns bans over time chart data
func (h *GOTHHandlers) HandleChartBansTimeline(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	// Generate hourly labels for last 24 hours
	resp := ChartDataResponse{
		Labels: make([]string, 24),
		Values: make([]int64, 24),
	}

	now := time.Now()
	for i := 23; i >= 0; i-- {
		resp.Labels[23-i] = now.Add(-time.Duration(i) * time.Hour).Format("15:04")
	}

	// Try to get real ban counts from recent bans
	recentBans := h.getRecentBans()

	// Count bans per hour
	for _, ban := range recentBans {
		if banTime, err := time.Parse("2006-01-02 15:04:05", ban.Timestamp); err == nil {
			hoursAgo := int(now.Sub(banTime).Hours())
			if hoursAgo >= 0 && hoursAgo < 24 {
				idx := 23 - hoursAgo
				if idx >= 0 && idx < 24 {
					resp.Values[idx]++
				}
			}
		}
	}

	json.NewEncoder(w).Encode(resp)
}
