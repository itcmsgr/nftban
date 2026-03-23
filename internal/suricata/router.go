// =============================================================================
// NFTBan - Suricata Alert Router
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="router"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-02-08"
// meta:description="Deterministic priority-based alert routing for Suricata events"
// meta:input="Suricata EVE JSON events"
// meta:output="Module routing decisions with reasons"
// meta:depends="os,strings,sync,time"
// meta:inventory.files="/etc/nftban/suricata/routing.conf"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/suricata/routing.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package suricata

import (
	"container/list"
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// RouterConfig holds routing configuration
type RouterConfig struct {
	Enabled bool

	// Priority levels per module (higher number = higher priority)
	Priorities map[string]int

	// Deduplication TTL in seconds
	DedupTTL int

	// DDoS rate gate settings
	DDosRateGateThreshold int
	DDosRateGateWindow    int
}

// RateGateConfig holds rate gate configuration for a module
type RateGateConfig struct {
	MinEvents int // Minimum events per IP
	WindowSec int // Time window in seconds
}

// ScoreCapConfig holds score cap configuration for a module
type ScoreCapConfig struct {
	MaxScore  int // Maximum score per window
	WindowSec int // Time window in seconds
}

// TiebreakRule represents a tiebreak rule
type TiebreakRule struct {
	Conditions []TiebreakCondition
	Winner     string
}

// TiebreakCondition represents a single condition in a tiebreak rule
type TiebreakCondition struct {
	Type  string // "dest_port", "keyword", "category", "rate_gate"
	Value string // The value to match
}

// Router handles deterministic priority-based alert routing
type Router struct {
	mu sync.RWMutex

	// Configuration
	config RouterConfig

	// SID override map (SID -> module)
	sidOverrides map[int]string

	// Category map (normalized category pattern -> module)
	categoryMap map[string]string

	// Service port map (port -> module)
	servicePorts map[int]string

	// Keyword map (module -> keywords)
	keywords map[string][]string

	// Tiebreak rules
	tiebreakRules []TiebreakRule

	// Rate gate thresholds (module -> config)
	rateGates map[string]RateGateConfig

	// Score caps (module -> config)
	scoreCaps map[string]ScoreCapConfig

	// Rate gate tracking (srcIP -> timestamps)
	rateGateEvents    map[string]*list.List
	rateGateMaxEvents int

	// Deduplication
	dedupEnabled  bool
	dedupFields   []string
	dedupTTL      int
	dedupMaxSize  int
	dedupCache    map[string]time.Time
	dedupLRU      *list.List
	dedupElements map[string]*list.Element
}

// NewRouter creates a new Router with default configuration
func NewRouter() *Router {
	return &Router{
		config: RouterConfig{
			Enabled:    true,
			Priorities: make(map[string]int),
		},
		sidOverrides:      make(map[int]string),
		categoryMap:       make(map[string]string),
		servicePorts:      make(map[int]string),
		keywords:          make(map[string][]string),
		tiebreakRules:     make([]TiebreakRule, 0),
		rateGates:         make(map[string]RateGateConfig),
		scoreCaps:         make(map[string]ScoreCapConfig),
		rateGateEvents:    make(map[string]*list.List),
		rateGateMaxEvents: 10000,
		dedupEnabled:      true,
		dedupFields:       []string{"timestamp", "src_ip", "dest_ip", "src_port", "dest_port", "signature_id", "proto"},
		dedupTTL:          3600,
		dedupMaxSize:      100000,
		dedupCache:        make(map[string]time.Time),
		dedupLRU:          list.New(),
		dedupElements:     make(map[string]*list.Element),
	}
}

// NormalizeCategory normalizes a Suricata category string for matching
// - Lowercase
// - Trim whitespace
// - Replace spaces/underscores with hyphens
// Example: "Attempted Administrator Privilege Gain" -> "attempted-administrator-privilege-gain"
func NormalizeCategory(category string) string {
	// Lowercase
	result := strings.ToLower(category)

	// Trim whitespace
	result = strings.TrimSpace(result)

	// Replace spaces and underscores with hyphens
	result = strings.ReplaceAll(result, " ", "-")
	result = strings.ReplaceAll(result, "_", "-")

	// Collapse multiple hyphens
	for strings.Contains(result, "--") {
		result = strings.ReplaceAll(result, "--", "-")
	}

	// Trim leading/trailing hyphens
	result = strings.Trim(result, "-")

	return result
}

// Route determines which module should handle an event
// Returns the winning module and a reason string for logging
//
// Routing precedence (highest to lowest):
//  1. SID overrides (explicit SID -> module mapping)
//  2. Category mapping (normalized category -> module)
//  3. Service/port constraints (proto + dest_port -> module)
//  4. Keyword patterns (substring matching)
//  5. Apply tiebreak rules if multiple matches
//  6. Apply priority arbitration (ddos > portscan > login > other)
func (r *Router) Route(event *Event) (module string, reason string) {
	r.mu.RLock()
	defer r.mu.RUnlock()

	if !r.config.Enabled {
		return "", "routing disabled"
	}

	// Track all matches for tie-breaking
	matches := make(map[string]string) // module -> reason

	// 1. Check SID override first (highest precedence)
	if targetModule, ok := r.sidOverrides[event.SignatureID]; ok {
		return targetModule, fmt.Sprintf("sid_override:%d", event.SignatureID)
	}

	// 2. Check category map (normalized, contains/prefix match)
	normalizedCategory := NormalizeCategory(event.Category)
	for pattern, targetModule := range r.categoryMap {
		if strings.Contains(normalizedCategory, pattern) || strings.HasPrefix(normalizedCategory, pattern) {
			matches[targetModule] = fmt.Sprintf("category:%s", pattern)
		}
	}

	// If exactly one category match and no higher precedence, return it
	if len(matches) == 1 {
		for mod, rsn := range matches {
			return mod, rsn
		}
	}

	// 3. Check service/port context
	if targetModule, ok := r.servicePorts[event.DestPort]; ok {
		portReason := fmt.Sprintf("service_port:%d", event.DestPort)
		matches[targetModule] = portReason
	}

	// 4. Check keyword patterns
	sigLower := strings.ToLower(event.Signature)
	catLower := strings.ToLower(event.Category)
	combined := sigLower + " " + catLower

	for targetModule, moduleKeywords := range r.keywords {
		for _, kw := range moduleKeywords {
			if strings.Contains(combined, kw) {
				if _, exists := matches[targetModule]; !exists {
					matches[targetModule] = fmt.Sprintf("keyword:%s", kw)
				}
				break // Found one keyword for this module, move on
			}
		}
	}

	// If no matches at all, return empty
	if len(matches) == 0 {
		return "", "no_match"
	}

	// If exactly one match, return it
	if len(matches) == 1 {
		for mod, rsn := range matches {
			return mod, rsn
		}
	}

	// 5. Apply tiebreak rules if multiple matches
	matchedModules := make([]string, 0, len(matches))
	for mod := range matches {
		matchedModules = append(matchedModules, mod)
	}

	tiebreakWinner := r.applyTiebreakRules(event, matchedModules)
	if tiebreakWinner != "" {
		return tiebreakWinner, fmt.Sprintf("tiebreak:%s->%s", matches[tiebreakWinner], tiebreakWinner)
	}

	// 6. Apply priority arbitration (ddos > portscan > login > other)
	highestPriority := -1
	var winner string
	var winnerReason string

	for mod, rsn := range matches {
		priority := r.config.Priorities[mod]
		if priority > highestPriority {
			highestPriority = priority
			winner = mod
			winnerReason = rsn
		}
	}

	if winner != "" {
		return winner, fmt.Sprintf("priority:%s", winnerReason)
	}

	// Fallback: return first match (should not happen)
	for mod, rsn := range matches {
		return mod, rsn
	}

	return "", "no_match"
}

// applyTiebreakRules checks tiebreak rules and returns the winning module
func (r *Router) applyTiebreakRules(event *Event, matchedModules []string) string {
	for _, rule := range r.tiebreakRules {
		allConditionsMet := true

		for _, cond := range rule.Conditions {
			switch cond.Type {
			case "dest_port":
				port, err := strconv.Atoi(cond.Value)
				if err != nil || event.DestPort != port {
					allConditionsMet = false
				}
			case "keyword":
				sigLower := strings.ToLower(event.Signature)
				catLower := strings.ToLower(event.Category)
				combined := sigLower + " " + catLower
				if !strings.Contains(combined, cond.Value) {
					allConditionsMet = false
				}
			case "category":
				normalizedCat := NormalizeCategory(event.Category)
				if !strings.Contains(normalizedCat, cond.Value) {
					allConditionsMet = false
				}
			case "rate_gate":
				// rate_gate:true or rate_gate:false
				rateGateMet := r.checkRateGateLocked("ddos", event.SrcIP)
				expected := cond.Value == "true"
				if rateGateMet != expected {
					allConditionsMet = false
				}
			}

			if !allConditionsMet {
				break
			}
		}

		// Check if winner is in matched modules
		if allConditionsMet {
			for _, mod := range matchedModules {
				if mod == rule.Winner {
					return rule.Winner
				}
			}
			// Winner might not be in matches, but rule can still force it
			return rule.Winner
		}
	}

	return ""
}

// CheckRateGate checks if an event meets the rate threshold for a module
// Returns true if the event meets the threshold (enough events in window)
// For example, DDoS requires 10 events from same IP in 10 seconds
func (r *Router) CheckRateGate(module string, srcIP string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()

	return r.checkRateGateLocked(module, srcIP)
}

// checkRateGateLocked checks rate gate without acquiring lock (caller must hold lock)
func (r *Router) checkRateGateLocked(module string, srcIP string) bool {
	config, ok := r.rateGates[module]
	if !ok {
		// No rate gate for this module, always passes
		return true
	}

	events, ok := r.rateGateEvents[srcIP]
	if !ok {
		return false // No events yet, doesn't meet threshold
	}

	// Count events in window
	cutoff := time.Now().Add(-time.Duration(config.WindowSec) * time.Second)
	count := 0

	// Iterate from back (oldest) and remove expired entries
	for e := events.Back(); e != nil; {
		prev := e.Prev()
		if ts, ok := e.Value.(time.Time); ok {
			if ts.Before(cutoff) {
				events.Remove(e)
			} else {
				count++
			}
		}
		e = prev
	}

	return count >= config.MinEvents
}

// RecordEvent records an event for rate gate tracking
func (r *Router) RecordEvent(srcIP string, timestamp time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()

	events, ok := r.rateGateEvents[srcIP]
	if !ok {
		events = list.New()
		r.rateGateEvents[srcIP] = events
	}

	// Add event timestamp
	events.PushFront(timestamp)

	// Limit events per IP
	for events.Len() > 100 {
		events.Remove(events.Back())
	}

	// Limit total tracked IPs
	if len(r.rateGateEvents) > r.rateGateMaxEvents {
		// Simple eviction: remove a random IP (not optimal but simple)
		for ip := range r.rateGateEvents {
			if ip != srcIP {
				delete(r.rateGateEvents, ip)
				break
			}
		}
	}
}

// IsDuplicate checks if an event has been seen before
func (r *Router) IsDuplicate(event *Event) bool {
	if !r.dedupEnabled {
		return false
	}

	r.mu.Lock()
	defer r.mu.Unlock()

	// Generate event ID from configured fields
	eventID := r.generateEventID(event)

	// Check cache
	if expiry, ok := r.dedupCache[eventID]; ok {
		if time.Now().Before(expiry) {
			return true // Still valid, is duplicate
		}
		// Expired, remove from cache
		r.removeDedupEntry(eventID)
	}

	// Not a duplicate, add to cache
	r.addDedupEntry(eventID)

	return false
}

// generateEventID generates a unique ID for deduplication
func (r *Router) generateEventID(event *Event) string {
	parts := make([]string, 0, len(r.dedupFields))

	for _, field := range r.dedupFields {
		switch field {
		case "timestamp":
			// Use second precision for dedup
			parts = append(parts, event.Timestamp.Truncate(time.Second).Format(time.RFC3339))
		case "src_ip":
			parts = append(parts, event.SrcIP)
		case "dest_ip":
			parts = append(parts, event.DestIP)
		case "src_port":
			parts = append(parts, strconv.Itoa(event.SrcPort))
		case "dest_port":
			parts = append(parts, strconv.Itoa(event.DestPort))
		case "signature_id":
			parts = append(parts, strconv.Itoa(event.SignatureID))
		case "proto":
			parts = append(parts, event.Proto)
		}
	}

	return strings.Join(parts, "|")
}

// addDedupEntry adds an entry to the dedup cache with LRU eviction
func (r *Router) addDedupEntry(eventID string) {
	// Evict if at capacity
	for len(r.dedupCache) >= r.dedupMaxSize {
		oldest := r.dedupLRU.Back()
		if oldest == nil {
			break
		}
		if id, ok := oldest.Value.(string); ok {
			r.removeDedupEntry(id)
		}
	}

	// Add new entry
	expiry := time.Now().Add(time.Duration(r.dedupTTL) * time.Second)
	r.dedupCache[eventID] = expiry
	elem := r.dedupLRU.PushFront(eventID)
	r.dedupElements[eventID] = elem
}

// removeDedupEntry removes an entry from the dedup cache
func (r *Router) removeDedupEntry(eventID string) {
	delete(r.dedupCache, eventID)
	if elem, ok := r.dedupElements[eventID]; ok {
		r.dedupLRU.Remove(elem)
		delete(r.dedupElements, eventID)
	}
}

// GetStats returns router statistics
func (r *Router) GetStats() map[string]interface{} {
	r.mu.RLock()
	defer r.mu.RUnlock()

	return map[string]interface{}{
		"enabled":           r.config.Enabled,
		"sid_overrides":     len(r.sidOverrides),
		"category_mappings": len(r.categoryMap),
		"service_ports":     len(r.servicePorts),
		"keyword_modules":   len(r.keywords),
		"tiebreak_rules":    len(r.tiebreakRules),
		"rate_gate_ips":     len(r.rateGateEvents),
		"dedup_cache_size":  len(r.dedupCache),
	}
}

// LoadRoutingConfig loads routing configuration from a file
func LoadRoutingConfig(configPath string) (*Router, error) {
	router := NewRouter()

	data, err := os.ReadFile(configPath)
	if err != nil {
		if os.IsNotExist(err) {
			// Return default router if config doesn't exist
			return router, nil
		}
		return nil, fmt.Errorf("failed to read routing config: %w", err)
	}

	if err := router.parseConfig(string(data)); err != nil {
		return nil, fmt.Errorf("failed to parse routing config: %w", err)
	}

	return router, nil
}

// parseConfig parses the routing configuration
func (r *Router) parseConfig(data string) error {
	lines := strings.Split(data, "\n")
	var currentSection string

	for lineNum, line := range lines {
		line = strings.TrimSpace(line)

		// Skip comments and empty lines
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		// Section headers
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			currentSection = strings.Trim(line, "[]")
			continue
		}

		// Key-value pairs
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}

		key := strings.TrimSpace(parts[0])
		value := strings.TrimSpace(parts[1])

		switch currentSection {
		case "global":
			r.parseGlobalSetting(key, value)
		case "sid_override":
			if err := r.parseSIDOverride(key, value); err != nil {
				fmt.Fprintf(os.Stderr, "Warning: routing.conf:%d: %v\n", lineNum+1, err)
			}
		case "category_map":
			r.categoryMap[key] = value
		case "service_ports":
			if err := r.parseServicePort(key, value); err != nil {
				fmt.Fprintf(os.Stderr, "Warning: routing.conf:%d: %v\n", lineNum+1, err)
			}
		case "keywords":
			r.parseKeywords(key, value)
		case "tiebreak":
			if err := r.parseTiebreakRule(key, value); err != nil {
				fmt.Fprintf(os.Stderr, "Warning: routing.conf:%d: %v\n", lineNum+1, err)
			}
		case "rate_gate":
			if err := r.parseRateGate(key, value); err != nil {
				fmt.Fprintf(os.Stderr, "Warning: routing.conf:%d: %v\n", lineNum+1, err)
			}
		case "score_cap":
			if err := r.parseScoreCap(key, value); err != nil {
				fmt.Fprintf(os.Stderr, "Warning: routing.conf:%d: %v\n", lineNum+1, err)
			}
		case "dedup":
			r.parseDedupSetting(key, value)
		}
	}

	return nil
}

