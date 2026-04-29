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
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/panelfw"
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

func TestRequiredPorts_Default(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	tcp, udp, err := a.RequiredPorts(context.Background(), mock)
	if err != nil {
		t.Fatalf("RequiredPorts must not error on default-port path: %v", err)
	}
	if len(tcp) != 1 || tcp[0] != 2222 {
		t.Errorf("expected default TCP=[2222]; got %v", tcp)
	}
	if len(udp) != 0 {
		t.Errorf("expected UDP=[]; got %v", udp)
	}
}

func TestRequiredPorts_ConfigOverride(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	mock.Files[configPath] = []byte("# header\nport=2225\nfoo=bar\n")
	tcp, _, err := a.RequiredPorts(context.Background(), mock)
	if err != nil {
		t.Fatalf("config-override path must not error: %v", err)
	}
	if len(tcp) != 1 || tcp[0] != 2225 {
		t.Errorf("expected TCP=[2225] from config override; got %v", tcp)
	}
}

// Malformed override falls back to default (no error — read-only tolerance).
func TestRequiredPorts_MalformedConfig_FallsBackToDefault(t *testing.T) {
	cases := []struct {
		name, conf string
	}{
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
			tcp, _, err := a.RequiredPorts(context.Background(), mock)
			if err != nil {
				t.Fatalf("malformed-config path must not error: %v", err)
			}
			if tcp[0] != defaultPort {
				t.Errorf("expected fallback to default port %d; got %v", defaultPort, tcp)
			}
		})
	}
}

// Inline-comment tolerance: `port=2222 # comment` parses as 2222.
func TestRequiredPorts_ConfigInlineComment(t *testing.T) {
	a := New()
	mock := executor.NewMockExecutor()
	mock.Files[configPath] = []byte("port=2225 # operator override\n")
	tcp, _, err := a.RequiredPorts(context.Background(), mock)
	if err != nil {
		t.Fatalf("inline-comment path must not error: %v", err)
	}
	if tcp[0] != 2225 {
		t.Errorf("expected port=2225 with inline comment; got %v", tcp)
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

func TestFrameworkIntegration_DA_Detected_Reachable_Passes(t *testing.T) {
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
}

func TestFrameworkIntegration_DA_Detected_NotReachable_Blocks(t *testing.T) {
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
