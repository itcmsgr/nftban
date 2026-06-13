// =============================================================================
// NFTBan v1.179.0 - WebAuth Detector Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
//
// meta:name="webauth_detector_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-13"
// meta:description="Unit tests for WebAuthDetector — auth_failure ownership: HTTP basic-auth 401/403 + WordPress wp-login failed-credential matched; web_abuse (xmlrpc, wp-login flood/success, GET) not matched (BotScan->BotGuard owns it); IPv4+IPv6; ownership ordering vs PanelDetector."
//
// meta:inventory.files="webauth_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package detector

import (
	"net/netip"
	"testing"
)

func TestWebAuthDetector(t *testing.T) {
	d := NewWebAuthDetector()
	tests := []struct {
		name       string
		line       string
		wantMatch  bool
		wantReason uint16
		wantIP     string
		wantSvc    string
	}{
		// --- AUTH failures (owned) ---
		{"apache basic-auth 401 IPv4", `203.0.113.7 - - [13/Jun/2026:10:00:00 +0000] "GET /admin HTTP/1.1" 401 12 "-" "curl"`, true, ReasonGenericAuthFail, "203.0.113.7", "http-auth"},
		{"nginx basic-auth 401 IPv4", `198.51.100.5 - - [13/Jun/2026:10:00:00 +0000] "GET /private/ HTTP/1.1" 401 5 "-" "bot"`, true, ReasonGenericAuthFail, "198.51.100.5", "http-auth"},
		{"basic-auth 401 IPv6", `2001:db8::1 - - [13/Jun/2026:10:00:00 +0000] "GET /admin HTTP/1.1" 401 12 "-" "x"`, true, ReasonGenericAuthFail, "2001:db8::1", "http-auth"},
		{"wp-login failed credential (POST 200) IPv4", `192.0.2.10 - - [13/Jun/2026:10:00:00 +0000] "POST /wp-login.php HTTP/1.1" 200 1500 "-" "Mozilla"`, true, ReasonWordPressWPLogin, "192.0.2.10", "wordpress"},
		{"wp-login failed credential (POST 200) IPv6", `2001:db8::2 - - [13/Jun/2026:10:00:00 +0000] "POST /wp-login.php HTTP/1.1" 200 1500 "-" "x"`, true, ReasonWordPressWPLogin, "2001:db8::2", "wordpress"},

		// --- NOT owned: web_abuse / non-auth (must NOT match — wrong-module prevention) ---
		{"xmlrpc is web_abuse not auth (even with 200)", `203.0.113.9 - - [13/Jun/2026:10:00:00 +0000] "POST /xmlrpc.php HTTP/1.1" 200 800 "-" "x"`, false, 0, "", ""},
		{"xmlrpc with 403 still excluded", `203.0.113.9 - - [..] "POST /xmlrpc.php HTTP/1.1" 403 5 "-" "x"`, false, 0, "", ""},
		{"wp-login SUCCESS (302) not a failure", `192.0.2.11 - - [..] "POST /wp-login.php HTTP/1.1" 302 0 "-" "x"`, false, 0, "", ""},
		{"wp-login GET (page view) not a failure", `192.0.2.12 - - [..] "GET /wp-login.php HTTP/1.1" 200 1500 "-" "x"`, false, 0, "", ""},
		{"cPanel /login/ 401 excluded (PanelDetector-owned)", `203.0.113.20 - - [..] "POST /login/?login_only=1 HTTP/1.1" 401 0 "-" "x"`, false, 0, "", ""},
		{"403 forbidden is web_abuse not auth (scanner /.env)", `203.0.113.40 - - [..] "GET /.env HTTP/1.1" 403 5 "-" "scanner"`, false, 0, "", ""},
		{"403 forbidden is web_abuse not auth (scanner /wp-admin)", `203.0.113.41 - - [..] "GET /wp-admin/ HTTP/1.1" 403 5 "-" "bot"`, false, 0, "", ""},
		{"404 scanner probe not auth", `203.0.113.42 - - [..] "GET /phpmyadmin/ HTTP/1.1" 404 5 "-" "bot"`, false, 0, "", ""},
		{"normal 200 GET not auth", `203.0.113.30 - - [..] "GET /index.html HTTP/1.1" 200 1500 "-" "x"`, false, 0, "", ""},
		{"malformed (no IP) no match", `- - - [..] "GET /admin HTTP/1.1" 401 0`, false, 0, "", ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			v, ok := d.Detect([]byte(tt.line))
			if ok != tt.wantMatch {
				t.Fatalf("match=%v want %v (line=%q)", ok, tt.wantMatch, tt.line)
			}
			if !tt.wantMatch {
				return
			}
			if v.Reason != tt.wantReason {
				t.Errorf("reason=%d want %d", v.Reason, tt.wantReason)
			}
			if v.Service != tt.wantSvc {
				t.Errorf("service=%q want %q", v.Service, tt.wantSvc)
			}
			want, _ := netip.ParseAddr(tt.wantIP)
			if v.IP != want {
				t.Errorf("ip=%v want %v", v.IP, want)
			}
			if v.ScoreDelta <= 0 {
				t.Errorf("scoreDelta=%d want >0", v.ScoreDelta)
			}
		})
	}
}

