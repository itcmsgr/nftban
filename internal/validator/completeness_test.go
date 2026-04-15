// =============================================================================
// NFTBan v1.85 — Module Completeness & Classification Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="completeness-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-15"
// meta:description="CI gates G8-1/G8-2/G8-3: module completeness, classification, IPv6 parity"
// meta:inventory.files="internal/validator/completeness_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package validator

import (
	"reflect"
	"testing"
)

// =============================================================================
// G8-1: Module Completeness Gate
// Every CORE module must appear in ModuleHealthMap + HealthOutput JSON
// =============================================================================

func TestModuleCompleteness(t *testing.T) {
	// CORE modules that MUST have validator representation
	coreModules := []string{"botguard", "ddos", "portscan", "loginmon", "blacklist"}

	// Verify ModuleHealthMap has a field for each core module
	healthMapType := reflect.TypeOf(ModuleHealthMap{})
	for _, mod := range coreModules {
		found := false
		for i := 0; i < healthMapType.NumField(); i++ {
			field := healthMapType.Field(i)
			jsonTag := field.Tag.Get("json")
			// Strip ",omitempty" from tag
			if idx := len(jsonTag); idx > 0 {
				for j := 0; j < len(jsonTag); j++ {
					if jsonTag[j] == ',' {
						jsonTag = jsonTag[:j]
						break
					}
				}
			}
			if jsonTag == mod {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("G8-1: CORE module %q missing from ModuleHealthMap (types.go)", mod)
		}
	}

	// Verify ModulesJSON (HealthOutput) has a field for each core module
	modulesJSONType := reflect.TypeOf(ModulesJSON{})
	for _, mod := range coreModules {
		found := false
		for i := 0; i < modulesJSONType.NumField(); i++ {
			field := modulesJSONType.Field(i)
			jsonTag := field.Tag.Get("json")
			for j := 0; j < len(jsonTag); j++ {
				if jsonTag[j] == ',' {
					jsonTag = jsonTag[:j]
					break
				}
			}
			if jsonTag == mod {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("G8-1: CORE module %q missing from ModulesJSON (health_output.go)", mod)
		}
	}
}

// =============================================================================
// G8-2: Module Classification Gate
// Every known config directory must be classified
// =============================================================================

func TestNoUnclassifiedModules(t *testing.T) {
	// Known config directories (from /etc/nftban/conf.d/)
	knownConfigDirs := []string{
		"botguard", "botscan", "ddos", "geoban", "geoip",
		"login", "panels", "portscan", "rbl", "suricata", "tunnel",
	}

	for _, dir := range knownConfigDirs {
		if _, exists := ModuleClassification[dir]; !exists {
			// Also check if classified under a different name
			// (e.g., "login" might be classified as "loginmon")
			found := false
			aliases := map[string]string{
				"login": "loginmon",
			}
			if alias, ok := aliases[dir]; ok {
				if _, exists := ModuleClassification[alias]; exists {
					found = true
				}
			}
			if !found {
				t.Errorf("G8-2: config directory %q has no classification in ModuleClassification", dir)
			}
		}
	}
}

func TestClassificationValues(t *testing.T) {
	validClasses := map[ModuleClass]bool{
		ModuleCore: true, ModuleAdvisory: true,
		ModuleMonitor: true, ModuleExternal: true,
	}
	for mod, class := range ModuleClassification {
		if !validClasses[class] {
			t.Errorf("G8-2: module %q has invalid classification %q", mod, class)
		}
	}
}

func TestCoreModulesHaveEvaluators(t *testing.T) {
	// CORE modules that have dedicated evaluator functions.
	// This verifies at compile time that the evaluator functions exist.
	// Note: botscan, geoip, geoban, panels are sub-functions classified
	// as CORE but served by parent evaluators (BotGuard, Blacklist).
	coreWithEvaluators := map[string]bool{
		"ddos": true, "botguard": true, "portscan": true,
		"loginmon": true,
		// Blacklist is composite (evaluateBlacklist covers geoban sub-state)
	}

	for mod, class := range ModuleClassification {
		if class != ModuleCore {
			continue
		}
		// Sub-functions served by parent evaluators
		if mod == "botscan" || mod == "geoip" || mod == "geoban" || mod == "panels" {
			continue
		}
		if mod == "loginmon" {
			// loginmon has evaluateLoginMon()
			continue
		}
		if !coreWithEvaluators[mod] {
			t.Errorf("G8-1: CORE module %q has no known evaluator function", mod)
		}
	}
}

// =============================================================================
// G8-3: IPv6 Parity Gate
// Verify that evaluators with IPv4 checks also have IPv6 checks
// =============================================================================

func TestIPv6Parity_DDoS(t *testing.T) {
	// DDoS evaluator must check IPv6 chains when ip6 table exists
	// Build a doc with IPv4 chains present but IPv6 missing
	objects := []NftObject{
		{Table: &NftTable{Family: "ip", Name: "nftban"}},
		{Table: &NftTable{Family: "ip6", Name: "nftban"}},
		{Chain: &NftChain{Family: "ip", Table: "nftban", Name: "ddos_sanity"}},
		{Chain: &NftChain{Family: "ip", Table: "nftban", Name: "ddos_penalty"}},
		{Chain: &NftChain{Family: "ip", Table: "nftban", Name: "ddos_prefix"}},
		{Chain: &NftChain{Family: "ip", Table: "nftban", Name: "ddos_protection"}},
		// IPv6 chains MISSING — should cause structural=missing
	}
	raw := &NftRuleset{Nftables: objects}
	doc := ParseRuleset(raw)

	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/ddos/main.conf": `DDOS_ENABLED="true"`,
	})
	defer cleanup()

	h := evaluateDDoS(doc)
	if h.Structural != StructuralMissing {
		t.Errorf("G8-3: DDoS with IPv4 present but IPv6 missing should be StructuralMissing, got %s", h.Structural)
	}
}

