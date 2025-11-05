package safety

import (
	"os"
	"runtime"
	"strconv"
)

// Limits holds all safety thresholds
type Limits struct {
	// Absolute caps
	MaxPrefixesTotal  int   // e.g., 1_000_000
	MaxProjectedBytes int64 // e.g., 512<<20 (512 MiB)
	MaxPctOfAvail     int   // e.g., 20 => up to 20% of available

	// Delta caps per run
	MaxAddsPerRun int // e.g., 1000 => allow at most +1k per sync
	MaxDelsPerRun int // optional large drops guard (e.g., 200k)

	// Enforcement flag: if false => warn-only
	Enforce bool

	// Apply timeout seconds
	ApplyTimeoutSec int // e.g., 60

	// Fetch workers
	FetchWorkers int // e.g., 8

	// GOMAXPROCS limit
	GoMaxProcs int // e.g., 2

	// Cache directory for snapshots/hash
	CacheDir string // default /var/lib/nftban/cache
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

// FromEnv returns sane defaults that can be overridden via environment variables
func FromEnv() Limits {
	cache := os.Getenv("NFTBAN_CACHE_DIR")
	if cache == "" {
		cache = "/var/lib/nftban/cache"
	}
	return Limits{
		MaxPrefixesTotal:  getEnvInt("NFTBAN_MAX_PREFIXES", 1_000_000),
		MaxProjectedBytes: getEnvInt64("NFTBAN_MAX_PROJECTED_BYTES", 512<<20), // 512 MiB
		MaxPctOfAvail:     getEnvInt("NFTBAN_MAX_PCT_AVAIL", 20),
		MaxAddsPerRun:     getEnvInt("NFTBAN_MAX_ADDS_PER_RUN", 1000),
		MaxDelsPerRun:     getEnvInt("NFTBAN_MAX_DELS_PER_RUN", 200_000),
		Enforce:           getEnvInt("NFTBAN_ENFORCE_LIMITS", 1) == 1,
		ApplyTimeoutSec:   getEnvInt("NFTBAN_APPLY_TIMEOUT_SEC", 60),
		FetchWorkers:      getEnvInt("NFTBAN_FETCH_WORKERS", 8),
		GoMaxProcs:        getEnvInt("NFTBAN_GOMAXPROCS", 2),
		CacheDir:          cache,
	}
}

// InitCPU sets GOMAXPROCS based on config
func InitCPU(lim Limits) {
	if lim.GoMaxProcs > 0 {
		runtime.GOMAXPROCS(lim.GoMaxProcs)
	}
}

// WorkerLimit returns the safe worker pool size
func WorkerLimit(desired int, lim Limits) int {
	if desired > lim.FetchWorkers {
		return lim.FetchWorkers
	}
	return desired
}
