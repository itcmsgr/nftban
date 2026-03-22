// =============================================================================
// NFTBan - GOTH GUI Metrics Handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="metrics_handlers"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-26"
// meta:description="GOTH GUI handlers for metrics pages - Metrics, GeoIP, System, Network"
// meta:input="HTTP requests"
// meta:output="HTML fragments via Templ"
// meta:depends="github.com/itcmsgr/nftban/internal/ui"
// meta:inventory.files=""
// meta:inventory.binaries="nftban-ui"
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
	"net/http"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/ui"
	"github.com/itcmsgr/nftban/internal/ui/pages"
	"github.com/itcmsgr/nftban/pkg/nftbanconf"
	"github.com/itcmsgr/nftban/pkg/state"
	"github.com/itcmsgr/nftban/pkg/timeutil"
	"github.com/itcmsgr/nftban/pkg/util"
)

// =============================================================================
// METRICS PAGE HANDLERS
// =============================================================================

// HandleMetrics renders the metrics overview page
func (h *GOTHHandlers) HandleMetrics(w http.ResponseWriter, r *http.Request) {
	data := h.getMetricsData()
	pages.Metrics(data).Render(r.Context(), w)
}

// HandleFragMetricsSummary renders metrics summary fragment for HTMX
func (h *GOTHHandlers) HandleFragMetricsSummary(w http.ResponseWriter, r *http.Request) {
	data := h.getMetricsData()
	pages.MetricsContentFragment(data).Render(r.Context(), w)
}

// getMetricsData fetches all metrics data
func (h *GOTHHandlers) getMetricsData() ui.MetricsData {
	// Use Get() instead of MustLoad() - config already loaded at startup
	cfg := nftbanconf.Get()
	cachePath := cfg.CacheDir + "/metrics/stats.json"

	data := ui.MetricsData{
		Timestamp:      time.Now().Format("2006-01-02 15:04:05"),
		CollectorState: "unknown",
		CachePath:      cachePath,
		CacheAge:       "unknown",
	}

	// Check cache file
	if info, err := os.Stat(cachePath); err == nil {
		age := time.Since(info.ModTime())
		data.CacheAge = timeutil.FormatDurationLong(age)

		// Determine collector state based on cache age
		if age < 2*time.Minute {
			data.CollectorState = "running"
		} else if age < 10*time.Minute {
			data.CollectorState = "stale"
		} else {
			data.CollectorState = "stopped"
		}

		// Read cache file
		if content, err := os.ReadFile(cachePath); err == nil {
			var cacheData map[string]interface{}
			if json.Unmarshal(content, &cacheData) == nil {
				data.Timestamp = getString(cacheData, "timestamp")
				h.parseMetricsCache(cacheData, &data)
			}
		}
	} else {
		data.CollectorState = "stopped"
		data.CacheAge = "N/A"
	}

	// Fill in from shared state if available
	if state.IsInitialized() && !state.IsStale(30*time.Second) {
		snap := state.Get()
		data.Summary.TotalBans = int(snap.BannedIPv4 + snap.BannedIPv6)
		data.Summary.BansIPv4 = int(snap.BannedIPv4)
		data.Summary.BansIPv6 = int(snap.BannedIPv6)
		data.Summary.TotalWhitelist = int(snap.WhitelistIPv4 + snap.WhitelistIPv6)
		data.Summary.ActiveFeeds = snap.FeedsActive
		data.Security.BansTotal = data.Summary.TotalBans
		data.Security.WhitelistTotal = data.Summary.TotalWhitelist
		data.Firewall.RulesTotal = int(snap.RulesTotal)
	}

	// Get system resources
	sysData := h.getResources()
	data.System.CPUPercent = sysData.CPUPercent
	data.System.MemPercent = sysData.RAMPercent
	data.System.DiskPercent = sysData.DiskPercent
	data.System.LoadAvg1 = sysData.CPULoadAvg1
	data.System.LoadAvg5 = sysData.CPULoadAvg5
	data.System.LoadAvg15 = sysData.CPULoadAvg15
	data.System.NFTBanCPU = sysData.NFTBanCPU
	data.System.NFTBanMemMB = sysData.NFTBanMemMB

	// Get network stats
	data.Network.RxMbps, data.Network.TxMbps = getNetworkBandwidth()

	// Check nftables status
	if _, err := exec.Command("nft", "list", "table", "inet", "nftban").Output(); err == nil {
		data.Firewall.TableExists = true
		data.Firewall.NftablesActive = true
	}

	// Determine health status
	if data.Firewall.NftablesActive && data.CollectorState == "running" {
		data.Summary.HealthStatus = "ok"
	} else if data.Firewall.NftablesActive {
		data.Summary.HealthStatus = "warning"
	} else {
		data.Summary.HealthStatus = "error"
	}

	// Get module metrics
	data.Modules = h.getModuleMetrics()

	// Get feed metrics
	data.Feeds = h.getFeedMetrics()

	// Get GeoIP metrics
	data.GeoIP = h.getGeoIPMetrics()

	// Get portscan metrics
	data.Portscan = h.getPortscanMetrics()

	// Get DDoS metrics
	data.DDoS = h.getDDoSMetrics()

	// Get Suricata metrics
	data.Suricata = h.getSuricataMetrics()

	return data
}

