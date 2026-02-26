// =============================================================================
// NFTBan v1.0 - nftband Daemon
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftband"
// meta:type="cmd"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Single daemon that runs all nftban modules with HTTP API and Unix socket"
//
// meta:inventory.files="/usr/lib/nftban/bin/nftband"
// meta:inventory.binaries="nftband"
// meta:inventory.env_vars="NFTBAN_CONFIG_DIR, NFTBAN_LOG_DIR"
// meta:inventory.config_files="/etc/nftban/nftban.conf"
// meta:inventory.systemd_units="nftband.service, nftband.socket"
// meta:inventory.network="8080/tcp (HTTP API), /run/nftban/nftband.sock (Unix)"
// meta:inventory.privileges="root"
//
// Architecture:
// - Runs all modules as goroutines
// - Provides event bus for inter-module communication
// - Serves HTTP API for GUI and external access
// - Serves Unix socket for fast CLI communication
// - Handles graceful shutdown with SIGTERM/SIGINT
//
// Usage:
//   nftband              # Run daemon
//   nftband --version    # Show version
//   nftband --help       # Show help
//
// =============================================================================

package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	nethttpprof "net/http/pprof" // BUG-H4 FIX: explicit import instead of blank import to avoid polluting DefaultServeMux
	"os"
	"os/signal"
	"os/user"
	"path/filepath"
	goruntime "runtime"
	"runtime/pprof"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/coreos/go-systemd/v22/activation"
	"github.com/google/nftables"
	"github.com/itcmsgr/nftban/pkg/analytics"
	"github.com/itcmsgr/nftban/pkg/version"
	"github.com/itcmsgr/nftban/pkg/banlog"
	"github.com/itcmsgr/nftban/pkg/ddos"
	"github.com/itcmsgr/nftban/pkg/eventbus"
	"github.com/itcmsgr/nftban/pkg/geoip"
	"github.com/itcmsgr/nftban/pkg/metrics"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/itcmsgr/nftban/pkg/feeds"
	"github.com/itcmsgr/nftban/pkg/geoban"
	"github.com/itcmsgr/nftban/pkg/loginmon"
	"github.com/itcmsgr/nftban/pkg/module"
	"github.com/itcmsgr/nftban/pkg/nftbackend"
	"github.com/itcmsgr/nftban/pkg/nftbanconf"
	"github.com/itcmsgr/nftban/pkg/persistence"
	"github.com/itcmsgr/nftban/pkg/persistent"
	"github.com/itcmsgr/nftban/pkg/ports"
	"github.com/itcmsgr/nftban/pkg/portscan"
	"github.com/itcmsgr/nftban/pkg/runtime"
	"github.com/itcmsgr/nftban/pkg/safety"
	"github.com/itcmsgr/nftban/pkg/stats"
	nftsync "github.com/itcmsgr/nftban/pkg/sync"
	"github.com/itcmsgr/nftban/pkg/opqueue"
	"github.com/itcmsgr/nftban/pkg/safeconv"
	"github.com/itcmsgr/nftban/pkg/watchdog"
	"github.com/itcmsgr/nftban/pkg/whitelist"
	"golang.org/x/sys/unix"
)

const (
	// HTTP API default (can be overridden via NFTBAN_API_ADDR config)
	DefaultHTTPAddr = "127.0.0.1:8080"

	// Profiling (pprof) - localhost only for security
	PprofAddr = "127.0.0.1:6060"

	// MaxConcurrentIPCConns limits simultaneous IPC socket connections
	MaxConcurrentIPCConns = 100
)

// validNFTBanTable checks table belongs to nftban
func validNFTBanTable(table string) bool {
	return table == "ip nftban" || table == "ip6 nftban"
}

// validNFTBanSet checks set is a known nftban set
var knownNFTBanSets = map[string]bool{
	"blacklist_ipv4": true, "blacklist_ipv6": true,
	"whitelist_ipv4": true, "whitelist_ipv6": true,
	"persistent_offenders_ipv4": true, "persistent_offenders_ipv6": true,
	"bogon_ipv4": true, "bogon_ipv6": true,
	"geoban_ipv4": true, "geoban_ipv6": true,
	"tcp_ports_in": true, "tcp_ports_out": true,
	"udp_ports_in": true, "udp_ports_out": true,
}

func validNFTBanSet(set string) bool {
	return knownNFTBanSets[set]
}

// getAPIAddr returns the HTTP API address from config or default
func getAPIAddr() string {
	cfg := nftbanconf.MustLoad()
	if cfg.APIAddr != "" {
		return cfg.APIAddr
	}
	return DefaultHTTPAddr
}

// Build-time variables (injected by -ldflags)
var (
	GitCommit = "dev"
	BuildDate = "unknown"
)

// Runtime flags
var profileEnabled = false

// banMutex protects concurrent ban operations during escalation
// to prevent race conditions when multiple goroutines attempt
// to escalate and ban the same IP simultaneously
var banMutex sync.Mutex

// syncMutex protects concurrent sync operations to prevent
// race conditions when multiple sync requests are issued simultaneously
var syncMutex sync.Mutex

// getDaemonPaths returns paths from central config
// NO FALLBACK - paths must come from /etc/nftban/nftban.conf
func getDaemonPaths() (runDir, configDir, dataDir, logDir string) {
	cfg := nftbanconf.MustLoad()
	return cfg.RunDir, cfg.ConfigDir, cfg.DataDir, cfg.LogDir
}

// getSocketPath returns socket path from central config
func getSocketPath() string {
	runDir, _, _, _ := getDaemonPaths()
	return runDir + "/nftband.sock"
}

// getPidFile returns PID file path from central config
func getPidFile() string {
	runDir, _, _, _ := getDaemonPaths()
	return runDir + "/nftband.pid"
}

// getIPCSocketTimeout returns IPC socket timeout from NFTBAN_TIMEOUT_IPC_SOCKET
// Default: 300 seconds (5 minutes)
func getIPCSocketTimeout() time.Duration {
	val := os.Getenv("NFTBAN_TIMEOUT_IPC_SOCKET")
	if val == "" {
		return 300 * time.Second
	}
	secs, err := strconv.Atoi(val)
	if err != nil || secs <= 0 {
		return 300 * time.Second
	}
	return time.Duration(secs) * time.Second
}

// getAutoSyncDelay returns auto-sync startup delay from NFTBAN_AUTO_SYNC_DELAY
// Default: 60 seconds
func getAutoSyncDelay() time.Duration {
	val := os.Getenv("NFTBAN_AUTO_SYNC_DELAY")
	if val == "" {
		return 60 * time.Second
	}
	secs, err := strconv.Atoi(val)
	if err != nil || secs < 0 {
		return 60 * time.Second
	}
	return time.Duration(secs) * time.Second
}

// Daemon holds the main daemon state
type Daemon struct {
	bus       *eventbus.Bus
	registry  *module.Registry
	backend   *nftbackend.Backend // AUTHORITATIVE nft writer
	stats     *stats.Collector    // Runtime stats collector
	watchdog  *watchdog.Watchdog  // Dynamic watchdog
	wdMetrics *watchdog.MetricsExporter // Watchdog metrics exporter
	ctx       context.Context
	cancel    context.CancelFunc
	socketLn  net.Listener
	httpSrv   *http.Server
	configDir string             // Config directory for whitelist loading

	// v1.13.0: Async IPC operation queue
	opQueue     *opqueue.OpQueue     // Async operation queue for batched netlink
	sourceIndex *opqueue.SourceIndex // Source tracking for shared sets

	// v1.13.12: Config reload tracking
	configHash    string       // SHA256 of loaded config files
	lastReloadTs  time.Time    // When config was last loaded/reloaded
	reloadMu      sync.RWMutex // Protects config reload operations

	// IPC rate limiting
	connSem chan struct{} // Semaphore for limiting concurrent IPC connections

	// IPC metrics tracking
	activeConns     int64      // Current active connections (atomic)
	peakConns       int64      // Peak connections since reset (atomic)
	activeConnsMu   sync.Mutex // Protects peak calculation

	// Signal handling for PID cleanup
	sigCh           chan os.Signal // Signal channel for shutdown
	startupComplete bool           // True when initialization is complete
	sigMu           sync.Mutex     // Protects startupComplete
}

// isWhitelisted checks if an IP is in the whitelist.
// Returns true if the IP should NOT be banned.
func (d *Daemon) isWhitelisted(ip string) bool {
	if d.configDir == "" {
		return false
	}
	ipv4Set, ipv6Set, err := whitelist.LoadAllWhitelists(d.configDir)
	if err != nil {
		log.Printf("[WHITELIST] Warning: failed to load whitelists: %v", err)
		return false
	}
	if strings.Contains(ip, ":") {
		return ipv6Set[ip]
	}
	return ipv4Set[ip]
}

// checkAndEscalate checks if a temp-banned IP has exceeded the persistent
// offender threshold and should be escalated to a permanent ban.
// Called asynchronously after each temp ban from EventBan handler.
// Reads thresholds from conf.d/persistent.conf (per-filter or global defaults).
// Uses banMutex to prevent race conditions during concurrent escalation.
func (d *Daemon) checkAndEscalate(ip, source, country string) {
	// Acquire mutex to prevent race conditions when multiple goroutines
	// attempt to escalate the same IP simultaneously
	banMutex.Lock()
	defer banMutex.Unlock()

	if d.configDir == "" {
		return
	}

	filterName := source
	if filterName == "" {
		filterName = "unknown"
	}

	// Load persistent offender configuration
	cfg, err := persistent.LoadConfig(d.configDir)
	if err != nil {
		log.Printf("[ESCALATE] Failed to load persistent config: %v", err)
		return
	}
	if !cfg.Enabled {
		return
	}

	filterCfg := cfg.GetFilterConfig(filterName)

	// Log this temp ban for escalation tracking
	if err := persistent.LogTempBan(cfg.BanLog, ip, filterName, fmt.Sprintf("temp ban from %s", filterName)); err != nil {
		log.Printf("[ESCALATE] Failed to log temp ban for %s: %v", ip, err)
		return
	}

	// Count recent bans within the configured period
	banCount, err := persistent.CountRecentBans(cfg.BanLog, ip, filterCfg.Period)
	if err != nil {
		log.Printf("[ESCALATE] Failed to count bans for %s: %v", ip, err)
		return
	}

	if banCount < filterCfg.Threshold {
		return // Below threshold, no escalation needed
	}

	log.Printf("[ESCALATE] IP %s exceeded threshold (%d/%d bans in %s from %s) - escalating to permanent",
		ip, banCount, filterCfg.Threshold, filterCfg.Period, filterName)

	// Log persistent offender event
	_ = persistent.LogPersistentOffender(cfg.OffendersLog, ip, filterName, banCount)

	// Add to persistent offenders config file
	reason := fmt.Sprintf(">=%d bans in %s from %s", filterCfg.Threshold, filterCfg.Period, filterName)
	if err := persistent.AddToPersistentOffenders(cfg.OffendersConf, ip, reason); err != nil {
		log.Printf("[ESCALATE] Failed to add %s to persistent offenders file: %v", ip, err)
		return
	}

	// Re-ban as permanent (timeout=0)
	_, err = d.backend.Ban(d.ctx, nftbackend.BanRequest{
		IP:      ip,
		Timeout: 0, // permanent
		Reason:  reason,
		Source:  "persistent",
	})
	if err != nil {
		log.Printf("[ESCALATE] Failed to permanent-ban %s: %v", ip, err)
		return
	}

	// Persist to blacklist.d/30-persistent-offenders.conf via persistence package
	_, _, err = persistence.PersistBan(d.configDir, ip, reason, "persistent")
	if err != nil {
		log.Printf("[ESCALATE] Failed to persist permanent ban for %s: %v", ip, err)
	}

	// Record analytics
	if st := analytics.StateOrNil(); st != nil {
		st.RecordPersistentOffender(ip, country, filterName, time.Now())
	}

	log.Printf("[ESCALATE] IP %s permanently banned and persisted (source: %s, bans: %d)", ip, filterName, banCount)
}

// lookupCountry performs GeoIP lookup and returns country code.
// Returns "UNK" if lookup fails.
func lookupCountry(ip string) string {
	country, _ := geoip.LookupIP(ip)
	if country == "" {
		return "UNK"
	}
	return country
}

func main() {
	// Handle version/help and parse flags
	for _, arg := range os.Args[1:] {
		switch arg {
		case "--version", "-v":
			fmt.Printf("nftband v%s (git %s, build %s)\n", version.Version, GitCommit, BuildDate)
			return
		case "--help", "-h":
			printHelp()
			return
		case "--profile":
			profileEnabled = true
		}
	}

	// Also check environment variable for pprof (useful for systemd/container deployments)
	if os.Getenv("NFTBAN_ENABLE_PPROF") == "true" {
		profileEnabled = true
	}

	// Initialize safety limits (dynamic based on server profile: CPU, RAM, panel)
	// This sets GOMEMLIMIT to prevent unbounded memory growth
	safetyLimits := safety.FromEnv()
	safety.InitMemory(safetyLimits)
	log.Printf("Safety: %s", safety.GetProfileDescription())

	// Create daemon
	_, configDir, _, _ := getDaemonPaths()
	d := &Daemon{
		bus:       eventbus.New(),
		registry:  module.NewRegistry(),
		backend:   nftbackend.New(), // AUTHORITATIVE nft backend
		stats:     stats.NewCollector(stats.DefaultConfig()),
		configDir: configDir,
		connSem:   make(chan struct{}, MaxConcurrentIPCConns),
	}

	// Initialize dynamic watchdog
	if err := d.initWatchdog(); err != nil {
		log.Printf("Warning: watchdog init failed: %v (continuing without watchdog)", err)
	}

	// Run
	if err := d.Run(); err != nil {
		log.Fatalf("Daemon error: %v", err)
	}
}

// initWatchdog initializes the dynamic watchdog
func (d *Daemon) initWatchdog() error {
	// Load watchdog configuration
	cfg := watchdog.LoadConfig("")

	// Create runtime controls
	controls := watchdog.NewRuntimeControls()

	// Create watchdog
	wd, err := watchdog.New(cfg, controls)
	if err != nil {
		return err
	}

	// Create metrics exporter
	d.wdMetrics = watchdog.NewMetricsExporter()

	// Wire up metrics callback
	wd.SetOnMetrics(func(snapshot *watchdog.Snapshot, state *watchdog.PressureState) {
		d.wdMetrics.Update(snapshot, state)

		// Update stats collector with watchdog state
		if d.stats != nil {
			status := 0
			if d.watchdog != nil && d.watchdog.IsRunning() {
				status = 1
			}
			cpuScore := state.Scores[watchdog.DimCPU]
			memScore := state.Scores[watchdog.DimMEM]
			ioScore := state.Scores[watchdog.DimIO]
			d.stats.SetWatchdogState(status, string(state.Mode), cpuScore, memScore, ioScore)
			d.stats.SetDaemonMode(string(state.Mode))
		}
	})

	d.watchdog = wd
	return nil
}