// parseGlobalSetting parses a global configuration setting
func (r *Router) parseGlobalSetting(key, value string) {
	switch key {
	case "enabled":
		r.config.Enabled = (value == "true" || value == "yes" || value == "1")
	case "dedup_ttl":
		if val, err := strconv.Atoi(value); err == nil {
			r.config.DedupTTL = val
			r.dedupTTL = val
		}
	case "ddos_rate_gate_threshold":
		if val, err := strconv.Atoi(value); err == nil {
			r.config.DDosRateGateThreshold = val
		}
	case "ddos_rate_gate_window":
		if val, err := strconv.Atoi(value); err == nil {
			r.config.DDosRateGateWindow = val
		}
	default:
		// Check for priority_* settings
		if strings.HasPrefix(key, "priority_") {
			module := strings.TrimPrefix(key, "priority_")
			if val, err := strconv.Atoi(value); err == nil {
				r.config.Priorities[module] = val
			}
		}
	}
}

// parseSIDOverride parses a SID override entry
func (r *Router) parseSIDOverride(key, value string) error {
	sid, err := strconv.Atoi(key)
	if err != nil {
		return fmt.Errorf("invalid SID '%s': %w", key, err)
	}
	r.sidOverrides[sid] = value
	return nil
}

// parseServicePort parses a service port entry
func (r *Router) parseServicePort(key, value string) error {
	port, err := strconv.Atoi(key)
	if err != nil {
		return fmt.Errorf("invalid port '%s': %w", key, err)
	}
	r.servicePorts[port] = value
	return nil
}

