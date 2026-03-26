// =============================================================================
// NFTBan v1.0 - nftband Daemon - Ban/unban request handlers with whitelist and escalation
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftband"
// meta:type="cmd"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Ban/unban request handlers with whitelist and escalation"
//
// meta:inventory.files="/usr/lib/nftban/bin/nftband"
// meta:inventory.binaries="nftband"
// meta:inventory.env_vars="NFTBAN_CONFIG_DIR, NFTBAN_LOG_DIR"
// meta:inventory.config_files="/etc/nftban/nftban.conf"
// meta:inventory.systemd_units="nftband.service, nftband.socket"
// meta:inventory.network="8080/tcp (HTTP API), /run/nftban/nftband.sock (Unix)"
// meta:inventory.privileges="root"
// =============================================================================

package main

import (
	"fmt"
	"log"
	"net"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/analytics"
	"github.com/itcmsgr/nftban/internal/banlog"
	"github.com/itcmsgr/nftban/internal/eventbus"
	"github.com/itcmsgr/nftban/internal/geoip"
	"github.com/itcmsgr/nftban/internal/metrics"
	"github.com/itcmsgr/nftban/internal/nftbackend"
	"github.com/itcmsgr/nftban/internal/persistence"
	"github.com/itcmsgr/nftban/internal/persistent"
	"github.com/itcmsgr/nftban/internal/safety"
	"github.com/itcmsgr/nftban/internal/whitelist"
)

// isWhitelisted checks if an IP is in the whitelist.
// Returns true if the IP should NOT be banned.
func (d *Daemon) isWhitelisted(ip string) bool {
	if d.configDir == "" {
		return false
	}
	ipv4Set, ipv6Set, err := whitelist.LoadAllWhitelists(d.configDir)
	if err != nil {
		log.Printf("[WHITELIST] Warning: failed to load whitelists: %v", err)
		return false
	}
	if strings.Contains(ip, ":") {
		return ipv6Set[ip]
	}
	return ipv4Set[ip]
}

// checkAndEscalate checks if a temp-banned IP has exceeded the persistent
// offender threshold and should be escalated to a permanent ban.
// Called asynchronously after each temp ban from EventBan handler.
// Reads thresholds from conf.d/persistent.conf (per-filter or global defaults).
// Uses banMutex to prevent race conditions during concurrent escalation.
func (d *Daemon) checkAndEscalate(ip, source, country string) {
	// Acquire mutex to prevent race conditions when multiple goroutines
	// attempt to escalate the same IP simultaneously
	banMutex.Lock()
	defer banMutex.Unlock()

	if d.configDir == "" {
		return
	}

	filterName := source
	if filterName == "" {
		filterName = "unknown"
	}

	// Load persistent offender configuration
	cfg, err := persistent.LoadConfig(d.configDir)
	if err != nil {
		log.Printf("[ESCALATE] Failed to load persistent config: %v", err)
		return
	}
	if !cfg.Enabled {
		return
	}

	filterCfg := cfg.GetFilterConfig(filterName)

	// Log this temp ban for escalation tracking
	if err := persistent.LogTempBan(cfg.BanLog, ip, filterName, fmt.Sprintf("temp ban from %s", filterName)); err != nil {
		log.Printf("[ESCALATE] Failed to log temp ban for %s: %v", ip, err)
		return
	}

	// Count recent bans within the configured period
	banCount, err := persistent.CountRecentBans(cfg.BanLog, ip, filterCfg.Period)
	if err != nil {
		log.Printf("[ESCALATE] Failed to count bans for %s: %v", ip, err)
		return
	}

	if banCount < filterCfg.Threshold {
		return // Below threshold, no escalation needed
	}

	log.Printf("[ESCALATE] IP %s exceeded threshold (%d/%d bans in %s from %s) - escalating to permanent",
		ip, banCount, filterCfg.Threshold, filterCfg.Period, filterName)

	// Log persistent offender event
	_ = persistent.LogPersistentOffender(cfg.OffendersLog, ip, filterName, banCount)

	// Add to persistent offenders config file
	reason := fmt.Sprintf(">=%d bans in %s from %s", filterCfg.Threshold, filterCfg.Period, filterName)
	if err := persistent.AddToPersistentOffenders(cfg.OffendersConf, ip, reason); err != nil {
		log.Printf("[ESCALATE] Failed to add %s to persistent offenders file: %v", ip, err)
		return
	}

	// Re-ban as permanent (timeout=0)
	_, err = d.backend.Ban(d.ctx, nftbackend.BanRequest{
		IP:      ip,
		Timeout: 0, // permanent
		Reason:  reason,
		Source:  "persistent",
	})
	if err != nil {
		log.Printf("[ESCALATE] Failed to permanent-ban %s: %v", ip, err)
		return
	}

	// Persist to blacklist.d/30-persistent-offenders.conf via persistence package
	_, _, err = persistence.PersistBan(d.configDir, ip, reason, "persistent")
	if err != nil {
		log.Printf("[ESCALATE] Failed to persist permanent ban for %s: %v", ip, err)
	}

	// Record analytics
	if st := analytics.StateOrNil(); st != nil {
		st.RecordPersistentOffender(ip, country, filterName, time.Now())
	}

	log.Printf("[ESCALATE] IP %s permanently banned and persisted (source: %s, bans: %d)", ip, filterName, banCount)
}

