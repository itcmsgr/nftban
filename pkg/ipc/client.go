// =============================================================================
// NFTBan v1.0 - IPC Client Package
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
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
	DefaultTimeout = 30 * time.Second
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
func (c *Client) Sync() (*Response, error) {
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
	params := map[string]any{
		"set_type": setType,
	}
	if len(cidrs) > 0 {
		params["cidrs"] = cidrs
	}
	return c.Call("load_cidrs", params)
}
