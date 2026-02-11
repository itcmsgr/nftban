// =============================================================================
// NFTBan - Safety Limits Configuration
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="limits"
// meta:type="package"
// meta:version="1.0.0"
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
	"encoding/json"
	"fmt"
	"os"
	"runtime"
	"runtime/debug"
	"strconv"
	"time"
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

// CIDR loading limits to prevent memory exhaustion
const (
	// MaxCIDRsWarning is the threshold for warning users about large CIDR sets
	MaxCIDRsWarning = 50000

	// BytesPerCIDREstimate is the estimated memory per CIDR during merge operations
	// Includes string storage + parsing + temporary merge buffers
	BytesPerCIDREstimate = 300

	// BanAgeThresholdDays is how long a permanent ban must be inactive before eviction
	BanAgeThresholdDays = 30
)

// GetMaxCIDRsHard returns the dynamic CIDR limit based on server tier
// Small servers (≤4GB): 75,000 max CIDRs
// Medium servers (4-8GB): 100,000 max CIDRs
// Large servers (>8GB): 150,000 max CIDRs
func GetMaxCIDRsHard() int {
	profile := DetectServerProfile()
	const GB = 1024 * 1024 * 1024

	switch {
	case profile.TotalRAM <= 4*GB:
		return 75000 // Small servers: conservative limit
	case profile.TotalRAM <= 8*GB:
		return 100000 // Medium servers: standard limit
	default:
		return 150000 // Large servers: higher limit
	}
}

// GetMaxCIDRsHardWithTier returns both the limit and tier name for logging
func GetMaxCIDRsHardWithTier() (limit int, tier string) {
	profile := DetectServerProfile()
	const GB = 1024 * 1024 * 1024

	switch {
	case profile.TotalRAM <= 4*GB:
		return 75000, "small"
	case profile.TotalRAM <= 8*GB:
		return 100000, "medium"
	default:
		return 150000, "large"
	}
}

// CIDRLoadResult describes the result of ValidateCIDRLoad
type CIDRLoadResult struct {
	Allowed      bool   // Whether to proceed with loading
	Warning      bool   // Whether to show a warning
	Message      string // Human-readable message
	EstimatedMem int64  // Estimated memory usage in bytes
}

// ValidateCIDRLoad checks if loading the given number of CIDRs is safe
// Returns result with recommendation and warning message if applicable
func ValidateCIDRLoad(ipv4Count, ipv6Count int) CIDRLoadResult {
	totalCount := ipv4Count + ipv6Count
	estimatedMem := int64(totalCount) * BytesPerCIDREstimate

	// Dynamic hard limit based on server tier
	maxCIDRs := GetMaxCIDRsHard()

	// Hard limit check
	if totalCount > maxCIDRs {
		return CIDRLoadResult{
			Allowed:      false,
			Warning:      true,
			Message:      fmt.Sprintf("CIDR count %d exceeds maximum limit of %d for this server. This would require ~%s memory and could crash the daemon.", totalCount, maxCIDRs, FormatBytes(estimatedMem)),
			EstimatedMem: estimatedMem,
		}
	}

	// Memory availability check
	if !CanAllocate(estimatedMem) {
		mem := AvailableMem()
		return CIDRLoadResult{
			Allowed:      false,
			Warning:      true,
			Message:      fmt.Sprintf("Insufficient memory for %d CIDRs. Need ~%s, available ~%s. Consider reducing geoban countries or disabling some feeds.", totalCount, FormatBytes(estimatedMem), FormatBytes(mem.Avail)),
			EstimatedMem: estimatedMem,
		}
	}

	// Warning threshold check
	if totalCount > MaxCIDRsWarning {
		return CIDRLoadResult{
			Allowed:      true,
			Warning:      true,
			Message:      fmt.Sprintf("Loading %d CIDRs (>%d). This will use ~%s memory and may take several minutes.", totalCount, MaxCIDRsWarning, FormatBytes(estimatedMem)),
			EstimatedMem: estimatedMem,
		}
	}

	// All clear
	return CIDRLoadResult{
		Allowed:      true,
		Warning:      false,
		Message:      "",
		EstimatedMem: estimatedMem,
	}
}

// =============================================================================
// Protection State Tracking
// =============================================================================
// Records when memory protection triggered to skip feeds/geoban
// This allows health checks and CLI to show protection status