// lookupCountry performs GeoIP lookup and returns country code.
// Returns "UNK" if lookup fails.
func lookupCountry(ip string) string {
	country, _ := geoip.LookupIP(ip)
	if country == "" {
		return "UNK"
	}
	return country
}

// handleBanRequest bans an IP
func (d *Daemon) handleBanRequest(params map[string]any) SocketResponse {
	ip, ok := params["ip"].(string)
	if !ok || ip == "" {
		return SocketResponse{Success: false, Error: "missing ip parameter"}
	}

	// SECURITY: Validate IP address before processing
	if net.ParseIP(ip) == nil {
		// Also accept CIDR notation
		if _, _, err := net.ParseCIDR(ip); err != nil {
			return SocketResponse{Success: false, Error: "invalid IP address"}
		}
	}

	// SECURITY: Check whitelist before banning (defense-in-depth)
	if d.isWhitelisted(ip) {
		log.Printf("[BAN] BLOCKED: %s is whitelisted, refusing IPC ban", ip)
		return SocketResponse{
			Success: false,
			Error:   fmt.Sprintf("IP %s is whitelisted, cannot ban", ip),
		}
	}

	// Parse optional parameters
	timeout := 0
	if t, ok := params["timeout"].(float64); ok {
		timeout = int(t)
	}
	reason := ""
	if r, ok := params["reason"].(string); ok {
		reason = r
	}
	source := "cli"
	if s, ok := params["source"].(string); ok {
		source = s
	}

	// Parse permanent ban parameters
	permanent := false
	if p, ok := params["permanent"].(bool); ok {
		permanent = p
	}
	protected := false
	if p, ok := params["protected"].(bool); ok {
		protected = p
	}

	// Perform the ban via AUTHORITATIVE backend
	result, err := d.backend.Ban(d.ctx, nftbackend.BanRequest{
		IP:      ip,
		Timeout: timeout,
		Reason:  reason,
		Source:  source,
	})
	if err != nil {
		return SocketResponse{
			Success: false,
			Error:   err.Error(),
		}
	}

	// Record in stats collector
	d.stats.RecordBan()

	// Record Prometheus metric
	family := "ipv4"
	if strings.Contains(ip, ":") {
		family = "ipv6"
	}
	metrics.RecordBanWithIP(source, family, ip)

	// Log ban to bans.log for stats tracking
	banSource := banlog.SourceManual
	switch {
	case strings.Contains(source, "portscan"):
		banSource = banlog.SourcePortscan
	case strings.Contains(source, "login"):
		banSource = banlog.SourceLogin
	case strings.Contains(source, "ddos"):
		banSource = banlog.SourceDDoS
	case strings.Contains(source, "feed"):
		banSource = banlog.SourceFeeds
	case strings.Contains(source, "suricata"):
		banSource = banlog.SourceSuricata
	}
	country := lookupCountry(ip)
	_ = banlog.LogBanWithReason(ip, banSource, country, reason)

	// Track permanent ban if requested (timeout=0 and permanent flag set)
	if permanent && timeout == 0 {
		if err := safety.TrackPermanentBan(ip, reason, source, protected); err != nil {
			log.Printf("[BAN] Warning: failed to track permanent ban for %s: %v", ip, err)
		}
	}

	// NOTE: Do NOT publish EventBan here - the IPC handler already executed the ban
	// and logged it. The EventBan subscriber is for module-initiated bans only.
	// Publishing EventBan here would cause:
	// 1. Duplicate ban execution (subscriber calls d.backend.Ban again)
	// 2. Duplicate bans.log entries

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"ip":        ip,
			"set":       result.Set,
			"status":    "banned",
			"message":   result.Message,
			"permanent": permanent && timeout == 0,
			"protected": protected,
		},
	}
}

