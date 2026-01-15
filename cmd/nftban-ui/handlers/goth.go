// =============================================================================
// NFTBan - GOTH GUI Handlers (Professional Dashboard)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="goth"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-15"
// meta:description="GOTH GUI handlers - Go + Templ + HTMX dashboard"
// meta:input="HTTP requests"
// meta:output="HTML fragments via Templ"
// meta:depends="github.com/gorilla/mux,github.com/itcmsgr/nftban/internal/ui"
// meta:inventory.files=""
// meta:inventory.binaries="nftban"
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/nftban.conf"
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
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/gorilla/mux"
	"github.com/itcmsgr/nftban/internal/ui"
	"github.com/itcmsgr/nftban/internal/ui/pages"
	"github.com/itcmsgr/nftban/pkg/auth"
	"github.com/itcmsgr/nftban/pkg/nftbanconf"
	"github.com/itcmsgr/nftban/pkg/session"
)

// GOTHHandlers holds dependencies for GOTH UI handlers
type GOTHHandlers struct {
	Auth         *auth.PAMAuth
	SessionStore *session.Store
}

// Network stats tracking for bandwidth calculation
var (
	lastNetRxBytes uint64
	lastNetTxBytes uint64
	lastNetTime    time.Time
)

// NewGOTHHandlers creates a new GOTHHandlers instance
func NewGOTHHandlers(authService *auth.PAMAuth, sessionStore *session.Store) *GOTHHandlers {
	return &GOTHHandlers{
		Auth:         authService,
		SessionStore: sessionStore,
	}
}

// =============================================================================
// PAGE HANDLERS
// =============================================================================

// HandleLogin renders the login page
func (h *GOTHHandlers) HandleLogin(w http.ResponseWriter, r *http.Request) {
	if cookie, err := r.Cookie("session_id"); err == nil {
		if _, err := h.SessionStore.Get(cookie.Value); err == nil {
			http.Redirect(w, r, "/ui/", http.StatusSeeOther)
			return
		}
	}
	errorMsg := r.URL.Query().Get("error")
	pages.Login(errorMsg).Render(r.Context(), w)
}

// HandleDashboard renders the dashboard
func (h *GOTHHandlers) HandleDashboard(w http.ResponseWriter, r *http.Request) {
	data := h.getDashboardData()
	pages.Dashboard(data).Render(r.Context(), w)
}

// HandleHealth renders health page
func (h *GOTHHandlers) HandleHealth(w http.ResponseWriter, r *http.Request) {
	data := h.getHealthData()
	pages.Health(data).Render(r.Context(), w)
}

// HandleModules renders modules page
func (h *GOTHHandlers) HandleModules(w http.ResponseWriter, r *http.Request) {
	data := h.getModulesData()
	pages.Modules(data).Render(r.Context(), w)
}

// HandleInventory renders inventory page
func (h *GOTHHandlers) HandleInventory(w http.ResponseWriter, r *http.Request) {
	data := h.getInventoryData()
	pages.Inventory(data).Render(r.Context(), w)
}

// HandleFragInventory renders inventory fragment for HTMX
func (h *GOTHHandlers) HandleFragInventory(w http.ResponseWriter, r *http.Request) {
	data := h.getInventoryData()
	pages.InventoryContent(data).Render(r.Context(), w)
}

// =============================================================================
// FRAGMENT HANDLERS (HTMX)
// =============================================================================

func (h *GOTHHandlers) HandleFragIdentity(w http.ResponseWriter, r *http.Request) {
	pages.IdentityFragment(h.getIdentity()).Render(r.Context(), w)
}

func (h *GOTHHandlers) HandleFragSecurity(w http.ResponseWriter, r *http.Request) {
	pages.SecurityFragment(h.getSecurity()).Render(r.Context(), w)
}

func (h *GOTHHandlers) HandleFragNetwork(w http.ResponseWriter, r *http.Request) {
	pages.NetworkFragment(h.getSecurity()).Render(r.Context(), w)
}

func (h *GOTHHandlers) HandleFragResources(w http.ResponseWriter, r *http.Request) {
	pages.ResourcesFragment(h.getResources()).Render(r.Context(), w)
}

func (h *GOTHHandlers) HandleFragModules(w http.ResponseWriter, r *http.Request) {
	pages.ModulesFragment(h.getModulesList()).Render(r.Context(), w)
}

func (h *GOTHHandlers) HandleFragRecent(w http.ResponseWriter, r *http.Request) {
	pages.RecentFragment(h.getRecentBans()).Render(r.Context(), w)
}

// Backwards compat
func (h *GOTHHandlers) HandleFragSummary(w http.ResponseWriter, r *http.Request) {
	pages.SecurityFragment(h.getSecurity()).Render(r.Context(), w)
}

func (h *GOTHHandlers) HandleFragSystem(w http.ResponseWriter, r *http.Request) {
	pages.ResourcesFragment(h.getResources()).Render(r.Context(), w)
}

func (h *GOTHHandlers) HandleFragHealth(w http.ResponseWriter, r *http.Request) {
	pages.HealthFragment(h.getHealthItems()).Render(r.Context(), w)
}

func (h *GOTHHandlers) HandleFragServicesQuick(w http.ResponseWriter, r *http.Request) {
	pages.HealthFragment(h.getHealthItems()).Render(r.Context(), w)
}

func (h *GOTHHandlers) HandleFragBanStats(w http.ResponseWriter, r *http.Request) {
	pages.SecurityFragment(h.getSecurity()).Render(r.Context(), w)
}

func (h *GOTHHandlers) HandleFragWhitelistStats(w http.ResponseWriter, r *http.Request) {
	pages.WhitelistStatsFragment(h.getSecurity()).Render(r.Context(), w)
}

func (h *GOTHHandlers) HandleFragHealthAll(w http.ResponseWriter, r *http.Request) {
	pages.HealthContentFragment(h.getHealthData()).Render(r.Context(), w)
}

func (h *GOTHHandlers) HandleFragModulesList(w http.ResponseWriter, r *http.Request) {
	pages.ModulesListFragment(h.getModulesList()).Render(r.Context(), w)
}

// =============================================================================
// ACTION HANDLERS
// =============================================================================

