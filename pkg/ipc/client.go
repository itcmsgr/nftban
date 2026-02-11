// =============================================================================
// NFTBan - IPC Client Package
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="ipc_client"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-09-01"
// meta:description="IPC client for communicating with nftband daemon"
// meta:input="Unix socket requests"
// meta:output="JSON responses"
// meta:depends="net,encoding/json,time"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network="unix:/run/nftban/nftband.sock"
// meta:inventory.privileges=""
//
// This package provides IPC client for communicating with nftband daemon.
// All Go code that needs to perform nftables WRITE operations must use this
// client instead of calling nft directly.
//
// See: ARCHITECTURE-NFT-POLICY.md
// =============================================================================

package ipc

import (
	"encoding/json"
	"fmt"
	"net"
	"time"
)

const (
	// DefaultSocketPath is the default daemon socket location
	DefaultSocketPath = "/run/nftban/nftband.sock"

	// DefaultTimeout is the default request timeout
	// Increased from 30s to 90s to handle larger operations (feeds loading, CIDR merging, geoban)
	DefaultTimeout = 90 * time.Second
)

// Client provides IPC communication with nftband daemon
type Client struct {
	socketPath string
	timeout    time.Duration
}

// NewClient creates a new IPC client with default settings
func NewClient() *Client {
	return &Client{
		socketPath: DefaultSocketPath,
		timeout:    DefaultTimeout,
	}
}

// NewClientWithSocket creates a client with custom socket path
func NewClientWithSocket(socketPath string) *Client {
	return &Client{
		socketPath: socketPath,
		timeout:    DefaultTimeout,
	}
}

// SetTimeout sets the request timeout
func (c *Client) SetTimeout(d time.Duration) {
	c.timeout = d
}

// Request represents a request to the daemon
type Request struct {
	Method string         `json:"method"`
	Params map[string]any `json:"params,omitempty"`
}

// Response represents a response from the daemon
type Response struct {
	Success bool   `json:"success"`
	Data    any    `json:"data,omitempty"`
	Error   string `json:"error,omitempty"`
}

// Call sends a request to the daemon and returns the response
func (c *Client) Call(method string, params map[string]any) (*Response, error) {
	conn, err := net.DialTimeout("unix", c.socketPath, c.timeout)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to daemon at %s: %w", c.socketPath, err)
	}
	defer conn.Close()

	// Set deadline
	conn.SetDeadline(time.Now().Add(c.timeout))

	// Send request
	req := Request{
		Method: method,
		Params: params,
	}
	if err := json.NewEncoder(conn).Encode(req); err != nil {
		return nil, fmt.Errorf("failed to send request: %w", err)
	}

	// Read response
	var resp Response
	if err := json.NewDecoder(conn).Decode(&resp); err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}

	return &resp, nil
}

// Ping checks if the daemon is alive
func (c *Client) Ping() error {
	resp, err := c.Call("ping", nil)
	if err != nil {
		return err
	}
	if !resp.Success {
		return fmt.Errorf("ping failed: %s", resp.Error)
	}
	return nil
}

// Ban bans an IP address
func (c *Client) Ban(ip string, timeout int, reason, source string) (*Response, error) {
	// Client-side validation
	if ip == "" {
		return nil, fmt.Errorf("ip parameter is required")
	}

	params := map[string]any{
		"ip": ip,
	}
	if timeout > 0 {
		params["timeout"] = timeout
	}
	if reason != "" {
		params["reason"] = reason
	}
	if source != "" {
		params["source"] = source
	}
	return c.Call("ban", params)
}

// Unban unbans an IP address
func (c *Client) Unban(ip string) (*Response, error) {
	return c.Call("unban", map[string]any{"ip": ip})
}

// PersistBan adds an IP to persistent blacklist files
// This is for permanent bans that survive reboots
func (c *Client) PersistBan(ip, reason, source string) (*Response, error) {
	params := map[string]any{
		"ip": ip,
	}
	if reason != "" {
		params["reason"] = reason
	}
	if source != "" {
		params["source"] = source
	}
	return c.Call("persist_ban", params)
}