const (
	// ProtectionStateDir is where protection state is stored
	ProtectionStateDir = "/var/lib/nftban/state"
	// ProtectionStateFile is the protection state JSON file
	ProtectionStateFile = "/var/lib/nftban/state/protection.json"
)

// ProtectionState tracks what was skipped due to memory limits
type ProtectionState struct {
	Timestamp       string `json:"timestamp"`
	FeedsSkipped    bool   `json:"feeds_skipped"`
	GeobanSkipped   bool   `json:"geoban_skipped"`
	FeedsCIDRCount  int    `json:"feeds_cidr_count,omitempty"`
	GeobanCIDRCount int    `json:"geoban_cidr_count,omitempty"`
	FeedsMemNeeded  int64  `json:"feeds_mem_needed,omitempty"`
	GeobanMemNeeded int64  `json:"geoban_mem_needed,omitempty"`
	AvailableMemory int64  `json:"available_memory"`
	Reason          string `json:"reason"`
}

// RecordProtectionTriggered writes protection state when feeds or geoban are skipped
func RecordProtectionTriggered(feedsSkipped bool, geobanSkipped bool, feedsCIDRs int, geobanCIDRs int, feedsMem int64, geobanMem int64) error {
	// Create state directory if needed
	if err := os.MkdirAll(ProtectionStateDir, 0755); err != nil {
		return err
	}

	mem := AvailableMem()

	reason := "Insufficient memory"
	if feedsSkipped && geobanSkipped {
		reason = "Memory protection: skipped feeds and geoban to prevent crash"
	} else if feedsSkipped {
		reason = "Memory protection: skipped feeds to prevent crash"
	} else if geobanSkipped {
		reason = "Memory protection: skipped geoban to prevent crash"
	}

	state := ProtectionState{
		Timestamp:       time.Now().Format(time.RFC3339),
		FeedsSkipped:    feedsSkipped,
		GeobanSkipped:   geobanSkipped,
		FeedsCIDRCount:  feedsCIDRs,
		GeobanCIDRCount: geobanCIDRs,
		FeedsMemNeeded:  feedsMem,
		GeobanMemNeeded: geobanMem,
		AvailableMemory: mem.Avail,
		Reason:          reason,
	}

	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}

	return os.WriteFile(ProtectionStateFile, data, 0644)
}

// ClearProtectionState removes protection state (called when sync succeeds fully)
func ClearProtectionState() error {
	if _, err := os.Stat(ProtectionStateFile); os.IsNotExist(err) {
		return nil // Already cleared
	}
	return os.Remove(ProtectionStateFile)
}

// GetProtectionState reads current protection state
func GetProtectionState() (*ProtectionState, error) {
	data, err := os.ReadFile(ProtectionStateFile)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil // No protection state = OK
		}
		return nil, err
	}

	var state ProtectionState
	if err := json.Unmarshal(data, &state); err != nil {
		return nil, err
	}

	return &state, nil
}

// IsProtectionActive returns true if memory protection is currently active
func IsProtectionActive() bool {
	state, err := GetProtectionState()
	if err != nil || state == nil {
		return false
	}
	return state.FeedsSkipped || state.GeobanSkipped
}

// GetProtectionSummary returns a human-readable protection status
func GetProtectionSummary() string {
	state, err := GetProtectionState()
	if err != nil || state == nil {
		return ""
	}

	if state.FeedsSkipped && state.GeobanSkipped {
		return fmt.Sprintf("Feeds+Geoban skipped (need %s, have %s)",
			FormatBytes(state.FeedsMemNeeded+state.GeobanMemNeeded),
			FormatBytes(state.AvailableMemory))
	} else if state.FeedsSkipped {
		return fmt.Sprintf("Feeds skipped (%d CIDRs, need %s)",
			state.FeedsCIDRCount, FormatBytes(state.FeedsMemNeeded))
	} else if state.GeobanSkipped {
		return fmt.Sprintf("Geoban skipped (%d CIDRs, need %s)",
			state.GeobanCIDRCount, FormatBytes(state.GeobanMemNeeded))
	}
	return ""
}

// =============================================================================
// CIDR Filter State Tracking
// =============================================================================
// Records CIDR filter statistics for metrics export and visibility

const (
	// FilterStateFile is the CIDR filter state JSON file
	FilterStateFile = "/var/lib/nftban/state/filter.json"
)

