// =============================================================================
// NFTBan v1.81 - Module Health Evaluator Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="module_health_test"
// meta:type="test"
// meta:version="1.81.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Tests for M81-4 per-module health derivation against truth tables"
// meta:inventory.files="internal/validator/module_health_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package validator

import (
	"os"
	"path/filepath"
	"testing"
)

// setupTestConfig creates a temporary config directory with the given
// config files. Returns cleanup function.
func setupTestConfig(t *testing.T, files map[string]string) func() {
	t.Helper()
	tmpDir := t.TempDir()
	for relPath, content := range files {
		fullPath := filepath.Join(tmpDir, relPath)
		if err := os.MkdirAll(filepath.Dir(fullPath), 0755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(fullPath, []byte(content), 0644); err != nil {
			t.Fatal(err)
		}
	}
	oldConfigDir := ConfigDir
	ConfigDir = tmpDir
	return func() { ConfigDir = oldConfigDir }
}

// buildDoc creates a minimal RulesetDocument with specified objects.
func buildDoc(chains []string, sets []string) *RulesetDocument {
	objects := []NftObject{
		{Table: &NftTable{Family: "ip", Name: "nftban"}},
	}
	for _, c := range chains {
		objects = append(objects, NftObject{Chain: &NftChain{Family: "ip", Table: "nftban", Name: c}})
	}
	for _, s := range sets {
		objects = append(objects, NftObject{Set: &NftSet{Family: "ip", Table: "nftban", Name: s}})
	}
	raw := &NftRuleset{Nftables: objects}
	return ParseRuleset(raw)
}

// =============================================================================
// BotGuard truth table tests
// =============================================================================

func TestBotGuardDisabled(t *testing.T) {
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/botguard/main.conf": `HTTP_BOTGUARD_ENABLED="false"`,
	})
	defer cleanup()

	doc := buildDoc(nil, nil)
	h := evaluateBotGuard(doc, ServiceState{Nftband: RuntimeRunning})

	if h.Config != ConfigDisabled {
		t.Errorf("config = %s, want disabled", h.Config)
	}
	// Disabled modules skip all other axes
	if h.Structural != "" {
		t.Errorf("structural should be empty for disabled module, got %s", h.Structural)
	}
}

func TestBotGuardEnabledPresentIdle(t *testing.T) {
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/botguard/main.conf.local": `HTTP_BOTGUARD_ENABLED="true"`,
	})
	defer cleanup()
	// Mock: all sets empty → idle (per BUG-3 lesson)
	old := countSetElementsFunc
	countSetElementsFunc = func(_, _ string) int { return 0 }
	defer func() { countSetElementsFunc = old }()

	bgSets := []string{"http_bot_suspect", "http_bot_pending", "http_bot_allow",
		"http_bot_grey", "http_bot_ban", "http_bot_emergency"}
	doc := buildDoc([]string{"http_bot_guard"}, bgSets)
	h := evaluateBotGuard(doc, ServiceState{Nftband: RuntimeRunning})

	if h.Config != ConfigEnabled {
		t.Errorf("config = %s, want enabled", h.Config)
	}
	if h.Structural != StructuralPresent {
		t.Errorf("structural = %s, want present", h.Structural)
	}
	if h.Runtime != RuntimeRunning {
		t.Errorf("runtime = %s, want RUNNING", h.Runtime)
	}
	if h.Effective != EffectiveIdle {
		t.Errorf("effective = %s, want idle (all sets empty)", h.Effective)
	}
}

func TestBotGuardEnabledEnforcing(t *testing.T) {
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/botguard/main.conf.local": `HTTP_BOTGUARD_ENABLED="true"`,
	})
	defer cleanup()
	// Mock: ban set has elements → enforcing
	old := countSetElementsFunc
	countSetElementsFunc = func(_, name string) int {
		if name == "http_bot_ban" {
			return 3
		}
		return 0
	}
	defer func() { countSetElementsFunc = old }()

	bgSets := []string{"http_bot_suspect", "http_bot_pending", "http_bot_allow",
		"http_bot_grey", "http_bot_ban", "http_bot_emergency"}
	doc := buildDoc([]string{"http_bot_guard"}, bgSets)
	h := evaluateBotGuard(doc, ServiceState{Nftband: RuntimeRunning})

	if h.Effective != EffectiveEnforcing {
		t.Errorf("effective = %s, want enforcing (ban set > 0)", h.Effective)
	}
}

