// =============================================================================
// NFTBan v1.179.0 - LoginMon web access-log discovery (auth_failure source)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: loginmon
// Purpose: Panel-aware discovery of WEB access logs for the LoginMon auth_failure
//          event class (HTTP basic-auth 401/403 + WordPress wp-login failed-credential).
//
// meta:name="loginmon_webdiscovery"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="loginmon"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-13"
// meta:description="Discovers panel-appropriate + generic web access-log files for the LoginMon WebAuth detector. The LoginMon module runs inside the root nftband.service (CAP_DAC_OVERRIDE) so it reads these directly — NOT via the BotScan collector/spool. Owns ONLY auth_failure events on these logs; web_abuse (xmlrpc/floods/scanners) stays with BotScan->BotGuard. Canonicalizes paths (handles the cPanel domlogs symlink chain), excludes error/compressed/rotated files, and bounds the set to the most-recently-modified files (one tail -F per file). Mirrors the shell discovery in cli/lib/nftban/lib/nftban_http_logs.sh for the Go daemon path."
//
// meta:inventory.files="webdiscovery.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package loginmon

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// webAuthMaxFiles bounds how many access-log files LoginMon will tail concurrently
// (one tail -F per file). The most-recently-modified files are kept — active/attacked
// domains have recent traffic, so they are preferred. (Future optimization: a single
// poller over all files instead of one tail per file — tracked as a v1.18x item.)
const webAuthMaxFiles = 64

// webStackDetected reports whether any web server or panel that produces access logs
// is present — used to distinguish WARN_NO_LOGS (stack present, no logs) from NO_LOGS.
func (m *Module) webStackDetected() bool {
	return m.detectedServices["apache"] || m.detectedServices["nginx"] ||
		m.detectedServices["litespeed"] || m.detectedServices["directadmin"] ||
		m.detectedServices["cpanel"] || m.detectedServices["plesk"]
}

// webAccessLogGlobs returns panel-appropriate + generic access-log globs.
func (m *Module) webAccessLogGlobs() []string {
	var g []string
	if m.detectedServices["directadmin"] {
		// DA nginx-reverse-proxy-to-Apache logs EVERY request to BOTH
		// /var/log/httpd/domains AND /var/log/nginx/domains (a mirror). Watching both
		// double-counts each failed login → the scorer would ban at half the real
		// attempts (over-aggressive / false-ban risk on production). Prefer httpd
		// (the Apache backend, the canonical per-domain access log); fall back to the
		// nginx mirror only if httpd/domains has no logs (nginx-only host).
		const daHTTPd = "/var/log/httpd/domains/*.log"
		g = append(g, daHTTPd)
		if mm, _ := filepath.Glob(daHTTPd); len(mm) == 0 {
			g = append(g, "/var/log/nginx/domains/*.log")
		}
	}
	if m.detectedServices["cpanel"] {
		g = append(g, "/usr/local/apache/domlogs/*", "/usr/local/apache/domlogs/*/*", "/var/log/apache2/domlogs/*")
	}
	if m.detectedServices["plesk"] {
		g = append(g, "/var/www/vhosts/system/*/logs/access_log", "/var/www/vhosts/system/*/logs/access_ssl_log")
	}
	// generic stacks (harmless if absent)
	g = append(g,
		"/var/log/httpd/access_log",
		"/var/log/apache2/access.log",
		"/var/log/nginx/access.log",
		"/var/log/nginx/*access*",
		"/usr/local/lsws/logs/*access*",
	)
	return g
}

// isExcludedWebLog drops error/compressed/rotated files (access logs only).
func isExcludedWebLog(path string) bool {
	base := filepath.Base(path)
	if strings.Contains(base, "error_log") || strings.Contains(base, "error.log") ||
		strings.Contains(base, "-error") || strings.Contains(base, "_error") {
		return true
	}
	if strings.HasSuffix(base, ".gz") {
		return true
	}
	// rotated: trailing ".<digits>"
	if i := strings.LastIndexByte(base, '.'); i >= 0 {
		suf := base[i+1:]
		if suf != "" {
			allDigit := true
			for _, c := range suf {
				if c < '0' || c > '9' {
					allDigit = false
					break
				}
			}
			if allDigit {
				return true
			}
		}
	}
	return false
}

// discoverWebAccessLogs returns existing, regular, non-error/non-rotated web access-log
// files (canonicalized), bounded to the most-recently-modified webAuthMaxFiles. The root
// daemon reads them directly (no collector/spool).
func (m *Module) discoverWebAccessLogs() []string {
	return discoverFromGlobs(m.webAccessLogGlobs())
}

// discoverFromGlobs is the testable core: glob → canonicalize → regular-file +
// non-excluded filter → dedup → most-recent-mtime bound. Separated so it can be
// unit-tested with real temp files + injected globs.
func discoverFromGlobs(globs []string) []string {
	seen := make(map[string]bool)
	type fent struct {
		path  string
		mtime int64
	}
	var ents []fent
	for _, g := range globs {
		matches, _ := filepath.Glob(g)
		for _, p := range matches {
			// Canonicalize (handles cPanel domlogs symlink chain) then dedup on the
			// CANONICAL path only — two globs may resolve to the same real file.
			cp, err := filepath.EvalSymlinks(p)
			if err != nil {
				continue
			}
			if seen[cp] {
				continue
			}
			fi, err := os.Stat(cp)
			if err != nil || !fi.Mode().IsRegular() {
				continue
			}
			if isExcludedWebLog(cp) {
				continue
			}
			seen[cp] = true
			ents = append(ents, fent{path: cp, mtime: fi.ModTime().UnixNano()})
		}
	}
	sort.Slice(ents, func(i, j int) bool { return ents[i].mtime > ents[j].mtime })
	if len(ents) > webAuthMaxFiles {
		ents = ents[:webAuthMaxFiles]
	}
	out := make([]string, 0, len(ents))
	for _, e := range ents {
		out = append(out, e.path)
	}
	return out
}
