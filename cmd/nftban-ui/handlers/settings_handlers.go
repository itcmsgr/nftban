// =============================================================================
// NFTBan - GOTH GUI Settings Handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="settings_handlers"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-02-06"
// meta:description="GOTH GUI handlers for settings page - configuration management"
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
	"html"
	"log"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"

	"github.com/gorilla/mux"
	"github.com/itcmsgr/nftban/internal/ui"
	"github.com/itcmsgr/nftban/internal/ui/pages"
	"github.com/itcmsgr/nftban/pkg/nftbanconf"
)

// SettingsSaveRequest represents a settings save request
type SettingsSaveRequest struct {
	Section string            `json:"section"`
	Values  map[string]string `json:"values"`
}

// validLogLevels defines valid log levels (package-level to avoid recreation per call)
var validLogLevels = map[string]bool{
	"DEBUG": true,
	"INFO":  true,
	"WARN":  true,
	"ERROR": true,
}

// =============================================================================
// SECURITY FIX: Input validation for settings form to prevent command injection
// =============================================================================

// validConfigKeys is an allowlist of valid configuration keys that can be set via the UI
// SECURITY FIX: Only these keys are allowed to prevent arbitrary config manipulation
var validConfigKeys = map[string]bool{
	// Feature toggles
	"NFTBAN_METRICS_ENABLED":         true,
	"NFTBAN_GEOIP_ENABLED":           true,
	"NFTBAN_FEEDS_ENABLED":           true,
	"NFTBAN_FEEDS_AUTO_UPDATE":       true,
	"NFTBAN_SURICATA_ENABLED":        true,
	"NFTBAN_GUI_ENABLED":             true,
	"NFTBAN_PORTSCAN_ENABLED":        true,
	"NFTBAN_DDOS_ENABLED":            true,
	"NFTBAN_LOGIN_MONITOR_ENABLED":   true,
	"NFTBAN_GRAFANA_ENABLED":         true,
	// Metrics settings
	"NFTBAN_METRICS_BACKEND":            true,
	"NFTBAN_METRICS_SAMPLING_INTERVAL":  true,
	"NFTBAN_METRICS_MAX_SAMPLES":        true,
	"NFTBAN_PROMETHEUS_DIR":             true,
	"NFTBAN_METRICS_PROMETHEUS_ADDR":    true,
	"NFTBAN_METRICS_NODE_EXPORTER_ADDR": true,
	"NFTBAN_METRICS_VICTORIA_ADDR":      true,
	// GeoIP settings
	"NFTBAN_GEOIP_LICENSE_KEY": true,
	// Suricata settings
	"NFTBAN_SURICATA_EVE_LOG":              true,
	"NFTBAN_SURICATA_LOG_DIR":              true,
	"NFTBAN_SURICATA_BAN_THRESHOLD":        true,
	"NFTBAN_SURICATA_SCORE_DECAY":          true,
	"NFTBAN_SURICATA_CLOUDFLARE_WHITELIST": true,
	// Logging settings
	"NFTBAN_LOG_LEVEL":       true,
	"NFTBAN_COLOR_OUTPUT":    true,
	"NFTBAN_DEBUG_TRACE":     true,
	"NFTBAN_DEBUG_TRACE_LOG": true,
	// Network settings
	"NFTBAN_GUI_ADDR": true,
	"NFTBAN_API_ADDR": true,
}

// validConfigValueRegex validates config values - allows alphanumeric, paths, addresses
// SECURITY FIX: Prevents shell metacharacter injection
var validConfigValueRegex = regexp.MustCompile(`^[a-zA-Z0-9/._:@-]*$`)

// shellMetacharacters contains characters that could be used for command injection
// SECURITY FIX: These characters are explicitly rejected in config values
var shellMetacharacters = []string{";", "|", "&", "$", "`", "(", ")", "{", "}", "[", "]", "<", ">", "\\", "\"", "'"}

// validateConfigKey checks if a config key is in the allowlist
// SECURITY FIX: Prevents setting arbitrary/dangerous config keys
func validateConfigKey(key string) error {
	if !validConfigKeys[key] {
		return fmt.Errorf("invalid config key: %s is not in the allowlist", key)
	}
	return nil
}

