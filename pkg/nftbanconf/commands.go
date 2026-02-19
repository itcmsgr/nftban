// =============================================================================
// NFTBan - CLI Command Builders
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="commands"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Build CLI command strings using central config paths"
// meta:input="None"
// meta:output="Command paths and feature flags"
// meta:depends="path/filepath"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/nftban.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package nftbanconf

// =============================================================================
// CLI Command Builders
// =============================================================================
// Purpose: Build CLI command strings using central config paths
//          This eliminates hardcoded paths scattered across the codebase
//
// Usage:
//   cmd := nftbanconf.Commands()
//   exec.Command(cmd.Bin, "status")  // Uses NFTBAN_BIN from config
//   exec.Command(cmd.CoreBin, "sync") // Uses NFTBAN_CORE_BIN from config
// =============================================================================

import (
	"fmt"
	"path/filepath"
)

// CommandPaths provides paths to CLI binaries and scripts
type CommandPaths struct {
	cfg   *Config
	paths *Paths
}

// Commands returns command path builder (loads config if needed)
func Commands() *CommandPaths {
	return &CommandPaths{
		cfg:   Get(),
		paths: GetPaths(),
	}
}

// =============================================================================
// Binary Paths - Main executables
// =============================================================================

// Bin returns path to main nftban CLI (bash wrapper)
func (c *CommandPaths) Bin() string {
	return c.cfg.Bin
}

// CoreBin returns path to nftban-core Go binary
func (c *CommandPaths) CoreBin() string {
	return c.cfg.CoreBin
}

// UIBin returns path to nftban-ui Go binary
func (c *CommandPaths) UIBin() string {
	return c.cfg.UIBin
}

// AuthBin returns path to nftban-ui-auth helper
func (c *CommandPaths) AuthBin() string {
	return c.cfg.AuthBin
}

// =============================================================================
// Library Scripts - Bash modules in NFTBAN_LIB_DIR
// =============================================================================

// LibScript returns path to a library script
// Example: LibScript("core", "nftban_sync.sh") -> /usr/lib/nftban/core/nftban_sync.sh
func (c *CommandPaths) LibScript(subdir, script string) string {
	return filepath.Join(c.cfg.LibDir, subdir, script)
}

// CoreScript returns path to core library script
func (c *CommandPaths) CoreScript(name string) string {
	return c.LibScript("core", name)
}

// CLIScript returns path to CLI command script
func (c *CommandPaths) CLIScript(name string) string {
	return c.LibScript("cli", name)
}

// ExporterScript returns path to exporter script
func (c *CommandPaths) ExporterScript(name string) string {
	return c.LibScript("exporters", name)
}

// HelperScript returns path to helper script
func (c *CommandPaths) HelperScript(name string) string {
	return c.LibScript("helpers", name)
}

// SetupScript returns path to setup script
func (c *CommandPaths) SetupScript(name string) string {
	return c.LibScript("setup", name)
}

// =============================================================================
// Well-Known Script Paths
// =============================================================================

// SyncScript returns path to nftban_sync.sh
func (c *CommandPaths) SyncScript() string {
	return c.CoreScript("nftban_sync.sh")
}

// HealthScript returns path to nftban_health.sh
func (c *CommandPaths) HealthScript() string {
	return c.CoreScript("nftban_health.sh")
}

// StatsScript returns path to nftban_stats.sh
func (c *CommandPaths) StatsScript() string {
	return c.CoreScript("nftban_stats.sh")
}

// NFTablesScript returns path to nftban_nftables.sh
func (c *CommandPaths) NFTablesScript() string {
	return c.CoreScript("nftban_nftables.sh")
}

// ValidatorScript returns path to nftban_validator.sh
func (c *CommandPaths) ValidatorScript() string {
	return c.CoreScript("nftban_validator.sh")
}

// GeoIPDownloadScript returns path to geoip download script
func (c *CommandPaths) GeoIPDownloadScript() string {
	return c.CoreScript("nftban_geoip_download.sh")
}

// PrometheusExporter returns path to prometheus exporter
func (c *CommandPaths) PrometheusExporter() string {
	return c.ExporterScript("nftban_prometheus_exporter.sh")
}

// =============================================================================
// Config File Paths
// =============================================================================

// MainConfig returns path to main nftban.conf
func (c *CommandPaths) MainConfig() string {
	return filepath.Join(c.cfg.ConfigDir, "nftban.conf")
}

// WhitelistConfig returns path to main whitelist.conf
func (c *CommandPaths) WhitelistConfig() string {
	return filepath.Join(c.cfg.ConfigDir, "whitelist.conf")
}