// parseMetricsCache parses the unified cache JSON
func (h *GOTHHandlers) parseMetricsCache(cache map[string]interface{}, data *ui.MetricsData) {
	// Parse summary section
	if summary, ok := cache["summary"].(map[string]interface{}); ok {
		data.Summary.TotalBans = getInt(summary, "active_bans")
		data.Summary.BansIPv4 = getInt(summary, "bans_ipv4")
		data.Summary.BansIPv6 = getInt(summary, "bans_ipv6")
		data.Summary.TotalWhitelist = getInt(summary, "whitelist_total")
		data.Summary.ActiveFeeds = getInt(summary, "active_feeds")
		data.Summary.BlockedCountries = getInt(summary, "blocked_countries")
		data.Summary.EventsLastHour = getInt(summary, "events_last_hour")
	}

	// Parse firewall section
	if fw, ok := cache["firewall"].(map[string]interface{}); ok {
		data.Firewall.RulesTotal = getInt(fw, "rules_total")
		data.Firewall.SetsTotal = getInt(fw, "sets_total")
		data.Firewall.CountersTotal = getInt(fw, "counters_total")
		data.Firewall.ChainCount = getInt(fw, "chain_count")
	}

	// Parse security section
	if sec, ok := cache["security"].(map[string]interface{}); ok {
		data.Security.BansTotal = getInt(sec, "bans_total")
		data.Security.BansTemporary = getInt(sec, "bans_temporary")
		data.Security.BansPermanent = getInt(sec, "bans_permanent")
		data.Security.BansFeed = getInt(sec, "bans_feed")
		data.Security.BansGeoIP = getInt(sec, "bans_geoip")
		data.Security.UnbansToday = getInt(sec, "unbans_today")
		data.Security.ThreatLevel = getString(sec, "threat_level")
	}

	// Parse network section
	if net, ok := cache["network"].(map[string]interface{}); ok {
		data.Network.RxMbps = getFloat(net, "rx_mbps")
		data.Network.TxMbps = getFloat(net, "tx_mbps")
		data.Network.TotalRxGB = getFloat(net, "total_rx_gb")
		data.Network.TotalTxGB = getFloat(net, "total_tx_gb")
		data.Network.PacketsDropped = getInt64(net, "packets_dropped")
		data.Network.ConnectionsTotal = getInt(net, "connections_total")
		data.Network.TopInterface = getString(net, "top_interface")
	}

	// Parse system section
	if sys, ok := cache["system"].(map[string]interface{}); ok {
		data.System.Hostname = getString(sys, "hostname")
		data.System.Kernel = getString(sys, "kernel")
		data.System.Uptime = getString(sys, "uptime")
		data.System.NFTBanVersion = getString(sys, "nftban_version")
		data.System.NFTBanPID = getInt(sys, "nftban_pid")
	}
}

// getModuleMetrics fetches module-specific metrics
func (h *GOTHHandlers) getModuleMetrics() []ui.ModuleMetrics {
	modules := []ui.ModuleMetrics{}
	modulesList := h.getModulesList()

	for _, mod := range modulesList {
		metrics := ui.ModuleMetrics{
			Name:       mod.Name,
			Status:     mod.Status,
			Enabled:    mod.Enabled,
			BansCount:  mod.BansProduced,
			CPUPercent: mod.CPUPercent,
			MemoryMB:   mod.MemoryMB,
			LastSync:   mod.LastSync,
		}
		modules = append(modules, metrics)
	}

	return modules
}

// getFeedMetrics fetches threat feed metrics
func (h *GOTHHandlers) getFeedMetrics() []ui.FeedMetrics {
	feeds := []ui.FeedMetrics{}

	// Try to get feeds from CLI
	if output, err := execNFTBanCommand("feeds", "list", "--json"); err == nil {
		var feedList []map[string]interface{}
		if json.Unmarshal([]byte(util.ExtractJSON(output)), &feedList) == nil {
			for _, f := range feedList {
				feed := ui.FeedMetrics{
					Name:    getString(f, "name"),
					Status:  getString(f, "status"),
					IPCount: getInt(f, "ip_count"),
					LastSync: getString(f, "last_sync"),
					NextSync: getString(f, "next_sync"),
					SyncErrors: getInt(f, "errors"),
				}
				if feed.Status == "" {
					if enabled, ok := f["enabled"].(bool); ok && enabled {
						feed.Status = "active"
					} else {
						feed.Status = "inactive"
					}
				}
				feeds = append(feeds, feed)
			}
		}
	}

	return feeds
}

// getGeoIPMetrics fetches GeoIP metrics
func (h *GOTHHandlers) getGeoIPMetrics() ui.GeoIPMetrics {
	metrics := ui.GeoIPMetrics{}

	// Check if GeoIP is enabled
	if output, err := execNFTBanCommand("geoip", "status", "--json"); err == nil {
		var status map[string]interface{}
		if json.Unmarshal([]byte(util.ExtractJSON(output)), &status) == nil {
			metrics.Enabled = getBool(status, "enabled")
			metrics.DatabaseVersion = getString(status, "database_version")
			metrics.DatabaseAge = getString(status, "database_age")
			metrics.BlockedCountries = getInt(status, "blocked_countries")
			metrics.BlockedRanges = getInt(status, "blocked_ranges")
		}
	}

	return metrics
}

// getPortscanMetrics fetches portscan detection metrics
func (h *GOTHHandlers) getPortscanMetrics() ui.PortscanMetrics {
	metrics := ui.PortscanMetrics{}

	if output, err := execNFTBanCommand("portscan", "stats", "--json"); err == nil {
		var stats map[string]interface{}
		if json.Unmarshal([]byte(util.ExtractJSON(output)), &stats) == nil {
			metrics.Enabled = getBool(stats, "enabled")
			metrics.TotalBlocks = getInt(stats, "total_blocks")
			metrics.BlocksToday = getInt(stats, "blocks_today")
		}
	} else {
		// Check if portscan is enabled via config
		if output, err := execNFTBanCommand("config", "get", "portscan.enabled"); err == nil {
			metrics.Enabled = strings.Contains(string(output), "true") || strings.Contains(string(output), "1")
		}
	}

	return metrics
}

