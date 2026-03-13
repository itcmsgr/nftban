// =============================================================================
// NFTBan v1.8.0 - nftbackend Package (Netlink Implementation)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftbackend"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Serialized nftables write operations via netlink"
// meta:depends="github.com/google/nftables,github.com/itcmsgr/nftban/pkg/sync"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
//
// ARCHITECTURE: This is the ONLY authorized location for nftables WRITE operations.
// All nft add/delete/flush/insert commands MUST go through this package.
// The nftband daemon is the ONLY consumer of this package.
//
// v1.8.0: Refactored from CLI (exec.Command) to netlink (google/nftables) via
// pkg/sync.NFTManager. Single point of truth for all nftables operations.
// Performance: ~50x faster (syscall vs fork+exec per operation).
//
// See: ARCHITECTURE-NFT-POLICY.md
// =============================================================================

package nftbackend

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/google/nftables"
	nftsync "github.com/itcmsgr/nftban/pkg/sync"
)

// Backend provides serialized access to nftables write operations.
// All operations are thread-safe and atomic where possible.
// Uses netlink (google/nftables) for performance instead of CLI.
type Backend struct {
	mu sync.Mutex

	// NFTManager for netlink operations
	nft *nftsync.NFTManager

	// Cached tables and sets for performance
	tableIPv4 *nftables.Table
	tableIPv6 *nftables.Table
	setBlacklistIPv4 *nftables.Set
	setBlacklistIPv6 *nftables.Set
	setWhitelistIPv4 *nftables.Set
	setWhitelistIPv6 *nftables.Set

	// Configuration (string form for legacy compatibility)
	tableIPv4Str string
	tableIPv6Str string

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

// New creates a new nftables backend with netlink connection
func New() *Backend {
	b := &Backend{
		tableIPv4Str: "ip nftban",
		tableIPv6Str: "ip6 nftban",
	}

	// Initialize NFTManager - if this fails, fall back to CLI on first operation
	if nft, err := nftsync.NewNFTManager(); err == nil {
		b.nft = nft
		// Pre-cache tables and sets (best effort, will retry on demand)
		b.initCachedObjects()
	}

	return b
}

// initCachedObjects pre-caches tables and sets for performance
func (b *Backend) initCachedObjects() {
	if b.nft == nil {
		return
	}

	// Get/create IPv4 table and sets
	if table, err := b.nft.GetOrCreateTable(nftables.TableFamilyIPv4); err == nil {
		b.tableIPv4 = table
		if set, err := b.nft.GetOrCreateIntervalSet(table, "blacklist_ipv4", true); err == nil {
			b.setBlacklistIPv4 = set
		}
		if set, err := b.nft.GetOrCreateIntervalSet(table, "whitelist_ipv4", true); err == nil {
			b.setWhitelistIPv4 = set
		}
	}

	// Get/create IPv6 table and sets
	if table, err := b.nft.GetOrCreateTable(nftables.TableFamilyIPv6); err == nil {
		b.tableIPv6 = table
		if set, err := b.nft.GetOrCreateIntervalSet(table, "blacklist_ipv6", false); err == nil {
			b.setBlacklistIPv6 = set
		}
		if set, err := b.nft.GetOrCreateIntervalSet(table, "whitelist_ipv6", false); err == nil {
			b.setWhitelistIPv6 = set
		}
	}

	// Initialize port sets (v1.15.0 - directional architecture)
	// These must exist before any port operations can succeed
	portSets := []string{"tcp_ports_in", "tcp_ports_out", "udp_ports_in", "udp_ports_out"}
	for _, setName := range portSets {
		// IPv4
		if _, err := b.nft.GetOrCreatePortSet(b.tableIPv4, setName); err != nil {
			log.Printf("Warning: failed to create IPv4 port set %s: %v", setName, err)
		}
		// IPv6
		if _, err := b.nft.GetOrCreatePortSet(b.tableIPv6, setName); err != nil {
			log.Printf("Warning: failed to create IPv6 port set %s: %v", setName, err)
		}
	}
	log.Printf("Port sets initialized: %v", portSets)
}

// ensureNetlink ensures NFTManager is initialized
func (b *Backend) ensureNetlink() error {
	if b.nft != nil {
		return nil
	}

	nft, err := nftsync.NewNFTManager()
	if err != nil {
		return fmt.Errorf("failed to create netlink connection: %w", err)
	}
	b.nft = nft
	b.initCachedObjects()
	return nil
}

// getBlacklistSet returns the appropriate blacklist set for an IP
func (b *Backend) getBlacklistSet(ipStr string) (*nftables.Set, bool, error) {
	ip := net.ParseIP(ipStr)
	isIPv6 := false

	if ip != nil {
		isIPv6 = ip.To4() == nil
	} else {
		// CIDR - check if contains ':'
		isIPv6 = strings.Contains(ipStr, ":")
	}

	if isIPv6 {
		if b.setBlacklistIPv6 == nil {
			return nil, true, fmt.Errorf("blacklist_ipv6 set not initialized")
		}
		return b.setBlacklistIPv6, true, nil
	}

	if b.setBlacklistIPv4 == nil {
		return nil, false, fmt.Errorf("blacklist_ipv4 set not initialized")
	}
	return b.setBlacklistIPv4, false, nil
}

// BanRequest contains parameters for banning an IP
type BanRequest struct {
	IP      string
	Timeout int    // seconds, 0 = permanent
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
// Uses netlink for ~50x faster performance vs CLI
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

	// Ensure netlink connection
	if err := b.ensureNetlink(); err != nil {
		b.stats.Errors++
		b.stats.LastError = err.Error()
		return nil, err
	}

	// Get appropriate set
	set, isIPv6, err := b.getBlacklistSet(req.IP)
	if err != nil {
		b.stats.Errors++
		b.stats.LastError = err.Error()
		return nil, err
	}

	// Add IP with optional timeout
	timeout := time.Duration(req.Timeout) * time.Second
	if err := b.nft.AddIPWithTimeout(set, req.IP, timeout); err != nil {
		b.stats.Errors++
		b.stats.LastError = fmt.Sprintf("netlink error: %v", err)
		return nil, fmt.Errorf("nft add element failed: %w", err)
	}

	b.stats.Bans++

	setName := "blacklist_ipv4"
	tableName := b.tableIPv4Str
	if isIPv6 {
		setName = "blacklist_ipv6"
		tableName = b.tableIPv6Str
	}

	return &BanResult{
		Success: true,
		IP:      req.IP,
		Set:     setName,
		Message: fmt.Sprintf("added to %s %s", tableName, setName),
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
// Uses netlink for ~50x faster performance vs CLI
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

	// Ensure netlink connection
	if err := b.ensureNetlink(); err != nil {
		b.stats.Errors++
		b.stats.LastError = err.Error()
		return nil, err
	}

	// Get appropriate set
	set, isIPv6, err := b.getBlacklistSet(req.IP)
	if err != nil {
		b.stats.Errors++
		b.stats.LastError = err.Error()
		return nil, err
	}

	// Delete IP from set
	if err := b.nft.DeleteSetElements(set, []string{req.IP}); err != nil {
		// Check if it's a "not found" error (not a real error)
		if errors.Is(err, os.ErrNotExist) {
			setName := "blacklist_ipv4"
			if isIPv6 {
				setName = "blacklist_ipv6"
			}
			return &UnbanResult{
				Success: true,
				IP:      req.IP,
				Set:     setName,
				Message: "IP was not in blocklist",
			}, nil
		}
		b.stats.Errors++
		b.stats.LastError = fmt.Sprintf("netlink error: %v", err)
		return nil, fmt.Errorf("nft delete element failed: %w", err)
	}

	b.stats.Unbans++

	setName := "blacklist_ipv4"
	tableName := b.tableIPv4Str
	if isIPv6 {
		setName = "blacklist_ipv6"
		tableName = b.tableIPv6Str
	}

	return &UnbanResult{
		Success: true,
		IP:      req.IP,
		Set:     setName,
		Message: fmt.Sprintf("removed from %s %s", tableName, setName),
	}, nil
}

// AddElementRequest for generic set element operations
type AddElementRequest struct {
	Table   string // e.g., "ip nftban", "ip6 nftban"
	Set     string // e.g., "whitelist_ipv4", "tcp_ports_in"
	Element string // e.g., "1.2.3.4", "8080"
	Timeout int    // seconds, 0 = permanent
}

// AddElement adds an element to any set
// This is the ONLY authorized add element implementation
func (b *Backend) AddElement(ctx context.Context, req AddElementRequest) error {
	b.mu.Lock()
	defer b.mu.Unlock()

	// Ensure netlink connection
	if err := b.ensureNetlink(); err != nil {
		b.stats.Errors++
		b.stats.LastError = err.Error()
		return err
	}

	// Determine table family from string
	var family nftables.TableFamily
	if strings.HasPrefix(req.Table, "ip6") {
		family = nftables.TableFamilyIPv6
	} else {
		family = nftables.TableFamilyIPv4
	}

	// Get table
	table, err := b.nft.GetOrCreateTable(family)
	if err != nil {
		b.stats.Errors++
		b.stats.LastError = fmt.Sprintf("get table: %v", err)
		return fmt.Errorf("failed to get table: %w", err)
	}

	// Get or create set (assume interval set for IP sets)
	isIPv4 := family == nftables.TableFamilyIPv4
	set, err := b.nft.GetOrCreateIntervalSet(table, req.Set, isIPv4)
	if err != nil {
		b.stats.Errors++
		b.stats.LastError = fmt.Sprintf("get set: %v", err)
		return fmt.Errorf("failed to get set: %w", err)
	}

	// Add element with optional timeout
	timeout := time.Duration(req.Timeout) * time.Second
	if err := b.nft.AddIPWithTimeout(set, req.Element, timeout); err != nil {
		b.stats.Errors++
		b.stats.LastError = fmt.Sprintf("add element: %v", err)
		return fmt.Errorf("nft add element failed: %w", err)
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

	// Ensure netlink connection
	if err := b.ensureNetlink(); err != nil {
		b.stats.Errors++
		b.stats.LastError = err.Error()
		return err
	}

	// Determine table family from string
	var family nftables.TableFamily
	if strings.HasPrefix(req.Table, "ip6") {
		family = nftables.TableFamilyIPv6
	} else {
		family = nftables.TableFamilyIPv4
	}

	// Get table
	table, err := b.nft.GetOrCreateTable(family)
	if err != nil {
		b.stats.Errors++
		b.stats.LastError = fmt.Sprintf("get table: %v", err)
		return fmt.Errorf("failed to get table: %w", err)
	}

	// Get set
	isIPv4 := family == nftables.TableFamilyIPv4
	set, err := b.nft.GetOrCreateIntervalSet(table, req.Set, isIPv4)
	if err != nil {
		b.stats.Errors++
		b.stats.LastError = fmt.Sprintf("get set: %v", err)
		return fmt.Errorf("failed to get set: %w", err)
	}

	// Delete element
	if err := b.nft.DeleteSetElements(set, []string{req.Element}); err != nil {
		// Ignore "not found" errors
		if !errors.Is(err, os.ErrNotExist) {
			b.stats.Errors++
			b.stats.LastError = fmt.Sprintf("delete element: %v", err)
			return fmt.Errorf("nft delete element failed: %w", err)
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

	// Ensure netlink connection
	if err := b.ensureNetlink(); err != nil {
		b.stats.Errors++
		b.stats.LastError = err.Error()
		return err
	}

	// Determine table family from string
	var family nftables.TableFamily
	if strings.HasPrefix(req.Table, "ip6") {
		family = nftables.TableFamilyIPv6
	} else {
		family = nftables.TableFamilyIPv4
	}

	// Get table
	table, err := b.nft.GetOrCreateTable(family)
	if err != nil {
		b.stats.Errors++
		b.stats.LastError = fmt.Sprintf("get table: %v", err)
		return fmt.Errorf("failed to get table: %w", err)
	}

	// Get set
	isIPv4 := family == nftables.TableFamilyIPv4
	set, err := b.nft.GetOrCreateIntervalSet(table, req.Set, isIPv4)
	if err != nil {
		b.stats.Errors++
		b.stats.LastError = fmt.Sprintf("get set: %v", err)
		return fmt.Errorf("failed to get set: %w", err)
	}

	// Flush set
	if err := b.nft.FlushSet(set); err != nil {
		b.stats.Errors++
		b.stats.LastError = fmt.Sprintf("flush set: %v", err)
		return fmt.Errorf("nft flush set failed: %w", err)
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
// NOTE: This still uses CLI as netlink doesn't support loading .nft files
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

	// Invalidate cached objects after ruleset apply (may have changed structure)
	if b.nft != nil {
		b.nft.InvalidateTableCache()
		b.initCachedObjects()
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
	parsed := net.ParseIP(ip)
	if parsed == nil {
		return false, "", fmt.Errorf("invalid IP: %s", ip)
	}

	// Determine family using To4() - handles IPv4-mapped IPv6 addresses correctly
	ipv4 := parsed.To4()
	isIPv6 := ipv4 == nil

	// Normalize IP string for consistent comparison
	normalizedIP := parsed.String()
	if !isIPv6 {
		normalizedIP = ipv4.String()
	}

	// Ensure netlink
	if err := b.ensureNetlink(); err != nil {
		// Fall back to CLI
		return b.checkIPCLI(ctx, normalizedIP, isIPv6)
	}

	var set *nftables.Set
	var setName string
	if isIPv6 {
		set = b.setBlacklistIPv6
		setName = "blacklist_ipv6"
	} else {
		set = b.setBlacklistIPv4
		setName = "blacklist_ipv4"
	}

	if set == nil {
		// Fall back to CLI
		return b.checkIPCLI(ctx, normalizedIP, isIPv6)
	}

	// Get set elements via netlink
	elements, err := b.nft.GetSetElements(set)
	if err != nil {
		// Fall back to CLI on error
		return b.checkIPCLI(ctx, normalizedIP, isIPv6)
	}

	// Check if IP is in elements
	for _, elem := range elements {
		if elem == normalizedIP || strings.HasPrefix(elem, normalizedIP+"/") {
			return true, setName, nil
		}
	}

	return false, "", nil
}

// checkIPCLI is a fallback for CheckIP using CLI
func (b *Backend) checkIPCLI(ctx context.Context, ip string, isIPv6 bool) (bool, string, error) {
	var table, set string
	if isIPv6 {
		table = b.tableIPv6Str
		set = "blacklist_ipv6"
	} else {
		table = b.tableIPv4Str
		set = "blacklist_ipv4"
	}

	cmd := exec.CommandContext(ctx, "nft", "list", "set", table, set)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return false, "", fmt.Errorf("nft list set failed: %w", err)
	}

	outputStr := string(output)
	if strings.Contains(outputStr, ip+" ") || strings.Contains(outputStr, ip+",") ||
		strings.Contains(outputStr, ip+"\n") || strings.Contains(outputStr, ip+"}") {
		return true, set, nil
	}

	return false, "", nil
}

// HealthCheck verifies nftables is operational
func (b *Backend) HealthCheck(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()

	// Try netlink first
	if b.nft != nil {
		if _, err := b.nft.GetOrCreateTable(nftables.TableFamilyIPv4); err == nil {
			return nil
		}
	}

	// Fall back to CLI
	cmd := exec.CommandContext(ctx, "nft", "list", "tables")
	_, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("nftables not operational: %w", err)
	}
	return nil
}

// GetNFTManager returns the underlying NFTManager for advanced operations
// This allows the daemon to use the same connection for sync operations
func (b *Backend) GetNFTManager() *nftsync.NFTManager {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.nft
}

// InvalidateCache invalidates cached tables and sets
// Call this after external nftables modifications
func (b *Backend) InvalidateCache() {
	b.mu.Lock()
	defer b.mu.Unlock()

	if b.nft != nil {
		b.nft.InvalidateTableCache()
	}
	b.tableIPv4 = nil
	b.tableIPv6 = nil
	b.setBlacklistIPv4 = nil
	b.setBlacklistIPv6 = nil
	b.setWhitelistIPv4 = nil
	b.setWhitelistIPv6 = nil

	// Re-initialize
	b.initCachedObjects()
}
