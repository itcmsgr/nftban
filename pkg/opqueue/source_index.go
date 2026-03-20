// SPDX-License-Identifier: MPL-2.0
// meta:name="opqueue/source_index" meta:type="package" meta:version="1.1.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Source tracking index for shared nftables sets"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"

package opqueue

import (
	"bufio"
	"context"
	"encoding/json"
	"log"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"github.com/itcmsgr/nftban/pkg/constants"
)

const (
	// Only persist for shared sets (feeds/geoban are dedicated, no need)
	defaultIndexPath = "/var/lib/nftban/source_index.jsonl"
)

// persistSets defines which sets need source tracking persistence
// v2.1: All bans go to unified blacklist - track sources in database
var persistSets = map[string]bool{
	"blacklist_ipv4": true,
	"blacklist_ipv6": true,
}

// IndexEntry represents a persisted index entry
type IndexEntry struct {
	Set     string   `json:"set"`
	Element string   `json:"element"`
	Sources []string `json:"sources"`
	TTL     uint32   `json:"ttl,omitempty"`
	Updated int64    `json:"updated"`
}

// SourceIndex tracks which elements came from which source
// Enables flush_source without dedicated sets per module
type SourceIndex struct {
	mu sync.RWMutex

	// set -> element -> sources
	index map[string]map[string]map[string]struct{}

	// Persistence
	indexPath string
	dirty     atomic.Bool
	saveCh    chan struct{}
	stopCh    chan struct{}
}

// NewSourceIndex creates a new source index
func NewSourceIndex(indexPath string) *SourceIndex {
	if indexPath == "" {
		indexPath = defaultIndexPath
	}
	return &SourceIndex{
		index:     make(map[string]map[string]map[string]struct{}),
		indexPath: indexPath,
		saveCh:    make(chan struct{}, 1),
		stopCh:    make(chan struct{}),
	}
}

// Add adds an element with its source
func (si *SourceIndex) Add(setName, element, source string) {
	si.mu.Lock()
	defer si.mu.Unlock()

	if si.index[setName] == nil {
		si.index[setName] = make(map[string]map[string]struct{})
	}
	if si.index[setName][element] == nil {
		si.index[setName][element] = make(map[string]struct{})
	}
	si.index[setName][element][source] = struct{}{}

	// Mark dirty only for persisted sets
	if persistSets[setName] {
		si.markDirty()
	}
}

// Remove removes a source from an element
func (si *SourceIndex) Remove(setName, element, source string) {
	si.mu.Lock()
	defer si.mu.Unlock()

	if si.index[setName] != nil && si.index[setName][element] != nil {
		delete(si.index[setName][element], source)
		if len(si.index[setName][element]) == 0 {
			delete(si.index[setName], element)
		}
	}

	if persistSets[setName] {
		si.markDirty()
	}
}

// RemoveAll removes all sources from an element
func (si *SourceIndex) RemoveAll(setName, element string) {
	si.mu.Lock()
	defer si.mu.Unlock()

	if si.index[setName] != nil {
		delete(si.index[setName], element)
	}

	if persistSets[setName] {
		si.markDirty()
	}
}

// GetElementsBySource returns all elements in a set from a specific source
func (si *SourceIndex) GetElementsBySource(setName, source string) []string {
	si.mu.RLock()
	defer si.mu.RUnlock()

	var elements []string
	if si.index[setName] != nil {
		for element, sources := range si.index[setName] {
			if _, ok := sources[source]; ok {
				elements = append(elements, element)
			}
		}
	}
	return elements
}

// HasElement checks if an element exists in a set
func (si *SourceIndex) HasElement(setName, element string) bool {
	si.mu.RLock()
	defer si.mu.RUnlock()

	return si.index[setName] != nil && si.index[setName][element] != nil && len(si.index[setName][element]) > 0
}

// ShouldDelete returns true if element has no remaining sources
func (si *SourceIndex) ShouldDelete(setName, element string) bool {
	si.mu.RLock()
	defer si.mu.RUnlock()

	return si.index[setName] == nil ||
		si.index[setName][element] == nil ||
		len(si.index[setName][element]) == 0
}

// GetAllElements returns all elements in a set (as a map for O(1) lookup)
func (si *SourceIndex) GetAllElements(setName string) map[string]bool {
	si.mu.RLock()
	defer si.mu.RUnlock()

	result := make(map[string]bool)
	if si.index[setName] != nil {
		for element := range si.index[setName] {
			result[element] = true
		}
	}
	return result
}

// ClearSet removes all entries for a set
func (si *SourceIndex) ClearSet(setName string) {
	si.mu.Lock()
	defer si.mu.Unlock()

	delete(si.index, setName)

	if persistSets[setName] {
		si.markDirty()
	}
}

