// =============================================================================
// NFTBan - Structured Logging Wrappers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="logx"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Category-based and severity-based logging helpers"
// meta:input="Log format strings and arguments"
// meta:output="Prefixed log output"
// meta:depends="log,fmt"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

// Package logx provides structured logging wrappers for NFTBan
// This centralizes log prefixes and makes future enhancements (JSON logs, levels) easier
package logx

import (
	"fmt"
	"log"
)

// =============================================================================
// Category-based Logging
// =============================================================================
// Usage: logx.Auth("User %s logged in", username)
// Output: [AUTH] User admin logged in
//
// Future: Can easily add log levels, JSON output, or external logging
// =============================================================================

// Auth logs authentication-related messages
func Auth(format string, args ...any) {
	log.Printf("[AUTH] "+format, args...)
}

// HTTP logs HTTP request/response messages
func HTTP(format string, args ...any) {
	log.Printf("[HTTP] "+format, args...)
}

// Security logs security-related events (blocked IPs, auth failures, etc.)
func Security(format string, args ...any) {
	log.Printf("[SECURITY] "+format, args...)
}

// Firewall logs firewall operations (ban, unban, rules)
func Firewall(format string, args ...any) {
	log.Printf("[FIREWALL] "+format, args...)
}

// Feeds logs threat feed operations
func Feeds(format string, args ...any) {
	log.Printf("[FEEDS] "+format, args...)
}

// Sync logs synchronization operations
func Sync(format string, args ...any) {
	log.Printf("[SYNC] "+format, args...)
}

// GeoIP logs GeoIP-related operations
func GeoIP(format string, args ...any) {
	log.Printf("[GEOIP] "+format, args...)
}

// Metrics logs metrics collection events
func Metrics(format string, args ...any) {
	log.Printf("[METRICS] "+format, args...)
}

// Session logs session management events
func Session(format string, args ...any) {
	log.Printf("[SESSION] "+format, args...)
}

// Audit logs audit trail events (actions taken)
func Audit(format string, args ...any) {
	log.Printf("[AUDIT] "+format, args...)
}

// Config logs configuration changes
func Config(format string, args ...any) {
	log.Printf("[CONFIG] "+format, args...)
}

// NFT logs nftables operations
func NFT(format string, args ...any) {
	log.Printf("[NFT] "+format, args...)
}

// Suricata logs Suricata IDS integration events
func Suricata(format string, args ...any) {
	log.Printf("[SURICATA] "+format, args...)
}

// DDoS logs DDoS protection events
func DDoS(format string, args ...any) {
	log.Printf("[DDOS] "+format, args...)
}

// Portscan logs port scan detection events
func Portscan(format string, args ...any) {
	log.Printf("[PORTSCAN] "+format, args...)
}

// Login logs login monitoring events
func Login(format string, args ...any) {
	log.Printf("[LOGIN] "+format, args...)
}

// Watchdog logs dynamic watchdog events (pressure, mode changes, actions)
func Watchdog(format string, args ...any) {
	log.Printf("[WATCHDOG] "+format, args...)
}

// Daemon logs daemon lifecycle events
func Daemon(format string, args ...any) {
	log.Printf("[DAEMON] "+format, args...)
}

// IPC logs inter-process communication events
func IPC(format string, args ...any) {
	log.Printf("[IPC] "+format, args...)
}

// Module logs module lifecycle events
func Module(format string, args ...any) {
	log.Printf("[MODULE] "+format, args...)
}

// =============================================================================
// Severity-based Logging
// =============================================================================

// Error logs error messages with [ERROR] prefix
func Error(format string, args ...any) {
	log.Printf("[ERROR] "+format, args...)
}

// Warn logs warning messages with [WARN] prefix
func Warn(format string, args ...any) {
	log.Printf("[WARN] "+format, args...)
}

// Info logs informational messages with [INFO] prefix
func Info(format string, args ...any) {
	log.Printf("[INFO] "+format, args...)
}

// Debug logs debug messages with [DEBUG] prefix
func Debug(format string, args ...any) {
	log.Printf("[DEBUG] "+format, args...)
}

// =============================================================================
// Combined Category + Severity
// =============================================================================

// AuthError logs auth errors
func AuthError(format string, args ...any) {
	log.Printf("[AUTH][ERROR] "+format, args...)
}

// SecurityWarn logs security warnings
func SecurityWarn(format string, args ...any) {
	log.Printf("[SECURITY][WARN] "+format, args...)
}

// FirewallError logs firewall errors
func FirewallError(format string, args ...any) {
	log.Printf("[FIREWALL][ERROR] "+format, args...)
}

// WatchdogWarn logs watchdog warnings (pressure threshold breaches)
func WatchdogWarn(format string, args ...any) {
	log.Printf("[WATCHDOG][WARN] "+format, args...)
}

// WatchdogError logs watchdog errors
func WatchdogError(format string, args ...any) {
	log.Printf("[WATCHDOG][ERROR] "+format, args...)
}

// WatchdogCritical logs watchdog critical events (mode transitions to SURVIVAL)
func WatchdogCritical(format string, args ...any) {
	log.Printf("[WATCHDOG][CRITICAL] "+format, args...)
}

// DaemonError logs daemon errors
func DaemonError(format string, args ...any) {
	log.Printf("[DAEMON][ERROR] "+format, args...)
}

// =============================================================================
// Formatted Output (returns string instead of logging)
// =============================================================================

// Sprintf returns formatted string with category prefix (for custom logging)
func Sprintf(category, format string, args ...any) string {
	return fmt.Sprintf("[%s] "+format, append([]any{category}, args...)...)
}
