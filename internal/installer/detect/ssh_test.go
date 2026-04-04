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