func TestBotGuardEnabledObserving(t *testing.T) {
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/botguard/main.conf.local": `HTTP_BOTGUARD_ENABLED="true"`,
	})
	defer cleanup()
	// Mock: suspect set has elements, ban set empty → observing
	old := countSetElementsFunc
	countSetElementsFunc = func(_, name string) int {
		if name == "http_bot_suspect" {
			return 5
		}
		return 0
	}
	defer func() { countSetElementsFunc = old }()

	bgSets := []string{"http_bot_suspect", "http_bot_pending", "http_bot_allow",
		"http_bot_grey", "http_bot_ban", "http_bot_emergency"}
	doc := buildDoc([]string{"http_bot_guard"}, bgSets)
	h := evaluateBotGuard(doc, ServiceState{Nftband: RuntimeRunning})

	if h.Effective != EffectiveObserving {
		t.Errorf("effective = %s, want observing (suspect > 0, ban = 0)", h.Effective)
	}
}

func TestBotGuardEnabledMissing(t *testing.T) {
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/botguard/main.conf.local": `HTTP_BOTGUARD_ENABLED="true"`,
	})
	defer cleanup()

	// No BotGuard chain or sets
	doc := buildDoc(nil, nil)
	h := evaluateBotGuard(doc, ServiceState{Nftband: RuntimeRunning})

	if h.Config != ConfigEnabled {
		t.Errorf("config = %s, want enabled", h.Config)
	}
	if h.Structural != StructuralMissing {
		t.Errorf("structural = %s, want missing", h.Structural)
	}
}

func TestBotGuardEnabledDaemonStopped(t *testing.T) {
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/botguard/main.conf.local": `HTTP_BOTGUARD_ENABLED="true"`,
	})
	defer cleanup()

	bgSets := []string{"http_bot_suspect", "http_bot_pending", "http_bot_allow",
		"http_bot_grey", "http_bot_ban", "http_bot_emergency"}
	doc := buildDoc([]string{"http_bot_guard"}, bgSets)
	h := evaluateBotGuard(doc, ServiceState{Nftband: RuntimeStopped, NftbandDetail: "inactive"})

	if h.Runtime != RuntimeStopped {
		t.Errorf("runtime = %s, want STOPPED", h.Runtime)
	}
}

// =============================================================================
// DDoS truth table tests
// =============================================================================

func TestDDoSDisabled(t *testing.T) {
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/ddos/main.conf": `DDOS_ENABLED="false"`,
	})
	defer cleanup()

	doc := buildDoc(nil, nil)
	h := evaluateDDoS(doc)

	if h.Config != ConfigDisabled {
		t.Errorf("config = %s, want disabled", h.Config)
	}
}

func TestDDoSDisabledResidual(t *testing.T) {
	// Disabled in config but chains present (residual state per Rule 8)
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/ddos/main.conf": `DDOS_ENABLED="false"`,
	})
	defer cleanup()

	chains := []string{"ddos_sanity", "ddos_penalty", "ddos_prefix", "ddos_protection"}
	doc := buildDoc(chains, nil)
	h := evaluateDDoS(doc)

	if h.Config != ConfigDisabled {
		t.Errorf("config = %s, want disabled", h.Config)
	}
	if h.Structural != StructuralPresent {
		t.Errorf("structural = %s, want present (residual)", h.Structural)
	}
}

func TestDDoSEnabledPresent(t *testing.T) {
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/ddos/main.conf": `DDOS_ENABLED="true"`,
	})
	defer cleanup()

	chains := []string{"ddos_sanity", "ddos_penalty", "ddos_prefix", "ddos_protection"}
	doc := buildDoc(chains, nil)
	h := evaluateDDoS(doc)

	if h.Config != ConfigEnabled {
		t.Errorf("config = %s, want enabled", h.Config)
	}
	if h.Structural != StructuralPresent {
		t.Errorf("structural = %s, want present", h.Structural)
	}
}

