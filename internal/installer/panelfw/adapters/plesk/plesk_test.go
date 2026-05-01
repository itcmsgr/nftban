// =============================================================================
// NFTBan v1.100.x PR26.7 - Plesk Adapter Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-panelfw-plesk-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-30"
// meta:description="Detect / RequiredPorts / ValidateReachability + framework integration for Plesk"
// meta:inventory.files="internal/installer/panelfw/adapters/plesk/plesk_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package plesk

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/panelfw"
	"github.com/itcmsgr/nftban/internal/ports"
)

func newTestLogger() *logging.Logger {
	return logging.New("/dev/null", false)
}

// seedPlesk populates the mock with strong-confidence Plesk evidence
// in the Ubuntu-realistic shape: install dir, marker binary,
// sw-cp-server.service active (the canonical panel-listener daemon
// per the 203.0.113.229 audit; sha256 c1a72266e2eb...), and TCP
// <port> in LISTEN state.
//
// PR26.7.1 calibration: the original seedPlesk activated
// `plesk.service`, which does not exist on Ubuntu Plesk Obsidian.
// Switching the default to `sw-cp-server.service` makes the strong-
// confidence path mirror real-world Ubuntu Plesk. Tests covering the
// legacy plesk.service compat path use seedPleskLegacyService below.
func seedPlesk(mock *executor.MockExecutor, port int) {
	mock.Dirs[installDir] = true
	mock.Files[binaryPath] = []byte("ELF")
	mock.Services["sw-cp-server.service"] = true
	mock.RunResults["ss:-lnt"] = executor.Result{
		ExitCode: 0,
		Stdout:   ssOutput(port),
	}
}

// seedPleskLegacyService activates `plesk.service` (the legacy/compat
// unit) instead of sw-cp-server.service. Used to verify that hosts
// where only the legacy unit is the systemd surface still detect
// strong. Mirror of seedPlesk but with E3 wired through the legacy
// any-of branch.
func seedPleskLegacyService(mock *executor.MockExecutor, port int) {
	mock.Dirs[installDir] = true
	mock.Files[binaryPath] = []byte("ELF")
	mock.Services["plesk.service"] = true
	mock.RunResults["ss:-lnt"] = executor.Result{
		ExitCode: 0,
		Stdout:   ssOutput(port),
	}
}

// seedPleskOrchestratorOnly activates psa.service (the orchestrator
// unit, typically `active(exited)` on a healthy host). Used to verify
// the any-of probe accepts psa as fallback E3 evidence when neither
// sw-cp-server nor plesk.service is the surfaced unit.
func seedPleskOrchestratorOnly(mock *executor.MockExecutor, port int) {
	mock.Dirs[installDir] = true
	mock.Files[binaryPath] = []byte("ELF")
	mock.Services["psa.service"] = true
	mock.RunResults["ss:-lnt"] = executor.Result{
		ExitCode: 0,
		Stdout:   ssOutput(port),
	}
}

func ssOutput(listenPorts ...int) string {
	header := "State Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n"
	rows := []string{header}
	for _, p := range listenPorts {
		rows = append(rows, "LISTEN 0 128 0.0.0.0:"+itoa(p)+" 0.0.0.0:* users:((\"sw-cp-server\",pid=1,fd=3))")
	}
	return strings.Join(rows, "\n")
}

func itoa(n int) string { return formatInt(n) }

func formatInt(n int) string {
	if n == 0 {
		return "0"
	}
	digits := []byte{}
	for n > 0 {
		digits = append([]byte{byte('0' + n%10)}, digits...)
		n /= 10
	}
	return string(digits)
}

// ----------------------------------------------------------------------------
// Detect
// ----------------------------------------------------------------------------

func TestDetect_AllSignals_Strong(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	seedPlesk(mock, defaultPort)

	det := a.Detect(context.Background(), mock)
	if !det.Detected {
		t.Fatalf("expected Detected=true; got %#v", det)
	}
	if det.Confidence != "strong" {
		t.Errorf("expected strong confidence with 4 indicators; got %q", det.Confidence)
	}
	if len(det.Evidence) != 4 {
		t.Errorf("expected 4 evidence entries; got %d (%v)", len(det.Evidence), det.Evidence)
	}
	if len(det.RequiredTCP) != 1 || det.RequiredTCP[0] != defaultPort {
		t.Errorf("expected RequiredTCP=[%d]; got %v", defaultPort, det.RequiredTCP)
	}
}

func TestDetect_Absent_NotDetected(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	det := a.Detect(context.Background(), mock)
	if det.Detected {
		t.Fatalf("expected Detected=false on bare host; got %#v", det)
	}
}

func TestDetect_PartialInstall_Weak(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	// Only the install dir + marker binary; service stopped, no listener.
	mock.Dirs[installDir] = true
	mock.Files[binaryPath] = []byte("ELF")

	det := a.Detect(context.Background(), mock)
	if !det.Detected {
		t.Fatalf("expected Detected=true on 2 indicators; got %#v", det)
	}
	if det.Confidence != "weak" {
		t.Errorf("expected weak confidence; got %q", det.Confidence)
	}
	if len(det.Warnings) == 0 {
		t.Errorf("expected at least one warning for partial install")
	}
}