// validateConfigValue checks if a config value is safe
// SECURITY FIX: Prevents command injection via config values
func validateConfigValue(value string) error {
	// Check for shell metacharacters
	for _, char := range shellMetacharacters {
		if strings.Contains(value, char) {
			return fmt.Errorf("invalid config value: contains forbidden character '%s'", char)
		}
	}
	// Additional regex validation for allowed characters
	if !validConfigValueRegex.MatchString(value) {
		return fmt.Errorf("invalid config value: contains disallowed characters")
	}
	return nil
}

// =============================================================================
// SETTINGS PAGE HANDLERS
// =============================================================================

// HandleSettings renders the settings page
func (h *GOTHHandlers) HandleSettings(w http.ResponseWriter, r *http.Request) {
	extData := h.getExtendedSettingsData()

	// Check for success/error query params (after redirect)
	if r.URL.Query().Get("saved") == "true" {
		extData.SaveSuccess = true
	}
	if errMsg := r.URL.Query().Get("error"); errMsg != "" {
		extData.SaveError = errMsg
	}

	// Convert to basic SettingsData for existing template
	data := h.convertToBasicSettings(extData)
	pages.Settings(data).Render(r.Context(), w)
}

// HandleSettingsSave handles POST requests to save settings
func (h *GOTHHandlers) HandleSettingsSave(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Parse form data
	if err := r.ParseForm(); err != nil {
		log.Printf("[GOTH] Settings save: parse form error: %v", err)
		h.sendSettingsError(w, "Failed to parse form data")
		return
	}

	section := r.FormValue("section")
	if section == "" {
		section = "all"
	}

	log.Printf("[GOTH] Settings save requested for section: %s", section)

	// Build the config command arguments based on section
	var args []string
	var hasChanges bool

	switch section {
	case "features":
		args, hasChanges = h.buildFeatureArgs(r)
	case "metrics":
		args, hasChanges = h.buildMetricsArgs(r)
	case "geoip":
		args, hasChanges = h.buildGeoIPArgs(r)
	case "suricata":
		args, hasChanges = h.buildSuricataArgs(r)
	case "logging":
		args, hasChanges = h.buildLoggingArgs(r)
	case "network":
		args, hasChanges = h.buildNetworkArgs(r)
	case "all":
		// Save all sections
		allArgs := []string{}
		if featureArgs, has := h.buildFeatureArgs(r); has {
			allArgs = append(allArgs, featureArgs...)
			hasChanges = true
		}
		if metricsArgs, has := h.buildMetricsArgs(r); has {
			allArgs = append(allArgs, metricsArgs...)
			hasChanges = true
		}
		if geoipArgs, has := h.buildGeoIPArgs(r); has {
			allArgs = append(allArgs, geoipArgs...)
			hasChanges = true
		}
		if suricataArgs, has := h.buildSuricataArgs(r); has {
			allArgs = append(allArgs, suricataArgs...)
			hasChanges = true
		}
		if loggingArgs, has := h.buildLoggingArgs(r); has {
			allArgs = append(allArgs, loggingArgs...)
			hasChanges = true
		}
		if networkArgs, has := h.buildNetworkArgs(r); has {
			allArgs = append(allArgs, networkArgs...)
			hasChanges = true
		}
		args = allArgs
	default:
		h.sendSettingsError(w, "Unknown settings section: "+section)
		return
	}

	if !hasChanges {
		log.Printf("[GOTH] Settings save: no changes detected")
		h.sendSettingsSuccess(w, "No changes to save")
		return
	}

	// Execute nftban config set commands
	for _, arg := range args {
		parts := strings.SplitN(arg, "=", 2)
		if len(parts) != 2 {
			continue
		}
		key, value := parts[0], parts[1]

		// SECURITY FIX: Validate config key against allowlist
		if err := validateConfigKey(key); err != nil {
			log.Printf("[GOTH] Settings save: security validation failed for key %s: %v", key, err)
			h.sendSettingsError(w, fmt.Sprintf("Security error: %v", err))
			return
		}

		// SECURITY FIX: Validate config value to prevent command injection
		if err := validateConfigValue(value); err != nil {
			log.Printf("[GOTH] Settings save: security validation failed for value of %s: %v", key, err)
			h.sendSettingsError(w, fmt.Sprintf("Security error: %v", err))
			return
		}

		output, err := execNFTBanCommand("config", "set", key, value)
		if err != nil {
			log.Printf("[GOTH] Settings save: failed to set %s: %v - %s", key, err, output)
			h.sendSettingsError(w, fmt.Sprintf("Failed to set %s: %v", key, err))
			return
		}
		log.Printf("[GOTH] Settings save: set %s = %s", key, value)
	}

	log.Printf("[GOTH] Settings save: %d settings updated successfully", len(args))
	h.sendSettingsSuccess(w, fmt.Sprintf("%d settings updated", len(args)))
}