func TestDDoSEnforcingFromCounter(t *testing.T) {
	// DDoS with counter > 0 should report ENFORCING.
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/ddos/main.conf": `DDOS_ENABLED="true"`,
	})
	defer cleanup()

	// Build doc with chains + a counter that has packets
	objects := []NftObject{
		{Table: &NftTable{Family: "ip", Name: "nftban"}},
		{Chain: &NftChain{Family: "ip", Table: "nftban", Name: "ddos_sanity"}},
		{Chain: &NftChain{Family: "ip", Table: "nftban", Name: "ddos_penalty"}},
		{Chain: &NftChain{Family: "ip", Table: "nftban", Name: "ddos_prefix"}},
		{Chain: &NftChain{Family: "ip", Table: "nftban", Name: "ddos_protection"}},
		{Counter: &NftCounter{Family: "ip", Table: "nftban", Name: "input_syn_rate_exceeded", Packets: 5}},
	}
	raw := &NftRuleset{Nftables: objects}
	doc := ParseRuleset(raw)

	h := evaluateDDoS(doc)
	if h.Effective != EffectiveEnforcing {
		t.Errorf("effective = %s, want enforcing (counter > 0)", h.Effective)
	}
}

func TestDDoSIdleZeroCounters(t *testing.T) {
	// DDoS with all counters at zero = IDLE (neutral per Rule 1).
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/ddos/main.conf": `DDOS_ENABLED="true"`,
	})
	defer cleanup()

	objects := []NftObject{
		{Table: &NftTable{Family: "ip", Name: "nftban"}},
		{Chain: &NftChain{Family: "ip", Table: "nftban", Name: "ddos_sanity"}},
		{Chain: &NftChain{Family: "ip", Table: "nftban", Name: "ddos_penalty"}},
		{Chain: &NftChain{Family: "ip", Table: "nftban", Name: "ddos_prefix"}},
		{Chain: &NftChain{Family: "ip", Table: "nftban", Name: "ddos_protection"}},
		{Counter: &NftCounter{Family: "ip", Table: "nftban", Name: "input_syn_rate_exceeded", Packets: 0}},
		{Counter: &NftCounter{Family: "ip", Table: "nftban", Name: "input_ct_ssh_drop", Packets: 0}},
	}
	raw := &NftRuleset{Nftables: objects}
	doc := ParseRuleset(raw)

	h := evaluateDDoS(doc)
	if h.Effective != EffectiveIdle {
		t.Errorf("effective = %s, want idle (all counters zero)", h.Effective)
	}
}

func TestPortscanEffectiveAlwaysIdle(t *testing.T) {
	// Portscan has no dedicated counter. Effective is always IDLE from
	// the validator's perspective. This is a documented M81-3 gap, not a bug.
	// Real enforcement evidence requires kernel log parsing (M81-7 scope).
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/portscan/main.conf": `PORTSCAN_ENABLED="true"`,
	})
	defer cleanup()

	doc := buildDoc([]string{"portscan_detection"}, nil)
	h := evaluatePortscan(doc)

	if h.Effective != EffectiveIdle {
		t.Errorf("effective = %s, want idle (no counter evidence per M81-3)", h.Effective)
	}
}

// =============================================================================
// Portscan truth table tests
// =============================================================================

func TestPortscanDisabled(t *testing.T) {
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/portscan/main.conf": `PORTSCAN_ENABLED="false"`,
	})
	defer cleanup()

	doc := buildDoc(nil, nil)
	h := evaluatePortscan(doc)

	if h.Config != ConfigDisabled {
		t.Errorf("config = %s, want disabled", h.Config)
	}
}

func TestPortscanEnabledPresent(t *testing.T) {
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/portscan/main.conf": `PORTSCAN_ENABLED="true"`,
	})
	defer cleanup()

	doc := buildDoc([]string{"portscan_detection"}, nil)
	h := evaluatePortscan(doc)

	if h.Config != ConfigEnabled {
		t.Errorf("config = %s, want enabled", h.Config)
	}
	if h.Structural != StructuralPresent {
		t.Errorf("structural = %s, want present", h.Structural)
	}
	if h.Effective != EffectiveIdle {
		t.Errorf("effective = %s, want idle (no counter evidence)", h.Effective)
	}
}

