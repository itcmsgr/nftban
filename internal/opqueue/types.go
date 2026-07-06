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

	"github.com/itcmsgr/nftban/internal/constants"
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
		FlushInterval:  constants.OpQueueFlushInterval,
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
	// L2b: number of replace_set applies that flushed then applied fewer elements than
	// intended (partial/fail-open). Non-zero = degraded; the set is short of requested.
	ReplacePartialFailures uint64
	// L3b: number of EnqueueBan calls refused because a single exempt IP targeted an
	// enforcement/drop set (never-ban invariant on the opqueue ban path).
	EnqueueBanExemptSkips uint64
	LastFlushTime         time.Time
}

// FlushResult contains the outcome of a buffer flush
type FlushResult struct {
	SetName     string
	Applied     int      // TRUE count of elements actually applied (== actually_applied)
	Intended    int      // L2b: elements the replace/flush intended to apply (diagnostic; 0 if N/A)
	Adds        int      // Count of add operations applied (v1.32.0)
	Deletes     int      // Count of delete operations applied (v1.32.0)
	WasReplace  bool     // True if this was a replace_set operation (v1.32.0)
	WasFlush    bool     // True if this was a flush_set operation (v1.32.0)
	PostBarrier []*SetOp // Ops to re-enqueue after flush
	// Err is set when the operation did not fully succeed. L2b invariant:
	// a partial replace (Applied < Intended) is NOT success — Err is non-nil.
	Err error
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

	// AddElements adds elements to a set (batched). L2b: truth-bearing contract —
	// returns the count ACTUALLY applied and a non-nil error if any element failed
	// (applied < len(elements)). The returned count MUST equal what was really applied;
	// callers rely on partial_apply != success.
	AddElements(table, set string, elements []SetElement) (applied int, err error)

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
// v1.33.0: Manual/auto-detect sources route to hash sets (O(1))
//          Feed/geoban sources route to interval sets (CIDR aggregation)
var sourceConfigs = map[string]sourceConfig{
	// Bulk sources → interval set (CIDR aggregation, auto-merge)
	"feeds": {
		IPv4Set:   "blacklist_ipv4",
		IPv6Set:   "blacklist_ipv6",
		AllowBulk: true,
		AllowBan:  false,
	},
	"geoban": {
		IPv4Set:   "blacklist_ipv4",
		IPv6Set:   "blacklist_ipv6",
		AllowBulk: true,
		AllowBan:  false,
	},

	// Auto-detection sources → hash set (O(1) ban/unban)
	"login": {
		IPv4Set:    "blacklist_manual_ipv4",
		IPv6Set:    "blacklist_manual_ipv6",
		AllowBulk:  false,
		AllowBan:   true,
		DefaultTTL: 3600, // 1 hour
	},
	"portscan": {
		IPv4Set:    "blacklist_manual_ipv4",
		IPv6Set:    "blacklist_manual_ipv6",
		AllowBulk:  false,
		AllowBan:   true,
		DefaultTTL: 7200, // 2 hours
	},
	"portscan-classic": {
		IPv4Set:    "blacklist_manual_ipv4",
		IPv6Set:    "blacklist_manual_ipv6",
		AllowBulk:  false,
		AllowBan:   true,
		DefaultTTL: 7200,
	},
	"portscan-suricata": {
		IPv4Set:    "blacklist_manual_ipv4",
		IPv6Set:    "blacklist_manual_ipv6",
		AllowBulk:  false,
		AllowBan:   true,
		DefaultTTL: 7200,
	},
	"ddos": {
		IPv4Set:    "blacklist_manual_ipv4",
		IPv6Set:    "blacklist_manual_ipv6",
		AllowBulk:  false,
		AllowBan:   true,
		DefaultTTL: 3600,
	},
	"ddos-classic": {
		IPv4Set:    "blacklist_manual_ipv4",
		IPv6Set:    "blacklist_manual_ipv6",
		AllowBulk:  false,
		AllowBan:   true,
		DefaultTTL: 3600,
	},
	"ddos-suricata": {
		IPv4Set:    "blacklist_manual_ipv4",
		IPv6Set:    "blacklist_manual_ipv6",
		AllowBulk:  false,
		AllowBan:   true,
		DefaultTTL: 3600,
	},
	"suricata": {
		IPv4Set:    "blacklist_manual_ipv4",
		IPv6Set:    "blacklist_manual_ipv6",
		AllowBulk:  false,
		AllowBan:   true,
		DefaultTTL: 3600,
	},

	// Manual CLI → hash set (O(1), permanent bans by default)
	"manual": {
		IPv4Set:    "blacklist_manual_ipv4",
		IPv6Set:    "blacklist_manual_ipv6",
		AllowBulk:  false,
		AllowBan:   true,
		DefaultTTL: 0, // Permanent by default
	},
	"cli": {
		IPv4Set:    "blacklist_manual_ipv4",
		IPv6Set:    "blacklist_manual_ipv6",
		AllowBulk:  false,
		AllowBan:   true,
		DefaultTTL: 0,
	},
	// Persistent offender escalation → hash set
	"persistent": {
		IPv4Set:    "blacklist_manual_ipv4",
		IPv6Set:    "blacklist_manual_ipv6",
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
// v1.39.0: CIDRs always route to interval set (hash sets don't support ranges)
func GetTargetSet(source, ip string) string {
	cfg, _ := GetSourceConfig(source)

	isIPv6 := false
	for _, c := range ip {
		if c == ':' {
			isIPv6 = true
			break
		}
	}

	// v1.39.0: CIDRs must use interval sets
	isCIDR := false
	for _, c := range ip {
		if c == '/' {
			isCIDR = true
			break
		}
	}

	if isIPv6 {
		if isCIDR {
			return "blacklist_ipv6"
		}
		return cfg.IPv6Set
	}
	if isCIDR {
		return "blacklist_ipv4"
	}
	return cfg.IPv4Set
}

// GetAllSets returns all known set names
// v1.33.0: Dual sets — interval (feeds) + hash (manual)
func GetAllSets() []string {
	return []string{
		"whitelist_ipv4", "whitelist_ipv6",
		"blacklist_ipv4", "blacklist_ipv6",
		"blacklist_manual_ipv4", "blacklist_manual_ipv6",
	}
}

