// SPDX-License-Identifier: MPL-2.0
// meta:name="opqueue/types" meta:type="package" meta:version="1.1.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Type definitions for OpQueue operations"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"

package opqueue

import (
	"sync"
	"time"
)

// OpType represents the type of operation
type OpType int

const (
	OpAdd OpType = iota
	OpDelete
	OpReplaceSet
	OpFlushSet
)

func (t OpType) String() string {
	switch t {
	case OpAdd:
		return "ADD"
	case OpDelete:
		return "DELETE"
	case OpReplaceSet:
		return "REPLACE_SET"
	case OpFlushSet:
		return "FLUSH_SET"
	default:
		return "UNKNOWN"
	}
}

// SetOp represents a single operation to be queued
type SetOp struct {
	Type     OpType
	Element  string   // IP or CIDR (for Add/Delete)
	Elements []string // For ReplaceSet
	TTL      uint32   // Seconds, 0 = permanent
	Reason   string   // For logging
	Source   string   // Origin module (login, portscan, ddos, etc.)
}

// PendingOp represents a coalesced pending operation
type PendingOp struct {
	Type      OpType
	Element   string
	TTL       uint32   // Seconds, 0 = permanent (infinity in comparisons)
	Source    string   // Latest source (for logging)
	Reason    string   // Latest reason (for logging)
	CreatedAt time.Time
}

// SetBuffer holds pending operations for one set with coalescing
type SetBuffer struct {
	mu sync.Mutex

	setName string

	// Pending individual ops (coalesced by element)
	pending map[string]*PendingOp

	// Barrier support
	currentGen uint64 // Current generation
	barrierGen uint64 // Operations with gen <= barrierGen are pre-barrier

	// Replace/Flush operations (take precedence)
	replaceOp *SetOp // If non-nil, replace entire set
	flushPending bool // If true, flush before any ops

	// Post-barrier ops (queued after barrier set, applied after barrier)
	postBarrier []*SetOp
}

// QueueConfig holds configuration for the operation queue
type QueueConfig struct {
	// Flush policies
	FlushInterval  time.Duration // Time-based flush interval (default: 100ms)
	FlushThreshold int           // Size-based flush threshold (default: 1000 ops)
	MaxBatchSize   int           // Max elements per netlink batch (default: 5000)
	MaxQueueDepth  int64         // Backpressure limit (default: 50000)
}

// DefaultQueueConfig returns sensible defaults
func DefaultQueueConfig() QueueConfig {
	return QueueConfig{
		FlushInterval:  100 * time.Millisecond,
		FlushThreshold: 1000,
		MaxBatchSize:   5000,
		MaxQueueDepth:  50000,
	}
}

// QueueStats holds queue statistics
type QueueStats struct {
	PendingCount  int64
	TotalQueued   uint64
	TotalApplied  uint64
	TotalDropped  uint64
	LastFlushTime time.Time
}

// FlushResult contains the outcome of a buffer flush
type FlushResult struct {
	SetName     string
	Applied     int
	PostBarrier []*SetOp // Ops to re-enqueue after flush
	Err         error
}

// SetElement represents an element to add/delete from nftables
type SetElement struct {
	Value   string
	TTL     uint32
	IsIPv6  bool
}

// NetlinkBackend interface for nftables operations (allows mocking in tests)
type NetlinkBackend interface {
	// FlushSet clears all elements from a set
	FlushSet(table, set string) error

	// AddElements adds elements to a set (batched)
	AddElements(table, set string, elements []SetElement) error

	// DeleteElements removes elements from a set (batched)
	DeleteElements(table, set string, elements []SetElement) error

	// GetSetElements returns all elements in a set
	GetSetElements(table, set string) ([]string, error)
}

// sourceConfig defines how each source module routes to sets
type sourceConfig struct {
	IPv4Set    string
	IPv6Set    string
	AllowBulk  bool   // Can use replace_set
	AllowBan   bool   // Can use ban/unban
	DefaultTTL uint32 // Default timeout (0 = permanent)
}

