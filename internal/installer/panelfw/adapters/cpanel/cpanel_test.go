// =============================================================================
// NFTBan v1.100.x PR26.8 - cPanel/WHM Adapter Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-panelfw-cpanel-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-01"
// meta:description="Detect / RequiredPorts / ValidateReachability + framework integration for cPanel"
// meta:inventory.files="internal/installer/panelfw/adapters/cpanel/cpanel_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package cpanel

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

// seedCpanel populates the mock with strong-confidence cPanel evidence
// in the lab4-realistic shape: install dir, cpanel binary,
// cpanel.service active (orchestrator), and TCP 2087 LISTEN (WHM
// HTTPS — admin control plane).
func seedCpanel(mock *executor.MockExecutor, listenPort int) {
	mock.Dirs[installDir] = true
	mock.Files[binaryPath] = []byte("ELF")
	mock.Services[systemdUnit] = true
	mock.RunResults["ss:-lnt"] = executor.Result{
		ExitCode: 0,
		Stdout:   ssOutput(listenPort),
	}
}

// seedCpanelUserSurfaceOnly mirrors the case where the WHM admin
// surface is down but cPanel user HTTPS (2083) is up. Per the any-of
// control-plane probe, this is still "panel reachable".
func seedCpanelUserSurfaceOnly(mock *executor.MockExecutor) {
	mock.Dirs[installDir] = true
	mock.Files[binaryPath] = []byte("ELF")
	mock.Services[systemdUnit] = true
	mock.RunResults["ss:-lnt"] = executor.Result{
		ExitCode: 0,
		Stdout:   ssOutput(portCPanelSSL),
	}
}

