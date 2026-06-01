// =============================================================================
// NFTBan v1.73 - Installer SSH Port Detection Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-detect-ssh-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Tests for 4-source SSH port detection chain"
// meta:inventory.files="internal/installer/detect/ssh_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package detect

import (
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

func newTestLogger() *logging.Logger {
	return logging.New("/dev/null", false)
}

func TestSSHPort_FromListener(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.RunResults["ss:-tlnp"] = executor.Result{
		ExitCode: 0,
		Stdout: `State  Recv-Q  Send-Q  Local Address:Port   Peer Address:Port  Process
LISTEN 0       128     0.0.0.0:55000         0.0.0.0:*          users:(("sshd",pid=1234,fd=3))
LISTEN 0       128     [::]:55000            [::]:*             users:(("sshd",pid=1234,fd=4))
`,
	}

	port, err := SSHPort(mock, newTestLogger())
	if err != nil {
		t.Fatalf("SSHPort: %v", err)
	}
	if port != 55000 {
		t.Errorf("port = %d, want 55000", port)
	}
}

func TestSSHPort_FromConfig(t *testing.T) {
	mock := executor.NewMockExecutor()
	// ss returns nothing useful
	mock.RunResults["ss:-tlnp"] = executor.Result{ExitCode: 0, Stdout: ""}
	// ls returns no drop-in files
	mock.RunResults["ls:/etc/ssh/sshd_config.d/"] = executor.Result{ExitCode: 1}
	// sshd_config has Port directive
	mock.Files["/etc/ssh/sshd_config"] = []byte("# SSH config\nPort 2222\n")

	port, err := SSHPort(mock, newTestLogger())
	if err != nil {
		t.Fatalf("SSHPort: %v", err)
	}
	if port != 2222 {
		t.Errorf("port = %d, want 2222", port)
	}
}

func TestSSHPort_FromDropIn(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.RunResults["ss:-tlnp"] = executor.Result{ExitCode: 0, Stdout: ""}
	// Main config has no Port
	mock.Files["/etc/ssh/sshd_config"] = []byte("# Default SSH config\n")
	// Drop-in dir has a config
	mock.RunResults["ls:/etc/ssh/sshd_config.d/"] = executor.Result{
		ExitCode: 0, Stdout: "50-custom.conf\n",
	}
	mock.Files["/etc/ssh/sshd_config.d/50-custom.conf"] = []byte("Port 33333\n")

	port, err := SSHPort(mock, newTestLogger())
	if err != nil {
		t.Fatalf("SSHPort: %v", err)
	}
	if port != 33333 {
		t.Errorf("port = %d, want 33333", port)
	}
}

func TestSSHPort_FromStateFile(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.RunResults["ss:-tlnp"] = executor.Result{ExitCode: 0, Stdout: ""}
	mock.RunResults["ls:/etc/ssh/sshd_config.d/"] = executor.Result{ExitCode: 1}
	mock.Files["/var/lib/nftban/state/ssh_port_active.state"] = []byte("44444\n")

	port, err := SSHPort(mock, newTestLogger())
	if err != nil {
		t.Fatalf("SSHPort: %v", err)
	}
	if port != 44444 {
		t.Errorf("port = %d, want 44444", port)
	}
}

func TestSSHPort_FromConfLocal(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.RunResults["ss:-tlnp"] = executor.Result{ExitCode: 0, Stdout: ""}
	mock.RunResults["ls:/etc/ssh/sshd_config.d/"] = executor.Result{ExitCode: 1}
	mock.Files["/etc/nftban/nftban.conf.local"] = []byte("# Local overrides\nSSH_PORT=9999\n")

	port, err := SSHPort(mock, newTestLogger())
	if err != nil {
		t.Fatalf("SSHPort: %v", err)
	}
	if port != 9999 {
		t.Errorf("port = %d, want 9999", port)
	}
}

func TestSSHPort_NoSource(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.RunResults["ss:-tlnp"] = executor.Result{ExitCode: 0, Stdout: ""}
	mock.RunResults["ls:/etc/ssh/sshd_config.d/"] = executor.Result{ExitCode: 1}

	_, err := SSHPort(mock, newTestLogger())
	if err == nil {
		t.Fatal("expected error when no SSH port source available")
	}
}

func TestSSHPort_InvalidPort(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.RunResults["ss:-tlnp"] = executor.Result{ExitCode: 0, Stdout: ""}
	mock.RunResults["ls:/etc/ssh/sshd_config.d/"] = executor.Result{ExitCode: 1}
	// State file has invalid port
	mock.Files["/var/lib/nftban/state/ssh_port_active.state"] = []byte("99999\n") // > 65535

	// conf.local has valid port
	mock.Files["/etc/nftban/nftban.conf.local"] = []byte("SSH_PORT=22\n")

	port, err := SSHPort(mock, newTestLogger())
	if err != nil {
		t.Fatalf("SSHPort: %v", err)
	}
	if port != 22 {
		t.Errorf("port = %d, want 22 (should skip invalid 99999)", port)
	}
}

func TestValidatePort(t *testing.T) {
	tests := []struct {
		input string
		want  int
	}{
		{"22", 22},
		{"55000", 55000},
		{"65535", 65535},
		{"1", 1},
		{"0", 0},
		{"-1", 0},
		{"65536", 0},
		{"abc", 0},
		{"", 0},
	}
	for _, tt := range tests {
		if got := validatePort(tt.input); got != tt.want {
			t.Errorf("validatePort(%q) = %d, want %d", tt.input, got, tt.want)
		}
	}
}

// =============================================================================
// v1.125 R-1: SSH multi-port detection + render
// =============================================================================
// Tests for the multi-port-aware detection path that closes the dns2-class
// lockout vector where a host's sshd listens on multiple ports (e.g.,
// internal :22 + external :55000) and the pre-v1.125 detector returned only
// the first listener. The new DetectSSHPorts returns all listeners + a
// SSH_CLIENT-aware primary; the new RenderNftablesConfMultiPort renders the
// full allow-set so operators connecting on any listener port survive a
// firewall reload.
//
// Scope per AUDIT_190_LIFECYCLE/V125_INSTALL_ROBUSTNESS_SCOPE.md §3.1 R-1:
//   - single-port listener (backward compat — no behavior change)
//   - multi-port listener :22 + :55000 (dns2-class)
//   - SSH_CLIENT primary-port preference
//   - render-side: tcp_ports_in carries all ports
//   - legacy single-port SSH_PORT path still works
// =============================================================================

func TestDetectSSHPorts_SinglePort_BackwardCompat(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.RunResults["ss:-tlnp"] = executor.Result{
		ExitCode: 0,
		Stdout: `State  Recv-Q  Send-Q  Local Address:Port   Peer Address:Port  Process
LISTEN 0       128     0.0.0.0:22            0.0.0.0:*          users:(("sshd",pid=1234,fd=3))
LISTEN 0       128     [::]:22               [::]:*             users:(("sshd",pid=1234,fd=4))
`,
	}

	ports, primary, err := DetectSSHPorts(mock, newTestLogger())
	if err != nil {
		t.Fatalf("DetectSSHPorts: %v", err)
	}
	if len(ports) != 1 {
		t.Errorf("len(ports) = %d, want 1 (deduped IPv4+IPv6 of :22)", len(ports))
	}
	if primary != 22 {
		t.Errorf("primary = %d, want 22", primary)
	}
	if ports[0] != 22 {
		t.Errorf("ports[0] = %d, want 22", ports[0])
	}
}

func TestDetectSSHPorts_MultiPort_Dns2Class(t *testing.T) {
	// Reproduces the dns2 host topology: sshd listens on both :22 (internal)
	// and :55000 (external/operator port). Pre-v1.125 detector returned :22
	// only; v1.125 R-1 returns both.
	mock := executor.NewMockExecutor()
	mock.RunResults["ss:-tlnp"] = executor.Result{
		ExitCode: 0,
		Stdout: `State  Recv-Q  Send-Q  Local Address:Port   Peer Address:Port  Process
LISTEN 0       128     0.0.0.0:22            0.0.0.0:*          users:(("sshd",pid=1234,fd=3))
LISTEN 0       128     [::]:22               [::]:*             users:(("sshd",pid=1234,fd=4))
LISTEN 0       128     0.0.0.0:55000         0.0.0.0:*          users:(("sshd",pid=1234,fd=5))
LISTEN 0       128     [::]:55000            [::]:*             users:(("sshd",pid=1234,fd=6))
`,
	}

	// No SSH_CLIENT in test env (this test asserts the no-preference fallback).
	// Subsequent test exercises the SSH_CLIENT-aware primary selection.
	t.Setenv("SSH_CLIENT", "")

	ports, primary, err := DetectSSHPorts(mock, newTestLogger())
	if err != nil {
		t.Fatalf("DetectSSHPorts: %v", err)
	}
	if len(ports) != 2 {
		t.Fatalf("len(ports) = %d, want 2 (deduped :22 + :55000); ports=%v", len(ports), ports)
	}
	// Order = first-occurrence in `ss` output. :22 appears before :55000.
	if ports[0] != 22 || ports[1] != 55000 {
		t.Errorf("ports = %v, want [22, 55000]", ports)
	}
	// Without SSH_CLIENT, primary defaults to the first detected listener.
	if primary != 22 {
		t.Errorf("primary = %d, want 22 (no SSH_CLIENT → first listener)", primary)
	}
}

func TestDetectSSHPorts_SSHClient_PrimaryPreference(t *testing.T) {
	// dns2 topology, but the operator is connected on :55000. The primary
	// MUST come back as :55000 so the rendered firewall and the operator's
	// session port stay aligned.
	//
	// v1.125 R-1 contract (primary-first): the returned ports slice MUST
	// have the selected primary at index 0. RenderNftablesConfMultiPort
	// reads sshPorts[0] for the __SSH_PORT__ template substitution (the
	// per-IP SSH rate-limit rule). Without primary-first ordering, the
	// rate-limit rule would apply to the wrong port on multi-port hosts
	// (regression discovered in v1.125 R-1 code review — bundle reviewer
	// noted "selected primary is not first in sshPorts" as merge-blocker).
	mock := executor.NewMockExecutor()
	mock.RunResults["ss:-tlnp"] = executor.Result{
		ExitCode: 0,
		Stdout: `State  Recv-Q  Send-Q  Local Address:Port   Peer Address:Port  Process
LISTEN 0       128     0.0.0.0:22            0.0.0.0:*          users:(("sshd",pid=1234,fd=3))
LISTEN 0       128     0.0.0.0:55000         0.0.0.0:*          users:(("sshd",pid=1234,fd=5))
`,
	}
	// SSH_CLIENT format: "<peer-ip> <peer-port> <local-port>"
	// 62.38.150.122 is the dns2 operator peer; the third field 55000 is the
	// destination port on this host (the port the operator's session is on).
	t.Setenv("SSH_CLIENT", "62.38.150.122 51234 55000")

	ports, primary, err := DetectSSHPorts(mock, newTestLogger())
	if err != nil {
		t.Fatalf("DetectSSHPorts: %v", err)
	}
	if len(ports) != 2 {
		t.Fatalf("len(ports) = %d, want 2", len(ports))
	}
	if primary != 55000 {
		t.Errorf("primary = %d, want 55000 (SSH_CLIENT destination port preferred)", primary)
	}
	// v1.125 R-1 primary-first contract: primary (55000) MUST be at index 0;
	// the additional listener (22, detected first in `ss -tlnp`) goes to
	// index 1.
	if ports[0] != 55000 || ports[1] != 22 {
		t.Errorf("ports = %v, want [55000, 22] (primary-first ordering per v1.125 R-1 contract)", ports)
	}
}

// TestDetectSSHPorts_PrimaryFirst_NoSSHClient_PreservesDetectionOrder asserts
// that primaryFirstPorts is a no-op when the selected primary is already at
// index 0 (the common single-port case + the multi-port-no-SSH_CLIENT case).
// The reorder must only fire when SSH_CLIENT selects a non-first port.
func TestDetectSSHPorts_PrimaryFirst_NoSSHClient_PreservesDetectionOrder(t *testing.T) {
	t.Setenv("SSH_CLIENT", "")
	mock := executor.NewMockExecutor()
	mock.RunResults["ss:-tlnp"] = executor.Result{
		ExitCode: 0,
		Stdout: `LISTEN 0 128 0.0.0.0:22    0.0.0.0:* users:(("sshd",pid=1,fd=3))
LISTEN 0 128 0.0.0.0:55000 0.0.0.0:* users:(("sshd",pid=1,fd=4))
`,
	}
	ports, primary, err := DetectSSHPorts(mock, newTestLogger())
	if err != nil {
		t.Fatalf("DetectSSHPorts: %v", err)
	}
	// Without SSH_CLIENT, primary defaults to the first detected listener
	// (22). primaryFirstPorts no-ops because primary == ports[0]. Detection
	// order preserved.
	if primary != 22 {
		t.Errorf("primary = %d, want 22 (no SSH_CLIENT → first listener)", primary)
	}
	if ports[0] != 22 || ports[1] != 55000 {
		t.Errorf("ports = %v, want [22, 55000] (detection order preserved when SSH_CLIENT absent)", ports)
	}
}

// TestPrimaryFirstPorts directly exercises the reorder helper across the
// edge cases that DetectSSHPorts depends on. Without this guard, a future
// refactor could silently break the primary-first contract that
// RenderNftablesConfMultiPort relies on.
func TestPrimaryFirstPorts(t *testing.T) {
	tests := []struct {
		name    string
		ports   []int
		primary int
		want    []int
	}{
		{"empty in", []int{}, 22, []int{}},
		{"primary=0 (no selection)", []int{22, 55000}, 0, []int{22, 55000}},
		{"primary already first", []int{22, 55000}, 22, []int{22, 55000}},
		{"primary at index 1 → moved to 0", []int{22, 55000}, 55000, []int{55000, 22}},
		{"primary at index 2 of 3 → moved to 0", []int{22, 2222, 55000}, 55000, []int{55000, 22, 2222}},
		{"primary not in list (defensive)", []int{22, 55000}, 9999, []int{9999, 22, 55000}},
		{"single port already first", []int{22}, 22, []int{22}},
		{"single port + different primary (defensive)", []int{22}, 55000, []int{55000, 22}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := primaryFirstPorts(tt.ports, tt.primary)
			if len(got) != len(tt.want) {
				t.Fatalf("len(got) = %d, want %d (got=%v want=%v)", len(got), len(tt.want), got, tt.want)
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Errorf("got[%d] = %d, want %d (got=%v want=%v)", i, got[i], tt.want[i], got, tt.want)
				}
			}
		})
	}
}

