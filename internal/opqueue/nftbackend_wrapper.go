// =============================================================================
// NFTBan v1.13.0 - NFTBackend Wrapper for OpQueue
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
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
	"net/netip"
	"strings"
	"time"

	"github.com/google/nftables"
	nftsync "github.com/itcmsgr/nftban/internal/setsync"
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

// v1.238.1 F2 (BUG-OPQUEUE-IPV6-SETS-RESOLVED-BY-NAME-SUFFIX): the write path no longer picks
// the table from the set NAME (only "_ipv6" names went to ip6, so http_bot_grey6/http_bot_ban6
// resolved to the ip table) and no longer CREATES a missing set (getSet fabricated an ipv4
// interval set of that name in table ip, which later coexisted with the real ip6 set).
// Add/delete resolve the set in the table of the ELEMENT's address family and check the set's
// key type; flush/list resolve by name only when that is unambiguous. A missing set is an error.

// valueFamily returns the address family of an element (IP or CIDR).
func valueFamily(v string) (nftables.TableFamily, error) {
	if p, err := netip.ParsePrefix(v); err == nil {
		if p.Addr().Is4() || p.Addr().Is4In6() {
			return nftables.TableFamilyIPv4, nil
		}
		return nftables.TableFamilyIPv6, nil
	}
	a, err := netip.ParseAddr(v)
	if err != nil {
		return 0, fmt.Errorf("element %q is not an IP address or prefix", v)
	}
	if a.Is4() || a.Is4In6() {
		return nftables.TableFamilyIPv4, nil
	}
	return nftables.TableFamilyIPv6, nil
}

func keyTypeMatches(set *nftables.Set, fam nftables.TableFamily) bool {
	if fam == nftables.TableFamilyIPv6 {
		return set.KeyType == nftables.TypeIP6Addr
	}
	return set.KeyType == nftables.TypeIPAddr
}

func (w *NFTBackendWrapper) tableFor(fam nftables.TableFamily) *nftables.Table {
	if fam == nftables.TableFamilyIPv6 {
		return w.tableIPv6
	}
	return w.tableIPv4
}

func familyName(fam nftables.TableFamily) string {
	if fam == nftables.TableFamilyIPv6 {
		return "ip6"
	}
	return "ip"
}

// setInFamily returns the existing set setName in the nftban table of family fam, after checking
// that its key type is that family's address type. It never looks in the other family and never
// creates a set.
func (w *NFTBackendWrapper) setInFamily(setName string, fam nftables.TableFamily) (*nftables.Set, error) {
	key := familyName(fam) + "|" + setName
	if set, ok := w.sets[key]; ok {
		return set, nil
	}
	set, err := w.nft.FindSetInTable(w.tableFor(fam), setName)
	if err != nil {
		return nil, err
	}
	if set == nil {
		return nil, fmt.Errorf("set %s not found in %s nftban table", setName, familyName(fam))
	}
	if !keyTypeMatches(set, fam) {
		return nil, fmt.Errorf("set %s in %s nftban table has key type %s, not the %s address type",
			setName, familyName(fam), set.KeyType.Name, familyName(fam))
	}
	w.sets[key] = set
	return set, nil
}

// setByName resolves setName when no element tells the family (flush, list). It is used only
// when that is unambiguous: the set exists with a matching address key type in exactly one
// family; if both families hold one, the schema's naming decides (see below), so a flush of
// http_bot_grey6 empties the ip6 set and never the ipv4-typed copy the old path left in table ip.
func (w *NFTBackendWrapper) setByName(setName string) (*nftables.Set, error) {
	var found []*nftables.Set
	for _, fam := range []nftables.TableFamily{nftables.TableFamilyIPv4, nftables.TableFamilyIPv6} {
		set, err := w.nft.FindSetInTable(w.tableFor(fam), setName)
		if err != nil {
			return nil, err
		}
		if set != nil && keyTypeMatches(set, fam) {
			found = append(found, set)
		}
	}
	switch len(found) {
	case 1:
		return found[0], nil
	case 0:
		return nil, fmt.Errorf("set %s not found with an address key type in the ip or ip6 nftban table", setName)
	default:
		// Both tables hold a set of this name. That is the state the old name-suffix path left on
		// upgraded hosts (a real ip6 http_bot_grey6 plus an ipv4-typed copy in table ip). The
		// schema's naming decides: names ending "_ipv6" or "6" belong to ip6, all others to ip.
		if strings.HasSuffix(setName, "_ipv6") || strings.HasSuffix(setName, "6") {
			return found[1], nil
		}
		return found[0], nil
	}
}

// FlushSet clears all elements from a set
func (w *NFTBackendWrapper) FlushSet(tableName, setName string) error {
	set, err := w.setByName(setName)
	if err != nil {
		return err
	}

	return w.nft.FlushSet(set)
}