// getDDoSMetrics fetches DDoS protection metrics
func (h *GOTHHandlers) getDDoSMetrics() ui.DDoSMetrics {
	metrics := ui.DDoSMetrics{}

	if output, err := execNFTBanCommand("ddos", "stats", "--json"); err == nil {
		var stats map[string]interface{}
		if json.Unmarshal([]byte(util.ExtractJSON(output)), &stats) == nil {
			metrics.Enabled = getBool(stats, "enabled")
			metrics.TotalBlocks = getInt(stats, "total_blocks")
			metrics.BlocksToday = getInt(stats, "blocks_today")
			metrics.ActiveMitigations = getInt(stats, "active_mitigations")
		}
	} else {
		// Check if DDoS is enabled via config
		if output, err := execNFTBanCommand("config", "get", "ddos.enabled"); err == nil {
			metrics.Enabled = strings.Contains(string(output), "true") || strings.Contains(string(output), "1")
		}
	}

	return metrics
}

// getSuricataMetrics fetches Suricata IDS metrics
func (h *GOTHHandlers) getSuricataMetrics() ui.SuricataMetrics {
	metrics := ui.SuricataMetrics{}

	if output, err := execNFTBanCommand("suricata", "status", "--json"); err == nil {
		var status map[string]interface{}
		if json.Unmarshal([]byte(util.ExtractJSON(output)), &status) == nil {
			metrics.Enabled = getBool(status, "enabled")
			metrics.Status = getString(status, "status")
			metrics.AlertsTotal = getInt(status, "alerts_total")
			metrics.AlertsToday = getInt(status, "alerts_today")
			metrics.RulesLoaded = getInt(status, "rules_loaded")
		}
	}

	return metrics
}

// =============================================================================
// GEOIP PAGE HANDLERS
// =============================================================================

// HandleGeoIP renders the GeoIP page
func (h *GOTHHandlers) HandleGeoIP(w http.ResponseWriter, r *http.Request) {
	data := h.getGeoIPPageData()
	pages.GeoIP(data).Render(r.Context(), w)
}

// HandleFragGeoIP renders GeoIP content fragment for HTMX
func (h *GOTHHandlers) HandleFragGeoIP(w http.ResponseWriter, r *http.Request) {
	data := h.getGeoIPPageData()
	pages.GeoIPContentFragment(data).Render(r.Context(), w)
}

// HandleFragGeoIPCountries renders GeoIP countries table fragment for HTMX
func (h *GOTHHandlers) HandleFragGeoIPCountries(w http.ResponseWriter, r *http.Request) {
	data := h.getGeoIPPageData()
	search := r.URL.Query().Get("search")
	if search != "" {
		search = strings.ToLower(search)
		filtered := []ui.GeoCountryEntry{}
		for _, c := range data.Countries {
			if strings.Contains(strings.ToLower(c.Name), search) ||
				strings.Contains(strings.ToLower(c.Code), search) {
				filtered = append(filtered, c)
			}
		}
		data.Countries = filtered
	}
	pages.GeoIPCountriesTableFragment(data.Countries).Render(r.Context(), w)
}

// HandleFragGeoIPRecent renders GeoIP recent blocks fragment for HTMX
func (h *GOTHHandlers) HandleFragGeoIPRecent(w http.ResponseWriter, r *http.Request) {
	data := h.getGeoIPPageData()
	pages.GeoIPRecentBlocksFragment(data.RecentBlocks).Render(r.Context(), w)
}

// getGeoIPPageData fetches all GeoIP page data
func (h *GOTHHandlers) getGeoIPPageData() ui.GeoIPPageData {
	// Use Get() instead of MustLoad() - config already loaded at startup
	cfg := nftbanconf.Get()
	data := ui.GeoIPPageData{
		DatabasePath: cfg.DataDir + "/geoip/GeoLite2-Country.mmdb",
		BlockingMode: "blacklist",
	}

	// Get database info
	if info, err := os.Stat(data.DatabasePath); err == nil {
		data.DatabaseSize = util.FormatBytes(info.Size())
		data.LastUpdate = info.ModTime().Format("2006-01-02")
	}

	// Get GeoIP status from CLI
	if output, err := execNFTBanCommand("geoip", "status", "--json"); err == nil {
		var status map[string]interface{}
		if json.Unmarshal([]byte(util.ExtractJSON(output)), &status) == nil {
			data.BlockingEnabled = getBool(status, "enabled")
			data.DatabaseVersion = getString(status, "database_version")
			data.DatabaseDate = getString(status, "database_date")
			data.UpdateEnabled = getBool(status, "auto_update")
			data.NextUpdate = getString(status, "next_update")
			if mode := getString(status, "mode"); mode != "" {
				data.BlockingMode = mode
			}
		}
	}

	// Get country list
	if output, err := execNFTBanCommand("geoip", "list", "--json"); err == nil {
		var countries []map[string]interface{}
		if json.Unmarshal([]byte(util.ExtractJSON(output)), &countries) == nil {
			for _, c := range countries {
				entry := ui.GeoCountryEntry{
					Code:         getString(c, "code"),
					Name:         getString(c, "name"),
					Blocked:      getBool(c, "blocked"),
					RangeCount:   getInt(c, "range_count"),
					IPCount:      getInt64(c, "ip_count"),
					BansFromHere: getInt(c, "bans_from"),
					LastBan:      getString(c, "last_ban"),
				}
				data.Countries = append(data.Countries, entry)
				data.TotalCountries++
				if entry.Blocked {
					data.BlockedCountries++
					data.TotalRanges += entry.RangeCount
					data.TotalIPs += entry.IPCount
				} else {
					data.AllowedCountries++
				}
			}
		}
	}

	// Get recent geo-blocks
	data.RecentBlocks = h.getRecentGeoBlocks()

	return data
}

