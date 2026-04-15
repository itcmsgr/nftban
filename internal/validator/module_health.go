// =============================================================================
// NFTBan v1.81 - Module Health Evaluator
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="module_health"
// meta:type="lib"
// meta:version="1.81.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Per-module 4-axis health evaluation per M81-4 HEALTH_METRIC_DERIVATION_v1.81.md"
// meta:inventory.files="internal/validator/module_health.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="conf.d/botguard/main.conf,conf.d/ddos/main.conf,conf.d/portscan/main.conf,conf.d/login_alert.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
//
// This evaluator implements the truth tables from HEALTH_METRIC_DERIVATION_v1.81.md.
// It MUST NOT invent derivation logic outside that specification.
// All state values are vocabulary-approved terms from NFTBAN_VOCABULARY_REFERENCE_v1.81.md.
// =============================================================================
package validator

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// ConfigDir is the base config directory. Overridable for testing.
var ConfigDir = "/etc/nftban"

// evaluateModuleHealth evaluates all modules and returns the health map.
// Called from ValidateKernel after structural + runtime checks.
// evaluateModuleHealth evaluates all modules and returns the health map.
// Also populates moduleFindings with any module-specific findings.
// The caller MUST append moduleFindings to result.Findings after this call.
func evaluateModuleHealth(doc *RulesetDocument, svcState ServiceState) ModuleHealthMap {
	moduleFindings = nil // reset for this evaluation cycle
	m := ModuleHealthMap{}

	m.BotGuard = evaluateBotGuard(doc, svcState)
	m.DDoS = evaluateDDoS(doc)
	m.Portscan = evaluatePortscan(doc)
	m.LoginMon = evaluateLoginMon(svcState)
	m.Blacklist = evaluateBlacklist(doc)

	return m
}

// =============================================================================
// BotGuard — daemon-dependent, set-based evidence
// =============================================================================

func evaluateBotGuard(doc *RulesetDocument, svcState ServiceState) *ModuleHealth {
	h := &ModuleHealth{}

	// Config axis
	h.Config = readConfigBool("conf.d/botguard/main.conf.local", "conf.d/botguard/main.conf", "HTTP_BOTGUARD_ENABLED")
	if h.Config == ConfigDisabled {
		return h // disabled → skip all other axes
	}

	// Structural axis: 6 sets + chain per family.
	// Per M81 Rule 9 (per-family aggregation): check each active family.
	// IPv4 is always checked. IPv6 checked only if ip6 nftban table exists.
	bgSetsV4 := []string{"http_bot_suspect", "http_bot_pending", "http_bot_allow",
		"http_bot_grey", "http_bot_ban", "http_bot_emergency"}
	bgSetsV6 := []string{"http_bot_suspect6", "http_bot_pending6", "http_bot_allow6",
		"http_bot_grey6", "http_bot_ban6", "http_bot_emergency6"}

	v4Present := true
	for _, s := range bgSetsV4 {
		if !doc.SetExists("ip", "nftban", s) {
			v4Present = false
			break
		}
	}
	v4Present = v4Present && doc.ChainExists("ip", "nftban", "http_bot_guard")

	// IPv6: only required if ip6 nftban table exists
	v6Required := doc.TableExists("ip6", "nftban")
	v6Present := true
	if v6Required {
		for _, s := range bgSetsV6 {
			if !doc.SetExists("ip6", "nftban", s) {
				v6Present = false
				break
			}
		}
		v6Present = v6Present && doc.ChainExists("ip6", "nftban", "http_bot_guard")
	}

	if v4Present && (!v6Required || v6Present) {
		h.Structural = StructuralPresent
	} else {
		h.Structural = StructuralMissing
	}

	// Runtime axis: daemon required for BotGuard.
	// A1-2: Refine with journal evidence — daemon running is necessary but
	// not sufficient. Check journal for BotGuard module registration.
	// If daemon is running but no BotGuard startup evidence in journal,
	// runtime is still RUNNING (daemon is up), but we emit an informational
	// finding. This does NOT downgrade runtime — it adds visibility.
	if svcState.Nftband == RuntimeRunning {
		h.Runtime = RuntimeRunning
		// Check for BotGuard module registration in recent journal
		evidence := queryJournal(context.Background(), JournalQuery{
			Patterns: []string{"module_start: botguard", "[botguard] loaded"},
			Since:    15 * time.Minute,
		})
		if evidence.ErrKind == ErrNone && !evidence.Found {
			// Daemon running but no recent BotGuard startup evidence.
			// This may indicate the module hasn't restarted recently (normal)
			// or the module failed to register (abnormal). Not a downgrade.
			// Only emit finding if structural objects exist (module should be active).
			if h.Structural == StructuralPresent {
				moduleFindings = append(moduleFindings, Finding{
					Code:      CodeBotGuardNoEvidence,
					Severity:  SeverityInfo,
					Component: "module",
					Message:   "no recent BotGuard runtime evidence in journal (last 15m)",
				})
			}
		}
	} else {
		h.Runtime = svcState.Nftband
	}

	// Effective axis: set population as evidence
	if h.Structural == StructuralMissing || h.Runtime != RuntimeRunning {
		// Cannot determine effective state without structure + runtime
		h.Effective = EffectiveIdle
		return h
	}

	// Check enforcement sets (ban, grey, emergency)
	enforcementSets := []string{"http_bot_ban", "http_bot_grey", "http_bot_emergency"}
	for _, s := range enforcementSets {
		if countSetElements("ip", s) > 0 {
			h.Effective = EffectiveEnforcing
			return h
		}
	}

	// Check observation sets (suspect, pending)
	observationSets := []string{"http_bot_suspect", "http_bot_pending"}
	for _, s := range observationSets {
		if countSetElements("ip", s) > 0 {
			h.Effective = EffectiveObserving
			return h
		}
	}

	// All sets empty → idle (valid per BUG-3 lesson)
	h.Effective = EffectiveIdle
	return h
}