// Service-only signal still counts as a (weak) detection. Activating
// the canonical Ubuntu Plesk listener unit (sw-cp-server.service) is
// the strongest single E3 evidence; PR26.7.1 any-of probe accepts it
// alone as enough for Detected=true with weak confidence.
func TestDetect_ServiceOnly_Weak(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	mock.Services["sw-cp-server.service"] = true

	det := a.Detect(context.Background(), mock)
	if !det.Detected {
		t.Fatalf("expected Detected=true on service-active alone")
	}
	if det.Confidence != "weak" {
		t.Errorf("expected weak confidence; got %q", det.Confidence)
	}
}

// PR26.7.1 — Ubuntu Plesk Obsidian realistic strong-detect path.
//
// Real-world Ubuntu Plesk (per the 203.0.113.229 audit, sha256
// c1a72266e2eb...) has:
//   /usr/local/psa            present (symlink → /opt/psa)
//   httpdmng                  present (symlink → ../sbin/wrapper)
//   sw-cp-server.service      active+enabled (owns 8443/8880 listener)
//   plesk.service             ABSENT from systemctl list-unit-files
//   8443                      LISTEN
//
// The pre-PR26.7.1 adapter probed only `plesk.service`, computing
// confidence="weak" with a misleading "partial install" warning on a
// fully-functional Ubuntu Plesk panel. After PR26.7.1, Detect must
// compute confidence="strong" with no warnings on this realistic
// signal set.
func TestDetect_UbuntuRealistic_SwCpServer_Strong(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	seedPlesk(mock, defaultPort) // seedPlesk now defaults to sw-cp-server.service

	// Explicit guard: plesk.service must be absent from this fixture
	// to prove the any-of probe does NOT silently fall back to it.
	if mock.Services["plesk.service"] {
		t.Fatal("test fixture invariant: plesk.service must not be active in this case")
	}

	det := a.Detect(context.Background(), mock)
	if !det.Detected {
		t.Fatalf("expected Detected=true on Ubuntu-realistic Plesk fixture; got %#v", det)
	}
	if det.Confidence != "strong" {
		t.Errorf("expected strong confidence on Ubuntu-realistic 4-signal Plesk; got %q (evidence=%v)",
			det.Confidence, det.Evidence)
	}
	if len(det.Warnings) != 0 {
		t.Errorf("expected zero warnings on healthy Ubuntu Plesk; got %v", det.Warnings)
	}
	// Evidence must explicitly name sw-cp-server.service (not plesk.service).
	foundSwCp := false
	for _, e := range det.Evidence {
		if e == "service-active:sw-cp-server.service" {
			foundSwCp = true
		}
		if e == "service-active:plesk.service" {
			t.Errorf("evidence wrongly references plesk.service when sw-cp-server is the active unit: %v", det.Evidence)
		}
	}
	if !foundSwCp {
		t.Errorf("evidence must record service-active:sw-cp-server.service; got %v", det.Evidence)
	}
}

// PR26.7.1 — psa.service-only fallback path. When sw-cp-server is
// somehow not the surfaced unit (rare, but possible on fresh-boot
// race or non-Ubuntu Plesk distros), psa.service active(exited) is
// the orchestrator-evidence fallback. Adapter must accept it as E3.
func TestDetect_UbuntuRealistic_PsaServiceFallback_Strong(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	seedPleskOrchestratorOnly(mock, defaultPort)

	if mock.Services["sw-cp-server.service"] || mock.Services["plesk.service"] {
		t.Fatal("test fixture invariant: only psa.service must be the surfaced unit")
	}

	det := a.Detect(context.Background(), mock)
	if !det.Detected {
		t.Fatalf("expected Detected=true with psa.service evidence; got %#v", det)
	}
	if det.Confidence != "strong" {
		t.Errorf("expected strong confidence (4 signals); got %q (evidence=%v)",
			det.Confidence, det.Evidence)
	}
	foundPsa := false
	for _, e := range det.Evidence {
		if e == "service-active:psa.service" {
			foundPsa = true
		}
	}
	if !foundPsa {
		t.Errorf("evidence must record service-active:psa.service; got %v", det.Evidence)
	}
}

// PR26.7.1 — legacy plesk.service compat path. Distros that DO ship
// `plesk.service` (some non-Ubuntu Plesk hosts) must still detect
// strong via the legacy any-of branch.
func TestDetect_LegacyPleskService_Compat_Strong(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	seedPleskLegacyService(mock, defaultPort)

	if mock.Services["sw-cp-server.service"] || mock.Services["psa.service"] {
		t.Fatal("test fixture invariant: only plesk.service must be the surfaced unit")
	}

	det := a.Detect(context.Background(), mock)
	if !det.Detected {
		t.Fatalf("expected Detected=true with plesk.service evidence; got %#v", det)
	}
	if det.Confidence != "strong" {
		t.Errorf("expected strong confidence on legacy plesk.service compat path; got %q",
			det.Confidence)
	}
	foundLegacy := false
	for _, e := range det.Evidence {
		if e == "service-active:plesk.service" {
			foundLegacy = true
		}
	}
	if !foundLegacy {
		t.Errorf("evidence must record service-active:plesk.service; got %v", det.Evidence)
	}
}