func (h *GOTHHandlers) HandleActionLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Redirect(w, r, "/ui/login", http.StatusSeeOther)
		return
	}

	username := r.FormValue("username")
	password := r.FormValue("password")

	user, err := h.Auth.Authenticate(username, password)
	if err != nil {
		log.Printf("[GOTH] Login failed for user %s: %v", username, err)
		http.Redirect(w, r, "/ui/login?error=Invalid+credentials", http.StatusSeeOther)
		return
	}

	sess, err := h.SessionStore.Create(user.Username, user.Groups, r.RemoteAddr)
	if err != nil {
		log.Printf("[GOTH] Session create failed: %v", err)
		http.Redirect(w, r, "/ui/login?error=Session+error", http.StatusSeeOther)
		return
	}

	http.SetCookie(w, &http.Cookie{
		Name:     "session_id",
		Value:    sess.Token,
		Path:     "/",
		HttpOnly: true,
		Secure:   true,
		SameSite: http.SameSiteLaxMode,
		MaxAge:   3600,
	})

	log.Printf("[GOTH] User %s logged in successfully", username)
	http.Redirect(w, r, "/ui/", http.StatusSeeOther)
}

func (h *GOTHHandlers) HandleActionLogout(w http.ResponseWriter, r *http.Request) {
	if cookie, err := r.Cookie("session_id"); err == nil {
		h.SessionStore.Delete(cookie.Value)
	}
	http.SetCookie(w, &http.Cookie{
		Name:   "session_id",
		Value:  "",
		Path:   "/",
		MaxAge: -1,
	})
	http.Redirect(w, r, "/ui/login", http.StatusSeeOther)
}

// HandleIPCheck handles quick IP lookup
func (h *GOTHHandlers) HandleIPCheck(w http.ResponseWriter, r *http.Request) {
	ip := r.URL.Query().Get("ip")
	if ip == "" {
		w.Write([]byte(""))
		return
	}

	// Validate IP format
	ip = strings.TrimSpace(ip)
	if !isValidIP(ip) {
		fmt.Fprintf(w, `<span style="color: var(--text-muted);">Invalid IP format</span>`)
		return
	}

	result := ui.IPCheckResult{IP: ip, Status: "clean"}

	// Use nftban check --json for comprehensive status
	if output, err := execNFTBanCommand("check", ip, "--json"); err == nil {
		var checkResult map[string]interface{}
		if json.Unmarshal([]byte(extractJSON(output)), &checkResult) == nil {
			// Parse status
			if status, ok := checkResult["status"].(string); ok {
				statusLower := strings.ToLower(status)
				if strings.Contains(statusLower, "blocked") || strings.Contains(statusLower, "banned") {
					result.Status = "banned"
				} else if strings.Contains(statusLower, "whitelisted") || strings.Contains(statusLower, "allowed") {
					result.Status = "whitelisted"
				}
			}
			// Parse additional info
			if reason, ok := checkResult["reason"].(string); ok {
				result.Reason = reason
			}
			if module, ok := checkResult["module"].(string); ok {
				result.Module = module
			}
			if since, ok := checkResult["banned_since"].(string); ok {
				result.BannedSince = since
			}
			if country, ok := checkResult["country"].(string); ok {
				result.Country = country
			}
			// Check matched set for more context
			if matchedSet, ok := checkResult["matched_set"].(string); ok {
				if strings.Contains(matchedSet, "whitelist") {
					result.Status = "whitelisted"
				} else if strings.Contains(matchedSet, "blacklist") {
					result.Status = "banned"
				}
			}
		}
	}

	// Render result
	pages.IPCheckResultFragment(result).Render(r.Context(), w)
}

// HandleFlushTemp flushes temporary bans
func (h *GOTHHandlers) HandleFlushTemp(w http.ResponseWriter, r *http.Request) {
	log.Printf("[GOTH] Flush temp bans requested")

	// Execute flush command
	if _, err := execNFTBanCommand("flush", "--temp"); err != nil {
		// Try alternative command
		if _, err := execNFTBanCommand("flush-temp"); err != nil {
			log.Printf("[GOTH] Flush temp failed: %v", err)
			w.Header().Set("HX-Trigger", `{"showToast": {"message": "Failed to flush temp bans", "type": "error"}}`)
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
	}

	log.Printf("[GOTH] Temp bans flushed successfully")
	w.Header().Set("HX-Trigger", `{"showToast": {"message": "Temporary bans cleared", "type": "success"}}`)
	w.WriteHeader(http.StatusOK)
}

// HandleRestartService restarts a systemd service
func (h *GOTHHandlers) HandleRestartService(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	serviceName := vars["service"]

	// Validate service name - only allow nftban services
	if !strings.HasPrefix(serviceName, "nftban-") {
		log.Printf("[GOTH] Invalid service name: %s", serviceName)
		w.Header().Set("HX-Trigger", `{"showToast": {"message": "Invalid service", "type": "error"}}`)
		w.WriteHeader(http.StatusBadRequest)
		return
	}

	log.Printf("[GOTH] Restart service requested: %s", serviceName)

	// Execute restart
	if output, err := exec.Command("systemctl", "restart", serviceName).CombinedOutput(); err != nil {
		log.Printf("[GOTH] Restart %s failed: %v - %s", serviceName, err, string(output))
		w.Header().Set("HX-Trigger", fmt.Sprintf(`{"showToast": {"message": "Failed to restart %s", "type": "error"}}`, serviceName))
		w.WriteHeader(http.StatusInternalServerError)
		return
	}

	log.Printf("[GOTH] Service %s restarted successfully", serviceName)
	w.Header().Set("HX-Trigger", fmt.Sprintf(`{"showToast": {"message": "%s restarted", "type": "success"}}`, serviceName))
	w.WriteHeader(http.StatusOK)
}

// HandleHealthFix runs auto-heal to fix issues
func (h *GOTHHandlers) HandleHealthFix(w http.ResponseWriter, r *http.Request) {
	log.Printf("[GOTH] Health auto-fix requested")

	// Execute health check with auto-heal flag
	output, err := execNFTBanCommand("health", "check", "--auto-heal")
	if err != nil {
		log.Printf("[GOTH] Health auto-fix failed: %v - %s", err, output)
		w.Header().Set("HX-Trigger", `{"showToast": {"message": "Auto-heal completed with errors", "type": "warning"}}`)
	} else {
		log.Printf("[GOTH] Health auto-fix completed successfully")
		w.Header().Set("HX-Trigger", `{"showToast": {"message": "Auto-heal completed", "type": "success"}}`)
	}

	// Refresh the health content
	data := h.getHealthData()
	pages.HealthContentFragment(data).Render(r.Context(), w)
}

// RequireSession middleware
func (h *GOTHHandlers) RequireSession(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		cookie, err := r.Cookie("session_id")
		if err != nil {
			http.Redirect(w, r, "/ui/login", http.StatusSeeOther)
			return
		}
		if _, err := h.SessionStore.Get(cookie.Value); err != nil {
			http.Redirect(w, r, "/ui/login", http.StatusSeeOther)
			return
		}
		next(w, r)
	}
}

