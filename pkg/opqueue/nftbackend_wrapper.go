// =============================================================================
// NFTBan v1.13.0 - NFTBackend Wrapper for OpQueue
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="opqueue/nftbackend_wrapper" meta:type="package" meta:version="1.1.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="NFTBackend wrapper for OpQueue netlink operations"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
//
// This adapter wraps the existing nftbackend.Backend to implement the
// NetlinkBackend interface required by OpQueue. This ensures a single
// netlink connection is shared across the daemon.
// =============================================================================

package opqueue

import (
	"context"
	"fmt"
	"net"
	"strings"
	"time"

	"github.com/google/nftables"
	nftsync "github.com/itcmsgr/nftban/pkg/sync"
)

// NFTBackendWrapper wraps nftsync.NFTManager to implement NetlinkBackend
type NFTBackendWrapper struct {
	nft *nftsync.NFTManager

	// Cached tables
	tableIPv4 *nftables.Table
	tableIPv6 *nftables.Table

	// Cached sets (keyed by set name)
	sets map[string]*nftables.Set
}

// NewNFTBackendWrapper creates a wrapper around an existing NFTManager
func NewNFTBackendWrapper(nft *nftsync.NFTManager) (*NFTBackendWrapper, error) {
	if nft == nil {
		return nil, fmt.Errorf("NFTManager is nil")
	}

	wrapper := &NFTBackendWrapper{
		nft:  nft,
		sets: make(map[string]*nftables.Set),
	}

	// Initialize tables
	if err := wrapper.initTables(); err != nil {
		return nil, fmt.Errorf("failed to init tables: %w", err)
	}

	return wrapper, nil
}

// initTables finds or creates the nftban tables
func (w *NFTBackendWrapper) initTables() error {
	var err error

	w.tableIPv4, err = w.nft.GetOrCreateTable(nftables.TableFamilyIPv4)
	if err != nil {
		return fmt.Errorf("failed to get IPv4 table: %w", err)
	}

	w.tableIPv6, err = w.nft.GetOrCreateTable(nftables.TableFamilyIPv6)
	if err != nil {
		return fmt.Errorf("failed to get IPv6 table: %w", err)
	}

	return nil
}

// getTable returns the appropriate table for a set name
func (w *NFTBackendWrapper) getTable(setName string) *nftables.Table {
	if strings.HasSuffix(setName, "_ipv6") {
		return w.tableIPv6
	}
	return w.tableIPv4
}

// getSet gets or creates a set with caching
func (w *NFTBackendWrapper) getSet(setName string) (*nftables.Set, error) {
	// Check cache
	if set, ok := w.sets[setName]; ok {
		return set, nil
	}

	table := w.getTable(setName)
	isIPv4 := table == w.tableIPv4

	// Use NFTManager's GetOrCreateIntervalSet
	set, err := w.nft.GetOrCreateIntervalSet(table, setName, isIPv4)
	if err != nil {
		return nil, fmt.Errorf("failed to get/create set %s: %w", setName, err)
	}

	w.sets[setName] = set
	return set, nil
}

// FlushSet clears all elements from a set
func (w *NFTBackendWrapper) FlushSet(tableName, setName string) error {
	set, err := w.getSet(setName)
	if err != nil {
		return err
	}

	return w.nft.FlushSet(set)
}

// AddElements adds elements to a set (batched)
func (w *NFTBackendWrapper) AddElements(tableName, setName string, elements []SetElement) error {
	if len(elements) == 0 {
		return nil
	}

	set, err := w.getSet(setName)
	if err != nil {
		return err
	}

	// Convert to string IPs for NFTManager
	for _, elem := range elements {
		timeout := time.Duration(elem.TTL) * time.Second
		if err := w.nft.AddIPWithTimeout(set, elem.Value, timeout); err != nil {
			// Log but continue - don't fail batch for individual errors
			continue
		}
	}

	return nil
}

// DeleteElements removes elements from a set (batched)
func (w *NFTBackendWrapper) DeleteElements(tableName, setName string, elements []SetElement) error {
	if len(elements) == 0 {
		return nil
	}

	set, err := w.getSet(setName)
	if err != nil {
		return err
	}

	// Convert to string IPs
	ips := make([]string, len(elements))
	for i, elem := range elements {
		ips[i] = elem.Value
	}

	return w.nft.DeleteSetElements(set, ips)
}

// GetSetElements returns all elements in a set
func (w *NFTBackendWrapper) GetSetElements(tableName, setName string) ([]string, error) {
	set, err := w.getSet(setName)
	if err != nil {
		return nil, err
	}

	return w.nft.GetSetElements(set)
}

// InvalidateCache clears the set cache (call after external nft changes)
func (w *NFTBackendWrapper) InvalidateCache() {
	w.sets = make(map[string]*nftables.Set)
	w.nft.InvalidateTableCache()
	w.initTables()
}

// Close is a no-op since we don't own the NFTManager
func (w *NFTBackendWrapper) Close() {
	// Connection cleanup handled by the owner (nftbackend.Backend)
}

// Ensure NFTBackendWrapper implements NetlinkBackend
var _ NetlinkBackend = (*NFTBackendWrapper)(nil)

// =============================================================================
// STANDALONE BACKEND (for testing or standalone usage)
// =============================================================================

// StandaloneBackend creates its own NFTManager connection
// Use this only for testing or when no existing Backend is available
type StandaloneBackend struct {
	*NFTBackendWrapper
	ownedNFT *nftsync.NFTManager
}

// NewStandaloneBackend creates a backend with its own netlink connection
func NewStandaloneBackend() (*StandaloneBackend, error) {
	nft, err := nftsync.NewNFTManager()
	if err != nil {
		return nil, fmt.Errorf("failed to create NFTManager: %w", err)
	}

	wrapper, err := NewNFTBackendWrapper(nft)
	if err != nil {
		return nil, err
	}

	return &StandaloneBackend{
		NFTBackendWrapper: wrapper,
		ownedNFT:          nft,
	}, nil
}

// Close closes the owned NFTManager connection
func (s *StandaloneBackend) Close() {
	// NFTManager doesn't have explicit Close, GC handles it
	s.ownedNFT = nil
}

// =============================================================================
// HELPER: IP PARSING
// =============================================================================

// isIPv6 checks if an IP string represents IPv6
func isIPv6(ip string) bool {
	// Quick check for colon (IPv6 indicator)
	for _, c := range ip {
		if c == ':' {
			return true
		}
	}
	return false
}

// parseIPForSet parses an IP/CIDR string for set insertion
func parseIPForSet(ipStr string, isIPv6Set bool) (net.IP, *net.IPNet, error) {
	// Check if it's a CIDR
	if strings.Contains(ipStr, "/") {
		_, ipNet, err := net.ParseCIDR(ipStr)
		if err != nil {
			return nil, nil, fmt.Errorf("invalid CIDR: %s", ipStr)
		}
		return nil, ipNet, nil
	}

	// Single IP
	ip := net.ParseIP(ipStr)
	if ip == nil {
		return nil, nil, fmt.Errorf("invalid IP: %s", ipStr)
	}

	return ip, nil, nil
}

// =============================================================================
// CONTEXT HELPERS
// =============================================================================

// contextKey for passing context options
type contextKey string

const ctxKeyTimeout contextKey = "timeout"

// WithTimeout returns a context with timeout for operations
func WithTimeout(ctx context.Context, timeout time.Duration) context.Context {
	return context.WithValue(ctx, ctxKeyTimeout, timeout)
}
