// =============================================================================
// NFTBan v1.0 - nftband Daemon - Daemon initialization, configuration, and startup sequence
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftband"
// meta:type="cmd"
// meta:version="1.41.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Daemon initialization, configuration, and startup sequence"
//
// meta:inventory.files="/usr/lib/nftban/bin/nftband"
// meta:inventory.binaries="nftband"
// meta:inventory.env_vars="NFTBAN_CONFIG_DIR, NFTBAN_LOG_DIR"
// meta:inventory.config_files="/etc/nftban/nftban.conf"
// meta:inventory.systemd_units="nftband.service, nftband.socket"
// meta:inventory.network="9580/tcp (HTTP API), /run/nftban/nftband.sock (Unix)"
// meta:inventory.privileges="root"
// =============================================================================

package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	goruntime "runtime"

	"github.com/itcmsgr/nftban/internal/constants"
	"github.com/itcmsgr/nftban/internal/nftlock"
	"github.com/itcmsgr/nftban/internal/stats"

	"github.com/itcmsgr/nftban/internal/banlog"
	"github.com/itcmsgr/nftban/internal/botguard"
	"github.com/itcmsgr/nftban/internal/ddos"
	"github.com/itcmsgr/nftban/internal/eventbus"
	"github.com/itcmsgr/nftban/internal/loginmon"
	"github.com/itcmsgr/nftban/internal/metrics"
	"github.com/itcmsgr/nftban/internal/nftbackend"
	"github.com/itcmsgr/nftban/internal/opqueue"
	"github.com/itcmsgr/nftban/internal/portscan"
	"github.com/itcmsgr/nftban/internal/safeconv"
	"github.com/itcmsgr/nftban/internal/safety"
	"github.com/itcmsgr/nftban/pkg/version"
	"github.com/itcmsgr/nftban/internal/watchdog"
)

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

	// v1.34.0: Pre-create nft lock file for early operations (LIVE-BUG-1 fix)
	if _, err := os.OpenFile(nftlock.LockPath, os.O_CREATE|os.O_RDWR, 0640); err != nil { // #nosec G302
		log.Printf("Warning: could not pre-create nft lock file: %v", err)
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

	// BUG-008 FIX: Set CIDR limit metric based on server tier at startup
	cidrLimit, cidrTier := safety.GetMaxCIDRsHardWithTier()
	metrics.SetCIDRLimitHard(cidrLimit)
	log.Printf("Server tier: %s (max CIDRs: %d)", cidrTier, cidrLimit)

	// Register modules
	d.registerModules()

	// Initialize all modules with event bus
	log.Println("Initializing modules...")
	if err := d.registry.InitAll(d.bus); err != nil {
		return fmt.Errorf("failed to initialize modules: %w", err)
	}

	// Wire OpQueue to bot guard module (needs OpQueue for set enforcement)
	if bgMod, ok := d.registry.Get(botguard.ModuleName); ok {
		if bg, ok := bgMod.(*botguard.Module); ok && d.opQueue != nil {
			bg.InitEnforcer(d.opQueue)
		}
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
			metrics.RecordBanWithIP(e.Source, family, e.IP)
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
			case strings.Contains(e.Source, "botguard"):
				banSource = banlog.SourceDDoS // Bot guard bans categorized as DDoS
			}
			country := lookupCountry(e.IP)
			// v1.41.0: Generate ban correlation ID to link BAN→UNBAN entries
			banID := banlog.GenerateBanID()
			d.banIDMap.Store(e.IP, banID)
			// BLC-1: determine ban class from event data
			banClass := banlog.ClassTemp
			if timeout == 0 {
				banClass = banlog.ClassPermanent
			} else if timeout > 900 { // > 15m default = escalated
				banClass = banlog.ClassEscalated
			}
			_ = banlog.LogBanFull(e.IP, banSource, country, reason, banID, timeout, banClass)

			// Check persistent offender escalation for temp bans
			// If this IP has been temp-banned too many times, escalate to permanent
			if timeout > 0 {
				go d.checkAndEscalate(e.IP, e.Source, country)
			}
		}
	})

	// v1.41.0: Subscribe attack rate tracker to ban/ddos/portscan events
	attackTracker := metrics.GetAttackRateTracker()
	for _, et := range []eventbus.EventType{eventbus.EventBan, eventbus.EventDDoSDetected, eventbus.EventPortscan} {
		et := et // capture for closure
		d.bus.Subscribe(et, func(e eventbus.Event) {
			_ = et // avoid unused warning
			attackTracker.RecordAttack()
		})
	}

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

	// v1.38.0: Log recommended WatchdogSec based on total set elements
	d.logWatchdogSecGuidance()

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

	// Register HTTP Bot Guard module (v1.20.0)
	d.registry.Register(botguard.New(), botguard.Descriptor())

	// TODO: Register more modules as they are implemented
	// d.registry.Register(suricata.NewWatcher(), suricata.Descriptor())

	log.Printf("Registered %d modules", len(d.registry.All()))
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

		// v1.89 INV-M-008: Wire memory pressure → Prometheus gauges (call site 2 of 2).
		pressureLevel := safety.GetMemoryPressureLevel()
		metrics.SetMemoryPressureLevel(int(pressureLevel))
		budget := safety.GetMemoryBudget()
		metrics.SetMemoryBudgetBytes(budget)
		if budget > 0 {
			usedPct := float64(snapshot.Process.RSS) / float64(budget) * 100
			if usedPct > 100 {
				usedPct = 100
			}
			metrics.SetMemoryUsedPercent(usedPct)
		}
	})

	// Wire up action callback so nftban_watchdog_action_total and
	// nftban_watchdog_last_action_timestamp_seconds actually emit in production
	// (fixes D-METR-2 — registered-but-unwired emission).
	wd.SetOnAction(func(action watchdog.Action) {
		d.wdMetrics.RecordAction(action)
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

	// v1.32.0: Initialize set element counters for huge set management
	runDir, _, _, _ := getDaemonPaths()
	d.setCounters = stats.NewSetCounters(runDir)

	// Wire OpQueue flush callback to update set counters
	d.opQueue.SetOnFlush(func(setName string, applied int, opType string) {
		switch opType {
		case "add":
			d.setCounters.Add(setName, int64(applied))
		case "delete":
			d.setCounters.Add(setName, -int64(applied))
		case "replace":
			d.setCounters.Set(setName, int64(applied))
		case "flush":
			d.setCounters.Set(setName, 0)
		}
	})

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

	// Start set counter cache file writer (v1.32.0)
	d.bgWg.Add(1)
	go func() {
		defer d.bgWg.Done()
		d.setCounters.CacheWriterLoop(d.ctx)
	}()

	// Reconcile source index with actual nft state, then start periodic loop
	go func() {
		time.Sleep(constants.DaemonStartupWait) // Wait for daemon to fully start
		d.sourceIndex.ReconcileWithBackend(wrapper)

		// v1.32.0: Reconcile set counters from kernel on startup (one-time full count)
		d.reconcileSetCountersFromKernel(wrapper)

		// v1.34.0: Start periodic reconciliation after initial startup
		d.startPeriodicReconciliation(wrapper)
	}()

	log.Println("[OpQueue] Async operation queue initialized")
	return nil
}

// reconcileSetCountersFromKernel counts elements in all nftban sets
// and initializes the in-memory counters. Called once on startup. (v1.32.0)
func (d *Daemon) reconcileSetCountersFromKernel(wrapper *opqueue.NFTBackendWrapper) {
	log.Println("[set_counters] Reconciling set counts from kernel state...")

	// Known set names in the nftban schema
	setNames := []string{
		"blacklist_ipv4", "blacklist_ipv6",
		"blacklist_manual_ipv4", "blacklist_manual_ipv6", // v1.34.0: hash sets
		"whitelist_ipv4", "whitelist_ipv6",
		"tcp_ports_in", "tcp_ports_out",
		"udp_ports_in", "udp_ports_out",
	}

	for _, setName := range setNames {
		// Use GetSetCount instead of GetSetElements to avoid loading all elements
		// into memory. On a 500K+ interval set, GetSetElements causes 1GB+ heap spike.
		count, err := wrapper.GetSetCount("nftban", setName)
		if err != nil {
			// Set might not exist yet (e.g. IPv6 not configured)
			log.Printf("[set_counters] %s: skipped (%v)", setName, err)
			continue
		}
		d.setCounters.SetReconciled(setName, int64(count))
		if count > 0 {
			log.Printf("[set_counters] %s: %d elements [%s]", setName, count, d.setCounters.Scale(setName))
		}
	}

	// v1.41.0: Also check port_allow concat sets
	portAllowSets := []string{
		"port_allow_tcp_ipv4", "port_allow_udp_ipv4",
		"port_allow_tcp_ipv6", "port_allow_udp_ipv6",
	}
	for _, setName := range portAllowSets {
		count, err := wrapper.GetSetCount("nftban", setName)
		if err != nil {
			continue // Port allow sets may not exist on older schemas
		}
		if count > 0 {
			d.setCounters.SetReconciled(setName, int64(count))
		}
	}

	// Also check botguard sets if they exist
	botguardSets := []string{
		"http_bot_suspect", "http_bot_pending", "http_bot_allow",
		"http_bot_grey", "http_bot_ban", "http_bot_emergency",
	}
	for _, setName := range botguardSets {
		count, err := wrapper.GetSetCount("nftban", setName)
		if err != nil {
			continue // Botguard sets may not exist
		}
		if count > 0 {
			d.setCounters.SetReconciled(setName, int64(count))
		}
	}

	// Force immediate cache file write
	if err := d.setCounters.WriteCacheFile(); err != nil {
		log.Printf("[set_counters] Warning: cache write failed: %v", err)
	}

	globalScale := d.setCounters.GlobalScale()
	log.Printf("[set_counters] Reconciliation complete — global scale: %s, exporter interval: %ds",
		globalScale, int(d.setCounters.RecommendedExporterInterval().Seconds()))
}

// logWatchdogSecGuidance logs a recommended WatchdogSec value based on total set elements.
// Does NOT modify the service file — purely informational.
func (d *Daemon) logWatchdogSecGuidance() {
	if d.setCounters == nil {
		return
	}
	var total int64
	for _, name := range d.setCounters.AllSets() {
		total += d.setCounters.Get(name)
	}

	var recommended string
	switch {
	case total < 50000:
		recommended = "30s"
	case total < 200000:
		recommended = "60s"
	case total < 500000:
		recommended = "120s"
	default:
		recommended = "180s"
	}
	log.Printf("[WATCHDOG] Total set elements: %d — recommended WatchdogSec=%s", total, recommended)
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