// initOpQueue initializes the async operation queue (v1.13.0)
func (d *Daemon) initOpQueue() error {
	// Get NFTManager from backend for shared netlink connection
	nft := d.backend.GetNFTManager()
	if nft == nil {
		return fmt.Errorf("nftbackend has no NFTManager")
	}

	// Create backend wrapper for opqueue
	wrapper, err := opqueue.NewNFTBackendWrapper(nft)
	if err != nil {
		return fmt.Errorf("failed to create NFTBackendWrapper: %w", err)
	}

	// Create OpQueue with default config
	d.opQueue = opqueue.NewOpQueue(wrapper, opqueue.DefaultQueueConfig())

	// Create SourceIndex for tracking element sources
	_, _, dataDir, _ := getDaemonPaths()
	d.sourceIndex = opqueue.NewSourceIndex(dataDir + "/source_index.jsonl")

	// Load persisted source index
	if err := d.sourceIndex.LoadFromDisk(); err != nil {
		log.Printf("[OpQueue] Warning: failed to load source index: %v", err)
	}

	// Start async workers
	d.opQueue.Start(d.ctx)
	go d.sourceIndex.StartBackgroundSaver(d.ctx)

	// Reconcile source index with actual nft state
	go func() {
		time.Sleep(5 * time.Second) // Wait for daemon to fully start
		d.sourceIndex.ReconcileWithBackend(wrapper)
	}()

	log.Println("[OpQueue] Async operation queue initialized")
	return nil
}

func printHelp() {
	fmt.Println("nftband - NFTBan Daemon")
	fmt.Println()
	fmt.Println("Usage:")
	fmt.Println("  nftband              Run the daemon")
	fmt.Println("  nftband --profile    Run with pprof profiling enabled")
	fmt.Println("  nftband --version    Show version")
	fmt.Println("  nftband --help       Show this help")
	fmt.Println()
	fmt.Println("The daemon:")
	fmt.Println("  - Runs all nftban modules as goroutines")
	fmt.Println("  - Provides HTTP API on", getAPIAddr())
	fmt.Println("  - Provides Unix socket at", getSocketPath())
	fmt.Println("  - Handles graceful shutdown on SIGTERM/SIGINT")
	fmt.Println()
	fmt.Println("Profiling (--profile or NFTBAN_ENABLE_PPROF=true):")
	fmt.Println("  WARNING: Only enable for debugging - exposes runtime information")
	fmt.Println("  When enabled, pprof endpoints are available at", PprofAddr)
	fmt.Println("  Endpoints:")
	fmt.Println("    /debug/pprof/          - Index page")
	fmt.Println("    /debug/pprof/heap      - Heap profile")
	fmt.Println("    /debug/pprof/profile   - CPU profile (add ?seconds=N)")
	fmt.Println("    /debug/pprof/goroutine - Goroutine profile")
	fmt.Println("    /debug/pprof/block     - Block profile")
	fmt.Println("    /debug/pprof/trace     - Execution trace")
	fmt.Println()
	fmt.Println("  Example usage:")
	fmt.Println("    go tool pprof http://127.0.0.1:6060/debug/pprof/heap")
	fmt.Println("    go tool pprof http://127.0.0.1:6060/debug/pprof/profile?seconds=30")
	fmt.Println("    curl http://127.0.0.1:6060/debug/pprof/goroutine?debug=2")
	fmt.Println()
}

// Run starts the daemon and blocks until shutdown
func (d *Daemon) Run() error {
	log.Printf("nftband v%s starting...", version.Version)

	// Create context for lifecycle management
	d.ctx, d.cancel = context.WithCancel(context.Background())
	defer d.cancel()

	// Ensure directories exist
	if err := d.ensureDirectories(); err != nil {
		return fmt.Errorf("failed to create directories: %w", err)
	}

	// Write PID file
	if err := d.writePidFile(); err != nil {
		return fmt.Errorf("failed to write PID file: %w", err)
	}

	// Set up signal handler IMMEDIATELY after PID file creation to ensure cleanup
	// even if a signal arrives during initialization. The handler checks startupComplete
	// to decide whether to do minimal cleanup (during startup) or full graceful shutdown.
	pidFile := getPidFile()
	d.sigCh = make(chan os.Signal, 1)
	signal.Notify(d.sigCh, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)

	// Start unified signal handler goroutine
	go d.handleSignals(pidFile)

	// Defer PID file removal for normal shutdown path (also handles panics)
	defer func() {
		if r := recover(); r != nil {
			log.Printf("PANIC during daemon operation: %v", r)
			os.Remove(pidFile)
			panic(r) // Re-panic after cleanup
		}
		os.Remove(pidFile)
	}()

	// Initialize OpQueue and SourceIndex (v1.13.0 async IPC)
	if err := d.initOpQueue(); err != nil {
		log.Printf("Warning: OpQueue init failed: %v (async operations disabled)", err)
	}

	// Initialize config hash for reload tracking (v1.13.12)
	d.initConfigHash()

	// Register modules
	d.registerModules()

	// Initialize all modules with event bus
	log.Println("Initializing modules...")
	if err := d.registry.InitAll(d.bus); err != nil {
		return fmt.Errorf("failed to initialize modules: %w", err)
	}

	// Subscribe event bus logger
	d.bus.SubscribeAll(func(e eventbus.Event) {
		log.Printf("[EVENT] %s: %s ip=%s user=%s msg=%s",
			e.Type, e.Source, e.IP, e.User, e.Message)
	})

	// Subscribe to ban events and actually execute the bans
	d.bus.Subscribe(eventbus.EventBan, func(e eventbus.Event) {
		if e.IP == "" {
			return
		}

		// SECURITY: Check whitelist before banning (defense-in-depth)
		if d.isWhitelisted(e.IP) {
			log.Printf("[BAN] BLOCKED: %s is whitelisted, refusing module ban from %s", e.IP, e.Source)
			return
		}

		// Extract timeout from event data (default 1 hour)
		timeout := 3600
		if dur, ok := e.Data["duration"].(string); ok {
			if parsed, err := time.ParseDuration(dur); err == nil {
				timeout = int(parsed.Seconds())
			}
		}

		reason := "module_ban"
		if r, ok := e.Data["reason"].(string); ok {
			reason = r
		}

		// Execute the ban via nftables backend
		_, err := d.backend.Ban(d.ctx, nftbackend.BanRequest{
			IP:      e.IP,
			Timeout: timeout,
			Reason:  reason,
			Source:  e.Source,
		})
		if err != nil {
			log.Printf("[BAN] Failed to ban %s: %v", e.IP, err)
			metrics.RecordBanError(e.Source, "nft_error")
		} else {
			log.Printf("[BAN] Successfully banned %s (timeout=%ds, source=%s)", e.IP, timeout, e.Source)
			// Record in stats collector
			d.stats.RecordBan()
			// Record Prometheus metric
			family := "ipv4"
			if strings.Contains(e.IP, ":") {
				family = "ipv6"
			}
			metrics.RecordBan(e.Source, family)
			// Log to bans.log with GeoIP country lookup
			banSource := banlog.SourceManual
			switch {
			case strings.Contains(e.Source, "portscan"):
				banSource = banlog.SourcePortscan
			case strings.Contains(e.Source, "login"):
				banSource = banlog.SourceLogin
			case strings.Contains(e.Source, "ddos"):
				banSource = banlog.SourceDDoS
			case strings.Contains(e.Source, "feed"):
				banSource = banlog.SourceFeeds
			case strings.Contains(e.Source, "suricata"):
				banSource = banlog.SourceSuricata
			}
			country := lookupCountry(e.IP)
			_ = banlog.LogBanWithReason(e.IP, banSource, country, reason)

			// Check persistent offender escalation for temp bans
			// If this IP has been temp-banned too many times, escalate to permanent
			if timeout > 0 {
				go d.checkAndEscalate(e.IP, e.Source, country)
			}
		}
	})

	// Start Unix socket
	log.Println("Starting Unix socket...")
	if err := d.startSocket(); err != nil {
		return fmt.Errorf("failed to start socket: %w", err)
	}
	defer d.socketLn.Close()

	// Start HTTP server
	log.Println("Starting HTTP API...")
	if err := d.startHTTP(); err != nil {
		return fmt.Errorf("failed to start HTTP: %w", err)
	}

	// Start pprof server if profiling enabled
	if profileEnabled {
		log.Println("Starting pprof server...")
		d.startPprof()
	}

	// Start all modules
	log.Println("Starting modules...")
	if err := d.registry.StartAll(d.ctx); err != nil {
		return fmt.Errorf("failed to start modules: %w", err)
	}

	// Initialize server info for stats
	hostname, _ := os.Hostname()
	var unameInfo syscall.Utsname
	syscall.Uname(&unameInfo)
	// Convert int8 array to string (Linux syscall returns []int8)
	kernelBytes := make([]byte, 0, len(unameInfo.Release))
	for _, b := range unameInfo.Release {
		if b == 0 {
			break
		}
		kernelBytes = append(kernelBytes, safeconv.Int8ToByte(b))
	}
	kernel := string(kernelBytes)
	arch := goruntime.GOARCH
	osName := goruntime.GOOS
	region := os.Getenv("NFTBAN_SERVER_REGION")
	if region == "" {
		region = "unknown"
	}
	d.stats.SetServerInfo(hostname, region, osName, kernel, arch)
	d.stats.SetDaemonMode("normal")

	// Start stats collector (respects enabled flag - no work if disabled)
	log.Println("Starting stats collector...")
	d.stats.Start(d.ctx)

	// Start dynamic watchdog
	if d.watchdog != nil {
		log.Println("Starting dynamic watchdog...")
		go d.watchdog.Run(d.ctx)
	}

	// Publish startup event
	d.bus.Publish(eventbus.NewEvent(eventbus.EventModuleStart, "nftband").
		WithMessage("NFTBan daemon started").
		WithSeverity(eventbus.SeverityInfo))

	log.Printf("nftband ready - HTTP %s, Socket %s", getAPIAddr(), getSocketPath())

	// Schedule auto-sync after startup
	// This ensures feeds and geoban are loaded even after quick postinst sync
	go func() {
		// Wait for system to stabilize after package install
		// Configurable via NFTBAN_AUTO_SYNC_DELAY (default 60s)
		time.Sleep(getAutoSyncDelay())

		// Check if context is still valid (daemon not shutting down)
		select {
		case <-d.ctx.Done():
			return
		default:
		}

		log.Println("[AUTO-SYNC] Running scheduled full sync (feeds + geoban)...")
		resp := d.handleSyncRequest(map[string]any{"quick": false})
		if resp.Success {
			if data, ok := resp.Data.(map[string]any); ok {
				feedsV4 := data["feeds_ipv4_loaded"]
				feedsV6 := data["feeds_ipv6_loaded"]
				geoV4 := data["geoban_ipv4_loaded"]
				geoV6 := data["geoban_ipv6_loaded"]
				log.Printf("[AUTO-SYNC] Complete - feeds: %v/%v, geoban: %v/%v", feedsV4, feedsV6, geoV4, geoV6)
			}
		} else {
			log.Printf("[AUTO-SYNC] Warning: %s", resp.Error)
		}
	}()

	// Wait for shutdown signal
	d.waitForShutdown()

	return nil
}

// ensureDirectories creates required directories
func (d *Daemon) ensureDirectories() error {
	runDir, configDir, dataDir, logDir := getDaemonPaths()
	dirs := []string{
		runDir,
		configDir,
		dataDir,
		logDir,
	}

	for _, dir := range dirs {
		if err := os.MkdirAll(dir, 0755); err != nil {
			return fmt.Errorf("mkdir %s: %w", dir, err)
		}
	}

	return nil
}

// writePidFile writes the daemon PID
func (d *Daemon) writePidFile() error {
	return os.WriteFile(getPidFile(), []byte(fmt.Sprintf("%d\n", os.Getpid())), 0644)
}

// registerModules registers all nftban modules
func (d *Daemon) registerModules() {
	// Register DDoS protection module
	d.registry.Register(ddos.New(), ddos.Descriptor())

	// Register Portscan detection module
	d.registry.Register(portscan.New(), portscan.Descriptor())

	// Register Login Monitor module (pure Go - replaces fail2ban)
	d.registry.Register(loginmon.New(), loginmon.Descriptor())

	// TODO: Register more modules as they are implemented
	// d.registry.Register(suricata.NewWatcher(), suricata.Descriptor())

	log.Printf("Registered %d modules", len(d.registry.All()))
}

// startSocket starts the Unix socket listener
// Supports two modes:
//   1. Socket activation (systemd): uses pre-created socket from nftband.socket
//   2. Manual start: creates socket directly (for testing/development)
func (d *Daemon) startSocket() error {
	socketPath := getSocketPath()

	// Check for systemd socket activation first
	listeners, err := activation.Listeners()
	if err != nil {
		log.Printf("Warning: failed to check systemd activation: %v", err)
	}

	if len(listeners) > 0 {
		// Systemd socket activation - use the pre-configured socket
		// Socket permissions (0660 root:nftban) are set by nftband.socket unit
		d.socketLn = listeners[0]
		log.Printf("Using systemd socket activation (socket from nftband.socket)")
		go d.acceptSocketConnections()
		return nil
	}

	// Manual start - create socket ourselves (for testing/development)
	log.Printf("No systemd socket, creating socket manually at %s", socketPath)

	// Remove stale socket
	os.Remove(socketPath)

	ln, err := net.Listen("unix", socketPath)
	if err != nil {
		return err
	}
	d.socketLn = ln

	// Set permissions: 0660 = owner+group read/write
	// Socket owned by root:nftban so CLI users in nftban group can connect
	if err := os.Chmod(socketPath, 0660); err != nil {
		log.Printf("Warning: failed to chmod socket: %v", err)
	}

	// Try to set group ownership to 'nftban' if group exists
	// This allows non-root CLI users in nftban group to connect
	if err := setSocketGroup(socketPath, "nftban"); err != nil {
		log.Printf("Info: socket group not set (nftban group may not exist): %v", err)
	}

	// Handle connections
	go d.acceptSocketConnections()

	return nil
}

// setSocketGroup sets the group ownership of a file
func setSocketGroup(path, groupName string) error {
	grp, err := user.LookupGroup(groupName)
	if err != nil {
		return err
	}
	gid, err := strconv.Atoi(grp.Gid)
	if err != nil {
		return err
	}
	return os.Chown(path, -1, gid)
}

// nftbanGroupGID caches the nftban group GID for peer validation
var nftbanGroupGID = -1

func init() {
	// Cache nftban group GID at startup
	if grp, err := user.LookupGroup("nftban"); err == nil {
		if gid, err := strconv.Atoi(grp.Gid); err == nil {
			nftbanGroupGID = gid
		}
	}
}