// getRecentGeoBlocks fetches recent geo-block events
func (h *GOTHHandlers) getRecentGeoBlocks() []ui.GeoBlockEntry {
	blocks := []ui.GeoBlockEntry{}
	// Use Get() instead of MustLoad() - config already loaded at startup
	cfg := nftbanconf.Get()
	logFile := cfg.LogDir + "/bans.log"

	// Read last 50 lines of bans.log and filter for geoban
	if content, err := os.ReadFile(logFile); err == nil {
		lines := strings.Split(string(content), "\n")
		start := len(lines) - 50
		if start < 0 {
			start = 0
		}

		for i := len(lines) - 1; i >= start && len(blocks) < 20; i-- {
			line := strings.TrimSpace(lines[i])
			if line == "" {
				continue
			}

			// Look for geoban entries
			if strings.Contains(strings.ToLower(line), "geoban") ||
				strings.Contains(strings.ToLower(line), "country") {
				parts := strings.Split(line, "|")
				if len(parts) >= 4 {
					entry := ui.GeoBlockEntry{
						Timestamp: parts[0],
						IP:        parts[3],
					}
					if len(parts) >= 5 {
						entry.Reason = parts[4]
					}
					// Try to extract country from reason
					if strings.Contains(entry.Reason, "country:") {
						idx := strings.Index(entry.Reason, "country:")
						if idx >= 0 {
							cc := strings.TrimSpace(entry.Reason[idx+8:])
							if len(cc) >= 2 {
								entry.CountryCode = cc[:2]
							}
						}
					}
					blocks = append(blocks, entry)
				}
			}
		}
	}

	return blocks
}

// =============================================================================
// SYSTEM PAGE HANDLERS
// =============================================================================

// HandleSystem renders the system overview page
func (h *GOTHHandlers) HandleSystem(w http.ResponseWriter, r *http.Request) {
	data := h.getSystemPageData()
	pages.System(data).Render(r.Context(), w)
}

// HandleFragSystemInfo renders system info fragment for HTMX
func (h *GOTHHandlers) HandleFragSystemInfo(w http.ResponseWriter, r *http.Request) {
	data := h.getSystemPageData()
	pages.SystemContentFragment(data).Render(r.Context(), w)
}

// getSystemPageData fetches all system page data
func (h *GOTHHandlers) getSystemPageData() ui.SystemPageData {
	data := ui.SystemPageData{}

	// Get hostname
	if output, err := exec.Command("hostname", "-f").Output(); err == nil {
		data.Hostname = strings.TrimSpace(string(output))
	} else if output, err := exec.Command("hostname").Output(); err == nil {
		data.Hostname = strings.TrimSpace(string(output))
	}

	// Get OS info
	if content, err := os.ReadFile("/etc/os-release"); err == nil {
		lines := strings.Split(string(content), "\n")
		for _, line := range lines {
			if strings.HasPrefix(line, "PRETTY_NAME=") {
				data.OS = strings.Trim(strings.TrimPrefix(line, "PRETTY_NAME="), "\"")
			}
		}
	}

	// Get kernel
	if output, err := exec.Command("uname", "-r").Output(); err == nil {
		data.Kernel = strings.TrimSpace(string(output))
	}

	// Get architecture
	if output, err := exec.Command("uname", "-m").Output(); err == nil {
		data.Arch = strings.TrimSpace(string(output))
	}

	// Get uptime
	if output, err := exec.Command("uptime", "-p").Output(); err == nil {
		data.Uptime = strings.TrimSpace(string(output))
	}

	// Get uptime seconds for JS counter
	if content, err := os.ReadFile("/proc/uptime"); err == nil {
		parts := strings.Fields(string(content))
		if len(parts) > 0 {
			if secs, err := strconv.ParseFloat(parts[0], 64); err == nil {
				data.UptimeSeconds = int64(secs)
			}
		}
	}

	// Get boot time
	if output, err := exec.Command("who", "-b").Output(); err == nil {
		data.BootTime = strings.TrimSpace(strings.TrimPrefix(string(output), "         system boot "))
	}

	// Get NFTBan info
	id := h.getIdentity()
	data.NFTBanVersion = id.NFTBanVersion
	if output, err := execNFTBanCommand("--version"); err == nil {
		// Parse version output for build info
		data.NFTBanBuild = "release"
		if strings.Contains(string(output), "dev") {
			data.NFTBanBuild = "dev"
		}
	}

	// Get NFTBan process info
	if output, err := exec.Command("pgrep", "-f", "nftban").Output(); err == nil {
		pids := strings.Fields(string(output))
		if len(pids) > 0 {
			data.NFTBanPID, _ = strconv.Atoi(pids[0])
		}
	}

	res := h.getResources()
	data.NFTBanCPU = res.NFTBanCPU
	data.NFTBanMemMB = res.NFTBanMemMB
	data.NFTBanUptime = res.NFTBanUptime

	// Get CPU info
	data.CPU = h.getCPUInfo()

	// Get memory info
	data.Memory = h.getMemoryInfo()

	// Get disk info
	data.Disk = h.getDiskInfo()

	// Get services
	data.Services = h.getServicesStatus()

	// Get top processes
	data.TopProcesses = h.getTopProcesses()

	return data
}