func ssOutput(listenPorts ...int) string {
	header := "State Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n"
	rows := []string{header}
	for _, p := range listenPorts {
		rows = append(rows, "LISTEN 0 128 0.0.0.0:"+itoa(p)+" 0.0.0.0:* users:((\"cpsrvd\",pid=1,fd=3))")
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

// PR26.8 lab4-realistic case — WHM admin surface is the listener.
// /usr/local/cpanel + /usr/local/cpanel/cpanel + cpanel.service +
// TCP 2087 LISTEN → strong / 4-signal / no warnings.
func TestDetect_AllSignals_Strong_WHMSurface(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	seedCpanel(mock, portWHMSSL)

	det := a.Detect(context.Background(), mock)
	if !det.Detected {
		t.Fatalf("expected Detected=true; got %#v", det)
	}
	if det.Confidence != "strong" {
		t.Errorf("expected strong confidence with 4 indicators; got %q (evidence=%v)",
			det.Confidence, det.Evidence)
	}
	if len(det.Evidence) != 4 {
		t.Errorf("expected 4 evidence entries; got %d (%v)", len(det.Evidence), det.Evidence)
	}
	if len(det.Warnings) != 0 {
		t.Errorf("expected zero warnings on healthy cPanel host; got %v", det.Warnings)
	}
	// RequiredTCP must declare BOTH control-plane ports (any-of model).
	if len(det.RequiredTCP) != 2 || det.RequiredTCP[0] != portWHMSSL || det.RequiredTCP[1] != portCPanelSSL {
		t.Errorf("expected RequiredTCP=[%d,%d]; got %v",
			portWHMSSL, portCPanelSSL, det.RequiredTCP)
	}
	// Evidence must explicitly name the WHM SSL port that satisfied E4.
	foundWHM := false
	for _, e := range det.Evidence {
		if e == "listener-tcp:2087" {
			foundWHM = true
		}
	}
	if !foundWHM {
		t.Errorf("evidence must record listener-tcp:2087; got %v", det.Evidence)
	}
}

// User-surface-only path: WHM down, cPanel HTTPS up. The any-of
// control-plane model says the panel is still reachable.
func TestDetect_AllSignals_Strong_UserSurfaceOnly(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	seedCpanelUserSurfaceOnly(mock)

	det := a.Detect(context.Background(), mock)
	if !det.Detected {
		t.Fatalf("expected Detected=true; got %#v", det)
	}
	if det.Confidence != "strong" {
		t.Errorf("expected strong confidence; got %q", det.Confidence)
	}
	foundUser := false
	for _, e := range det.Evidence {
		if e == "listener-tcp:2083" {
			foundUser = true
		}
		if e == "listener-tcp:2087" {
			t.Errorf("evidence wrongly references 2087 when only 2083 is listening: %v", det.Evidence)
		}
	}
	if !foundUser {
		t.Errorf("evidence must record listener-tcp:2083; got %v", det.Evidence)
	}
}

// First-match-wins discipline: when BOTH 2087 and 2083 are listening
// (the common healthy case), evidence must record 2087 only and
// signals must increment exactly once for E4. Prevents inflating
// confidence past 4/4 on a host where multiple control-plane ports
// happen to be up.
func TestDetect_BothControlPortsListening_FirstMatchWins(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	mock.Dirs[installDir] = true
	mock.Files[binaryPath] = []byte("ELF")
	mock.Services[systemdUnit] = true
	mock.RunResults["ss:-lnt"] = executor.Result{
		ExitCode: 0,
		Stdout:   ssOutput(portWHMSSL, portCPanelSSL),
	}

	det := a.Detect(context.Background(), mock)
	if !det.Detected {
		t.Fatalf("expected Detected=true")
	}
	listenerCount := 0
	for _, e := range det.Evidence {
		if strings.HasPrefix(e, "listener-tcp:") {
			listenerCount++
		}
	}
	if listenerCount != 1 {
		t.Errorf("E4 must record exactly one listener-tcp evidence (first-match-wins); got %d entries (%v)",
			listenerCount, det.Evidence)
	}
	// First match must be 2087 (WHM admin preferred — ordered first
	// in controlPlanePorts).
	for _, e := range det.Evidence {
		if strings.HasPrefix(e, "listener-tcp:") {
			if e != "listener-tcp:2087" {
				t.Errorf("first-match-wins must pick WHM (2087); got %q (controlPlanePorts order broken?)", e)
			}
			break
		}
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
	// Install dir + binary; service stopped, no listener.
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

// Scope guard: cpsrvd.service active alone (without cpanel.service)
// must NOT be treated as E3 evidence. Audit on lab4 found cpsrvd is
// the daemon that listens on 2087/2083 but its systemd unit is
// inactive on healthy hosts (orchestrator runs cpsrvd directly).
// Probing cpsrvd.service was the trap PR26.7 had with plesk.service;
// PR26.8 must not repeat it.
func TestDetect_OnlyCpsrvdServiceActive_NotE3Evidence(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	mock.Dirs[installDir] = true
	mock.Files[binaryPath] = []byte("ELF")
	mock.Services["cpsrvd.service"] = true // wrong unit name — must not count
	mock.RunResults["ss:-lnt"] = executor.Result{ExitCode: 0, Stdout: ssOutput(portWHMSSL)}

	det := a.Detect(context.Background(), mock)
	if !det.Detected {
		t.Fatalf("expected Detected=true via E1+E2+E4 even without proper E3")
	}
	for _, e := range det.Evidence {
		if e == "service-active:cpsrvd.service" {
			t.Errorf("evidence wrongly counts cpsrvd.service as E3; only cpanel.service is the orchestrator: %v", det.Evidence)
		}
	}
	// Three signals (E1+E2+E4 — E3 missing) → still confident enough
	// for "weak" (1-2) or "strong" (3+). With 3 we're exactly at the
	// strong boundary; assert that's stable.
	if det.Confidence != "strong" {
		t.Errorf("expected strong confidence with 3 of 4 signals; got %q (evidence=%v)",
			det.Confidence, det.Evidence)
	}
}

// Negative-coupling guard: a DirectAdmin-shape mock must NOT trigger
// cPanel detection.
func TestDetect_DirectAdminEvidence_NotCpanel(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	mock.Dirs["/usr/local/directadmin"] = true
	mock.Files["/usr/local/directadmin/directadmin"] = []byte("ELF")
	mock.Services["directadmin.service"] = true

	det := a.Detect(context.Background(), mock)
	if det.Detected {
		t.Fatalf("cPanel adapter must not detect on a DA-only host: %#v", det)
	}
}

// Negative-coupling guard: a Plesk-shape mock must NOT trigger
// cPanel detection.
func TestDetect_PleskEvidence_NotCpanel(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	mock.Dirs["/usr/local/psa"] = true
	mock.Files["/usr/local/psa/admin/bin/httpdmng"] = []byte("ELF")
	mock.Services["sw-cp-server.service"] = true

	det := a.Detect(context.Background(), mock)
	if det.Detected {
		t.Fatalf("cPanel adapter must not detect on a Plesk-only host: %#v", det)
	}
}

// CPANEL-RPCBIND-111-DIRECTIVE: a bare TCP/UDP 111 listener (rpcbind)
// without cPanel filesystem markers must NOT trigger cPanel detection.
// Guards against mistakenly treating rpcbind as cPanel evidence.
func TestDetect_RpcbindOnly_NotCpanel(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	mock.RunResults["ss:-lnt"] = executor.Result{
		ExitCode: 0,
		Stdout:   ssOutput(111),
	}
	det := a.Detect(context.Background(), mock)
	if det.Detected {
		t.Fatalf("cPanel adapter must not detect from bare port-111 listener (rpcbind/portmapper) without cPanel markers: %#v", det)
	}
}

// ----------------------------------------------------------------------------
// RequiredPorts
// ----------------------------------------------------------------------------

func withStubLoader(t *testing.T, fn func(configDir, panelName string) (*ports.PanelConfig, error)) {
	t.Helper()
	saved := panelConfDLoader
	panelConfDLoader = fn
	t.Cleanup(func() { panelConfDLoader = saved })
}

func withFixtureConfD(t *testing.T, mainConf string) string {
	t.Helper()
	tmp := t.TempDir()
	confDir := filepath.Join(tmp, "conf.d", "panels", "cpanel")
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
// The cPanel port surface (TCP/UDP × IN/OUT × IPv4/IPv6 + CUSTOM) lives
// ONLY in the shipped conf.d file:
//
//	etc/nftban/conf.d/panels/cpanel/main.conf
//
// That file is the single source of truth. Operators edit conf.d, not
// Go. Reproducing any port list in Go (this test file or production
// code) recreates the four-truth drift PR26.4 was created to close.
//
// CPANEL-RPCBIND-111-DIRECTIVE: the cPanel adapter MUST NOT include
// TCP/UDP 111 (rpcbind/portmapper) anywhere — not in Detect, not in
// RequiredPorts, not in ValidateReachability, not in conf.d. The
// canonical conf.d shipped in PR26.5 omits 111 by design. Operator-
// required NFS/RPC must go through the operator-services lane (custom
// ports.d / future service-profile / explicit allowlist) — never via
// panel conf.d.
//
// RULES FOR FUTURE EDITS TO THIS TEST FILE:
//   1. Stub-loader tests use the small `synthCpanel` synthetic fixture
//      below — clearly marked synthetic, not authoritative. Its only
//      job is to give the adapter SOMETHING to pass through so we can
//      test the contract (errors, defensive copies, fail-closed
//      branches). Its specific port values are arbitrary.
//   2. Tests that verify ACTUAL cPanel port content read the shipped
//      conf.d via the real loader. Use
//      `locateRepoFile(t, "etc/nftban/conf.d/panels/cpanel/main.conf")`.
//   3. Do NOT add hardcoded port lists to Go. If you find yourself
//      typing a list of cPanel ports in this file, stop and put them
//      in conf.d instead.
//   4. Do NOT add port 111 to synthCpanel or any test fixture except
//      the explicit no-111 negative tests below.
// =============================================================================

// synthCpanel is a tiny synthetic PanelConfig for stub-loader tests.
// Synthetic — NOT the canonical cPanel port surface.
var synthCpanel = struct {
	tcpIn []int
	udpIn []int
}{
	tcpIn: []int{2087, 2083, 25, 80, 443, 587},
	udpIn: []int{53, 443},
}

func TestRequiredPorts_ConfDLoaded_FullSurface(t *testing.T) {
	withStubLoader(t, func(configDir, panelName string) (*ports.PanelConfig, error) {
		if panelName != "cpanel" {
			t.Fatalf("loader called with panelName=%q; want cpanel", panelName)
		}
		return &ports.PanelConfig{
			Name:       "cpanel",
			Enabled:    true,
			ConfigFile: configDir + "/conf.d/panels/cpanel/main.conf",
			TCPIn:      synthCpanel.tcpIn,
			UDPIn:      synthCpanel.udpIn,
		}, nil
	})

	a := New()
	tcp, udp, err := a.RequiredPorts(context.Background(), executor.NewMockExecutor())
	if err != nil {
		t.Fatalf("RequiredPorts must not error on stub fixture: %v", err)
	}
	if !equalIntSlices(tcp, synthCpanel.tcpIn) {
		t.Errorf("TCP pass-through mismatch:\n  got  %v\n  want %v", tcp, synthCpanel.tcpIn)
	}
	if !equalIntSlices(udp, synthCpanel.udpIn) {
		t.Errorf("UDP pass-through mismatch:\n  got  %v\n  want %v", udp, synthCpanel.udpIn)
	}
}

// RequiredPorts must NOT fall back to {2087, 2083}-only on any path.
func TestRequiredPorts_ConfDLoaded_NotJustControlPorts(t *testing.T) {
	withStubLoader(t, func(configDir, panelName string) (*ports.PanelConfig, error) {
		return &ports.PanelConfig{
			Name:  "cpanel",
			TCPIn: synthCpanel.tcpIn,
			UDPIn: synthCpanel.udpIn,
		}, nil
	})

	tcp, udp, err := New().RequiredPorts(context.Background(), executor.NewMockExecutor())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(tcp) <= 2 {
		t.Fatalf("expected full cPanel TCP surface; got only %v", tcp)
	}
	hasNonControl := false
	for _, p := range tcp {
		if p != portWHMSSL && p != portCPanelSSL {
			hasNonControl = true
			break
		}
	}
	if !hasNonControl {
		t.Errorf("RequiredPorts must include ports beyond control-plane {2087, 2083}; got %v", tcp)
	}
	if len(udp) == 0 {
		t.Errorf("RequiredPorts must declare UDP surface for cPanel; got empty")
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

func TestRequiredPorts_MissingConfD_FailsClosed(t *testing.T) {
	withStubLoader(t, func(configDir, panelName string) (*ports.PanelConfig, error) {
		return nil, fmt.Errorf("panel config not found: %s/conf.d/panels/%s/main.conf",
			configDir, panelName)
	})

	tcp, udp, err := New().RequiredPorts(context.Background(), executor.NewMockExecutor())
	if err == nil {
		t.Fatalf("expected error on missing conf.d; got tcp=%v udp=%v", tcp, udp)
	}
	if !strings.Contains(err.Error(), "cPanel") || !strings.Contains(err.Error(), "conf.d") {
		t.Errorf("error must reference cPanel and conf.d; got %v", err)
	}
	assertNoControlPlaneFallback(t, tcp, udp)
}

func TestRequiredPorts_EmptyTCPIn_FailsClosed(t *testing.T) {
	withStubLoader(t, func(configDir, panelName string) (*ports.PanelConfig, error) {
		return &ports.PanelConfig{
			Name:       "cpanel",
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

// SSH port 22 must be absent from shipped conf.d (managed separately
// via /etc/nftban/ports.d/00-ssh.conf).
func TestRequiredPorts_ConfDDoesNotIncludeSSHPort22(t *testing.T) {
	if _, err := os.Stat("/bin/bash"); err != nil {
		t.Skipf("/bin/bash unavailable on this host: %v", err)
	}
	shipped := locateRepoFile(t, "etc/nftban/conf.d/panels/cpanel/main.conf")
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
		t.Errorf("shipped cPanel conf.d declares port 22 in TCP_IN — "+
			"SSH is managed by /etc/nftban/ports.d/00-ssh.conf; check %s", shipped)
	}
	if containsInt(udp, 22) {
		t.Errorf("shipped cPanel conf.d declares port 22 in UDP_IN; check %s", shipped)
	}
}

// CPANEL-RPCBIND-111-DIRECTIVE — port 111 must be ABSENT from shipped
// cPanel conf.d. If a future edit adds 111, this test trips
// immediately. Operator-required NFS/RPC must go through the
// operator-services lane, not via panel conf.d.
func TestRequiredPorts_ConfDDoesNotIncludeRpcbindPort111(t *testing.T) {
	if _, err := os.Stat("/bin/bash"); err != nil {
		t.Skipf("/bin/bash unavailable on this host: %v", err)
	}
	shipped := locateRepoFile(t, "etc/nftban/conf.d/panels/cpanel/main.conf")
	data, err := os.ReadFile(shipped) // #nosec G304 -- fixed path under repo
	if err != nil {
		t.Fatalf("read shipped main.conf at %s: %v", shipped, err)
	}
	withFixtureConfD(t, string(data))

	tcp, udp, err := New().RequiredPorts(context.Background(), executor.NewMockExecutor())
	if err != nil {
		t.Fatalf("unexpected error loading shipped conf.d: %v", err)
	}
	if containsInt(tcp, 111) {
		t.Errorf("CPANEL-RPCBIND-111-DIRECTIVE violated: shipped cPanel conf.d declares port 111 in TCP_IN — "+
			"rpcbind/portmapper is operator/service-specific RPC surface, NOT cPanel panel-survival. "+
			"Move to operator-services lane (custom ports.d / explicit allowlist). Check %s", shipped)
	}
	if containsInt(udp, 111) {
		t.Errorf("CPANEL-RPCBIND-111-DIRECTIVE violated: shipped cPanel conf.d declares port 111 in UDP_IN. "+
			"Check %s", shipped)
	}
}

// Real-loader assertion: the shipped conf.d must include BOTH cPanel
// control-plane ports (2087 + 2083). Without them the panel itself
// is unreachable. Structural assertions only.
func TestRequiredPorts_RealLoader_ControlPortsAndSurfaceSize(t *testing.T) {
	if _, err := os.Stat("/bin/bash"); err != nil {
		t.Skipf("/bin/bash unavailable on this host: %v", err)
	}
	shipped := locateRepoFile(t, "etc/nftban/conf.d/panels/cpanel/main.conf")
	data, err := os.ReadFile(shipped) // #nosec G304 -- fixed path under repo
	if err != nil {
		t.Fatalf("read shipped main.conf at %s: %v", shipped, err)
	}
	withFixtureConfD(t, string(data))

	tcp, udp, err := New().RequiredPorts(context.Background(), executor.NewMockExecutor())
	if err != nil {
		t.Fatalf("real-loader RequiredPorts: %v", err)
	}

	for _, p := range controlPlanePorts {
		if !containsInt(tcp, p) {
			t.Errorf("TCP_IN must include cPanel control port %d; got len=%d (check %s)",
				p, len(tcp), shipped)
		}
	}
	if containsInt(tcp, 22) {
		t.Errorf("real loader produced TCP_IN containing port 22 — conf.d four-truth violation; check %s", shipped)
	}
	if containsInt(udp, 22) {
		t.Errorf("real loader produced UDP_IN containing port 22; check %s", shipped)
	}
	// CPANEL-RPCBIND-111-DIRECTIVE — defense-in-depth.
	if containsInt(tcp, 111) || containsInt(udp, 111) {
		t.Errorf("real loader produced port 111 — CPANEL-RPCBIND-111-DIRECTIVE violation; check %s", shipped)
	}
	if len(udp) == 0 {
		t.Errorf("UDP_IN empty — conf.d should declare cPanel's UDP surface (DNS, etc.)")
	}
	// Sanity floor — cPanel's surface is bigger than just 2 control ports.
	if len(tcp) < 10 {
		t.Errorf("TCP_IN length = %d; expected larger cPanel surface (mail, web, panel, webmail, dav); "+
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

func assertNoControlPlaneFallback(t *testing.T, tcp, udp []int) {
	t.Helper()
	if len(tcp) != 0 {
		t.Errorf("fail-closed: tcp must be nil/empty on error — must NOT fall back to control-plane defaults; got %v", tcp)
	}
	if len(udp) != 0 {
		t.Errorf("fail-closed: udp must be nil/empty on error; got %v", udp)
	}
}

func TestRequiredPorts_DefensiveCopy(t *testing.T) {
	internalTCP := []int{20, 21, 25, 2083, 2087}
	internalUDP := []int{53, 443}
	withStubLoader(t, func(configDir, panelName string) (*ports.PanelConfig, error) {
		return &ports.PanelConfig{Name: "cpanel", TCPIn: internalTCP, UDPIn: internalUDP}, nil
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

func TestRequiredPorts_ConfDLoaded_RealLoader_FixtureFile(t *testing.T) {
	if _, err := os.Stat("/bin/bash"); err != nil {
		t.Skipf("/bin/bash unavailable on this host: %v", err)
	}
	const fixtureMain = `# fixture main.conf for PR26.8 integration test
NFTBAN_CPANEL_PATH="/usr/local/cpanel"
NFTBAN_CPANEL_PANEL_PORT="2082"
NFTBAN_CPANEL_PANEL_SSL_PORT="2083"
NFTBAN_WHM_PANEL_PORT="2086"
NFTBAN_WHM_PANEL_SSL_PORT="2087"
NFTBAN_CPANEL_TCP_IN="20,21,25,2082,2083,2086,2087"
NFTBAN_CPANEL_UDP_IN="53,443"
NFTBAN_CPANEL_TCP_OUT="20,21,25,2087"
NFTBAN_CPANEL_UDP_OUT="53,123"
`
	withFixtureConfD(t, fixtureMain)

	tcp, udp, err := New().RequiredPorts(context.Background(), executor.NewMockExecutor())
	if err != nil {
		t.Fatalf("real-loader RequiredPorts: %v", err)
	}
	wantTCP := []int{20, 21, 25, 2082, 2083, 2086, 2087}
	wantUDP := []int{53, 443}
	if !equalIntSlices(tcp, wantTCP) {
		t.Errorf("TCP mismatch:\n  got  %v\n  want %v", tcp, wantTCP)
	}
	if !equalIntSlices(udp, wantUDP) {
		t.Errorf("UDP mismatch:\n  got  %v\n  want %v", udp, wantUDP)
	}
}

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
// ValidateReachability — any-of {2087, 2083}
// ----------------------------------------------------------------------------

func TestValidateReachability_WHMListening_OK(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	mock.RunResults["ss:-lnt"] = executor.Result{ExitCode: 0, Stdout: ssOutput(portWHMSSL)}

	if err := a.ValidateReachability(context.Background(), mock); err != nil {
		t.Errorf("expected nil with WHM 2087 listening; got %v", err)
	}
}

func TestValidateReachability_CPanelListening_OK(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	mock.RunResults["ss:-lnt"] = executor.Result{ExitCode: 0, Stdout: ssOutput(portCPanelSSL)}

	if err := a.ValidateReachability(context.Background(), mock); err != nil {
		t.Errorf("expected nil with cPanel 2083 listening; got %v", err)
	}
}

func TestValidateReachability_BothListening_OK(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	mock.RunResults["ss:-lnt"] = executor.Result{
		ExitCode: 0,
		Stdout:   ssOutput(portWHMSSL, portCPanelSSL),
	}
	if err := a.ValidateReachability(context.Background(), mock); err != nil {
		t.Errorf("expected nil with both control ports listening; got %v", err)
	}
}

func TestValidateReachability_NeitherListening_ReturnsError(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	mock.RunResults["ss:-lnt"] = executor.Result{ExitCode: 0, Stdout: ssOutput(80)}

	err := a.ValidateReachability(context.Background(), mock)
	if err == nil {
		t.Fatalf("expected error when neither 2087 nor 2083 listening")
	}
	msg := err.Error()
	if !strings.Contains(msg, "2087") || !strings.Contains(msg, "2083") {
		t.Errorf("error must name BOTH probed ports; got %q", msg)
	}
	if !strings.Contains(msg, "control-plane") {
		t.Errorf("error must say 'control-plane'; got %q", msg)
	}
	for _, forbidden := range []string{
		"full panel survival validated",
		"full panel survived",
		"all cPanel ports validated",
		"all cPanel ports listening",
		"all panel ports listening",
		"all panel ports validated",
	} {
		if strings.Contains(msg, forbidden) {
			t.Errorf("error must NOT claim %q (overstates scope); got %q", forbidden, msg)
		}
	}
}

// Defensive: ":12087" must not match expected ":2087".
func TestValidateReachability_PortPrefixCollision(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	mock.RunResults["ss:-lnt"] = executor.Result{ExitCode: 0, Stdout: ssOutput(12087)}
	if err := a.ValidateReachability(context.Background(), mock); err == nil {
		t.Errorf("expected error — :12087 must not collide with :2087")
	}
}

func TestValidateReachability_SsErrorsOut_NotListening(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	mock.RunResults["ss:-lnt"] = executor.Result{ExitCode: 1, Stdout: "", Stderr: "ss: command not found"}
	if err := a.ValidateReachability(context.Background(), mock); err == nil {
		t.Errorf("expected error when ss fails — must NOT silently report reachable")
	}
}

// 2086/2082 (HTTP redirect ports) listening but neither HTTPS port up.
// Must FAIL — control plane is HTTPS-only.
func TestValidateReachability_OnlyHTTPRedirects_Fails(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	mock.RunResults["ss:-lnt"] = executor.Result{ExitCode: 0, Stdout: ssOutput(2086, 2082)}
	if err := a.ValidateReachability(context.Background(), mock); err == nil {
		t.Errorf("expected error — HTTP redirect ports 2086/2082 must not satisfy control-plane probe")
	}
}

// CPANEL-RPCBIND-111-DIRECTIVE — port 111 listening (rpcbind) must
// NOT satisfy control-plane reachability. Guards against any future
// loosening of the any-of probe to include arbitrary listening ports.
func TestValidateReachability_RpcbindOnly_Fails(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	mock.RunResults["ss:-lnt"] = executor.Result{ExitCode: 0, Stdout: ssOutput(111)}
	if err := a.ValidateReachability(context.Background(), mock); err == nil {
		t.Errorf("expected error — port 111 (rpcbind) must not satisfy cPanel control-plane probe")
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
	if string(a.ID()) != "cpanel" {
		t.Errorf("string ID drift: %q", string(a.ID()))
	}
}

// ----------------------------------------------------------------------------
// Framework integration: registered adapter detected → policy fires
// ----------------------------------------------------------------------------

func stubCanonicalCpanel(t *testing.T) {
	withStubLoader(t, func(configDir, panelName string) (*ports.PanelConfig, error) {
		return &ports.PanelConfig{
			Name:    "cpanel",
			Enabled: true,
			TCPIn:   synthCpanel.tcpIn,
			UDPIn:   synthCpanel.udpIn,
		}, nil
	})
}

func TestFrameworkIntegration_Cpanel_Detected_Reachable_Passes(t *testing.T) {
	stubCanonicalCpanel(t)

	a := New()
	mock := executor.NewMockExecutor()
	seedCpanel(mock, portWHMSSL)

	res := panelfw.EvaluateAdapters(context.Background(), mock, newTestLogger(),
		[]panelfw.PanelAdapter{a}, panelfw.DefaultPolicy())

	if res.Fatal {
		t.Fatalf("expected Fatal=false on healthy cPanel host; got %#v", res)
	}
	if string(res.Detection.ID) != "cpanel" {
		t.Errorf("expected detection ID=cpanel; got %q", res.Detection.ID)
	}
	if !res.PortsApplied || !res.ReachableAfter {
		t.Errorf("expected PortsApplied+ReachableAfter true; got %#v", res)
	}
	if !equalIntSlices(res.PortsTCP, synthCpanel.tcpIn) {
		t.Errorf("PortsTCP pass-through mismatch; got %v want %v", res.PortsTCP, synthCpanel.tcpIn)
	}
	if !equalIntSlices(res.PortsUDP, synthCpanel.udpIn) {
		t.Errorf("PortsUDP pass-through mismatch; got %v want %v", res.PortsUDP, synthCpanel.udpIn)
	}
}

func TestFrameworkIntegration_Cpanel_Detected_NotReachable_Blocks(t *testing.T) {
	stubCanonicalCpanel(t)

	a := New()
	mock := executor.NewMockExecutor()
	mock.Dirs[installDir] = true
	mock.Files[binaryPath] = []byte("ELF")
	mock.Services[systemdUnit] = true
	mock.RunResults["ss:-lnt"] = executor.Result{ExitCode: 0, Stdout: ssOutput(80)}

	res := panelfw.EvaluateAdapters(context.Background(), mock, newTestLogger(),
		[]panelfw.PanelAdapter{a}, panelfw.DefaultPolicy())

	if !res.Fatal {
		t.Fatalf("expected Fatal=true when cPanel detected but unreachable; got %#v", res)
	}
	if !strings.Contains(res.Reason, "cpanel") && !strings.Contains(res.Reason, "cPanel") {
		t.Errorf("Reason should mention cPanel: %q", res.Reason)
	}
	if !strings.Contains(res.Reason, "control-plane") {
		t.Errorf("Reason must say 'control-plane'; got %q", res.Reason)
	}
}

func TestFrameworkIntegration_Cpanel_ControlPlaneError_DoesNotClaimFullSurfaceReachability(t *testing.T) {
	stubCanonicalCpanel(t)

	a := New()
	mock := executor.NewMockExecutor()
	mock.Dirs[installDir] = true
	mock.Files[binaryPath] = []byte("ELF")
	mock.Services[systemdUnit] = true
	mock.RunResults["ss:-lnt"] = executor.Result{ExitCode: 0, Stdout: ssOutput(80)}

	res := panelfw.EvaluateAdapters(context.Background(), mock, newTestLogger(),
		[]panelfw.PanelAdapter{a}, panelfw.DefaultPolicy())

	if !res.Fatal {
		t.Fatalf("expected Fatal=true; got %#v", res)
	}
	for _, forbidden := range []string{
		"full panel survival validated",
		"full panel survived",
		"all cPanel ports validated",
		"all cPanel ports listening",
		"all panel ports listening",
		"all panel ports validated",
	} {
		if strings.Contains(res.Reason, forbidden) {
			t.Errorf("Reason must NOT claim %q (control-plane probe only); got %q", forbidden, res.Reason)
		}
	}
}

func TestFrameworkIntegration_Cpanel_Absent_Passes(t *testing.T) {
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

func TestFrameworkIntegration_Cpanel_NotReachable_OperatorDisabled_Passes(t *testing.T) {
	stubCanonicalCpanel(t)

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
		t.Fatalf("cPanel adapter not registered via init(); registry=%v", got)
	}
}

// ----------------------------------------------------------------------------
// Read-only discipline
// ----------------------------------------------------------------------------

func TestReadOnly_NoWrites_NoMutationCommands(t *testing.T) {
	stubCanonicalCpanel(t)

	a := New()
	mock := executor.NewMockExecutor()
	seedCpanel(mock, portWHMSSL)

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
