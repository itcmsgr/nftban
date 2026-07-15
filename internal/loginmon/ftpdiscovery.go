// =============================================================================
// NFTBan v1.180.0 - LoginMon FTP log discovery (auth_failure source)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: loginmon
// Purpose: Discovery of FTP daemon logs for the LoginMon auth_failure event class
//          (pure-ftpd / vsftpd / proftpd authentication-failure lines).
//
// meta:name="loginmon_ftpdiscovery"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="loginmon"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-13"
// meta:description="Discovers FILE-logging FTP daemon logs (vsftpd /var/log/vsftpd.log, proftpd /var/log/proftpd/*.log + auth.log) for the LoginMon FTPDetector. pure-ftpd is intentionally NOT globbed here: it logs auth failures to syslog facility ftp (11) by default (its dedicated AltLog is stats-only), so it is consumed by runJournalWatcher (SYSLOG_FACILITY=11) — excluding it from files avoids tailing a no-auth file and double-counting clf-configured hosts. Verified against live fleet traffic (the fleet hosts run pure-ftpd; pureftpd.log empty/stats while '(?@<ip>) Authentication failed' appears at journal facility 11). The LoginMon module runs inside the root nftband.service (CAP_DAC_OVERRIDE) so it reads these directly — NOT via a collector/spool. Owns ONLY the auth_failure event class (ReasonFTPAuthFail); no other module bans FTP auth failures. Existence + regular-file filter, excludes rotated/.gz, dedups on the canonical path, bounds to the most-recently-modified files (one tail -F per file, reusing discoverFromGlobs). Mirrors the v1.179 web discovery pattern."
//
// meta:inventory.files="ftpdiscovery.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package loginmon

// ftpStackDetected reports whether an FTP daemon that produces auth logs is present
// — used to distinguish WARN_NO_LOGS (daemon present, no logs) from NO_LOGS. The FTP
// daemons are recorded in detectedServices by detectServices() under their package
// names (pure-ftpd / vsftpd / proftpd).
func (m *Module) ftpStackDetected() bool {
	return m.detectedServices["pure-ftpd"] || m.detectedServices["vsftpd"] ||
		m.detectedServices["proftpd"]
}

// ftpJournalDaemonDetected reports whether a journal-routed FTP daemon is present.
// pure-ftpd logs auth failures to syslog facility ftp (11) by default — NOT to a
// dedicated auth file (its AltLog is stats-only) — so it is consumed via the journal
// watcher (SYSLOG_FACILITY=11), not a file watcher. Verified against live fleet
// traffic (the fleet hosts all run pure-ftpd; /var/log/pureftpd.log is stats/empty while the
// "(?@<ip>) Authentication failed" lines appear at journal facility 11).
func (m *Module) ftpJournalDaemonDetected() bool {
	return m.detectedServices["pure-ftpd"]
}

// ftpFileDaemonDetected reports whether a file-logging FTP daemon is present. vsftpd
// (/var/log/vsftpd.log) and proftpd (/var/log/proftpd/*.log) default to their own log
// files, so they are consumed via FTP file watchers — NOT the journal.
func (m *Module) ftpFileDaemonDetected() bool {
	return m.detectedServices["vsftpd"] || m.detectedServices["proftpd"]
}

// ftpLogGlobs returns FTP-daemon log globs for the FILE-logging daemons only
// (vsftpd, proftpd). pure-ftpd is intentionally excluded: it is journal-routed
// (facility 11) and its dedicated file carries stats, not auth failures — globbing
// it would tail a no-auth file and risk double-counting clf-configured hosts.
func (m *Module) ftpLogGlobs() []string {
	var g []string
	if m.detectedServices["vsftpd"] {
		g = append(g,
			"/var/log/vsftpd.log",
			"/var/log/vsftpd/*.log",
		)
	}
	if m.detectedServices["proftpd"] {
		g = append(g,
			"/var/log/proftpd/*.log",
			"/var/log/proftpd/auth.log",
			"/var/log/proftpd.log",
		)
	}
	return g
}

// discoverFTPLogs returns existing, regular, non-rotated/.gz FTP log files
// (canonicalized), bounded to the most-recently-modified webAuthMaxFiles. The root
// daemon reads them directly (no collector/spool). Reuses the shared discoverFromGlobs
// core (glob → canonicalize → regular-file + non-excluded filter → dedup → mtime bound)
// — isExcludedWebLog still applies (drops .gz + trailing ".<digits>" rotated files; the
// "error_log" exclusion is irrelevant to FTP file names).
func (m *Module) discoverFTPLogs() []string {
	return discoverFromGlobs(m.ftpLogGlobs())
}