// HandleFragSettingsSection renders a specific settings section fragment for HTMX
func (h *GOTHHandlers) HandleFragSettingsSection(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	section := vars["section"]

	extData := h.getExtendedSettingsData()

	switch section {
	case "general":
		pages.SettingsGeneralFragment(extData).Render(r.Context(), w)
	case "features":
		pages.SettingsFeaturesFragment(extData).Render(r.Context(), w)
	case "metrics":
		pages.SettingsMetricsFragment(extData).Render(r.Context(), w)
	case "geoip":
		pages.SettingsGeoIPFragment(extData).Render(r.Context(), w)
	case "suricata":
		pages.SettingsSuricataFragment(extData).Render(r.Context(), w)
	case "logging":
		pages.SettingsLoggingFragment(extData).Render(r.Context(), w)
	case "network":
		pages.SettingsNetworkFragment(extData).Render(r.Context(), w)
	case "paths":
		pages.SettingsPathsFragment(extData).Render(r.Context(), w)
	default:
		http.Error(w, "Unknown section: "+section, http.StatusBadRequest)
	}
}

// =============================================================================
// SETTINGS DATA FETCHER
// =============================================================================

// getExtendedSettingsData loads current settings from /etc/nftban/nftban.conf
func (h *GOTHHandlers) getExtendedSettingsData() ui.ExtendedSettingsData {
	// Use Get() instead of MustLoad() - config already loaded at startup
	cfg := nftbanconf.Get()
	configPath := nftbanconf.DefaultConfigFile

	data := ui.ExtendedSettingsData{
		ConfigPath:    configPath,
		ConfigVersion: cfg.ConfigVersion,
	}

	// Check if config file is writable
	if info, err := os.Stat(configPath); err == nil {
		data.LastModified = info.ModTime().Format("2006-01-02 15:04:05")
		// Check write permission
		if file, err := os.OpenFile(configPath, os.O_WRONLY, 0); err == nil {
			file.Close()
			data.CanWrite = true
		}
	}

	// General settings
	data.General = ui.GeneralSettingsData{
		Version:       cfg.Version,
		ConfigVersion: cfg.ConfigVersion,
	}

	// Feature toggles
	data.Features = ui.FeatureSettingsData{
		MetricsEnabled:      cfg.MetricsEnabled,
		GeoIPEnabled:        cfg.GeoIPEnabled,
		FeedsEnabled:        cfg.FeedsEnabled,
		FeedsAutoUpdate:     cfg.FeedsAutoUpdate,
		SuricataEnabled:     cfg.SuricataEnabled,
		GUIEnabled:          cfg.GUIEnabled,
		PortscanEnabled:     cfg.PortscanEnabled,
		DDoSEnabled:         cfg.DDoSEnabled,
		LoginMonitorEnabled: cfg.LoginMonitorEnabled,
		GrafanaEnabled:      cfg.GrafanaEnabled,
	}

	// Metrics settings
	data.Metrics = ui.MetricsSettingsData{
		Enabled:          cfg.MetricsEnabled,
		Backend:          cfg.MetricsBackend,
		SamplingInterval: cfg.MetricsSamplingInterval,
		MaxSamples:       cfg.MetricsMaxSamples,
		PrometheusDir:    cfg.PrometheusDir,
		PrometheusAddr:   cfg.MetricsPrometheusAddr,
		NodeExporterAddr: cfg.MetricsNodeExporterAddr,
		VictoriaAddr:     cfg.MetricsVictoriaAddr,
	}

	// GeoIP settings
	data.GeoIP = ui.GeoIPSettingsData{
		Enabled: cfg.GeoIPEnabled,
		HasKey:  cfg.GeoIPLicenseKey != "",
	}
	// Mask license key for display (show only last 4 chars)
	if cfg.GeoIPLicenseKey != "" {
		keyLen := len(cfg.GeoIPLicenseKey)
		if keyLen > 4 {
			data.GeoIP.LicenseKey = strings.Repeat("*", keyLen-4) + cfg.GeoIPLicenseKey[keyLen-4:]
		} else {
			data.GeoIP.LicenseKey = strings.Repeat("*", keyLen)
		}
	}

	// Suricata settings
	data.Suricata = ui.SuricataSettingsData{
		Enabled:             cfg.SuricataEnabled,
		EveLog:              cfg.SuricataEveLog,
		LogDir:              cfg.SuricataLogDir,
		BanThreshold:        cfg.SuricataBanThreshold,
		ScoreDecay:          cfg.SuricataScoreDecay,
		CloudflareWhitelist: cfg.SuricataCloudflareWhitelist,
	}

	// Logging settings
	data.Logging = ui.LoggingSettingsData{
		LogLevel:      cfg.LogLevel,
		ColorOutput:   cfg.ColorOutput,
		DebugTrace:    cfg.DebugTrace,
		DebugTraceLog: cfg.DebugTraceLog,
	}

	// Network settings
	data.Network = ui.NetworkSettingsData{
		GUIAddr: cfg.GUIAddr,
		APIAddr: cfg.APIAddr,
	}

	// Paths (read-only)
	data.Paths = ui.PathSettingsData{
		Bin:       cfg.Bin,
		CoreBin:   cfg.CoreBin,
		UIBin:     cfg.UIBin,
		LibDir:    cfg.LibDir,
		ConfigDir: cfg.ConfigDir,
		DataDir:   cfg.DataDir,
		LogDir:    cfg.LogDir,
		CacheDir:  cfg.CacheDir,
		RunDir:    cfg.RunDir,
	}

	// Try to get additional config info from CLI
	if output, err := execNFTBanCommand("config", "info", "--json"); err == nil {
		var configInfo map[string]interface{}
		if json.Unmarshal([]byte(extractJSON(output)), &configInfo) == nil {
			if version, ok := configInfo["version"].(string); ok {
				data.General.Version = version
			}
			if modified, ok := configInfo["last_modified"].(string); ok {
				data.LastModified = modified
			}
		}
	}

	return data
}