// =============================================================================
// LoginMon truth table tests
// =============================================================================

func TestLoginMonDisabled(t *testing.T) {
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/login_alert.conf": `NFTBAN_LOGIN_ALERT_ENABLED="false"`,
	})
	defer cleanup()

	h := evaluateLoginMon(ServiceState{Nftband: RuntimeRunning})

	if h.Config != ConfigDisabled {
		t.Errorf("config = %s, want disabled", h.Config)
	}
}

func TestLoginMonEnabledRunning(t *testing.T) {
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/login_alert.conf.local": `NFTBAN_LOGIN_ALERT_ENABLED="true"`,
	})
	defer cleanup()

	h := evaluateLoginMon(ServiceState{Nftband: RuntimeRunning})

	if h.Config != ConfigEnabled {
		t.Errorf("config = %s, want enabled", h.Config)
	}
	if h.Runtime != RuntimeRunning {
		t.Errorf("runtime = %s, want RUNNING", h.Runtime)
	}
}

func TestLoginMonEnabledDaemonStopped(t *testing.T) {
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/login_alert.conf.local": `NFTBAN_LOGIN_ALERT_ENABLED="true"`,
	})
	defer cleanup()

	h := evaluateLoginMon(ServiceState{Nftband: RuntimeStopped})

	if h.Runtime != RuntimeStopped {
		t.Errorf("runtime = %s, want STOPPED", h.Runtime)
	}
}

// =============================================================================
// Blacklist truth table tests
// =============================================================================

func TestBlacklistManualIdle(t *testing.T) {
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/geoban/main.conf": `GEOBAN_ENABLED="false"`,
	})
	defer cleanup()
	// Mock: manual set empty → idle
	old := countSetElementsFunc
	countSetElementsFunc = func(_, _ string) int { return 0 }
	defer func() { countSetElementsFunc = old }()

	sets := []string{"blacklist_ipv4", "blacklist_manual_ipv4"}
	doc := buildDoc(nil, sets)
	bh := evaluateBlacklist(doc)

	if bh.Manual.State != "idle" {
		t.Errorf("manual state = %s, want idle (0 elements)", bh.Manual.State)
	}
	if bh.Manual.Entries != 0 {
		t.Errorf("manual entries = %d, want 0", bh.Manual.Entries)
	}
	if bh.Feeds.State != "disabled" {
		t.Errorf("feeds state = %s, want disabled", bh.Feeds.State)
	}
	if bh.Geoban.State != "disabled" {
		t.Errorf("geoban state = %s, want disabled", bh.Geoban.State)
	}
}

func TestBlacklistManualPrimed(t *testing.T) {
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/geoban/main.conf": `GEOBAN_ENABLED="false"`,
	})
	defer cleanup()
	// Mock: manual set has 5 entries → primed
	old := countSetElementsFunc
	countSetElementsFunc = func(_, _ string) int { return 5 }
	defer func() { countSetElementsFunc = old }()

	sets := []string{"blacklist_ipv4", "blacklist_manual_ipv4"}
	doc := buildDoc(nil, sets)
	bh := evaluateBlacklist(doc)

	if bh.Manual.State != "primed" {
		t.Errorf("manual state = %s, want primed (5 elements)", bh.Manual.State)
	}
	if bh.Manual.Entries != 5 {
		t.Errorf("manual entries = %d, want 5", bh.Manual.Entries)
	}
}