// =============================================================================
// DATA FETCHERS - Using existing CLI commands only
// =============================================================================

func (h *GOTHHandlers) getDashboardData() ui.DashboardData {
	return ui.DashboardData{
		Identity:   h.getIdentity(),
		Security:   h.getSecurity(),
		Resources:  h.getResources(),
		Modules:    h.getModulesList(),
		RecentBans: h.getRecentBans(),
		Theme:      "dark",
	}
}

func (h *GOTHHandlers) getIdentity() ui.SystemIdentity {
	id := ui.SystemIdentity{
		Hostname:      "unknown",
		Kernel:        "unknown",
		Uptime:        "N/A",
		UptimeSeconds: 0,
		NFTBanVersion: "1.0.0",
		PanelMode:     "active",
		Heartbeat:     true,
	}

	// Try nftban status --json first for consolidated data
	if output, err := execNFTBanCommand("status", "--json"); err == nil {
		var status map[string]interface{}
		if json.Unmarshal([]byte(extractJSON(output)), &status) == nil {
			if hostname, ok := status["hostname"].(string); ok {
				id.Hostname = hostname
			}
			if version, ok := status["version"].(string); ok {
				id.NFTBanVersion = version
			}
			// System section
			if sys, ok := status["system"].(map[string]interface{}); ok {
				if kernel, ok := sys["kernel"].(string); ok {
					id.Kernel = kernel
				}
				if uptime, ok := sys["uptime"].(string); ok {
					id.Uptime = uptime
				}
			}
		}
	}

	// Fallback for hostname
	if id.Hostname == "unknown" {
		if output, err := exec.Command("hostname").Output(); err == nil {
			id.Hostname = strings.TrimSpace(string(output))
		}
	}

	// Fallback for kernel
	if id.Kernel == "unknown" {
		if output, err := exec.Command("uname", "-r").Output(); err == nil {
			id.Kernel = strings.TrimSpace(string(output))
		}
	}

	// Fallback for uptime
	if id.Uptime == "N/A" {
		if output, err := exec.Command("uptime", "-p").Output(); err == nil {
			id.Uptime = strings.TrimSpace(string(output))
		}
	}

	// Uptime seconds for JS counter (always from /proc)
	if content, err := os.ReadFile("/proc/uptime"); err == nil {
		parts := strings.Fields(string(content))
		if len(parts) > 0 {
			if secs, err := strconv.ParseFloat(parts[0], 64); err == nil {
				id.UptimeSeconds = int64(secs)
			}
		}
	}

	// Fallback for version
	if id.NFTBanVersion == "1.0.0" {
		if output, err := execNFTBanCommand("--version"); err == nil {
			id.NFTBanVersion = strings.TrimSpace(string(output))
		}
	}

	// Panel mode based on service status
	id.PanelMode = h.getPanelMode()

	return id
}

func (h *GOTHHandlers) getPanelMode() string {
	// Primary check: nftables must be working
	output, err := exec.Command("nft", "list", "tables").Output()
	if err != nil {
		return "error" // nftables not working at all
	}

	// Check if nftban table exists
	hasTable := strings.Contains(string(output), "nftban")
	if !hasTable {
		return "warning" // nftables works but nftban not initialized
	}

	// Optional: check if core daemon is running (degraded if not)
	if err := exec.Command("systemctl", "is-active", "--quiet", "nftban-core").Run(); err != nil {
		// Daemon not running but nftables is configured - still functional
		return "active" // CLI-only mode is fine
	}

	return "active"
}

func (h *GOTHHandlers) getSecurity() ui.SecurityKPIs {
	sec := ui.SecurityKPIs{}

	// Use nftban stats --json for detailed breakdown
	if output, err := execNFTBanCommand("stats", "--json"); err == nil {
		var stats map[string]interface{}
		if json.Unmarshal([]byte(extractJSON(output)), &stats) == nil {
			// Stats JSON wraps data in "data" field
			data, hasData := stats["data"].(map[string]interface{})
			if !hasData {
				data = stats // Fallback to root level
			}

			// Summary section
			if summary, ok := data["summary"].(map[string]interface{}); ok {
				if active, ok := summary["active_bans"].(float64); ok {
					sec.BansTotal = int(active)
				}
				if total, ok := summary["total_bans"].(float64); ok {
					sec.TotalBansEver = int(total)
				}
			}

			// Breakdown section with IPv4/IPv6 details
			if breakdown, ok := data["breakdown"].(map[string]interface{}); ok {
				// Blacklist (main bans)
				if blacklist, ok := breakdown["blacklist"].(map[string]interface{}); ok {
					if v4, ok := blacklist["ipv4"].(float64); ok {
						sec.BansIPv4 = int(v4)
					}
					if v6, ok := blacklist["ipv6"].(float64); ok {
						sec.BansIPv6 = int(v6)
					}
				}

				// Whitelist
				if whitelist, ok := breakdown["whitelist"].(map[string]interface{}); ok {
					if total, ok := whitelist["total"].(float64); ok {
						sec.WhitelistTotal = int(total)
					}
					if v4, ok := whitelist["ipv4"].(float64); ok {
						sec.WhitelistIPv4 = int(v4)
					}
					if v6, ok := whitelist["ipv6"].(float64); ok {
						sec.WhitelistIPv6 = int(v6)
					}
				}
			}
		}
	}

	// Fallback to status --json if stats didn't work
	if sec.BansTotal == 0 {
		if output, err := execNFTBanCommand("status", "--json"); err == nil {
			var status map[string]interface{}
			if json.Unmarshal([]byte(extractJSON(output)), &status) == nil {
				if fw, ok := status["firewall"].(map[string]interface{}); ok {
					if bans, ok := fw["banned_ips"].(float64); ok {
						sec.BansTotal = int(bans)
					}
					if wl, ok := fw["whitelist_ips"].(float64); ok {
						sec.WhitelistTotal = int(wl)
					}
				}
			}
		}
	}

	// Fallback: if no IPv4/IPv6 split, use total
	if sec.BansIPv4 == 0 && sec.BansIPv6 == 0 && sec.BansTotal > 0 {
		sec.BansIPv4 = sec.BansTotal
	}
	if sec.WhitelistIPv4 == 0 && sec.WhitelistTotal > 0 {
		sec.WhitelistIPv4 = sec.WhitelistTotal
	}

	// Network stats from /sys/class/net
	sec.NetworkInMbps, sec.NetworkOutMbps = getNetworkBandwidth()

	// Packet drop rate from nftables counters
	if output, err := exec.Command("nft", "list", "counters").CombinedOutput(); err == nil {
		// Count drop entries (rough estimate)
		sec.PacketDropRate = strings.Count(string(output), "drop")
	}

	return sec
}