// parseKeywords parses a keywords entry
func (r *Router) parseKeywords(module, keywordsStr string) {
	keywords := make([]string, 0)
	for _, kw := range strings.Split(keywordsStr, ",") {
		kw = strings.TrimSpace(kw)
		if kw != "" {
			keywords = append(keywords, strings.ToLower(kw))
		}
	}
	r.keywords[module] = keywords
}

// parseTiebreakRule parses a tiebreak rule entry
// Format: condition1+condition2+... = winner_module
// Conditions: dest_port:22, keyword:brute, category:dos, rate_gate:false
func (r *Router) parseTiebreakRule(conditionsStr, winner string) error {
	conditionParts := strings.Split(conditionsStr, "+")
	conditions := make([]TiebreakCondition, 0, len(conditionParts))

	for _, part := range conditionParts {
		part = strings.TrimSpace(part)
		colonIdx := strings.Index(part, ":")
		if colonIdx == -1 {
			return fmt.Errorf("invalid tiebreak condition '%s' (expected type:value)", part)
		}

		condType := part[:colonIdx]
		condValue := part[colonIdx+1:]

		conditions = append(conditions, TiebreakCondition{
			Type:  condType,
			Value: strings.ToLower(condValue),
		})
	}

	r.tiebreakRules = append(r.tiebreakRules, TiebreakRule{
		Conditions: conditions,
		Winner:     winner,
	})

	return nil
}