// convertToBasicSettings converts ExtendedSettingsData to ui.SettingsData for existing templates
func (h *GOTHHandlers) convertToBasicSettings(ext ui.ExtendedSettingsData) ui.SettingsData {
	return ui.SettingsData{
		System: ui.SystemSettings{
			Timezone:         "UTC", // Default, could be read from system
			LogLevel:         ext.Logging.LogLevel,
			LogRetentionDays: 30, // Default
		},
		Security: ui.SecuritySettings{
			DefaultBanDurationHours: 24, // Default
			PermBanThreshold:        5,  // Default
			WhitelistEnabled:        true,
			AutoWhitelistPrivate:    true,
		},
		Notifications: ui.NotificationSettings{
			EmailEnabled:   false,
			WebhookEnabled: false,
			NotifyOnBan:    true,
			NotifyOnHealth: true,
		},
		Modules: ui.ModuleSettings{
			PortscanEnabled: ext.Features.PortscanEnabled,
			DDoSEnabled:     ext.Features.DDoSEnabled,
			LoginEnabled:    ext.Features.LoginMonitorEnabled,
			FeedsEnabled:    ext.Features.FeedsEnabled,
			GeobanEnabled:   ext.Features.GeoIPEnabled,
		},
	}
}

// =============================================================================
// HELPER FUNCTIONS
// =============================================================================