// AddElements adds elements to a set (batched). L2b (OPQUEUE_PER_ELEMENT_APPLY_RESULT):
// truth-bearing — returns the count ACTUALLY applied and, if any element failed, a
// non-nil error carrying the applied/total shortfall + the first failure. Previously this
// swallowed per-element failures and returned nil (success-shaped), which hid partial
// replace_set applies from the caller. It still continues past a single bad element (so one
// bad IP does not abort the whole batch), but no longer reports that as full success.
func (w *NFTBackendWrapper) AddElements(tableName, setName string, elements []SetElement) (int, error) {
	if len(elements) == 0 {
		return 0, nil
	}

	applied := 0
	var firstErr error
	for _, elem := range elements {
		fam, err := valueFamily(elem.Value)
		if err == nil {
			var set *nftables.Set
			if set, err = w.setInFamily(setName, fam); err == nil {
				err = w.nft.AddIPWithTimeout(set, elem.Value, time.Duration(elem.TTL)*time.Second)
			}
		}
		if err != nil {
			// Continue past a single bad element, but remember the first failure.
			if firstErr == nil {
				firstErr = fmt.Errorf("add %q to %s: %w", elem.Value, setName, err)
			}
			continue
		}
		applied++
	}

	if applied < len(elements) {
		return applied, fmt.Errorf("applied %d of %d to %s: %w", applied, len(elements), setName, firstErr)
	}
	return applied, nil
}

// ReplaceSet atomically replaces the entire contents of a set in ONE netlink
// transaction, delegating to the shared NFTManager connection. It does NOT call
// the separately-committing FlushSet()/AddElements() methods — flush + add +
// commit happen as a single transaction, so the set is never transiently empty
// (fail-CLOSED on failure). The address family is derived from the resolved set's
// KeyType inside ReplaceSetElements, never from setName.
func (w *NFTBackendWrapper) ReplaceSet(tableName, setName string, elements []SetElement) error {
	// v1.238.1 F2: the family comes from the elements (all must share it); an empty replacement
	// (clear) resolves by name only when unambiguous. Never the ip6-first name lookup.
	var set *nftables.Set
	var err error
	if len(elements) == 0 {
		set, err = w.setByName(setName)
	} else {
		fam, ferr := valueFamily(elements[0].Value)
		if ferr != nil {
			return fmt.Errorf("replace_set %s: %w", setName, ferr)
		}
		for _, e := range elements[1:] {
			if f, ferr := valueFamily(e.Value); ferr != nil || f != fam {
				return fmt.Errorf("replace_set %s: elements mix address families or are invalid (%q)", setName, e.Value)
			}
		}
		set, err = w.setInFamily(setName, fam)
	}
	if err != nil {
		return err
	}

	inputs := make([]nftsync.SetElementInput, 0, len(elements))
	for _, e := range elements {
		inputs = append(inputs, nftsync.SetElementInput{
			Value:   e.Value,
			Timeout: time.Duration(e.TTL) * time.Second,
		})
	}

	return w.nft.ReplaceSetElements(set, inputs)
}

// DeleteElements removes elements from a set (batched)
func (w *NFTBackendWrapper) DeleteElements(tableName, setName string, elements []SetElement) error {
	if len(elements) == 0 {
		return nil
	}

	// Group by address family: each element is removed only from the set of its own family.
	byFam := map[nftables.TableFamily][]string{}
	for _, elem := range elements {
		fam, err := valueFamily(elem.Value)
		if err != nil {
			return fmt.Errorf("delete from %s: %w", setName, err)
		}
		byFam[fam] = append(byFam[fam], elem.Value)
	}
	for _, fam := range []nftables.TableFamily{nftables.TableFamilyIPv4, nftables.TableFamilyIPv6} {
		ips := byFam[fam]
		if len(ips) == 0 {
			continue
		}
		set, err := w.setInFamily(setName, fam)
		if err != nil {
			return err
		}
		if err := w.nft.DeleteSetElements(set, ips); err != nil {
			return err
		}
	}
	return nil
}

// GetSetElements returns all elements in a set
func (w *NFTBackendWrapper) GetSetElements(tableName, setName string) ([]string, error) {
	set, err := w.setByName(setName)
	if err != nil {
		return nil, err
	}

	return w.nft.GetSetElements(set)
}

// GetSetCount returns the number of elements in a set (it reads every element; the caller
// bounds how often). For interval sets, filters out IntervalEnd markers to return the true
// entry count.
//
// v1.236: read-only. It used getSet, which CREATES a missing set as an interval set in the
// table guessed from the name (http_bot_ban6 has no _ipv6 suffix, so it would be fabricated
// in the ip table), and counting now runs every exporter interval. The set is looked up in
// the name's table first (tcp_ports_in etc. exist in both families), then the other one,
// with FindSetInTable (as setInFamily/setByName do); a missing set is an error, never created.
func (w *NFTBackendWrapper) GetSetCount(tableName, setName string) (int, error) {
	first, second := w.getTable(setName), w.tableIPv6
	if first == w.tableIPv6 {
		second = w.tableIPv4
	}
	for _, tbl := range []*nftables.Table{first, second} {
		set, err := w.nft.FindSetInTable(tbl, setName)
		if err != nil {
			return 0, err
		}
		if set != nil {
			return w.nft.GetSetCount(set)
		}
	}
	return 0, fmt.Errorf("set %s not found in ip or ip6 nftban table", setName)
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
// CONTEXT HELPERS
// =============================================================================

// contextKey for passing context options
type contextKey string

const ctxKeyTimeout contextKey = "timeout"

// WithTimeout returns a context with timeout for operations
func WithTimeout(ctx context.Context, timeout time.Duration) context.Context {
	return context.WithValue(ctx, ctxKeyTimeout, timeout)
}