// sourceConfigs maps source names to their configuration
var sourceConfigs = map[string]sourceConfig{
	// Bulk sources (use replace_set)
	"feeds": {
		IPv4Set:   "feeds_ipv4",
		IPv6Set:   "feeds_ipv6",
		AllowBulk: true,
		AllowBan:  false,
	},
	"geoban": {
		IPv4Set:   "geoban_ipv4",
		IPv6Set:   "geoban_ipv6",
		AllowBulk: true,
		AllowBan:  false,
	},

	// Auto-detection sources (all share auto_* sets)
	"login": {
		IPv4Set:    "auto_ipv4",
		IPv6Set:    "auto_ipv6",
		AllowBulk:  false,
		AllowBan:   true,
		DefaultTTL: 3600, // 1 hour
	},
	"portscan": {
		IPv4Set:    "auto_ipv4",
		IPv6Set:    "auto_ipv6",
		AllowBulk:  false,
		AllowBan:   true,
		DefaultTTL: 7200, // 2 hours
	},
	"portscan-classic": {
		IPv4Set:    "auto_ipv4",
		IPv6Set:    "auto_ipv6",
		AllowBulk:  false,
		AllowBan:   true,
		DefaultTTL: 7200,
	},
	"portscan-suricata": {
		IPv4Set:    "auto_ipv4",
		IPv6Set:    "auto_ipv6",
		AllowBulk:  false,
		AllowBan:   true,
		DefaultTTL: 7200,
	},
	"ddos": {
		IPv4Set:    "auto_ipv4",
		IPv6Set:    "auto_ipv6",
		AllowBulk:  false,
		AllowBan:   true,
		DefaultTTL: 3600,
	},
	"ddos-classic": {
		IPv4Set:    "auto_ipv4",
		IPv6Set:    "auto_ipv6",
		AllowBulk:  false,
		AllowBan:   true,
		DefaultTTL: 3600,
	},
	"ddos-suricata": {
		IPv4Set:    "auto_ipv4",
		IPv6Set:    "auto_ipv6",
		AllowBulk:  false,
		AllowBan:   true,
		DefaultTTL: 3600,
	},
	"suricata": {
		IPv4Set:    "auto_ipv4",
		IPv6Set:    "auto_ipv6",
		AllowBulk:  false,
		AllowBan:   true,
		DefaultTTL: 3600,
	},

	// Manual CLI
	"manual": {
		IPv4Set:    "manual_ipv4",
		IPv6Set:    "manual_ipv6",
		AllowBulk:  false,
		AllowBan:   true,
		DefaultTTL: 0, // Permanent by default
	},
	"cli": {
		IPv4Set:    "manual_ipv4",
		IPv6Set:    "manual_ipv6",
		AllowBulk:  false,
		AllowBan:   true,
		DefaultTTL: 0,
	},
}

// GetSourceConfig returns the configuration for a source
func GetSourceConfig(source string) (sourceConfig, bool) {
	cfg, ok := sourceConfigs[source]
	if !ok {
		// Default to manual for unknown sources
		return sourceConfigs["manual"], false
	}
	return cfg, true
}

// GetTargetSet returns the appropriate set for a source and IP
func GetTargetSet(source, ip string) string {
	cfg, _ := GetSourceConfig(source)

	isIPv6 := false
	for _, c := range ip {
		if c == ':' {
			isIPv6 = true
			break
		}
	}

	if isIPv6 {
		return cfg.IPv6Set
	}
	return cfg.IPv4Set
}

// GetAllSets returns all known set names
func GetAllSets() []string {
	return []string{
		"feeds_ipv4", "feeds_ipv6",
		"geoban_ipv4", "geoban_ipv6",
		"auto_ipv4", "auto_ipv6",
		"manual_ipv4", "manual_ipv6",
	}
}