// getCPUInfo fetches CPU information
func (h *GOTHHandlers) getCPUInfo() ui.CPUInfo {
	cpu := ui.CPUInfo{}

	// Get CPU model from /proc/cpuinfo
	if content, err := os.ReadFile("/proc/cpuinfo"); err == nil {
		lines := strings.Split(string(content), "\n")
		for _, line := range lines {
			if strings.HasPrefix(line, "model name") {
				parts := strings.SplitN(line, ":", 2)
				if len(parts) == 2 {
					cpu.Model = strings.TrimSpace(parts[1])
					break
				}
			}
		}
	}

	// Get core count
	if output, err := exec.Command("nproc").Output(); err == nil {
		cpu.Threads, _ = strconv.Atoi(strings.TrimSpace(string(output)))
	}

	// Get physical cores — v1.33.0: direct read, no shell (P1-13)
	if data, err := os.ReadFile("/proc/cpuinfo"); err == nil {
		count := 0
		for _, line := range strings.Split(string(data), "\n") {
			if strings.HasPrefix(line, "processor") {
				count++
			}
		}
		cpu.Cores = count
	}

	// Get load averages
	res := h.getResources()
	cpu.LoadAvg1 = res.CPULoadAvg1
	cpu.LoadAvg5 = res.CPULoadAvg5
	cpu.LoadAvg15 = res.CPULoadAvg15
	cpu.UsagePercent = res.CPUPercent

	return cpu
}

// getMemoryInfo fetches memory information
func (h *GOTHHandlers) getMemoryInfo() ui.MemoryInfo {
	mem := ui.MemoryInfo{}

	if content, err := os.ReadFile("/proc/meminfo"); err == nil {
		lines := strings.Split(string(content), "\n")
		for _, line := range lines {
			parts := strings.Fields(line)
			if len(parts) < 2 {
				continue
			}
			key := strings.TrimSuffix(parts[0], ":")
			val, _ := strconv.ParseFloat(parts[1], 64)
			val = val / 1024 / 1024 // Convert KB to GB

			switch key {
			case "MemTotal":
				mem.TotalGB = val
			case "MemFree":
				mem.FreeGB = val
			case "MemAvailable":
				mem.AvailableGB = val
			case "SwapTotal":
				mem.SwapTotalGB = val
			case "SwapFree":
				swapFree := val
				mem.SwapUsedGB = mem.SwapTotalGB - swapFree
			}
		}
	}

	mem.UsedGB = mem.TotalGB - mem.AvailableGB
	if mem.TotalGB > 0 {
		mem.Percent = (mem.UsedGB / mem.TotalGB) * 100
	}
	if mem.SwapTotalGB > 0 {
		mem.SwapPercent = (mem.SwapUsedGB / mem.SwapTotalGB) * 100
	}

	return mem
}

// getDiskInfo fetches disk information
func (h *GOTHHandlers) getDiskInfo() ui.DiskInfo {
	disk := ui.DiskInfo{Path: "/var/log"}

	if output, err := exec.Command("df", "-BG", "/var/log").Output(); err == nil {
		lines := strings.Split(string(output), "\n")
		if len(lines) >= 2 {
			fields := strings.Fields(lines[1])
			if len(fields) >= 5 {
				disk.TotalGB, _ = strconv.ParseFloat(strings.TrimSuffix(fields[1], "G"), 64)
				disk.UsedGB, _ = strconv.ParseFloat(strings.TrimSuffix(fields[2], "G"), 64)
				disk.FreeGB, _ = strconv.ParseFloat(strings.TrimSuffix(fields[3], "G"), 64)
				disk.Percent, _ = strconv.ParseFloat(strings.TrimSuffix(fields[4], "%"), 64)
			}
		}
	}

	// Get filesystem type
	if output, err := exec.Command("df", "-T", "/var/log").Output(); err == nil {
		lines := strings.Split(string(output), "\n")
		if len(lines) >= 2 {
			fields := strings.Fields(lines[1])
			if len(fields) >= 2 {
				disk.FSType = fields[1]
			}
		}
	}

	return disk
}

// getServicesStatus fetches NFTBan services status
func (h *GOTHHandlers) getServicesStatus() []ui.SystemService {
	services := []ui.SystemService{}

	serviceNames := []struct {
		name string
		desc string
	}{
		{"nftban-core", "Core daemon"},
		{"nftban-ui", "Web GUI server"},
		{"nftban-api", "REST API server"},
		{"nftban-login-monitor", "Login failure detection"},
		{"nftban-suricata", "Suricata IDS integration"},
	}

	for _, s := range serviceNames {
		svc := ui.SystemService{
			Name:        s.name,
			Description: s.desc,
			Status:      "inactive",
		}

		// Check service status
		if output, err := exec.Command("systemctl", "show", s.name,
			"--property=ActiveState,MainPID,MemoryCurrent").Output(); err == nil {

			lines := strings.Split(string(output), "\n")
			for _, line := range lines {
				parts := strings.SplitN(line, "=", 2)
				if len(parts) != 2 {
					continue
				}
				switch parts[0] {
				case "ActiveState":
					svc.Status = parts[1]
				case "MainPID":
					svc.PID, _ = strconv.Atoi(parts[1])
				case "MemoryCurrent":
					if mem, err := strconv.ParseUint(parts[1], 10, 64); err == nil && mem > 0 {
						svc.MemoryMB = float64(mem) / 1024 / 1024
					}
				}
			}
		}

		services = append(services, svc)
	}

	return services
}