// validatePeerCredentials checks if the connecting process is authorized
// Returns: (uid, gid, error) - error if unauthorized
func validatePeerCredentials(conn net.Conn) (uint32, uint32, error) {
	// Get the underlying Unix socket file descriptor
	unixConn, ok := conn.(*net.UnixConn)
	if !ok {
		return 0, 0, fmt.Errorf("not a Unix socket connection")
	}

	// Get raw connection to access file descriptor
	rawConn, err := unixConn.SyscallConn()
	if err != nil {
		return 0, 0, fmt.Errorf("failed to get raw connection: %w", err)
	}

	var cred *unix.Ucred
	var credErr error

	err = rawConn.Control(func(fd uintptr) {
		cred, credErr = unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED) // #nosec G115 -: fd always fits in int
	})
	if err != nil {
		return 0, 0, fmt.Errorf("failed to control socket: %w", err)
	}
	if credErr != nil {
		return 0, 0, fmt.Errorf("failed to get peer credentials: %w", credErr)
	}

	// Validate: allow root (uid 0) or members of nftban group
	if cred.Uid == 0 {
		// Root is always allowed
		return cred.Uid, cred.Gid, nil
	}

	// Check if caller's primary group is nftban
	if nftbanGroupGID >= 0 && int(cred.Gid) == nftbanGroupGID {
		return cred.Uid, cred.Gid, nil
	}

	// Check supplementary groups - lookup user and check group membership
	u, err := user.LookupId(strconv.Itoa(int(cred.Uid)))
	if err == nil {
		groups, err := u.GroupIds()
		if err == nil {
			for _, gidStr := range groups {
				if gid, _ := strconv.Atoi(gidStr); nftbanGroupGID >= 0 && gid == nftbanGroupGID {
					return cred.Uid, cred.Gid, nil
				}
			}
		}
	}

	return cred.Uid, cred.Gid, fmt.Errorf("unauthorized: uid=%d gid=%d is not root and not in nftban group", cred.Uid, cred.Gid)
}

// acceptSocketConnections handles incoming socket connections
func (d *Daemon) acceptSocketConnections() {
	for {
		conn, err := d.socketLn.Accept()
		acceptTime := time.Now()
		if err != nil {
			// Check if we're shutting down
			select {
			case <-d.ctx.Done():
				return
			default:
				log.Printf("Socket accept error: %v", err)
				continue
			}
		}

		// Rate limit: acquire semaphore slot (non-blocking check first)
		select {
		case d.connSem <- struct{}{}:
			// Got a slot - record wait time and update metrics
			waitTime := time.Since(acceptTime).Seconds()
			metrics.RecordIPCConnectionWait(waitTime)

			// Track active connections
			active := atomic.AddInt64(&d.activeConns, 1)
			metrics.SetIPCConnectionsActive(int(active))
			metrics.SetIPCSemaphoreAvailable(MaxConcurrentIPCConns - int(active))

			// Track peak connections
			d.activeConnsMu.Lock()
			if active > d.peakConns {
				d.peakConns = active
				metrics.SetIPCConnectionsPeak(int(active))
			}
			d.activeConnsMu.Unlock()

			// Handle connection
			go func(c net.Conn) {
				defer func() {
					<-d.connSem // Release slot
					newActive := atomic.AddInt64(&d.activeConns, -1)
					metrics.SetIPCConnectionsActive(int(newActive))
					metrics.SetIPCSemaphoreAvailable(MaxConcurrentIPCConns - int(newActive))
				}()
				d.handleSocketConnection(c)
			}(conn)
		default:
			// At capacity, reject connection and record metric
			metrics.RecordIPCRejection("at_capacity")
			log.Printf("IPC rate limit: rejecting connection (max %d concurrent, peak %d)", MaxConcurrentIPCConns, atomic.LoadInt64(&d.peakConns))
			conn.Close()
		}
	}
}

// SocketRequest is the format for CLI→daemon requests
type SocketRequest struct {
	Method string         `json:"method"`
	Params map[string]any `json:"params"`
}

// SocketResponse is the format for daemon→CLI responses
type SocketResponse struct {
	Success bool   `json:"success"`
	Data    any    `json:"data,omitempty"`
	Error   string `json:"error,omitempty"`
}

// handleSocketConnection processes a single socket connection
func (d *Daemon) handleSocketConnection(conn net.Conn) {
	defer conn.Close()

	// Set timeout from config (default 300s)
	conn.SetDeadline(time.Now().Add(getIPCSocketTimeout()))

	// SECURITY: Validate peer credentials via SO_PEERCRED
	// Defense-in-depth: socket permissions (0660 root:nftban) + credential check
	uid, gid, err := validatePeerCredentials(conn)
	if err != nil {
		metrics.RecordIPCRejection("auth_failed")
		log.Printf("Socket auth rejected: %v", err)
		d.writeSocketResponse(conn, SocketResponse{
			Success: false,
			Error:   "unauthorized: not root or member of nftban group",
		})
		return
	}
	_ = uid // Available for audit logging if needed
	_ = gid

	// Read request (limit to 1 MB to prevent DoS via oversized payloads)
	decoder := json.NewDecoder(io.LimitReader(conn, 1<<20))
	var req SocketRequest
	if err := decoder.Decode(&req); err != nil {
		metrics.RecordIPCRejection("read_error")
		d.writeSocketResponse(conn, SocketResponse{
			Success: false,
			Error:   "invalid request: " + err.Error(),
		})
		return
	}

	// Handle request with timing and per-method metrics
	start := time.Now()
	resp := d.handleSocketRequest(req)
	latencySec := time.Since(start).Seconds()
	latencyNs := time.Since(start).Nanoseconds()

	// Record both old-style stats and new Prometheus metrics
	d.stats.RecordIPCRequest(latencyNs, resp.Success)
	metrics.RecordIPCRequest(req.Method, resp.Success, latencySec)

	// Log slow requests for investigation
	if latencySec > 0.5 {
		log.Printf("IPC slow request: method=%s latency=%.3fs success=%v", req.Method, latencySec, resp.Success)
	}

	d.writeSocketResponse(conn, resp)
}

// writeSocketResponse sends a response to the socket
func (d *Daemon) writeSocketResponse(conn net.Conn, resp SocketResponse) {
	encoder := json.NewEncoder(conn)
	encoder.Encode(resp)
}

// handleSocketRequest processes a socket request
func (d *Daemon) handleSocketRequest(req SocketRequest) SocketResponse {
	switch req.Method {
	case "status":
		return d.handleStatusRequest()
	case "modules":
		return d.handleModulesRequest()
	case "ban":
		return d.handleBanRequest(req.Params)
	case "unban":
		return d.handleUnbanRequest(req.Params)
	case "add_element":
		return d.handleAddElementRequest(req.Params)
	case "delete_element":
		return d.handleDeleteElementRequest(req.Params)
	case "flush_set":
		return d.handleFlushSetRequest(req.Params)
	case "apply_ruleset":
		return d.handleApplyRulesetRequest(req.Params)
	case "check":
		return d.handleCheckRequest(req.Params)
	case "persist_ban":
		return d.handlePersistBanRequest(req.Params)
	case "unpersist_ban":
		return d.handleUnpersistBanRequest(req.Params)
	case "sync":
		return d.handleSyncRequest(req.Params)
	case "load_ports":
		return d.handleLoadPortsRequest(req.Params)
	case "add_port_element":
		return d.handleAddPortElementRequest(req.Params)
	case "delete_port_element":
		return d.handleDeletePortElementRequest(req.Params)
	case "load_cidrs":
		return d.handleLoadCIDRsRequest(req.Params)
	case "stats":
		return d.handleStatsRequest()
	case "stats_history":
		return d.handleStatsHistoryRequest(req.Params)
	case "snapshot_profile":
		return d.handleSnapshotProfileRequest(req.Params)
	case "ping":
		return SocketResponse{Success: true, Data: "pong"}
	case "watchdog_status":
		return d.handleWatchdogStatusRequest()
	case "watchdog_pressure":
		return d.handleWatchdogPressureRequest()
	case "watchdog_events":
		return d.handleWatchdogEventsRequest(req.Params)
	case "protect_ban":
		return d.handleProtectBanRequest(req.Params)
	case "unprotect_ban":
		return d.handleUnprotectBanRequest(req.Params)
	case "get_evictable_bans":
		return d.handleGetEvictableBansRequest(req.Params)
	case "evict_old_bans":
		return d.handleEvictOldBansRequest(req.Params)
	case "permanent_ban_stats":
		return d.handlePermanentBanStatsRequest()
	// v1.13.0: Async IPC handlers
	case "replace_set":
		return d.handleReplaceSetRequest(req.Params)
	case "flush_source":
		return d.handleFlushSourceRequest(req.Params)
	case "queue_status":
		return d.handleQueueStatusRequest()
	// v1.13.12: Config reload handler
	case "reload":
		return d.handleReloadRequest(req.Params)
	default:
		return SocketResponse{
			Success: false,
			Error:   "unknown method: " + req.Method,
		}
	}
}

// =============================================================================
// WATCHDOG IPC HANDLERS
// =============================================================================

// handleWatchdogStatusRequest returns watchdog status
func (d *Daemon) handleWatchdogStatusRequest() SocketResponse {
	if d.watchdog == nil {
		return SocketResponse{
			Success: false,
			Error:   "watchdog not initialized",
		}
	}

	state := d.watchdog.GetState()
	snapshot := d.watchdog.GetSnapshot()

	data := map[string]any{
		"running": d.watchdog.IsRunning(),
		"mode":    string(state.Mode),
		"mode_duration_seconds": state.ModeDuration.Seconds(),
	}

	// Add per-dimension info
	dimensions := make(map[string]any)
	for dim, score := range state.Scores {
		dimensions[string(dim)] = map[string]any{
			"score": score,
			"level": string(state.Levels[dim]),
		}
	}
	data["dimensions"] = dimensions

	// Add key metrics if snapshot available
	if snapshot != nil {
		data["metrics"] = map[string]any{
			"rss_bytes":             snapshot.Process.RSS,
			"cpu_percent":           snapshot.Process.CPUPct,
			"goroutines":            snapshot.Runtime.Goroutines,
			"heap_alloc_bytes":      snapshot.Runtime.HeapAlloc,
			"conntrack_utilization": snapshot.Kernel.ConntrackUtilization,
			"iowait_percent":        snapshot.System.IOWaitPct,
		}
	}

	return SocketResponse{
		Success: true,
		Data:    data,
	}
}

// handleWatchdogPressureRequest returns detailed pressure info
func (d *Daemon) handleWatchdogPressureRequest() SocketResponse {
	if d.watchdog == nil {
		return SocketResponse{
			Success: false,
			Error:   "watchdog not initialized",
		}
	}

	state := d.watchdog.GetState()

	// Build detailed pressure response
	data := map[string]any{
		"timestamp": state.Timestamp.Format(time.RFC3339),
		"mode":      string(state.Mode),
	}

	dimensions := make(map[string]any)
	for _, dim := range watchdog.AllDimensions() {
		dimensions[string(dim)] = map[string]any{
			"score": state.Scores[dim],
			"level": string(state.Levels[dim]),
		}
	}
	data["dimensions"] = dimensions

	// Runtime controls
	controls := d.watchdog.GetControls()
	data["controls"] = map[string]any{
		"max_workers":               controls.MaxWorkers.Load(),
		"expensive_collectors":      controls.EnableExpensiveCollectors.Load(),
		"nft_ruleset_scan":          controls.EnableNFTRulesetScan.Load(),
		"sampling_factor":           controls.GetSamplingFactor(),
	}

	return SocketResponse{
		Success: true,
		Data:    data,
	}
}

// handleWatchdogEventsRequest returns recent watchdog events
func (d *Daemon) handleWatchdogEventsRequest(params map[string]any) SocketResponse {
	if d.watchdog == nil {
		return SocketResponse{
			Success: false,
			Error:   "watchdog not initialized",
		}
	}

	count := 20
	if c, ok := params["count"].(float64); ok && c > 0 {
		count = int(c)
		if count > 100 {
			count = 100
		}
	}

	events := d.watchdog.GetRecentEvents(count)

	// Convert to simple format
	eventList := make([]map[string]any, len(events))
	for i, e := range events {
		eventList[i] = map[string]any{
			"type":      string(e.Type),
			"timestamp": e.Timestamp.Format(time.RFC3339),
			"message":   e.Message,
		}
		if e.Action != nil {
			eventList[i]["action"] = string(e.Action.Type)
		}
		if e.Dimension != "" {
			eventList[i]["dimension"] = string(e.Dimension)
			eventList[i]["score"] = e.Score
		}
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"count":  len(events),
			"events": eventList,
		},
	}
}

// =============================================================================
// PERMANENT BAN MANAGEMENT IPC HANDLERS
// =============================================================================

// handleProtectBanRequest marks a permanent ban as protected (cannot be evicted)
func (d *Daemon) handleProtectBanRequest(params map[string]any) SocketResponse {
	ip, ok := params["ip"].(string)
	if !ok || ip == "" {
		return SocketResponse{Success: false, Error: "missing ip parameter"}
	}

	if err := safety.SetBanProtected(ip, true); err != nil {
		return SocketResponse{
			Success: false,
			Error:   err.Error(),
		}
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"ip":        ip,
			"protected": true,
		},
	}
}

// handleUnprotectBanRequest marks a permanent ban as unprotected (can be evicted)
func (d *Daemon) handleUnprotectBanRequest(params map[string]any) SocketResponse {
	ip, ok := params["ip"].(string)
	if !ok || ip == "" {
		return SocketResponse{Success: false, Error: "missing ip parameter"}
	}

	if err := safety.SetBanProtected(ip, false); err != nil {
		return SocketResponse{
			Success: false,
			Error:   err.Error(),
		}
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"ip":        ip,
			"protected": false,
		},
	}
}

// handleGetEvictableBansRequest returns IPs that can be evicted (old, unprotected)
func (d *Daemon) handleGetEvictableBansRequest(params map[string]any) SocketResponse {
	count := 100 // default
	if c, ok := params["count"].(float64); ok && c > 0 {
		count = int(c)
	}

	ips, err := safety.GetEvictableBans(count)
	if err != nil {
		return SocketResponse{
			Success: false,
			Error:   err.Error(),
		}
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"count": len(ips),
			"ips":   ips,
		},
	}
}

// handleEvictOldBansRequest evicts old unprotected bans
func (d *Daemon) handleEvictOldBansRequest(params map[string]any) SocketResponse {
	count := 100 // default
	if c, ok := params["count"].(float64); ok && c > 0 {
		count = int(c)
	}

	// Get evictable bans
	ips, err := safety.GetEvictableBans(count)
	if err != nil {
		return SocketResponse{
			Success: false,
			Error:   "failed to get evictable bans: " + err.Error(),
		}
	}

	if len(ips) == 0 {
		return SocketResponse{
			Success: true,
			Data: map[string]any{
				"evicted": 0,
				"message": "no evictable bans found",
			},
		}
	}

	// Unban each evictable IP
	evicted := 0
	var errors []string
	for _, ip := range ips {
		// Unban via backend
		_, err := d.backend.Unban(d.ctx, nftbackend.UnbanRequest{IP: ip})
		if err != nil {
			errors = append(errors, fmt.Sprintf("%s: %v", ip, err))
			continue
		}

		// Remove from permanent ban tracking
		if err := safety.RemovePermanentBan(ip); err != nil {
			log.Printf("[EVICT] Warning: failed to remove %s from tracking: %v", ip, err)
		}

		// Record metrics
		family := "ipv4"
		if strings.Contains(ip, ":") {
			family = "ipv6"
		}
		metrics.RecordUnban("eviction", family)
		d.stats.RecordUnban()
		evicted++
	}

	data := map[string]any{
		"evicted":   evicted,
		"requested": len(ips),
	}
	if len(errors) > 0 {
		data["errors"] = errors
	}

	return SocketResponse{
		Success: true,
		Data:    data,
	}
}