func TestDetectSSHPorts_SSHClient_NotInListenerList(t *testing.T) {
	// SSH_CLIENT destination port doesn't match any detected listener
	// (e.g., session came through a NAT/forward that doesn't map to a
	// local sshd). Primary falls back to the first detected listener.
	mock := executor.NewMockExecutor()
	mock.RunResults["ss:-tlnp"] = executor.Result{
		ExitCode: 0,
		Stdout: `State  Recv-Q  Send-Q  Local Address:Port   Peer Address:Port  Process
LISTEN 0       128     0.0.0.0:22            0.0.0.0:*          users:(("sshd",pid=1234,fd=3))
`,
	}
	t.Setenv("SSH_CLIENT", "10.0.0.1 51234 9999") // 9999 not in listener list

	_, primary, err := DetectSSHPorts(mock, newTestLogger())
	if err != nil {
		t.Fatalf("DetectSSHPorts: %v", err)
	}
	if primary != 22 {
		t.Errorf("primary = %d, want 22 (SSH_CLIENT port 9999 not in listener list → fallback to first listener)", primary)
	}
}

func TestSSHClientLocalPort(t *testing.T) {
	tests := []struct {
		name   string
		envVal string
		want   int
	}{
		{"unset", "", 0},
		{"valid 3-field", "62.38.150.122 51234 55000", 55000},
		{"valid IPv6 peer", "2001:db8::1 51234 22", 22},
		{"port too high", "10.0.0.1 51234 99999", 0},
		{"port zero", "10.0.0.1 51234 0", 0},
		{"port negative", "10.0.0.1 51234 -1", 0},
		{"non-numeric port", "10.0.0.1 51234 abc", 0},
		{"too few fields", "10.0.0.1 51234", 0},
		{"empty fields", "  ", 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Setenv("SSH_CLIENT", tt.envVal)
			if got := sshClientLocalPort(); got != tt.want {
				t.Errorf("sshClientLocalPort() = %d, want %d (SSH_CLIENT=%q)", got, tt.want, tt.envVal)
			}
		})
	}
}

