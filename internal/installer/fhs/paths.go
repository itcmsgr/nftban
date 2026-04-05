// =============================================================================
// NFTBan v1.73 - Installer FHS Path Constants
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-fhs-paths"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="FHS-compliant path constants matching fhs-spec.yaml"
// meta:inventory.files="internal/installer/fhs/paths.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package fhs

// All paths match the FHS spec in build/fhs-spec.yaml and are enforced
// by cli/lib/nftban/setup/fhs-permissions.sh at install time.
//
// Ownership/permission contract (from fhs-permissions.sh):
//   /etc/nftban/*.conf          → root:nftban  0640
//   /etc/nftban/*.local         → root:nftban  0640
//   /usr/lib/nftban/*.sh        → root:root    0755
//   /usr/lib/nftban/bin/*       → root:root    0755 (+ cap_net_admin on core/daemon)
//   /usr/lib/nftban/sbin/*      → root:root    0755
//   /usr/sbin/nftban*           → root:nftban  0750
//   /var/lib/nftban/*           → nftban:nftban 0640
//   /var/lib/nftban/reports/auditors/* → root:nftban-auditor 0660
//   /var/log/nftban/*           → nftban:nftban 0640
//   /var/log/nftban/suricata/*  → suricata:nftban 0640

// --- Configuration ---

const (
	// EtcDir is the main configuration directory.
	EtcDir = "/etc/nftban"

	// MainConf is the primary configuration file.
	MainConf = "/etc/nftban/nftban.conf"

	// MainConfLocal is the local override configuration file.
	MainConfLocal = "/etc/nftban/nftban.conf.local"

	// ConfDir is the drop-in configuration directory.
	ConfDir = "/etc/nftban/conf.d"

	// WhitelistDir contains whitelist configuration files.
	WhitelistDir = "/etc/nftban/whitelist.d"

	// BlacklistDir contains blacklist configuration files.
	BlacklistDir = "/etc/nftban/blacklist.d"

	// PortsDir contains port configuration files.
	PortsDir = "/etc/nftban/ports.d"
)

// --- Installation ---

const (
	// LibDir is the main installation directory.
	LibDir = "/usr/lib/nftban"

	// BinDir contains binary executables.
	BinDir = "/usr/lib/nftban/bin"

	// SbinDir contains privileged binary executables.
	SbinDir = "/usr/lib/nftban/sbin"

	// SetupDir contains setup scripts.
	SetupDir = "/usr/lib/nftban/setup"

	// CLIDir contains CLI command scripts.
	CLIDir = "/usr/lib/nftban/cli"

	// CoreDir contains core firewall scripts.
	CoreDir = "/usr/lib/nftban/core"

	// TemplatesDir contains nftables templates.
	TemplatesDir = "/usr/lib/nftban/templates"
)

// --- Runtime data ---

const (
	// DataDir is the variable data directory.
	DataDir = "/var/lib/nftban"

	// StateDir contains runtime state files (install_state, etc.).
	StateDir = "/var/lib/nftban/state"

	// FeedsDir contains threat feed data.
	FeedsDir = "/var/lib/nftban/feeds"

	// PanelsDir contains panel state files.
	PanelsDir = "/var/lib/nftban/panels"
)

// --- Logs ---

const (
	// LogDir is the log directory.
	LogDir = "/var/log/nftban"

	// InstallerLog is the installer's persistent log file.
	InstallerLog = "/var/log/nftban/installer.log"

	// UpdateLog is the update log file.
	UpdateLog = "/var/log/nftban/update.log"

	// MainLog is the main nftban log file.
	MainLog = "/var/log/nftban/nftban.log"
)

// --- Runtime ---

const (
	// RunDir is the runtime directory (cleared on reboot).
	RunDir = "/run/nftban"

	// RunUIDir is the UI socket directory.
	RunUIDir = "/run/nftban-ui"
)

// --- Cache ---

const (
	// CacheDir is the cache directory.
	CacheDir = "/var/cache/nftban"
)

// --- Share ---

const (
	// ShareDir is the shared data directory.
	ShareDir = "/usr/share/nftban"
)

// --- External ---

const (
	// NodeExporterDir is the node_exporter textfile collector directory.
	NodeExporterDir = "/var/lib/node_exporter/textfile_collector"
)

// --- Key files ---

