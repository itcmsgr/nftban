// =============================================================================
// NFTBan v1.100.x PR26.3 - DirectAdmin Adapter Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-panelfw-directadmin-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-29"
// meta:description="Detect / RequiredPorts / ValidateReachability + framework integration"
// meta:inventory.files="internal/installer/panelfw/adapters/directadmin/directadmin_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package directadmin

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
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

// seedDirectAdmin populates the mock with strong-confidence DA evidence:
// install dir, binary, active service, and TCP <port> in LISTEN state.
func seedDirectAdmin(mock *executor.MockExecutor, port int) {
	mock.Dirs[installDir] = true
	mock.Files[binaryPath] = []byte("ELF")
	mock.Services[systemdUnit] = true
	// Mock the `ss -lnt` output containing a LISTEN row for the port.
	mock.RunResults["ss:-lnt"] = executor.Result{
		ExitCode: 0,
		Stdout: ssOutput(port),
	}
}

func ssOutput(listenPorts ...int) string {
	header := "State Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n"
	rows := []string{header}
	for _, p := range listenPorts {
		rows = append(rows, "LISTEN 0 128 0.0.0.0:"+itoa(p)+" 0.0.0.0:* users:((\"directadmin\",pid=1,fd=3))")
	}
	return strings.Join(rows, "\n")
}

func itoa(n int) string {
	// Avoid pulling strconv into the test fixture preamble; the
	// adapter uses strconv.Itoa internally.
	return formatInt(n)
}

// formatInt renders a non-negative int as decimal. Sufficient for the
// 1–65535 port range used in tests.
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
	seedDirectAdmin(mock, 2222)

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
	if len(det.RequiredTCP) != 1 || det.RequiredTCP[0] != 2222 {
		t.Errorf("expected RequiredTCP=[2222]; got %v", det.RequiredTCP)
	}
}

func TestDetect_Absent_NotDetected(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	// no install dir, no binary, no service, no listener
	det := a.Detect(context.Background(), mock)
	if det.Detected {
		t.Fatalf("expected Detected=false on bare host; got %#v", det)
	}
}

