// =============================================================================
// NFTBan v1.186.0 - LoginMon Roundcube userlogins.log discovery (DirectAdmin-only)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: loginmon
// Purpose: Discovery of the Roundcube webmail userlogins.log for the LoginMon
//          auth_failure event class (source=roundcube), DirectAdmin-only in v1.186.
//
// meta:name="loginmon_roundcubediscovery"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="loginmon"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-14"
// meta:description="Discovers the DirectAdmin/OpenLiteSpeed central Roundcube userlogins.log (Gate-0 captured: /var/log/roundcube/userlogins.log, real client IP, root-readable). v1.186 claims DirectAdmin coverage ONLY: cPanel (per-user $HOME/logs/roundcube/userlogins.log) and Plesk (/var/log/plesk-roundcube/userlogins.log) are DEFERRED and intentionally NOT globbed here — no coverage is claimed for them. The root nftband.service (CAP_DAC_OVERRIDE) reads the central log directly (Option A; the webapps log dir is drwx--x--- so a cap-scoped nftban-user collector cannot traverse it). The RoundcubeDetector's mandatory public-IP-only guard keeps any non-DA/proxied host that logs 127.0.0.1 a safe no-op."
//
// meta:inventory.files="roundcubediscovery.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package loginmon

import "os"

// roundcubeLogGlobs returns the DirectAdmin central Roundcube userlogins log glob.
// v1.186 DA-only: cPanel/Plesk paths are deliberately absent (deferred, not claimed).
// /var/log/roundcube/ is both the DA default and the Gate-0-captured path; a
// config-driven log_dir override is a deferred refinement (the default holds on DA).
func (m *Module) roundcubeLogGlobs() []string {
	return []string{
		"/var/log/roundcube/userlogins.log",
	}
}

// discoverRoundcubeLogs returns the existing DA Roundcube userlogins.log (canonicalized,
// regular-file filtered) — or nil. DA-only: returns nil unless DirectAdmin is detected,
// so the source is never even attempted on cPanel/Plesk hosts (no coverage claim).
func (m *Module) discoverRoundcubeLogs() []string {
	if !m.detectedServices["directadmin"] {
		return nil
	}
	return discoverFromGlobs(m.roundcubeLogGlobs())
}

// roundcubeDetected reports whether Roundcube appears installed on this (DA) host —
// used to distinguish WARN_NO_LOGS (Roundcube present but log_logins off / no
// userlogins.log yet) from NO_LOGS (no Roundcube at all). DA-only.
func (m *Module) roundcubeDetected() bool {
	if !m.detectedServices["directadmin"] {
		return false
	}
	for _, p := range []string{"/var/log/roundcube", "/var/www/html/roundcube"} {
		if _, err := os.Stat(p); err == nil {
			return true
		}
	}
	return false
}