const (
	// VersionFile holds the installed version number.
	VersionFile = "/usr/lib/nftban/VERSION"

	// SchemaVersionFile holds the nftables schema version.
	SchemaVersionFile = "/etc/nftban/.schema_version"

	// AuthorityFile records the install authority decision.
	AuthorityFile = "/var/lib/nftban/state/authority"

	// SSHPortState records the detected SSH port.
	SSHPortState = "/var/lib/nftban/state/ssh_port_active.state"

	// UpdateHistoryJSON is the JSON update history file.
	UpdateHistoryJSON = "/var/lib/nftban/update-history.json"

	// InstallFailedMarker signals a failed installation to runtime CLI.
	InstallFailedMarker = "/run/nftban/install_failed"

	// NftablesConf is the system nftables configuration file.
	NftablesConf = "/etc/nftables.conf"

	// FHSPermissionsScript is the generated FHS permissions script.
	FHSPermissionsScript = "/usr/lib/nftban/setup/fhs-permissions.sh"

	// TmpfilesConf is the systemd-tmpfiles configuration file.
	TmpfilesConf = "/usr/lib/tmpfiles.d/nftban.conf"
)

// --- Binaries ---

const (
	// NftbanCoreBin is the main nftban-core Go binary.
	NftbanCoreBin = "/usr/lib/nftban/bin/nftban-core"

	// NftbandBin is the nftband daemon Go binary.
	NftbandBin = "/usr/lib/nftban/bin/nftband"

	// NftbanInstallerBin is the Go-based installer binary.
	NftbanInstallerBin = "/usr/lib/nftban/bin/nftban-installer"

	// NftbanCLI is the main nftban CLI wrapper.
	NftbanCLI = "/usr/sbin/nftban"
)

// Directories that must exist for NFTBan to operate correctly.
// All dirs from the old shell postinst are included for full parity.
var RequiredDirs = []struct {
	Path string
	Mode uint32
}{
	// /etc/nftban/
	{EtcDir, 0750},
	{ConfDir, 0750},
	{EtcDir + "/distros", 0750},
	{WhitelistDir, 0750},
	{BlacklistDir, 0750},
	{PortsDir, 0750},
	{EtcDir + "/rules.d", 0750},
	// /etc/nftban/suricata/
	{EtcDir + "/suricata", 0750},
	{EtcDir + "/suricata/profiles", 0750},
	{EtcDir + "/suricata/config", 0750},
	{EtcDir + "/suricata/rules", 0750},
	{EtcDir + "/suricata/cache", 0750},
	{EtcDir + "/suricata/state", 0750},
	{EtcDir + "/suricata/state/last-good", 0750},
	// /var/lib/nftban/ (synced with install/systemd/tmpfiles.d/nftban.conf)
	{DataDir, 0750},
	{StateDir, 0750},
	{FeedsDir, 0750},
	{PanelsDir, 0750},
	{DataDir + "/banned", 0750},
	{DataDir + "/whitelist", 0750},
	{DataDir + "/geoip", 0750},
	{DataDir + "/reports", 0750},
	{DataDir + "/reports/baseline", 0750},
	{DataDir + "/reports/auditors", 0770},
	{DataDir + "/reports/watchdog", 0750},
	{DataDir + "/reports/archive", 0750},
	{DataDir + "/config", 0750},
	{DataDir + "/metrics", 0750},
	{DataDir + "/snapshots", 0750},
	{DataDir + "/exports", 0750},
	{DataDir + "/stats", 0750},
	{DataDir + "/stats/history", 0750},
	{DataDir + "/stats/profiles", 0750},
	{DataDir + "/queue", 0750},
	{DataDir + "/queue/pending", 0750},
	{DataDir + "/queue/work", 0750},
	{DataDir + "/queue/dlq", 0750},
	{DataDir + "/mailspool", 0750},
	{DataDir + "/botguard", 0750},
	{DataDir + "/tunnel", 0750},
	{DataDir + "/analytics", 0750},
	{DataDir + "/backup", 0750},
	{DataDir + "/login", 0750},
	{DataDir + "/portscan", 0750},
	{DataDir + "/recorder", 0750},
	{DataDir + "/staging", 0750},
	{DataDir + "/suricata", 0750},
	{DataDir + "/update-backups", 0750},
	{DataDir + "/watchdog", 0750},
	{DataDir + "/pro", 0750},
	// /var/log/nftban/ (synced with install/systemd/tmpfiles.d/nftban.conf)
	{LogDir, 0750},
	{LogDir + "/reports", 0750},
	{LogDir + "/watchdog", 0750},
	{LogDir + "/rbl", 0750},
	{LogDir + "/botguard", 0750},
	{LogDir + "/suricata", 0750},
	{LogDir + "/metrics", 0750},
	// /var/cache/nftban/
	{CacheDir, 0750},
	{CacheDir + "/health", 0750},
	// /run/
	{RunDir, 0755},
	{RunUIDir, 0750},
	// /usr/share/nftban/
	{ShareDir + "/templates", 0755},
	{ShareDir + "/templates/mail", 0755},
	{ShareDir + "/templates/reports", 0755},
	// /var/lib/node_exporter/textfile_collector
	{NodeExporterDir, 0755},
}