func TestSelectPrimarySSHPort(t *testing.T) {
	tests := []struct {
		name          string
		ports         []int
		sshClientPort int
		want          int
	}{
		{"empty", []int{}, 0, 0},
		{"single port no client", []int{22}, 0, 22},
		{"single port client matches", []int{22}, 22, 22},
		{"single port client mismatches → first", []int{22}, 55000, 22},
		{"multi-port no client → first", []int{22, 55000}, 0, 22},
		{"multi-port client matches second", []int{22, 55000}, 55000, 55000},
		{"multi-port client matches first", []int{22, 55000}, 22, 22},
		{"multi-port client not in list → first", []int{22, 55000}, 9999, 22},
		{"three ports client matches third", []int{22, 2222, 55000}, 55000, 55000},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := selectPrimarySSHPort(tt.ports, tt.sshClientPort); got != tt.want {
				t.Errorf("selectPrimarySSHPort(%v, %d) = %d, want %d", tt.ports, tt.sshClientPort, got, tt.want)
			}
		})
	}
}

func TestSSHAllListeners_Deduplication(t *testing.T) {
	// IPv4 + IPv6 binds on the same port should dedupe to a single entry.
	mock := executor.NewMockExecutor()
	mock.RunResults["ss:-tlnp"] = executor.Result{
		ExitCode: 0,
		Stdout: `LISTEN 0 128 0.0.0.0:22       0.0.0.0:*  users:(("sshd",pid=1,fd=3))
LISTEN 0 128 [::]:22          [::]:*     users:(("sshd",pid=1,fd=4))
LISTEN 0 128 0.0.0.0:22       0.0.0.0:*  users:(("sshd",pid=1,fd=5))
`,
	}
	ports := sshAllListeners(mock)
	if len(ports) != 1 || ports[0] != 22 {
		t.Errorf("sshAllListeners = %v, want [22]", ports)
	}
}