// markDirty signals that index needs persistence (atomic, no lock needed)
func (si *SourceIndex) markDirty() {
	si.dirty.Store(true)

	// Non-blocking signal to background saver
	select {
	case si.saveCh <- struct{}{}:
	default:
	}
}

// LoadFromDisk restores index on daemon startup
func (si *SourceIndex) LoadFromDisk() error {
	file, err := os.Open(si.indexPath)
	if os.IsNotExist(err) {
		return nil // Fresh start
	}
	if err != nil {
		return err
	}
	defer file.Close()

	si.mu.Lock()
	defer si.mu.Unlock()

	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024) // 1MB max line

	for scanner.Scan() {
		var entry IndexEntry
		if err := json.Unmarshal(scanner.Bytes(), &entry); err != nil {
			continue // Skip malformed lines
		}

		// Rebuild in-memory index
		if si.index[entry.Set] == nil {
			si.index[entry.Set] = make(map[string]map[string]struct{})
		}
		if si.index[entry.Set][entry.Element] == nil {
			si.index[entry.Set][entry.Element] = make(map[string]struct{})
		}
		for _, src := range entry.Sources {
			si.index[entry.Set][entry.Element][src] = struct{}{}
		}
	}

	return scanner.Err()
}

// SaveToDisk persists index (called after netlink apply, not on enqueue)
func (si *SourceIndex) SaveToDisk() error {
	if !si.dirty.Load() {
		return nil
	}

	si.mu.RLock()

	// Build entries to write
	var entries []IndexEntry
	now := time.Now().Unix()

	for setName, elements := range si.index {
		// Only persist shared sets
		if !persistSets[setName] {
			continue
		}

		for element, sources := range elements {
			srcList := make([]string, 0, len(sources))
			for src := range sources {
				srcList = append(srcList, src)
			}

			entries = append(entries, IndexEntry{
				Set:     setName,
				Element: element,
				Sources: srcList,
				Updated: now,
			})
		}
	}

	si.mu.RUnlock()

	// Write to temp file then atomic rename
	tmpPath := si.indexPath + ".tmp"
	file, err := os.OpenFile(tmpPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		return err
	}
	closed := false
	defer func() {
		if !closed {
			_ = file.Close()
			_ = os.Remove(tmpPath)
		}
	}()

	writer := bufio.NewWriter(file)

	for _, entry := range entries {
		data, err := json.Marshal(entry)
		if err != nil {
			continue
		}
		if _, err := writer.Write(data); err != nil {
			return err
		}
		if err := writer.WriteByte('\n'); err != nil {
			return err
		}
	}

	if err := writer.Flush(); err != nil {
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	closed = true

	if err := os.Rename(tmpPath, si.indexPath); err != nil {
		return err
	}

	si.dirty.Store(false)
	return nil
}

// StartBackgroundSaver runs periodic persistence
func (si *SourceIndex) StartBackgroundSaver(ctx context.Context) {
	ticker := time.NewTicker(constants.OpQueueSourceIndexInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			if err := si.SaveToDisk(); err != nil {
				log.Printf("[SourceIndex] Final save on shutdown failed: %v", err)
			}
			return
		case <-si.stopCh:
			if err := si.SaveToDisk(); err != nil {
				log.Printf("[SourceIndex] Final save on stop failed: %v", err)
			}
			return
		case <-si.saveCh:
			if err := si.SaveToDisk(); err != nil {
				log.Printf("[SourceIndex] Save failed: %v", err)
			}
		case <-ticker.C:
			if err := si.SaveToDisk(); err != nil {
				log.Printf("[SourceIndex] Periodic save failed: %v", err)
			}
		}
	}
}

// Stop signals the background saver to stop
func (si *SourceIndex) Stop() {
	close(si.stopCh)
}

// ReconcileWithBackend syncs index with actual nft state
// Uses O(n) map lookups instead of O(n²) nested loops
// v2.1: Only unified blacklist sets need reconciliation
func (si *SourceIndex) ReconcileWithBackend(backend NetlinkBackend) {
	for _, setName := range []string{"blacklist_ipv4", "blacklist_ipv6"} {
		elements, err := backend.GetSetElements("nftban", setName)
		if err != nil {
			continue
		}

		// Build map of nft elements for O(1) lookup
		nftElements := make(map[string]bool, len(elements))
		for _, elem := range elements {
			nftElements[elem] = true
		}

		// Get indexed elements (already a map)
		indexed := si.GetAllElements(setName)

		// Elements in nft but not in index -> add with source="unknown"
		for elem := range nftElements {
			if !indexed[elem] {
				si.Add(setName, elem, "unknown")
			}
		}

		// Elements in index but not in nft -> remove from index
		for elem := range indexed {
			if !nftElements[elem] {
				si.RemoveAll(setName, elem)
			}
		}
	}

	si.markDirty()
}
