// =============================================================================
// NFTBan v1.73 - Installer Distro Detection Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-detect-distro-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Tests for OS distribution detection and nftables path"
// meta:inventory.files="internal/installer/detect/distro_test.go"
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
)

func TestDetectDistro_AlmaLinux(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Files["/etc/os-release"] = []byte(`NAME="AlmaLinux"
VERSION="9.7 (Moss Jungle Cat)"
ID="almalinux"
VERSION_ID="9.7"
PRETTY_NAME="AlmaLinux 9.7 (Moss Jungle Cat)"
`)
	mock.Files["/etc/sysconfig/nftables.conf"] = []byte("# nftables\n")

	info, err := DetectDistro(mock, newTestLogger())
	if err != nil {
		t.Fatalf("DetectDistro: %v", err)
	}
	if info.ID != "almalinux" {
		t.Errorf("ID = %s, want almalinux", info.ID)
	}
	if info.VersionID != "9.7" {
		t.Errorf("VersionID = %s, want 9.7", info.VersionID)
	}
	if info.NftConfPath != "/etc/sysconfig/nftables.conf" {
		t.Errorf("NftConfPath = %s, want /etc/sysconfig/nftables.conf", info.NftConfPath)
	}
}

func TestDetectDistro_Ubuntu(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Files["/etc/os-release"] = []byte(`NAME="Ubuntu"
VERSION="24.04 LTS (Noble Numbat)"
ID=ubuntu
VERSION_ID="24.04"
PRETTY_NAME="Ubuntu 24.04 LTS"
`)

	info, err := DetectDistro(mock, newTestLogger())
	if err != nil {
		t.Fatalf("DetectDistro: %v", err)
	}
	if info.ID != "ubuntu" {
		t.Errorf("ID = %s, want ubuntu", info.ID)
	}
	if info.NftConfPath != "/etc/nftables.conf" {
		t.Errorf("NftConfPath = %s, want /etc/nftables.conf", info.NftConfPath)
	}
}

func TestDetectDistro_RockyFallbackPath(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Files["/etc/os-release"] = []byte(`ID="rocky"
VERSION_ID="10.1"
PRETTY_NAME="Rocky Linux 10.1"
`)
	// /etc/sysconfig/nftables.conf does NOT exist → fallback

	info, err := DetectDistro(mock, newTestLogger())
	if err != nil {
		t.Fatalf("DetectDistro: %v", err)
	}
	if info.ID != "rocky" {
		t.Errorf("ID = %s, want rocky", info.ID)
	}
	if info.NftConfPath != "/etc/nftables.conf" {
		t.Errorf("NftConfPath = %s, want /etc/nftables.conf (fallback)", info.NftConfPath)
	}
}

func TestDetectDistro_Normalize(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"centos-stream", "centos"},
		{"centos", "centos"},
		{"rhel", "rhel"},
		{"redhat", "rhel"},
		{"alma", "almalinux"},
		{"almalinux", "almalinux"},
		{"rocky", "rocky"},
		{"debian", "debian"},
		{"ubuntu", "ubuntu"},
		{"fedora", "fedora"},
		{"unknown-distro", "unknown-distro"},
	}
	for _, tt := range tests {
		if got := normalizeDistroID(tt.input); got != tt.want {
			t.Errorf("normalizeDistroID(%q) = %q, want %q", tt.input, got, tt.want)
		}
	}
}

func TestDetectDistro_Missing(t *testing.T) {
	mock := executor.NewMockExecutor()
	_, err := DetectDistro(mock, newTestLogger())
	if err == nil {
		t.Fatal("expected error when /etc/os-release is missing")
	}
}
