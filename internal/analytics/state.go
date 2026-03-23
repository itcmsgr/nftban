// =============================================================================
// NFTBan v1.0 - Analytics State Management
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="state"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="State management for analytics data with persistence"
// meta:inventory.files="/var/lib/nftban/analytics"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package analytics

import (
	"container/list"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/internal/safety"
)

type State struct {
	mu sync.RWMutex

	countries map[string]*CountryStats
	ipOrigins map[string]*IPOrigin

	// LRU eviction for ipOrigins (CWE-400 mitigation)
	ipOriginsLRU *list.List
	maxIPOrigins int
	maxIPsPerCountry int

	analyticsDir string // /var/lib/nftban/analytics
	reportsDir   string // /var/lib/nftban/reports
}

var (
	defaultState     *State
	defaultStateLock sync.Mutex
)

// Init creates directories and loads existing state if present.
// Call once from your main init/bootstrap code.
func Init(libPath string, reportsPath string) error {
	defaultStateLock.Lock()
	defer defaultStateLock.Unlock()

	if libPath == "" {
		return errors.New("analytics: libPath is empty")
	}
	if reportsPath == "" {
		return errors.New("analytics: reportsPath is empty")
	}

	analyticsDir := filepath.Join(libPath, "analytics")

	if err := os.MkdirAll(analyticsDir, 0o755); err != nil {
		return err
	}
	if err := os.MkdirAll(reportsPath, 0o755); err != nil {
		return err
	}

	limits := safety.GetMemoryLimits()

	st := &State{
		countries:        make(map[string]*CountryStats),
		ipOrigins:        make(map[string]*IPOrigin),
		ipOriginsLRU:     list.New(),
		maxIPOrigins:     limits.AnalyticsMaxIPOrigins,
		maxIPsPerCountry: limits.AnalyticsMaxIPsPerCountry,
		analyticsDir:     analyticsDir,
		reportsDir:       reportsPath,
	}

	if err := st.loadIfExists(); err != nil {
		return err
	}

	defaultState = st
	return nil
}

// StateOrNil returns the global state (if Init succeeded).
func StateOrNil() *State {
	defaultStateLock.Lock()
	defer defaultStateLock.Unlock()
	return defaultState
}

// loadIfExists loads country-bans.json and ip-origins.json if they exist.
func (s *State) loadIfExists() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	countryPath := filepath.Join(s.analyticsDir, "country-bans.json")
	ipPath := filepath.Join(s.analyticsDir, "ip-origins.json")

	// Countries
	if data, err := os.ReadFile(countryPath); err == nil {
		var m map[string]*CountryStats
		if err := json.Unmarshal(data, &m); err != nil {
			return err
		}
		// Migrate: convert IPs slice to IPSet map for O(1) lookups
		for _, cs := range m {
			if cs.IPSet == nil {
				cs.IPSet = make(map[string]struct{})
			}
			for _, ip := range cs.IPs {
				if len(cs.IPSet) < s.maxIPsPerCountry {
					cs.IPSet[ip] = struct{}{}
				}
			}
			// Clear legacy IPs slice to save memory
			cs.IPs = nil
			cs.IPCount = len(cs.IPSet)
		}
		s.countries = m
	}

	// IP origins - load with LRU and cap
	if data, err := os.ReadFile(ipPath); err == nil {
		var m map[string]*IPOrigin
		if err := json.Unmarshal(data, &m); err != nil {
			return err
		}

		// Convert to slice, sort by BannedAt (oldest first), and load with cap
		origins := make([]*IPOrigin, 0, len(m))
		for _, o := range m {
			origins = append(origins, o)
		}
		sort.Slice(origins, func(i, j int) bool {
			return origins[i].BannedAt.Before(origins[j].BannedAt)
		})

		// Load most recent entries up to cap
		startIdx := 0
		if len(origins) > s.maxIPOrigins {
			startIdx = len(origins) - s.maxIPOrigins
		}
		for i := startIdx; i < len(origins); i++ {
			o := origins[i]
			s.ipOrigins[o.IP] = o
			o.lruElement = s.ipOriginsLRU.PushFront(o.IP)
		}
	}

	return nil
}