// buildFeatureArgs builds config set arguments for feature toggles
func (h *GOTHHandlers) buildFeatureArgs(r *http.Request) ([]string, bool) {
	args := []string{}

	// Helper to get checkbox value (present = true, absent = false)
	checkboxValue := func(name string) string {
		if r.FormValue(name) == "on" || r.FormValue(name) == "true" || r.FormValue(name) == "1" {
			return "true"
		}
		return "false"
	}

	// Only add if form field was submitted
	if r.Form.Has("metrics_enabled") || r.Form.Has("features_metrics_enabled") {
		args = append(args, "NFTBAN_METRICS_ENABLED="+checkboxValue("metrics_enabled"))
	}
	if r.Form.Has("geoip_enabled") || r.Form.Has("features_geoip_enabled") {
		args = append(args, "NFTBAN_GEOIP_ENABLED="+checkboxValue("geoip_enabled"))
	}
	if r.Form.Has("feeds_enabled") || r.Form.Has("features_feeds_enabled") {
		args = append(args, "NFTBAN_FEEDS_ENABLED="+checkboxValue("feeds_enabled"))
	}
	if r.Form.Has("feeds_auto_update") || r.Form.Has("features_feeds_auto_update") {
		args = append(args, "NFTBAN_FEEDS_AUTO_UPDATE="+checkboxValue("feeds_auto_update"))
	}
	if r.Form.Has("suricata_enabled") || r.Form.Has("features_suricata_enabled") {
		args = append(args, "NFTBAN_SURICATA_ENABLED="+checkboxValue("suricata_enabled"))
	}
	if r.Form.Has("gui_enabled") || r.Form.Has("features_gui_enabled") {
		args = append(args, "NFTBAN_GUI_ENABLED="+checkboxValue("gui_enabled"))
	}
	if r.Form.Has("portscan_enabled") || r.Form.Has("features_portscan_enabled") {
		args = append(args, "NFTBAN_PORTSCAN_ENABLED="+checkboxValue("portscan_enabled"))
	}
	if r.Form.Has("ddos_enabled") || r.Form.Has("features_ddos_enabled") {
		args = append(args, "NFTBAN_DDOS_ENABLED="+checkboxValue("ddos_enabled"))
	}
	if r.Form.Has("login_monitor_enabled") || r.Form.Has("features_login_monitor_enabled") {
		args = append(args, "NFTBAN_LOGIN_MONITOR_ENABLED="+checkboxValue("login_monitor_enabled"))
	}
	if r.Form.Has("grafana_enabled") || r.Form.Has("features_grafana_enabled") {
		args = append(args, "NFTBAN_GRAFANA_ENABLED="+checkboxValue("grafana_enabled"))
	}

	return args, len(args) > 0
}

// buildMetricsArgs builds config set arguments for metrics settings
func (h *GOTHHandlers) buildMetricsArgs(r *http.Request) ([]string, bool) {
	args := []string{}

	if val := r.FormValue("metrics_backend"); val != "" {
		args = append(args, "NFTBAN_METRICS_BACKEND="+val)
	}
	if val := r.FormValue("metrics_sampling_interval"); val != "" {
		if _, err := strconv.Atoi(val); err == nil {
			args = append(args, "NFTBAN_METRICS_SAMPLING_INTERVAL="+val)
		}
	}
	if val := r.FormValue("metrics_max_samples"); val != "" {
		if _, err := strconv.Atoi(val); err == nil {
			args = append(args, "NFTBAN_METRICS_MAX_SAMPLES="+val)
		}
	}
	if val := r.FormValue("prometheus_dir"); val != "" {
		args = append(args, "NFTBAN_PROMETHEUS_DIR="+val)
	}
	if val := r.FormValue("prometheus_addr"); val != "" {
		args = append(args, "NFTBAN_METRICS_PROMETHEUS_ADDR="+val)
	}
	if val := r.FormValue("node_exporter_addr"); val != "" {
		args = append(args, "NFTBAN_METRICS_NODE_EXPORTER_ADDR="+val)
	}
	if val := r.FormValue("victoria_addr"); val != "" {
		args = append(args, "NFTBAN_METRICS_VICTORIA_ADDR="+val)
	}

	return args, len(args) > 0
}

// buildGeoIPArgs builds config set arguments for GeoIP settings
func (h *GOTHHandlers) buildGeoIPArgs(r *http.Request) ([]string, bool) {
	args := []string{}

	// License key - only update if a new value is provided (not masked)
	if val := r.FormValue("geoip_license_key"); val != "" && !strings.Contains(val, "*") {
		args = append(args, "NFTBAN_GEOIP_LICENSE_KEY="+val)
	}

	return args, len(args) > 0
}