func TestDetect_PartialInstall_Weak(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	// Only the install dir + binary; service stopped, no listener.
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

// Service-only signal still counts as a (weak) detection — DirectAdmin
// with no install dir present is unusual, but the signal matters.
func TestDetect_ServiceOnly_Weak(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	mock.Services[systemdUnit] = true

	det := a.Detect(context.Background(), mock)
	if !det.Detected {
		t.Fatalf("expected Detected=true on service-active alone")
	}
	if det.Confidence != "weak" {
		t.Errorf("expected weak confidence; got %q", det.Confidence)
	}
}

// ----------------------------------------------------------------------------
// RequiredPorts
// ----------------------------------------------------------------------------

// PR26.4: RequiredPorts now consumes
// internal/ports/panel_loader.LoadPanelConfig("directadmin"). It must
// return the canonical conf.d-declared TCP_IN / UDP_IN port surface,
// NOT a hardcoded [2222] list. Tests stub panelConfDLoader to inject
// fixture PanelConfig values; one integration test exercises the
// real bash-subshell loader against a tempdir-stamped main.conf.

// withStubLoader temporarily replaces panelConfDLoader with a
// deterministic fixture provider. Restores the original on cleanup.
func withStubLoader(t *testing.T, fn func(configDir, panelName string) (*ports.PanelConfig, error)) {
	t.Helper()
	saved := panelConfDLoader
	panelConfDLoader = fn
	t.Cleanup(func() { panelConfDLoader = saved })
}

// withFixtureConfD writes a real conf.d/panels/directadmin/main.conf
// under a tempdir and points panelConfDDir at it for the duration of
// the test. Used by the integration test that exercises the real
// LoadPanelConfig (which shells to bash to source the file).
func withFixtureConfD(t *testing.T, mainConf string) string {
	t.Helper()
	tmp := t.TempDir()
	confDir := filepath.Join(tmp, "conf.d", "panels", "directadmin")
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

// canonicalDA is the conf.d port surface that ships with NFTBan
// (etc/nftban/conf.d/panels/directadmin/main.conf as of PR26.4). The
// adapter's RequiredPorts must return this set verbatim, no addition,
// no truncation.
var canonicalDA = struct {
	tcpIn []int
	udpIn []int
}{
	// TCP_IN: 20,21,25,53,853,80,110,143,443,465,587,993,995,2222,35000-35999
	tcpIn: append([]int{20, 21, 25, 53, 853, 80, 110, 143, 443, 465, 587, 993, 995, 2222}, expandRange(35000, 35999)...),
	// UDP_IN: 20,21,53,853,80,443
	udpIn: []int{20, 21, 53, 853, 80, 443},
}

func expandRange(lo, hi int) []int {
	out := make([]int, 0, hi-lo+1)
	for p := lo; p <= hi; p++ {
		out = append(out, p)
	}
	return out
}

// PR26.4 R1: RequiredPorts equals DirectAdmin conf.d TCP/UDP declarations.
func TestRequiredPorts_ConfDLoaded_FullSurface(t *testing.T) {
	withStubLoader(t, func(configDir, panelName string) (*ports.PanelConfig, error) {
		if panelName != "directadmin" {
			t.Fatalf("loader called with panelName=%q; want directadmin", panelName)
		}
		return &ports.PanelConfig{
			Name:       "directadmin",
			Enabled:    true,
			ConfigFile: configDir + "/conf.d/panels/directadmin/main.conf",
			TCPIn:      canonicalDA.tcpIn,
			UDPIn:      canonicalDA.udpIn,
		}, nil
	})

	a := New()
	tcp, udp, err := a.RequiredPorts(context.Background(), executor.NewMockExecutor())
	if err != nil {
		t.Fatalf("RequiredPorts must not error on canonical DA conf.d: %v", err)
	}
	if !equalIntSlices(tcp, canonicalDA.tcpIn) {
		t.Errorf("TCP surface mismatch:\n  got  %v\n  want %v", tcp, canonicalDA.tcpIn)
	}
	if !equalIntSlices(udp, canonicalDA.udpIn) {
		t.Errorf("UDP surface mismatch:\n  got  %v\n  want %v", udp, canonicalDA.udpIn)
	}
}

// PR26.4 R2: RequiredPorts is NOT [2222]-only. This is a structural
// regression check that ensures the legacy hardcoded path is gone.
func TestRequiredPorts_ConfDLoaded_NotJust2222(t *testing.T) {
	withStubLoader(t, func(configDir, panelName string) (*ports.PanelConfig, error) {
		return &ports.PanelConfig{
			Name:  "directadmin",
			TCPIn: canonicalDA.tcpIn,
			UDPIn: canonicalDA.udpIn,
		}, nil
	})

	tcp, udp, err := New().RequiredPorts(context.Background(), executor.NewMockExecutor())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(tcp) <= 1 {
		t.Fatalf("expected full DA TCP surface; got only %v", tcp)
	}
	// Specific checks: at least one non-2222 TCP port; UDP non-empty.
	hasNon2222 := false
	for _, p := range tcp {
		if p != 2222 {
			hasNon2222 = true
			break
		}
	}
	if !hasNon2222 {
		t.Errorf("RequiredPorts must include ports beyond control-plane 2222; got %v", tcp)
	}
	if len(udp) == 0 {
		t.Errorf("RequiredPorts must declare UDP surface for DA; got empty")
	}
	// Specific port spot-checks (TCP 25 SMTP, TCP 443 HTTPS, UDP 53 DNS).
	for _, p := range []int{25, 443} {
		if !containsInt(tcp, p) {
			t.Errorf("TCP surface missing canonical port %d; got %v", p, tcp)
		}
	}
	if !containsInt(udp, 53) {
		t.Errorf("UDP surface missing canonical port 53; got %v", udp)
	}
}

// PR26.4 R4: missing conf.d main.conf must fail closed.
func TestRequiredPorts_MissingConfD_FailsClosed(t *testing.T) {
	withStubLoader(t, func(configDir, panelName string) (*ports.PanelConfig, error) {
		return nil, fmt.Errorf("panel config not found: %s/conf.d/panels/%s/main.conf",
			configDir, panelName)
	})

	tcp, udp, err := New().RequiredPorts(context.Background(), executor.NewMockExecutor())
	if err == nil {
		t.Fatalf("expected error on missing conf.d; got tcp=%v udp=%v", tcp, udp)
	}
	if !strings.Contains(err.Error(), "DirectAdmin conf.d") {
		t.Errorf("error must reference DirectAdmin conf.d; got %v", err)
	}
}

// PR26.4 R5: malformed conf.d (loaded but empty TCP_IN) must fail closed.
func TestRequiredPorts_EmptyTCPIn_FailsClosed(t *testing.T) {
	withStubLoader(t, func(configDir, panelName string) (*ports.PanelConfig, error) {
		return &ports.PanelConfig{
			Name:       "directadmin",
			ConfigFile: "/tmp/test/main.conf",
			TCPIn:      nil, // malformed: panel host with no inbound surface
			UDPIn:      []int{53},
		}, nil
	})

	_, _, err := New().RequiredPorts(context.Background(), executor.NewMockExecutor())
	if err == nil {
		t.Fatalf("expected error on empty TCP_IN")
	}
	if !strings.Contains(err.Error(), "no TCP_IN") {
		t.Errorf("error must explain malformed TCP_IN; got %v", err)
	}
}

// Loader returning nil PanelConfig (defensive).
func TestRequiredPorts_NilPanelConfig_FailsClosed(t *testing.T) {
	withStubLoader(t, func(configDir, panelName string) (*ports.PanelConfig, error) {
		return nil, nil
	})
	if _, _, err := New().RequiredPorts(context.Background(), executor.NewMockExecutor()); err == nil {
		t.Fatalf("expected error when loader returns nil cfg")
	}
}

// PR26.4 defensive: returned slices must not alias internal loader state.
func TestRequiredPorts_DefensiveCopy(t *testing.T) {
	internalTCP := []int{20, 21, 25, 2222}
	internalUDP := []int{53, 443}
	withStubLoader(t, func(configDir, panelName string) (*ports.PanelConfig, error) {
		return &ports.PanelConfig{Name: "directadmin", TCPIn: internalTCP, UDPIn: internalUDP}, nil
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

// Integration: real internal/ports.LoadPanelConfig against a tempdir-
// stamped fixture main.conf. Exercises the actual bash-subshell parser
// path so a future change in the conf.d format or loader behavior
// surfaces here. Skipped if /bin/bash is not available.
func TestRequiredPorts_ConfDLoaded_RealLoader_FixtureFile(t *testing.T) {
	if _, err := os.Stat("/bin/bash"); err != nil {
		t.Skipf("/bin/bash unavailable on this host: %v", err)
	}
	const fixtureMain = `# fixture main.conf for PR26.4 integration test
NFTBAN_DIRECTADMIN_PATH="/usr/local/directadmin"
NFTBAN_DIRECTADMIN_PANEL_PORT="2222"
NFTBAN_DIRECTADMIN_TCP_IN="20,21,25,2222,35000-35001"
NFTBAN_DIRECTADMIN_UDP_IN="53,853"
NFTBAN_DIRECTADMIN_TCP_OUT="20,21,25,2222"
NFTBAN_DIRECTADMIN_UDP_OUT="53,123"
`
	withFixtureConfD(t, fixtureMain)

	tcp, udp, err := New().RequiredPorts(context.Background(), executor.NewMockExecutor())
	if err != nil {
		t.Fatalf("real-loader RequiredPorts: %v", err)
	}
	wantTCP := []int{20, 21, 25, 2222, 35000, 35001}
	wantUDP := []int{53, 853}
	if !equalIntSlices(tcp, wantTCP) {
		t.Errorf("TCP mismatch:\n  got  %v\n  want %v", tcp, wantTCP)
	}
	if !equalIntSlices(udp, wantUDP) {
		t.Errorf("UDP mismatch:\n  got  %v\n  want %v", udp, wantUDP)
	}
}

// Integration: missing fixture main.conf must surface as a fail-closed
// error from the real loader.
func TestRequiredPorts_RealLoader_MissingConfD_FailsClosed(t *testing.T) {
	saved := panelConfDDir
	panelConfDDir = t.TempDir() // tempdir without conf.d/ in it
	t.Cleanup(func() { panelConfDDir = saved })

	if _, _, err := New().RequiredPorts(context.Background(), executor.NewMockExecutor()); err == nil {
		t.Fatalf("expected error from real loader when main.conf is absent")
	}
}

// equalIntSlices compares two int slices order-sensitively.
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
// ValidateReachability — directadmin.conf control-port override now lives here
// (PR26.4 separates control-plane probing from RequiredPorts surface load).
// ----------------------------------------------------------------------------

// PR26.4 R3: ValidateReachability still honors directadmin.conf
// `port=N` override. Previously tested via RequiredPorts; now tested
// where the override actually applies.
func TestValidateReachability_ConfigOverride_HonoredByControlPlane(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	mock.Files[configPath] = []byte("port=2225\n")
	mock.RunResults["ss:-lnt"] = executor.Result{ExitCode: 0, Stdout: ssOutput(2225)}
	if err := a.ValidateReachability(context.Background(), mock); err != nil {
		t.Errorf("expected nil; got %v", err)
	}
}

// Malformed override → control-plane probes the default port (2222).
// Reachability check passes only if 2222 is listening.
func TestValidateReachability_MalformedOverride_FallsBackToDefault(t *testing.T) {
	cases := []struct{ name, conf string }{
		{"non-numeric", "port=NOT_A_PORT\n"},
		{"out-of-range-zero", "port=0\n"},
		{"out-of-range-high", "port=99999\n"},
		{"missing-port", "foo=bar\n"},
		{"empty", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			a := New()
			mock := executor.NewMockExecutor()
			mock.Files[configPath] = []byte(c.conf)
			// 2222 listening → fallback succeeds.
			mock.RunResults["ss:-lnt"] = executor.Result{ExitCode: 0, Stdout: ssOutput(defaultPort)}
			if err := a.ValidateReachability(context.Background(), mock); err != nil {
				t.Errorf("malformed config should fall back to default %d; got error: %v", defaultPort, err)
			}
		})
	}
}

// ----------------------------------------------------------------------------
// ValidateReachability
// ----------------------------------------------------------------------------

func TestValidateReachability_Listening_OK(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	mock.RunResults["ss:-lnt"] = executor.Result{ExitCode: 0, Stdout: ssOutput(2222)}

	if err := a.ValidateReachability(context.Background(), mock); err != nil {
		t.Errorf("expected nil; got %v", err)
	}
}

func TestValidateReachability_NotListening_ReturnsError(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	// Listener present but on a different port — must NOT match.
	mock.RunResults["ss:-lnt"] = executor.Result{ExitCode: 0, Stdout: ssOutput(80)}

	err := a.ValidateReachability(context.Background(), mock)
	if err == nil {
		t.Fatalf("expected error when port 2222 not listening")
	}
	if !strings.Contains(err.Error(), "2222") {
		t.Errorf("error should mention the port: %v", err)
	}
}

// PR26.3 Path A: the user-facing error must explicitly identify the
// scope as control-plane, not "panel survival" or "full panel". This
// keeps operators from mistakenly believing the assertion has
// validated the full DirectAdmin port surface.
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
	// Negative: the message must NOT make affirmative claims of full
	// survival or full surface validation. We allow the explanatory
	// negation form ("full DirectAdmin port surface validated in
	// PR26.4") because it reads as scope clarification, not a claim
	// the assertion has validated those ports.
	for _, forbidden := range []string{
		"full panel survival validated",
		"full panel survived",
		"all DirectAdmin ports validated",
		"all DirectAdmin ports listening",
		"all panel ports listening",
		"all panel ports validated",
	} {
		if strings.Contains(msg, forbidden) {
			t.Errorf("error must NOT claim %q (overstates scope); got %q", forbidden, msg)
		}
	}
}

// Defensive: ":22222" must not match expected ":2222".
func TestValidateReachability_PortPrefixCollision(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	mock.RunResults["ss:-lnt"] = executor.Result{ExitCode: 0, Stdout: ssOutput(22222)}
	if err := a.ValidateReachability(context.Background(), mock); err == nil {
		t.Errorf("expected error — :22222 must not collide with :2222")
	}
}

// ss exit-code non-zero → treated as not-reachable. Adapter does not
// invent reachability when the source of truth is unavailable.
func TestValidateReachability_SsErrorsOut_NotListening(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	mock.RunResults["ss:-lnt"] = executor.Result{ExitCode: 1, Stdout: "", Stderr: "ss: command not found"}
	if err := a.ValidateReachability(context.Background(), mock); err == nil {
		t.Errorf("expected error when ss fails — must NOT silently report reachable")
	}
}

// Config-override port flows through to ValidateReachability.
func TestValidateReachability_OverridePortHonored(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	mock.Files[configPath] = []byte("port=2225\n")
	mock.RunResults["ss:-lnt"] = executor.Result{ExitCode: 0, Stdout: ssOutput(2225)}
	if err := a.ValidateReachability(context.Background(), mock); err != nil {
		t.Errorf("expected nil for overridden port 2225; got %v", err)
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
	if string(a.ID()) != "directadmin" {
		t.Errorf("string ID drift: %q", string(a.ID()))
	}
}

// ----------------------------------------------------------------------------
// Framework integration: registered adapter detected → policy fires
// ----------------------------------------------------------------------------

// stubCanonicalDA installs a stub loader returning the canonical DA
// conf.d port surface, so framework-integration tests are deterministic
// regardless of whether /etc/nftban/conf.d/... exists on the build host.
func stubCanonicalDA(t *testing.T) {
	withStubLoader(t, func(configDir, panelName string) (*ports.PanelConfig, error) {
		return &ports.PanelConfig{
			Name:    "directadmin",
			Enabled: true,
			TCPIn:   canonicalDA.tcpIn,
			UDPIn:   canonicalDA.udpIn,
		}, nil
	})
}

func TestFrameworkIntegration_DA_Detected_Reachable_Passes(t *testing.T) {
	stubCanonicalDA(t)

	a := New()
	mock := executor.NewMockExecutor()
	seedDirectAdmin(mock, 2222)

	res := panelfw.EvaluateAdapters(context.Background(), mock, newTestLogger(),
		[]panelfw.PanelAdapter{a}, panelfw.DefaultPolicy())

	if res.Fatal {
		t.Fatalf("expected Fatal=false on healthy DA host; got %#v", res)
	}
	if string(res.Detection.ID) != "directadmin" {
		t.Errorf("expected detection ID=directadmin; got %q", res.Detection.ID)
	}
	if !res.PortsApplied || !res.ReachableAfter {
		t.Errorf("expected PortsApplied+ReachableAfter true; got %#v", res)
	}
	// PR26.4: framework PanelResult must carry the full conf.d
	// port surface, not just the control plane.
	if !equalIntSlices(res.PortsTCP, canonicalDA.tcpIn) {
		t.Errorf("PortsTCP must equal canonical DA TCP_IN; got %v", res.PortsTCP)
	}
	if !equalIntSlices(res.PortsUDP, canonicalDA.udpIn) {
		t.Errorf("PortsUDP must equal canonical DA UDP_IN; got %v", res.PortsUDP)
	}
}

func TestFrameworkIntegration_DA_Detected_NotReachable_Blocks(t *testing.T) {
	stubCanonicalDA(t)

	a := New()
	mock := executor.NewMockExecutor()
	// Install dir + binary + service active, but port NOT listening.
	mock.Dirs[installDir] = true
	mock.Files[binaryPath] = []byte("ELF")
	mock.Services[systemdUnit] = true
	mock.RunResults["ss:-lnt"] = executor.Result{ExitCode: 0, Stdout: ssOutput(80)}

	res := panelfw.EvaluateAdapters(context.Background(), mock, newTestLogger(),
		[]panelfw.PanelAdapter{a}, panelfw.DefaultPolicy())

	if !res.Fatal {
		t.Fatalf("expected Fatal=true when DA detected but unreachable; got %#v", res)
	}
	if !strings.Contains(res.Reason, "directadmin") {
		t.Errorf("Reason should mention directadmin: %q", res.Reason)
	}
	// PR26.3 Path A: the surfaced Reason must say control-plane.
	if !strings.Contains(res.Reason, "control-plane") {
		t.Errorf("Reason must say 'control-plane'; got %q", res.Reason)
	}
}

// PR26.3 Path A: the surfaced Reason on a failing DA host must NOT
// claim that the full panel survival was checked — the assertion
// covers only the control plane in PR26.3. Full port-surface
// validation lands in PR26.4.
func TestFrameworkIntegration_DA_Reason_DoesNotImplyFullPortSurvival(t *testing.T) {
	stubCanonicalDA(t)

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
	// These phrases would imply the assertion validated more than the
	// control plane. The error MAY mention "full ... port surface" in
	// a NEGATION (e.g., "...full DirectAdmin port surface validated in
	// PR26.4"), so we look for affirmative-claim verbs instead.
	for _, forbidden := range []string{
		"full panel survival validated",
		"full panel survived",
		"all DirectAdmin ports validated",
		"all DirectAdmin ports listening",
		"all panel ports listening",
		"all panel ports validated",
	} {
		if strings.Contains(res.Reason, forbidden) {
			t.Errorf("Reason must NOT claim %q (overstates PR26.3 scope); got %q", forbidden, res.Reason)
		}
	}
}

func TestFrameworkIntegration_DA_Absent_Passes(t *testing.T) {
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

// OperatorDisabled (--no-panel) flips a failing DA host to non-fatal.
func TestFrameworkIntegration_DA_NotReachable_OperatorDisabled_Passes(t *testing.T) {
	stubCanonicalDA(t)

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
// init() registration: the package adds itself to the global registry
// ----------------------------------------------------------------------------

func TestInitRegistration_AdapterPresent(t *testing.T) {
	// The init() runs at package import; the test merely confirms
	// the registry contains a DirectAdmin adapter.
	got := panelfw.RegisteredAdapters()
	var found bool
	for _, a := range got {
		if a.ID() == adapterID {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("DirectAdmin adapter not registered via init(); registry=%v", got)
	}
}

// ----------------------------------------------------------------------------
// Read-only discipline — adapter does not write files or run mutation cmds
// ----------------------------------------------------------------------------

func TestReadOnly_NoWrites_NoMutationCommands(t *testing.T) {
	stubCanonicalDA(t)

	a := New()
	mock := executor.NewMockExecutor()
	seedDirectAdmin(mock, 2222)

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
			// `is-active` only — ServiceActive is read-only on the mock
		default:
			t.Errorf("unexpected command %q (mutation suspected)", c.Name)
		}
	}
}