// getNetworkBandwidth calculates network bandwidth in Mbps from all interfaces
func getNetworkBandwidth() (inMbps, outMbps float64) {
	var totalRxBytes, totalTxBytes uint64

	// Read /sys/class/net to get all interfaces
	entries, err := os.ReadDir("/sys/class/net")
	if err != nil {
		return 0, 0
	}

	for _, entry := range entries {
		iface := entry.Name()
		// Skip loopback and virtual interfaces
		if iface == "lo" || strings.HasPrefix(iface, "veth") ||
			strings.HasPrefix(iface, "docker") || strings.HasPrefix(iface, "br-") ||
			strings.HasPrefix(iface, "virbr") {
			continue
		}

		rxPath := fmt.Sprintf("/sys/class/net/%s/statistics/rx_bytes", iface)
		txPath := fmt.Sprintf("/sys/class/net/%s/statistics/tx_bytes", iface)

		if rxData, err := os.ReadFile(rxPath); err == nil {
			if v, err := strconv.ParseUint(strings.TrimSpace(string(rxData)), 10, 64); err == nil {
				totalRxBytes += v
			}
		}
		if txData, err := os.ReadFile(txPath); err == nil {
			if v, err := strconv.ParseUint(strings.TrimSpace(string(txData)), 10, 64); err == nil {
				totalTxBytes += v
			}
		}
	}

	now := time.Now()

	// Calculate rate if we have previous measurement
	if !lastNetTime.IsZero() {
		elapsed := now.Sub(lastNetTime).Seconds()
		if elapsed > 0 {
			// Calculate bytes per second, then convert to Mbps
			rxRate := float64(totalRxBytes-lastNetRxBytes) / elapsed
			txRate := float64(totalTxBytes-lastNetTxBytes) / elapsed
			inMbps = (rxRate * 8) / 1000000  // bits to Mbps
			outMbps = (txRate * 8) / 1000000
		}
	}

	// Store current values for next calculation
	lastNetRxBytes = totalRxBytes
	lastNetTxBytes = totalTxBytes
	lastNetTime = now

	return inMbps, outMbps
}