// handlePermanentBanStatsRequest returns statistics about permanent bans
func (d *Daemon) handlePermanentBanStatsRequest() SocketResponse {
	total, protected, evictable, err := safety.GetPermanentBanStats()
	if err != nil {
		return SocketResponse{
			Success: false,
			Error:   err.Error(),
		}
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"total":     total,
			"protected": protected,
			"evictable": evictable,
		},
	}
}

// handleStatusRequest returns daemon status
func (d *Daemon) handleStatusRequest() SocketResponse {
	stats := d.bus.Stats()

	// Get config info (thread-safe)
	d.reloadMu.RLock()
	configHash := d.configHash
	lastReload := d.lastReloadTs
	d.reloadMu.RUnlock()

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"version":       version.Version,
			"uptime":        "TODO",
			"modules":       len(d.registry.All()),
			"events_total":  stats.Published,
			"subscriptions": stats.Subscriptions,
			// v1.13.12: Config reload tracking
			"config_hash":   configHash,
			"config_loaded": lastReload.Format(time.RFC3339),
		},
	}
}

// handleModulesRequest returns module statuses
func (d *Daemon) handleModulesRequest() SocketResponse {
	statuses := d.registry.StatusAll()
	return SocketResponse{
		Success: true,
		Data:    statuses,
	}
}

// handleBanRequest bans an IP
func (d *Daemon) handleBanRequest(params map[string]any) SocketResponse {
	ip, ok := params["ip"].(string)
	if !ok || ip == "" {
		return SocketResponse{Success: false, Error: "missing ip parameter"}
	}

	// SECURITY: Validate IP address before processing
	if net.ParseIP(ip) == nil {
		// Also accept CIDR notation
		if _, _, err := net.ParseCIDR(ip); err != nil {
			return SocketResponse{Success: false, Error: "invalid IP address"}
		}
	}

	// SECURITY: Check whitelist before banning (defense-in-depth)
	if d.isWhitelisted(ip) {
		log.Printf("[BAN] BLOCKED: %s is whitelisted, refusing IPC ban", ip)
		return SocketResponse{
			Success: false,
			Error:   fmt.Sprintf("IP %s is whitelisted, cannot ban", ip),
		}
	}

	// Parse optional parameters
	timeout := 0
	if t, ok := params["timeout"].(float64); ok {
		timeout = int(t)
	}
	reason := ""
	if r, ok := params["reason"].(string); ok {
		reason = r
	}
	source := "cli"
	if s, ok := params["source"].(string); ok {
		source = s
	}

	// Parse permanent ban parameters
	permanent := false
	if p, ok := params["permanent"].(bool); ok {
		permanent = p
	}
	protected := false
	if p, ok := params["protected"].(bool); ok {
		protected = p
	}

	// Perform the ban via AUTHORITATIVE backend
	result, err := d.backend.Ban(d.ctx, nftbackend.BanRequest{
		IP:      ip,
		Timeout: timeout,
		Reason:  reason,
		Source:  source,
	})
	if err != nil {
		return SocketResponse{
			Success: false,
			Error:   err.Error(),
		}
	}

	// Record in stats collector
	d.stats.RecordBan()

	// Record Prometheus metric
	family := "ipv4"
	if strings.Contains(ip, ":") {
		family = "ipv6"
	}
	metrics.RecordBan(source, family)

	// Log ban to bans.log for stats tracking
	banSource := banlog.SourceManual
	switch {
	case strings.Contains(source, "portscan"):
		banSource = banlog.SourcePortscan
	case strings.Contains(source, "login"):
		banSource = banlog.SourceLogin
	case strings.Contains(source, "ddos"):
		banSource = banlog.SourceDDoS
	case strings.Contains(source, "feed"):
		banSource = banlog.SourceFeeds
	case strings.Contains(source, "suricata"):
		banSource = banlog.SourceSuricata
	}
	country := lookupCountry(ip)
	_ = banlog.LogBanWithReason(ip, banSource, country, reason)

	// Track permanent ban if requested (timeout=0 and permanent flag set)
	if permanent && timeout == 0 {
		if err := safety.TrackPermanentBan(ip, reason, source, protected); err != nil {
			log.Printf("[BAN] Warning: failed to track permanent ban for %s: %v", ip, err)
		}
	}

	// NOTE: Do NOT publish EventBan here - the IPC handler already executed the ban
	// and logged it. The EventBan subscriber is for module-initiated bans only.
	// Publishing EventBan here would cause:
	// 1. Duplicate ban execution (subscriber calls d.backend.Ban again)
	// 2. Duplicate bans.log entries

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"ip":        ip,
			"set":       result.Set,
			"status":    "banned",
			"message":   result.Message,
			"permanent": permanent && timeout == 0,
			"protected": protected,
		},
	}
}

// handleUnbanRequest unbans an IP
func (d *Daemon) handleUnbanRequest(params map[string]any) SocketResponse {
	ip, ok := params["ip"].(string)
	if !ok || ip == "" {
		return SocketResponse{Success: false, Error: "missing ip parameter"}
	}

	// SECURITY: Validate IP address before processing
	if net.ParseIP(ip) == nil {
		// Also accept CIDR notation
		if _, _, err := net.ParseCIDR(ip); err != nil {
			return SocketResponse{Success: false, Error: "invalid IP address"}
		}
	}

	// Perform the unban via AUTHORITATIVE backend
	result, err := d.backend.Unban(d.ctx, nftbackend.UnbanRequest{
		IP: ip,
	})
	if err != nil {
		return SocketResponse{
			Success: false,
			Error:   err.Error(),
		}
	}

	// Record in stats collector
	d.stats.RecordUnban()

	// Record Prometheus metric
	family := "ipv4"
	if strings.Contains(ip, ":") {
		family = "ipv6"
	}
	metrics.RecordUnban("manual", family)

	// Publish unban event
	d.bus.Publish(eventbus.NewEvent(eventbus.EventUnban, "cli").
		WithIP(ip).
		WithMessage("Manual unban via CLI").
		WithSeverity(eventbus.SeverityInfo))

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"ip":      ip,
			"set":     result.Set,
			"status":  "unbanned",
			"message": result.Message,
		},
	}
}

// handleAddElementRequest adds an element to any set
func (d *Daemon) handleAddElementRequest(params map[string]any) SocketResponse {
	table, _ := params["table"].(string)
	set, _ := params["set"].(string)
	element, _ := params["element"].(string)

	if table == "" || set == "" || element == "" {
		return SocketResponse{Success: false, Error: "missing table, set, or element parameter"}
	}
	if !validNFTBanTable(table) {
		return SocketResponse{Success: false, Error: "invalid table: must be 'ip nftban' or 'ip6 nftban'"}
	}
	if !validNFTBanSet(set) {
		return SocketResponse{Success: false, Error: "invalid set: " + set}
	}

	timeout := 0
	if t, ok := params["timeout"].(float64); ok {
		timeout = int(t)
	}

	err := d.backend.AddElement(d.ctx, nftbackend.AddElementRequest{
		Table:   table,
		Set:     set,
		Element: element,
		Timeout: timeout,
	})
	if err != nil {
		return SocketResponse{Success: false, Error: err.Error()}
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"table":   table,
			"set":     set,
			"element": element,
		},
	}
}

// handleDeleteElementRequest removes an element from any set
func (d *Daemon) handleDeleteElementRequest(params map[string]any) SocketResponse {
	table, _ := params["table"].(string)
	set, _ := params["set"].(string)
	element, _ := params["element"].(string)

	if table == "" || set == "" || element == "" {
		return SocketResponse{Success: false, Error: "missing table, set, or element parameter"}
	}
	if !validNFTBanTable(table) {
		return SocketResponse{Success: false, Error: "invalid table: must be 'ip nftban' or 'ip6 nftban'"}
	}
	if !validNFTBanSet(set) {
		return SocketResponse{Success: false, Error: "invalid set: " + set}
	}

	err := d.backend.DeleteElement(d.ctx, nftbackend.DeleteElementRequest{
		Table:   table,
		Set:     set,
		Element: element,
	})
	if err != nil {
		return SocketResponse{Success: false, Error: err.Error()}
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"table":   table,
			"set":     set,
			"element": element,
			"status":  "deleted",
		},
	}
}

// handleFlushSetRequest flushes all elements from a set
func (d *Daemon) handleFlushSetRequest(params map[string]any) SocketResponse {
	table, _ := params["table"].(string)
	set, _ := params["set"].(string)

	if table == "" || set == "" {
		return SocketResponse{Success: false, Error: "missing table or set parameter"}
	}
	if !validNFTBanTable(table) {
		return SocketResponse{Success: false, Error: "invalid table: must be 'ip nftban' or 'ip6 nftban'"}
	}
	if !validNFTBanSet(set) {
		return SocketResponse{Success: false, Error: "invalid set: " + set}
	}

	err := d.backend.FlushSet(d.ctx, nftbackend.FlushSetRequest{
		Table: table,
		Set:   set,
	})
	if err != nil {
		return SocketResponse{Success: false, Error: err.Error()}
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"table":  table,
			"set":    set,
			"status": "flushed",
		},
	}
}

// handleApplyRulesetRequest applies a ruleset from file
func (d *Daemon) handleApplyRulesetRequest(params map[string]any) SocketResponse {
	filePath, _ := params["file"].(string)
	check, _ := params["check"].(bool)

	if filePath == "" {
		return SocketResponse{Success: false, Error: "missing file parameter"}
	}

	// Security: reject path traversal attempts before any further processing
	if strings.Contains(filePath, "..") {
		return SocketResponse{Success: false, Error: "path traversal not allowed"}
	}

	// Security: restrict ruleset paths to allowed directories
	absPath := filepath.Clean(filePath)
	var err error
	absPath, err = filepath.Abs(absPath)
	if err != nil {
		return SocketResponse{Success: false, Error: "invalid file path: " + err.Error()}
	}
	// Double-check after Clean/Abs (defense-in-depth)
	if strings.Contains(absPath, "..") {
		return SocketResponse{Success: false, Error: "path traversal not allowed"}
	}
	runDir, configDir, dataDir, _ := getDaemonPaths()
	if !strings.HasPrefix(absPath, dataDir+"/") &&
		!strings.HasPrefix(absPath, configDir+"/") &&
		!strings.HasPrefix(absPath, runDir+"/") {
		return SocketResponse{Success: false, Error: "file path must be within " + dataDir + "/, " + configDir + "/, or " + runDir + "/"}
	}

	err = d.backend.ApplyRuleset(d.ctx, nftbackend.ApplyRulesetRequest{
		FilePath: absPath,
		Check:    check,
	})
	if err != nil {
		return SocketResponse{Success: false, Error: err.Error()}
	}

	action := "applied"
	if check {
		action = "validated"
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"file":   filePath,
			"status": action,
		},
	}
}

// handleCheckRequest checks if an IP is banned
func (d *Daemon) handleCheckRequest(params map[string]any) SocketResponse {
	ip, _ := params["ip"].(string)

	if ip == "" {
		return SocketResponse{Success: false, Error: "missing ip parameter"}
	}

	banned, set, err := d.backend.CheckIP(d.ctx, ip)
	if err != nil {
		return SocketResponse{Success: false, Error: err.Error()}
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"ip":     ip,
			"banned": banned,
			"set":    set,
		},
	}
}

// handlePersistBanRequest adds an IP to persistent blacklist files
func (d *Daemon) handlePersistBanRequest(params map[string]any) SocketResponse {
	ip, _ := params["ip"].(string)
	if ip == "" {
		return SocketResponse{Success: false, Error: "missing ip parameter"}
	}

	reason, _ := params["reason"].(string)
	source, _ := params["source"].(string)
	if source == "" {
		source = "manual"
	}

	// Get config directory
	_, configDir, _, _ := getDaemonPaths()

	// Persist the ban
	result, filename, err := persistence.PersistBan(configDir, ip, reason, source)
	if err != nil {
		return SocketResponse{Success: false, Error: err.Error()}
	}

	// Track permanent ban for protect/evict functionality
	// This enables 'nftban protect' and 'nftban cleanup' commands to work
	if err := safety.TrackPermanentBan(ip, reason, source, false); err != nil {
		log.Printf("[PERSIST] Warning: failed to track permanent ban for %s: %v", ip, err)
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"ip":       ip,
			"result":   string(result),
			"filename": filename,
		},
	}
}

// handleUnpersistBanRequest removes an IP from all persistent blacklist files
func (d *Daemon) handleUnpersistBanRequest(params map[string]any) SocketResponse {
	ip, _ := params["ip"].(string)
	if ip == "" {
		return SocketResponse{Success: false, Error: "missing ip parameter"}
	}

	// Get config directory
	_, configDir, _, _ := getDaemonPaths()

	// Remove from all blacklist files
	filesModified, err := persistence.UnpersistBan(configDir, ip)
	if err != nil {
		return SocketResponse{Success: false, Error: err.Error()}
	}

	// Remove from permanent ban tracking
	if err := safety.RemovePermanentBan(ip); err != nil {
		log.Printf("[UNPERSIST] Warning: failed to remove permanent ban tracking for %s: %v", ip, err)
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"ip":             ip,
			"files_modified": filesModified,
		},
	}
}

// startHTTP starts the HTTP API server
func (d *Daemon) startHTTP() error {
	mux := http.NewServeMux()

	// Health check
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"status":  "ok",
			"version": version.Version,
		})
	})

	// Prometheus metrics endpoint
	// BUG-H5 FIX: Restrict /metrics to localhost only (prevents information disclosure)
	mux.Handle("/metrics", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, _ := net.SplitHostPort(r.RemoteAddr)
		if host != "127.0.0.1" && host != "::1" {
			http.Error(w, "Forbidden", http.StatusForbidden)
			return
		}
		promhttp.Handler().ServeHTTP(w, r)
	}))

	// Status endpoint
	mux.HandleFunc("/api/v1/status", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		stats := d.bus.Stats()
		_ = json.NewEncoder(w).Encode(map[string]any{
			"success": true,
			"data": map[string]any{
				"version":      version.Version,
				"modules":      len(d.registry.All()),
				"events_total": stats.Published,
			},
		})
	})

	// Modules endpoint
	mux.HandleFunc("/api/v1/modules", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		statuses := d.registry.StatusAll()
		_ = json.NewEncoder(w).Encode(map[string]any{
			"success": true,
			"data":    statuses,
		})
	})

	// TODO: Mount existing pkg/api handlers here
	// mux.Handle("/api/v1/", api.NewRouter())

	d.httpSrv = &http.Server{
		Addr:    getAPIAddr(),
		Handler: mux,
	}

	go func() {
		if err := d.httpSrv.ListenAndServe(); err != http.ErrServerClosed {
			log.Printf("HTTP server error: %v", err)
		}
	}()

	return nil
}