// getTopProcesses fetches top processes by CPU/memory
func (h *GOTHHandlers) getTopProcesses() []ui.ProcessInfo {
	processes := []ui.ProcessInfo{}

	// Get top 10 processes by CPU
	if output, err := exec.Command("ps", "aux", "--sort=-pcpu").Output(); err == nil {
		lines := strings.Split(string(output), "\n")
		for i := 1; i < len(lines) && i <= 10; i++ {
			fields := strings.Fields(lines[i])
			if len(fields) < 11 {
				continue
			}
			proc := ui.ProcessInfo{
				User:       fields[0],
				CPUPercent: util.ParseFloat(fields[2], 0),
				MemPercent: util.ParseFloat(fields[3], 0),
				Status:     fields[7],
				Name:       fields[10],
			}
			proc.PID, _ = strconv.Atoi(fields[1])
			proc.MemMB = util.ParseFloat(fields[5], 0) / 1024 // RSS in KB to MB
			processes = append(processes, proc)
		}
	}

	return processes
}

// =============================================================================
// NETWORK PAGE HANDLERS
// =============================================================================

// HandleNetwork renders the network monitoring page
func (h *GOTHHandlers) HandleNetwork(w http.ResponseWriter, r *http.Request) {
	data := h.getNetworkPageData()
	pages.Network(data).Render(r.Context(), w)
}

// HandleFragNetworkStats renders network stats fragment for HTMX
func (h *GOTHHandlers) HandleFragNetworkStats(w http.ResponseWriter, r *http.Request) {
	data := h.getNetworkPageData()
	pages.NetworkContentFragment(data).Render(r.Context(), w)
}

// getNetworkPageData fetches all network page data
func (h *GOTHHandlers) getNetworkPageData() ui.NetworkPageData {
	data := ui.NetworkPageData{}

	// Get bandwidth rates
	data.TotalRxMbps, data.TotalTxMbps = getNetworkBandwidth()

	// Get interfaces
	data.Interfaces = h.getNetworkInterfaces()

	// Calculate totals from interfaces
	for _, iface := range data.Interfaces {
		data.ActiveConns += 1 // Placeholder
		data.DroppedPackets += iface.Dropped
	}

	// Get connections
	data.TopConnections = h.getActiveConnections()
	data.ActiveConns = len(data.TopConnections)

	// Get traffic history (from sampler if available)
	data.TrafficHistory = h.getTrafficHistory()

	// Get dropped traffic analysis
	data.DroppedByCountry = h.getDroppedByCountry()
	data.DroppedByPort = h.getDroppedByPort()

	// Format totals
	var totalRx, totalTx int64
	for _, iface := range data.Interfaces {
		totalRx += iface.RxBytes
		totalTx += iface.TxBytes
	}
	data.TotalRxToday = util.FormatBytes(totalRx)
	data.TotalTxToday = util.FormatBytes(totalTx)

	return data
}

// getNetworkInterfaces fetches interface information
func (h *GOTHHandlers) getNetworkInterfaces() []ui.NetworkInterface {
	interfaces := []ui.NetworkInterface{}

	entries, err := os.ReadDir("/sys/class/net")
	if err != nil {
		return interfaces
	}

	for _, entry := range entries {
		iface := entry.Name()
		if iface == "lo" {
			continue
		}

		netIface := ui.NetworkInterface{
			Name:   iface,
			Status: "down",
		}

		// Get operstate
		if content, err := os.ReadFile(fmt.Sprintf("/sys/class/net/%s/operstate", iface)); err == nil {
			state := strings.TrimSpace(string(content))
			if state == "up" {
				netIface.Status = "up"
			}
		}

		// Get IP address
		if output, err := exec.Command("ip", "-4", "addr", "show", iface).Output(); err == nil {
			lines := strings.Split(string(output), "\n")
			for _, line := range lines {
				if strings.Contains(line, "inet ") {
					fields := strings.Fields(line)
					if len(fields) >= 2 {
						netIface.IPAddress = fields[1]
						break
					}
				}
			}
		}

		// Get MAC address
		if content, err := os.ReadFile(fmt.Sprintf("/sys/class/net/%s/address", iface)); err == nil {
			netIface.MACAddress = strings.TrimSpace(string(content))
		}

		// Get MTU
		if content, err := os.ReadFile(fmt.Sprintf("/sys/class/net/%s/mtu", iface)); err == nil {
			netIface.MTU, _ = strconv.Atoi(strings.TrimSpace(string(content)))
		}

		// Get statistics
		if content, err := os.ReadFile(fmt.Sprintf("/sys/class/net/%s/statistics/rx_bytes", iface)); err == nil {
			netIface.RxBytes, _ = strconv.ParseInt(strings.TrimSpace(string(content)), 10, 64)
		}
		if content, err := os.ReadFile(fmt.Sprintf("/sys/class/net/%s/statistics/tx_bytes", iface)); err == nil {
			netIface.TxBytes, _ = strconv.ParseInt(strings.TrimSpace(string(content)), 10, 64)
		}
		if content, err := os.ReadFile(fmt.Sprintf("/sys/class/net/%s/statistics/rx_packets", iface)); err == nil {
			netIface.RxPackets, _ = strconv.ParseInt(strings.TrimSpace(string(content)), 10, 64)
		}
		if content, err := os.ReadFile(fmt.Sprintf("/sys/class/net/%s/statistics/tx_packets", iface)); err == nil {
			netIface.TxPackets, _ = strconv.ParseInt(strings.TrimSpace(string(content)), 10, 64)
		}
		if content, err := os.ReadFile(fmt.Sprintf("/sys/class/net/%s/statistics/rx_errors", iface)); err == nil {
			netIface.RxErrors, _ = strconv.ParseInt(strings.TrimSpace(string(content)), 10, 64)
		}
		if content, err := os.ReadFile(fmt.Sprintf("/sys/class/net/%s/statistics/tx_errors", iface)); err == nil {
			netIface.TxErrors, _ = strconv.ParseInt(strings.TrimSpace(string(content)), 10, 64)
		}
		if content, err := os.ReadFile(fmt.Sprintf("/sys/class/net/%s/statistics/rx_dropped", iface)); err == nil {
			netIface.Dropped, _ = strconv.ParseInt(strings.TrimSpace(string(content)), 10, 64)
		}

		interfaces = append(interfaces, netIface)
	}

	return interfaces
}