func (h *GOTHHandlers) getResources() ui.ResourceStats {
	res := ui.ResourceStats{
		DiskPath: "/var/log",
	}

	// Use nftban watchdog check --json for system resources
	if output, err := execNFTBanCommand("watchdog", "check", "--json"); err == nil {
		var wd map[string]interface{}
		if json.Unmarshal([]byte(extractJSON(output)), &wd) == nil {
			// Load average
			if load, ok := wd["load"].(map[string]interface{}); ok {
				if v, ok := load["1m"].(string); ok {
					res.CPULoadAvg1, _ = strconv.ParseFloat(v, 64)
				}
				if v, ok := load["5m"].(string); ok {
					res.CPULoadAvg5, _ = strconv.ParseFloat(v, 64)
				}
				if v, ok := load["15m"].(string); ok {
					res.CPULoadAvg15, _ = strconv.ParseFloat(v, 64)
				}
			}

			// Memory
			if mem, ok := wd["memory"].(map[string]interface{}); ok {
				if v, ok := mem["used_percent"].(string); ok {
					res.RAMPercent, _ = strconv.ParseFloat(v, 64)
				}
				if v, ok := mem["total_mb"].(string); ok {
					if mb, err := strconv.ParseFloat(v, 64); err == nil {
						res.RAMTotalGB = mb / 1024
					}
				}
				if v, ok := mem["available_mb"].(string); ok {
					if mb, err := strconv.ParseFloat(v, 64); err == nil {
						res.RAMUsedGB = res.RAMTotalGB - (mb / 1024)
					}
				}
			}

			// IO wait as CPU indicator
			if iowait, ok := wd["iowait"].(map[string]interface{}); ok {
				if v, ok := iowait["percent"].(string); ok {
					res.CPUPercent, _ = strconv.ParseFloat(v, 64)
				}
			}

			// Disk
			if disk, ok := wd["disk"].(map[string]interface{}); ok {
				if v, ok := disk["used_percent"].(string); ok {
					res.DiskPercent, _ = strconv.ParseFloat(v, 64)
				}
				if path, ok := disk["path"].(string); ok {
					res.DiskPath = path
				}
			}
		}
	}

	// Fallback for CPU from /proc/stat (real CPU usage)
	if res.CPUPercent == 0 {
		if output, err := exec.Command("sh", "-c", "grep 'cpu ' /proc/stat | awk '{printf \"%.1f\", ($2+$4)*100/($2+$4+$5)}'").Output(); err == nil {
			if val, err := strconv.ParseFloat(strings.TrimSpace(string(output)), 64); err == nil {
				res.CPUPercent = val
			}
		}
	}

	// Fallback for load average
	if res.CPULoadAvg1 == 0 {
		if content, err := os.ReadFile("/proc/loadavg"); err == nil {
			parts := strings.Fields(string(content))
			if len(parts) >= 3 {
				res.CPULoadAvg1, _ = strconv.ParseFloat(parts[0], 64)
				res.CPULoadAvg5, _ = strconv.ParseFloat(parts[1], 64)
				res.CPULoadAvg15, _ = strconv.ParseFloat(parts[2], 64)
			}
		}
	}

	// Fallback for RAM
	if res.RAMTotalGB == 0 {
		if content, err := os.ReadFile("/proc/meminfo"); err == nil {
			var memTotal, memAvail float64
			lines := strings.Split(string(content), "\n")
			for _, line := range lines {
				if strings.HasPrefix(line, "MemTotal:") {
					parts := strings.Fields(line)
					if len(parts) >= 2 {
						if val, err := strconv.ParseFloat(parts[1], 64); err == nil {
							memTotal = val / 1024 / 1024
						}
					}
				}
				if strings.HasPrefix(line, "MemAvailable:") {
					parts := strings.Fields(line)
					if len(parts) >= 2 {
						if val, err := strconv.ParseFloat(parts[1], 64); err == nil {
							memAvail = val / 1024 / 1024
						}
					}
				}
			}
			res.RAMTotalGB = memTotal
			res.RAMUsedGB = memTotal - memAvail
			if memTotal > 0 {
				res.RAMPercent = (res.RAMUsedGB / memTotal) * 100
			}
		}
	}

	// Fallback for Disk
	if res.DiskPercent == 0 {
		if output, err := exec.Command("df", "-BG", "/var/log").Output(); err == nil {
			lines := strings.Split(string(output), "\n")
			if len(lines) >= 2 {
				fields := strings.Fields(lines[1])
				if len(fields) >= 5 {
					res.DiskTotalGB, _ = strconv.ParseFloat(strings.TrimSuffix(fields[1], "G"), 64)
					res.DiskUsedGB, _ = strconv.ParseFloat(strings.TrimSuffix(fields[2], "G"), 64)
					res.DiskPercent, _ = strconv.ParseFloat(strings.TrimSuffix(fields[4], "%"), 64)
				}
			}
		}
	}

	// NFTBan daemon stats from watchdog stats --json
	if output, err := execNFTBanCommand("watchdog", "stats", "--json"); err == nil {
		var stats map[string]interface{}
		if json.Unmarshal([]byte(extractJSON(output)), &stats) == nil {
			if cpu, ok := stats["cpu_percent"].(float64); ok {
				res.NFTBanCPU = cpu
			}
			if mem, ok := stats["memory_mb"].(float64); ok {
				res.NFTBanMemMB = mem
			}
			if uptime, ok := stats["uptime"].(string); ok {
				res.NFTBanUptime = uptime
			}
		}
	}

	// Fallback for NFTBan process stats
	if res.NFTBanCPU == 0 {
		if output, err := exec.Command("sh", "-c", "ps aux | grep 'nftban' | grep -v grep | head -1 | awk '{print $3, $6}'").Output(); err == nil {
			parts := strings.Fields(string(output))
			if len(parts) >= 2 {
				res.NFTBanCPU, _ = strconv.ParseFloat(parts[0], 64)
				if mem, err := strconv.ParseFloat(parts[1], 64); err == nil {
					res.NFTBanMemMB = mem / 1024
				}
			}
		}
	}

	return res
}