// startPprof starts a pprof HTTP server for profiling
// The server listens on localhost only (127.0.0.1:6060) for security
// SECURITY: pprof exposes sensitive runtime information - only enable for debugging
// BUG-H4 FIX: Uses a dedicated ServeMux instead of DefaultServeMux
func (d *Daemon) startPprof() {
	pprofMux := http.NewServeMux()
	pprofMux.HandleFunc("/debug/pprof/", nethttpprof.Index)
	pprofMux.HandleFunc("/debug/pprof/cmdline", nethttpprof.Cmdline)
	pprofMux.HandleFunc("/debug/pprof/profile", nethttpprof.Profile)
	pprofMux.HandleFunc("/debug/pprof/symbol", nethttpprof.Symbol)
	pprofMux.HandleFunc("/debug/pprof/trace", nethttpprof.Trace)
	go func() {
		log.Println("WARNING: pprof profiling enabled - disable in production (unset NFTBAN_ENABLE_PPROF or remove --profile)")
		log.Printf("pprof server listening on http://%s/debug/pprof/", PprofAddr)
		if err := http.ListenAndServe(PprofAddr, pprofMux); err != nil {
			log.Printf("pprof server error: %v", err)
		}
	}()
}

// handleSignals is the unified signal handler that runs as a goroutine.
// It handles all signals throughout the daemon lifecycle:
// - During startup (startupComplete=false): minimal cleanup and exit
// - After startup (startupComplete=true): graceful shutdown with full cleanup
func (d *Daemon) handleSignals(pidFile string) {
	for sig := range d.sigCh {
		d.sigMu.Lock()
		complete := d.startupComplete
		d.sigMu.Unlock()

		switch sig {
		case syscall.SIGHUP:
			if !complete {
				// Ignore SIGHUP during startup
				log.Println("Ignoring SIGHUP during startup")
				continue
			}
			// Handle config reload
			log.Println("Received SIGHUP, reloading configuration...")
			if err := d.reloadConfig(); err != nil {
				log.Printf("Config reload failed: %v", err)
			} else {
				log.Printf("Config reloaded successfully (hash: %s)", d.configHash[:16])
			}
			continue // Keep waiting for signals

		case syscall.SIGTERM, syscall.SIGINT:
			if !complete {
				// During startup: minimal cleanup and exit
				log.Printf("Received %v during startup, cleaning up PID file...", sig)
				os.Remove(pidFile)
				os.Exit(1)
			}
			// After startup: graceful shutdown
			log.Printf("Received %v, shutting down...", sig)
			d.gracefulShutdown()
			return
		}
	}
}

// gracefulShutdown performs orderly shutdown of all daemon components
func (d *Daemon) gracefulShutdown() {
	// Close socket listener first to stop accepting new IPC connections
	if d.socketLn != nil {
		_ = d.socketLn.Close()
	}

	// Publish shutdown event
	d.bus.Publish(eventbus.NewEvent(eventbus.EventModuleStop, "nftband").
		WithMessage("NFTBan daemon shutting down").
		WithSeverity(eventbus.SeverityInfo))

	// Shutdown HTTP server
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := d.httpSrv.Shutdown(ctx); err != nil {
		log.Printf("HTTP shutdown error: %v", err)
	}

	// Stop all modules
	if err := d.registry.StopAll(); err != nil {
		log.Printf("Module stop error: %v", err)
	}

	// Stop OpQueue and save SourceIndex (v1.13.0)
	if d.opQueue != nil {
		log.Println("Stopping OpQueue...")
		d.opQueue.Stop()
	}
	if d.sourceIndex != nil {
		log.Println("Saving SourceIndex...")
		d.sourceIndex.Stop()
	}

	// Close event bus
	d.bus.Close()

	// Cancel context
	d.cancel()

	log.Println("nftband stopped")
}

// waitForShutdown blocks until the signal handler completes shutdown
func (d *Daemon) waitForShutdown() {
	// Mark startup as complete so signal handler does graceful shutdown
	d.sigMu.Lock()
	d.startupComplete = true
	d.sigMu.Unlock()

	log.Println("Startup complete, waiting for shutdown signal...")

	// Block until gracefulShutdown() is called by handleSignals
	// We wait on the context which is cancelled during gracefulShutdown
	<-d.ctx.Done()
}

// =============================================================================
// CONFIG RELOAD (v1.13.12)
// =============================================================================

// computeConfigHash computes SHA256 hash of config files for change detection
func (d *Daemon) computeConfigHash() (string, error) {
	configDir := "/etc/nftban"
	h := sha256.New()

	// Hash main config files
	files := []string{
		filepath.Join(configDir, "nftban.conf"),
		filepath.Join(configDir, "nftban.conf.local"),
	}

	for _, f := range files {
		if data, err := os.ReadFile(f); err == nil {
			h.Write([]byte(f + ":"))
			h.Write(data)
		}
	}

	// Hash module configs in conf.d/
	confD := filepath.Join(configDir, "conf.d")
	if entries, err := os.ReadDir(confD); err == nil {
		for _, entry := range entries {
			if entry.IsDir() {
				// Module directory - hash main.conf and main.conf.local
				for _, name := range []string{"main.conf", "main.conf.local"} {
					f := filepath.Join(confD, entry.Name(), name)
					if data, err := os.ReadFile(f); err == nil {
						h.Write([]byte(f + ":"))
						h.Write(data)
					}
				}
			} else if strings.HasSuffix(entry.Name(), ".conf") {
				// Top-level conf file
				f := filepath.Join(confD, entry.Name())
				if data, err := os.ReadFile(f); err == nil {
					h.Write([]byte(f + ":"))
					h.Write(data)
				}
			}
		}
	}

	return hex.EncodeToString(h.Sum(nil)), nil
}

// reloadConfig reloads configuration from disk
// This is called on SIGHUP or via IPC reload request
func (d *Daemon) reloadConfig() error {
	d.reloadMu.Lock()
	defer d.reloadMu.Unlock()

	// Compute new hash before reload
	newHash, err := d.computeConfigHash()
	if err != nil {
		return fmt.Errorf("failed to compute config hash: %w", err)
	}

	// Check if config actually changed
	if newHash == d.configHash {
		log.Println("Config unchanged, skipping reload")
		return nil
	}

	// Reload config via nftbanconf package
	if err := nftbanconf.Reload(); err != nil {
		return fmt.Errorf("failed to reload config: %w", err)
	}

	// Update daemon state
	oldHash := d.configHash
	d.configHash = newHash
	d.lastReloadTs = time.Now()

	// Publish reload event
	d.bus.Publish(eventbus.NewEvent(eventbus.EventConfigReload, "nftband").
		WithMessage(fmt.Sprintf("Config reloaded (hash: %s -> %s)", oldHash[:8], newHash[:8])).
		WithSeverity(eventbus.SeverityInfo))

	return nil
}

// initConfigHash initializes config hash on startup
func (d *Daemon) initConfigHash() {
	hash, err := d.computeConfigHash()
	if err != nil {
		log.Printf("Warning: failed to compute initial config hash: %v", err)
		return
	}
	d.configHash = hash
	d.lastReloadTs = time.Now()
	log.Printf("Config hash initialized: %s", hash[:16])
}

// =============================================================================
// HIGH-LEVEL IPC HANDLERS (for CLI delegation)
// =============================================================================