// PR26.7.1 — broadening guard: bare TCP 8443 listener WITHOUT Plesk
// filesystem markers must NOT trigger detection. The any-of systemd
// probe could otherwise incorrectly broaden the detection surface to
// any non-Plesk host that happens to listen on 8443 (e.g., a custom
// HTTPS service). Filesystem markers (E1/E2) gate the host as Plesk
// before E3/E4 contribute.
//
// Note on confidence: a bare 8443 listener still records E4 evidence,
// which technically means signals=1 → Detected=true / Confidence=weak
// per the existing rule. That is correct framework behavior — the
// adapter does not pretend the host is non-Plesk. The PANEL-SURVIVAL
// invariant fires only on `Detected=true` AND failing reachability;
// this test guards against a confident MISdetection (e.g., strong on
// 8443 alone).
func TestDetect_BarePort8443_NoPleskMarkers_NotConfidentDetection(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	mock.RunResults["ss:-lnt"] = executor.Result{
		ExitCode: 0,
		Stdout:   ssOutput(defaultPort),
	}

	det := a.Detect(context.Background(), mock)
	if det.Confidence == "strong" {
		t.Errorf("bare 8443 without Plesk markers must NOT yield strong confidence; got %q evidence=%v",
			det.Confidence, det.Evidence)
	}
	// E1/E2/E3 must all be absent in evidence — only the listener entry.
	for _, e := range det.Evidence {
		if e == "install-dir-present:"+installDir || e == "binary-present:"+binaryPath {
			t.Errorf("evidence wrongly claims Plesk filesystem markers on bare-8443 fixture: %v", det.Evidence)
		}
		if len(e) >= 16 && e[:16] == "service-active:s" {
			t.Errorf("evidence wrongly claims Plesk service on bare-8443 fixture: %v", det.Evidence)
		}
	}
}

// Negative-coupling guard: a DirectAdmin-shape mock (binary at
// /usr/local/directadmin/...) must NOT trigger Plesk detection. Catches
// future regressions where a path constant gets fat-fingered.
func TestDetect_DirectAdminEvidence_NotPlesk(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	mock.Dirs["/usr/local/directadmin"] = true
	mock.Files["/usr/local/directadmin/directadmin"] = []byte("ELF")
	mock.Services["directadmin.service"] = true

	det := a.Detect(context.Background(), mock)
	if det.Detected {
		t.Fatalf("Plesk adapter must not detect on a DA-only host: %#v", det)
	}
}

// ----------------------------------------------------------------------------
// RequiredPorts
// ----------------------------------------------------------------------------

// withStubLoader temporarily replaces panelConfDLoader with a
// deterministic fixture provider. Restores the original on cleanup.
func withStubLoader(t *testing.T, fn func(configDir, panelName string) (*ports.PanelConfig, error)) {
	t.Helper()
	saved := panelConfDLoader
	panelConfDLoader = fn
	t.Cleanup(func() { panelConfDLoader = saved })
}

// withFixtureConfD writes a real conf.d/panels/plesk/main.conf under a
// tempdir and points panelConfDDir at it for the duration of the test.
// Used by integration tests that exercise the real LoadPanelConfig
// (which shells to bash to source the file).
func withFixtureConfD(t *testing.T, mainConf string) string {
	t.Helper()
	tmp := t.TempDir()
	confDir := filepath.Join(tmp, "conf.d", "panels", "plesk")
	if err := os.MkdirAll(confDir, 0755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	if err := os.WriteFile(filepath.Join(confDir, "main.conf"), []byte(mainConf), 0644); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}
	saved := panelConfDDir
	panelConfDDir = tmp
	t.Cleanup(func() { panelConfDDir = saved })
	return tmp
}

// =============================================================================
// FUTURE-AUDITOR DIRECTIVE — port content lives in CONF.D, not in Go.
// =============================================================================
// The Plesk port surface (TCP/UDP × IN/OUT × IPv4/IPv6 + CUSTOM) lives
// ONLY in the shipped conf.d file:
//
//	etc/nftban/conf.d/panels/plesk/main.conf
//
// That file is the single source of truth. Operators edit conf.d, not
// Go. Reproducing any port list in Go (this test file or production
// code) recreates the four-truth drift PR26.4 was created to close.
//
// RULES FOR FUTURE EDITS TO THIS TEST FILE:
//   1. Stub-loader tests use the small `synthPlesk` synthetic fixture
//      below — clearly marked synthetic, not authoritative. Its only
//      job is to give the adapter SOMETHING to pass through so we can
//      test the contract (errors, defensive copies, fail-closed
//      branches). Its specific port values are arbitrary.
//   2. Tests that verify ACTUAL Plesk port content read the shipped
//      conf.d via the real loader. Use
//      `locateRepoFile(t, "etc/nftban/conf.d/panels/plesk/main.conf")`.
//   3. Do NOT add hardcoded port lists to Go. If you find yourself
//      typing a list of Plesk ports in this file, stop and put them
//      in conf.d instead.
// =============================================================================

