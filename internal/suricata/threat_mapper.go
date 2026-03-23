// =============================================================================
// NFTBan - Suricata L7 EVE to ThreatEvent Mapper
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="threat_mapper"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-28"
// meta:description="Maps raw Suricata EVE JSON events to canonical ThreatEvent"
// meta:input="EveEvent (raw JSON parsed)"
// meta:output="ThreatEvent (canonical model)"
// meta:depends="crypto/sha256,encoding/hex,fmt,time"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package suricata

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"time"
)

// EveEvent represents a raw Suricata EVE JSON event (extended fields)
// This extends the basic EveAlert with additional L7 protocol support
type EveEvent struct {
	Timestamp   string `json:"timestamp"`
	EventType   string `json:"event_type"`
	SrcIP       string `json:"src_ip"`
	SrcPort     int    `json:"src_port"`
	DestIP      string `json:"dest_ip"`
	DestPort    int    `json:"dest_port"`
	Proto       string `json:"proto"`
	AppProto    string `json:"app_proto"`
	FlowID      uint64 `json:"flow_id"`
	TxID        int    `json:"tx_id,omitempty"`
	CommunityID string `json:"community_id,omitempty"`

	// HTTP fields (when event_type=http or embedded in alert)
	HTTP *EveHTTP `json:"http,omitempty"`

	// TLS fields
	TLS *EveTLS `json:"tls,omitempty"`

	// Alert fields
	Alert *EveAlertFields `json:"alert,omitempty"`

	// DNS fields
	DNS *EveDNS `json:"dns,omitempty"`

	// SSH fields
	SSH *EveSSH `json:"ssh,omitempty"`
}

// EveHTTP represents HTTP fields in EVE JSON
type EveHTTP struct {
	Hostname    string `json:"hostname"`
	URL         string `json:"url"`
	Method      string `json:"http_method"`
	Status      int    `json:"status"`
	UserAgent   string `json:"http_user_agent"`
	Referer     string `json:"http_refer"`
	XFF         string `json:"xff"`
	ContentType string `json:"http_content_type"`
	Length      int64  `json:"length"`
	Protocol    string `json:"protocol"`
}

// EveTLS represents TLS fields in EVE JSON
type EveTLS struct {
	SNI     string `json:"sni"`
	Version string `json:"version"`
	Subject string `json:"subject"`
	Issuer  string `json:"issuerdn"`
	JA3     *struct {
		Hash string `json:"hash"`
	} `json:"ja3,omitempty"`
	JA3S *struct {
		Hash string `json:"hash"`
	} `json:"ja3s,omitempty"`
	Fingerprint string `json:"fingerprint,omitempty"`
	Serial      string `json:"serial,omitempty"`
	NotBefore   string `json:"notbefore,omitempty"`
	NotAfter    string `json:"notafter,omitempty"`
}

// EveAlertFields represents alert fields in EVE JSON
type EveAlertFields struct {
	Action    string              `json:"action"`
	GID       int                 `json:"gid"`
	SID       int                 `json:"signature_id"`
	Rev       int                 `json:"rev"`
	Signature string              `json:"signature"`
	Category  string              `json:"category"`
	Severity  int                 `json:"severity"`
	Metadata  map[string][]string `json:"metadata,omitempty"`
}

// EveDNS represents DNS fields in EVE JSON
type EveDNS struct {
	Type   string   `json:"type"`
	RRType string   `json:"rrtype"`
	RRName string   `json:"rrname"`
	RCode  string   `json:"rcode"`
	RData  []string `json:"rdata"`
}

// EveSSH represents SSH fields in EVE JSON
type EveSSH struct {
	Client *struct {
		ProtoVersion    string `json:"proto_version"`
		SoftwareVersion string `json:"software_version"`
	} `json:"client,omitempty"`
	Server *struct {
		ProtoVersion    string `json:"proto_version"`
		SoftwareVersion string `json:"software_version"`
	} `json:"server,omitempty"`
}

