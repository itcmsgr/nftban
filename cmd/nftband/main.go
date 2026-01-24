// =============================================================================
// NFTBan v1.0 - nftband Daemon
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Binary: nftband
// Purpose: Single daemon that runs all nftban modules
//
// meta:name="nftband"
// meta:type="binary"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:homepage="https://nftban.com"
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
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	_ "net/http/pprof" // Enable pprof endpoints
	"os"
	"os/signal"
	"os/user"
	"path/filepath"
	goruntime "runtime"
	"runtime/pprof"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/coreos/go-systemd/v22/activation"
	"github.com/google/nftables"
	"github.com/itcmsgr/nftban/pkg/banlog"
	"github.com/itcmsgr/nftban/pkg/ddos"
	"github.com/itcmsgr/nftban/pkg/eventbus"
	"github.com/itcmsgr/nftban/pkg/metrics"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/itcmsgr/nftban/pkg/feeds"
	"github.com/itcmsgr/nftban/pkg/loginmon"
	"github.com/itcmsgr/nftban/pkg/module"
	"github.com/itcmsgr/nftban/pkg/nftbackend"
	"github.com/itcmsgr/nftban/pkg/nftbanconf"
	"github.com/itcmsgr/nftban/pkg/persistence"
	"github.com/itcmsgr/nftban/pkg/ports"
	"github.com/itcmsgr/nftban/pkg/portscan"
	"github.com/itcmsgr/nftban/pkg/runtime"
	"github.com/itcmsgr/nftban/pkg/safety"
	"github.com/itcmsgr/nftban/pkg/stats"
	"github.com/itcmsgr/nftban/pkg/sync"
	"github.com/itcmsgr/nftban/pkg/watchdog"
	"golang.org/x/sys/unix"
)

const (
	Version = "1.0.0"

	// HTTP API
	HTTPAddr = ":8080"

	// Profiling (pprof) - localhost only for security
	PprofAddr = "127.0.0.1:6060"
)

// Build-time variables (injected by -ldflags)
var (
	GitCommit = "dev"
	BuildDate = "unknown"
)

// Runtime flags
var profileEnabled = false

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
}

func main() {
	// Handle version/help and parse flags
	for _, arg := range os.Args[1:] {
		switch arg {
		case "--version", "-v":
			fmt.Printf("nftband v%s (git %s, build %s)\n", Version, GitCommit, BuildDate)
			return
		case "--help", "-h":
			printHelp()
			return
		case "--profile":
			profileEnabled = true
		}
	}

	// Initialize safety limits (dynamic based on server profile: CPU, RAM, panel)
	// This sets GOMEMLIMIT to prevent unbounded memory growth
	safetyLimits := safety.FromEnv()
	safety.InitMemory(safetyLimits)
	log.Printf("Safety: %s", safety.GetProfileDescription())

	// Create daemon
	d := &Daemon{
		bus:      eventbus.New(),
		registry: module.NewRegistry(),
		backend:  nftbackend.New(), // AUTHORITATIVE nft backend
		stats:    stats.NewCollector(stats.DefaultConfig()),
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
	fmt.Println("  - Provides HTTP API on", HTTPAddr)
	fmt.Println("  - Provides Unix socket at", getSocketPath())
	fmt.Println("  - Handles graceful shutdown on SIGTERM/SIGINT")
	fmt.Println()
	fmt.Println("Profiling (--profile):")
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
	log.Printf("nftband v%s starting...", Version)

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
	defer os.Remove(getPidFile())

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
			// Log to bans.log for stats tracking
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
			_ = banlog.LogBan(e.IP, banSource, "UNK")
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
		kernelBytes = append(kernelBytes, byte(b))
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

	log.Printf("nftband ready - HTTP %s, Socket %s", HTTPAddr, getSocketPath())

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
		cred, credErr = unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED)
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

		go d.handleSocketConnection(conn)
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

	// Set timeout
	conn.SetDeadline(time.Now().Add(30 * time.Second))

	// SECURITY: Validate peer credentials via SO_PEERCRED
	// Defense-in-depth: socket permissions (0660 root:nftban) + credential check
	uid, gid, err := validatePeerCredentials(conn)
	if err != nil {
		log.Printf("Socket auth rejected: %v", err)
		d.writeSocketResponse(conn, SocketResponse{
			Success: false,
			Error:   "unauthorized: not root or member of nftban group",
		})
		return
	}
	_ = uid // Available for audit logging if needed
	_ = gid

	// Read request
	decoder := json.NewDecoder(conn)
	var req SocketRequest
	if err := decoder.Decode(&req); err != nil {
		d.writeSocketResponse(conn, SocketResponse{
			Success: false,
			Error:   "invalid request: " + err.Error(),
		})
		return
	}

	// Handle request with timing
	start := time.Now()
	resp := d.handleSocketRequest(req)
	latency := time.Since(start).Nanoseconds()
	d.stats.RecordIPCRequest(latency, resp.Success)
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

// handleStatusRequest returns daemon status
func (d *Daemon) handleStatusRequest() SocketResponse {
	stats := d.bus.Stats()
	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"version":       Version,
			"uptime":        "TODO",
			"modules":       len(d.registry.All()),
			"events_total":  stats.Published,
			"subscriptions": stats.Subscriptions,
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
	_ = banlog.LogBan(ip, banSource, "UNK") // Country lookup done separately

	// Publish ban event
	d.bus.Publish(eventbus.NewEvent(eventbus.EventBan, source).
		WithIP(ip).
		WithMessage(fmt.Sprintf("Banned: %s", reason)).
		WithSeverity(eventbus.SeverityInfo))

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"ip":      ip,
			"set":     result.Set,
			"status":  "banned",
			"message": result.Message,
		},
	}
}

