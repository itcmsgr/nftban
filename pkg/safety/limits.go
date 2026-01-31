// =============================================================================
// NFTBan - Safety Limits Configuration
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="limits"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="CPU, memory, and connection limits for the GUI server"
// meta:input="Environment variables"
// meta:output="Limits configuration"
// meta:depends="os,runtime"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars="NFTBAN_GOMAXPROCS,NFTBAN_MAX_CONCURRENT_CONNS,NFTBAN_MAX_MEMORY_BYTES"
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package safety

import (
	"os"
	"runtime"
	"runtime/debug"
	"strconv"
)

// Limits holds all safety thresholds for the GUI server
type Limits struct {
	// GOMAXPROCS limit (CPU cores)
	GoMaxProcs int // default: 2

	// Connection limits
	MaxConcurrentConns int // default: 100
	MaxConnsPerIP      int // default: 10

	// Request limits
	RequestTimeoutSec  int   // default: 30
	MaxRequestBodyMB   int   // default: 10
	MaxRequestBodyBytes int64 // computed from MB

	// Rate limiting
	RateLimitPerMin int // default: 60 requests per minute per IP

	// Memory limits
	MaxMemoryPercent int   // default: 20% of available
	MaxMemoryBytes   int64 // default: 512 MiB

	// Logging
	EnableMetrics bool // default: true
}

func getEnvInt(k string, def int) int {
	if v := os.Getenv(k); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func getEnvInt64(k string, def int64) int64 {
	if v := os.Getenv(k); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			return n
		}
	}
	return def
}

func getEnvBool(k string, def bool) bool {
	if v := os.Getenv(k); v != "" {
		return v == "1" || v == "true" || v == "yes"
	}
	return def
}

// FromEnv returns sane defaults that can be overridden via environment variables
// This matches the pattern from go-feeds/internal/safety/config.go
func FromEnv() Limits {
	// Get max request body MB and convert to bytes
	maxBodyMB := getEnvInt("NFTBAN_MAX_REQUEST_BODY_MB", 10)
	maxBodyBytes := int64(maxBodyMB) << 20 // MB to bytes

	return Limits{
		GoMaxProcs:          getEnvInt("NFTBAN_GOMAXPROCS", 2),
		MaxConcurrentConns:  getEnvInt("NFTBAN_MAX_CONCURRENT_CONNS", 100),
		MaxConnsPerIP:       getEnvInt("NFTBAN_MAX_CONNS_PER_IP", 10),
		RequestTimeoutSec:   getEnvInt("NFTBAN_REQUEST_TIMEOUT_SEC", 30),
		MaxRequestBodyMB:    maxBodyMB,
		MaxRequestBodyBytes: maxBodyBytes,
		RateLimitPerMin:     getEnvInt("NFTBAN_RATE_LIMIT_PER_MIN", 60),
		MaxMemoryPercent:    getEnvInt("NFTBAN_MAX_MEMORY_PERCENT", 20),
		MaxMemoryBytes:      getEnvInt64("NFTBAN_MAX_MEMORY_BYTES", 512<<20), // 512 MiB
		EnableMetrics:       getEnvBool("NFTBAN_ENABLE_METRICS", true),
	}
}

// InitCPU sets GOMAXPROCS based on config
// This prevents the Go server from consuming all CPU cores
func InitCPU(lim Limits) {
	if lim.GoMaxProcs > 0 {
		runtime.GOMAXPROCS(lim.GoMaxProcs)
	}
}

// InitMemory sets memory limit based on server profile and optional overrides
// Uses runtime/debug SetMemoryLimit (Go 1.19+)
//
// The memory budget is calculated by GetResourceLimits() which considers:
//   - Server RAM size (applies tier caps: ≤4GB→384MB, 4-8GB→512MB, >8GB→1GB)
//   - Control panel presence (20% for panel servers, 35% for non-panel)
//   - Minimum 64MB floor
//
// Environment variable NFTBAN_MAX_MEMORY_BYTES can override this for special cases.
func InitMemory(lim Limits) {
	// Get memory budget from GetResourceLimits() - single source of truth
	// This considers: panel detection, RAM tiers, and leaves headroom for OS/panel
	targetLimit, _ := GetResourceLimits()

	// Allow env var override for special cases (e.g., constrained containers)
	// Only apply if explicitly set and smaller than dynamic calculation
	if lim.MaxMemoryBytes > 0 && lim.MaxMemoryBytes < targetLimit {
		targetLimit = lim.MaxMemoryBytes
	}

	// Set memory limit (Go 1.19+ soft limit)
	// This makes GC work harder as heap approaches limit, keeping RSS bounded
	if targetLimit > 0 {
		debug.SetMemoryLimit(targetLimit)
	}
}

// GetMemoryBudget calculates a safe memory budget based on server profile
// Takes into account CPU cores, total RAM, and control panel presence
// Returns a value that leaves headroom for the OS, panel, and other processes
func GetMemoryBudget() int64 {
	budget, _ := GetResourceLimits()
	return budget
}

// CanAllocate checks if allocating the given bytes is safe
// Returns false if allocation would exceed available memory budget
func CanAllocate(estimatedBytes int64) bool {
	mem := AvailableMem()
	if mem.Avail <= 0 {
		return true // Can't determine, allow operation
	}

	// Reserve 20% of available memory as safety margin
	safeAvail := (mem.Avail * 80) / 100
	return estimatedBytes < safeAvail
}