// =============================================================================
// DDoS — kernel-only enforcement, daemon NOT required
// =============================================================================

func evaluateDDoS(doc *RulesetDocument) *ModuleHealth {
	h := &ModuleHealth{}

	// Config axis
	h.Config = readConfigBool("conf.d/ddos/main.conf.local", "conf.d/ddos/main.conf", "DDOS_ENABLED")

	// Structural axis: 4 required chains in IPv4.
	// GAP-D1: Also check IPv6 if ip6 table exists — DDoS chains should
	// be present in both families for full dual-stack protection.
	ddosChains := []string{"ddos_sanity", "ddos_penalty", "ddos_prefix", "ddos_protection"}
	allPresent := true
	for _, c := range ddosChains {
		if !doc.ChainExists("ip", "nftban", c) {
			allPresent = false
			break
		}
	}
	// Check IPv6 if table exists
	if allPresent && doc.TableExists("ip6", "nftban") {
		for _, c := range ddosChains {
			if !doc.ChainExists("ip6", "nftban", c) {
				allPresent = false
				break
			}
		}
	}
	if allPresent {
		h.Structural = StructuralPresent
	} else {
		h.Structural = StructuralMissing
	}

	// Runtime: not required for DDoS (kernel-only enforcement)
	// Omit from output

	// Effective axis: check DDoS enforcement counters from kernel.
	// Per M81-3 DDoS contract: each counter is PRIMARY ENFORCEMENT evidence.
	// Any counter > 0 = ENFORCING. All zero = IDLE (neutral).
	if h.Structural == StructuralPresent {
		ddosCounters := []string{
			"input_ct_ssh_drop",
			"input_ct_http_drop",
			"input_ct_mail_drop",
			"input_syn_rate_exceeded",
		}
		enforcing := false
		for _, name := range ddosCounters {
			if doc.GetCounter("ip", "nftban", name) > 0 {
				enforcing = true
				break
			}
		}
		// Also check IPv6 SYN prefix counter
		if !enforcing && doc.GetCounter("ip6", "nftban", "input_syn_prefix_drop") > 0 {
			enforcing = true
		}

		if enforcing {
			h.Effective = EffectiveEnforcing
		} else {
			h.Effective = EffectiveIdle // zero = NEUTRAL per vocabulary Rule 1
		}
	}

	return h
}