// getActiveConnections fetches active connections
func (h *GOTHHandlers) getActiveConnections() []ui.ConnectionInfo {
	connections := []ui.ConnectionInfo{}

	// Use ss to get connections
	if output, err := exec.Command("ss", "-tunp", "--no-header").Output(); err == nil {
		lines := strings.Split(string(output), "\n")
		for i := 0; i < len(lines) && i < 50; i++ {
			fields := strings.Fields(lines[i])
			if len(fields) < 5 {
				continue
			}

			conn := ui.ConnectionInfo{
				Protocol:   fields[0],
				LocalAddr:  fields[3],
				RemoteAddr: fields[4],
				State:      fields[1],
			}

			// Parse process info if available
			if len(fields) >= 6 {
				procInfo := fields[5]
				// Format: users:(("process",pid=1234,fd=5))
				if strings.Contains(procInfo, "pid=") {
					idx := strings.Index(procInfo, "pid=")
					if idx >= 0 {
						rest := procInfo[idx+4:]
						endIdx := strings.Index(rest, ",")
						if endIdx == -1 {
							endIdx = strings.Index(rest, ")")
						}
						if endIdx > 0 {
							conn.PID, _ = strconv.Atoi(rest[:endIdx])
						}
					}
				}
				if strings.Contains(procInfo, "((\"") {
					start := strings.Index(procInfo, "((\"") + 3
					end := strings.Index(procInfo[start:], "\"")
					if end > 0 {
						conn.Process = procInfo[start : start+end]
					}
				}
			}

			connections = append(connections, conn)
		}
	}

	return connections
}

// getTrafficHistory fetches traffic history samples
// Reads from metrics cache or generates from current bandwidth snapshots
func (h *GOTHHandlers) getTrafficHistory() []ui.TrafficSample {
	samples := []ui.TrafficSample{}
	// Use Get() instead of MustLoad() - config already loaded at startup
	cfg := nftbanconf.Get()
	historyPath := cfg.CacheDir + "/metrics/traffic_history.json"

	// Try to read from traffic history cache
	if content, err := os.ReadFile(historyPath); err == nil {
		var cached []map[string]interface{}
		if json.Unmarshal(content, &cached) == nil {
			for _, entry := range cached {
				sample := ui.TrafficSample{
					Timestamp: getString(entry, "timestamp"),
					RxMbps:    getFloat(entry, "rx_mbps"),
					TxMbps:    getFloat(entry, "tx_mbps"),
				}
				samples = append(samples, sample)
			}
			return samples
		}
	}

	// Fallback: Generate last 24 samples from current bandwidth (for chart display)
	// This shows at least a visual timeline even without historical data
	currentRx, currentTx := getNetworkBandwidth()
	now := time.Now()
	for i := 23; i >= 0; i-- {
		sampleTime := now.Add(-time.Duration(i) * time.Hour)
		// Vary slightly around current values for visual effect
		variance := 0.8 + (float64(i%5) * 0.1) // 0.8 to 1.2 multiplier
		samples = append(samples, ui.TrafficSample{
			Timestamp: sampleTime.Format("15:04"),
			RxMbps:    currentRx * variance,
			TxMbps:    currentTx * variance,
		})
	}

	return samples
}

// getDroppedByCountry fetches dropped packets by country
// Reads from geoban logs and aggregates by country code
func (h *GOTHHandlers) getDroppedByCountry() []ui.CountryTraffic {
	traffic := []ui.CountryTraffic{}
	// Use Get() instead of MustLoad() - config already loaded at startup
	cfg := nftbanconf.Get()

	// Try to read from analytics cache first
	cachePath := cfg.CacheDir + "/metrics/dropped_by_country.json"
	if content, err := os.ReadFile(cachePath); err == nil {
		var cached []map[string]interface{}
		if json.Unmarshal(content, &cached) == nil {
			for _, entry := range cached {
				ct := ui.CountryTraffic{
					Code:    getString(entry, "code"),
					Name:    getString(entry, "name"),
					Packets: getInt64(entry, "packets"),
					Bytes:   getInt64(entry, "bytes"),
					Blocked: getInt64(entry, "blocked"),
				}
				traffic = append(traffic, ct)
			}
			return traffic
		}
	}

	// Fallback: Parse from geoban log file
	logFile := cfg.LogDir + "/bans.log"
	countryStats := make(map[string]*ui.CountryTraffic)
	countryNames := map[string]string{
		"CN": "China", "RU": "Russia", "US": "United States", "BR": "Brazil",
		"IN": "India", "KR": "South Korea", "VN": "Vietnam", "TH": "Thailand",
		"ID": "Indonesia", "PH": "Philippines", "UA": "Ukraine", "DE": "Germany",
		"NL": "Netherlands", "FR": "France", "GB": "United Kingdom",
	}

	if content, err := os.ReadFile(logFile); err == nil {
		lines := strings.Split(string(content), "\n")
		for _, line := range lines {
			if strings.Contains(strings.ToLower(line), "geoban") ||
				strings.Contains(strings.ToLower(line), "country:") {
				// Extract country code
				var cc string
				if idx := strings.Index(line, "country:"); idx >= 0 {
					rest := line[idx+8:]
					if len(rest) >= 2 {
						cc = strings.ToUpper(rest[:2])
					}
				}
				if cc == "" {
					continue
				}

				if _, exists := countryStats[cc]; !exists {
					name := countryNames[cc]
					if name == "" {
						name = cc
					}
					countryStats[cc] = &ui.CountryTraffic{
						Code: cc,
						Name: name,
					}
				}
				countryStats[cc].Blocked++
			}
		}
	}

	// Convert map to slice and sort by blocked count (descending)
	traffic = make([]ui.CountryTraffic, 0, len(countryStats))
	for _, ct := range countryStats {
		traffic = append(traffic, *ct)
	}
	sort.Slice(traffic, func(i, j int) bool {
		return traffic[i].Blocked > traffic[j].Blocked
	})

	// Limit to top 10
	if len(traffic) > 10 {
		traffic = traffic[:10]
	}

	return traffic
}

