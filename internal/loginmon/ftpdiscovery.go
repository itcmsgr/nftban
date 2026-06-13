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
// meta:description="Discovers FTP daemon log files (pure-ftpd /var/log/pureftpd.log + /var/log/pure-ftpd/*.log, vsftpd /var/log/vsftpd.log, proftpd /var/log/proftpd/*.log + auth.log) for the LoginMon FTPDetector. The LoginMon module runs inside the root nftband.service (CAP_DAC_OVERRIDE) so it reads these directly — NOT via a collector/spool. Owns ONLY the auth_failure event class on these logs (ReasonFTPAuthFail); no other module bans FTP auth failures. Existence + regular-file filter, excludes rotated/.gz, dedups on the canonical path, and bounds the set to the most-recently-modified files (one tail -F per file, reusing the shared discoverFromGlobs core). Mirrors the v1.179 web discovery pattern (webdiscovery.go) for the FTP source-feed."
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

// ftpLogGlobs returns FTP-daemon log globs scoped to the detected FTP daemon(s).
// pure-ftpd commonly logs to /var/log/pureftpd.log or a /var/log/pure-ftpd/ dir;
// vsftpd to /var/log/vsftpd.log; proftpd to /var/log/proftpd/*.log (auth.log on
// some distros). Globs for absent daemons are harmless — discoverFromGlobs just
// finds no matches.
func (m *Module) ftpLogGlobs() []string {
	var g []string
	if m.detectedServices["pure-ftpd"] {
		g = append(g,
			"/var/log/pureftpd.log",
			"/var/log/pure-ftpd.log",
			"/var/log/pure-ftpd/*.log",
		)
	}
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