// =============================================================================
// Portscan — kernel-only, no counter evidence available
// =============================================================================

func evaluatePortscan(doc *RulesetDocument) *ModuleHealth {
	h := &ModuleHealth{}

	h.Config = readConfigBool("conf.d/portscan/main.conf.local", "conf.d/portscan/main.conf", "PORTSCAN_ENABLED")

	// GAP-P1: Check both IPv4 and IPv6 (if ip6 table exists).
	if doc.ChainExists("ip", "nftban", "portscan_detection") {
		if doc.TableExists("ip6", "nftban") && !doc.ChainExists("ip6", "nftban", "portscan_detection") {
			h.Structural = StructuralMissing // IPv4 present but IPv6 missing
		} else {
			h.Structural = StructuralPresent
		}
	} else {
		h.Structural = StructuralMissing
	}

	// Portscan has no dedicated counter — effective state is always IDLE
	// from the validator's perspective. Real enforcement evidence requires
	// kernel log parsing which is outside the validator's scope (M81-7 gap).
	h.Effective = EffectiveIdle

	return h
}

// =============================================================================
// LoginMon — daemon-dependent, no dedicated kernel objects
// =============================================================================

func evaluateLoginMon(svcState ServiceState) *ModuleHealth {
	h := &ModuleHealth{}

	h.Config = readConfigBool("conf.d/login_alert.conf.local", "conf.d/login_alert.conf", "NFTBAN_LOGIN_ALERT_ENABLED")
	if h.Config == ConfigDisabled {
		return h
	}

	// Structural: LoginMon has no dedicated kernel objects.
	// Its presence is proven by runtime evidence (daemon + bindings).
	// Base blacklist sets are always present (required by base schema).
	h.Structural = StructuralPresent

	// Runtime: daemon required.
	// A1-3: Refine with journal evidence — check for module registration
	// AND source binding. LoginMon runtime is meaningful only when sources
	// are actually bound (path resolution succeeded).
	if svcState.Nftband == RuntimeRunning {
		h.Runtime = RuntimeRunning
		// Check for LoginMon module registration AND source binding.
		// Both must be present — module_start alone proves the module loaded,
		// but sources must be bound for LoginMon to actually process events.
		// Two separate queries with AND semantics (not OR).
		regEvidence := queryJournal(context.Background(), JournalQuery{
			Patterns: []string{"module_start: loginmon"},
			Since:    15 * time.Minute,
		})
		bindEvidence := queryJournal(context.Background(), JournalQuery{
			Patterns: []string{"resolved_by="},
			Since:    15 * time.Minute,
		})
		// Only emit finding when both queries succeeded (no error) and
		// at least one required evidence is missing.
		regOK := regEvidence.ErrKind == ErrNone
		bindOK := bindEvidence.ErrKind == ErrNone
		if regOK && bindOK && (!regEvidence.Found || !bindEvidence.Found) {
			moduleFindings = append(moduleFindings, Finding{
				Code:      CodeLoginMonNoEvidence,
				Severity:  SeverityInfo,
				Component: "module",
				Message:   "no recent LoginMon runtime + source-binding evidence in journal (last 15m)",
			})
		}
	} else {
		h.Runtime = svcState.Nftband
	}

	// Effective: LoginMon enforcement is through shared blacklist sets.
	// Journal-based evidence (login_failed/banned events) could prove
	// activity but counter attribution is not possible (shared set).
	// Default to idle from validator perspective.
	h.Effective = EffectiveIdle

	return h
}

// =============================================================================
// Blacklist — unified: manual + feeds + geoban
// =============================================================================

