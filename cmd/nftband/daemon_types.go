// =============================================================================
// NFTBan v1.0 - nftband Daemon
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftband"
// meta:type="cmd"
// meta:version="1.41.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Single daemon that runs all nftban modules with HTTP API and Unix socket"
//
// meta:inventory.files="/usr/lib/nftban/bin/nftband"
// meta:inventory.binaries="nftband"
// meta:inventory.env_vars="NFTBAN_CONFIG_DIR, NFTBAN_LOG_DIR"
// meta:inventory.config_files="/etc/nftban/nftban.conf"
// meta:inventory.systemd_units="nftband.service, nftband.socket"
// meta:inventory.network="9580/tcp (HTTP API), /run/nftban/nftband.sock (Unix)"
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
	"net"
	"net/http"
	"os"
	"strconv"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/internal/eventbus"
	"github.com/itcmsgr/nftban/internal/module"
	"github.com/itcmsgr/nftban/internal/nftbackend"
	"github.com/itcmsgr/nftban/internal/nftbanconf"
	"github.com/itcmsgr/nftban/internal/opqueue"
	"github.com/itcmsgr/nftban/internal/stats"
	"github.com/itcmsgr/nftban/internal/watchdog"
	"github.com/itcmsgr/nftban/pkg/version"
)

const (
	// HTTP API default (can be overridden via NFTBAN_API_ADDR config)
	// v1.52.0: Changed from 8080 to 9580 — 8080 conflicts with Apache/DA/cPanel/nginx
	DefaultHTTPAddr = "127.0.0.1:9580"

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
	// v1.145 PR-B2: ssh_ports is the set-driven SSH brute-force rate-limit set
	// (`tcp dport @ssh_ports ct count`). It MUST be daemon-writable so the
	// runtime union reconciliation (maintenance/health) can keep every detected
	// SSH listener port in BOTH tcp_ports_in AND ssh_ports. Without it the IPC
	// rejected ssh_ports ("invalid set") and multi-port hosts left extra SSH
	// ports out of the rate-limit set (and the runtime could not self-heal).
	"ssh_ports": true,
	// HTTP Bot Guard sets (v1.20.0)
	"http_bot_suspect": true, "http_bot_suspect6": true,
	"http_bot_allow": true, "http_bot_allow6": true,
	"http_bot_ban": true, "http_bot_ban6": true,
	"http_bot_grey": true, "http_bot_grey6": true,
	"http_bot_emergency": true, "http_bot_emergency6": true,
	"http_bot_pending": true, "http_bot_pending6": true,
	// Per-IP port access sets (v1.43.0 — BUG-008 fix: flush was silently failing)
	"port_allow_tcp_ipv4": true, "port_allow_tcp_ipv6": true,
	"port_allow_udp_ipv4": true, "port_allow_udp_ipv6": true,
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

// Build-time variables (injected by -ldflags) — PR v1.100.4 H1.1:
// the canonical names live in pkg/version. Aliases are kept here for
// backwards-compatibility with tests that reference cmd-local symbols
// during the transition; they re-export the centralized values so the
// build-time injection path stays single-sourced.
var (
	GitCommit = version.GitCommit
	BuildDate = version.BuildDate
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

	// v1.32.0: In-memory set element counters (huge set management)
	setCounters *stats.SetCounters   // Per-set element counts (O(1) reads)
	bgWg        sync.WaitGroup       // Tracks background goroutines for clean shutdown

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

	// v1.33.0: Daemon start time for uptime calculation
	startedAt time.Time // Set when daemon starts

	// Signal handling for PID cleanup
	sigCh           chan os.Signal // Signal channel for shutdown
	startupComplete bool           // True when initialization is complete
	sigMu           sync.Mutex     // Protects startupComplete

	// v1.41.0: Ban correlation ID tracking (IP → banID for BAN→UNBAN linking)
	banIDMap sync.Map // key: string (IP), value: string (banID)
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
