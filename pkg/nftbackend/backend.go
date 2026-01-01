// =============================================================================
// NFTBan v1.0 - nftbackend Package
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
//
// ARCHITECTURE: This is the ONLY authorized location for nftables WRITE operations.
// All nft add/delete/flush/insert commands MUST go through this package.
// The nftband daemon is the ONLY consumer of this package.
//
// See: ARCHITECTURE-NFT-POLICY.md
// =============================================================================

package nftbackend

import (
	"context"
	"fmt"
	"net"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// Backend provides serialized access to nftables write operations.
// All operations are thread-safe and atomic where possible.
type Backend struct {
	mu sync.Mutex

	// Configuration
	tableIPv4 string
	tableIPv6 string

	// Statistics
	stats Stats
}

// Stats tracks operation counts
type Stats struct {
	Bans      int64
	Unbans    int64
	Syncs     int64
	Errors    int64
	LastError string
}

// New creates a new nftables backend
func New() *Backend {
	return &Backend{
		tableIPv4: "ip nftban",
		tableIPv6: "ip6 nftban",
	}
}

// BanRequest contains parameters for banning an IP
type BanRequest struct {
	IP      string
	Timeout int           // seconds, 0 = permanent
	Reason  string
	Source  string
}

// BanResult contains the result of a ban operation
type BanResult struct {
	Success bool
	IP      string
	Set     string
	Message string
}

// Ban adds an IP to the appropriate blacklist set
// This is the ONLY authorized ban implementation
func (b *Backend) Ban(ctx context.Context, req BanRequest) (*BanResult, error) {
	b.mu.Lock()
	defer b.mu.Unlock()

	// Validate IP
	ip := net.ParseIP(req.IP)
	if ip == nil {
		// Check if it's a CIDR
		_, _, err := net.ParseCIDR(req.IP)
		if err != nil {
			b.stats.Errors++
			b.stats.LastError = "invalid IP: " + req.IP
			return nil, fmt.Errorf("invalid IP address: %s", req.IP)
		}
	}

	// Determine IPv4 or IPv6
	isIPv6 := ip != nil && ip.To4() == nil
	if ip == nil {
		// CIDR - check if contains ':'
		isIPv6 = strings.Contains(req.IP, ":")
	}

	var table, set string
	if isIPv6 {
		table = b.tableIPv6
		set = "blacklist_ipv6"
	} else {
		table = b.tableIPv4
		set = "blacklist_ipv4"
	}

	// Build nft command
	var element string
	if req.Timeout > 0 {
		element = fmt.Sprintf("{ %s timeout %ds }", req.IP, req.Timeout)
	} else {
		element = fmt.Sprintf("{ %s }", req.IP)
	}

	// Execute: nft add element <table> <set> { <ip> [timeout Xs] }
	cmd := exec.CommandContext(ctx, "nft", "add", "element", table, set, element)
	output, err := cmd.CombinedOutput()
	if err != nil {
		b.stats.Errors++
		b.stats.LastError = fmt.Sprintf("nft error: %v: %s", err, string(output))
		return nil, fmt.Errorf("nft add element failed: %w: %s", err, string(output))
	}

	b.stats.Bans++

	return &BanResult{
		Success: true,
		IP:      req.IP,
		Set:     set,
		Message: fmt.Sprintf("added to %s %s", table, set),
	}, nil
}

// UnbanRequest contains parameters for unbanning an IP
type UnbanRequest struct {
	IP string
}

// UnbanResult contains the result of an unban operation
type UnbanResult struct {
	Success bool
	IP      string
	Set     string
	Message string
}

// Unban removes an IP from the appropriate blacklist set
// This is the ONLY authorized unban implementation
func (b *Backend) Unban(ctx context.Context, req UnbanRequest) (*UnbanResult, error) {
	b.mu.Lock()
	defer b.mu.Unlock()

	// Validate IP
	ip := net.ParseIP(req.IP)
	if ip == nil {
		_, _, err := net.ParseCIDR(req.IP)
		if err != nil {
			b.stats.Errors++
			b.stats.LastError = "invalid IP: " + req.IP
			return nil, fmt.Errorf("invalid IP address: %s", req.IP)
		}
	}

	// Determine IPv4 or IPv6
	isIPv6 := ip != nil && ip.To4() == nil
	if ip == nil {
		isIPv6 = strings.Contains(req.IP, ":")
	}

	var table, set string
	if isIPv6 {
		table = b.tableIPv6
		set = "blacklist_ipv6"
	} else {
		table = b.tableIPv4
		set = "blacklist_ipv4"
	}

	// Execute: nft delete element <table> <set> { <ip> }
	element := fmt.Sprintf("{ %s }", req.IP)
	cmd := exec.CommandContext(ctx, "nft", "delete", "element", table, set, element)
	output, err := cmd.CombinedOutput()
	if err != nil {
		// Check if IP wasn't in set (not a real error)
		if strings.Contains(string(output), "No such file or directory") ||
			strings.Contains(string(output), "does not exist") {
			return &UnbanResult{
				Success: true,
				IP:      req.IP,
				Set:     set,
				Message: "IP was not in blocklist",
			}, nil
		}
		b.stats.Errors++
		b.stats.LastError = fmt.Sprintf("nft error: %v: %s", err, string(output))
		return nil, fmt.Errorf("nft delete element failed: %w: %s", err, string(output))
	}

	b.stats.Unbans++

	return &UnbanResult{
		Success: true,
		IP:      req.IP,
		Set:     set,
		Message: fmt.Sprintf("removed from %s %s", table, set),
	}, nil
}

// AddElementRequest for generic set element operations
type AddElementRequest struct {
	Table   string // e.g., "ip nftban", "ip6 nftban", "inet nftban"
	Set     string // e.g., "whitelist_ipv4", "tcp_ports"
	Element string // e.g., "1.2.3.4", "8080"
	Timeout int    // seconds, 0 = permanent
}

// AddElement adds an element to any set
// This is the ONLY authorized add element implementation
func (b *Backend) AddElement(ctx context.Context, req AddElementRequest) error {
	b.mu.Lock()
	defer b.mu.Unlock()

	var element string
	if req.Timeout > 0 {
		element = fmt.Sprintf("{ %s timeout %ds }", req.Element, req.Timeout)
	} else {
		element = fmt.Sprintf("{ %s }", req.Element)
	}

	cmd := exec.CommandContext(ctx, "nft", "add", "element", req.Table, req.Set, element)
	output, err := cmd.CombinedOutput()
	if err != nil {
		b.stats.Errors++
		b.stats.LastError = fmt.Sprintf("add element: %v: %s", err, string(output))
		return fmt.Errorf("nft add element failed: %w: %s", err, string(output))
	}

	return nil
}

// DeleteElementRequest for removing set elements
type DeleteElementRequest struct {
	Table   string
	Set     string
	Element string
}

// DeleteElement removes an element from any set
// This is the ONLY authorized delete element implementation
func (b *Backend) DeleteElement(ctx context.Context, req DeleteElementRequest) error {
	b.mu.Lock()
	defer b.mu.Unlock()

	element := fmt.Sprintf("{ %s }", req.Element)
	cmd := exec.CommandContext(ctx, "nft", "delete", "element", req.Table, req.Set, element)
	output, err := cmd.CombinedOutput()
	if err != nil {
		// Ignore "not found" errors
		if !strings.Contains(string(output), "No such file or directory") &&
			!strings.Contains(string(output), "does not exist") {
			b.stats.Errors++
			b.stats.LastError = fmt.Sprintf("delete element: %v: %s", err, string(output))
			return fmt.Errorf("nft delete element failed: %w: %s", err, string(output))
		}
	}

	return nil
}

// FlushSetRequest for flushing sets
type FlushSetRequest struct {
	Table string
	Set   string
}

// FlushSet flushes all elements from a set
// This is the ONLY authorized flush set implementation
func (b *Backend) FlushSet(ctx context.Context, req FlushSetRequest) error {
	b.mu.Lock()
	defer b.mu.Unlock()

	cmd := exec.CommandContext(ctx, "nft", "flush", "set", req.Table, req.Set)
	output, err := cmd.CombinedOutput()
	if err != nil {
		b.stats.Errors++
		b.stats.LastError = fmt.Sprintf("flush set: %v: %s", err, string(output))
		return fmt.Errorf("nft flush set failed: %w: %s", err, string(output))
	}

	return nil
}

// ApplyRulesetRequest for applying complete rulesets
type ApplyRulesetRequest struct {
	FilePath string // path to .nft file
	Check    bool   // if true, validate only (nft -c)
}

// ApplyRuleset applies a ruleset from a file
// This is the ONLY authorized apply ruleset implementation
func (b *Backend) ApplyRuleset(ctx context.Context, req ApplyRulesetRequest) error {
	b.mu.Lock()
	defer b.mu.Unlock()

	var cmd *exec.Cmd
	if req.Check {
		cmd = exec.CommandContext(ctx, "nft", "-c", "-f", req.FilePath)
	} else {
		cmd = exec.CommandContext(ctx, "nft", "-f", req.FilePath)
	}

	output, err := cmd.CombinedOutput()
	if err != nil {
		b.stats.Errors++
		b.stats.LastError = fmt.Sprintf("apply ruleset: %v: %s", err, string(output))
		return fmt.Errorf("nft apply ruleset failed: %w: %s", err, string(output))
	}

	b.stats.Syncs++
	return nil
}

// GetStats returns current statistics
func (b *Backend) GetStats() Stats {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.stats
}

// CheckIP checks if an IP is in a specific set (read operation)
func (b *Backend) CheckIP(ctx context.Context, ip string) (bool, string, error) {
	// This is a READ operation - allowed but should eventually go through daemon too
	parsed := net.ParseIP(ip)
	if parsed == nil {
		return false, "", fmt.Errorf("invalid IP: %s", ip)
	}

	isIPv6 := parsed.To4() == nil

	var table, set string
	if isIPv6 {
		table = b.tableIPv6
		set = "blacklist_ipv6"
	} else {
		table = b.tableIPv4
		set = "blacklist_ipv4"
	}

	// Use nft get element (if available) or list and grep
	cmd := exec.CommandContext(ctx, "nft", "list", "set", table, set)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return false, "", fmt.Errorf("nft list set failed: %w", err)
	}

	if strings.Contains(string(output), ip) {
		return true, set, nil
	}

	return false, "", nil
}

// HealthCheck verifies nftables is operational
func (b *Backend) HealthCheck(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "nft", "list", "tables")
	_, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("nftables not operational: %w", err)
	}
	return nil
}