func (h *GOTHHandlers) getModulesList() []ui.ModuleStatus {
	modules := []ui.ModuleStatus{}
	now := time.Now().Format("15:04:05")

	// Get comprehensive status from nftban status --json
	if output, err := execNFTBanCommand("status", "--json"); err == nil {
		var status map[string]interface{}
		if json.Unmarshal([]byte(extractJSON(output)), &status) == nil {
			// Parse services section
			if services, ok := status["services"].(map[string]interface{}); ok {
				// nftables
				if svc, ok := services["nftables"].(map[string]interface{}); ok {
					mod := ui.ModuleStatus{
						Name:        "nftables",
						Description: "Packet filtering firewall",
						LastSync:    now,
					}
					if st, ok := svc["status"].(string); ok {
						mod.Status = st
						mod.Running = st == "active"
						mod.Enabled = true
					}
					modules = append(modules, mod)
				}

				// Login Monitor
				if svc, ok := services["login_monitor"].(map[string]interface{}); ok {
					mod := ui.ModuleStatus{
						Name:        "login-monitor",
						Description: "SSH/FTP login failure detection",
						ServiceName: "nftban-login-monitor",
						LastSync:    now,
					}
					if st, ok := svc["status"].(string); ok {
						mod.Status = st
						mod.Running = st == "active"
						mod.Enabled = st == "active"
					}
					if pid, ok := svc["pid"].(float64); ok && pid > 0 {
						mod.Running = true
					}
					if mem, ok := svc["memory_mb"].(float64); ok {
						mod.MemoryMB = mem
					}
					modules = append(modules, mod)
				}

				// Metrics Exporter
				if svc, ok := services["metrics_exporter"].(map[string]interface{}); ok {
					mod := ui.ModuleStatus{
						Name:        "metrics-exporter",
						Description: "Prometheus metrics exporter",
						ServiceName: "nftban-metrics-exporter",
						LastSync:    now,
					}
					if st, ok := svc["status"].(string); ok {
						mod.Status = st
						mod.Running = st == "active"
						mod.Enabled = st == "active" || st == "timer"
					}
					modules = append(modules, mod)
				}
			}

			// Parse protection section
			if protection, ok := status["protection"].(map[string]interface{}); ok {
				// Suricata IDS
				if suri, ok := protection["suricata"].(map[string]interface{}); ok {
					mod := ui.ModuleStatus{
						Name:        "suricata",
						Description: "Network intrusion detection",
						ServiceName: "nftban-suricata",
						LastSync:    now,
					}
					if enabled, ok := suri["enabled"].(bool); ok {
						mod.Enabled = enabled
						if enabled {
							mod.Status = "active"
							mod.Running = true
						} else {
							mod.Status = "inactive"
						}
					}
					modules = append(modules, mod)
				}

				// GeoIP/GeoBan
				if geo, ok := protection["geoip"].(map[string]interface{}); ok {
					mod := ui.ModuleStatus{
						Name:        "geoban",
						Description: "Country-based IP blocking",
						LastSync:    now,
					}
					if installed, ok := geo["installed"].(bool); ok {
						mod.Enabled = installed
						if installed {
							mod.Status = "active"
							mod.Running = true
						} else {
							mod.Status = "inactive"
						}
					}
					if countries, ok := geo["blocked_countries"].(float64); ok {
						mod.BansProduced = int(countries)
					}
					modules = append(modules, mod)
				}

				// Feeds
				if feeds, ok := protection["feeds"].(map[string]interface{}); ok {
					mod := ui.ModuleStatus{
						Name:        "threat-feeds",
						Description: "Threat intelligence feeds",
						ServiceName: "nftban-core-feeds",
						LastSync:    now,
					}
					if count, ok := feeds["count"].(float64); ok {
						mod.BansProduced = int(count)
						mod.Enabled = count > 0
						if count > 0 {
							mod.Status = "active"
							mod.Running = true
						} else {
							mod.Status = "inactive"
						}
					}
					modules = append(modules, mod)
				}
			}

			// Check timers for portscan and ddos status
			if timers, ok := status["timers"].(map[string]interface{}); ok {
				// Add portscan module based on config check
				portscanMod := ui.ModuleStatus{
					Name:        "portscan",
					Description: "Port scan detection",
					LastSync:    now,
					Status:      "inactive",
				}
				// Check if portscan is enabled via config
				if output, err := execNFTBanCommand("config", "get", "portscan.enabled"); err == nil {
					if strings.Contains(string(output), "true") || strings.Contains(string(output), "1") {
						portscanMod.Enabled = true
						portscanMod.Status = "active"
						portscanMod.Running = true
					}
				}
				modules = append(modules, portscanMod)

				// Add ddos module
				ddosMod := ui.ModuleStatus{
					Name:        "ddos",
					Description: "DDoS protection",
					LastSync:    now,
					Status:      "inactive",
				}
				if output, err := execNFTBanCommand("config", "get", "ddos.enabled"); err == nil {
					if strings.Contains(string(output), "true") || strings.Contains(string(output), "1") {
						ddosMod.Enabled = true
						ddosMod.Status = "active"
						ddosMod.Running = true
					}
				}
				modules = append(modules, ddosMod)

				// Show timer status
				_ = timers // Used above for reference
			}
		}
	}

	// If no modules found or nftables not in list, add direct nftables check
	hasNftables := false
	for _, m := range modules {
		if m.Name == "nftables" {
			hasNftables = true
			break
		}
	}

	if !hasNftables {
		// Direct nftables check as fallback
		nftMod := ui.ModuleStatus{
			Name:        "nftables",
			Description: "Packet filtering firewall",
			LastSync:    now,
			Status:      "error",
		}

		// Check if nftables service is running
		if err := exec.Command("systemctl", "is-active", "--quiet", "nftables").Run(); err == nil {
			nftMod.Status = "active"
			nftMod.Running = true
			nftMod.Enabled = true

			// Check if nftban table exists
			if output, err := exec.Command("nft", "list", "tables").Output(); err == nil {
				if !strings.Contains(string(output), "nftban") {
					nftMod.Status = "warning" // nftables running but no nftban table
				}
			}
		} else {
			// Check if nft command works at all
			if _, err := exec.Command("nft", "list", "tables").Output(); err == nil {
				nftMod.Status = "active" // nft works even if service not "active"
				nftMod.Running = true
			}
		}

		// Prepend nftables to modules list
		modules = append([]ui.ModuleStatus{nftMod}, modules...)
	}

	// If still no modules, add minimal fallback
	if len(modules) == 0 {
		modules = []ui.ModuleStatus{
			{Name: "nftables", Description: "Packet filtering", Status: "unknown", LastSync: now},
		}
	}

	return modules
}

func (h *GOTHHandlers) getRecentBans() []ui.RecentBan {
	bans := []ui.RecentBan{}

	// Try to get recent bans from CLI
	if output, err := execNFTBanCommand("list", "--recent=10", "--json"); err == nil {
		var banData []map[string]interface{}
		if json.Unmarshal([]byte(extractJSON(output)), &banData) == nil {
			for _, b := range banData {
				ban := ui.RecentBan{}
				if ip, ok := b["ip"].(string); ok {
					ban.IP = ip
				}
				if country, ok := b["country"].(string); ok {
					ban.Country = country
				}
				if reason, ok := b["reason"].(string); ok {
					ban.Reason = reason
				}
				if module, ok := b["module"].(string); ok {
					ban.Module = module
				}
				if ts, ok := b["timestamp"].(string); ok {
					ban.Timestamp = ts
				} else if ts, ok := b["timestamp"].(float64); ok {
					ban.Timestamp = time.Unix(int64(ts), 0).Format("15:04:05")
				}
				bans = append(bans, ban)
			}
		}
	}

	return bans
}

func (h *GOTHHandlers) getHealthItems() []ui.HealthItem {
	items := []ui.HealthItem{}

	// Service checks
	services := []struct {
		service string
		name    string
	}{
		{"nftban-core", "Core"},
		{"nftban-login-monitor", "Login Monitor"},
		{"nftban-ui", "Web UI"},
	}

	for _, svc := range services {
		status := "error"
		if output, err := exec.Command("systemctl", "is-active", svc.service).Output(); err == nil {
			switch strings.TrimSpace(string(output)) {
			case "active":
				status = "ok"
			case "inactive":
				status = "warning"
			}
		}
		items = append(items, ui.HealthItem{Name: svc.name, Status: status})
	}

	// NFTables check
	if output, err := exec.Command("nft", "list", "tables").Output(); err == nil {
		if strings.Contains(string(output), "nftban") {
			items = append(items, ui.HealthItem{Name: "NFTables", Status: "ok"})
		} else {
			items = append(items, ui.HealthItem{Name: "NFTables", Status: "warning"})
		}
	} else {
		items = append(items, ui.HealthItem{Name: "NFTables", Status: "error"})
	}

	return items
}

