// =============================================================================
// NFTBan v1.0 - nftband Daemon
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Binary: nftband
// Purpose: Single daemon that runs all nftban modules
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
	"os"
	"os/signal"
	"os/user"
	"strconv"
	"syscall"
	"time"

	"github.com/coreos/go-systemd/v22/activation"
	"github.com/google/nftables"
	"github.com/itcmsgr/nftban/pkg/ddos"
	"github.com/itcmsgr/nftban/pkg/eventbus"
	"github.com/itcmsgr/nftban/pkg/feeds"
	"github.com/itcmsgr/nftban/pkg/loginmon"
	"github.com/itcmsgr/nftban/pkg/module"
	"github.com/itcmsgr/nftban/pkg/nftbackend"
	"github.com/itcmsgr/nftban/pkg/nftbanconf"
	"github.com/itcmsgr/nftban/pkg/persistence"
	"github.com/itcmsgr/nftban/pkg/ports"
	"github.com/itcmsgr/nftban/pkg/portscan"
	"github.com/itcmsgr/nftban/pkg/runtime"
	"github.com/itcmsgr/nftban/pkg/sync"
	"golang.org/x/sys/unix"
)

const (
	Version = "1.0.0"

	// HTTP API
	HTTPAddr = ":8080"
)

// Build-time variables (injected by -ldflags)
var (
	GitCommit = "dev"
	BuildDate = "unknown"
)

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
	ctx       context.Context
	cancel    context.CancelFunc
	socketLn  net.Listener
	httpSrv   *http.Server
}

func main() {
	// Handle version/help
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "--version", "-v":
			fmt.Printf("nftband v%s (git %s, build %s)\n", Version, GitCommit, BuildDate)
			return
		case "--help", "-h":
			printHelp()
			return
		}
	}

	// Create daemon
	d := &Daemon{
		bus:      eventbus.New(),
		registry: module.NewRegistry(),
		backend:  nftbackend.New(), // AUTHORITATIVE nft backend
	}

	// Run
	if err := d.Run(); err != nil {
		log.Fatalf("Daemon error: %v", err)
	}
}

func printHelp() {
	fmt.Println("nftband - NFTBan Daemon")
	fmt.Println()
	fmt.Println("Usage:")
	fmt.Println("  nftband              Run the daemon")
	fmt.Println("  nftband --version    Show version")
	fmt.Println("  nftband --help       Show this help")
	fmt.Println()
	fmt.Println("The daemon:")
	fmt.Println("  - Runs all nftban modules as goroutines")
	fmt.Println("  - Provides HTTP API on", HTTPAddr)
	fmt.Println("  - Provides Unix socket at", getSocketPath())
	fmt.Println("  - Handles graceful shutdown on SIGTERM/SIGINT")
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

	// Start all modules
	log.Println("Starting modules...")
	if err := d.registry.StartAll(d.ctx); err != nil {
		return fmt.Errorf("failed to start modules: %w", err)
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

	// Handle request
	resp := d.handleSocketRequest(req)
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
	case "ping":
		return SocketResponse{Success: true, Data: "pong"}
	default:
		return SocketResponse{
			Success: false,
			Error:   "unknown method: " + req.Method,
		}
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
			"whitelist_ipv4_added":   result.WhitelistIPv4.Added,
			"whitelist_ipv4_removed": result.WhitelistIPv4.Removed,
			"whitelist_ipv6_added":   result.WhitelistIPv6.Added,
			"whitelist_ipv6_removed": result.WhitelistIPv6.Removed,
			"blacklist_ipv4_added":   result.BlacklistIPv4.Added,
			"blacklist_ipv4_removed": result.BlacklistIPv4.Removed,
			"blacklist_ipv6_added":   result.BlacklistIPv6.Added,
			"blacklist_ipv6_removed": result.BlacklistIPv6.Removed,
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