// synthPlesk is a tiny synthetic PanelConfig used only by stub-loader
// tests that test the adapter contract (pass-through, defensive copy,
// non-trivial surface size). Its port values are arbitrary fixtures —
// NOT the canonical Plesk port surface. The canonical surface lives
// in etc/nftban/conf.d/panels/plesk/main.conf and is verified by
// real-loader tests.
var synthPlesk = struct {
	tcpIn []int
	udpIn []int
}{
	tcpIn: []int{8443, 8880, 25, 80, 443, 587},
	udpIn: []int{53, 443},
}

// adapter passes through the loader's PanelConfig verbatim.
func TestRequiredPorts_ConfDLoaded_FullSurface(t *testing.T) {
	withStubLoader(t, func(configDir, panelName string) (*ports.PanelConfig, error) {
		if panelName != "plesk" {
			t.Fatalf("loader called with panelName=%q; want plesk", panelName)
		}
		return &ports.PanelConfig{
			Name:       "plesk",
			Enabled:    true,
			ConfigFile: configDir + "/conf.d/panels/plesk/main.conf",
			TCPIn:      synthPlesk.tcpIn,
			UDPIn:      synthPlesk.udpIn,
		}, nil
	})

	a := New()
	tcp, udp, err := a.RequiredPorts(context.Background(), executor.NewMockExecutor())
	if err != nil {
		t.Fatalf("RequiredPorts must not error on stub fixture: %v", err)
	}
	if !equalIntSlices(tcp, synthPlesk.tcpIn) {
		t.Errorf("TCP pass-through mismatch:\n  got  %v\n  want %v", tcp, synthPlesk.tcpIn)
	}
	if !equalIntSlices(udp, synthPlesk.udpIn) {
		t.Errorf("UDP pass-through mismatch:\n  got  %v\n  want %v", udp, synthPlesk.udpIn)
	}
}

// RequiredPorts is NOT [8443]-only. Structural regression guard.
func TestRequiredPorts_ConfDLoaded_NotJust8443(t *testing.T) {
	withStubLoader(t, func(configDir, panelName string) (*ports.PanelConfig, error) {
		return &ports.PanelConfig{
			Name:  "plesk",
			TCPIn: synthPlesk.tcpIn,
			UDPIn: synthPlesk.udpIn,
		}, nil
	})

	tcp, udp, err := New().RequiredPorts(context.Background(), executor.NewMockExecutor())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(tcp) <= 1 {
		t.Fatalf("expected full Plesk TCP surface; got only %v", tcp)
	}
	hasNon8443 := false
	for _, p := range tcp {
		if p != defaultPort {
			hasNon8443 = true
			break
		}
	}
	if !hasNon8443 {
		t.Errorf("RequiredPorts must include ports beyond control-plane %d; got %v", defaultPort, tcp)
	}
	if len(udp) == 0 {
		t.Errorf("RequiredPorts must declare UDP surface for Plesk; got empty")
	}
	for _, p := range []int{25, 443} {
		if !containsInt(tcp, p) {
			t.Errorf("TCP surface missing canonical port %d; got %v", p, tcp)
		}
	}
	if !containsInt(udp, 53) {
		t.Errorf("UDP surface missing canonical port 53; got %v", udp)
	}
}

// Missing conf.d main.conf must fail closed.
func TestRequiredPorts_MissingConfD_FailsClosed(t *testing.T) {
	withStubLoader(t, func(configDir, panelName string) (*ports.PanelConfig, error) {
		return nil, fmt.Errorf("panel config not found: %s/conf.d/panels/%s/main.conf",
			configDir, panelName)
	})

	tcp, udp, err := New().RequiredPorts(context.Background(), executor.NewMockExecutor())
	if err == nil {
		t.Fatalf("expected error on missing conf.d; got tcp=%v udp=%v", tcp, udp)
	}
	if !strings.Contains(err.Error(), "Plesk") || !strings.Contains(err.Error(), "conf.d") {
		t.Errorf("error must reference Plesk and conf.d; got %v", err)
	}
	assertNoControlPlaneFallback(t, tcp, udp)
}