// MapEVEToThreatEvent converts a raw Suricata EVE event to canonical ThreatEvent
func MapEVEToThreatEvent(eve *EveEvent, sensor string, proxyCfg ProxyTrustConfig) (*ThreatEvent, error) {
	if eve == nil {
		return nil, fmt.Errorf("nil eve event")
	}

	// Parse timestamp (Suricata format)
	ts, err := time.Parse("2006-01-02T15:04:05.999999-0700", eve.Timestamp)
	if err != nil {
		// Try alternate format
		ts, err = time.Parse(time.RFC3339Nano, eve.Timestamp)
		if err != nil {
			ts = time.Now() // Fallback
		}
	}

	// Determine event type
	eventType := mapThreatEventType(eve.EventType)

	// Build HTTP details if present
	var httpDetails *HTTPDetails
	if eve.HTTP != nil {
		httpDetails = &HTTPDetails{
			Method:      eve.HTTP.Method,
			Host:        eve.HTTP.Hostname,
			URI:         eve.HTTP.URL,
			Status:      eve.HTTP.Status,
			UserAgent:   eve.HTTP.UserAgent,
			Referer:     eve.HTTP.Referer,
			XFF:         eve.HTTP.XFF,
			ContentType: eve.HTTP.ContentType,
			Length:      eve.HTTP.Length,
			Protocol:    eve.HTTP.Protocol,
		}
	}

	// Resolve actor IP (handles trusted proxies)
	actorIP, actorTrust := ResolveActorIP(eve.SrcIP, httpDetails, proxyCfg)

	// Generate event ID
	eventID := generateThreatEventID(ts, eve.FlowID, eve.TxID, eve.EventType)

	event := &ThreatEvent{
		EventID:           eventID,
		Timestamp:         ts,
		Sensor:            sensor,
		EventType:         eventType,
		FlowID:            eve.FlowID,
		TxID:              eve.TxID,
		ActorIP:           actorIP,
		ActorTrust:        actorTrust,
		ActorKey:          actorIP, // Default: use resolved IP as key
		SrcIP:             eve.SrcIP,
		DstIP:             eve.DestIP,
		Proto:             eve.Proto,
		AppProto:          eve.AppProto,
		SrcPort:           eve.SrcPort,
		DstPort:           eve.DestPort,
		CommunityID:       eve.CommunityID,
		ObservedDirection: determineDirection(eve.SrcPort, eve.DestPort),
		HTTP:              httpDetails,
	}

	// Add TLS details if present
	if eve.TLS != nil {
		event.TLS = &TLSDetails{
			SNI:         eve.TLS.SNI,
			Version:     eve.TLS.Version,
			Subject:     eve.TLS.Subject,
			Issuer:      eve.TLS.Issuer,
			Fingerprint: eve.TLS.Fingerprint,
			Serial:      eve.TLS.Serial,
			NotBefore:   eve.TLS.NotBefore,
			NotAfter:    eve.TLS.NotAfter,
		}
		if eve.TLS.JA3 != nil {
			event.TLS.JA3 = eve.TLS.JA3.Hash
		}
		if eve.TLS.JA3S != nil {
			event.TLS.JA3S = eve.TLS.JA3S.Hash
		}
	}

	// Add alert details if present
	if eve.Alert != nil {
		event.Alert = &AlertDetails{
			SID:       eve.Alert.SID,
			GID:       eve.Alert.GID,
			Rev:       eve.Alert.Rev,
			Signature: eve.Alert.Signature,
			Category:  eve.Alert.Category,
			Severity:  eve.Alert.Severity,
			Action:    eve.Alert.Action,
			Metadata:  eve.Alert.Metadata,
		}
	}

	// Add DNS details if present
	if eve.DNS != nil {
		event.DNS = &DNSDetails{
			Type:   eve.DNS.Type,
			RRType: eve.DNS.RRType,
			RRName: eve.DNS.RRName,
			RCode:  eve.DNS.RCode,
			RData:  eve.DNS.RData,
		}
	}

	// Add SSH details if present
	if eve.SSH != nil {
		event.SSH = &SSHDetails{}
		if eve.SSH.Client != nil {
			event.SSH.Client.Version = eve.SSH.Client.ProtoVersion
			event.SSH.Client.Software = eve.SSH.Client.SoftwareVersion
		}
		if eve.SSH.Server != nil {
			event.SSH.Server.Version = eve.SSH.Server.ProtoVersion
			event.SSH.Server.Software = eve.SSH.Server.SoftwareVersion
		}
	}

	return event, nil
}

func mapThreatEventType(eveType string) ThreatEventType {
	switch eveType {
	case "http":
		return ThreatEventTypeHTTP
	case "tls":
		return ThreatEventTypeTLS
	case "dns":
		return ThreatEventTypeDNS
	case "ssh":
		return ThreatEventTypeSSH
	case "alert":
		return ThreatEventTypeAlert
	case "flow":
		return ThreatEventTypeFlow
	default:
		return ThreatEventType(eveType)
	}
}

func generateThreatEventID(ts time.Time, flowID uint64, txID int, eventType string) string {
	data := fmt.Sprintf("%d-%d-%d-%s", ts.UnixNano(), flowID, txID, eventType)
	hash := sha256.Sum256([]byte(data))
	return hex.EncodeToString(hash[:8]) // Short hash for readability
}

func determineDirection(srcPort, dstPort int) string {
	// Simple heuristic: low dest port = inbound request
	if dstPort < 1024 {
		return "inbound"
	}
	if srcPort < 1024 {
		return "outbound"
	}
	return "unknown"
}
