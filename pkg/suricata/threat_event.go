// =============================================================================
// NFTBan - Suricata L7 Canonical Event Model
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="threat_event"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-28"
// meta:description="Canonical event model for Suricata L7 deep packet inspection"
// meta:input="Suricata EVE JSON events"
// meta:output="ThreatEvent structs for aggregation and scoring"
// meta:depends="time"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package suricata

import "time"

// ThreatEventType represents the type of Suricata event
type ThreatEventType string

const (
	ThreatEventTypeHTTP  ThreatEventType = "http"
	ThreatEventTypeTLS   ThreatEventType = "tls"
	ThreatEventTypeDNS   ThreatEventType = "dns"
	ThreatEventTypeSSH   ThreatEventType = "ssh"
	ThreatEventTypeAlert ThreatEventType = "alert"
	ThreatEventTypeFlow  ThreatEventType = "flow"
)

// ActorTrust represents the trust level of the resolved actor IP
type ActorTrust string

const (
	ActorDirect         ActorTrust = "direct"
	ActorProxyTrusted   ActorTrust = "proxy_trusted"
	ActorProxyUntrusted ActorTrust = "proxy_untrusted"
)

// ThreatEvent is the canonical event model for all Suricata events
// This extends the basic Event struct with L7 deep packet inspection fields
type ThreatEvent struct {
	// Identity
	EventID   string          `json:"event_id"`
	Timestamp time.Time       `json:"timestamp"`
	Sensor    string          `json:"sensor,omitempty"`
	EventType ThreatEventType `json:"event_type"`
	FlowID    uint64          `json:"flow_id,omitempty"`
	TxID      int             `json:"tx_id,omitempty"`

	// Actor (resolved real client IP)
	ActorIP    string     `json:"actor_ip"`
	ActorTrust ActorTrust `json:"actor_trust"`
	ActorKey   string     `json:"actor_key"` // stable key for aggregation (usually ActorIP)

	// Network layer
	SrcIP    string `json:"src_ip"`
	DstIP    string `json:"dst_ip"`
	Proto    string `json:"proto"`
	AppProto string `json:"app_proto,omitempty"`
	SrcPort  int    `json:"src_port,omitempty"`
	DstPort  int    `json:"dst_port,omitempty"`

	// Correlation
	CommunityID       string `json:"community_id,omitempty"`
	ObservedDirection string `json:"direction,omitempty"` // "inbound", "outbound"

	// Protocol-specific details
	HTTP  *HTTPDetails  `json:"http,omitempty"`
	TLS   *TLSDetails   `json:"tls,omitempty"`
	Alert *AlertDetails `json:"alert,omitempty"`
	DNS   *DNSDetails   `json:"dns,omitempty"`
	SSH   *SSHDetails   `json:"ssh,omitempty"`

	// Scoring (computed by scorer)
	Score      float64            `json:"score,omitempty"`
	Category   string             `json:"category,omitempty"`
	Confidence float64            `json:"confidence,omitempty"`
	Features   map[string]float64 `json:"features,omitempty"`
}

// HTTPDetails contains HTTP-specific event data
type HTTPDetails struct {
	Method      string `json:"method"`
	Host        string `json:"host,omitempty"`
	URI         string `json:"uri,omitempty"`
	Status      int    `json:"status,omitempty"`
	UserAgent   string `json:"user_agent,omitempty"`
	Referer     string `json:"referer,omitempty"`
	XFF         string `json:"xff,omitempty"` // X-Forwarded-For (untrusted unless proxy verified)
	ContentType string `json:"content_type,omitempty"`
	Length      int64  `json:"length,omitempty"`
	Protocol    string `json:"protocol,omitempty"` // HTTP/1.1, HTTP/2
}

// TLSDetails contains TLS-specific event data
type TLSDetails struct {
	SNI         string `json:"sni,omitempty"`
	JA3         string `json:"ja3,omitempty"`
	JA3S        string `json:"ja3s,omitempty"`
	JA4         string `json:"ja4,omitempty"`
	Version     string `json:"version,omitempty"`
	Subject     string `json:"subject,omitempty"`
	Issuer      string `json:"issuer,omitempty"`
	Fingerprint string `json:"fingerprint,omitempty"`
	Serial      string `json:"serial,omitempty"`
	NotBefore   string `json:"not_before,omitempty"`
	NotAfter    string `json:"not_after,omitempty"`
}

// AlertDetails contains Suricata alert data
type AlertDetails struct {
	SID       int                 `json:"sid,omitempty"`       // Suricata Signature ID
	GID       int                 `json:"gid,omitempty"`       // Generator ID
	Rev       int                 `json:"rev,omitempty"`       // Revision
	Signature string              `json:"signature,omitempty"` // Full signature text
	Category  string              `json:"category,omitempty"`  // Alert category
	Severity  int                 `json:"severity,omitempty"`  // 1-4 (1=high)
	Action    string              `json:"action,omitempty"`    // "allowed", "blocked"
	Metadata  map[string][]string `json:"metadata,omitempty"`
}

// DNSDetails contains DNS-specific event data
type DNSDetails struct {
	Type   string   `json:"type,omitempty"`   // "query" or "answer"
	RRType string   `json:"rrtype,omitempty"` // A, AAAA, MX, etc.
	RRName string   `json:"rrname,omitempty"` // Query name
	RCode  string   `json:"rcode,omitempty"`  // Response code
	RData  []string `json:"rdata,omitempty"`  // Response data
}

// SSHDetails contains SSH-specific event data
type SSHDetails struct {
	Client struct {
		Version  string `json:"version,omitempty"`
		Software string `json:"software,omitempty"`
	} `json:"client,omitempty"`
	Server struct {
		Version  string `json:"version,omitempty"`
		Software string `json:"software,omitempty"`
	} `json:"server,omitempty"`
}