// Malformed conf.d (loaded but empty TCP_IN) must fail closed.
func TestRequiredPorts_EmptyTCPIn_FailsClosed(t *testing.T) {
	withStubLoader(t, func(configDir, panelName string) (*ports.PanelConfig, error) {
		return &ports.PanelConfig{
			Name:       "plesk",
			ConfigFile: "/tmp/test/main.conf",
			TCPIn:      nil,
			UDPIn:      []int{53},
		}, nil
	})

	tcp, udp, err := New().RequiredPorts(context.Background(), executor.NewMockExecutor())
	if err == nil {
		t.Fatalf("expected error on empty TCP_IN")
	}
	if !strings.Contains(err.Error(), "no TCP_IN") {
		t.Errorf("error must explain malformed TCP_IN; got %v", err)
	}
	assertNoControlPlaneFallback(t, tcp, udp)
}

// Loader returning nil PanelConfig must fail closed.
func TestRequiredPorts_NilPanelConfig_FailsClosed(t *testing.T) {
	withStubLoader(t, func(configDir, panelName string) (*ports.PanelConfig, error) {
		return nil, nil
	})
	tcp, udp, err := New().RequiredPorts(context.Background(), executor.NewMockExecutor())
	if err == nil {
		t.Fatalf("expected error when loader returns nil cfg")
	}
	assertNoControlPlaneFallback(t, tcp, udp)
}

// Real-loader assertion against the SHIPPED conf.d: SSH port 22 must
// not appear in Plesk TCP_IN/UDP_IN. SSH is managed separately via
// /etc/nftban/ports.d/00-ssh.conf.
func TestRequiredPorts_ConfDDoesNotIncludeSSHPort22(t *testing.T) {
	if _, err := os.Stat("/bin/bash"); err != nil {
		t.Skipf("/bin/bash unavailable on this host: %v", err)
	}
	shipped := locateRepoFile(t, "etc/nftban/conf.d/panels/plesk/main.conf")
	data, err := os.ReadFile(shipped) // #nosec G304 -- fixed path under repo
	if err != nil {
		t.Fatalf("read shipped main.conf at %s: %v", shipped, err)
	}
	withFixtureConfD(t, string(data))

	tcp, udp, err := New().RequiredPorts(context.Background(), executor.NewMockExecutor())
	if err != nil {
		t.Fatalf("unexpected error loading shipped conf.d: %v", err)
	}
	if containsInt(tcp, 22) {
		t.Errorf("shipped Plesk conf.d declares port 22 in TCP_IN — "+
			"SSH is managed by /etc/nftban/ports.d/00-ssh.conf; check %s", shipped)
	}
	if containsInt(udp, 22) {
		t.Errorf("shipped Plesk conf.d declares port 22 in UDP_IN; check %s", shipped)
	}
}

// Real-loader assertion: the shipped conf.d must include the Plesk
// control plane port (8443). Without it the panel itself is unreachable.
// Structural assertions only — never enumerates the full port list.
//
// FUTURE-AUDITOR DIRECTIVE — DO NOT INVENT PORT LISTS HERE.
// Source of truth for Plesk ports is etc/nftban/conf.d/panels/plesk/main.conf.
func TestRequiredPorts_RealLoader_ControlPortAndSurfaceSize(t *testing.T) {
	if _, err := os.Stat("/bin/bash"); err != nil {
		t.Skipf("/bin/bash unavailable on this host: %v", err)
	}
	shipped := locateRepoFile(t, "etc/nftban/conf.d/panels/plesk/main.conf")
	data, err := os.ReadFile(shipped) // #nosec G304 -- fixed path under repo
	if err != nil {
		t.Fatalf("read shipped main.conf at %s: %v", shipped, err)
	}
	withFixtureConfD(t, string(data))

	tcp, udp, err := New().RequiredPorts(context.Background(), executor.NewMockExecutor())
	if err != nil {
		t.Fatalf("real-loader RequiredPorts: %v", err)
	}

	// Plesk control plane MUST be in the surface.
	if !containsInt(tcp, defaultPort) {
		t.Errorf("TCP_IN must include the Plesk control port %d; got len=%d", defaultPort, len(tcp))
	}
	// PR26.7.1 — TCP 4190 (Sieve/managesieve, RFC 5804) MUST be in
	// the surface. Confirmed listening on real Plesk Obsidian 18.0.76
	// by the 203.0.113.229 audit; required for dovecot-managed mail
	// filter rules from external clients.
	if !containsInt(tcp, 4190) {
		t.Errorf("TCP_IN must include managesieve port 4190 (RFC 5804); got len=%d — "+
			"check %s for missing 4190 entry (PR26.7.1)", len(tcp), shipped)
	}
	// SSH must be absent.
	if containsInt(tcp, 22) {
		t.Errorf("real loader produced TCP_IN containing port 22 — conf.d four-truth violation; check %s", shipped)
	}
	if containsInt(udp, 22) {
		t.Errorf("real loader produced UDP_IN containing port 22; check %s", shipped)
	}
	// UDP must be non-empty (Plesk needs DNS at minimum).
	if len(udp) == 0 {
		t.Errorf("UDP_IN empty — conf.d should declare Plesk's UDP surface (DNS, etc.)")
	}
	// Sanity floor on TCP surface — bigger than just the control port.
	// Avoid an exact count so future operator-edits to conf.d don't
	// churn this test.
	if len(tcp) < 5 {
		t.Errorf("TCP_IN length = %d; expected larger Plesk surface (HTTPS, mail, etc.); "+
			"loader may be dropping declarations", len(tcp))
	}
}