// WhitelistD returns path to whitelist.d directory
func (c *CommandPaths) WhitelistD() string {
	return c.paths.WhitelistD
}

// BlacklistD returns path to blacklist.d directory
func (c *CommandPaths) BlacklistD() string {
	return c.paths.BlacklistD
}

// PortsD returns path to ports.d directory
func (c *CommandPaths) PortsD() string {
	return c.paths.PortsD
}

// GeobanD returns path to geoban.d directory
func (c *CommandPaths) GeobanD() string {
	return c.paths.GeobanD
}

// =============================================================================
// Data File Paths
// =============================================================================

// FeedsDir returns path to feeds data directory
func (c *CommandPaths) FeedsDir() string {
	return c.paths.FeedsDir
}

// GeoIPDir returns path to geoip data directory
func (c *CommandPaths) GeoIPDir() string {
	return c.paths.GeoIPDir
}

// MetricsDir returns path to metrics data directory
func (c *CommandPaths) MetricsDir() string {
	return c.paths.MetricsDir
}

// SnapshotsDir returns path to snapshots directory
func (c *CommandPaths) SnapshotsDir() string {
	return c.paths.SnapshotsDir
}

// ReportsDir returns path to reports directory
func (c *CommandPaths) ReportsDir() string {
	return c.paths.ReportsDir
}

// ExportsDir returns path to exports directory
func (c *CommandPaths) ExportsDir() string {
	return c.paths.ExportsDir
}

// =============================================================================
// Log File Paths
// =============================================================================

// MainLog returns path to main nftban.log
func (c *CommandPaths) MainLog() string {
	return c.paths.MainLog
}

// AuditLog returns path to audit log (actions)
func (c *CommandPaths) AuditLog() string {
	return c.paths.AuditLog
}

// BansLog returns path to bans log
func (c *CommandPaths) BansLog() string {
	return c.paths.BansLog
}

// =============================================================================
// Runtime File Paths
// =============================================================================

// PIDFile returns path to PID file
func (c *CommandPaths) PIDFile() string {
	return c.paths.PIDFile
}

// SocketFile returns path to socket file
func (c *CommandPaths) SocketFile() string {
	return c.paths.SocketFile
}

// =============================================================================
// Metrics File Paths
// =============================================================================

// PrometheusFile returns path to prometheus metrics file
func (c *CommandPaths) PrometheusFile() string {
	return c.paths.PrometheusFile
}

// MetricsJSON returns path to JSON metrics file
func (c *CommandPaths) MetricsJSON() string {
	return c.paths.MetricsJSON
}

// =============================================================================
// NFT Command Helpers
// =============================================================================

// NFTTableIPv4 returns the IPv4 table reference (e.g., "ip nftban")
func (c *CommandPaths) NFTTableIPv4() string {
	return GetNFT().TableIPv4
}

// NFTTableIPv6 returns the IPv6 table reference (e.g., "ip6 nftban")
func (c *CommandPaths) NFTTableIPv6() string {
	return GetNFT().TableIPv6
}

// NFTSetBlacklist returns the blacklist set name for the given IP family
func (c *CommandPaths) NFTSetBlacklist(ipv4 bool) string {
	nft := GetNFT()
	if ipv4 {
		return nft.BlacklistIPv4
	}
	return nft.BlacklistIPv6
}

// NFTSetWhitelist returns the whitelist set name for the given IP family
func (c *CommandPaths) NFTSetWhitelist(ipv4 bool) string {
	nft := GetNFT()
	if ipv4 {
		return nft.WhitelistIPv4
	}
	return nft.WhitelistIPv6
}

// v2.1: All bans go to blacklist (NFTSetBlacklist)
// Source tracking (feeds, geoban, auto, manual) is done in daemon database

// =============================================================================
// Feature Check Helpers
// =============================================================================

// IsMetricsEnabled returns true if metrics are enabled
func (c *CommandPaths) IsMetricsEnabled() bool {
	return c.cfg.MetricsEnabled
}

// IsGeoIPEnabled returns true if GeoIP is enabled
func (c *CommandPaths) IsGeoIPEnabled() bool {
	return c.cfg.GeoIPEnabled
}

// IsFeedsEnabled returns true if threat feeds are enabled
func (c *CommandPaths) IsFeedsEnabled() bool {
	return c.cfg.FeedsEnabled
}

// IsSuricataEnabled returns true if Suricata integration is enabled
func (c *CommandPaths) IsSuricataEnabled() bool {
	return c.cfg.SuricataEnabled
}

