// SPDX-License-Identifier: MPL-2.0
// meta:name="logretention-inventory"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-07-19"
// meta:description="Canonical NFTBan log-family inventory for the retention calculator + generated-policy renderer. Mirrors the shipped baseline install/config/nftban.logrotate + nftban-suricata.logrotate (grouping, cadence, rotation mechanism). BaseSizeBytes/BaseRotate are the ceilings the calculator will not exceed; the calculator scales the effective size/rotate down to fit the capacity budget. A Phase-8 drift test asserts this table stays in sync with the shipped templates and logs.go LogInventory()."
// meta:depends="none (stdlib)"
// meta:inventory.files="internal/logretention/inventory.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.config_files="install/config/nftban.logrotate,install/config/nftban-suricata.logrotate"
// meta:inventory.privileges="none"
package logretention

// LogFamily describes one logrotate stanza's identity, budget metadata, and
// rotation mechanism. The mechanism fields mirror the corrected shipped
// templates so the renderer reproduces them faithfully.
type LogFamily struct {
	Key           string
	Paths         []string
	File          string // "main" | "suricata"
	Cadence       string // "daily" | "weekly" | "monthly"
	Volume        VolumeClass
	Weight        int    // weighted share of the distributable size budget
	FloorDays     int    // minimum retention (forensic floor) for this family
	CeilingDays   int    // per-family safety ceiling on retention (0 = derive from volume)
	BaseRotate    int    // reference rotate (shipped-baseline value)
	BaseSizeBytes uint64 // ceiling size cap (shipped-baseline value)
	Fixed         bool   // keep base policy, do not budget-scale (report documents)

	// rotation mechanism (reproduced verbatim by the renderer)
	Copytruncate   bool
	Delaycompress  bool
	Create         string // e.g. "0640 nftban nftban" ("" = omit)
	Su             string // e.g. "suricata nftban" ("" = omit)
	Olddir         string // e.g. "/var/lib/nftban/reports/archive" ("" = omit)
	CreateOlddir   string // e.g. "0750 nftban nftban" ("" = omit)
	UseMaxsize     bool   // emit `maxsize` instead of `size` (report documents)
	PostrotateUSR2 bool   // emit the Suricata USR2 postrotate reopen block
}