// locateRepoFile climbs from the test file's directory until it finds
// the repo's go.mod, then resolves relPath against that root.
func locateRepoFile(t *testing.T, relPath string) string {
	t.Helper()
	_, this, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatalf("runtime.Caller failed")
	}
	dir := filepath.Dir(this)
	for {
		if _, err := os.Stat(filepath.Join(dir, "go.mod")); err == nil {
			return filepath.Join(dir, relPath)
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatalf("could not locate go.mod above %s", filepath.Dir(this))
		}
		dir = parent
	}
}

// assertNoControlPlaneFallback is a fail-closed assertion helper: when
// RequiredPorts errors, the returned slices must be nil/empty — never
// the legacy [8443] fallback.
func assertNoControlPlaneFallback(t *testing.T, tcp, udp []int) {
	t.Helper()
	if len(tcp) != 0 {
		t.Errorf("fail-closed: tcp must be nil/empty on error — must NOT fall back to [%d]; got %v", defaultPort, tcp)
	}
	if len(udp) != 0 {
		t.Errorf("fail-closed: udp must be nil/empty on error; got %v", udp)
	}
}

// Returned slices must not alias internal loader state.
func TestRequiredPorts_DefensiveCopy(t *testing.T) {
	internalTCP := []int{20, 21, 25, 8443}
	internalUDP := []int{53, 443}
	withStubLoader(t, func(configDir, panelName string) (*ports.PanelConfig, error) {
		return &ports.PanelConfig{Name: "plesk", TCPIn: internalTCP, UDPIn: internalUDP}, nil
	})

	tcp, udp, err := New().RequiredPorts(context.Background(), executor.NewMockExecutor())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	tcp[0] = 99999
	udp[0] = 99999
	if internalTCP[0] == 99999 || internalUDP[0] == 99999 {
		t.Errorf("RequiredPorts must return defensive copies; caller mutation leaked into loader cache")
	}
}

// Real internal/ports.LoadPanelConfig against a tempdir-stamped
// fixture main.conf. Exercises the actual bash-subshell parser path.
func TestRequiredPorts_ConfDLoaded_RealLoader_FixtureFile(t *testing.T) {
	if _, err := os.Stat("/bin/bash"); err != nil {
		t.Skipf("/bin/bash unavailable on this host: %v", err)
	}
	const fixtureMain = `# fixture main.conf for PR26.7 integration test
NFTBAN_PLESK_PATH="/usr/local/psa"
NFTBAN_PLESK_PANEL_PORT="8880"
NFTBAN_PLESK_PANEL_SSL_PORT="8443"
NFTBAN_PLESK_TCP_IN="20,21,25,8443,8880"
NFTBAN_PLESK_UDP_IN="53,443"
NFTBAN_PLESK_TCP_OUT="20,21,25,8443"
NFTBAN_PLESK_UDP_OUT="53,123"
`
	withFixtureConfD(t, fixtureMain)

	tcp, udp, err := New().RequiredPorts(context.Background(), executor.NewMockExecutor())
	if err != nil {
		t.Fatalf("real-loader RequiredPorts: %v", err)
	}
	wantTCP := []int{20, 21, 25, 8443, 8880}
	wantUDP := []int{53, 443}
	if !equalIntSlices(tcp, wantTCP) {
		t.Errorf("TCP mismatch:\n  got  %v\n  want %v", tcp, wantTCP)
	}
	if !equalIntSlices(udp, wantUDP) {
		t.Errorf("UDP mismatch:\n  got  %v\n  want %v", udp, wantUDP)
	}
}

// Missing fixture main.conf must surface as a fail-closed error.
func TestRequiredPorts_RealLoader_MissingConfD_FailsClosed(t *testing.T) {
	saved := panelConfDDir
	panelConfDDir = t.TempDir()
	t.Cleanup(func() { panelConfDDir = saved })

	if _, _, err := New().RequiredPorts(context.Background(), executor.NewMockExecutor()); err == nil {
		t.Fatalf("expected error from real loader when main.conf is absent")
	}
}

func equalIntSlices(a, b []int) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func containsInt(slice []int, v int) bool {
	for _, p := range slice {
		if p == v {
			return true
		}
	}
	return false
}

// ----------------------------------------------------------------------------
// ValidateReachability
// ----------------------------------------------------------------------------

func TestValidateReachability_Listening_OK(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	mock.RunResults["ss:-lnt"] = executor.Result{ExitCode: 0, Stdout: ssOutput(defaultPort)}

	if err := a.ValidateReachability(context.Background(), mock); err != nil {
		t.Errorf("expected nil; got %v", err)
	}
}