// UnpersistBan removes an IP from all persistent blacklist files
func (c *Client) UnpersistBan(ip string) (*Response, error) {
	return c.Call("unpersist_ban", map[string]any{"ip": ip})
}

// AddElement adds an element to a set
func (c *Client) AddElement(table, set, element string, timeout int) (*Response, error) {
	params := map[string]any{
		"table":   table,
		"set":     set,
		"element": element,
	}
	if timeout > 0 {
		params["timeout"] = timeout
	}
	return c.Call("add_element", params)
}

// DeleteElement removes an element from a set
func (c *Client) DeleteElement(table, set, element string) (*Response, error) {
	return c.Call("delete_element", map[string]any{
		"table":   table,
		"set":     set,
		"element": element,
	})
}

// FlushSet removes all elements from a set
func (c *Client) FlushSet(table, set string) (*Response, error) {
	return c.Call("flush_set", map[string]any{
		"table": table,
		"set":   set,
	})
}

// ApplyRuleset applies a ruleset from file
func (c *Client) ApplyRuleset(filePath string, checkOnly bool) (*Response, error) {
	return c.Call("apply_ruleset", map[string]any{
		"file":  filePath,
		"check": checkOnly,
	})
}

// Check checks if an IP is banned
func (c *Client) Check(ip string) (*Response, error) {
	return c.Call("check", map[string]any{"ip": ip})
}

// Status gets daemon status
func (c *Client) Status() (*Response, error) {
	return c.Call("status", nil)
}

// Modules gets module statuses
func (c *Client) Modules() (*Response, error) {
	return c.Call("modules", nil)
}

// IsConnected checks if daemon is reachable
func (c *Client) IsConnected() bool {
	return c.Ping() == nil
}

// Sync performs a full differential sync of whitelists/blacklists/ports
// If quick is true, skips feeds and geoban loading (for fast postinst sync)
func (c *Client) Sync(quick bool) (*Response, error) {
	if quick {
		return c.Call("sync", map[string]any{"quick": true})
	}
	return c.Call("sync", nil)
}

// LoadPorts loads ports into nftables port sets
func (c *Client) LoadPorts() (*Response, error) {
	return c.Call("load_ports", nil)
}

// LoadCIDRs loads CIDRs into blacklist or whitelist sets
// setType should be "blacklist" or "whitelist"
// If cidrs is nil/empty, loads from feeds/trust directories
func (c *Client) LoadCIDRs(setType string, cidrs []string) (*Response, error) {
	// Client-side validation
	if setType == "" {
		return nil, fmt.Errorf("set_type parameter is required")
	}

	params := map[string]any{
		"set_type": setType,
	}
	if len(cidrs) > 0 {
		params["cidrs"] = cidrs
	}
	return c.Call("load_cidrs", params)
}

// =============================================================================
// STATS IPC CLIENT METHODS
// =============================================================================

// Stats returns current daemon runtime statistics
func (c *Client) Stats() (*Response, error) {
	return c.Call("stats", nil)
}

// StatsHistory returns historical daily stats for specified number of days
// days: number of days to retrieve (1-30)
func (c *Client) StatsHistory(days int) (*Response, error) {
	if days < 1 {
		days = 1
	}
	if days > 30 {
		days = 30
	}
	return c.Call("stats_history", map[string]any{
		"days": days,
	})
}

// SnapshotProfile triggers a pprof profile capture
// profileType: "heap", "goroutine", or "cpu"
// duration: seconds for CPU profile (only used for cpu type, default 30s)
func (c *Client) SnapshotProfile(profileType string, duration int) (*Response, error) {
	if profileType == "" {
		profileType = "heap"
	}
	params := map[string]any{
		"type": profileType,
	}
	if duration > 0 {
		params["duration"] = duration
	}
	return c.Call("snapshot_profile", params)
}