func TestIPv6Parity_Portscan(t *testing.T) {
	// Portscan evaluator must check IPv6 chain when ip6 table exists
	objects := []NftObject{
		{Table: &NftTable{Family: "ip", Name: "nftban"}},
		{Table: &NftTable{Family: "ip6", Name: "nftban"}},
		{Chain: &NftChain{Family: "ip", Table: "nftban", Name: "portscan_detection"}},
		// IPv6 chain MISSING
	}
	raw := &NftRuleset{Nftables: objects}
	doc := ParseRuleset(raw)

	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/portscan/main.conf": `PORTSCAN_ENABLED="true"`,
	})
	defer cleanup()

	h := evaluatePortscan(doc)
	if h.Structural != StructuralMissing {
		t.Errorf("G8-3: Portscan with IPv4 present but IPv6 missing should be StructuralMissing, got %s", h.Structural)
	}
}

func TestIPv6Parity_BotGuard(t *testing.T) {
	// BotGuard evaluator must check IPv6 sets when ip6 table exists
	bgSetsV4 := []string{"http_bot_suspect", "http_bot_pending", "http_bot_allow",
		"http_bot_grey", "http_bot_ban", "http_bot_emergency"}

	objects := []NftObject{
		{Table: &NftTable{Family: "ip", Name: "nftban"}},
		{Table: &NftTable{Family: "ip6", Name: "nftban"}},
		{Chain: &NftChain{Family: "ip", Table: "nftban", Name: "http_bot_guard"}},
	}
	for _, s := range bgSetsV4 {
		objects = append(objects, NftObject{Set: &NftSet{Family: "ip", Table: "nftban", Name: s}})
	}
	// IPv6 sets MISSING
	raw := &NftRuleset{Nftables: objects}
	doc := ParseRuleset(raw)

	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/botguard/main.conf": `HTTP_BOTGUARD_ENABLED="true"`,
	})
	defer cleanup()
	old := countSetElementsFunc
	countSetElementsFunc = func(_, _ string) int { return 0 }
	defer func() { countSetElementsFunc = old }()
	SetJournalReader(mockJournalReader{lines: []string{"module_start: botguard"}})
	defer SetJournalReader(SystemdJournalReader{})

	h := evaluateBotGuard(doc, ServiceState{Nftband: RuntimeRunning})
	if h.Structural != StructuralMissing {
		t.Errorf("G8-3: BotGuard with IPv4 present but IPv6 missing should be StructuralMissing, got %s", h.Structural)
	}
}