// handleUnbanRequest unbans an IP
func (d *Daemon) handleUnbanRequest(params map[string]any) SocketResponse {
	ip, ok := params["ip"].(string)
	if !ok || ip == "" {
		return SocketResponse{Success: false, Error: "missing ip parameter"}
	}

	// SECURITY: Validate IP address before processing
	if net.ParseIP(ip) == nil {
		// Also accept CIDR notation
		if _, _, err := net.ParseCIDR(ip); err != nil {
			return SocketResponse{Success: false, Error: "invalid IP address"}
		}
	}

	// Perform the unban via AUTHORITATIVE backend
	result, err := d.backend.Unban(d.ctx, nftbackend.UnbanRequest{
		IP: ip,
	})
	if err != nil {
		return SocketResponse{
			Success: false,
			Error:   err.Error(),
		}
	}

	// Record in stats collector
	d.stats.RecordUnban()

	// Record Prometheus metric
	family := "ipv4"
	if strings.Contains(ip, ":") {
		family = "ipv6"
	}
	metrics.RecordUnbanWithIP("manual", family, ip)

	// Publish unban event
	d.bus.Publish(eventbus.NewEvent(eventbus.EventUnban, "cli").
		WithIP(ip).
		WithMessage("Manual unban via CLI").
		WithSeverity(eventbus.SeverityInfo))

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"ip":      ip,
			"set":     result.Set,
			"status":  "unbanned",
			"message": result.Message,
		},
	}
}

// =============================================================================
// PERMANENT BAN MANAGEMENT IPC HANDLERS
// =============================================================================

// handleProtectBanRequest marks a permanent ban as protected (cannot be evicted)
func (d *Daemon) handleProtectBanRequest(params map[string]any) SocketResponse {
	ip, ok := params["ip"].(string)
	if !ok || ip == "" {
		return SocketResponse{Success: false, Error: "missing ip parameter"}
	}

	if err := safety.SetBanProtected(ip, true); err != nil {
		return SocketResponse{
			Success: false,
			Error:   err.Error(),
		}
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"ip":        ip,
			"protected": true,
		},
	}
}

// handleUnprotectBanRequest marks a permanent ban as unprotected (can be evicted)
func (d *Daemon) handleUnprotectBanRequest(params map[string]any) SocketResponse {
	ip, ok := params["ip"].(string)
	if !ok || ip == "" {
		return SocketResponse{Success: false, Error: "missing ip parameter"}
	}

	if err := safety.SetBanProtected(ip, false); err != nil {
		return SocketResponse{
			Success: false,
			Error:   err.Error(),
		}
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"ip":        ip,
			"protected": false,
		},
	}
}

// handleGetEvictableBansRequest returns IPs that can be evicted (old, unprotected)
func (d *Daemon) handleGetEvictableBansRequest(params map[string]any) SocketResponse {
	count := 100 // default
	if c, ok := params["count"].(float64); ok && c > 0 {
		count = int(c)
	}

	ips, err := safety.GetEvictableBans(count)
	if err != nil {
		return SocketResponse{
			Success: false,
			Error:   err.Error(),
		}
	}

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"count": len(ips),
			"ips":   ips,
		},
	}
}

// handleEvictOldBansRequest evicts old unprotected bans
func (d *Daemon) handleEvictOldBansRequest(params map[string]any) SocketResponse {
	count := 100 // default
	if c, ok := params["count"].(float64); ok && c > 0 {
		count = int(c)
	}

	// Get evictable bans
	ips, err := safety.GetEvictableBans(count)
	if err != nil {
		return SocketResponse{
			Success: false,
			Error:   "failed to get evictable bans: " + err.Error(),
		}
	}

	if len(ips) == 0 {
		return SocketResponse{
			Success: true,
			Data: map[string]any{
				"evicted": 0,
				"message": "no evictable bans found",
			},
		}
	}

	// Unban each evictable IP
	evicted := 0
	var errors []string
	for _, ip := range ips {
		// Unban via backend
		_, err := d.backend.Unban(d.ctx, nftbackend.UnbanRequest{IP: ip})
		if err != nil {
			errors = append(errors, fmt.Sprintf("%s: %v", ip, err))
			continue
		}

		// Remove from permanent ban tracking
		if err := safety.RemovePermanentBan(ip); err != nil {
			log.Printf("[EVICT] Warning: failed to remove %s from tracking: %v", ip, err)
		}

		// Record metrics
		family := "ipv4"
		if strings.Contains(ip, ":") {
			family = "ipv6"
		}
		metrics.RecordUnbanWithIP("eviction", family, ip)
		d.stats.RecordUnban()
		evicted++
	}

	data := map[string]any{
		"evicted":   evicted,
		"requested": len(ips),
	}
	if len(errors) > 0 {
		data["errors"] = errors
	}

	return SocketResponse{
		Success: true,
		Data:    data,
	}
}

// handlePermanentBanStatsRequest returns statistics about permanent bans
func (d *Daemon) handlePermanentBanStatsRequest() SocketResponse {
	total, protected, evictable, err := safety.GetPermanentBanStats()
	if err != nil {
		return SocketResponse{
			Success: false,
			Error:   err.Error(),
		}
	}

	// BUG-008 FIX: Update Prometheus metrics for permanent ban tracking
	metrics.SetPermanentBansTotal(total)
	metrics.SetPermanentBansProtected(protected)
	metrics.SetPermanentBansEvictable(evictable)

	return SocketResponse{
		Success: true,
		Data: map[string]any{
			"total":     total,
			"protected": protected,
			"evictable": evictable,
		},
	}
}
