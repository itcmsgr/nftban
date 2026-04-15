// =============================================================================
// NFTBan v1.87 - Correlation Engine Tests (M87-6)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="evidence_correlate_test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-15"
// meta:description="Tests for evidence correlation engine"
// meta:inventory.files="internal/metrics/evidence_correlate_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package metrics

import "testing"

func TestCorrelate_ValidatorUnavailable(t *testing.T) {
	results := CorrelateEvidence(nil, nil, nil)
	for mod, result := range results {
		if result != CorrelationUnknown {
			t.Errorf("module %s: expected unknown when validator nil, got %s", mod, result)
		}
	}
}

func TestCorrelate_ValidatorUnknown(t *testing.T) {
	val := &ValidatorSnapshot{Status: "unavailable", Unknown: true}
	results := CorrelateEvidence(nil, nil, val)
	for mod, result := range results {
		if result != CorrelationUnknown {
			t.Errorf("module %s: expected unknown when validator Unknown=true, got %s", mod, result)
		}
	}
}

// DDoS correlation tests
func TestCorrelate_DDoS_CounterPositive_Enforcing(t *testing.T) {
	counters := map[string]CounterValue{
		"ip:input_ct_ssh_drop": {Packets: 42, Bytes: 1234},
	}
	val := &ValidatorSnapshot{
		Modules: map[string]string{"ddos": "enforcing"},
	}
	results := CorrelateEvidence(counters, nil, val)
	if results["ddos"] != CorrelationMatch {
		t.Errorf("ddos: counter>0 + enforcing should be match, got %s", results["ddos"])
	}
}

func TestCorrelate_DDoS_CounterPositive_Idle(t *testing.T) {
	counters := map[string]CounterValue{
		"ip:input_syn_rate_exceeded": {Packets: 100, Bytes: 5000},
	}
	val := &ValidatorSnapshot{
		Modules: map[string]string{"ddos": "idle"},
	}
	results := CorrelateEvidence(counters, nil, val)
	if results["ddos"] != CorrelationMismatch {
		t.Errorf("ddos: counter>0 + idle should be mismatch, got %s", results["ddos"])
	}
}

func TestCorrelate_DDoS_ZeroCounters_Idle(t *testing.T) {
	counters := map[string]CounterValue{
		"ip:input_ct_ssh_drop": {Packets: 0, Bytes: 0},
	}
	val := &ValidatorSnapshot{
		Modules: map[string]string{"ddos": "idle"},
	}
	results := CorrelateEvidence(counters, nil, val)
	if results["ddos"] != CorrelationMatch {
		t.Errorf("ddos: zero counters + idle should be match, got %s", results["ddos"])
	}
}

func TestCorrelate_DDoS_NilCounters(t *testing.T) {
	val := &ValidatorSnapshot{
		Modules: map[string]string{"ddos": "enforcing"},
	}
	results := CorrelateEvidence(nil, nil, val)
	if results["ddos"] != CorrelationUnknown {
		t.Errorf("ddos: nil counters should be unknown, got %s", results["ddos"])
	}
}

// BotGuard correlation tests
func TestCorrelate_BotGuard_SetsPopulated_Enforcing(t *testing.T) {
	sets := map[string]SetInfo{
		"ip:http_bot_ban": {Exists: true, Count: 5},
	}
	val := &ValidatorSnapshot{
		Modules: map[string]string{"botguard": "enforcing"},
	}
	results := CorrelateEvidence(nil, sets, val)
	if results["botguard"] != CorrelationMatch {
		t.Errorf("botguard: populated + enforcing should be match, got %s", results["botguard"])
	}
}

func TestCorrelate_BotGuard_SetsPopulated_Idle(t *testing.T) {
	sets := map[string]SetInfo{
		"ip:http_bot_ban": {Exists: true, Count: 3},
	}
	val := &ValidatorSnapshot{
		Modules: map[string]string{"botguard": "idle"},
	}
	results := CorrelateEvidence(nil, sets, val)
	if results["botguard"] != CorrelationMismatch {
		t.Errorf("botguard: populated + idle should be mismatch, got %s", results["botguard"])
	}
}

func TestCorrelate_BotGuard_UnknownSets(t *testing.T) {
	sets := map[string]SetInfo{
		"ip:http_bot_ban": {Exists: false, Unknown: true},
	}
	val := &ValidatorSnapshot{
		Modules: map[string]string{"botguard": "enforcing"},
	}
	results := CorrelateEvidence(nil, sets, val)
	// Unknown sets → correlation is unknown (not match, not mismatch)
	if results["botguard"] != CorrelationUnknown {
		t.Errorf("botguard: unknown sets should be unknown, got %s", results["botguard"])
	}
}