func TestValidateReachability_NotListening_ReturnsError(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	mock.RunResults["ss:-lnt"] = executor.Result{ExitCode: 0, Stdout: ssOutput(80)}

	err := a.ValidateReachability(context.Background(), mock)
	if err == nil {
		t.Fatalf("expected error when port %d not listening", defaultPort)
	}
	if !strings.Contains(err.Error(), "8443") {
		t.Errorf("error should mention the port: %v", err)
	}
}

// Error must explicitly identify the scope as control-plane.
func TestValidateReachability_NotListening_ErrorMentionsControlPlane(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	mock.RunResults["ss:-lnt"] = executor.Result{ExitCode: 0, Stdout: ssOutput(80)}

	err := a.ValidateReachability(context.Background(), mock)
	if err == nil {
		t.Fatalf("expected error when control port not listening")
	}
	msg := err.Error()
	if !strings.Contains(msg, "control-plane") {
		t.Errorf("error must explicitly say 'control-plane'; got %q", msg)
	}
	for _, forbidden := range []string{
		"full panel survival validated",
		"full panel survived",
		"all Plesk ports validated",
		"all Plesk ports listening",
		"all panel ports listening",
		"all panel ports validated",
	} {
		if strings.Contains(msg, forbidden) {
			t.Errorf("error must NOT claim %q (overstates scope); got %q", forbidden, msg)
		}
	}
}

// Defensive: ":84443" must not match expected ":8443".
func TestValidateReachability_PortPrefixCollision(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	mock.RunResults["ss:-lnt"] = executor.Result{ExitCode: 0, Stdout: ssOutput(84443)}
	if err := a.ValidateReachability(context.Background(), mock); err == nil {
		t.Errorf("expected error — :84443 must not collide with :8443")
	}
}

// ss exit-code non-zero → treated as not-reachable.
func TestValidateReachability_SsErrorsOut_NotListening(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	mock.RunResults["ss:-lnt"] = executor.Result{ExitCode: 1, Stdout: "", Stderr: "ss: command not found"}
	if err := a.ValidateReachability(context.Background(), mock); err == nil {
		t.Errorf("expected error when ss fails — must NOT silently report reachable")
	}
}

// 8447 (Plesk Updater) listening but 8443 not — must FAIL.
// 8447 is part of the conf.d full surface but is NOT the control plane.
// This guard ensures the adapter probes 8443 specifically, not "any
// Plesk-shaped port".
func TestValidateReachability_Only8447Listening_FailsBecauseNot8443(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	mock.RunResults["ss:-lnt"] = executor.Result{ExitCode: 0, Stdout: ssOutput(8447)}
	if err := a.ValidateReachability(context.Background(), mock); err == nil {
		t.Errorf("expected error — Plesk Updater 8447 must not satisfy control-plane probe")
	}
}

// ----------------------------------------------------------------------------
// ID + adapter contract identity
// ----------------------------------------------------------------------------

func TestID(t *testing.T) {
	a := New()
	if a.ID() != adapterID {
		t.Errorf("ID() = %q; want %q", a.ID(), adapterID)
	}
	if string(a.ID()) != "plesk" {
		t.Errorf("string ID drift: %q", string(a.ID()))
	}
}

// ----------------------------------------------------------------------------
// Framework integration: registered adapter detected → policy fires
// ----------------------------------------------------------------------------

func stubCanonicalPlesk(t *testing.T) {
	withStubLoader(t, func(configDir, panelName string) (*ports.PanelConfig, error) {
		return &ports.PanelConfig{
			Name:    "plesk",
			Enabled: true,
			TCPIn:   synthPlesk.tcpIn,
			UDPIn:   synthPlesk.udpIn,
		}, nil
	})
}

func TestFrameworkIntegration_Plesk_Detected_Reachable_Passes(t *testing.T) {
	stubCanonicalPlesk(t)

	a := New()
	mock := executor.NewMockExecutor()
	seedPlesk(mock, defaultPort)

	res := panelfw.EvaluateAdapters(context.Background(), mock, newTestLogger(),
		[]panelfw.PanelAdapter{a}, panelfw.DefaultPolicy())

	if res.Fatal {
		t.Fatalf("expected Fatal=false on healthy Plesk host; got %#v", res)
	}
	if string(res.Detection.ID) != "plesk" {
		t.Errorf("expected detection ID=plesk; got %q", res.Detection.ID)
	}
	if !res.PortsApplied || !res.ReachableAfter {
		t.Errorf("expected PortsApplied+ReachableAfter true; got %#v", res)
	}
	if !equalIntSlices(res.PortsTCP, synthPlesk.tcpIn) {
		t.Errorf("PortsTCP pass-through mismatch; got %v want %v", res.PortsTCP, synthPlesk.tcpIn)
	}
	if !equalIntSlices(res.PortsUDP, synthPlesk.udpIn) {
		t.Errorf("PortsUDP pass-through mismatch; got %v want %v", res.PortsUDP, synthPlesk.udpIn)
	}
}

