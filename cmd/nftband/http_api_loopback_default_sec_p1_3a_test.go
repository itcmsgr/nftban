// SPDX-License-Identifier: MPL-2.0
// meta:name="nftband/http_api_loopback_default_sec_p1_3a_test" meta:type="test" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="SEC-P1-3a: the daemon HTTP API defaults to loopback and a non-loopback bind is refused (falls back to loopback) unless explicitly acknowledged via NFTBAN_API_ALLOW_INSECURE_BIND. Covers isLoopbackAPIBind classification (loopback vs all-interfaces/0.0.0.0/::/LAN/public/hostname), resolveAPIBind fallback-vs-honor, the ack env parse, and that the DefaultHTTPAddr fallback is loopback. Hermetic: pure functions, no netlink/daemon."
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars="NFTBAN_API_ALLOW_INSECURE_BIND"
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"

package main

import "testing"

func TestIsLoopbackAPIBind_SEC_P1_3a(t *testing.T) {
	loopback := []string{"127.0.0.1:9580", "127.0.0.1:6060", "[::1]:9580", "localhost:9580"}
	exposed := []string{":9580", "0.0.0.0:9580", "[::]:9580", "192.168.1.5:9580", "203.0.113.9:9580", "10.0.0.1:9580", "host.example:9580"}
	for _, a := range loopback {
		if !isLoopbackAPIBind(a) {
			t.Errorf("%q must be loopback", a)
		}
	}
	for _, a := range exposed {
		if isLoopbackAPIBind(a) {
			t.Errorf("%q must be NON-loopback (exposed)", a)
		}
	}
}

func TestApiInsecureBindAcked_SEC_P1_3a(t *testing.T) {
	for _, v := range []string{"YES", "yes", "TRUE", "true", "1"} {
		t.Setenv("NFTBAN_API_ALLOW_INSECURE_BIND", v)
		if !apiInsecureBindAcked() {
			t.Errorf("%q must be an ack", v)
		}
	}
	for _, v := range []string{"", "NO", "no", "0", "false", "maybe"} {
		t.Setenv("NFTBAN_API_ALLOW_INSECURE_BIND", v)
		if apiInsecureBindAcked() {
			t.Errorf("%q must NOT be an ack", v)
		}
	}
}

func TestResolveAPIBind_LoopbackPassThrough_SEC_P1_3a(t *testing.T) {
	t.Setenv("NFTBAN_API_ALLOW_INSECURE_BIND", "")
	for _, a := range []string{"127.0.0.1:9580", "[::1]:9580", "localhost:9580"} {
		if got := resolveAPIBind(a); got != a {
			t.Errorf("loopback %q must pass through, got %q", a, got)
		}
	}
}

func TestResolveAPIBind_NonLoopbackWithoutAck_FallsBackToLoopback_SEC_P1_3a(t *testing.T) {
	t.Setenv("NFTBAN_API_ALLOW_INSECURE_BIND", "")
	for _, a := range []string{":9580", "0.0.0.0:9580", "[::]:9580", "192.168.1.5:9580", "203.0.113.9:9580"} {
		got := resolveAPIBind(a)
		if got != DefaultHTTPAddr {
			t.Errorf("unsafe %q without ack must fall back to %q, got %q", a, DefaultHTTPAddr, got)
		}
		if !isLoopbackAPIBind(got) {
			t.Errorf("fallback %q must be loopback", got)
		}
	}
}

func TestResolveAPIBind_NonLoopbackWithAck_Honored_SEC_P1_3a(t *testing.T) {
	t.Setenv("NFTBAN_API_ALLOW_INSECURE_BIND", "YES")
	for _, a := range []string{"0.0.0.0:9580", ":9580", "203.0.113.9:9580"} {
		if got := resolveAPIBind(a); got != a {
			t.Errorf("acked non-loopback %q must be honored, got %q", a, got)
		}
	}
}

func TestDefaultHTTPAddr_IsLoopback_SEC_P1_3a(t *testing.T) {
	if DefaultHTTPAddr != "127.0.0.1:9580" {
		t.Fatalf("DefaultHTTPAddr=%q, want 127.0.0.1:9580", DefaultHTTPAddr)
	}
	if !isLoopbackAPIBind(DefaultHTTPAddr) {
		t.Fatal("DefaultHTTPAddr must be loopback")
	}
}
