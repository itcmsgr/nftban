// =============================================================================
// NFTBan v1.0 - nftband Daemon - Unix socket server and peer credential validation
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftband"
// meta:type="cmd"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Unix socket server and peer credential validation"
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
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/user"
	"strconv"
	"sync/atomic"
	"time"

	"github.com/coreos/go-systemd/v22/activation"
	"github.com/itcmsgr/nftban/internal/constants"
	"github.com/itcmsgr/nftban/internal/metrics"
	"golang.org/x/sys/unix"
)

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

// startSocket starts the Unix socket listener
// Supports two modes:
//  1. Socket activation (systemd): uses pre-created socket from nftband.socket
//  2. Manual start: creates socket directly (for testing/development)
func (d *Daemon) startSocket() error {
	socketPath := getSocketPath()

	// Accept-loop serving acknowledgment (closed by acceptSocketConnections when
	// the loop reaches its serving state). Lets us mark ipc_accepting only when the
	// loop is genuinely serving, not merely because the goroutine was launched.
	d.acceptReady = make(chan struct{})

	// Check for systemd socket activation first
	listeners, err := activation.Listeners()
	if err != nil {
		log.Printf("Warning: failed to check systemd activation: %v", err)
	}

	if len(listeners) > 0 && listeners[0] != nil {
		// Systemd socket activation - use the pre-configured socket
		// Socket permissions (0660 root:nftban) are set by nftband.socket unit
		d.socketLn = listeners[0]
		d.lifecycle.setIPCBound(true)
		log.Printf("Using systemd socket activation (socket from nftband.socket)")
		return d.launchAcceptAndWait()
	}
	// v1.147: if activation reported listeners but the fd was mediated to nil
	// under MAC confinement, fall through to manual socket creation rather than
	// storing a nil listener (which would nil-panic on the deferred close).
	if len(listeners) > 0 {
		log.Printf("Warning: systemd reported %d socket(s) but listener[0] is nil (MAC confinement?); creating socket manually", len(listeners))
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
	d.lifecycle.setIPCBound(true)

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
	return d.launchAcceptAndWait()
}

// acceptReadyTimeout bounds how long startSocket waits for the accept loop to reach
// its serving state before treating the socket as not-serving. It is a package var
// so tests can shorten it; production keeps the daemon-startup wait.
var acceptReadyTimeout = constants.DaemonStartupWait

// launchAcceptAndWait starts the accept loop and blocks (bounded) until the loop
// signals it reached its serving state, then marks ipc_accepting. A socket that is
// bound but never reaches serving state is a real defect: return a clear error
// rather than an unbounded wait or a false "accepting".
func (d *Daemon) launchAcceptAndWait() error {
	go d.acceptSocketConnections()
	select {
	case <-d.acceptReady:
		d.lifecycle.setIPCAccepting(true)
		return nil
	case <-time.After(acceptReadyTimeout):
		return fmt.Errorf("IPC accept loop did not reach serving state within %s", acceptReadyTimeout)
	}
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
	// Signal that the accept loop reached its serving state (once). startSocket
	// blocks on this before marking ipc_accepting, so a bound-but-not-serving
	// socket is never reported as accepting.
	if d.acceptReady != nil {
		d.acceptReadyOnce.Do(func() { close(d.acceptReady) })
	}
	for {
		conn, err := d.socketLn.Accept()
		acceptTime := time.Now()
		if err != nil {
			// v1.19.21 FIX: Suppress shutdown errors
			// Check for closed listener (graceful shutdown) or context cancellation
			if errors.Is(err, net.ErrClosed) {
				return // graceful shutdown - listener closed
			}
			select {
			case <-d.ctx.Done():
				return // graceful shutdown - context cancelled
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
