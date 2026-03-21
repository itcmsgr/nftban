// =============================================================================
// NFTBan - Web UI Server (GOTH GUI)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="main"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="HTTPS web server providing GOTH GUI dashboard for NFTBan management"
// meta:input="Command line flags (config, port, cert, key, version)"
// meta:output="HTTPS web server on configured port"
// meta:depends="github.com/gorilla/mux,github.com/itcmsgr/nftban/pkg/api,github.com/itcmsgr/nftban/pkg/auth"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/ui.conf,/etc/nftban/ssl/cert.pem,/etc/nftban/ssl/key.pem"
// meta:inventory.systemd_units="nftban-ui.service"
// meta:inventory.network="https:3940"
// meta:inventory.privileges="none"
// =============================================================================

package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/gorilla/mux"
	"github.com/itcmsgr/nftban/cmd/nftban-ui/handlers"
	"github.com/itcmsgr/nftban/internal/config"
	"github.com/itcmsgr/nftban/pkg/api"
	"github.com/itcmsgr/nftban/pkg/auth"
	"github.com/itcmsgr/nftban/pkg/metrics"
	"github.com/itcmsgr/nftban/pkg/version"
	"github.com/itcmsgr/nftban/pkg/middleware"
	"github.com/itcmsgr/nftban/pkg/nftbanconf"
	"github.com/itcmsgr/nftban/pkg/safety"
	"github.com/itcmsgr/nftban/pkg/session"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

const (
	AppName = "NFTBan Web GUI"
)

// Build-time variables (injected by -ldflags)
var (
	GitCommit = "dev"
	BuildDate = "unknown"
)