// TestWebAuthRegisteredAfterPanel locks the ownership ordering: the full registry
// classifies a cPanel /login/ 401 as cpanel (PanelDetector), NOT http-auth (WebAuth),
// and a generic 401 as http-auth (WebAuth).
func TestWebAuthOwnershipOrdering(t *testing.T) {
	r := NewRegistry()
	cpanel := []byte(`203.0.113.20 - - [..] "POST /login/?login_only=1 HTTP/1.1" 401 0 "-" "x"`)
	if v, ok := r.Detect(cpanel); !ok || v.Reason != ReasonCPanelLogin {
		t.Errorf("cPanel /login/ 401 → reason=%d ok=%v, want ReasonCPanelLogin (PanelDetector owns it)", v.Reason, ok)
	}
	generic := []byte(`198.51.100.9 - - [..] "GET /secret HTTP/1.1" 401 0 "-" "x"`)
	if v, ok := r.Detect(generic); !ok || v.Reason != ReasonGenericAuthFail {
		t.Errorf("generic 401 → reason=%d ok=%v, want ReasonGenericAuthFail (WebAuth owns it)", v.Reason, ok)
	}
	xmlrpc := []byte(`203.0.113.9 - - [..] "POST /xmlrpc.php HTTP/1.1" 200 800 "-" "x"`)
	if _, ok := r.Detect(xmlrpc); ok {
		t.Errorf("xmlrpc must NOT produce a LoginMon verdict (web_abuse → BotScan)")
	}
}