func TestBlacklistManualEnforcing(t *testing.T) {
	// GAP-BL1: elements > 0 + drops > 0 = ENFORCING
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/geoban/main.conf": `GEOBAN_ENABLED="false"`,
	})
	defer cleanup()
	// Mock: manual set has 3 entries
	old := countSetElementsFunc
	countSetElementsFunc = func(_, _ string) int { return 3 }
	defer func() { countSetElementsFunc = old }()

	// Build doc with manual drop counter > 0
	objects := []NftObject{
		{Table: &NftTable{Family: "ip", Name: "nftban"}},
		{Set: &NftSet{Family: "ip", Table: "nftban", Name: "blacklist_ipv4"}},
		{Set: &NftSet{Family: "ip", Table: "nftban", Name: "blacklist_manual_ipv4"}},
		{Counter: &NftCounter{Family: "ip", Table: "nftban", Name: "input_blacklist_manual_drop", Packets: 42}},
	}
	raw := &NftRuleset{Nftables: objects}
	doc := ParseRuleset(raw)

	bh := evaluateBlacklist(doc)
	if bh.Manual.State != "enforcing" {
		t.Errorf("manual state = %s, want enforcing (elements > 0, drops > 0)", bh.Manual.State)
	}
	if bh.Manual.Entries != 3 {
		t.Errorf("manual entries = %d, want 3", bh.Manual.Entries)
	}
	if bh.Manual.Drops != 42 {
		t.Errorf("manual drops = %d, want 42", bh.Manual.Drops)
	}
}

func TestBlacklistManualPrimedZeroDrops(t *testing.T) {
	// elements > 0 but drops = 0 → PRIMED (not ENFORCING)
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/geoban/main.conf": `GEOBAN_ENABLED="false"`,
	})
	defer cleanup()
	old := countSetElementsFunc
	countSetElementsFunc = func(_, _ string) int { return 2 }
	defer func() { countSetElementsFunc = old }()

	// Counter exists but zero packets
	objects := []NftObject{
		{Table: &NftTable{Family: "ip", Name: "nftban"}},
		{Set: &NftSet{Family: "ip", Table: "nftban", Name: "blacklist_ipv4"}},
		{Set: &NftSet{Family: "ip", Table: "nftban", Name: "blacklist_manual_ipv4"}},
		{Counter: &NftCounter{Family: "ip", Table: "nftban", Name: "input_blacklist_manual_drop", Packets: 0}},
	}
	raw := &NftRuleset{Nftables: objects}
	doc := ParseRuleset(raw)

	bh := evaluateBlacklist(doc)
	if bh.Manual.State != "primed" {
		t.Errorf("manual state = %s, want primed (elements > 0, drops = 0)", bh.Manual.State)
	}
}

// =============================================================================
// Config helper tests
// =============================================================================

func TestReadConfigBoolLocalOverride(t *testing.T) {
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/botguard/main.conf":       `HTTP_BOTGUARD_ENABLED="false"`,
		"conf.d/botguard/main.conf.local":  `HTTP_BOTGUARD_ENABLED="true"`,
	})
	defer cleanup()

	result := readConfigBool("conf.d/botguard/main.conf.local", "conf.d/botguard/main.conf", "HTTP_BOTGUARD_ENABLED")
	if result != ConfigEnabled {
		t.Errorf("expected enabled from .local override, got %s", result)
	}
}

func TestReadConfigBoolFallback(t *testing.T) {
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/botguard/main.conf": `HTTP_BOTGUARD_ENABLED="true"`,
	})
	defer cleanup()

	result := readConfigBool("conf.d/botguard/main.conf.local", "conf.d/botguard/main.conf", "HTTP_BOTGUARD_ENABLED")
	if result != ConfigEnabled {
		t.Errorf("expected enabled from fallback, got %s", result)
	}
}

func TestReadConfigBoolMissing(t *testing.T) {
	cleanup := setupTestConfig(t, map[string]string{})
	defer cleanup()

	result := readConfigBool("conf.d/botguard/main.conf.local", "conf.d/botguard/main.conf", "HTTP_BOTGUARD_ENABLED")
	if result != ConfigDisabled {
		t.Errorf("expected disabled when config missing, got %s", result)
	}
}

// =============================================================================
// Schema version test
// =============================================================================

func TestSchemaVersion(t *testing.T) {
	if SchemaVersionCurrent != "1.83.0" {
		t.Errorf("schema version = %s, want 1.83.0", SchemaVersionCurrent)
	}
}