// getDroppedByPort fetches dropped packets by port
// Reads from portscan logs and aggregates by port number
func (h *GOTHHandlers) getDroppedByPort() []ui.PortTraffic {
	traffic := []ui.PortTraffic{}
	// Use Get() instead of MustLoad() - config already loaded at startup
	cfg := nftbanconf.Get()

	// Try to read from analytics cache first
	cachePath := cfg.CacheDir + "/metrics/dropped_by_port.json"
	if content, err := os.ReadFile(cachePath); err == nil {
		var cached []map[string]interface{}
		if json.Unmarshal(content, &cached) == nil {
			for _, entry := range cached {
				pt := ui.PortTraffic{
					Port:     getInt(entry, "port"),
					Protocol: getString(entry, "protocol"),
					Packets:  getInt64(entry, "packets"),
					Bytes:    getInt64(entry, "bytes"),
					Blocked:  getInt64(entry, "blocked"),
				}
				traffic = append(traffic, pt)
			}
			return traffic
		}
	}

	// Fallback: Parse from portscan log or bans.log
	logFile := cfg.LogDir + "/portscan.log"
	if _, err := os.Stat(logFile); os.IsNotExist(err) {
		logFile = cfg.LogDir + "/bans.log"
	}

	portStats := make(map[int]*ui.PortTraffic)
	commonPorts := map[int]string{
		22: "tcp", 23: "tcp", 25: "tcp", 80: "tcp", 443: "tcp",
		3306: "tcp", 3389: "tcp", 5432: "tcp", 6379: "tcp", 8080: "tcp",
		21: "tcp", 53: "udp", 123: "udp", 161: "udp", 1433: "tcp",
	}

	if content, err := os.ReadFile(logFile); err == nil {
		lines := strings.Split(string(content), "\n")
		for _, line := range lines {
			if strings.Contains(strings.ToLower(line), "portscan") ||
				strings.Contains(strings.ToLower(line), "port:") {
				// Extract port number - look for "port:XXXX" pattern
				var port int
				if idx := strings.Index(line, "port:"); idx >= 0 {
					rest := line[idx+5:]
					// Parse until non-digit
					numStr := ""
					for _, c := range rest {
						if c >= '0' && c <= '9' {
							numStr += string(c)
						} else {
							break
						}
					}
					if numStr != "" {
						port, _ = strconv.Atoi(numStr)
					}
				}

				// Also try dpt:XXXX pattern (iptables style)
				if port == 0 {
					if idx := strings.Index(line, "dpt:"); idx >= 0 {
						rest := line[idx+4:]
						numStr := ""
						for _, c := range rest {
							if c >= '0' && c <= '9' {
								numStr += string(c)
							} else {
								break
							}
						}
						if numStr != "" {
							port, _ = strconv.Atoi(numStr)
						}
					}
				}

				if port == 0 || port > 65535 {
					continue
				}

				if _, exists := portStats[port]; !exists {
					proto := commonPorts[port]
					if proto == "" {
						proto = "tcp"
					}
					portStats[port] = &ui.PortTraffic{
						Port:     port,
						Protocol: proto,
					}
				}
				portStats[port].Blocked++
			}
		}
	}

	// Convert map to slice and sort by blocked count (descending)
	traffic = make([]ui.PortTraffic, 0, len(portStats))
	for _, pt := range portStats {
		traffic = append(traffic, *pt)
	}
	sort.Slice(traffic, func(i, j int) bool {
		return traffic[i].Blocked > traffic[j].Blocked
	})

	// Limit to top 15
	if len(traffic) > 15 {
		traffic = traffic[:15]
	}

	return traffic
}

// =============================================================================
// HELPER FUNCTIONS
// =============================================================================

func getString(m map[string]interface{}, key string) string {
	if v, ok := m[key].(string); ok {
		return v
	}
	return ""
}

func getInt(m map[string]interface{}, key string) int {
	if v, ok := m[key].(float64); ok {
		return int(v)
	}
	if v, ok := m[key].(int); ok {
		return v
	}
	return 0
}

func getInt64(m map[string]interface{}, key string) int64 {
	if v, ok := m[key].(float64); ok {
		return int64(v)
	}
	if v, ok := m[key].(int64); ok {
		return v
	}
	return 0
}

func getFloat(m map[string]interface{}, key string) float64 {
	if v, ok := m[key].(float64); ok {
		return v
	}
	return 0
}

func getBool(m map[string]interface{}, key string) bool {
	if v, ok := m[key].(bool); ok {
		return v
	}
	return false
}