func (h *GOTHHandlers) getHealthData() ui.HealthData {
	data := ui.HealthData{
		Timestamp:     time.Now().Format("2006-01-02 15:04:05"),
		OverallStatus: "ok",
		ExitCode:      0,
	}

	// Use nftban health check --json for comprehensive health data
	if output, err := execNFTBanCommand("health", "check", "--json"); err == nil {
		var healthJSON map[string]interface{}
		if json.Unmarshal([]byte(extractJSON(output)), &healthJSON) == nil {
			// Timestamp
			if ts, ok := healthJSON["timestamp"].(string); ok {
				data.Timestamp = ts
			}

			// Overall status
			if status, ok := healthJSON["overall_status"].(string); ok {
				data.OverallStatus = status
			}

			// Exit code
			if exitCode, ok := healthJSON["exit_code"].(float64); ok {
				data.ExitCode = int(exitCode)
			}

			// Summary counts
			if summary, ok := healthJSON["summary"].(map[string]interface{}); ok {
				if errors, ok := summary["errors"].(float64); ok {
					data.ErrorCount = int(errors)
				}
				if warnings, ok := summary["warnings"].(float64); ok {
					data.WarningCount = int(warnings)
				}
			}

			// Parse checks section
			if checks, ok := healthJSON["checks"].(map[string]interface{}); ok {
				for name, checkData := range checks {
					if checkMap, ok := checkData.(map[string]interface{}); ok {
						check := ui.HealthCheck{
							Name: name,
						}
						if status, ok := checkMap["status"].(string); ok {
							check.Status = status
						}
						if exitCode, ok := checkMap["exit_code"].(float64); ok {
							check.ExitCode = int(exitCode)
						}
						if message, ok := checkMap["message"].(string); ok {
							check.Message = message
						}
						data.Checks = append(data.Checks, check)
					}
				}
			}

			// Parse errors array
			if errors, ok := healthJSON["errors"].([]interface{}); ok {
				for _, err := range errors {
					if errStr, ok := err.(string); ok {
						data.Errors = append(data.Errors, errStr)
					}
				}
			}

			// Parse warnings array
			if warnings, ok := healthJSON["warnings"].([]interface{}); ok {
				for _, warn := range warnings {
					if warnStr, ok := warn.(string); ok {
						data.Warnings = append(data.Warnings, warnStr)
					}
				}
			}
		}
	} else {
		// Fallback if health check command fails
		data.OverallStatus = "error"
		data.ExitCode = 1
		data.ErrorCount = 1
		data.Errors = append(data.Errors, "Health check command failed: "+err.Error())

		// Still try to get basic service status
		services := []struct {
			service string
			name    string
		}{
			{"nftban-core", "core"},
			{"nftban-login-monitor", "login_monitor"},
			{"nftban-ui", "ui"},
		}

		for _, svc := range services {
			check := ui.HealthCheck{Name: svc.name}
			if output, err := exec.Command("systemctl", "is-active", svc.service).Output(); err == nil {
				switch strings.TrimSpace(string(output)) {
				case "active":
					check.Status = "ok"
				case "inactive":
					check.Status = "warning"
					check.Message = "Service inactive"
				default:
					check.Status = "error"
					check.Message = "Service not running"
				}
			} else {
				check.Status = "error"
				check.Message = "Unable to check service"
			}
			data.Checks = append(data.Checks, check)
		}
	}

	return data
}

func (h *GOTHHandlers) getModulesData() pages.ModulesData {
	modules := h.getModulesList()
	data := pages.ModulesData{Modules: modules}

	for _, mod := range modules {
		data.Summary.Total++
		if mod.Enabled {
			data.Summary.Enabled++
			if mod.Running {
				data.Summary.Running++
			}
		} else {
			data.Summary.Disabled++
		}
	}

	return data
}

// =============================================================================
// HELPERS
// =============================================================================

func execNFTBanCommand(args ...string) (string, error) {
	// Use central config for CLI path - same as pkg/api/handlers.go
	cfg := nftbanconf.MustLoad()
	cmd := exec.Command(cfg.Bin, args...)
	output, err := cmd.CombinedOutput()

	outputStr := string(output)
	if err != nil {
		// Ignore netlink socket warnings - these are harmless
		if strings.Contains(outputStr, "Unable to initialize Netlink socket") {
			return outputStr, nil
		}
		return outputStr, err
	}
	return outputStr, nil
}

// extractJSON extracts JSON from CLI output (handles warnings/banners before JSON)
func extractJSON(output string) string {
	output = strings.TrimSpace(output)
	startIdx := strings.Index(output, "{")
	endIdx := strings.LastIndex(output, "}")
	if startIdx == -1 || endIdx == -1 || startIdx > endIdx {
		return "{}"
	}
	return output[startIdx : endIdx+1]
}


func isValidIP(ip string) bool {
	// Simple IPv4/IPv6 validation
	ip = strings.TrimSpace(ip)
	if ip == "" {
		return false
	}
	// IPv4: check for dots and numbers
	if strings.Contains(ip, ".") {
		parts := strings.Split(ip, ".")
		if len(parts) != 4 {
			return false
		}
		for _, p := range parts {
			if n, err := strconv.Atoi(p); err != nil || n < 0 || n > 255 {
				return false
			}
		}
		return true
	}
	// IPv6: check for colons
	if strings.Contains(ip, ":") {
		return true // Basic check - let the CLI validate fully
	}
	return false
}

// =============================================================================
// INVENTORY DATA
// =============================================================================

func (h *GOTHHandlers) getInventoryData() ui.InventoryData {
	data := ui.InventoryData{}

	// Get services from systemctl
	data.Services = h.getServicesList()

	// Get timers from systemctl
	data.Timers = h.getTimersList()

	// Get binaries
	data.Binaries = h.getBinariesList()

	// Get config files
	data.Configs = h.getConfigsList()

	// Get FHS data (limited to avoid too much data)
	data.FHS = h.getFHSList()

	return data
}

func (h *GOTHHandlers) getServicesList() []ui.ServiceInfo {
	services := []ui.ServiceInfo{}

	// NFTBan services to check
	svcNames := []struct {
		name string
		desc string
	}{
		{"nftables", "Packet filtering firewall"},
		{"nftban-ui", "Web GUI server"},
		{"nftban-api", "REST API server"},
		{"nftban-login-monitor", "Login failure detection"},
		{"nftban-suricata", "Suricata IDS integration"},
		{"prometheus", "Metrics database"},
		{"node_exporter", "System metrics exporter"},
	}

	for _, s := range svcNames {
		svc := ui.ServiceInfo{
			Name:        s.name,
			Description: s.desc,
			Status:      "inactive",
		}

		// Check if service exists and get status
		if output, err := exec.Command("systemctl", "show", s.name,
			"--property=ActiveState,MainPID,MemoryCurrent,ActiveEnterTimestamp").Output(); err == nil {

			lines := strings.Split(string(output), "\n")
			for _, line := range lines {
				parts := strings.SplitN(line, "=", 2)
				if len(parts) != 2 {
					continue
				}
				key, val := parts[0], parts[1]
				switch key {
				case "ActiveState":
					svc.Status = val
				case "MainPID":
					if pid, err := strconv.Atoi(val); err == nil {
						svc.PID = pid
					}
				case "MemoryCurrent":
					if mem, err := strconv.ParseUint(val, 10, 64); err == nil && mem > 0 {
						svc.MemoryMB = float64(mem) / 1024 / 1024
					}
				case "ActiveEnterTimestamp":
					if val != "" && val != "n/a" {
						// Parse timestamp and calculate uptime
						svc.Uptime = val
					}
				}
			}
		}

		services = append(services, svc)
	}

	return services
}