// handleSyncRequest performs a full differential sync of whitelists/blacklists
// If params["quick"]=true, skips feeds and geoban loading (for fast postinst sync)
func (d *Daemon) handleSyncRequest(params map[string]any) SocketResponse {
	// Prevent concurrent sync operations from racing
	syncMutex.Lock()
	defer syncMutex.Unlock()

	// Check for quick mode (skips feeds/geoban for fast postinst sync)
	quickMode := false
	if params != nil {
		if q, ok := params["quick"].(bool); ok && q {
			quickMode = true
		}
	}

	_, configDir, _, _ := getDaemonPaths()

	// Initialize RuntimeState
	state := runtime.NewRuntimeState(configDir)

	if err := state.LoadWhitelists(); err != nil {
		return SocketResponse{Success: false, Error: "failed to load whitelists: " + err.Error()}
	}

	if err := state.LoadBlacklists(); err != nil {
		return SocketResponse{Success: false, Error: "failed to load blacklists: " + err.Error()}
	}

	// Load ports from ALL sources
	allPorts, err := ports.LoadAllPorts(configDir)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to load ports: " + err.Error()}
	}

	// Use backend's shared nftables manager
	nft := d.backend.GetNFTManager()
	if nft == nil {
		return SocketResponse{Success: false, Error: "nftables backend not initialized"}
	}

	// Get or create tables
	tableIPv4, err := nft.GetOrCreateTable(nftables.TableFamilyIPv4)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to get/create IPv4 table: " + err.Error()}
	}

	tableIPv6, err := nft.GetOrCreateTable(nftables.TableFamilyIPv6)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to get/create IPv6 table: " + err.Error()}
	}

	// Create sets
	whitelistIPv4Set, err := nft.GetOrCreateIntervalSet(tableIPv4, "whitelist_ipv4", true)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to get/create whitelist_ipv4 set: " + err.Error()}
	}

	whitelistIPv6Set, err := nft.GetOrCreateIntervalSet(tableIPv6, "whitelist_ipv6", false)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to get/create whitelist_ipv6 set: " + err.Error()}
	}

	blacklistIPv4Set, err := nft.GetOrCreateSet(tableIPv4, "blacklist_ipv4", true)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to get/create blacklist_ipv4 set: " + err.Error()}
	}

	blacklistIPv6Set, err := nft.GetOrCreateSet(tableIPv6, "blacklist_ipv6", false)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to get/create blacklist_ipv6 set: " + err.Error()}
	}

	// Create and populate port sets if we have ports
	if len(allPorts.AllRules) > 0 {
		// Directional port sets (v2.1 schema - NO legacy sets)
		tcpInSetV4, err := nft.GetOrCreatePortSet(tableIPv4, "tcp_ports_in")
		if err != nil {
			return SocketResponse{Success: false, Error: "failed to create IPv4 tcp_ports_in set: " + err.Error()}
		}
		tcpInSetV6, err := nft.GetOrCreatePortSet(tableIPv6, "tcp_ports_in")
		if err != nil {
			return SocketResponse{Success: false, Error: "failed to create IPv6 tcp_ports_in set: " + err.Error()}
		}
		tcpOutSetV4, err := nft.GetOrCreatePortSet(tableIPv4, "tcp_ports_out")
		if err != nil {
			return SocketResponse{Success: false, Error: "failed to create IPv4 tcp_ports_out set: " + err.Error()}
		}
		tcpOutSetV6, err := nft.GetOrCreatePortSet(tableIPv6, "tcp_ports_out")
		if err != nil {
			return SocketResponse{Success: false, Error: "failed to create IPv6 tcp_ports_out set: " + err.Error()}
		}
		udpInSetV4, err := nft.GetOrCreatePortSet(tableIPv4, "udp_ports_in")
		if err != nil {
			return SocketResponse{Success: false, Error: "failed to create IPv4 udp_ports_in set: " + err.Error()}
		}
		udpInSetV6, err := nft.GetOrCreatePortSet(tableIPv6, "udp_ports_in")
		if err != nil {
			return SocketResponse{Success: false, Error: "failed to create IPv6 udp_ports_in set: " + err.Error()}
		}
		udpOutSetV4, err := nft.GetOrCreatePortSet(tableIPv4, "udp_ports_out")
		if err != nil {
			return SocketResponse{Success: false, Error: "failed to create IPv4 udp_ports_out set: " + err.Error()}
		}
		udpOutSetV6, err := nft.GetOrCreatePortSet(tableIPv6, "udp_ports_out")
		if err != nil {
			return SocketResponse{Success: false, Error: "failed to create IPv6 udp_ports_out set: " + err.Error()}
		}

		// Load directional port sets
		if len(allPorts.TCPPortsIn) > 0 {
			if err := nft.AddPortElements(tcpInSetV4, allPorts.TCPPortsIn); err != nil {
				return SocketResponse{Success: false, Error: "failed to add IPv4 TCP input ports: " + err.Error()}
			}
			if err := nft.AddPortElements(tcpInSetV6, allPorts.TCPPortsIn); err != nil {
				return SocketResponse{Success: false, Error: "failed to add IPv6 TCP input ports: " + err.Error()}
			}
		}
		if len(allPorts.TCPPortsOut) > 0 {
			if err := nft.AddPortElements(tcpOutSetV4, allPorts.TCPPortsOut); err != nil {
				return SocketResponse{Success: false, Error: "failed to add IPv4 TCP output ports: " + err.Error()}
			}
			if err := nft.AddPortElements(tcpOutSetV6, allPorts.TCPPortsOut); err != nil {
				return SocketResponse{Success: false, Error: "failed to add IPv6 TCP output ports: " + err.Error()}
			}
		}
		if len(allPorts.UDPPortsIn) > 0 {
			if err := nft.AddPortElements(udpInSetV4, allPorts.UDPPortsIn); err != nil {
				return SocketResponse{Success: false, Error: "failed to add IPv4 UDP input ports: " + err.Error()}
			}
			if err := nft.AddPortElements(udpInSetV6, allPorts.UDPPortsIn); err != nil {
				return SocketResponse{Success: false, Error: "failed to add IPv6 UDP input ports: " + err.Error()}
			}
		}
		if len(allPorts.UDPPortsOut) > 0 {
			if err := nft.AddPortElements(udpOutSetV4, allPorts.UDPPortsOut); err != nil {
				return SocketResponse{Success: false, Error: "failed to add IPv4 UDP output ports: " + err.Error()}
			}
			if err := nft.AddPortElements(udpOutSetV6, allPorts.UDPPortsOut); err != nil {
				return SocketResponse{Success: false, Error: "failed to add IPv6 UDP output ports: " + err.Error()}
			}
		}
	}

	// Get snapshots from runtime state
	whitelistIPv4, whitelistIPv6 := state.GetWhitelistSnapshot()
	blacklistIPv4, blacklistIPv6 := state.GetBlacklistSnapshot()

	// Perform full sync
	result, err := nftsync.FullSync(
		nft,
		whitelistIPv4Set, whitelistIPv6Set,
		blacklistIPv4Set, blacklistIPv6Set,
		whitelistIPv4, whitelistIPv6,
		blacklistIPv4, blacklistIPv6,
	)

	if err != nil {
		return SocketResponse{Success: false, Error: "sync failed: " + err.Error()}
	}

	// Update counters
	state.IncrementSyncCounter(result.Success)

	// ==========================================================================
	// FEEDS LOADING - Load threat feeds into blacklist sets if enabled
	// Skip in quick mode (postinst sync) to avoid 3-5 minute delay
	// ==========================================================================
	var feedsIPv4Loaded, feedsIPv6Loaded int
	var feedsSkipped, geobanSkipped bool
	var feedsCIDRCount, geobanCIDRCount int
	var feedsMemNeeded, geobanMemNeeded int64
	if !quickMode {
		// Check memory pressure before loading feeds
		if safety.ShouldSkipFeeds() {
			log.Printf("[SYNC] Memory pressure %s: skipping feeds", safety.GetMemoryPressureLevel())
			feedsSkipped = true
		} else {
		_, _, dataDir, _ := getDaemonPaths()
		feedsDir := dataDir + "/feeds"

		// Check if feeds directory exists and has .txt files
		if entries, err := os.ReadDir(feedsDir); err == nil && len(entries) > 0 {
		// Load all feeds
		ipv4Set, ipv6Set, ipv4CIDRSet, ipv6CIDRSet, _, feedErr := feeds.LoadAllFeeds(feedsDir)
		if feedErr == nil {
			// Pre-allocate slices with exact capacity to avoid reallocation overhead
			// With 15,000+ CIDRs, this prevents ~14 slice doublings
			ipv4CIDRs := make([]string, 0, len(ipv4Set)+len(ipv4CIDRSet))
			ipv6CIDRs := make([]string, 0, len(ipv6Set)+len(ipv6CIDRSet))
			for ip := range ipv4Set {
				ipv4CIDRs = append(ipv4CIDRs, ip+"/32")
			}
			for cidr := range ipv4CIDRSet {
				ipv4CIDRs = append(ipv4CIDRs, cidr)
			}
			for ip := range ipv6Set {
				ipv6CIDRs = append(ipv6CIDRs, ip+"/128")
			}
			for cidr := range ipv6CIDRSet {
				ipv6CIDRs = append(ipv6CIDRs, cidr)
			}

			// Memory safety check before loading feeds into nftables
			// CIDR merging can use 3x memory temporarily
			const bytesPerCIDR = 300 // conservative estimate
			totalFeedCIDRs := len(ipv4CIDRs) + len(ipv6CIDRs)
			estimatedFeedBytes := int64(totalFeedCIDRs) * bytesPerCIDR
			if !safety.CanAllocate(estimatedFeedBytes) {
				log.Printf("[SYNC] Warning: Skipping feeds - insufficient memory for %d CIDRs (need ~%s)",
					totalFeedCIDRs, safety.FormatBytes(estimatedFeedBytes))
				// Track protection trigger for visibility
				feedsSkipped = true
				feedsCIDRCount = totalFeedCIDRs
				feedsMemNeeded = estimatedFeedBytes
				// Skip feeds but continue with sync - don't fail entirely
			} else {
			// v2.1: Load feeds into unified blacklist_ipv4/ipv6 sets (CIDR aggregated)
			// All ban sources now use the same blacklist - daemon tracks source in DB
			if len(ipv4CIDRs) > 0 {
				feedSetV4, err := nft.GetOrCreateIntervalSet(tableIPv4, "blacklist_ipv4", true)
				if err != nil {
					log.Printf("[SYNC] Warning: Failed to get blacklist_ipv4 set: %v", err)
				} else {
					if stats, err := nft.AddCIDRElementsWithStats(feedSetV4, ipv4CIDRs); err != nil {
						log.Printf("[SYNC] Warning: Failed to load feeds IPv4: %v", err)
					} else if stats != nil {
						feedsIPv4Loaded = stats.OutputRanges
						log.Printf("[SYNC] Feeds IPv4: loaded %d ranges (from %d input CIDRs)", stats.OutputRanges, stats.InputCIDRs)
					}
				}
			}

			// Load IPv6 feeds into unified blacklist_ipv6 set
			if len(ipv6CIDRs) > 0 {
				feedSetV6, err := nft.GetOrCreateIntervalSet(tableIPv6, "blacklist_ipv6", false)
				if err != nil {
					log.Printf("[SYNC] Warning: Failed to get blacklist_ipv6 set: %v", err)
				} else {
					if stats, err := nft.AddCIDRElementsWithStats(feedSetV6, ipv6CIDRs); err != nil {
						log.Printf("[SYNC] Warning: Failed to load feeds IPv6: %v", err)
					} else if stats != nil {
						feedsIPv6Loaded = stats.OutputRanges
						log.Printf("[SYNC] Feeds IPv6: loaded %d ranges (from %d input CIDRs)", stats.OutputRanges, stats.InputCIDRs)
					}
				}
			}
			// Memory cleanup: clear CIDR slices after loading to nftables
			// These slices can hold 100-200MB that's no longer needed
			ipv4CIDRs = nil
			ipv6CIDRs = nil
			} // end else CanAllocate
			// Memory cleanup: clear feed maps to allow garbage collection
			// These maps can hold 400-800MB and are no longer needed after conversion
			ipv4Set = nil
			ipv6Set = nil
			ipv4CIDRSet = nil
			ipv6CIDRSet = nil
		}
		}
		} // end else ShouldSkipFeeds
	} // end if !quickMode (feeds)

	// ==========================================================================
	// GEOBAN LOADING - Load geoban CIDRs if any ban files exist
	// Skip in quick mode (postinst sync) to avoid 3-5 minute delay
	// ==========================================================================
	var geobanIPv4Loaded, geobanIPv6Loaded int
	if !quickMode {
		// Check memory pressure before loading geoban
		if safety.ShouldSkipGeoban() {
			log.Printf("[SYNC] Memory pressure %s: skipping geoban", safety.GetMemoryPressureLevel())
			geobanSkipped = true
		} else {
		geobanDir := configDir + "/geoban.d"

		// Check if geoban directory exists and has ban files (50-ban-*.conf)
		if entries, err := os.ReadDir(geobanDir); err == nil {
		hasBanFiles := false
		for _, e := range entries {
			if strings.HasPrefix(e.Name(), "50-ban-") && strings.HasSuffix(e.Name(), ".conf") {
				hasBanFiles = true
				break
			}
		}

		if hasBanFiles {
			// Load all geoban countries
			geobanData, geoErr := geoban.Build(geobanDir, nil) // nil = load all
			if geoErr == nil && geobanData != nil {
				// Memory safety check before loading geoban into nftables
				// Geoban can have 20K+ CIDRs per country (CN, RU, etc.)
				const bytesPerCIDR = 300 // conservative estimate
				totalGeoCIDRs := len(geobanData.IPv4) + len(geobanData.IPv6)
				estimatedGeoBytes := int64(totalGeoCIDRs) * bytesPerCIDR
				if !safety.CanAllocate(estimatedGeoBytes) {
					log.Printf("[SYNC] Warning: Skipping geoban - insufficient memory for %d CIDRs (need ~%s)",
						totalGeoCIDRs, safety.FormatBytes(estimatedGeoBytes))
					// Track protection trigger for visibility
					geobanSkipped = true
					geobanCIDRCount = totalGeoCIDRs
					geobanMemNeeded = estimatedGeoBytes
					// Skip geoban but continue with sync - don't fail entirely
				} else {
				// v2.1: Load geoban CIDRs into unified blacklist_ipv4/ipv6 sets
				// All ban sources now use the same blacklist - CIDR aggregation prevents duplicates
				if len(geobanData.IPv4) > 0 {
					geoSetV4, err := nft.GetOrCreateIntervalSet(tableIPv4, "blacklist_ipv4", true)
					if err != nil {
						log.Printf("[SYNC] Warning: Failed to get blacklist_ipv4 set: %v", err)
					} else {
						if stats, err := nft.AddCIDRElementsWithStats(geoSetV4, geobanData.IPv4); err != nil {
							log.Printf("[SYNC] Warning: Failed to load geoban IPv4: %v", err)
						} else if stats != nil {
							geobanIPv4Loaded = stats.OutputRanges
							log.Printf("[SYNC] Geoban IPv4: loaded %d ranges (from %d input CIDRs)", stats.OutputRanges, stats.InputCIDRs)
						}
					}
				}

				// Load IPv6 geoban CIDRs into unified blacklist_ipv6 set
				if len(geobanData.IPv6) > 0 {
					geoSetV6, err := nft.GetOrCreateIntervalSet(tableIPv6, "blacklist_ipv6", false)
					if err != nil {
						log.Printf("[SYNC] Warning: Failed to get blacklist_ipv6 set: %v", err)
					} else {
						if stats, err := nft.AddCIDRElementsWithStats(geoSetV6, geobanData.IPv6); err != nil {
							log.Printf("[SYNC] Warning: Failed to load geoban IPv6: %v", err)
						} else if stats != nil {
							geobanIPv6Loaded = stats.OutputRanges
							log.Printf("[SYNC] Geoban IPv6: loaded %d ranges (from %d input CIDRs)", stats.OutputRanges, stats.InputCIDRs)
						}
					}
				}
				// Memory cleanup: clear geoban data to allow garbage collection
				// Geoban can hold 200-400MB that's no longer needed after loading
				geobanData.IPv4 = nil
				geobanData.IPv6 = nil
				geobanData = nil
				} // end else CanAllocate
			}
		}
		}
		} // end else ShouldSkipGeoban
	} // end if !quickMode (geoban)

	// Force garbage collection after large sync to release memory immediately
	// Without this, ~800MB-1.3GB can remain allocated until next GC cycle
	if !quickMode {
		goruntime.GC()
	}

	// ==========================================================================
	// PROTECTION STATE TRACKING
	// Record if feeds/geoban were skipped for visibility in health/CLI
	// ==========================================================================
	if feedsSkipped || geobanSkipped {
		if err := safety.RecordProtectionTriggered(feedsSkipped, geobanSkipped,
			feedsCIDRCount, geobanCIDRCount, feedsMemNeeded, geobanMemNeeded); err != nil {
			log.Printf("[SYNC] Warning: Failed to record protection state: %v", err)
		}
	} else if !quickMode {
		// Clear protection state if sync completed fully
		_ = safety.ClearProtectionState()
	}

	// Build response with protection status
	respData := map[string]any{
		"whitelist_ipv4_added":   result.WhitelistIPv4.IPsAdded,
		"whitelist_ipv4_removed": result.WhitelistIPv4.IPsRemoved,
		"whitelist_ipv6_added":   result.WhitelistIPv6.IPsAdded,
		"whitelist_ipv6_removed": result.WhitelistIPv6.IPsRemoved,
		"blacklist_ipv4_added":   result.BlacklistIPv4.IPsAdded,
		"blacklist_ipv4_removed": result.BlacklistIPv4.IPsRemoved,
		"blacklist_ipv6_added":   result.BlacklistIPv6.IPsAdded,
		"blacklist_ipv6_removed": result.BlacklistIPv6.IPsRemoved,
		"feeds_ipv4_loaded":      feedsIPv4Loaded,
		"feeds_ipv6_loaded":      feedsIPv6Loaded,
		"geoban_ipv4_loaded":     geobanIPv4Loaded,
		"geoban_ipv6_loaded":     geobanIPv6Loaded,
		"tcp_ports_in":           len(allPorts.TCPPortsIn),
		"tcp_ports_out":          len(allPorts.TCPPortsOut),
		"udp_ports_in":           len(allPorts.UDPPortsIn),
		"udp_ports_out":          len(allPorts.UDPPortsOut),
		"pressure_level":         safety.GetMemoryPressureLevel().String(),
	}

	// Add protection status to response for CLI visibility
	if feedsSkipped || geobanSkipped {
		respData["protection_active"] = true
		respData["feeds_skipped"] = feedsSkipped
		respData["geoban_skipped"] = geobanSkipped
		if feedsSkipped {
			respData["feeds_skipped_count"] = feedsCIDRCount
		}
		if geobanSkipped {
			respData["geoban_skipped_count"] = geobanCIDRCount
		}
	}

	return SocketResponse{
		Success: result.Success,
		Data:    respData,
	}
}

// handleLoadPortsRequest loads ports into nftables port sets
func (d *Daemon) handleLoadPortsRequest(params map[string]any) SocketResponse {
	_, configDir, _, _ := getDaemonPaths()
	portsDir := configDir + "/ports.d"

	// Load port configuration
	config, err := ports.LoadPortsFromDirectory(portsDir)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to load ports: " + err.Error()}
	}

	if len(config.AllRules) == 0 {
		return SocketResponse{
			Success: true,
			Data: map[string]any{
				"message":       "no port rules configured",
				"tcp_ports_in":  0,
				"tcp_ports_out": 0,
				"udp_ports_in":  0,
				"udp_ports_out": 0,
			},
		}
	}

	// Use backend's shared nftables manager
	nft := d.backend.GetNFTManager()
	if nft == nil {
		return SocketResponse{Success: false, Error: "nftables backend not initialized"}
	}

	// Create IPv4 table and sets
	ipv4Table, err := nft.GetOrCreateTable(nftables.TableFamilyIPv4)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to get IPv4 table: " + err.Error()}
	}

	// Directional port sets for IPv4 (v2.1 schema - NO legacy sets)
	tcpInSetV4, err := nft.GetOrCreatePortSet(ipv4Table, "tcp_ports_in")
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to create IPv4 tcp_ports_in set: " + err.Error()}
	}
	tcpOutSetV4, err := nft.GetOrCreatePortSet(ipv4Table, "tcp_ports_out")
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to create IPv4 tcp_ports_out set: " + err.Error()}
	}
	udpInSetV4, err := nft.GetOrCreatePortSet(ipv4Table, "udp_ports_in")
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to create IPv4 udp_ports_in set: " + err.Error()}
	}
	udpOutSetV4, err := nft.GetOrCreatePortSet(ipv4Table, "udp_ports_out")
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to create IPv4 udp_ports_out set: " + err.Error()}
	}

	// Create IPv6 table and sets
	ipv6Table, err := nft.GetOrCreateTable(nftables.TableFamilyIPv6)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to get IPv6 table: " + err.Error()}
	}

	// Directional port sets for IPv6 (v2.1 schema - NO legacy sets)
	tcpInSetV6, err := nft.GetOrCreatePortSet(ipv6Table, "tcp_ports_in")
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to create IPv6 tcp_ports_in set: " + err.Error()}
	}
	tcpOutSetV6, err := nft.GetOrCreatePortSet(ipv6Table, "tcp_ports_out")
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to create IPv6 tcp_ports_out set: " + err.Error()}
	}
	udpInSetV6, err := nft.GetOrCreatePortSet(ipv6Table, "udp_ports_in")
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to create IPv6 udp_ports_in set: " + err.Error()}
	}
	udpOutSetV6, err := nft.GetOrCreatePortSet(ipv6Table, "udp_ports_out")
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to create IPv6 udp_ports_out set: " + err.Error()}
	}

	// IMPORTANT: Flush all port sets first for idempotent reload
	// This ensures removed ports in config are also removed from nftables
	allPortSets := []*nftables.Set{
		tcpInSetV4, tcpOutSetV4, udpInSetV4, udpOutSetV4,
		tcpInSetV6, tcpOutSetV6, udpInSetV6, udpOutSetV6,
	}
	for _, set := range allPortSets {
		if err := nft.FlushSet(set); err != nil {
			log.Printf("[load_ports] Warning: failed to flush set %s: %v", set.Name, err)
			// Continue anyway - set might be empty
		}
	}

	// Load directional port sets (v2.1 schema)
	if len(config.TCPPortsIn) > 0 {
		if err := nft.AddPortElements(tcpInSetV4, config.TCPPortsIn); err != nil {
			return SocketResponse{Success: false, Error: "failed to add IPv4 TCP input ports: " + err.Error()}
		}
		if err := nft.AddPortElements(tcpInSetV6, config.TCPPortsIn); err != nil {
			return SocketResponse{Success: false, Error: "failed to add IPv6 TCP input ports: " + err.Error()}
		}
	}
	if len(config.TCPPortsOut) > 0 {
		if err := nft.AddPortElements(tcpOutSetV4, config.TCPPortsOut); err != nil {
			return SocketResponse{Success: false, Error: "failed to add IPv4 TCP output ports: " + err.Error()}
		}
		if err := nft.AddPortElements(tcpOutSetV6, config.TCPPortsOut); err != nil {
			return SocketResponse{Success: false, Error: "failed to add IPv6 TCP output ports: " + err.Error()}
		}
	}
	if len(config.UDPPortsIn) > 0 {
		if err := nft.AddPortElements(udpInSetV4, config.UDPPortsIn); err != nil {
			return SocketResponse{Success: false, Error: "failed to add IPv4 UDP input ports: " + err.Error()}
		}
		if err := nft.AddPortElements(udpInSetV6, config.UDPPortsIn); err != nil {
			return SocketResponse{Success: false, Error: "failed to add IPv6 UDP input ports: " + err.Error()}
		}
	}
	if len(config.UDPPortsOut) > 0 {
		if err := nft.AddPortElements(udpOutSetV4, config.UDPPortsOut); err != nil {
			return SocketResponse{Success: false, Error: "failed to add IPv4 UDP output ports: " + err.Error()}
		}
		if err := nft.AddPortElements(udpOutSetV6, config.UDPPortsOut); err != nil {
			return SocketResponse{Success: false, Error: "failed to add IPv6 UDP output ports: " + err.Error()}
		}
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"tcp_ports_in":  len(config.TCPPortsIn),
			"tcp_ports_out": len(config.TCPPortsOut),
			"udp_ports_in":  len(config.UDPPortsIn),
			"udp_ports_out": len(config.UDPPortsOut),
			"total":         len(config.AllRules),
		},
	}
}

