// =============================================================================
// NFTBan - Event Rule Engine: Normalized Event Schema
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="ruleengine-event"
// meta:type="package"
// meta:version="1.93.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-16"
// meta:description="Normalized event schema for semantic/behavioral rule matching"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package ruleengine

import "time"

// Event is the normalized event format consumed by the rule engine.
// All detection sources (BotGuard, Suricata, LoginMon, future adapters)
// produce events in this format. The rule engine never sees raw packets,
// payloads, or protocol-specific data (INV-S-012).
type Event struct {
	Timestamp time.Time         `json:"timestamp"`
	EventType string            `json:"event_type"` // http_probe, http_attack, ids_alert, auth_fail, remote_intel
	SourceIP  string            `json:"src_ip"`
	DestIP    string            `json:"dest_ip"`
	DestPort  int               `json:"dest_port"`
	Protocol  string            `json:"proto"`       // tcp, udp, icmp
	Service   string            `json:"service"`     // ssh, http, smtp, dns
	Category  string            `json:"category"`    // sqli, traversal, probe, brute, c2, exploit
	Confidence float64          `json:"confidence"`  // 0.0-1.0
	Source    string            `json:"source"`      // botguard, suricata, loginmon, rule_engine
	Metadata  map[string]string `json:"metadata"`    // uri, method, status, user_agent, signature, sid
}

// Event type constants
const (
	EventHTTPProbe   = "http_probe"
	EventHTTPAttack  = "http_attack"
	EventIDSAlert    = "ids_alert"
	EventAuthFail    = "auth_fail"
	EventRemoteIntel = "remote_intel"
)

// Category constants
const (
	CategorySQLi      = "sqli"
	CategoryTraversal = "traversal"
	CategoryProbe     = "probe"
	CategoryBrute     = "brute"
	CategoryC2        = "c2"
	CategoryExploit   = "exploit"
	CategoryMalware   = "malware"
	CategoryXSS       = "xss"
)

// Source constants
const (
	SourceBotGuard   = "botguard"
	SourceSuricata   = "suricata"
	SourceLoginMon   = "loginmon"
	SourceRuleEngine = "rule_engine"
	SourceFeed       = "feed"
)