func TestSSHAllListeners_NoSSHDLines(t *testing.T) {
	// `ss -tlnp` returns lines but none mention sshd → no ports.
	mock := executor.NewMockExecutor()
	mock.RunResults["ss:-tlnp"] = executor.Result{
		ExitCode: 0,
		Stdout: `LISTEN 0 128 0.0.0.0:80 0.0.0.0:* users:(("nginx",pid=1,fd=3))
`,
	}
	ports := sshAllListeners(mock)
	if len(ports) != 0 {
		t.Errorf("sshAllListeners = %v, want empty", ports)
	}
}

// TestSSHPort_LegacySinglePortPathStillWorks ensures the v1.124-and-earlier
// SSHPort() entry point continues to return the primary port without error
// for all four source priorities (listener / sshd_config / state-file /
// conf.local). This is the back-compat invariant that protects every
// non-installer caller of detect.SSHPort.
func TestSSHPort_LegacySinglePortPathStillWorks(t *testing.T) {
	t.Setenv("SSH_CLIENT", "")
	// Source 1: ss listener
	mock1 := executor.NewMockExecutor()
	mock1.RunResults["ss:-tlnp"] = executor.Result{
		ExitCode: 0,
		Stdout:   `LISTEN 0 128 0.0.0.0:55000 0.0.0.0:* users:(("sshd",pid=1,fd=3))`,
	}
	if port, err := SSHPort(mock1, newTestLogger()); err != nil || port != 55000 {
		t.Errorf("SSHPort source=ss: port=%d err=%v, want 55000 nil", port, err)
	}

	// Source 2: sshd_config
	mock2 := executor.NewMockExecutor()
	mock2.RunResults["ss:-tlnp"] = executor.Result{ExitCode: 0, Stdout: ""}
	mock2.RunResults["ls:/etc/ssh/sshd_config.d/"] = executor.Result{ExitCode: 1}
	mock2.Files["/etc/ssh/sshd_config"] = []byte("Port 2222\n")
	if port, err := SSHPort(mock2, newTestLogger()); err != nil || port != 2222 {
		t.Errorf("SSHPort source=sshd_config: port=%d err=%v, want 2222 nil", port, err)
	}

	// Source 3: state file
	mock3 := executor.NewMockExecutor()
	mock3.RunResults["ss:-tlnp"] = executor.Result{ExitCode: 0, Stdout: ""}
	mock3.RunResults["ls:/etc/ssh/sshd_config.d/"] = executor.Result{ExitCode: 1}
	mock3.Files["/var/lib/nftban/state/ssh_port_active.state"] = []byte("33333\n")
	if port, err := SSHPort(mock3, newTestLogger()); err != nil || port != 33333 {
		t.Errorf("SSHPort source=state: port=%d err=%v, want 33333 nil", port, err)
	}

	// Source 4: conf.local
	mock4 := executor.NewMockExecutor()
	mock4.RunResults["ss:-tlnp"] = executor.Result{ExitCode: 0, Stdout: ""}
	mock4.RunResults["ls:/etc/ssh/sshd_config.d/"] = executor.Result{ExitCode: 1}
	mock4.Files["/etc/nftban/nftban.conf.local"] = []byte("SSH_PORT=44444\n")
	if port, err := SSHPort(mock4, newTestLogger()); err != nil || port != 44444 {
		t.Errorf("SSHPort source=conf.local: port=%d err=%v, want 44444 nil", port, err)
	}
}