func (h *GOTHHandlers) getTimersList() []ui.TimerInfo {
	timers := []ui.TimerInfo{}

	// NFTBan timers
	timerNames := []struct {
		name string
		desc string
	}{
		{"nftban-health.timer", "Health checks & auto-heal"},
		{"nftban-maintenance.timer", "Maintenance tasks"},
		{"nftban-metrics-exporter.timer", "Metrics collection"},
		{"nftban-core-feeds.timer", "Threat feed sync"},
		{"nftban-core-geoip.timer", "GeoIP database updates"},
		{"nftban-queue.timer", "Ban queue processing"},
	}

	for _, t := range timerNames {
		timer := ui.TimerInfo{
			Name:        strings.TrimSuffix(t.name, ".timer"),
			Description: t.desc,
			Status:      "inactive",
		}

		// Check timer status
		if output, err := exec.Command("systemctl", "show", t.name,
			"--property=ActiveState,NextElapseUSecRealtime,LastTriggerUSec").Output(); err == nil {

			lines := strings.Split(string(output), "\n")
			for _, line := range lines {
				parts := strings.SplitN(line, "=", 2)
				if len(parts) != 2 {
					continue
				}
				key, val := parts[0], parts[1]
				switch key {
				case "ActiveState":
					timer.Status = val
				case "NextElapseUSecRealtime":
					if val != "" && val != "n/a" {
						timer.NextRun = val
					}
				case "LastTriggerUSec":
					if val != "" && val != "n/a" {
						timer.LastRun = val
					}
				}
			}
		}

		// Check if timer is enabled
		if output, err := exec.Command("systemctl", "is-enabled", t.name).Output(); err == nil {
			if strings.TrimSpace(string(output)) == "enabled" && timer.Status == "inactive" {
				timer.Status = "enabled"
			}
		}

		timers = append(timers, timer)
	}

	return timers
}

func (h *GOTHHandlers) getBinariesList() []ui.BinaryInfo {
	binaries := []ui.BinaryInfo{}

	// NFTBan binaries to check
	binPaths := []struct {
		name string
		path string
	}{
		{"nftban", "/usr/sbin/nftban"},
		{"nftban-ui", "/usr/sbin/nftban-ui"},
		{"nftban-core", "/usr/sbin/nftban-core"},
		{"nftban-api", "/usr/sbin/nftban-api"},
		{"nft", "/usr/sbin/nft"},
	}

	for _, b := range binPaths {
		bin := ui.BinaryInfo{
			Name: b.name,
			Path: b.path,
		}

		// Check if binary exists and get info
		if info, err := os.Stat(b.path); err == nil {
			bin.Size = formatBytes(info.Size())

			// Try to get version
			if output, err := exec.Command(b.path, "--version").Output(); err == nil {
				ver := strings.TrimSpace(string(output))
				if len(ver) > 50 {
					ver = ver[:50]
				}
				bin.Version = ver
			}
		} else {
			bin.Version = "not installed"
		}

		binaries = append(binaries, bin)
	}

	return binaries
}

func (h *GOTHHandlers) getConfigsList() []ui.ConfigInfo {
	configs := []ui.ConfigInfo{}

	// Important config files
	cfgPaths := []struct {
		name string
		path string
	}{
		{"nftban.conf", "/etc/nftban/nftban.conf"},
		{"ui.conf", "/etc/nftban/ui.conf"},
		{"services.conf", "/etc/nftban/conf.d/services.conf"},
		{"trust.conf", "/etc/nftban/conf.d/trust.conf"},
		{"login/main.conf", "/etc/nftban/conf.d/login/main.conf"},
		{"ddos/main.conf", "/etc/nftban/conf.d/ddos/main.conf"},
		{"portscan/main.conf", "/etc/nftban/conf.d/portscan/main.conf"},
	}

	for _, c := range cfgPaths {
		cfg := ui.ConfigInfo{
			Name: c.name,
			Path: c.path,
		}

		if info, err := os.Stat(c.path); err == nil {
			cfg.Size = formatBytes(info.Size())
			cfg.Modified = info.ModTime().Format("2006-01-02 15:04")
		} else {
			cfg.Modified = "not found"
		}

		configs = append(configs, cfg)
	}

	return configs
}

func (h *GOTHHandlers) getFHSList() []ui.FHSItem {
	fhs := []ui.FHSItem{}

	// Key FHS directories
	dirs := []string{
		"/etc/nftban",
		"/var/lib/nftban",
		"/var/log/nftban",
		"/var/cache/nftban",
		"/run/nftban",
		"/usr/lib/nftban",
		"/usr/share/nftban",
	}

	for _, dir := range dirs {
		item := ui.FHSItem{
			Path:   dir,
			Status: "ok",
		}

		if info, err := os.Stat(dir); err == nil {
			mode := info.Mode()
			item.Actual = fmt.Sprintf("%04o", mode.Perm())
			item.Expected = "0755"
			if item.Actual != "0755" && item.Actual != "0750" {
				item.Status = "warning"
			}
		} else {
			item.Status = "error"
			item.Actual = "missing"
			item.Notes = "Directory does not exist"
		}

		fhs = append(fhs, item)
	}

	return fhs
}

func formatBytes(bytes int64) string {
	const unit = 1024
	if bytes < unit {
		return fmt.Sprintf("%d B", bytes)
	}
	div, exp := int64(unit), 0
	for n := bytes / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(bytes)/float64(div), "KMGTPE"[exp])
}
