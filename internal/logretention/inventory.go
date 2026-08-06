// SPDX-License-Identifier: MPL-2.0
// meta:name="logretention-inventory"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-07-19"
// meta:description="Canonical NFTBan log-family inventory for the retention calculator + generated-policy renderer. Mirrors the shipped baseline install/config/nftban.logrotate + nftban-suricata.logrotate (grouping, cadence, rotation mechanism). BaseSizeBytes/BaseRotate are the ceilings the calculator will not exceed; the calculator scales the effective size/rotate down to fit the capacity budget. A parity test (inventory_parity_test.go) asserts this table stays in sync with the shipped templates and logs.go LogInventory()."
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
	Olddir         string // e.g. "/var/log/nftban/reports/archive" ("" = omit)
	CreateOlddir   string // e.g. "0750 nftban nftban" ("" = omit)
	UseMaxsize     bool   // emit `maxsize` instead of `size` (report documents)
	PostrotateUSR2 bool   // emit the Suricata USR2 postrotate reopen block

	// R11 (firewall-logs vs general-logs authority — Stream J minimum).
	SemanticClass string // ENFORCEMENT_AUDIT | SECURITY_EVENT | MODULE_HIGH_VOLUME | LIFECYCLE_FORENSICS | OPERATIONAL | DEBUG
	Primary       bool   // true = authoritative record; false = a projection/derived surface
}

// Semantic classes (R11). The most-sensitive class of a family's member logs
// drives its treatment; it is surfaced in `nftban logs retention status` so the
// operator can see which retention families are enforcement/security records vs
// ordinary operational/debug logs.
const (
	ClassEnforcementAudit = "ENFORCEMENT_AUDIT"
	ClassSecurityEvent    = "SECURITY_EVENT"
	ClassModuleHighVolume = "MODULE_HIGH_VOLUME"
	ClassLifecycle        = "LIFECYCLE_FORENSICS"
	ClassOperational      = "OPERATIONAL"
	ClassDebug            = "DEBUG"
)

// DefaultFamilies returns the canonical family inventory mirroring the corrected
// shipped baseline templates (Gate B Phase 1).
func DefaultFamilies() []LogFamily {
	const nft = "0640 nftban nftban"
	const suri = "suricata nftban"
	const suriCreate = "0640 suricata nftban"
	fams := []LogFamily{
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
			Paths: []string{"/var/log/nftban/permissions_audit.log"}},
		{Key: "reports", File: "main", Cadence: "monthly", Volume: VolumeLow, Fixed: true, BaseRotate: 3, BaseSizeBytes: 50 * MiB, UseMaxsize: true, Olddir: "/var/log/nftban/reports/archive", CreateOlddir: "0750 nftban nftban", FloorDays: 90,
			Paths: []string{"/var/log/nftban/reports/*.html", "/var/log/nftban/reports/*.txt", "/var/log/nftban/reports/*.json"}},
		{Key: "reports-daily", File: "main", Cadence: "monthly", Volume: VolumeLow, Fixed: true, BaseRotate: 3, BaseSizeBytes: 20 * MiB, UseMaxsize: true, FloorDays: 90,
			Paths: []string{"/var/log/nftban/reports/daily/*.html", "/var/log/nftban/reports/daily/*.txt"}},

		// Suricata-native (separate file, su suricata nftban). v1.222.0 R1: ALL eve
		// logs use copytruncate — Suricata holds the fd open and USR2 is a rule
		// reload, not a log reopen (rename+create+USR2 was a regression). A future
		// lane may switch to rename+create + a proven SIGHUP reopen with a
		// behavioral test.
		{Key: "suri-eve-alerts", File: "suricata", Cadence: "daily", Volume: VolumeMedium, Weight: 4, FloorDays: 7, BaseRotate: 7, BaseSizeBytes: 50 * MiB, Copytruncate: true, Su: suri, Create: suriCreate,
			Paths: []string{"/var/log/nftban/suricata/eve-alerts.json"}},
		{Key: "suri-eve-audit", File: "suricata", Cadence: "daily", Volume: VolumeHigh, Weight: 4, FloorDays: 3, BaseRotate: 3, BaseSizeBytes: 100 * MiB, Copytruncate: true, Su: suri, Create: suriCreate,
			Paths: []string{"/var/log/nftban/suricata/eve-audit.json"}},
		{Key: "suri-eve-stats", File: "suricata", Cadence: "weekly", Volume: VolumeLow, Weight: 1, FloorDays: 7, BaseRotate: 2, BaseSizeBytes: 50 * MiB, Copytruncate: true, Su: suri, Create: suriCreate,
			Paths: []string{"/var/log/nftban/suricata/eve-stats.json"}},
		{Key: "suri-fast", File: "suricata", Cadence: "weekly", Volume: VolumeLow, Weight: 1, FloorDays: 14, BaseRotate: 4, BaseSizeBytes: 50 * MiB, Copytruncate: true, Su: suri, Create: suriCreate,
			Paths: []string{"/var/log/nftban/suricata/fast.log"}},
		{Key: "suri-stats", File: "suricata", Cadence: "weekly", Volume: VolumeLow, Weight: 1, FloorDays: 14, BaseRotate: 4, BaseSizeBytes: 20 * MiB, Copytruncate: true, Su: suri, Create: suriCreate,
			Paths: []string{"/var/log/nftban/suricata/stats.log"}},
	}

	// R11/Z6: semantic class + authority role per family, from the AUTHORITATIVE
	// package-level map. Every family MUST be classified there (the completeness
	// test forbids silent defaulting); the OPERATIONAL/primary fallback here is a
	// runtime safety net that the test guarantees is never exercised.
	classes := semanticClassMap()
	for i := range fams {
		c, ok := classes[fams[i].Key]
		if !ok {
			c = semClass{ClassOperational, true}
		}
		fams[i].SemanticClass = c.class
		fams[i].Primary = c.primary
	}
	return fams
}