// =============================================================================
// v1.145 PR-B — ListenAddress / AddressFamily parsing + conservative union
// =============================================================================

func TestListenAddressPort_Forms(t *testing.T) {
	cases := []struct {
		line string
		want int
	}{
		{"ListenAddress 0.0.0.0:22", 22},
		{"ListenAddress 192.0.2.10:55000", 55000},
		{"ListenAddress [::]:22", 22},
		{"ListenAddress [2001:db8::10]:55000", 55000},
		{"  ListenAddress 0.0.0.0:2222  ", 2222},
		{"listenaddress 10.0.0.1:443", 443}, // case-insensitive
		{"ListenAddress 0.0.0.0", 0},        // no port
		{"ListenAddress ::", 0},             // bare IPv6, no port
		{"ListenAddress 2001:db8::10", 0},   // bare IPv6, no port — the trap
		{"Port 22", 0},                      // not a ListenAddress line
		{"# ListenAddress 0.0.0.0:22", 0},   // comment
	}
	for _, c := range cases {
		if got := listenAddressPort(c.line); got != c.want {
			t.Errorf("listenAddressPort(%q) = %d, want %d", c.line, got, c.want)
		}
	}
}

func TestParseSSHConfig_ListenAddressFallback(t *testing.T) {
	mock := executor.NewMockExecutor()
	// Port directive wins even if a ListenAddress is also present.
	mock.Files["/etc/ssh/p"] = []byte("ListenAddress 0.0.0.0:2200\nPort 22\n")
	if got := parseSSHConfig(mock, "/etc/ssh/p"); got != 22 {
		t.Errorf("Port should win: got %d, want 22", got)
	}
	// ListenAddress-only config falls back to the ListenAddress port.
	mock.Files["/etc/ssh/la"] = []byte("# no Port line\nListenAddress [::]:55000\n")
	if got := parseSSHConfig(mock, "/etc/ssh/la"); got != 55000 {
		t.Errorf("ListenAddress fallback: got %d, want 55000", got)
	}
}

