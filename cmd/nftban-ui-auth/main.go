// =============================================================================
// NFTBan UI Auth Daemon - PAM Authentication Service
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftban-ui-auth"
// meta:type="cmd"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Socket-activated PAM authentication daemon for NFTBan Web GUI"
//
// meta:inventory.files=""
// meta:inventory.binaries="nftban-ui-auth"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units="nftban-ui-auth.socket,nftban-ui-auth.service"
// meta:inventory.network="unix:/run/nftban-ui/auth.sock"
// meta:inventory.privileges="root"
// =============================================================================

package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	pam "github.com/msteinert/pam/v2"

	"github.com/itcmsgr/nftban/internal/authproto"
	"github.com/itcmsgr/nftban/pkg/auth"
	"github.com/itcmsgr/nftban/pkg/system"
	"github.com/itcmsgr/nftban/pkg/version"
)

const (
	SocketPath = "/run/nftban-ui/auth.sock"
)

// Build-time variables (injected by -ldflags)
var (
	GitCommit = "dev"
	BuildDate = "unknown"
)

// Use shared types from authproto package
type AuthRequest = authproto.AuthRequest
type AuthResponse = authproto.AuthResponse

func main() {
	// Check for version flag
	if len(os.Args) > 1 && (os.Args[1] == "--version" || os.Args[1] == "-v") {
		fmt.Printf("nftban-ui-auth v%s (git %s, build %s)\n", version.Version, GitCommit, BuildDate)
		os.Exit(0)
	}

	// Must run as root for PAM authentication
	if os.Geteuid() != 0 {
		fmt.Fprintln(os.Stderr, "[AUTH] FATAL: Must run as root for PAM authentication")
		os.Exit(1)
	}

	fmt.Fprintf(os.Stderr, "[AUTH] NFTBan UI Auth Daemon v%s starting\n", version.Version)

	// Create socket directory if needed
	if err := os.MkdirAll("/run/nftban-ui", 0750); err != nil {
		fmt.Fprintf(os.Stderr, "[AUTH] Failed to create socket directory: %v\n", err)
		os.Exit(1)
	}

	// Clean any stale socket
	_ = os.Remove(SocketPath)

	// Create Unix socket listener
	ln, err := net.Listen("unix", SocketPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[AUTH] Failed to create socket: %v\n", err)
		os.Exit(1)
	}
	defer ln.Close()

	// Set socket permissions (root:nftban 0770)
	if err := os.Chmod(SocketPath, 0770); err != nil {
		fmt.Fprintf(os.Stderr, "[AUTH] Warning: Failed to set socket permissions: %v\n", err)
	}

	// Set socket group ownership to nftban
	if err := setSocketOwnership(SocketPath); err != nil {
		fmt.Fprintf(os.Stderr, "[AUTH] Warning: Failed to set socket ownership: %v\n", err)
	}

	fmt.Fprintf(os.Stderr, "[AUTH] Listening on %s\n", SocketPath)

	// Handle shutdown gracefully
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		<-sigChan
		fmt.Fprintln(os.Stderr, "[AUTH] Shutting down...")
		ln.Close()
		os.Exit(0)
	}()

	// Accept connections
	for {
		_ = ln.(*net.UnixListener).SetDeadline(time.Now().Add(5 * time.Minute))
		conn, err := ln.Accept()
		if err != nil {
			if strings.Contains(err.Error(), "use of closed network connection") {
				break
			}
			// Timeout or transient error, continue
			continue
		}

		go handleConnection(conn)
	}
}

func handleConnection(conn net.Conn) {
	defer conn.Close()

	// Set per-connection deadline
	_ = conn.SetDeadline(time.Now().Add(10 * time.Second))

	// Read request
	scanner := bufio.NewScanner(conn)
	if !scanner.Scan() {
		sendError(conn, "Failed to read request")
		return
	}

	// Parse request
	var req AuthRequest
	if err := json.Unmarshal(scanner.Bytes(), &req); err != nil {
		fmt.Fprintf(os.Stderr, "[AUTH] Invalid JSON request: %v\n", err)
		sendError(conn, "Invalid JSON request")
		return
	}

	username := strings.TrimSpace(req.Username)
	password := req.Password

	// Validate username using shared validation
	if !auth.ValidUsernameDefault(username) {
		fmt.Fprintf(os.Stderr, "[AUTH] Invalid username format: %s\n", username)
		sendError(conn, "Invalid username")
		return
	}

	// Validate password not empty
	if password == "" {
		fmt.Fprintf(os.Stderr, "[AUTH] Empty password for user: %s\n", username)
		sendError(conn, "Password required")
		return
	}

	// Block root login
	if username == "root" {
		fmt.Fprintln(os.Stderr, "[AUTH] BLOCKED: Root login attempt")
		sendError(conn, "Root login is disabled")
		return
	}

	// Authenticate via PAM (direct library call, no su)
	if pamAuthenticate(username, password) {
		fmt.Fprintf(os.Stderr, "[AUTH] SUCCESS: User %s authenticated\n", username)
		sendSuccess(conn, "Authentication successful")
	} else {
		fmt.Fprintf(os.Stderr, "[AUTH] FAILED: User %s authentication failed\n", username)
		sendError(conn, "Authentication failed")
	}
}

// pamAuthenticate validates credentials using PAM directly
// This runs as root, so pam_unix/unix_chkpwd works correctly
// Compatible with NoNewPrivileges=true systemd hardening
func pamAuthenticate(username, password string) bool {
	// PAM conversation handler - provides password when prompted
	conv := func(s pam.Style, msg string) (string, error) {
		switch s {
		case pam.PromptEchoOff:
			return password, nil
		case pam.PromptEchoOn, pam.ErrorMsg, pam.TextInfo:
			return "", nil
		default:
			return "", nil
		}
	}

	// Start PAM transaction using "nftban-ui" service
	// This uses /etc/pam.d/nftban-ui configuration
	t, err := pam.StartFunc("nftban-ui", username, conv)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[AUTH] PAM start error for %s: %v\n", username, err)
		return false
	}

	// Authenticate (verify password)
	if err = t.Authenticate(0); err != nil {
		fmt.Fprintf(os.Stderr, "[AUTH] PAM authenticate failed for %s: %v\n", username, err)
		return false
	}

	// Account management (check account validity, expiry, etc.)
	if err = t.AcctMgmt(0); err != nil {
		fmt.Fprintf(os.Stderr, "[AUTH] PAM acct_mgmt failed for %s: %v\n", username, err)
		return false
	}

	return true
}

func sendSuccess(conn net.Conn, message string) {
	resp := AuthResponse{
		Success: true,
		Message: message,
	}
	data, _ := json.Marshal(resp)
	conn.Write(append(data, '\n'))
}

func sendError(conn net.Conn, message string) {
	resp := AuthResponse{
		Success: false,
		Error:   message,
	}
	data, _ := json.Marshal(resp)
	conn.Write(append(data, '\n'))
}

// setSocketOwnership sets socket group to nftban
func setSocketOwnership(path string) error {
	// Get nftban group ID using shared lookup function
	gid, err := system.LookupGroupID("nftban")
	if err != nil {
		return fmt.Errorf("nftban group not found: %w", err)
	}

	// Set ownership (root:nftban)
	return os.Chown(path, 0, gid)
}