// parseRateGate parses a rate gate entry
// Format: module = min_events:window_seconds
func (r *Router) parseRateGate(module, value string) error {
	parts := strings.Split(value, ":")
	if len(parts) != 2 {
		return fmt.Errorf("invalid rate_gate format '%s' (expected min_events:window_seconds)", value)
	}

	minEvents, err := strconv.Atoi(parts[0])
	if err != nil {
		return fmt.Errorf("invalid min_events '%s': %w", parts[0], err)
	}

	windowSec, err := strconv.Atoi(parts[1])
	if err != nil {
		return fmt.Errorf("invalid window_seconds '%s': %w", parts[1], err)
	}

	r.rateGates[module] = RateGateConfig{
		MinEvents: minEvents,
		WindowSec: windowSec,
	}

	return nil
}

// parseScoreCap parses a score cap entry
// Format: module = max_score:window_seconds
func (r *Router) parseScoreCap(module, value string) error {
	parts := strings.Split(value, ":")
	if len(parts) != 2 {
		return fmt.Errorf("invalid score_cap format '%s' (expected max_score:window_seconds)", value)
	}

	maxScore, err := strconv.Atoi(parts[0])
	if err != nil {
		return fmt.Errorf("invalid max_score '%s': %w", parts[0], err)
	}

	windowSec, err := strconv.Atoi(parts[1])
	if err != nil {
		return fmt.Errorf("invalid window_seconds '%s': %w", parts[1], err)
	}

	r.scoreCaps[module] = ScoreCapConfig{
		MaxScore:  maxScore,
		WindowSec: windowSec,
	}

	return nil
}