// DefaultFamilies returns the canonical family inventory mirroring the corrected
// shipped baseline templates (Gate B Phase 1).
func DefaultFamilies() []LogFamily {
	const nft = "0640 nftban nftban"
	const suri = "suricata nftban"
	const suriCreate = "0640 suricata nftban"
	return []LogFamily{
		{Key: "main-app", File: "main", Cadence: "weekly", Volume: VolumeMedium, Weight: 6, FloorDays: 14, BaseRotate: 4, BaseSizeBytes: 50 * MiB, Copytruncate: true, Create: nft,
			Paths: []string{"/var/log/nftban/nftban.log", "/var/log/nftban/login-monitor.log", "/var/log/nftban/service-alerts.log"}},
		{Key: "bans", File: "main", Cadence: "weekly", Volume: VolumeMedium, Weight: 4, FloorDays: 30, BaseRotate: 12, BaseSizeBytes: 10 * MiB, Delaycompress: true, Create: nft,
			Paths: []string{"/var/log/nftban/bans.log"}}, // rename+create (metrics SoT)
		{Key: "mail-queue-maint", File: "main", Cadence: "weekly", Volume: VolumeLow, Weight: 3, FloorDays: 14, BaseRotate: 4, BaseSizeBytes: 20 * MiB, Copytruncate: true, Create: nft,
			Paths: []string{"/var/log/nftban/mail.log", "/var/log/nftban/queue.log", "/var/log/nftban/maintenance.log"}},
		{Key: "module-daily", File: "main", Cadence: "daily", Volume: VolumeHigh, Weight: 16, FloorDays: 7, BaseRotate: 30, BaseSizeBytes: 100 * MiB, Copytruncate: true, Create: nft,
			Paths: []string{"/var/log/nftban/ddos.log", "/var/log/nftban/ddos-classic.log", "/var/log/nftban/ddos-suricata.log", "/var/log/nftban/login-suricata.log", "/var/log/nftban/portscan.log", "/var/log/nftban/portscan-suricata.log", "/var/log/nftban/portscan-classic.log", "/var/log/nftban/trust.log"}},
		{Key: "feeds-group", File: "main", Cadence: "weekly", Volume: VolumeMedium, Weight: 6, FloorDays: 14, BaseRotate: 12, BaseSizeBytes: 50 * MiB, Copytruncate: true, Create: nft,
			Paths: []string{"/var/log/nftban/feeds.log", "/var/log/nftban/geoban.log", "/var/log/nftban/botscan.log", "/var/log/nftban/login_alert.log", "/var/log/nftban/cron.log", "/var/log/nftban/soak/cron.log", "/var/log/nftban/rbl.log"}},
		{Key: "security-audit", File: "main", Cadence: "weekly", Volume: VolumeLow, Weight: 2, FloorDays: 30, BaseRotate: 12, BaseSizeBytes: 20 * MiB, Copytruncate: true, Create: nft,
			Paths: []string{"/var/log/nftban/security-audit.log"}},
		{Key: "portscan-events", File: "main", Cadence: "daily", Volume: VolumeHigh, Weight: 6, FloorDays: 7, BaseRotate: 30, BaseSizeBytes: 100 * MiB, Copytruncate: true, Create: nft,
			Paths: []string{"/var/log/nftban/portscan-events.log"}},
		{Key: "tunnel", File: "main", Cadence: "weekly", Volume: VolumeLow, Weight: 2, FloorDays: 14, BaseRotate: 12, BaseSizeBytes: 20 * MiB, Copytruncate: true, Create: nft,
			Paths: []string{"/var/log/nftban/tunnel.log"}},
		{Key: "botguard", File: "main", Cadence: "daily", Volume: VolumeHigh, Weight: 8, FloorDays: 7, BaseRotate: 30, BaseSizeBytes: 100 * MiB, Copytruncate: true, Create: nft,
			Paths: []string{"/var/log/nftban/botguard/botguard.log", "/var/log/nftban/botguard/decisions.log"}},
		{Key: "watchdog-subdir", File: "main", Cadence: "weekly", Volume: VolumeLow, Weight: 2, FloorDays: 14, BaseRotate: 4, BaseSizeBytes: 20 * MiB, Copytruncate: true, Create: nft,
			Paths: []string{"/var/log/nftban/watchdog/alerts.log", "/var/log/nftban/watchdog/stats.log", "/var/log/nftban/watchdog/profiles.log"}},
		{Key: "audit", File: "main", Cadence: "daily", Volume: VolumeMedium, Weight: 6, FloorDays: 30, BaseRotate: 90, BaseSizeBytes: 50 * MiB, Copytruncate: true, Create: nft,
			Paths: []string{"/var/log/nftban/nftban-actions.log", "/var/log/nftban/audit.log"}},
		{Key: "health-diag", File: "main", Cadence: "weekly", Volume: VolumeMedium, Weight: 4, FloorDays: 14, BaseRotate: 12, BaseSizeBytes: 50 * MiB, Copytruncate: true, Create: nft,
			Paths: []string{"/var/log/nftban/health-incidents.log", "/var/log/nftban/cli-errors.log", "/var/log/nftban/debug_trace.log", "/var/log/nftban/watchdog.log"}},
		{Key: "suricata-events", File: "main", Cadence: "daily", Volume: VolumeHigh, Weight: 6, FloorDays: 7, BaseRotate: 30, BaseSizeBytes: 100 * MiB, Copytruncate: true, Create: nft,
			Paths: []string{"/var/log/nftban/suricata-events.log"}},
		{Key: "installer-update", File: "main", Cadence: "weekly", Volume: VolumeLow, Weight: 2, FloorDays: 30, BaseRotate: 8, BaseSizeBytes: 20 * MiB, Copytruncate: true, Create: nft,
			Paths: []string{"/var/log/nftban/installer.log", "/var/log/nftban/update.log"}},
		{Key: "permissions-audit", File: "main", Cadence: "weekly", Volume: VolumeLow, Weight: 1, FloorDays: 30, BaseRotate: 12, BaseSizeBytes: 10 * MiB, Copytruncate: true, Create: nft,
			Paths: []string{"/var/lib/nftban/permissions_audit.log"}},
		{Key: "reports", File: "main", Cadence: "monthly", Volume: VolumeLow, Fixed: true, BaseRotate: 3, BaseSizeBytes: 50 * MiB, UseMaxsize: true, Olddir: "/var/lib/nftban/reports/archive", CreateOlddir: "0750 nftban nftban", FloorDays: 90,
			Paths: []string{"/var/lib/nftban/reports/*.html", "/var/lib/nftban/reports/*.txt", "/var/lib/nftban/reports/*.json"}},
		{Key: "reports-daily", File: "main", Cadence: "monthly", Volume: VolumeLow, Fixed: true, BaseRotate: 3, BaseSizeBytes: 20 * MiB, UseMaxsize: true, FloorDays: 90,
			Paths: []string{"/var/lib/nftban/reports/daily/*.html", "/var/lib/nftban/reports/daily/*.txt"}},

		// Suricata-native (separate file, su suricata nftban). eve-alerts/eve-audit
		// = rename+create + USR2 (JSON record-integrity); delaycompress required.
		{Key: "suri-eve-alerts", File: "suricata", Cadence: "daily", Volume: VolumeMedium, Weight: 4, FloorDays: 7, BaseRotate: 7, BaseSizeBytes: 50 * MiB, Delaycompress: true, Su: suri, Create: suriCreate, PostrotateUSR2: true,
			Paths: []string{"/var/log/nftban/suricata/eve-alerts.json"}},
		{Key: "suri-eve-audit", File: "suricata", Cadence: "daily", Volume: VolumeHigh, Weight: 4, FloorDays: 3, BaseRotate: 3, BaseSizeBytes: 100 * MiB, Delaycompress: true, Su: suri, Create: suriCreate, PostrotateUSR2: true,
			Paths: []string{"/var/log/nftban/suricata/eve-audit.json"}},
		{Key: "suri-eve-stats", File: "suricata", Cadence: "weekly", Volume: VolumeLow, Weight: 1, FloorDays: 7, BaseRotate: 2, BaseSizeBytes: 50 * MiB, Copytruncate: true, Su: suri, Create: suriCreate,
			Paths: []string{"/var/log/nftban/suricata/eve-stats.json"}},
		{Key: "suri-fast", File: "suricata", Cadence: "weekly", Volume: VolumeLow, Weight: 1, FloorDays: 14, BaseRotate: 4, BaseSizeBytes: 50 * MiB, Copytruncate: true, Su: suri, Create: suriCreate,
			Paths: []string{"/var/log/nftban/suricata/fast.log"}},
		{Key: "suri-stats", File: "suricata", Cadence: "weekly", Volume: VolumeLow, Weight: 1, FloorDays: 14, BaseRotate: 4, BaseSizeBytes: 20 * MiB, Copytruncate: true, Su: suri, Create: suriCreate,
			Paths: []string{"/var/log/nftban/suricata/stats.log"}},
	}
}