// semClass is a family's semantic class + authority role (primary source vs
// projection).
type semClass struct {
	class   string
	primary bool
}

// semanticClassMap is the AUTHORITATIVE family -> (semantic class, authority
// role) mapping. The class is the most-sensitive class of the family's member
// logs (it justifies the forensic floor and is surfaced by the CLI). Z6: the
// completeness test binds this map both ways — every family key here must
// correspond to a real family (no orphans) and every family must be listed here
// (no silent default) — and pins the exact ENFORCEMENT_AUDIT and SECURITY_EVENT
// sets so a downgrade or deletion fails.
func semanticClassMap() map[string]semClass {
	return map[string]semClass{
		"bans":              {ClassEnforcementAudit, true}, // durable/temporary ban source-of-truth
		"audit":             {ClassEnforcementAudit, true}, // ban/unban/config/whitelist + PAM audit actions
		"security-audit":    {ClassSecurityEvent, true},    // path-security audit events
		"permissions-audit": {ClassSecurityEvent, true},    // permission-enforcement audit
		"module-daily":      {ClassModuleHighVolume, true}, // ddos/portscan/trust operational+enforcement
		"portscan-events":   {ClassModuleHighVolume, true}, // per-event scan records
		"botguard":          {ClassModuleHighVolume, true}, // Go daemon classification/decisions
		"suricata-events":   {ClassSecurityEvent, true},    // NFTBan's suricata event processing log
		"suri-eve-alerts":   {ClassSecurityEvent, true},    // Suricata alert eve JSON
		"suri-eve-audit":    {ClassSecurityEvent, true},    // Suricata audit eve JSON
		"suri-fast":         {ClassSecurityEvent, false},   // fast.log = projection of alerts
		"suri-eve-stats":    {ClassOperational, false},     // stats projection
		"suri-stats":        {ClassOperational, false},     // stats projection
		"installer-update":  {ClassLifecycle, true},        // installer + update lifecycle
		"feeds-group":       {ClassOperational, true},      // feeds/geoban/botscan/rbl/login_alert/cron
		"main-app":          {ClassOperational, true},      // nftban/login-monitor/service-alerts
		"mail-queue-maint":  {ClassOperational, true},
		"tunnel":            {ClassOperational, true}, // advisory-only DNS-tunnel scoring
		"watchdog-subdir":   {ClassOperational, true},
		"reports":           {ClassOperational, true},
		"reports-daily":     {ClassOperational, true},
		"health-diag":       {ClassDebug, true}, // health-incidents/cli-errors/debug_trace/watchdog
	}
}

// SelfBoundedLog is a log NOT rotated by logrotate: it is bounded by its own
// writer/pruner. Z6 classifies these too, so the semantic-class coverage is
// complete across ALL nftban logs, not only the logrotate-managed families —
// the retention MECHANISM differs (prune vs rotate) but the SIEM/forensic class
// is still declared.
type SelfBoundedLog struct {
	Path          string // may contain <run_id> for per-run records
	SemanticClass string
	BoundedBy     string // the mechanism that bounds it (not logrotate)
}

// SelfBoundedForensicLogs returns the self-bounded (non-logrotate) nftban logs
// with their semantic class. The per-update-run record under
// /var/log/nftban/update-runs/<run_id>/ — run.jsonl (machine JSONL stream),
// human.log (operator slice), installer.log (per-run installer copy) — is
// LIFECYCLE_FORENSICS, bounded by _forensic_prune (keeps a fixed number of
// recent runs) rather than logrotate. Classifying them here closes the Z6 gap
// where these logs had no semantic class.
func SelfBoundedForensicLogs() []SelfBoundedLog {
	const boundedBy = "_forensic_prune (retains a fixed number of recent update-runs)"
	base := "/var/log/nftban/update-runs/<run_id>/"
	return []SelfBoundedLog{
		{base + "run.jsonl", ClassLifecycle, boundedBy},
		{base + "human.log", ClassLifecycle, boundedBy},
		{base + "installer.log", ClassLifecycle, boundedBy},
	}
}