// ModuleFindings collects findings from module health evaluation.
// These are appended to the main ValidationResult.Findings by the caller.
var moduleFindings []Finding

func evaluateBlacklist(doc *RulesetDocument) *BlacklistHealth {
	bh := &BlacklistHealth{}

	// Manual blacklist
	// GAP-BL1 fix: Read dedicated counter to distinguish ENFORCING from PRIMED.
	// input_blacklist_manual_drop is a dedicated counter for manual bans
	// (shared with LoginMon + portscan bans that land in the same set).
	// elements > 0 + drops > 0 = ENFORCING (traffic is being blocked)
	// elements > 0 + drops = 0 = PRIMED (rules loaded, no matches yet)
	// elements = 0 = IDLE
	// v1.85 GAP-185-9: Count both IPv4 and IPv6 manual blacklist elements.
	manualElements := countSetElements("ip", "blacklist_manual_ipv4")
	manualElements += countSetElements("ip6", "blacklist_manual_ipv6")
	// Counter: check both families
	manualDrops := doc.GetCounter("ip", "nftban", "input_blacklist_manual_drop")
	manualDrops += doc.GetCounter("ip6", "nftban", "input_blacklist_manual_drop")
	if manualElements > 0 && manualDrops > 0 {
		bh.Manual = BlacklistSubHealth{State: "enforcing", Entries: manualElements, Drops: manualDrops}
	} else if manualElements > 0 {
		bh.Manual = BlacklistSubHealth{State: "primed", Entries: manualElements}
	} else {
		bh.Manual = BlacklistSubHealth{State: "idle", Entries: 0}
	}

	// Feeds: per M81-3 contract, feeds configured + data available = LOADED
	// (not ACTIVE — feeds are data pipeline, not traffic processing).
	// Feeds share blacklist_ipv4 with geoban so element count is shared.
	feedsConfigured := feedsExist()
	if !feedsConfigured {
		bh.Feeds = BlacklistSubHealth{State: "disabled"}
	} else {
		// Feed config exists → check data freshness.
		// GAP-BL5: Check feed data directory for actual downloaded data.
		// If no data files or all data > 7 days old → stale sync.
		feedDataDir := "/var/lib/nftban/feeds"
		feedFresh := feedDataIsFresh(feedDataDir, 7*24*time.Hour)
		if feedFresh {
			bh.Feeds = BlacklistSubHealth{State: "loaded"}
		} else {
			bh.Feeds = BlacklistSubHealth{State: "stale"}
		}
	}

	// Geoban
	geoEnabled := readConfigBool("conf.d/geoban/main.conf.local", "conf.d/geoban/main.conf", "GEOBAN_ENABLED")
	if geoEnabled == ConfigDisabled {
		bh.Geoban = BlacklistSubHealth{State: "disabled"}
	} else {
		// Check if geoip database exists.
		// Per M81-3 contract: enabled + DB missing = DEGRADED (not just stale).
		// Stale = DB exists but older than 45 days (future: check mtime).
		// Per CF-2 resolution: geoban DB missing uses "stale" (in allowed enum)
		// and emits a finding for visibility. "degraded" is not in the blacklist
		// sub-state enum (enforcing|primed|idle|loaded|stale|disabled).
		dbPath := "/var/cache/nftban/geoban/dbip-country-lite.mmdb"
		info, err := os.Stat(dbPath)
		if err != nil || info.Size() == 0 {
			bh.Geoban = BlacklistSubHealth{State: "stale"} // missing DB = stale data
			moduleFindings = append(moduleFindings, Finding{
				Code:        CodeGeobanDBMissing,
				Severity:    SeverityWarn,
				Component:   "module",
				Message:     "GeoIP database missing or empty — geoban enforcement unavailable",
				Remediation: "Run: nftban geoban sync",
			})
		} else if time.Since(info.ModTime()) > 45*24*time.Hour {
			// GAP-BL3: DB exists but older than 45 days → stale data
			bh.Geoban = BlacklistSubHealth{State: "stale"}
			moduleFindings = append(moduleFindings, Finding{
				Code:        CodeGeobanDBMissing,
				Severity:    SeverityWarn,
				Component:   "module",
				Message:     "GeoIP database older than 45 days — data may be inaccurate",
				Remediation: "Run: nftban geoban sync",
			})
		} else {
			bh.Geoban = BlacklistSubHealth{State: "loaded"}
		}
	}

	return bh
}