// handleUnbanRequest unbans an IP
func (d *Daemon) handleUnbanRequest(params map[string]any) SocketResponse {
	ip, ok := params["ip"].(string)
	if !ok || ip == "" {
		return SocketResponse{Success: false, Error: "missing ip parameter"}
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

	err := d.backend.ApplyRuleset(d.ctx, nftbackend.ApplyRulesetRequest{
		FilePath: filePath,
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
		json.NewEncoder(w).Encode(map[string]any{
			"status":  "ok",
			"version": Version,
		})
	})

	// Prometheus metrics endpoint
	mux.Handle("/metrics", promhttp.Handler())

	// Status endpoint
	mux.HandleFunc("/api/v1/status", func(w http.ResponseWriter, r *http.Request) {
		stats := d.bus.Stats()
		json.NewEncoder(w).Encode(map[string]any{
			"success": true,
			"data": map[string]any{
				"version":      Version,
				"modules":      len(d.registry.All()),
				"events_total": stats.Published,
			},
		})
	})

	// Modules endpoint
	mux.HandleFunc("/api/v1/modules", func(w http.ResponseWriter, r *http.Request) {
		statuses := d.registry.StatusAll()
		json.NewEncoder(w).Encode(map[string]any{
			"success": true,
			"data":    statuses,
		})
	})

	// TODO: Mount existing pkg/api handlers here
	// mux.Handle("/api/v1/", api.NewRouter())

	d.httpSrv = &http.Server{
		Addr:    HTTPAddr,
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
func (d *Daemon) startPprof() {
	// pprof handlers are already registered by the blank import
	// We just need to start a server on the pprof port
	go func() {
		log.Printf("pprof server listening on http://%s/debug/pprof/", PprofAddr)
		if err := http.ListenAndServe(PprofAddr, nil); err != nil {
			log.Printf("pprof server error: %v", err)
		}
	}()
}

// waitForShutdown blocks until SIGTERM/SIGINT
func (d *Daemon) waitForShutdown() {
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)

	sig := <-sigCh
	log.Printf("Received %v, shutting down...", sig)

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

	// Close event bus
	d.bus.Close()

	// Cancel context
	d.cancel()

	log.Println("nftband stopped")
}

// =============================================================================
// HIGH-LEVEL IPC HANDLERS (for CLI delegation)
// =============================================================================

// handleSyncRequest performs a full differential sync of whitelists/blacklists
func (d *Daemon) handleSyncRequest(params map[string]any) SocketResponse {
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

	// Initialize nftables manager
	nft, err := sync.NewNFTManager()
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to create nftables manager: " + err.Error()}
	}
	defer nft.Close()

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
		tcpSetV4, err := nft.GetOrCreatePortSet(tableIPv4, "tcp_ports")
		if err != nil {
			return SocketResponse{Success: false, Error: "failed to create IPv4 tcp_ports set: " + err.Error()}
		}

		tcpSetV6, err := nft.GetOrCreatePortSet(tableIPv6, "tcp_ports")
		if err != nil {
			return SocketResponse{Success: false, Error: "failed to create IPv6 tcp_ports set: " + err.Error()}
		}

		udpSetV4, err := nft.GetOrCreatePortSet(tableIPv4, "udp_ports")
		if err != nil {
			return SocketResponse{Success: false, Error: "failed to create IPv4 udp_ports set: " + err.Error()}
		}

		udpSetV6, err := nft.GetOrCreatePortSet(tableIPv6, "udp_ports")
		if err != nil {
			return SocketResponse{Success: false, Error: "failed to create IPv6 udp_ports set: " + err.Error()}
		}

		// Load ports into sets
		if len(allPorts.TCPPorts) > 0 {
			if err := nft.AddPortElements(tcpSetV4, allPorts.TCPPorts); err != nil {
				return SocketResponse{Success: false, Error: "failed to add IPv4 TCP ports: " + err.Error()}
			}
			if err := nft.AddPortElements(tcpSetV6, allPorts.TCPPorts); err != nil {
				return SocketResponse{Success: false, Error: "failed to add IPv6 TCP ports: " + err.Error()}
			}
		}

		if len(allPorts.UDPPorts) > 0 {
			if err := nft.AddPortElements(udpSetV4, allPorts.UDPPorts); err != nil {
				return SocketResponse{Success: false, Error: "failed to add IPv4 UDP ports: " + err.Error()}
			}
			if err := nft.AddPortElements(udpSetV6, allPorts.UDPPorts); err != nil {
				return SocketResponse{Success: false, Error: "failed to add IPv6 UDP ports: " + err.Error()}
			}
		}
	}

	// Get snapshots from runtime state
	whitelistIPv4, whitelistIPv6 := state.GetWhitelistSnapshot()
	blacklistIPv4, blacklistIPv6 := state.GetBlacklistSnapshot()

	// Perform full sync
	result, err := sync.FullSync(
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

	return SocketResponse{
		Success: result.Success,
		Data: map[string]any{
			"whitelist_ipv4_added":   result.WhitelistIPv4.IPsAdded,
			"whitelist_ipv4_removed": result.WhitelistIPv4.IPsRemoved,
			"whitelist_ipv6_added":   result.WhitelistIPv6.IPsAdded,
			"whitelist_ipv6_removed": result.WhitelistIPv6.IPsRemoved,
			"blacklist_ipv4_added":   result.BlacklistIPv4.IPsAdded,
			"blacklist_ipv4_removed": result.BlacklistIPv4.IPsRemoved,
			"blacklist_ipv6_added":   result.BlacklistIPv6.IPsAdded,
			"blacklist_ipv6_removed": result.BlacklistIPv6.IPsRemoved,
			"tcp_ports":              len(allPorts.TCPPorts),
			"udp_ports":              len(allPorts.UDPPorts),
		},
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
				"message":   "no port rules configured",
				"tcp_ports": 0,
				"udp_ports": 0,
			},
		}
	}

	// Initialize nftables manager
	nft, err := sync.NewNFTManager()
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to create nftables manager: " + err.Error()}
	}
	defer nft.Close()

	// Create IPv4 table and sets
	ipv4Table, err := nft.GetOrCreateTable(nftables.TableFamilyIPv4)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to get IPv4 table: " + err.Error()}
	}

	tcpSetV4, err := nft.GetOrCreatePortSet(ipv4Table, "tcp_ports")
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to create IPv4 tcp_ports set: " + err.Error()}
	}

	udpSetV4, err := nft.GetOrCreatePortSet(ipv4Table, "udp_ports")
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to create IPv4 udp_ports set: " + err.Error()}
	}

	// Create IPv6 table and sets
	ipv6Table, err := nft.GetOrCreateTable(nftables.TableFamilyIPv6)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to get IPv6 table: " + err.Error()}
	}

	tcpSetV6, err := nft.GetOrCreatePortSet(ipv6Table, "tcp_ports")
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to create IPv6 tcp_ports set: " + err.Error()}
	}

	udpSetV6, err := nft.GetOrCreatePortSet(ipv6Table, "udp_ports")
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to create IPv6 udp_ports set: " + err.Error()}
	}

	// Load ports into sets
	if len(config.TCPPorts) > 0 {
		if err := nft.AddPortElements(tcpSetV4, config.TCPPorts); err != nil {
			return SocketResponse{Success: false, Error: "failed to add IPv4 TCP ports: " + err.Error()}
		}
		if err := nft.AddPortElements(tcpSetV6, config.TCPPorts); err != nil {
			return SocketResponse{Success: false, Error: "failed to add IPv6 TCP ports: " + err.Error()}
		}
	}

	if len(config.UDPPorts) > 0 {
		if err := nft.AddPortElements(udpSetV4, config.UDPPorts); err != nil {
			return SocketResponse{Success: false, Error: "failed to add IPv4 UDP ports: " + err.Error()}
		}
		if err := nft.AddPortElements(udpSetV6, config.UDPPorts); err != nil {
			return SocketResponse{Success: false, Error: "failed to add IPv6 UDP ports: " + err.Error()}
		}
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"tcp_ports": len(config.TCPPorts),
			"udp_ports": len(config.UDPPorts),
			"total":     len(config.AllRules),
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

			// Combine IPs and CIDRs
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

	// Parse CIDRs from params
	var ipv4CIDRs, ipv6CIDRs []string
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
	// Initialize nftables manager
	nft, err := sync.NewNFTManager()
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to create nftables manager: " + err.Error()}
	}
	defer nft.Close()

	// Determine set names
	var setNameV4, setNameV6 string
	if setType == "whitelist" {
		setNameV4 = "whitelist_ipv4"
		setNameV6 = "whitelist_ipv6"
	} else {
		setNameV4 = "blacklist_ipv4"
		setNameV6 = "blacklist_ipv6"
	}

	var ipv4Stats, ipv6Stats *sync.MergeStats

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
	snapshot.Daemon.Version = Version

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
	os.MkdirAll(filepath.Dir(logPath), 0750)

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