func main() {
	// Initialize CPU/memory safety limits (from environment)
	limits := safety.FromEnv()
	safety.InitCPU(limits)
	safety.InitMemory(limits)

	// Log resource limits
	mem := safety.AvailableMem()
	log.Printf("Resource Limits: CPU=%d cores, MaxMem=%s, AvailMem=%s",
		limits.GoMaxProcs,
		safety.FormatBytes(limits.MaxMemoryBytes),
		safety.FormatBytes(mem.Avail))

	// Get default paths from central config
	nftbanCfg := nftbanconf.MustLoad()
	defaultConfigDir := nftbanCfg.ConfigDir

	// Command line flags
	configPath := flag.String("config", defaultConfigDir+"/ui.conf", "Path to configuration file")
	port := flag.Int("port", 3940, "HTTPS port to listen on")
	certFile := flag.String("cert", defaultConfigDir+"/ssl/cert.pem", "TLS certificate file")
	keyFile := flag.String("key", defaultConfigDir+"/ssl/key.pem", "TLS private key file")
	showVersion := flag.Bool("version", false, "Show version information")
	flag.Parse()

	// Show version
	if *showVersion {
		fmt.Printf("nftban-ui v%s (git %s, build %s)\n", version.Version, GitCommit, BuildDate)
		os.Exit(0)
	}

	// Load configuration
	cfg, err := config.Load(*configPath)
	if err != nil {
		log.Fatalf("Failed to load configuration: %v", err)
	}

	// SECURITY: Validate JWT secret configuration
	// This prevents the server from starting with weak/missing secrets
	if err := config.ValidateJWTSecret(cfg.JWTSecret); err != nil {
		log.Fatalf("Security error: %v. Set JWT_SECRET environment variable or configure in %s", err, *configPath)
	}

	// Override with command line flags
	if *port != 3940 {
		cfg.Port = *port
	}
	if *certFile != defaultConfigDir+"/ssl/cert.pem" {
		cfg.TLSCert = *certFile
	}
	if *keyFile != defaultConfigDir+"/ssl/key.pem" {
		cfg.TLSKey = *keyFile
	}

	// Initialize authentication (PAM service for user validation)
	authService, err := auth.NewPAMAuth(cfg)
	if err != nil {
		log.Fatalf("Failed to initialize authentication: %v", err)
	}

	// Initialize session store (in-memory, with configurable timeout)
	sessionTimeout := time.Duration(cfg.SessionTimeout) * time.Minute
	sessionStore := session.NewStore(sessionTimeout)
	log.Printf("[SESSION] Session store initialized (timeout: %v)", sessionTimeout)

	// Start session cleanup goroutine (runs every 5 minutes)
	go func() {
		ticker := time.NewTicker(5 * time.Minute)
		defer ticker.Stop()
		for range ticker.C {
			cleaned := sessionStore.Cleanup()
			if cleaned > 0 {
				log.Printf("[SESSION] Cleaned up %d expired sessions", cleaned)
			}
		}
	}()

	// Create router
	router := mux.NewRouter()

	// Apply middleware
	router.Use(middleware.LoggingMiddleware)
	router.Use(middleware.IPWhitelistMiddleware(cfg))
	router.Use(middleware.SecurityHeadersMiddleware)
	router.Use(middleware.MaxBodySizeMiddleware(1 << 20)) // 1MB request body limit
	router.Use(middleware.CSRFMiddleware(sessionStore))

	// Create rate limiter for login endpoints (brute force protection)
	// 5 attempts per minute per IP address
	loginRateLimiter := middleware.NewRateLimiter(5, time.Minute)
	log.Printf("[SECURITY] Login rate limiter initialized (5 attempts/minute per IP)")

	// ==========================================================================
	// GOTH GUI Routes (Go + Templ + HTMX) - v1.1.0
	// ==========================================================================
	gothHandlers := handlers.NewGOTHHandlers(authService, sessionStore)

	// Public GOTH routes (login page rate limited for brute force protection)
	router.HandleFunc("/ui/login", gothHandlers.HandleLogin).Methods("GET")
	router.HandleFunc("/ui/action/login", loginRateLimiter.WrapHandler(gothHandlers.HandleActionLogin)).Methods("POST")

	// Protected GOTH routes (require session)
	router.HandleFunc("/ui/", gothHandlers.RequireSession(gothHandlers.HandleDashboard)).Methods("GET")
	router.HandleFunc("/ui/bans", gothHandlers.RequireSession(gothHandlers.HandleBans)).Methods("GET")
	router.HandleFunc("/ui/whitelist", gothHandlers.RequireSession(gothHandlers.HandleWhitelist)).Methods("GET")
	router.HandleFunc("/ui/events", gothHandlers.RequireSession(gothHandlers.HandleEvents)).Methods("GET")
	router.HandleFunc("/ui/tools", gothHandlers.RequireSession(gothHandlers.HandleTools)).Methods("GET")
	router.HandleFunc("/ui/health", gothHandlers.RequireSession(gothHandlers.HandleHealth)).Methods("GET")
	router.HandleFunc("/ui/modules", gothHandlers.RequireSession(gothHandlers.HandleModules)).Methods("GET")
	router.HandleFunc("/ui/inventory", gothHandlers.RequireSession(gothHandlers.HandleInventory)).Methods("GET")
	router.HandleFunc("/ui/metrics", gothHandlers.RequireSession(gothHandlers.HandleMetrics)).Methods("GET")
	router.HandleFunc("/ui/geoip", gothHandlers.RequireSession(gothHandlers.HandleGeoIP)).Methods("GET")
	router.HandleFunc("/ui/feeds", gothHandlers.RequireSession(gothHandlers.HandleFeeds)).Methods("GET")
	router.HandleFunc("/ui/system", gothHandlers.RequireSession(gothHandlers.HandleSystem)).Methods("GET")
	router.HandleFunc("/ui/network", gothHandlers.RequireSession(gothHandlers.HandleNetwork)).Methods("GET")
	router.HandleFunc("/ui/settings", gothHandlers.RequireSession(gothHandlers.HandleSettings)).Methods("GET")
	router.HandleFunc("/ui/action/logout", gothHandlers.RequireSession(gothHandlers.HandleActionLogout)).Methods("POST")

	// GOTH fragments (HTMX partial updates) - Professional Dashboard
	router.HandleFunc("/ui/frag/identity", gothHandlers.RequireSession(gothHandlers.HandleFragIdentity)).Methods("GET")
	router.HandleFunc("/ui/frag/security", gothHandlers.RequireSession(gothHandlers.HandleFragSecurity)).Methods("GET")
	router.HandleFunc("/ui/frag/network", gothHandlers.RequireSession(gothHandlers.HandleFragNetwork)).Methods("GET")
	router.HandleFunc("/ui/frag/resources", gothHandlers.RequireSession(gothHandlers.HandleFragResources)).Methods("GET")
	router.HandleFunc("/ui/frag/modules", gothHandlers.RequireSession(gothHandlers.HandleFragModules)).Methods("GET")
	router.HandleFunc("/ui/frag/recent", gothHandlers.RequireSession(gothHandlers.HandleFragRecent)).Methods("GET")
	router.HandleFunc("/ui/frag/inventory", gothHandlers.RequireSession(gothHandlers.HandleFragInventory)).Methods("GET")
	router.HandleFunc("/ui/frag/bans-table", gothHandlers.RequireSession(gothHandlers.HandleFragBansTable)).Methods("GET")
	router.HandleFunc("/ui/frag/whitelist-table", gothHandlers.RequireSession(gothHandlers.HandleFragWhitelistTable)).Methods("GET")
	router.HandleFunc("/ui/frag/events-table", gothHandlers.RequireSession(gothHandlers.HandleFragEventsTable)).Methods("GET")
	router.HandleFunc("/ui/frag/logs", gothHandlers.RequireSession(gothHandlers.HandleFragLogs)).Methods("GET")

	// Backwards compat fragments
	router.HandleFunc("/ui/frag/summary", gothHandlers.RequireSession(gothHandlers.HandleFragSummary)).Methods("GET")
	router.HandleFunc("/ui/frag/system", gothHandlers.RequireSession(gothHandlers.HandleFragSystem)).Methods("GET")
	router.HandleFunc("/ui/frag/health", gothHandlers.RequireSession(gothHandlers.HandleFragHealth)).Methods("GET")
	router.HandleFunc("/ui/frag/services-quick", gothHandlers.RequireSession(gothHandlers.HandleFragServicesQuick)).Methods("GET")
	router.HandleFunc("/ui/frag/ban-stats", gothHandlers.RequireSession(gothHandlers.HandleFragBanStats)).Methods("GET")
	router.HandleFunc("/ui/frag/whitelist-stats", gothHandlers.RequireSession(gothHandlers.HandleFragWhitelistStats)).Methods("GET")
	router.HandleFunc("/ui/frag/health-all", gothHandlers.RequireSession(gothHandlers.HandleFragHealthAll)).Methods("GET")
	router.HandleFunc("/ui/frag/modules-list", gothHandlers.RequireSession(gothHandlers.HandleFragModulesList)).Methods("GET")
	router.HandleFunc("/ui/frag/module/{name}/logs", gothHandlers.RequireSession(gothHandlers.HandleFragModuleLogs)).Methods("GET")
	router.HandleFunc("/ui/frag/module/{name}/settings", gothHandlers.RequireSession(gothHandlers.HandleFragModuleSettings)).Methods("GET")

	// Metrics pages fragments (HTMX partial updates)
	router.HandleFunc("/ui/frag/metrics-summary", gothHandlers.RequireSession(gothHandlers.HandleFragMetricsSummary)).Methods("GET")
	router.HandleFunc("/ui/frag/geoip", gothHandlers.RequireSession(gothHandlers.HandleFragGeoIP)).Methods("GET")
	router.HandleFunc("/ui/frag/geoip-countries", gothHandlers.RequireSession(gothHandlers.HandleFragGeoIPCountries)).Methods("GET")
	router.HandleFunc("/ui/frag/geoip-recent", gothHandlers.RequireSession(gothHandlers.HandleFragGeoIPRecent)).Methods("GET")
	router.HandleFunc("/ui/frag/system-info", gothHandlers.RequireSession(gothHandlers.HandleFragSystemInfo)).Methods("GET")
	router.HandleFunc("/ui/frag/network-stats", gothHandlers.RequireSession(gothHandlers.HandleFragNetworkStats)).Methods("GET")
	router.HandleFunc("/ui/frag/feeds", gothHandlers.RequireSession(gothHandlers.HandleFragFeeds)).Methods("GET")

	// SSE (Server-Sent Events) endpoint for real-time dashboard updates
	router.HandleFunc("/ui/sse/dashboard", gothHandlers.RequireSession(gothHandlers.HandleSSEDashboard)).Methods("GET")

	// Dashboard API endpoints
	router.HandleFunc("/ui/api/ip-check", gothHandlers.RequireSession(gothHandlers.HandleIPCheck)).Methods("GET")

	// Chart data API endpoints (for dashboard visualizations)
	router.HandleFunc("/ui/api/chart/traffic", gothHandlers.RequireSession(gothHandlers.HandleChartTraffic)).Methods("GET")
	router.HandleFunc("/ui/api/chart/bans", gothHandlers.RequireSession(gothHandlers.HandleChartBans)).Methods("GET")
	router.HandleFunc("/ui/api/chart/countries", gothHandlers.RequireSession(gothHandlers.HandleChartCountries)).Methods("GET")
	router.HandleFunc("/ui/api/chart/portscan", gothHandlers.RequireSession(gothHandlers.HandleChartPortscan)).Methods("GET")
	router.HandleFunc("/ui/api/chart/bans-timeline", gothHandlers.RequireSession(gothHandlers.HandleChartBansTimeline)).Methods("GET")

	// Dashboard action endpoints
	router.HandleFunc("/ui/action/flush-temp", gothHandlers.RequireSession(gothHandlers.HandleFlushTemp)).Methods("POST")
	router.HandleFunc("/ui/action/restart/{service}", gothHandlers.RequireSession(gothHandlers.HandleRestartService)).Methods("POST")
	router.HandleFunc("/ui/action/health-fix", gothHandlers.RequireSession(gothHandlers.HandleHealthFix)).Methods("POST")
	router.HandleFunc("/ui/action/sync-feeds", gothHandlers.RequireSession(gothHandlers.HandleSyncFeeds)).Methods("POST")
	router.HandleFunc("/ui/action/sync-feed/{name}", gothHandlers.RequireSession(gothHandlers.HandleSyncFeed)).Methods("POST")
	router.HandleFunc("/ui/action/feed-toggle/{name}", gothHandlers.RequireSession(gothHandlers.HandleFeedToggle)).Methods("POST")

	// Bulk operations endpoints (multi-select ban/unban)
	router.HandleFunc("/ui/action/bulk-unban", gothHandlers.RequireSession(gothHandlers.HandleBulkUnban)).Methods("POST")
	router.HandleFunc("/ui/action/bulk-delete", gothHandlers.RequireSession(gothHandlers.HandleBulkDelete)).Methods("POST")

	// Tools page API endpoints (diagnostic tools)
	router.HandleFunc("/api/v1/tools/check", gothHandlers.RequireSession(gothHandlers.HandleToolsIPCheck)).Methods("POST")
	router.HandleFunc("/api/v1/tools/geoip", gothHandlers.RequireSession(gothHandlers.HandleToolsGeoIP)).Methods("POST")
	router.HandleFunc("/api/v1/tools/search", gothHandlers.RequireSession(gothHandlers.HandleToolsSearch)).Methods("POST")

	// Settings page endpoints
	router.HandleFunc("/ui/api/settings/save", gothHandlers.RequireSession(gothHandlers.HandleSettingsSave)).Methods("POST")
	router.HandleFunc("/ui/frag/settings-content", gothHandlers.RequireSession(gothHandlers.HandleFragSettingsSection)).Methods("GET")

	log.Printf("[GOTH] GOTH GUI routes registered at /ui/*")

	// ==========================================================================
	// REST API Routes (v1) - Backend API for programmatic access
	// ==========================================================================
	apiRouter := router.PathPrefix("/api/v1").Subrouter()

	// Public routes (no auth required) - rate limited for brute force protection
	apiRouter.HandleFunc("/login", loginRateLimiter.WrapHandler(api.SessionLoginHandler(authService, sessionStore))).Methods("POST")

	// Protected routes (auth required)
	protected := apiRouter.PathPrefix("").Subrouter()
	protected.Use(middleware.SessionAuthMiddleware(sessionStore))

	// Session management routes
	protected.HandleFunc("/logout", api.LogoutHandler(sessionStore)).Methods("POST")
	protected.HandleFunc("/session", api.SessionInfoHandler(sessionStore)).Methods("GET")
	protected.HandleFunc("/sessions", api.SessionsListHandler(sessionStore)).Methods("GET")
	protected.HandleFunc("/sessions/revoke", api.SessionRevokeHandler(sessionStore)).Methods("POST")

	protected.HandleFunc("/me", api.MeHandler).Methods("GET")
	protected.HandleFunc("/dashboard", api.DashboardHandler).Methods("GET")
	protected.HandleFunc("/status", api.StatusHandler).Methods("GET")
	protected.HandleFunc("/health", api.HealthHandler).Methods("GET")
	protected.HandleFunc("/health/fix", api.HealthFixHandler).Methods("POST")
	protected.HandleFunc("/ban", api.BanHandler).Methods("POST")
	protected.HandleFunc("/unban", api.UnbanHandler).Methods("POST")
	protected.HandleFunc("/search", api.SearchHandler).Methods("GET")
	protected.HandleFunc("/whitelist", api.WhitelistGetHandler).Methods("GET")
	protected.HandleFunc("/whitelist", api.WhitelistAddHandler).Methods("POST")
	protected.HandleFunc("/whitelist/add", api.WhitelistAddHandler).Methods("POST")
	protected.HandleFunc("/whitelist/remove", api.WhitelistRemoveHandler).Methods("POST")
	protected.HandleFunc("/feeds", api.FeedsHandler).Methods("GET")
	protected.HandleFunc("/feeds/control", api.FeedsControlHandler).Methods("POST")
	protected.HandleFunc("/logs", api.LogsHandler).Methods("GET")
	protected.HandleFunc("/logs/viewer", api.LogsViewerHandler).Methods("GET")
	protected.HandleFunc("/rules", api.RulesHandler).Methods("GET")
	protected.HandleFunc("/geo", api.GeoHandler).Methods("GET")
	protected.HandleFunc("/reload", api.ReloadHandler).Methods("POST")
	protected.HandleFunc("/sync-feeds", api.SyncFeedsHandler).Methods("POST")
	protected.HandleFunc("/flush", api.FlushHandler).Methods("POST")
	protected.HandleFunc("/ui/whitelist", api.UIWhitelistGetHandler).Methods("GET")
	protected.HandleFunc("/ui/whitelist", api.UIWhitelistAddHandler).Methods("POST")
	protected.HandleFunc("/ui/list-ips", api.UIListBannedIPsHandler).Methods("GET")

	// Metrics API routes
	protected.HandleFunc("/metrics/enable", api.MetricsEnableHandler).Methods("POST")
	protected.HandleFunc("/metrics/status", api.MetricsStatusHandler).Methods("GET")
	protected.HandleFunc("/metrics/snapshot", api.MetricsSnapshotHandler).Methods("GET")

	// Dashboard Statistics API routes
	protected.HandleFunc("/stats/traffic", api.StatsTrafficHandler).Methods("GET")
	protected.HandleFunc("/stats/bans", api.StatsBansHandler).Methods("GET")
	protected.HandleFunc("/stats/countries", api.StatsCountriesHandler).Methods("GET")
	protected.HandleFunc("/stats/trend", api.StatsTrendHandler).Methods("GET")
	protected.HandleFunc("/basic-stats", api.BasicStatsHandler).Methods("GET") // Shared state - NO CLI
	protected.HandleFunc("/system/hostname", api.SystemHostnameHandler).Methods("GET")
	protected.HandleFunc("/feeds/stats", api.FeedsStatsHandler).Methods("GET")
	protected.HandleFunc("/whitelist/count", api.WhitelistCountHandler).Methods("GET")

	// Network monitoring API routes
	protected.HandleFunc("/network/bandwidth", api.BandwidthHandler).Methods("GET")
	protected.HandleFunc("/network/connections", api.ConnectionsHandler).Methods("GET")
	protected.HandleFunc("/network/metrics/samples", api.MetricsSamplesHandler).Methods("GET")

	// Bandwidth monitoring API routes
	protected.HandleFunc("/bandwidth/current", api.BandwidthCurrentHandler).Methods("GET")
	protected.HandleFunc("/bandwidth/history", api.BandwidthHistoryHandler).Methods("GET")
	protected.HandleFunc("/bandwidth/interfaces", api.BandwidthInterfacesHandler).Methods("GET")
	protected.HandleFunc("/bandwidth/connections", api.BandwidthConnectionsHandler).Methods("GET")

	// Firewall validation and checking API routes
	protected.HandleFunc("/firewall/validate", api.FirewallValidateHandler).Methods("GET")
	protected.HandleFunc("/firewall/check", api.FirewallCheckHandler).Methods("POST")
	protected.HandleFunc("/firewall/stats", api.FirewallStatsHandler).Methods("GET")

	// NFTables API routes
	protected.HandleFunc("/nftables/ruleset", api.NFTablesRulesetHandler).Methods("GET")
	protected.HandleFunc("/nftables/validate", api.NFTablesValidateHandler).Methods("GET")
	protected.HandleFunc("/nftables/save", api.NFTablesSaveHandler).Methods("POST")

	// Emulate/Validator API routes
	protected.HandleFunc("/emulate", api.EmulateHandler).Methods("GET")
	protected.HandleFunc("/emulate/quick", api.EmulateQuickHandler).Methods("GET")
	protected.HandleFunc("/emulate/batch", api.EmulateBatchHandler).Methods("POST")

	// Portscan API routes
	protected.HandleFunc("/portscan/control", api.PortscanControlHandler).Methods("POST")
	protected.HandleFunc("/portscan/stats", api.PortscanStatsHandler).Methods("GET")

	// DDoS API routes
	protected.HandleFunc("/ddos/stats", api.DDoSStatsHandler).Methods("GET")
	protected.HandleFunc("/ddos/enable", api.DDoSEnableHandler).Methods("POST")
	protected.HandleFunc("/ddos/disable", api.DDoSDisableHandler).Methods("POST")

	// Login Monitor API routes
	protected.HandleFunc("/login-monitor/status", api.LoginMonitorStatusHandler).Methods("GET")
	protected.HandleFunc("/login-monitor/stats", api.LoginMonitorStatsHandler).Methods("GET")
	protected.HandleFunc("/login-monitor/events", api.LoginMonitorEventsHandler).Methods("GET")
	protected.HandleFunc("/login-monitor/users", api.LoginMonitorUsersHandler).Methods("GET")
	protected.HandleFunc("/login-monitor/control", api.LoginMonitorControlHandler).Methods("POST")

	// Suricata IDS API routes
	protected.HandleFunc("/suricata/status", api.SuricataStatusHandler).Methods("GET")
	protected.HandleFunc("/suricata/control", api.SuricataControlHandler).Methods("POST")
	protected.HandleFunc("/suricata/profile/detect", api.SuricataProfileDetectHandler).Methods("POST")
	protected.HandleFunc("/suricata/profile/apply", api.SuricataProfileApplyHandler).Methods("POST")
	protected.HandleFunc("/suricata/profile/show", api.SuricataProfileShowHandler).Methods("GET")
	protected.HandleFunc("/suricata/scan", api.SuricataScanHandler).Methods("POST")
	protected.HandleFunc("/suricata/services", api.SuricataServicesHandler).Methods("GET")
	protected.HandleFunc("/suricata/rules/stats", api.SuricataRulesStatsHandler).Methods("GET")
	protected.HandleFunc("/suricata/rules/reload", api.SuricataRulesReloadHandler).Methods("POST")
	protected.HandleFunc("/suricata/rules/generate", api.SuricataRulesGenerateHandler).Methods("POST")
	protected.HandleFunc("/suricata/rules/update", api.SuricataRulesUpdateHandler).Methods("POST")
	protected.HandleFunc("/suricata/alerts", api.SuricataAlertsHandler).Methods("GET")
	protected.HandleFunc("/suricata/config/validate", api.SuricataConfigValidateHandler).Methods("POST")

	// Port Management API routes
	protected.HandleFunc("/ports", api.PortsHandler).Methods("GET")
	protected.HandleFunc("/ports/ban", api.PortBanHandler).Methods("POST")
	protected.HandleFunc("/ports/unban", api.PortUnbanHandler).Methods("POST")
	protected.HandleFunc("/ports/status", api.PortStatusHandler).Methods("GET")

	// Configuration API routes
	protected.HandleFunc("/config/{module}", api.ConfigGetHandler).Methods("GET")
	protected.HandleFunc("/config/{module}", api.ConfigSetHandler).Methods("POST")
	protected.HandleFunc("/config/{module}/reset", api.ConfigResetHandler).Methods("POST")

	// Log file API route (uses ?path= query parameter for file path)
	// Registered after /logs and /logs/viewer to avoid conflicts
	protected.HandleFunc("/logs/file", api.LogFileHandler).Methods("GET")

	// Config file editor API route (parses file path from URL)
	// Registered after /config/{module} to avoid conflicts with module config handlers
	protected.HandleFunc("/config/file/{path:.*}", api.ConfigFileHandler).Methods("GET", "POST")

	// System API routes
	protected.HandleFunc("/system/services", api.SystemServicesHandler).Methods("GET")
	protected.HandleFunc("/system/modules", api.SystemModulesHandler).Methods("GET")
	protected.HandleFunc("/system/timers", api.SystemTimersHandler).Methods("GET")
	protected.HandleFunc("/system/service/control", api.SystemServiceControlHandler).Methods("POST")

	// System Management routes
	protected.HandleFunc("/system/status", api.SystemOverviewStatusHandler).Methods("GET")
	protected.HandleFunc("/system/info", api.SystemInfoHandler).Methods("GET")
	protected.HandleFunc("/system/health", api.SystemHealthHandler).Methods("GET")
	protected.HandleFunc("/system/health/fix", api.SystemHealthFixHandler).Methods("POST")
	protected.HandleFunc("/system/fhs", api.SystemFHSHandler).Methods("GET")
	protected.HandleFunc("/system/fhs/fix", api.SystemFHSFixHandler).Methods("POST")
	protected.HandleFunc("/system/timers/detail", api.SystemTimersDetailHandler).Methods("GET")
	protected.HandleFunc("/system/services/detail", api.SystemServicesDetailHandler).Methods("GET")

	// Dashboard API routes
	protected.HandleFunc("/prometheus/metrics", api.PrometheusMetricsHandler).Methods("GET")
	protected.HandleFunc("/portscan/logs", api.PortScanLogsHandler).Methods("GET")
	protected.HandleFunc("/geoban/stats", api.GeoBanStatsHandler).Methods("GET")
	protected.HandleFunc("/system/logs", api.SystemLogsHandler).Methods("GET")
	protected.HandleFunc("/dashboard/metrics", api.DashboardMetricsHandler).Methods("GET")

	// Analytics API routes
	protected.HandleFunc("/analytics/summary", api.AnalyticsSummaryHandler).Methods("GET")
	protected.HandleFunc("/analytics/countries", api.AnalyticsCountriesHandler).Methods("GET")
	protected.HandleFunc("/analytics/top", api.AnalyticsTopCountriesHandler).Methods("GET")
	protected.HandleFunc("/analytics/ip", api.AnalyticsIPHandler).Methods("GET")

	// Activity API routes
	protected.HandleFunc("/activity/recent", api.RecentActivityHandler).Methods("GET")

	// ==========================================================================
	// Prometheus metrics endpoint (public for scraping)
	// ==========================================================================
	sampler := metrics.GetSampler()
	router.Handle("/metrics", promhttp.HandlerFor(sampler.Registry(), promhttp.HandlerOpts{})).Methods("GET")

	// ==========================================================================
	// Root redirect to GOTH UI
	// ==========================================================================
	router.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/ui/", http.StatusFound)
	})

	// Server configuration with safety limits
	addr := fmt.Sprintf(":%d", cfg.Port)
	requestTimeout := time.Duration(limits.RequestTimeoutSec) * time.Second
	server := &http.Server{
		Addr:           addr,
		Handler:        router,
		ReadTimeout:    requestTimeout,
		WriteTimeout:   requestTimeout,
		IdleTimeout:    60 * time.Second,
		MaxHeaderBytes: 1 << 20, // 1 MB
	}

	// Log sampler status
	samplerStatus := sampler.GetStatus()
	log.Printf("[METRICS] Global sampler initialized: running=%v, sessions=%d, period=%v",
		samplerStatus["running"], samplerStatus["active_sessions"], samplerStatus["period_seconds"])

	// Start server
	log.Printf("%s v%s starting on https://0.0.0.0:%d", AppName, version.Version, cfg.Port)
	log.Printf("TLS Certificate: %s", cfg.TLSCert)
	log.Printf("TLS Key: %s", cfg.TLSKey)
	log.Printf("Request Timeout: %v, Max Connections: %d", requestTimeout, limits.MaxConcurrentConns)

	// Handle graceful shutdown on SIGINT/SIGTERM
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)

	// Start server in goroutine so we can handle shutdown
	go func() {
		if err := server.ListenAndServeTLS(cfg.TLSCert, cfg.TLSKey); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Server failed to start: %v", err)
		}
	}()

	// Wait for shutdown signal
	sig := <-quit
	log.Printf("Received signal %v, initiating graceful shutdown...", sig)

	// Create shutdown context with 30-second timeout
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// Attempt graceful shutdown
	if err := server.Shutdown(ctx); err != nil {
		log.Fatalf("Server forced to shutdown: %v", err)
	}

	log.Printf("Server exited gracefully")
}