// parseDedupSetting parses a deduplication setting
func (r *Router) parseDedupSetting(key, value string) {
	switch key {
	case "enabled":
		r.dedupEnabled = (value == "true" || value == "yes" || value == "1")
	case "event_id_fields":
		fields := make([]string, 0)
		for _, f := range strings.Split(value, ",") {
			f = strings.TrimSpace(f)
			if f != "" {
				fields = append(fields, f)
			}
		}
		r.dedupFields = fields
	case "ttl":
		if val, err := strconv.Atoi(value); err == nil {
			r.dedupTTL = val
		}
	case "max_events":
		if val, err := strconv.Atoi(value); err == nil {
			r.dedupMaxSize = val
		}
	}
}

// GetScoreCap returns the score cap configuration for a module
func (r *Router) GetScoreCap(module string) (ScoreCapConfig, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()

	config, ok := r.scoreCaps[module]
	return config, ok
}

// GetRateGate returns the rate gate configuration for a module
func (r *Router) GetRateGate(module string) (RateGateConfig, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()

	config, ok := r.rateGates[module]
	return config, ok
}

// GetPriority returns the priority for a module
func (r *Router) GetPriority(module string) int {
	r.mu.RLock()
	defer r.mu.RUnlock()

	return r.config.Priorities[module]
}

// IsEnabled returns whether routing is enabled
func (r *Router) IsEnabled() bool {
	r.mu.RLock()
	defer r.mu.RUnlock()

	return r.config.Enabled
}

// CleanupExpired cleans up expired rate gate events and dedup cache entries
func (r *Router) CleanupExpired() {
	r.mu.Lock()
	defer r.mu.Unlock()

	now := time.Now()

	// Cleanup expired dedup entries
	for eventID, expiry := range r.dedupCache {
		if now.After(expiry) {
			r.removeDedupEntry(eventID)
		}
	}

	// Cleanup empty rate gate entries
	for ip, events := range r.rateGateEvents {
		if events.Len() == 0 {
			delete(r.rateGateEvents, ip)
		}
	}
}