// IsGUIEnabled returns true if web GUI is enabled
func (c *CommandPaths) IsGUIEnabled() bool {
	return c.cfg.GUIEnabled
}

// IsPortscanEnabled returns true if portscan detection is enabled
func (c *CommandPaths) IsPortscanEnabled() bool {
	return c.cfg.PortscanEnabled
}

// IsDDoSEnabled returns true if DDoS protection is enabled
func (c *CommandPaths) IsDDoSEnabled() bool {
	return c.cfg.DDoSEnabled
}

// IsLoginMonitorEnabled returns true if login monitoring is enabled
func (c *CommandPaths) IsLoginMonitorEnabled() bool {
	return c.cfg.LoginMonitorEnabled
}

// =============================================================================
// GUI/API Settings
// =============================================================================

// GUIAddr returns the GUI listen address
func (c *CommandPaths) GUIAddr() string {
	return c.cfg.GUIAddr
}

// MetricsBackend returns the metrics backend type
func (c *CommandPaths) MetricsBackend() string {
	return c.cfg.MetricsBackend
}

// =============================================================================
// Version Info
// =============================================================================

// Version returns NFTBan version string
func (c *CommandPaths) Version() string {
	return c.cfg.Version
}

// ConfigVersion returns config file version
func (c *CommandPaths) ConfigVersion() string {
	return c.cfg.ConfigVersion
}

// =============================================================================
// Convenience Builders
// =============================================================================

// FeedFile returns path to a specific feed file
// Example: FeedFile("firehol_level1.netset") -> /var/lib/nftban/feeds/firehol_level1.netset
func (c *CommandPaths) FeedFile(name string) string {
	return filepath.Join(c.paths.FeedsDir, name)
}

// GeoIPFile returns path to a specific GeoIP file
// Example: GeoIPFile("GR.zone") -> /var/lib/nftban/geoip/GR.zone
func (c *CommandPaths) GeoIPFile(name string) string {
	return filepath.Join(c.paths.GeoIPDir, name)
}

// SnapshotFile returns path to a snapshot file
func (c *CommandPaths) SnapshotFile(name string) string {
	return filepath.Join(c.paths.SnapshotsDir, name)
}

// ExportFile returns path to an export file
func (c *CommandPaths) ExportFile(name string) string {
	return filepath.Join(c.paths.ExportsDir, name)
}

// ReportFile returns path to a report file
func (c *CommandPaths) ReportFile(name string) string {
	return filepath.Join(c.paths.ReportsDir, name)
}

// CacheFile returns path to a cache file
func (c *CommandPaths) CacheFile(name string) string {
	return filepath.Join(c.cfg.CacheDir, name)
}

// TempFile returns path to a temp file in run directory
func (c *CommandPaths) TempFile(name string) string {
	return filepath.Join(c.cfg.RunDir, name)
}

// ConfigFile returns path to a config file
func (c *CommandPaths) ConfigFile(name string) string {
	return filepath.Join(c.cfg.ConfigDir, name)
}

// LogFile returns path to a log file
func (c *CommandPaths) LogFile(name string) string {
	return filepath.Join(c.cfg.LogDir, name)
}

// =============================================================================
// Debug Helpers
// =============================================================================

// DebugString returns a summary of all paths for debugging
func (c *CommandPaths) DebugString() string {
	return fmt.Sprintf(`NFTBan Command Paths:
  Binaries:
    Bin:      %s
    CoreBin:  %s
    UIBin:    %s
    AuthBin:  %s
  Directories:
    LibDir:    %s
    ConfigDir: %s
    DataDir:   %s
    LogDir:    %s
    CacheDir:  %s
    RunDir:    %s
  Features:
    Metrics:   %v (backend: %s)
    GeoIP:     %v
    Feeds:     %v
    Suricata:  %v
    GUI:       %v (addr: %s)
    Portscan:  %v
    DDoS:      %v
    Login:     %v`,
		c.cfg.Bin, c.cfg.CoreBin, c.cfg.UIBin, c.cfg.AuthBin,
		c.cfg.LibDir, c.cfg.ConfigDir, c.cfg.DataDir, c.cfg.LogDir, c.cfg.CacheDir, c.cfg.RunDir,
		c.cfg.MetricsEnabled, c.cfg.MetricsBackend,
		c.cfg.GeoIPEnabled, c.cfg.FeedsEnabled, c.cfg.SuricataEnabled,
		c.cfg.GUIEnabled, c.cfg.GUIAddr,
		c.cfg.PortscanEnabled, c.cfg.DDoSEnabled, c.cfg.LoginMonitorEnabled,
	)
}
