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
	"os"
	"path/filepath"
	"strings"
)

// ConfigDir is the base config directory. Overridable for testing.
var ConfigDir = "/etc/nftban"

// evaluateModuleHealth evaluates all modules and returns the health map.
// Called from ValidateKernel after structural + runtime checks.
func evaluateModuleHealth(doc *RulesetDocument, svcState ServiceState) ModuleHealthMap {
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

	// Runtime axis: daemon required for BotGuard
	if svcState.Nftband == RuntimeRunning {
		h.Runtime = RuntimeRunning
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
		if countSetElements(doc, "ip", s) > 0 {
			h.Effective = EffectiveEnforcing
			return h
		}
	}

	// Check observation sets (suspect, pending)
	observationSets := []string{"http_bot_suspect", "http_bot_pending"}
	for _, s := range observationSets {
		if countSetElements(doc, "ip", s) > 0 {
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

	// Structural axis: 4 required chains
	ddosChains := []string{"ddos_sanity", "ddos_penalty", "ddos_prefix", "ddos_protection"}
	allPresent := true
	for _, c := range ddosChains {
		if !doc.ChainExists("ip", "nftban", c) {
			allPresent = false
			break
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

	if doc.ChainExists("ip", "nftban", "portscan_detection") {
		h.Structural = StructuralPresent
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

	// Runtime: daemon required
	if svcState.Nftband == RuntimeRunning {
		h.Runtime = RuntimeRunning
	} else {
		h.Runtime = svcState.Nftband
	}

	// Effective: would need journal query for login_failed/banned events.
	// The validator is a point-in-time snapshot tool — journal queries are
	// outside its current scope. Default to idle.
	h.Effective = EffectiveIdle

	return h
}

// =============================================================================
// Blacklist — unified: manual + feeds + geoban
// =============================================================================

func evaluateBlacklist(doc *RulesetDocument) *BlacklistHealth {
	bh := &BlacklistHealth{}

	// Manual blacklist
	manualElements := countSetElements(doc, "ip", "blacklist_manual_ipv4")
	// We don't have counter values from doc (counters are in the raw ruleset
	// but not currently extracted to RulesetDocument). For now, use element
	// count as the primary evidence.
	if manualElements > 0 {
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
		// Feed files exist → data pipeline is configured.
		// We cannot distinguish feed-originated elements from geoban-originated
		// in the shared blacklist_ipv4 set (per M81-3 shared counter rule).
		// Report as LOADED if feeds are configured, regardless of set element count.
		bh.Feeds = BlacklistSubHealth{State: "loaded"}
	}

	// Geoban
	geoEnabled := readConfigBool("conf.d/geoban/main.conf.local", "conf.d/geoban/main.conf", "GEOBAN_ENABLED")
	if geoEnabled == ConfigDisabled {
		bh.Geoban = BlacklistSubHealth{State: "disabled"}
	} else {
		// Check if geoip database exists.
		// Per M81-3 contract: enabled + DB missing = DEGRADED (not just stale).
		// Stale = DB exists but older than 45 days (future: check mtime).
		dbPath := "/var/cache/nftban/geoban/dbip-country-lite.mmdb"
		info, err := os.Stat(dbPath)
		if err != nil || info.Size() == 0 {
			bh.Geoban = BlacklistSubHealth{State: "degraded"} // missing or empty = DEGRADED
		} else {
			// DB exists. Future: check mtime > 45 days → "stale".
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
	data, err := os.ReadFile(path)
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
// NOTE: nft -j list ruleset does NOT include set elements in its output
// (only set metadata: name, type, flags). Actual element counting requires
// a separate `nft -j list set <family> <table> <name>` command per set,
// which is expensive and outside the current single-command validator model.
//
// For now, this returns 0. BotGuard enforcement evidence and blacklist
// element counting require per-set queries which are a Day 2+ enhancement.
// The validator's current evidence model handles this correctly:
// - zero = NEUTRAL per vocabulary Rule 1
// - BotGuard defaults to IDLE (not DEGRADED)
// - manual blacklist defaults to IDLE (not false PRIMED)
//
// Future: add targeted set queries for enforcement-critical sets only.
func countSetElements(_ *RulesetDocument, _, _ string) int {
	return 0
}