// RecordBan updates in-memory stats (call this for each ban).
// Parameters:
//   ip       - IP address being banned
//   country  - Country code (GeoIP)
//   city     - City name (GeoIP)
//   source   - Ban source: "suricata", "login-monitor", "manual", "feeds", or legacy jail name
//   reason   - Ban reason/description
//   t        - Timestamp
func (s *State) RecordBan(ip, country, city, source, reason string, t time.Time) {
	if s == nil {
		return
	}
	if country == "" {
		country = "UNK"
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	// Per-country stats with O(1) dedup using map
	cs := s.countries[country]
	if cs == nil {
		cs = &CountryStats{
			Country: country,
			IPSet:   make(map[string]struct{}),
		}
		s.countries[country] = cs
	}

	// O(1) dedup check instead of O(n) containsString
	if _, exists := cs.IPSet[ip]; !exists {
		// Cap per-country IPs
		if len(cs.IPSet) < s.maxIPsPerCountry {
			cs.IPSet[ip] = struct{}{}
			cs.IPCount = len(cs.IPSet)
		}
	}
	cs.LastUpdated = t

	// Parse source to determine service (dynamic from reason/source)
	service := extractServiceFromReason(reason, source)

	// Per-IP origin with LRU eviction
	if existing, exists := s.ipOrigins[ip]; exists {
		// Update existing entry, touch LRU
		existing.BannedAt = t
		existing.Source = source
		existing.Service = service
		existing.Reason = reason
		if existing.lruElement != nil {
			s.ipOriginsLRU.MoveToFront(existing.lruElement)
		}
	} else {
		// Evict oldest if at capacity
		if len(s.ipOrigins) >= s.maxIPOrigins {
			s.evictOldestIPOrigin()
		}

		origin := &IPOrigin{
			IP:       ip,
			Country:  country,
			City:     city,
			BannedAt: t,
			Jail:     source,   // Legacy compatibility
			Source:   source,   // New: suricata, login-monitor, manual, feeds
			Service:  service,  // New: Dynamic service extracted from reason
			Reason:   reason,
			Duration: 0,        // TODO: Add duration parameter if needed
		}
		s.ipOrigins[ip] = origin
		origin.lruElement = s.ipOriginsLRU.PushFront(ip)
	}
}

// evictOldestIPOrigin removes the oldest (least recently used) IP origin
func (s *State) evictOldestIPOrigin() {
	if s.ipOriginsLRU.Len() == 0 {
		return
	}
	oldest := s.ipOriginsLRU.Back()
	if oldest != nil {
		if ip, ok := oldest.Value.(string); ok {
			if origin, exists := s.ipOrigins[ip]; exists {
				// Also remove from country stats
				if origin.Country != "" {
					if cs, ok := s.countries[origin.Country]; ok {
						delete(cs.IPSet, ip)
						cs.IPCount = len(cs.IPSet)
					}
				}
				delete(s.ipOrigins, ip)
			}
			s.ipOriginsLRU.Remove(oldest)
		}
	}
}

// extractServiceFromReason extracts service name from ban reason dynamically.
// Parses the reason string to identify the service/filter that triggered the ban.
//
// Logic:
//   1. If reason contains "_" (e.g., "ssh_brute_force"), extract first part
//   2. If reason contains keywords, match against them
//   3. Fallback to source-based classification
//
// Examples:
//   "ssh_brute_force" -> "ssh"
//   "wordpress_attack" -> "wordpress"
//   "malware_c2" -> "malware"
//   "ET MALWARE Zeus" -> "malware"
//   "suricata:scan" -> "scan"
func extractServiceFromReason(reason, source string) string {
	if reason == "" {
		return extractServiceFromSource(source)
	}

	reasonLower := strings.ToLower(reason)

	// Pattern 1: service_action format (e.g., "ssh_brute_force")
	if strings.Contains(reasonLower, "_") {
		parts := strings.SplitN(reasonLower, "_", 2)
		if len(parts) > 0 && parts[0] != "" {
			return parts[0]
		}
	}

	// Pattern 2: source:service format (e.g., "suricata:malware")
	if strings.Contains(reasonLower, ":") {
		parts := strings.SplitN(reasonLower, ":", 2)
		if len(parts) > 1 && parts[1] != "" {
			return parts[1]
		}
	}

	// Pattern 3: Keyword matching (works with ET rules, descriptions, etc.)
	// Common keywords from Suricata signatures and filter names
	keywords := []string{
		"malware", "trojan", "botnet", "c2", "c&c",
		"ssh", "http", "https", "web",
		"wordpress", "wp-", "xmlrpc",
		"mail", "smtp", "imap", "pop3",
		"dns", "scan", "probe", "nmap",
		"exploit", "cve", "shellcode",
		"ddos", "flood", "amplification",
		"brute", "bruteforce", "auth",
		"sql", "xss", "rfi", "lfi",
		"ftp", "rdp", "mysql", "postgresql",
		"phpmyadmin", "joomla", "drupal",
		"smb", "cifs", "ldap", "voip",
	}

	for _, keyword := range keywords {
		if strings.Contains(reasonLower, keyword) {
			return keyword
		}
	}

	// Fallback to source-based classification
	return extractServiceFromSource(source)
}

// extractServiceFromSource returns a service based on the ban source.
func extractServiceFromSource(source string) string {
	switch source {
	case "suricata":
		return "ids"
	case "login-monitor":
		return "auth"
	case "feeds":
		return "reputation"
	case "manual":
		return "manual"
	default:
		// Legacy fail2ban jail names
		return source
	}
}

// Save flushes analytics state to JSON files on disk.
func (s *State) Save() error {
	if s == nil {
		return nil
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	// Prepare countries for serialization (convert IPSet back to IPs slice)
	countriesForSave := make(map[string]*CountryStats, len(s.countries))
	for k, cs := range s.countries {
		csCopy := *cs
		csCopy.IPs = make([]string, 0, len(cs.IPSet))
		for ip := range cs.IPSet {
			csCopy.IPs = append(csCopy.IPs, ip)
		}
		csCopy.IPSet = nil // Don't serialize the map
		countriesForSave[k] = &csCopy
	}

	if err := writeJSONAtomic(filepath.Join(s.analyticsDir, "country-bans.json"), countriesForSave); err != nil {
		return err
	}
	if err := writeJSONAtomic(filepath.Join(s.analyticsDir, "ip-origins.json"), s.ipOrigins); err != nil {
		return err
	}
	return nil
}

// SnapshotDaily writes a daily country snapshot into reports dir.
// Typically called once per day (via cron or internal scheduler).
func (s *State) SnapshotDaily(t time.Time) error {
	if s == nil {
		return nil
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	date := t.Format("2006-01-02")
	path := filepath.Join(s.reportsDir, date+"-country-stats.json")
	return writeJSONAtomic(path, s.countries)
}

// GetCountryStats returns a shallow copy of the map for read-only usage.
func (s *State) GetCountryStats() map[string]*CountryStats {
	if s == nil {
		return nil
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	out := make(map[string]*CountryStats, len(s.countries))
	for k, v := range s.countries {
		// shallow copy
		cpy := *v
		out[k] = &cpy
	}
	return out
}

// GetIPOrigin returns origin info for an IP, if known.
func (s *State) GetIPOrigin(ip string) (*IPOrigin, bool) {
	if s == nil {
		return nil, false
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	o, ok := s.ipOrigins[ip]
	if !ok {
		return nil, false
	}
	// copy to avoid external mutation
	cpy := *o
	return &cpy, true
}

// GetTopCountries returns top N countries by IP count.
func (s *State) GetTopCountries(n int) []CountryStats {
	if s == nil {
		return nil
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	var list []CountryStats
	for _, cs := range s.countries {
		list = append(list, *cs)
	}

	// Sort by IP count descending
	sort.Slice(list, func(i, j int) bool {
		return list[i].IPCount > list[j].IPCount
	})

	if n > 0 && n < len(list) {
		list = list[:n]
	}

	return list
}

// GetSummary returns a complete analytics summary for JSON output.
func (s *State) GetSummary() *AnalyticsSummary {
	if s == nil {
		return &AnalyticsSummary{
			Success:        false,
			TotalIPs:       0,
			TotalCountries: 0,
			Countries:      make(map[string]*CountryStats),
			LastUpdated:    time.Time{},
		}
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	var lastUpdated time.Time
	totalIPs := len(s.ipOrigins)

	for _, cs := range s.countries {
		if cs.LastUpdated.After(lastUpdated) {
			lastUpdated = cs.LastUpdated
		}
	}

	return &AnalyticsSummary{
		Success:        true,
		TotalIPs:       totalIPs,
		TotalCountries: len(s.countries),
		Countries:      s.GetCountryStats(),
		LastUpdated:    lastUpdated,
	}
}

// GetStats returns memory usage statistics for monitoring
func (s *State) GetStats() map[string]int {
	if s == nil {
		return nil
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	totalCountryIPs := 0
	for _, cs := range s.countries {
		totalCountryIPs += len(cs.IPSet)
	}

	return map[string]int{
		"ip_origins":          len(s.ipOrigins),
		"max_ip_origins":      s.maxIPOrigins,
		"countries":           len(s.countries),
		"total_country_ips":   totalCountryIPs,
		"max_ips_per_country": s.maxIPsPerCountry,
		"lru_size":            s.ipOriginsLRU.Len(),
	}
}

// writeJSONAtomic writes JSON atomically using temp file + rename.
func writeJSONAtomic(path string, v any) error {
	tmp := path + ".tmp"

	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	enc := json.NewEncoder(f)
	enc.SetIndent("", "  ")
	if err := enc.Encode(v); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
