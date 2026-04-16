// =============================================================================
// NFTBan - Event Rule Engine: Source Adapters
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="ruleengine-adapter"
// meta:type="package"
// meta:version="1.93.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-16"
// meta:description="Adapters that produce NormalizedEvents from detection sources"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package ruleengine

import (
	"fmt"
	"time"
)

// EventAdapter produces normalized events from a detection source.
// Each detection module (BotGuard, Suricata, LoginMon) implements this
// to feed events into the rule engine.
//
// The adapter MUST NOT trigger inline behavior (INV-S-012).
// The adapter MUST NOT inspect raw packets or payloads.
type EventAdapter interface {
	// Name returns the adapter source name (e.g. "botguard", "suricata", "loginmon")
	Name() string
}

// NewBotGuardEvent creates a normalized event from BotGuard detection data.
// Called by the BotGuard module when it detects suspicious HTTP behavior.
func NewBotGuardEvent(srcIP, destIP string, destPort int, uri, method, userAgent, category string, confidence float64) *Event {
	return &Event{
		Timestamp:  time.Now(),
		EventType:  EventHTTPProbe,
		SourceIP:   srcIP,
		DestIP:     destIP,
		DestPort:   destPort,
		Protocol:   "tcp",
		Service:    "http",
		Category:   category,
		Confidence: confidence,
		Source:     SourceBotGuard,
		Metadata: map[string]string{
			"uri":        uri,
			"method":     method,
			"user_agent": userAgent,
		},
	}
}

// NewSuricataEvent creates a normalized event from a Suricata EVE alert.
// Called by the Suricata adapter when it processes an alert.
func NewSuricataEvent(srcIP, destIP string, srcPort, destPort int, proto, signature, category string, severity int, sid int) *Event {
	return &Event{
		Timestamp:  time.Now(),
		EventType:  EventIDSAlert,
		SourceIP:   srcIP,
		DestIP:     destIP,
		DestPort:   destPort,
		Protocol:   proto,
		Service:    portToService(destPort),
		Category:   category,
		Confidence: severityToConfidence(severity),
		Source:     SourceSuricata,
		Metadata: map[string]string{
			"signature": signature,
			"sid":       fmt.Sprintf("%d", sid),
			"severity":  fmt.Sprintf("%d", severity),
		},
	}
}

// NewLoginMonEvent creates a normalized event from LoginMon auth failure.
func NewLoginMonEvent(srcIP, destIP string, destPort int, service, user string) *Event {
	return &Event{
		Timestamp:  time.Now(),
		EventType:  EventAuthFail,
		SourceIP:   srcIP,
		DestIP:     destIP,
		DestPort:   destPort,
		Protocol:   "tcp",
		Service:    service,
		Category:   CategoryBrute,
		Confidence: 0.8,
		Source:     SourceLoginMon,
		Metadata: map[string]string{
			"user": user,
		},
	}
}

// NewFeedEvent creates a normalized event from threat intel feed match.
func NewFeedEvent(srcIP, feedName, indicator string, confidence float64) *Event {
	return &Event{
		Timestamp:  time.Now(),
		EventType:  EventRemoteIntel,
		SourceIP:   srcIP,
		Category:   "feed",
		Confidence: confidence,
		Source:     SourceFeed,
		Metadata: map[string]string{
			"feed":      feedName,
			"indicator": indicator,
		},
	}
}

func portToService(port int) string {
	switch port {
	case 22:
		return "ssh"
	case 80, 8080:
		return "http"
	case 443, 8443:
		return "https"
	case 25, 587:
		return "smtp"
	case 53:
		return "dns"
	case 3306:
		return "mysql"
	case 5432:
		return "postgres"
	default:
		return "other"
	}
}

func severityToConfidence(severity int) float64 {
	switch severity {
	case 1:
		return 0.95
	case 2:
		return 0.8
	case 3:
		return 0.6
	default:
		return 0.5
	}
}