// buildSuricataArgs builds config set arguments for Suricata settings
func (h *GOTHHandlers) buildSuricataArgs(r *http.Request) ([]string, bool) {
	args := []string{}

	if val := r.FormValue("suricata_eve_log"); val != "" {
		args = append(args, "NFTBAN_SURICATA_EVE_LOG="+val)
	}
	if val := r.FormValue("suricata_log_dir"); val != "" {
		args = append(args, "NFTBAN_SURICATA_LOG_DIR="+val)
	}
	if val := r.FormValue("suricata_ban_threshold"); val != "" {
		if _, err := strconv.Atoi(val); err == nil {
			args = append(args, "NFTBAN_SURICATA_BAN_THRESHOLD="+val)
		}
	}
	if val := r.FormValue("suricata_score_decay"); val != "" {
		if _, err := strconv.Atoi(val); err == nil {
			args = append(args, "NFTBAN_SURICATA_SCORE_DECAY="+val)
		}
	}
	if r.Form.Has("suricata_cloudflare_whitelist") {
		val := "false"
		if r.FormValue("suricata_cloudflare_whitelist") == "on" ||
			r.FormValue("suricata_cloudflare_whitelist") == "true" {
			val = "true"
		}
		args = append(args, "NFTBAN_SURICATA_CLOUDFLARE_WHITELIST="+val)
	}

	return args, len(args) > 0
}

// buildLoggingArgs builds config set arguments for logging settings
func (h *GOTHHandlers) buildLoggingArgs(r *http.Request) ([]string, bool) {
	args := []string{}

	if val := r.FormValue("log_level"); val != "" {
		// Validate log level using package-level map
		if validLogLevels[strings.ToUpper(val)] {
			args = append(args, "NFTBAN_LOG_LEVEL="+strings.ToUpper(val))
		}
	}
	if r.Form.Has("color_output") {
		val := "false"
		if r.FormValue("color_output") == "on" || r.FormValue("color_output") == "true" {
			val = "true"
		}
		args = append(args, "NFTBAN_COLOR_OUTPUT="+val)
	}
	if r.Form.Has("debug_trace") {
		val := "false"
		if r.FormValue("debug_trace") == "on" || r.FormValue("debug_trace") == "true" {
			val = "true"
		}
		args = append(args, "NFTBAN_DEBUG_TRACE="+val)
	}
	if val := r.FormValue("debug_trace_log"); val != "" {
		args = append(args, "NFTBAN_DEBUG_TRACE_LOG="+val)
	}

	return args, len(args) > 0
}

// buildNetworkArgs builds config set arguments for network settings
func (h *GOTHHandlers) buildNetworkArgs(r *http.Request) ([]string, bool) {
	args := []string{}

	if val := r.FormValue("gui_addr"); val != "" {
		args = append(args, "NFTBAN_GUI_ADDR="+val)
	}
	if val := r.FormValue("api_addr"); val != "" {
		args = append(args, "NFTBAN_API_ADDR="+val)
	}

	return args, len(args) > 0
}

// sendSettingsSuccess sends a success response (HTMX compatible)
// v1.19.0: HTML-escape message to prevent XSS (R37)
func (h *GOTHHandlers) sendSettingsSuccess(w http.ResponseWriter, message string) {
	escaped := html.EscapeString(message)
	w.Header().Set("HX-Trigger", jsonMarshalHXTrigger(escaped, "success"))
	w.WriteHeader(http.StatusOK)
	fmt.Fprintf(w, `<div class="alert alert-success">%s</div>`, escaped)
}

// sendSettingsError sends an error response (HTMX compatible)
// v1.19.0: HTML-escape message to prevent XSS (R37)
func (h *GOTHHandlers) sendSettingsError(w http.ResponseWriter, message string) {
	escaped := html.EscapeString(message)
	w.Header().Set("HX-Trigger", jsonMarshalHXTrigger(escaped, "error"))
	w.WriteHeader(http.StatusBadRequest)
	fmt.Fprintf(w, `<div class="alert alert-error">%s</div>`, escaped)
}

// extractJSON extracts JSON from CLI output that may contain non-JSON prefix/suffix
func extractJSON(output string) string {
	// Find first { or [
	start := strings.IndexAny(output, "{[")
	if start == -1 {
		return output
	}

	// Find matching closing bracket
	depth := 0
	openChar := rune(output[start])
	closeChar := '}'
	if openChar == '[' {
		closeChar = ']'
	}

	for i := start; i < len(output); i++ {
		ch := rune(output[i])
		if ch == openChar {
			depth++
		} else if ch == closeChar {
			depth--
			if depth == 0 {
				return output[start : i+1]
			}
		}
	}

	return output[start:]
}