func TestCorrelate_BlacklistManual_UnknownSets(t *testing.T) {
	counters := map[string]CounterValue{
		"ip:input_blacklist_manual_drop": {Packets: 10, Bytes: 500},
	}
	sets := map[string]SetInfo{
		"ip:blacklist_manual_ipv4": {Exists: false, Unknown: true},
	}
	val := &ValidatorSnapshot{
		Modules: map[string]string{"blacklist_manual": "enforcing"},
	}
	results := CorrelateEvidence(counters, sets, val)
	if results["blacklist_manual"] != CorrelationUnknown {
		t.Errorf("blacklist_manual: unknown sets should be unknown, got %s", results["blacklist_manual"])
	}
}

// Portscan — always expected_limitation
func TestCorrelate_Portscan(t *testing.T) {
	val := &ValidatorSnapshot{
		Modules: map[string]string{"portscan": "idle"},
	}
	results := CorrelateEvidence(nil, nil, val)
	if results["portscan"] != CorrelationExpectedLimitation {
		t.Errorf("portscan should always be expected_limitation, got %s", results["portscan"])
	}
}

// LoginMon — always expected_limitation in Phase 1
func TestCorrelate_LoginMon(t *testing.T) {
	val := &ValidatorSnapshot{
		Modules: map[string]string{"loginmon": "idle"},
	}
	results := CorrelateEvidence(nil, nil, val)
	if results["loginmon"] != CorrelationExpectedLimitation {
		t.Errorf("loginmon should always be expected_limitation in Phase 1, got %s", results["loginmon"])
	}
}

// Blacklist manual correlation tests
func TestCorrelate_BlacklistManual_Enforcing(t *testing.T) {
	counters := map[string]CounterValue{
		"ip:input_blacklist_manual_drop": {Packets: 42, Bytes: 1234},
	}
	sets := map[string]SetInfo{
		"ip:blacklist_manual_ipv4": {Exists: true, Count: 3},
	}
	val := &ValidatorSnapshot{
		Modules: map[string]string{"blacklist_manual": "enforcing"},
	}
	results := CorrelateEvidence(counters, sets, val)
	if results["blacklist_manual"] != CorrelationMatch {
		t.Errorf("blacklist_manual: elements+drops+enforcing should be match, got %s", results["blacklist_manual"])
	}
}

func TestCorrelate_BlacklistManual_DropsButPrimed(t *testing.T) {
	counters := map[string]CounterValue{
		"ip:input_blacklist_manual_drop": {Packets: 10, Bytes: 500},
	}
	sets := map[string]SetInfo{
		"ip:blacklist_manual_ipv4": {Exists: true, Count: 2},
	}
	val := &ValidatorSnapshot{
		Modules: map[string]string{"blacklist_manual": "primed"},
	}
	results := CorrelateEvidence(counters, sets, val)
	if results["blacklist_manual"] != CorrelationWarning {
		t.Errorf("blacklist_manual: drops+primed should be warning, got %s", results["blacklist_manual"])
	}
}

func TestCorrelate_BlacklistManual_Idle(t *testing.T) {
	counters := map[string]CounterValue{}
	sets := map[string]SetInfo{
		"ip:blacklist_manual_ipv4": {Exists: true, Count: 0},
	}
	val := &ValidatorSnapshot{
		Modules: map[string]string{"blacklist_manual": "idle"},
	}
	results := CorrelateEvidence(counters, sets, val)
	if results["blacklist_manual"] != CorrelationMatch {
		t.Errorf("blacklist_manual: empty+idle should be match, got %s", results["blacklist_manual"])
	}
}

// Completeness check
func TestCorrelate_AllModulesPresent(t *testing.T) {
	val := &ValidatorSnapshot{
		Status:  "protected",
		Modules: map[string]string{},
	}
	results := CorrelateEvidence(
		map[string]CounterValue{},
		map[string]SetInfo{},
		val,
	)

	required := []string{"ddos", "botguard", "portscan", "loginmon", "blacklist_manual"}
	for _, mod := range required {
		if _, ok := results[mod]; !ok {
			t.Errorf("missing correlation result for module %s", mod)
		}
	}
}