// FilterState tracks CIDR filtering statistics from the last sync
type FilterState struct {
	Timestamp    string `json:"timestamp"`
	Total        int    `json:"total"`         // Total input CIDRs
	Filtered     int    `json:"filtered"`      // CIDRs removed by filtering
	BogonCount   int    `json:"bogon_count"`   // Bogon/reserved ranges removed
	OversizeCount int   `json:"oversize_count"` // Oversized CIDRs removed (< /9)
	Kept         int    `json:"kept"`          // CIDRs that passed filtering
}

// RecordFilterState writes CIDR filter statistics after sync
func RecordFilterState(total, filtered, bogon, oversize, kept int) error {
	// Create state directory if needed
	if err := os.MkdirAll(ProtectionStateDir, 0755); err != nil {
		return err
	}

	state := FilterState{
		Timestamp:     time.Now().Format(time.RFC3339),
		Total:         total,
		Filtered:      filtered,
		BogonCount:    bogon,
		OversizeCount: oversize,
		Kept:          kept,
	}

	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}

	return os.WriteFile(FilterStateFile, data, 0644)
}

// GetFilterState reads current CIDR filter state
func GetFilterState() (*FilterState, error) {
	data, err := os.ReadFile(FilterStateFile)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil // No filter state yet
		}
		return nil, err
	}

	var state FilterState
	if err := json.Unmarshal(data, &state); err != nil {
		return nil, err
	}

	return &state, nil
}

// =============================================================================
// Memory Pressure Levels
// =============================================================================

// PressureLevel represents the current memory pressure state
type PressureLevel int

const (
	// PressureNormal - below 70% of memory budget, full operations
	PressureNormal PressureLevel = iota
	// PressureWarning - 70-85% of budget, log warning but continue
	PressureWarning
	// PressureHigh - 85-95% of budget, skip geoban refresh
	PressureHigh
	// PressureCritical - >95% of budget, trim cold bans + skip feeds
	PressureCritical
)

// String returns the pressure level name
func (p PressureLevel) String() string {
	switch p {
	case PressureNormal:
		return "normal"
	case PressureWarning:
		return "warning"
	case PressureHigh:
		return "high"
	case PressureCritical:
		return "critical"
	default:
		return "unknown"
	}
}

// GetMemoryPressureLevel returns the current memory pressure level
func GetMemoryPressureLevel() PressureLevel {
	mem := AvailableMem()
	budget, _ := GetResourceLimits()

	if budget <= 0 || mem.Avail <= 0 {
		return PressureNormal // Can't determine, assume normal
	}

	// Calculate usage percentage relative to budget
	// Note: We estimate current daemon memory usage from available memory
	usedEstimate := budget - mem.Avail
	if usedEstimate < 0 {
		usedEstimate = 0
	}

	usagePct := float64(usedEstimate) / float64(budget) * 100

	switch {
	case usagePct >= 95:
		return PressureCritical
	case usagePct >= 85:
		return PressureHigh
	case usagePct >= 70:
		return PressureWarning
	default:
		return PressureNormal
	}
}

// ShouldSkipGeoban returns true if memory pressure is too high for geoban
func ShouldSkipGeoban() bool {
	level := GetMemoryPressureLevel()
	return level >= PressureHigh
}

// ShouldSkipFeeds returns true if memory pressure is critical
func ShouldSkipFeeds() bool {
	level := GetMemoryPressureLevel()
	return level >= PressureCritical
}

// =============================================================================
// Permanent Ban Management
// =============================================================================

const (
	// PermanentBansDir is where permanent ban tracking is stored
	PermanentBansDir = "/var/lib/nftban/state"
	// PermanentBansFile tracks permanent bans with metadata
	PermanentBansFile = "/var/lib/nftban/state/permanent_bans.json"
)

// PermanentBan represents a permanent ban with tracking metadata
type PermanentBan struct {
	IP        string    `json:"ip"`
	AddedAt   time.Time `json:"added_at"`
	Reason    string    `json:"reason,omitempty"`
	Source    string    `json:"source,omitempty"`
	Protected bool      `json:"protected"` // If true, NEVER evict this IP
}

// PermanentBansState holds all tracked permanent bans
type PermanentBansState struct {
	UpdatedAt time.Time                `json:"updated_at"`
	Bans      map[string]*PermanentBan `json:"bans"` // keyed by IP
}