// handleAddPortElementRequest atomically adds port(s) to nftables sets
// Params: ports ([]int), protocol (tcp/udp/both), direction (in/out/both)
func (d *Daemon) handleAddPortElementRequest(params map[string]any) SocketResponse {
	// Parse ports list
	portsRaw, ok := params["ports"].([]any)
	if !ok || len(portsRaw) == 0 {
		// Try single port
		if port, ok := params["port"].(float64); ok {
			portsRaw = []any{port}
		} else {
			return SocketResponse{Success: false, Error: "missing ports parameter"}
		}
	}

	var ports []int
	for _, p := range portsRaw {
		if pf, ok := p.(float64); ok {
			if pf < 1 || pf > 65535 {
				return SocketResponse{Success: false, Error: fmt.Sprintf("invalid port: %v", p)}
			}
			ports = append(ports, int(pf))
		}
	}

	protocol, _ := params["protocol"].(string)
	if protocol == "" {
		protocol = "tcp"
	}
	direction, _ := params["direction"].(string)
	if direction == "" {
		direction = "in"
	}

	// Use backend's shared nftables manager
	nft := d.backend.GetNFTManager()
	if nft == nil {
		return SocketResponse{Success: false, Error: "nftables backend not initialized"}
	}

	// Get tables
	ipv4Table, err := nft.GetOrCreateTable(nftables.TableFamilyIPv4)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to get IPv4 table: " + err.Error()}
	}
	ipv6Table, err := nft.GetOrCreateTable(nftables.TableFamilyIPv6)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to get IPv6 table: " + err.Error()}
	}

	// Determine which sets to update (v2.1 schema - directional only)
	var setNames []string
	switch strings.ToLower(protocol) {
	case "tcp", "t":
		switch strings.ToLower(direction) {
		case "in", "i", "input":
			setNames = []string{"tcp_ports_in"}
		case "out", "o", "output":
			setNames = []string{"tcp_ports_out"}
		case "both", "io", "b", "inout":
			setNames = []string{"tcp_ports_in", "tcp_ports_out"}
		default:
			setNames = []string{"tcp_ports_in"}
		}
	case "udp", "u":
		switch strings.ToLower(direction) {
		case "in", "i", "input":
			setNames = []string{"udp_ports_in"}
		case "out", "o", "output":
			setNames = []string{"udp_ports_out"}
		case "both", "io", "b", "inout":
			setNames = []string{"udp_ports_in", "udp_ports_out"}
		default:
			setNames = []string{"udp_ports_in"}
		}
	case "both", "b":
		switch strings.ToLower(direction) {
		case "in", "i", "input":
			setNames = []string{"tcp_ports_in", "udp_ports_in"}
		case "out", "o", "output":
			setNames = []string{"tcp_ports_out", "udp_ports_out"}
		case "both", "io", "b", "inout":
			setNames = []string{"tcp_ports_in", "tcp_ports_out", "udp_ports_in", "udp_ports_out"}
		default:
			setNames = []string{"tcp_ports_in", "udp_ports_in"}
		}
	default:
		setNames = []string{"tcp_ports_in"}
	}

	added := 0
	for _, setName := range setNames {
		// IPv4
		set, err := nft.GetOrCreatePortSet(ipv4Table, setName)
		if err != nil {
			log.Printf("[add_port_element] Warning: failed to get IPv4 set %s: %v", setName, err)
			continue
		}
		if err := nft.AddPortElements(set, ports); err != nil {
			log.Printf("[add_port_element] Warning: failed to add to IPv4 %s: %v", setName, err)
		} else {
			added++
		}

		// IPv6
		set, err = nft.GetOrCreatePortSet(ipv6Table, setName)
		if err != nil {
			log.Printf("[add_port_element] Warning: failed to get IPv6 set %s: %v", setName, err)
			continue
		}
		if err := nft.AddPortElements(set, ports); err != nil {
			log.Printf("[add_port_element] Warning: failed to add to IPv6 %s: %v", setName, err)
		} else {
			added++
		}
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"ports":     ports,
			"protocol":  protocol,
			"direction": direction,
			"sets":      setNames,
			"added":     added,
		},
	}
}

// handleDeletePortElementRequest atomically removes port(s) from nftables sets
// Params: ports ([]int), protocol (tcp/udp/both), direction (in/out/both)
func (d *Daemon) handleDeletePortElementRequest(params map[string]any) SocketResponse {
	// Parse ports list
	portsRaw, ok := params["ports"].([]any)
	if !ok || len(portsRaw) == 0 {
		// Try single port
		if port, ok := params["port"].(float64); ok {
			portsRaw = []any{port}
		} else {
			return SocketResponse{Success: false, Error: "missing ports parameter"}
		}
	}

	var ports []int
	for _, p := range portsRaw {
		if pf, ok := p.(float64); ok {
			if pf < 1 || pf > 65535 {
				return SocketResponse{Success: false, Error: fmt.Sprintf("invalid port: %v", p)}
			}
			ports = append(ports, int(pf))
		}
	}

	protocol, _ := params["protocol"].(string)
	if protocol == "" {
		protocol = "tcp"
	}
	direction, _ := params["direction"].(string)
	if direction == "" {
		direction = "in"
	}

	// Use backend's shared nftables manager
	nft := d.backend.GetNFTManager()
	if nft == nil {
		return SocketResponse{Success: false, Error: "nftables backend not initialized"}
	}

	// Get tables
	ipv4Table, err := nft.GetOrCreateTable(nftables.TableFamilyIPv4)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to get IPv4 table: " + err.Error()}
	}
	ipv6Table, err := nft.GetOrCreateTable(nftables.TableFamilyIPv6)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to get IPv6 table: " + err.Error()}
	}

	// Determine which sets to update (v2.1 schema - directional only)
	var setNames []string
	switch strings.ToLower(protocol) {
	case "tcp", "t":
		switch strings.ToLower(direction) {
		case "in", "i", "input":
			setNames = []string{"tcp_ports_in"}
		case "out", "o", "output":
			setNames = []string{"tcp_ports_out"}
		case "both", "io", "b", "inout":
			setNames = []string{"tcp_ports_in", "tcp_ports_out"}
		default:
			setNames = []string{"tcp_ports_in"}
		}
	case "udp", "u":
		switch strings.ToLower(direction) {
		case "in", "i", "input":
			setNames = []string{"udp_ports_in"}
		case "out", "o", "output":
			setNames = []string{"udp_ports_out"}
		case "both", "io", "b", "inout":
			setNames = []string{"udp_ports_in", "udp_ports_out"}
		default:
			setNames = []string{"udp_ports_in"}
		}
	case "both", "b":
		switch strings.ToLower(direction) {
		case "in", "i", "input":
			setNames = []string{"tcp_ports_in", "udp_ports_in"}
		case "out", "o", "output":
			setNames = []string{"tcp_ports_out", "udp_ports_out"}
		case "both", "io", "b", "inout":
			setNames = []string{"tcp_ports_in", "tcp_ports_out", "udp_ports_in", "udp_ports_out"}
		default:
			setNames = []string{"tcp_ports_in", "udp_ports_in"}
		}
	default:
		setNames = []string{"tcp_ports_in"}
	}

	deleted := 0
	for _, setName := range setNames {
		// IPv4 - use GetPortSet (not GetOrCreatePortSet) to avoid creating empty sets
		set, err := nft.GetPortSet(ipv4Table, setName)
		if err != nil {
			log.Printf("[delete_port_element] Warning: failed to get IPv4 set %s: %v", setName, err)
			continue
		}
		if set == nil {
			// Set doesn't exist - nothing to delete (idempotent)
			continue
		}
		if err := nft.DeletePortElements(set, ports); err != nil {
			log.Printf("[delete_port_element] Warning: failed to delete from IPv4 %s: %v", setName, err)
		} else {
			deleted++
		}

		// IPv6 - use GetPortSet (not GetOrCreatePortSet) to avoid creating empty sets
		set, err = nft.GetPortSet(ipv6Table, setName)
		if err != nil {
			log.Printf("[delete_port_element] Warning: failed to get IPv6 set %s: %v", setName, err)
			continue
		}
		if set == nil {
			// Set doesn't exist - nothing to delete (idempotent)
			continue
		}
		if err := nft.DeletePortElements(set, ports); err != nil {
			log.Printf("[delete_port_element] Warning: failed to delete from IPv6 %s: %v", setName, err)
		} else {
			deleted++
		}
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"ports":     ports,
			"protocol":  protocol,
			"direction": direction,
			"sets":      setNames,
			"deleted":   deleted,
		},
	}
}

// handleLoadCIDRsRequest loads CIDRs into a blacklist or whitelist set
func (d *Daemon) handleLoadCIDRsRequest(params map[string]any) SocketResponse {
	setType, _ := params["set_type"].(string) // "blacklist" or "whitelist"
	if setType == "" {
		setType = "blacklist"
	}

	// Memory safety pre-check: estimate memory needs before loading
	// Each CIDR in Go uses ~100 bytes for the string + parsing overhead
	// CIDR merging can temporarily 2-3x memory usage during sort/merge
	const bytesPerCIDREstimate = 300 // conservative estimate including merge overhead

	// Get CIDRs from params
	cidrsRaw, ok := params["cidrs"].([]any)
	if !ok || len(cidrsRaw) == 0 {
		// Try to load from feeds/trust directory
		_, _, dataDir, _ := getDaemonPaths()

		var ipv4CIDRs, ipv6CIDRs []string

		if setType == "blacklist" {
			// Load feeds
			feedsDir := dataDir + "/feeds"
			ipv4Set, ipv6Set, ipv4CIDRSet, ipv6CIDRSet, _, err := feeds.LoadAllFeeds(feedsDir)
			if err != nil {
				return SocketResponse{Success: false, Error: "failed to load feeds: " + err.Error()}
			}

			// Pre-allocate slices with exact capacity to avoid reallocation overhead
			ipv4CIDRs = make([]string, 0, len(ipv4Set)+len(ipv4CIDRSet))
			ipv6CIDRs = make([]string, 0, len(ipv6Set)+len(ipv6CIDRSet))
			for ip := range ipv4Set {
				ipv4CIDRs = append(ipv4CIDRs, ip+"/32")
			}
			for cidr := range ipv4CIDRSet {
				ipv4CIDRs = append(ipv4CIDRs, cidr)
			}
			for ip := range ipv6Set {
				ipv6CIDRs = append(ipv6CIDRs, ip+"/128")
			}
			for cidr := range ipv6CIDRSet {
				ipv6CIDRs = append(ipv6CIDRs, cidr)
			}

			// Memory safety check before CIDR merging (which can 3x memory temporarily)
			totalCIDRs := len(ipv4CIDRs) + len(ipv6CIDRs)
			estimatedBytes := int64(totalCIDRs) * bytesPerCIDREstimate
			if !safety.CanAllocate(estimatedBytes) {
				mem := safety.AvailableMem()
				return SocketResponse{
					Success: false,
					Error: fmt.Sprintf("insufficient memory for %d CIDRs: need ~%s, available %s",
						totalCIDRs, safety.FormatBytes(estimatedBytes), safety.FormatBytes(mem.Avail)),
				}
			}
		} else {
			// Load trust feeds
			trustDir := dataDir + "/trust"
			files, err := os.ReadDir(trustDir)
			if err != nil {
				return SocketResponse{Success: false, Error: "failed to read trust directory: " + err.Error()}
			}

			for _, file := range files {
				if file.IsDir() || !strings.HasSuffix(file.Name(), ".txt") {
					continue
				}

				content, err := os.ReadFile(trustDir + "/" + file.Name())
				if err != nil {
					continue
				}

				lines := strings.Split(string(content), "\n")
				for _, line := range lines {
					line = strings.TrimSpace(line)
					if line == "" || strings.HasPrefix(line, "#") {
						continue
					}

					if strings.Contains(line, ":") {
						// IPv6
						if !strings.Contains(line, "/") {
							line += "/128"
						}
						ipv6CIDRs = append(ipv6CIDRs, line)
					} else {
						// IPv4
						if !strings.Contains(line, "/") {
							line += "/32"
						}
						ipv4CIDRs = append(ipv4CIDRs, line)
					}
				}
			}

			// Memory safety check for trust feeds
			totalCIDRs := len(ipv4CIDRs) + len(ipv6CIDRs)
			estimatedBytes := int64(totalCIDRs) * bytesPerCIDREstimate
			if !safety.CanAllocate(estimatedBytes) {
				mem := safety.AvailableMem()
				return SocketResponse{
					Success: false,
					Error: fmt.Sprintf("insufficient memory for %d trust CIDRs: need ~%s, available %s",
						totalCIDRs, safety.FormatBytes(estimatedBytes), safety.FormatBytes(mem.Avail)),
				}
			}
		}

		// Load into nftables
		return d.loadCIDRsIntoSets(setType, ipv4CIDRs, ipv6CIDRs)
	}

	// Parse CIDRs from params - pre-allocate to avoid repeated reallocations
	ipv4CIDRs := make([]string, 0, len(cidrsRaw))
	ipv6CIDRs := make([]string, 0, len(cidrsRaw)/10) // IPv6 typically much less common
	for _, cidrRaw := range cidrsRaw {
		cidr, ok := cidrRaw.(string)
		if !ok {
			continue
		}
		if strings.Contains(cidr, ":") {
			ipv6CIDRs = append(ipv6CIDRs, cidr)
		} else {
			ipv4CIDRs = append(ipv4CIDRs, cidr)
		}
	}

	// Memory safety check for direct CIDRs
	totalCIDRs := len(ipv4CIDRs) + len(ipv6CIDRs)
	estimatedBytes := int64(totalCIDRs) * bytesPerCIDREstimate
	if !safety.CanAllocate(estimatedBytes) {
		mem := safety.AvailableMem()
		return SocketResponse{
			Success: false,
			Error: fmt.Sprintf("insufficient memory for %d CIDRs: need ~%s, available %s",
				totalCIDRs, safety.FormatBytes(estimatedBytes), safety.FormatBytes(mem.Avail)),
		}
	}

	return d.loadCIDRsIntoSets(setType, ipv4CIDRs, ipv6CIDRs)
}

