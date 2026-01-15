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

	sess, err := h.SessionStore.Create(user.Username, user.UID, user.Groups)
	if err != nil {
		log.Printf("[GOTH] Session create failed: %v", err)
		http.Redirect(w, r, "/ui/login?error=Session+error", http.StatusSeeOther)
		return
	}

	http.SetCookie(w, &http.Cookie{
		Name:     "session_id",
		Value:    sess.ID,
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
	// Check core service
	if _, err := exec.Command("systemctl", "is-active", "--quiet", "nftban-core").Output(); err != nil {
		return "error"
	}

	// Check nftables has nftban table
	if output, err := exec.Command("nft", "list", "tables").Output(); err == nil {
		if !strings.Contains(string(output), "nftban") {
			return "warning"
		}
	}

	return "active"
}

func (h *GOTHHandlers) getSecurity() ui.SecurityKPIs {
	sec := ui.SecurityKPIs{}

	// Use nftban stats --json for detailed breakdown
	if output, err := execNFTBanCommand("stats", "--json"); err == nil {
		var stats map[string]interface{}
		if json.Unmarshal([]byte(extractJSON(output)), &stats) == nil {
			// Summary section
			if summary, ok := stats["summary"].(map[string]interface{}); ok {
				if active, ok := summary["active_bans"].(float64); ok {
					sec.BansTotal = int(active)
				}
				if total, ok := summary["total_bans"].(float64); ok {
					sec.TotalBansEver = int(total)
				}
			}

			// Breakdown section with IPv4/IPv6 details
			if breakdown, ok := stats["breakdown"].(map[string]interface{}); ok {
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

	// Network stats from metrics pipeline --json
	if output, err := execNFTBanCommand("metrics", "pipeline", "--json"); err == nil {
		var metrics map[string]interface{}
		if json.Unmarshal([]byte(extractJSON(output)), &metrics) == nil {
			if inMbps, ok := metrics["network_in_mbps"].(float64); ok {
				sec.NetworkInMbps = inMbps
			}
			if outMbps, ok := metrics["network_out_mbps"].(float64); ok {
				sec.NetworkOutMbps = outMbps
			}
			if drops, ok := metrics["packet_drop_rate"].(float64); ok {
				sec.PacketDropRate = int(drops)
			}
		}
	}

	return sec
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

	// Try nftban module list --json first
	if output, err := execNFTBanCommand("module", "list", "--json"); err == nil {
		var modList []map[string]interface{}
		if json.Unmarshal([]byte(extractJSON(output)), &modList) == nil {
			for _, m := range modList {
				mod := ui.ModuleStatus{
					LastSync: time.Now().Format("15:04:05"),
				}
				if name, ok := m["name"].(string); ok {
					mod.Name = name
				}
				if desc, ok := m["description"].(string); ok {
					mod.Description = desc
				}
				if status, ok := m["status"].(string); ok {
					mod.Status = status
				}
				if enabled, ok := m["enabled"].(bool); ok {
					mod.Enabled = enabled
				}
				if running, ok := m["running"].(bool); ok {
					mod.Running = running
				}
				if service, ok := m["service"].(string); ok {
					mod.ServiceName = service
				}
				if bans, ok := m["bans_produced"].(float64); ok {
					mod.BansProduced = int(bans)
				}
				if cpu, ok := m["cpu_percent"].(float64); ok {
					mod.CPUPercent = cpu
				}
				if mem, ok := m["memory_mb"].(float64); ok {
					mod.MemoryMB = mem
				}
				if sync, ok := m["last_sync"].(string); ok {
					mod.LastSync = sync
				}
				modules = append(modules, mod)
			}
			if len(modules) > 0 {
				return modules
			}
		}
	}

	// Fallback: known modules with service checks
	knownModules := []struct {
		name        string
		description string
		service     string
	}{
		{"login-monitor", "SSH/FTP login failure detection", "nftban-login-monitor"},
		{"feeds", "Threat intelligence feeds", "nftban-feeds"},
		{"geoblock", "Country-based blocking", ""},
		{"ratelimit", "Connection rate limiting", ""},
	}

	for _, mod := range knownModules {
		info := ui.ModuleStatus{
			Name:        mod.name,
			Description: mod.description,
			ServiceName: mod.service,
			Status:      "inactive",
			LastSync:    time.Now().Format("15:04:05"),
		}

		// Check module status via JSON
		if output, err := execNFTBanCommand("module", "status", mod.name, "--json"); err == nil {
			var modStatus map[string]interface{}
			if json.Unmarshal([]byte(extractJSON(output)), &modStatus) == nil {
				if enabled, ok := modStatus["enabled"].(bool); ok {
					info.Enabled = enabled
				}
				if running, ok := modStatus["running"].(bool); ok {
					info.Running = running
				}
				if status, ok := modStatus["status"].(string); ok {
					info.Status = status
				}
			}
		}

		// Check service status if applicable
		if mod.service != "" && !info.Running {
			if output, err := exec.Command("systemctl", "is-active", mod.service).Output(); err == nil {
				if strings.TrimSpace(string(output)) == "active" {
					info.Running = true
					info.Status = "active"
				}
			}
		}

		modules = append(modules, info)
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

func (h *GOTHHandlers) getHealthData() pages.HealthData {
	data := pages.HealthData{}

	// Services
	data.Services = []ui.HealthItem{
		checkServiceHealth("nftban-core", "NFTBan Core"),
		checkServiceHealth("nftban-login-monitor", "Login Monitor"),
		checkServiceHealth("nftban-ui", "Web UI"),
		checkServiceHealth("nftban-ui-auth", "Auth Service"),
	}

	// Network
	data.Network = []ui.HealthItem{}
	if output, err := exec.Command("nft", "list", "tables").Output(); err == nil {
		if strings.Contains(string(output), "nftban") {
			data.Network = append(data.Network, ui.HealthItem{Name: "NFTables table", Status: "ok"})
		} else {
			data.Network = append(data.Network, ui.HealthItem{Name: "NFTables table", Status: "error"})
		}
	}

	// Permissions
	data.Permissions = []ui.HealthItem{}
	paths := []string{"/etc/nftban", "/var/lib/nftban", "/var/log/nftban"}
	for _, path := range paths {
		if _, err := os.Stat(path); err == nil {
			data.Permissions = append(data.Permissions, ui.HealthItem{Name: path, Status: "ok"})
		} else {
			data.Permissions = append(data.Permissions, ui.HealthItem{Name: path, Status: "error"})
		}
	}

	// Config
	data.Config = []ui.HealthItem{}
	if _, err := os.Stat("/etc/nftban/nftban.conf"); err == nil {
		data.Config = append(data.Config, ui.HealthItem{Name: "Main config", Status: "ok"})
	} else {
		data.Config = append(data.Config, ui.HealthItem{Name: "Main config", Status: "error"})
	}

	// Calculate summary
	for _, items := range [][]ui.HealthItem{data.Services, data.Network, data.Permissions, data.Config} {
		for _, item := range items {
			data.Summary.Total++
			switch item.Status {
			case "ok":
				data.Summary.OK++
			case "warning":
				data.Summary.Warning++
			default:
				data.Summary.Error++
			}
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

func checkServiceHealth(service, name string) ui.HealthItem {
	status := "error"
	if output, err := exec.Command("systemctl", "is-active", service).Output(); err == nil {
		switch strings.TrimSpace(string(output)) {
		case "active":
			status = "ok"
		case "inactive":
			status = "warning"
		}
	}
	return ui.HealthItem{Name: name, Status: status}
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