// LoadPermanentBans loads the permanent bans state from disk
func LoadPermanentBans() (*PermanentBansState, error) {
	data, err := os.ReadFile(PermanentBansFile)
	if err != nil {
		if os.IsNotExist(err) {
			// Return empty state
			return &PermanentBansState{
				UpdatedAt: time.Now(),
				Bans:      make(map[string]*PermanentBan),
			}, nil
		}
		return nil, err
	}

	var state PermanentBansState
	if err := json.Unmarshal(data, &state); err != nil {
		return nil, err
	}

	if state.Bans == nil {
		state.Bans = make(map[string]*PermanentBan)
	}

	return &state, nil
}

// SavePermanentBans saves the permanent bans state to disk
func SavePermanentBans(state *PermanentBansState) error {
	if err := os.MkdirAll(PermanentBansDir, 0755); err != nil {
		return err
	}

	state.UpdatedAt = time.Now()

	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}

	return os.WriteFile(PermanentBansFile, data, 0644)
}

// TrackPermanentBan adds or updates a permanent ban in tracking
func TrackPermanentBan(ip, reason, source string, protected bool) error {
	state, err := LoadPermanentBans()
	if err != nil {
		return err
	}

	// Check if already exists
	if existing, ok := state.Bans[ip]; ok {
		// Update reason/source but preserve original added_at and protected status
		if reason != "" {
			existing.Reason = reason
		}
		if source != "" {
			existing.Source = source
		}
		// Only upgrade to protected, never downgrade
		if protected {
			existing.Protected = true
		}
	} else {
		// Add new
		state.Bans[ip] = &PermanentBan{
			IP:        ip,
			AddedAt:   time.Now(),
			Reason:    reason,
			Source:    source,
			Protected: protected,
		}
	}

	return SavePermanentBans(state)
}

// SetBanProtected sets the protected flag for a permanent ban
func SetBanProtected(ip string, protected bool) error {
	state, err := LoadPermanentBans()
	if err != nil {
		return err
	}

	if ban, ok := state.Bans[ip]; ok {
		ban.Protected = protected
		return SavePermanentBans(state)
	}

	return fmt.Errorf("IP %s not found in permanent bans", ip)
}

// RemovePermanentBan removes a ban from tracking
func RemovePermanentBan(ip string) error {
	state, err := LoadPermanentBans()
	if err != nil {
		return err
	}

	delete(state.Bans, ip)
	return SavePermanentBans(state)
}

// GetEvictableBans returns IPs that can be evicted (old, unprotected)
// Returns at most maxCount IPs, oldest first
func GetEvictableBans(maxCount int) ([]string, error) {
	state, err := LoadPermanentBans()
	if err != nil {
		return nil, err
	}

	threshold := time.Now().AddDate(0, 0, -BanAgeThresholdDays)

	// Collect evictable bans (old + unprotected)
	type banAge struct {
		ip    string
		added time.Time
	}
	var candidates []banAge

	for ip, ban := range state.Bans {
		if ban.Protected {
			continue // Never evict protected bans
		}
		if ban.AddedAt.Before(threshold) {
			candidates = append(candidates, banAge{ip: ip, added: ban.AddedAt})
		}
	}

	// Sort by age (oldest first)
	for i := 0; i < len(candidates); i++ {
		for j := i + 1; j < len(candidates); j++ {
			if candidates[j].added.Before(candidates[i].added) {
				candidates[i], candidates[j] = candidates[j], candidates[i]
			}
		}
	}

	// Return at most maxCount
	result := make([]string, 0, maxCount)
	for i := 0; i < len(candidates) && i < maxCount; i++ {
		result = append(result, candidates[i].ip)
	}

	return result, nil
}

// GetPermanentBanStats returns stats about permanent bans
func GetPermanentBanStats() (total, protected, evictable int, err error) {
	state, err := LoadPermanentBans()
	if err != nil {
		return 0, 0, 0, err
	}

	threshold := time.Now().AddDate(0, 0, -BanAgeThresholdDays)

	for _, ban := range state.Bans {
		total++
		if ban.Protected {
			protected++
		} else if ban.AddedAt.Before(threshold) {
			evictable++
		}
	}

	return total, protected, evictable, nil
}