// equalInts compares two int slices for order-sensitive equality.
func equalInts(a, b []int) bool {
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

func TestDetectSSHPortsUnion(t *testing.T) {
	noDropins := executor.Result{ExitCode: 1}
	noListeners := executor.Result{ExitCode: 0, Stdout: ""}

	cases := []struct {
		name string
		ss   string // ss -tlnp stdout
		sshd string // /etc/ssh/sshd_config content
		want []int  // sorted unique union
	}{
		{
			name: "Port only single",
			sshd: "Port 22\n",
			want: []int{22},
		},
		{
			name: "Port only multi",
			sshd: "Port 22\nPort 55000\n",
			want: []int{22, 55000},
		},
		{
			name: "ListenAddress only IPv4",
			sshd: "ListenAddress 0.0.0.0:22\n",
			want: []int{22},
		},
		{
			name: "ListenAddress only IPv6",
			sshd: "ListenAddress [::]:55000\n",
			want: []int{55000},
		},
		{
			name: "mixed IPv4/IPv6 ListenAddress",
			sshd: "ListenAddress 0.0.0.0:22\nListenAddress [::]:55000\n",
			want: []int{22, 55000},
		},
		{
			name: "AddressFamily inet + Port",
			sshd: "AddressFamily inet\nPort 22\n",
			want: []int{22},
		},
		{
			name: "AddressFamily inet6 + ListenAddress",
			sshd: "AddressFamily inet6\nListenAddress [2001:db8::10]:55000\n",
			want: []int{55000},
		},
		{
			name: "bare IPv6 no port is not detected",
			sshd: "ListenAddress 2001:db8::10\n",
			want: nil,
		},
		{
			name: "union ss + config sorted unique",
			ss: `State Recv-Q Send-Q Local:Port Peer Process
LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))
`,
			sshd: "Port 55000\nListenAddress 0.0.0.0:22\n", // 22 duplicated across ss+config
			want: []int{22, 55000},
		},
		{
			name: "ss dual-stack",
			ss: `State Recv-Q Send-Q Local:Port Peer Process
LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))
LISTEN 0 128 [::]:55000 [::]:* users:(("sshd",pid=1,fd=4))
`,
			sshd: "",
			want: []int{22, 55000},
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			mock := executor.NewMockExecutor()
			if c.ss != "" {
				mock.RunResults["ss:-tlnp"] = executor.Result{ExitCode: 0, Stdout: c.ss}
			} else {
				mock.RunResults["ss:-tlnp"] = noListeners
			}
			mock.RunResults["ls:/etc/ssh/sshd_config.d/"] = noDropins
			mock.Files["/etc/ssh/sshd_config"] = []byte(c.sshd)

			got := DetectSSHPortsUnion(mock, newTestLogger())
			if !equalInts(got, c.want) {
				t.Errorf("DetectSSHPortsUnion() = %v, want %v", got, c.want)
			}
		})
	}
}