// loadCIDRsIntoSets loads CIDRs into the appropriate nftables sets
func (d *Daemon) loadCIDRsIntoSets(setType string, ipv4CIDRs, ipv6CIDRs []string) SocketResponse {
	// Use backend's shared nftables manager
	nft := d.backend.GetNFTManager()
	if nft == nil {
		return SocketResponse{Success: false, Error: "nftables backend not initialized"}
	}

	// Determine set names
	var setNameV4, setNameV6 string
	if setType == "whitelist" {
		setNameV4 = "whitelist_ipv4"
		setNameV6 = "whitelist_ipv6"
	} else {
		setNameV4 = "blacklist_ipv4"
		setNameV6 = "blacklist_ipv6"
	}

	var ipv4Stats, ipv6Stats *nftsync.MergeStats

	// Load IPv4 CIDRs
	if len(ipv4CIDRs) > 0 {
		tableIPv4, err := nft.GetOrCreateTable(nftables.TableFamilyIPv4)
		if err != nil {
			return SocketResponse{Success: false, Error: "failed to get IPv4 table: " + err.Error()}
		}

		setIPv4, err := nft.GetOrCreateIntervalSet(tableIPv4, setNameV4, true)
		if err != nil {
			return SocketResponse{Success: false, Error: "failed to get " + setNameV4 + " set: " + err.Error()}
		}

		stats, err := nft.AddCIDRElementsWithStats(setIPv4, ipv4CIDRs)
		if err != nil {
			// Check for overlap errors (not fatal)
			if !strings.Contains(err.Error(), "conflicting intervals") {
				return SocketResponse{Success: false, Error: "failed to load IPv4 CIDRs: " + err.Error()}
			}
		}
		ipv4Stats = stats
	}

	// Load IPv6 CIDRs
	if len(ipv6CIDRs) > 0 {
		tableIPv6, err := nft.GetOrCreateTable(nftables.TableFamilyIPv6)
		if err != nil {
			return SocketResponse{Success: false, Error: "failed to get IPv6 table: " + err.Error()}
		}

		setIPv6, err := nft.GetOrCreateIntervalSet(tableIPv6, setNameV6, false)
		if err != nil {
			return SocketResponse{Success: false, Error: "failed to get " + setNameV6 + " set: " + err.Error()}
		}

		stats, err := nft.AddCIDRElementsWithStats(setIPv6, ipv6CIDRs)
		if err != nil {
			return SocketResponse{Success: false, Error: "failed to load IPv6 CIDRs: " + err.Error()}
		}
		ipv6Stats = stats
	}

	// Build response data
	data := map[string]any{
		"set_type":    setType,
		"ipv4_input":  len(ipv4CIDRs),
		"ipv6_input":  len(ipv6CIDRs),
		"total_input": len(ipv4CIDRs) + len(ipv6CIDRs),
	}

	if ipv4Stats != nil {
		data["ipv4_output_ranges"] = ipv4Stats.OutputRanges
		data["ipv4_reduction_pct"] = ipv4Stats.ReductionPct
	}
	if ipv6Stats != nil {
		data["ipv6_output_ranges"] = ipv6Stats.OutputRanges
		data["ipv6_reduction_pct"] = ipv6Stats.ReductionPct
	}

	return SocketResponse{
		Success: true,
		Data:    data,
	}
}

// =============================================================================
// STATS IPC HANDLERS
// =============================================================================

// handleStatsRequest returns current daemon runtime stats
func (d *Daemon) handleStatsRequest() SocketResponse {
	if d.stats == nil {
		return SocketResponse{
			Success: false,
			Error:   "stats collector not initialized",
		}
	}

	snapshot := d.stats.Collect()
	// Set version from const
	snapshot.Daemon.Version = version.Version

	return SocketResponse{
		Success: true,
		Data:    snapshot,
	}
}

// handleStatsHistoryRequest returns historical stats for specified days
func (d *Daemon) handleStatsHistoryRequest(params map[string]any) SocketResponse {
	if d.stats == nil {
		return SocketResponse{
			Success: false,
			Error:   "stats collector not initialized",
		}
	}

	days := 1
	if d, ok := params["days"].(float64); ok {
		days = int(d)
	}
	if days < 1 {
		days = 1
	}
	if days > 30 {
		days = 30
	}

	config := d.stats.GetConfig()
	historyDir := config.HistoryDir

	// Read history files
	var history []stats.DailyStats
	for i := 0; i < days; i++ {
		date := time.Now().AddDate(0, 0, -i).Format("2006-01-02")
		filePath := historyDir + "/" + date + ".json"

		var daily stats.DailyStats
		if err := stats.ReadJSON(filePath, &daily); err == nil && daily.Date != "" {
			history = append(history, daily)
		}
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"days":    days,
			"history": history,
		},
	}
}

// handleSnapshotProfileRequest triggers a pprof capture
func (d *Daemon) handleSnapshotProfileRequest(params map[string]any) SocketResponse {
	if d.stats == nil {
		return SocketResponse{
			Success: false,
			Error:   "stats collector not initialized",
		}
	}

	config := d.stats.GetConfig()

	// Check if profiling is enabled
	if !config.IsProfileEnabled() {
		return SocketResponse{
			Success: false,
			Error:   "profiling is disabled in configuration (NFTBAN_WATCHDOG_PROFILE_ENABLED=false)",
		}
	}

	// Check if we can create a new profile (max count limit)
	if !stats.CanCreateProfile(config.ProfileDir, config.ProfileMaxCount) {
		return SocketResponse{
			Success: false,
			Error:   fmt.Sprintf("max profile count (%d) reached, cleanup required", config.ProfileMaxCount),
		}
	}

	profileType := "heap"
	if t, ok := params["type"].(string); ok && t != "" {
		profileType = t
	}

	duration := 0
	if d, ok := params["duration"].(float64); ok {
		duration = int(d)
	}

	// Create profile based on type
	timestamp := time.Now().Format("20060102_150405")
	var filename string
	var err error

	switch profileType {
	case "heap":
		filename = fmt.Sprintf("heap_%s.pprof", timestamp)
		err = d.captureHeapProfile(config.ProfileDir + "/" + filename)
	case "goroutine":
		filename = fmt.Sprintf("goroutine_%s.pprof", timestamp)
		err = d.captureGoroutineProfile(config.ProfileDir + "/" + filename)
	case "cpu":
		if duration < 1 {
			duration = 30 // Default 30 seconds
		}
		if duration > 120 {
			duration = 120 // Max 2 minutes
		}
		filename = fmt.Sprintf("cpu_%s_%ds.pprof", timestamp, duration)
		err = d.captureCPUProfile(config.ProfileDir+"/"+filename, duration)
	default:
		return SocketResponse{
			Success: false,
			Error:   "unsupported profile type: " + profileType + " (use: heap, goroutine, cpu)",
		}
	}

	if err != nil {
		return SocketResponse{
			Success: false,
			Error:   "failed to capture profile: " + err.Error(),
		}
	}

	// Log the capture
	d.logProfileCapture(config.ProfileLog, profileType, filename)

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"type":     profileType,
			"filename": filename,
			"path":     config.ProfileDir + "/" + filename,
			"duration": duration,
		},
	}
}

// captureHeapProfile writes a heap profile to file
func (d *Daemon) captureHeapProfile(path string) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()

	goruntime.GC() // Force GC for accurate heap stats
	return pprof.WriteHeapProfile(f)
}

// captureGoroutineProfile writes a goroutine profile to file
func (d *Daemon) captureGoroutineProfile(path string) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()

	return pprof.Lookup("goroutine").WriteTo(f, 0)
}

// captureCPUProfile captures CPU profile for specified duration
func (d *Daemon) captureCPUProfile(path string, seconds int) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}

	if err := pprof.StartCPUProfile(f); err != nil {
		f.Close()
		return err
	}

	// Run in goroutine so we don't block
	go func() {
		time.Sleep(time.Duration(seconds) * time.Second)
		pprof.StopCPUProfile()
		f.Close()
	}()

	return nil
}

// logProfileCapture logs profile capture to profiles.log
func (d *Daemon) logProfileCapture(logPath, profileType, filename string) {
	// Ensure directory exists
	if err := os.MkdirAll(filepath.Dir(logPath), 0750); err != nil {
		log.Printf("stats: failed to create profile log directory: %v", err)
		return
	}

	f, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0640)
	if err != nil {
		log.Printf("stats: failed to open profile log: %v", err)
		return
	}
	defer f.Close()

	line := fmt.Sprintf("%s captured %s profile: %s\n",
		time.Now().Format(time.RFC3339),
		profileType,
		filename,
	)
	f.WriteString(line)
}

// =============================================================================
// v1.13.0: ASYNC IPC HANDLERS
// =============================================================================

// handleReplaceSetRequest handles bulk replace_set operations via file
// This is for feeds/geoban that need atomic flush+bulk-add
func (d *Daemon) handleReplaceSetRequest(params map[string]any) SocketResponse {
	if d.opQueue == nil {
		return SocketResponse{Success: false, Error: "OpQueue not initialized"}
	}

	setName, _ := params["set"].(string)
	filePath, _ := params["file"].(string)
	source, _ := params["source"].(string)
	deleteFile, _ := params["delete_file"].(bool)

	if setName == "" {
		return SocketResponse{Success: false, Error: "missing set parameter"}
	}
	if !validNFTBanSet(setName) {
		return SocketResponse{Success: false, Error: "invalid set: " + setName}
	}
	if filePath == "" {
		return SocketResponse{Success: false, Error: "missing file parameter"}
	}
	if source == "" {
		source = "unknown"
	}

	// Read elements from file with security checks
	result, err := opqueue.SecureReadElementsFile(filePath)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to read file: " + err.Error()}
	}

	// Queue the replace operation
	if err := d.opQueue.EnqueueReplace(setName, result.Elements, source); err != nil {
		return SocketResponse{Success: false, Error: "failed to queue replace: " + err.Error()}
	}

	// Optionally delete the file after reading
	if deleteFile {
		os.Remove(filePath)
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"set":      setName,
			"source":   source,
			"elements": result.Count,
			"queued":   true,
		},
	}
}

// handleFlushSourceRequest removes all elements from a source
// Uses SourceIndex to find elements belonging to a source, then unbans them
// v1.18.1 FIX: Uses sourceIndex for ALL sources using shared blacklist_* sets
// to prevent coexistence bugs (feeds flush wiping geoban entries)
func (d *Daemon) handleFlushSourceRequest(params map[string]any) SocketResponse {
	if d.opQueue == nil || d.sourceIndex == nil {
		return SocketResponse{Success: false, Error: "OpQueue/SourceIndex not initialized"}
	}

	source, _ := params["source"].(string)
	if source == "" {
		return SocketResponse{Success: false, Error: "missing source parameter"}
	}

	// Get source configuration to determine target sets
	cfg, found := opqueue.GetSourceConfig(source)
	if !found {
		return SocketResponse{Success: false, Error: "unknown source: " + source}
	}

	// v1.18.1 FIX: Check if source uses shared blacklist sets
	// In unified blacklist architecture, feeds/geoban/manual all share blacklist_ipv4/ipv6
	// We must use sourceIndex-based removal to avoid wiping other sources' entries
	isSharedSet := cfg.IPv4Set == "blacklist_ipv4" || cfg.IPv6Set == "blacklist_ipv6"

	// Only use full flush for truly dedicated sets (not blacklist_*)
	if cfg.AllowBulk && !cfg.AllowBan && !isSharedSet {
		// Queue flush for dedicated IPv4 and IPv6 sets (e.g., feeds_ipv4, geoban_ipv4)
		if err := d.opQueue.EnqueueFlush(cfg.IPv4Set); err != nil {
			log.Printf("[FlushSource] Warning: failed to queue flush %s: %v", cfg.IPv4Set, err)
		}
		if err := d.opQueue.EnqueueFlush(cfg.IPv6Set); err != nil {
			log.Printf("[FlushSource] Warning: failed to queue flush %s: %v", cfg.IPv6Set, err)
		}

		return SocketResponse{
			Success: true,
			Data: map[string]any{
				"source": source,
				"sets":   []string{cfg.IPv4Set, cfg.IPv6Set},
				"action": "flush_set",
				"queued": true,
			},
		}
	}

	// For shared sets (blacklist_*), use source index to find and unban only this source's elements
	// This prevents feeds flush from wiping geoban/manual entries (coexistence bug fix)
	unbanned := 0
	for _, setName := range []string{cfg.IPv4Set, cfg.IPv6Set} {
		elements := d.sourceIndex.GetElementsBySource(setName, source)
		for _, elem := range elements {
			// Remove from source index
			d.sourceIndex.Remove(setName, elem, source)

			// Only unban if no other sources remain
			if d.sourceIndex.ShouldDelete(setName, elem) {
				if err := d.opQueue.EnqueueUnban(setName, elem, source); err != nil {
					log.Printf("[FlushSource] Warning: failed to queue unban %s: %v", elem, err)
					continue
				}
				unbanned++
			}
		}
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"source":   source,
			"unbanned": unbanned,
			"action":   "source_unban",
			"queued":   true,
		},
	}
}

// handleQueueStatusRequest returns OpQueue statistics
func (d *Daemon) handleQueueStatusRequest() SocketResponse {
	if d.opQueue == nil {
		return SocketResponse{Success: false, Error: "OpQueue not initialized"}
	}

	stats := d.opQueue.Stats()

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"pending_count":   stats.PendingCount,
			"total_queued":    stats.TotalQueued,
			"total_applied":   stats.TotalApplied,
			"total_dropped":   stats.TotalDropped,
			"last_flush_time": stats.LastFlushTime.Format(time.RFC3339),
			"queue_depth":     d.opQueue.QueueDepth(),
		},
	}
}

// =============================================================================
// CONFIG RELOAD IPC HANDLER (v1.13.12)
// =============================================================================

// handleReloadRequest handles config reload request via IPC
// Returns the new config hash and reload timestamp for verification
func (d *Daemon) handleReloadRequest(params map[string]any) SocketResponse {
	// Perform config reload
	if err := d.reloadConfig(); err != nil {
		return SocketResponse{
			Success: false,
			Error:   err.Error(),
		}
	}

	d.reloadMu.RLock()
	hash := d.configHash
	ts := d.lastReloadTs
	d.reloadMu.RUnlock()

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"reloaded":    true,
			"config_hash": hash,
			"reloaded_at": ts.Format(time.RFC3339),
		},
	}
}