// TestWebAuthRealTraffic locks ownership behavior against REAL sanitized production
// access-log lines sampled read-only from srv1-4/dns1-2 (client IPs masked to doc
// ranges; request shape preserved). Proves the detector owns auth_failure only and
// ignores the live web_abuse traffic (xmlrpc flood, 403/404 scanners, bad bots).
func TestWebAuthRealTraffic(t *testing.T) {
	d := NewWebAuthDetector()
	type tc struct {
		name       string
		line       string
		wantMatch  bool
		wantReason uint16
	}
	tests := []tc{
		// OWNED — auth_failure
		{"REST 401 wc customers", `203.0.113.1 - - [13/Jun/2026:00:28:11 +0000] "GET /wp-json/wc/v3/customers?per_page=100&_fields=username,email HTTP/2" 401 334 "-" "Mozilla/5.0 Chrome/133.0.0.0"`, true, ReasonGenericAuthFail},
		{"REST 401 users/me", `203.0.113.3 - - [13/Jun/2026:07:48:37 +0000] "GET /wp-json/wp/v2/users/me HTTP/2" 401 262 "-" "Chrome/133.0.0.0"`, true, ReasonGenericAuthFail},
		{"wp-login POST 200 IPv4", `203.0.113.1 - - [13/Jun/2026:00:22:24 +0000] "POST /wp-login.php HTTP/2" 200 4453 "-" "Safari/605.1.15"`, true, ReasonWordPressWPLogin},
		{"wp-login POST 200 IPv6", `2001:db8::3 - - [13/Jun/2026:00:30:32 +0000] "POST /wp-login.php HTTP/1.1" 200 4689 "-" "Firefox/102.0"`, true, ReasonWordPressWPLogin},
		// IGNORED — web_abuse / non-auth (the live flood + scanners)
		{"wp-login POST 302 success", `203.0.113.1 - - [13/Jun/2026:07:59:12 +0000] "POST /wp-login.php HTTP/1.1" 302 264 "http://x/wp-login.php" "Firefox/118.0"`, false, 0},
		{"wp-login POST 503 rate-limited", `203.0.113.1 - - [13/Jun/2026:01:00:00 +0000] "POST /wp-login.php HTTP/1.1" 503 200 "-" "Mozilla/5.0"`, false, 0},
		{"status 200 with size 401 not a 401 auth", `203.0.113.5 - - [13/Jun/2026:01:00:00 +0000] "GET /x HTTP/1.1" 200 401 "-" "Mozilla/5.0"`, false, 0},
		{"xmlrpc POST 200 jetpack/forged", `203.0.113.4 - - [13/Jun/2026:02:03:53 +0000] "POST /xmlrpc.php HTTP/1.1" 200 938 "-" "Jetpack/12.0; WordPress/6.1; http://site23614003.com"`, false, 0},
		{"xmlrpc GET 405", `203.0.113.1 - - [13/Jun/2026:00:33:46 +0000] "GET /xmlrpc.php HTTP/1.1" 405 641 "-" "Safari/604.1"`, false, 0},
		{"xmlrpc GET 403", `203.0.113.1 - - [13/Jun/2026:06:53:30 +0000] "GET /xmlrpc.php HTTP/1.1" 403 343 "-" "Safari/604.1"`, false, 0},
		{"403 webshell probe", `203.0.113.1 - - [13/Jun/2026:04:53:04 +0000] "GET /wp-content/plugins/fix/up.php HTTP/2" 403 0 "-" "Chrome/85.0.4183.102"`, false, 0},
		{"403 GET wp-login python-requests", `203.0.113.1 - - [13/Jun/2026:04:53:04 +0000] "GET /wp-login.php HTTP/2" 403 0 "-" "python-requests/2.33.1"`, false, 0},
		{"404 config-secret scanner", `203.0.113.2 - - [13/Jun/2026:00:42:03 +0000] "GET /application.yml HTTP/1.1" 404 40554 "-" "CCBot/2.0"`, false, 0},
		{"bad-bot MJ12 GET 200", `203.0.113.1 - - [13/Jun/2026:00:23:52 +0000] "GET /robots.txt HTTP/1.1" 200 755 "-" "Mozilla/5.0 (compatible; MJ12bot/v1.4.8; http://mj12bot.com/)"`, false, 0},
		{"python-requests POST / 200", `203.0.113.1 - - [13/Jun/2026:00:00:00 +0000] "POST / HTTP/1.1" 200 33521 "-" "python-requests/2.34.2"`, false, 0},
		{"wp-login only in referer, request is index.html (no false match)", `203.0.113.6 - - [13/Jun/2026:00:00:00 +0000] "POST /index.html HTTP/1.1" 200 1500 "http://x/wp-login.php" "Mozilla/5.0"`, false, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			v, ok := d.Detect([]byte(tt.line))
			if ok != tt.wantMatch {
				t.Fatalf("match=%v want %v", ok, tt.wantMatch)
			}
			if tt.wantMatch && v.Reason != tt.wantReason {
				t.Errorf("reason=%d want %d", v.Reason, tt.wantReason)
			}
		})
	}
}