// =============================================================================
// Config helpers
// =============================================================================

// readConfigBool reads a boolean config key from .local then base conf.
// Returns ConfigEnabled if key="true", ConfigDisabled otherwise.
func readConfigBool(localPath, basePath, key string) ConfigState {
	// Try .local first
	if val := readKeyFromFile(filepath.Join(ConfigDir, localPath), key); val != "" {
		if val == "true" {
			return ConfigEnabled
		}
		return ConfigDisabled
	}
	// Fallback to base
	if val := readKeyFromFile(filepath.Join(ConfigDir, basePath), key); val != "" {
		if val == "true" {
			return ConfigEnabled
		}
	}
	return ConfigDisabled
}

// readKeyFromFile reads a KEY="value" line from a shell config file.
func readKeyFromFile(path, key string) string {
	data, err := os.ReadFile(path) // #nosec G304 — path is constructed from hardcoded ConfigDir + known config filenames, not user input
	if err != nil {
		return ""
	}
	prefix := key + "="
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, prefix) {
			val := strings.TrimPrefix(line, prefix)
			val = strings.Trim(val, "\"'")
			return val
		}
	}
	return ""
}

// feedDataIsFresh checks if the feed data directory has files newer than maxAge.
// GAP-BL5: detects stale feed sync (no data or old data = sync not working).
func feedDataIsFresh(dir string, maxAge time.Duration) bool {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return false // no data directory = not fresh
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		if time.Since(info.ModTime()) < maxAge {
			return true // at least one recent file
		}
	}
	return false // no recent files
}

// feedsExist checks if any feed config files exist.
func feedsExist() bool {
	feedDir := filepath.Join(ConfigDir, "conf.d/feeds")
	entries, err := os.ReadDir(feedDir)
	if err != nil {
		return false
	}
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".conf") {
			return true
		}
	}
	return false
}

// countSetElements returns the number of elements in a kernel set.
//
// countSetElementsFunc is the default implementation for set element queries.
// Tests override this via the function variable (same pattern as
// defaultServiceChecker in validator.go:70).
var countSetElementsFunc = countSetElementsReal

// countSetElements delegates to countSetElementsFunc for testability.
func countSetElements(family, setName string) int {
	return countSetElementsFunc(family, setName)
}

// countSetElementsReal queries the kernel for actual element count in a set.
// v1.82 CF-4: replaces the v1.81 stub that always returned 0.
//
// Uses `nft -j list set <family> <table> <name>` which returns the full
// set including an "elem" array when elements exist. The "elem" key is
// absent when the set is empty (returns 0 in that case).
//
// This is called for enforcement-critical sets only (BotGuard ban/suspect,
// manual blacklist). The cost is one nft command per set query.
func countSetElementsReal(family, setName string) int {
	table := "nftban"
	out, err := exec.Command("nft", "-j", "list", "set", family, table, setName).Output()
	if err != nil {
		return 0
	}

	// Parse JSON: {"nftables": [{"metainfo":...}, {"set": {..., "elem": [...]}}]}
	var result struct {
		Nftables []struct {
			Set *struct {
				Elem []interface{} `json:"elem"`
			} `json:"set,omitempty"`
		} `json:"nftables"`
	}
	if err := json.Unmarshal(out, &result); err != nil {
		return 0
	}

	for _, obj := range result.Nftables {
		if obj.Set != nil {
			return len(obj.Set.Elem)
		}
	}
	return 0
}