func TestFrameworkIntegration_Plesk_Detected_NotReachable_Blocks(t *testing.T) {
	stubCanonicalPlesk(t)

	a := New()
	mock := executor.NewMockExecutor()
	mock.Dirs[installDir] = true
	mock.Files[binaryPath] = []byte("ELF")
	mock.Services["sw-cp-server.service"] = true
	mock.RunResults["ss:-lnt"] = executor.Result{ExitCode: 0, Stdout: ssOutput(80)}

	res := panelfw.EvaluateAdapters(context.Background(), mock, newTestLogger(),
		[]panelfw.PanelAdapter{a}, panelfw.DefaultPolicy())

	if !res.Fatal {
		t.Fatalf("expected Fatal=true when Plesk detected but unreachable; got %#v", res)
	}
	if !strings.Contains(res.Reason, "plesk") && !strings.Contains(res.Reason, "Plesk") {
		t.Errorf("Reason should mention plesk: %q", res.Reason)
	}
	if !strings.Contains(res.Reason, "control-plane") {
		t.Errorf("Reason must say 'control-plane'; got %q", res.Reason)
	}
}

// Surfaced Reason on control-plane miss must NOT claim full-surface
// reachability has been probed.
func TestFrameworkIntegration_Plesk_ControlPlaneError_DoesNotClaimFullSurfaceReachability(t *testing.T) {
	stubCanonicalPlesk(t)

	a := New()
	mock := executor.NewMockExecutor()
	mock.Dirs[installDir] = true
	mock.Files[binaryPath] = []byte("ELF")
	mock.Services["sw-cp-server.service"] = true
	mock.RunResults["ss:-lnt"] = executor.Result{ExitCode: 0, Stdout: ssOutput(80)}

	res := panelfw.EvaluateAdapters(context.Background(), mock, newTestLogger(),
		[]panelfw.PanelAdapter{a}, panelfw.DefaultPolicy())

	if !res.Fatal {
		t.Fatalf("expected Fatal=true; got %#v", res)
	}
	for _, forbidden := range []string{
		"full panel survival validated",
		"full panel survived",
		"all Plesk ports validated",
		"all Plesk ports listening",
		"all panel ports listening",
		"all panel ports validated",
	} {
		if strings.Contains(res.Reason, forbidden) {
			t.Errorf("Reason must NOT claim %q (control-plane probe only); got %q", forbidden, res.Reason)
		}
	}
}

func TestFrameworkIntegration_Plesk_Absent_Passes(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	res := panelfw.EvaluateAdapters(context.Background(), mock, newTestLogger(),
		[]panelfw.PanelAdapter{a}, panelfw.DefaultPolicy())
	if res.Fatal {
		t.Fatalf("expected Fatal=false on bare host; got %#v", res)
	}
	if res.Detection.Detected {
		t.Errorf("expected Detection.Detected=false")
	}
}

// OperatorDisabled (--no-panel) flips a failing Plesk host to non-fatal.
func TestFrameworkIntegration_Plesk_NotReachable_OperatorDisabled_Passes(t *testing.T) {
	stubCanonicalPlesk(t)

	a := New()
	mock := executor.NewMockExecutor()
	mock.Dirs[installDir] = true
	mock.Files[binaryPath] = []byte("ELF")
	mock.RunResults["ss:-lnt"] = executor.Result{ExitCode: 0, Stdout: ssOutput(80)}

	policy := panelfw.DefaultPolicy()
	policy.OperatorDisabled = true
	res := panelfw.EvaluateAdapters(context.Background(), mock, newTestLogger(),
		[]panelfw.PanelAdapter{a}, policy)

	if res.Fatal {
		t.Fatalf("OperatorDisabled=true must convert failure to non-fatal: %#v", res)
	}
}

// ----------------------------------------------------------------------------
// init() registration
// ----------------------------------------------------------------------------

func TestInitRegistration_AdapterPresent(t *testing.T) {
	got := panelfw.RegisteredAdapters()
	var found bool
	for _, a := range got {
		if a.ID() == adapterID {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("Plesk adapter not registered via init(); registry=%v", got)
	}
}

// ----------------------------------------------------------------------------
// Read-only discipline
// ----------------------------------------------------------------------------

func TestReadOnly_NoWrites_NoMutationCommands(t *testing.T) {
	stubCanonicalPlesk(t)

	a := New()
	mock := executor.NewMockExecutor()
	seedPlesk(mock, defaultPort)

	_ = a.Detect(context.Background(), mock)
	_, _, _ = a.RequiredPorts(context.Background(), mock)
	_ = a.ValidateReachability(context.Background(), mock)

	if len(mock.WrittenFiles) != 0 {
		t.Errorf("adapter wrote %d files via executor (want 0)", len(mock.WrittenFiles))
	}
	for _, c := range mock.Commands {
		switch c.Name {
		case "ss":
			// expected — read-only socket query
		case "systemctl":
			// is-active only — ServiceActive is read-only on the mock
		default:
			t.Errorf("unexpected command %q (mutation suspected)", c.Name)
		}
	}
}
