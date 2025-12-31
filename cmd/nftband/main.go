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
	"syscall"
	"time"

	"github.com/itcmsgr/nftban/pkg/ddos"
	"github.com/itcmsgr/nftban/pkg/eventbus"
	"github.com/itcmsgr/nftban/pkg/loginmon"
	"github.com/itcmsgr/nftban/pkg/module"
	"github.com/itcmsgr/nftban/pkg/nftbanconf"
	"github.com/itcmsgr/nftban/pkg/portscan"
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
func (d *Daemon) startSocket() error {
	socketPath := getSocketPath()

	// Remove stale socket
	os.Remove(socketPath)

	ln, err := net.Listen("unix", socketPath)
	if err != nil {
		return err
	}
	d.socketLn = ln

	// Set permissions
	os.Chmod(socketPath, 0660)

	// Handle connections
	go d.acceptSocketConnections()

	return nil
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

	// Publish ban event
	d.bus.Publish(eventbus.NewEvent(eventbus.EventBan, "cli").
		WithIP(ip).
		WithMessage("Manual ban via CLI").
		WithSeverity(eventbus.SeverityInfo))

	// TODO: Actually perform the ban via NFT manager

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"ip":     ip,
			"status": "banned",
		},
	}
}

// handleUnbanRequest unbans an IP
func (d *Daemon) handleUnbanRequest(params map[string]any) SocketResponse {
	ip, ok := params["ip"].(string)
	if !ok || ip == "" {
		return SocketResponse{Success: false, Error: "missing ip parameter"}
	}

	// Publish unban event
	d.bus.Publish(eventbus.NewEvent(eventbus.EventUnban, "cli").
		WithIP(ip).
		WithMessage("Manual unban via CLI").
		WithSeverity(eventbus.SeverityInfo))

	// TODO: Actually perform the unban via NFT manager

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"ip":     ip,
			"status": "unbanned",
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
