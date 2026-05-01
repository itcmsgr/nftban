// =============================================================================
// NFTBan - Tests for version parsing
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="version_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Tests for version parsing"
// meta:input="None"
// meta:output="None"
// meta:depends="testing"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package version

import (
	"strings"
	"testing"
)

// =============================================================================
// parseVersion tests
// =============================================================================

func TestParseVersion(t *testing.T) {
	tests := []struct {
		name    string
		version string
		want    []int
	}{
		{"semver", "1.25.0", []int{1, 25, 0}},
		{"with v prefix", "v1.25.0", []int{1, 25, 0}},
		{"two parts", "1.25", []int{1, 25}},
		{"one part", "1", []int{1}},
		{"dev", "dev", nil},
		{"empty", "", nil},
		{"partial invalid", "1.25.abc", []int{1, 25}},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Save and restore original Version
			orig := Version
			defer func() { Version = orig }()
			Version = tt.version

			got := parseVersion()
			if len(got) != len(tt.want) {
				t.Fatalf("parseVersion() = %v (len=%d), want %v (len=%d)",
					got, len(got), tt.want, len(tt.want))
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Errorf("parseVersion()[%d] = %d, want %d", i, got[i], tt.want[i])
				}
			}
		})
	}
}

// =============================================================================
// Major/Minor/Patch tests
// =============================================================================

func TestMajor(t *testing.T) {
	orig := Version
	defer func() { Version = orig }()

	Version = "1.25.3"
	if got := Major(); got != 1 {
		t.Errorf("Major() = %d, want 1", got)
	}

	Version = "dev"
	if got := Major(); got != 0 {
		t.Errorf("Major() = %d, want 0 for dev", got)
	}
}

func TestMinor(t *testing.T) {
	orig := Version
	defer func() { Version = orig }()

	Version = "1.25.3"
	if got := Minor(); got != 25 {
		t.Errorf("Minor() = %d, want 25", got)
	}

	Version = "1"
	if got := Minor(); got != 0 {
		t.Errorf("Minor() = %d, want 0 for single-part version", got)
	}
}

func TestPatch(t *testing.T) {
	orig := Version
	defer func() { Version = orig }()

	Version = "1.25.3"
	if got := Patch(); got != 3 {
		t.Errorf("Patch() = %d, want 3", got)
	}

	Version = "1.25"
	if got := Patch(); got != 0 {
		t.Errorf("Patch() = %d, want 0 for two-part version", got)
	}
}

// =============================================================================
// FullVersion tests
// =============================================================================

func TestFullVersion(t *testing.T) {
	orig := Version
	defer func() { Version = orig }()

	Version = "1.25.0"
	if got := FullVersion(); got != "v1.25.0" {
		t.Errorf("FullVersion() = %q, want %q", got, "v1.25.0")
	}

	Version = "dev"
	if got := FullVersion(); got != "vdev" {
		t.Errorf("FullVersion() = %q, want %q", got, "vdev")
	}
}

// =============================================================================
// Banner tests
// =============================================================================

func TestBanner(t *testing.T) {
	orig := Version
	defer func() { Version = orig }()
	Version = "1.25.0"

	tests := []struct {
		name      string
		component string
		want      string
	}{
		{"no component", "", "NFTBan v1.25.0"},
		{"with component", "Core Engine", "NFTBan v1.25.0 - Core Engine"},
		{"daemon component", "Daemon", "NFTBan v1.25.0 - Daemon"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := Banner(tt.component); got != tt.want {
				t.Errorf("Banner(%q) = %q, want %q", tt.component, got, tt.want)
			}
		})
	}
}

func TestBannerWithEmoji(t *testing.T) {
	orig := Version
	defer func() { Version = orig }()
	Version = "1.25.0"

	got := BannerWithEmoji("🛡️", "Firewall")
	if !strings.Contains(got, "NFTBan v1.25.0") {
		t.Errorf("BannerWithEmoji missing version: %q", got)
	}
	if !strings.Contains(got, "Firewall") {
		t.Errorf("BannerWithEmoji missing component: %q", got)
	}
}

// =============================================================================
// Constants tests
// =============================================================================

func TestConstants(t *testing.T) {
	if ProductName != "NFTBan" {
		t.Errorf("ProductName = %q, want %q", ProductName, "NFTBan")
	}
	if CoreEngineName != "nftban-core" {
		t.Errorf("CoreEngineName = %q, want %q", CoreEngineName, "nftban-core")
	}
	if SchemaVersion == "" {
		t.Error("SchemaVersion should not be empty")
	}
	if ConfigVersion == "" {
		t.Error("ConfigVersion should not be empty")
	}
}

// =============================================================================
// Build-metadata tests (PR v1.100.4 H1.1)
// =============================================================================
//
// GitCommit / BuildDate are package-level vars meant to be overridden
// at link time via -ldflags '-X github.com/itcmsgr/nftban/pkg/version.GitCommit=...'.
// When the binary is built without injection (go test, plain go build,
// developer workstation), the defaults must be the agreed sentinel
// strings so release/audit tooling can detect uninjected builds.

func TestBuildMetadata_Defaults(t *testing.T) {
	// Save + restore around any test that mutates these.
	origCommit, origDate := GitCommit, BuildDate
	defer func() { GitCommit, BuildDate = origCommit, origDate }()

	if GitCommit != "dev" {
		t.Errorf("GitCommit default = %q, want %q (release tooling treats this as 'uninjected build')",
			GitCommit, "dev")
	}
	if BuildDate != "unknown" {
		t.Errorf("BuildDate default = %q, want %q (release tooling treats this as 'uninjected build')",
			BuildDate, "unknown")
	}
}

func TestCommit_BuildTimestamp_Accessors(t *testing.T) {
	origCommit, origDate := GitCommit, BuildDate
	defer func() { GitCommit, BuildDate = origCommit, origDate }()

	GitCommit = "abc1234"
	BuildDate = "2026-05-01T08:30:00Z"

	if got := Commit(); got != "abc1234" {
		t.Errorf("Commit() = %q, want %q", got, "abc1234")
	}
	if got := BuildTimestamp(); got != "2026-05-01T08:30:00Z" {
		t.Errorf("BuildTimestamp() = %q, want %q", got, "2026-05-01T08:30:00Z")
	}
}

func TestLine_FormatStable(t *testing.T) {
	origVersion, origCommit, origDate := Version, GitCommit, BuildDate
	defer func() {
		Version, GitCommit, BuildDate = origVersion, origCommit, origDate
	}()

	Version = "1.100.4-dev"
	GitCommit = "abc1234"
	BuildDate = "2026-05-01T08:30:00Z"

	cases := []struct {
		name      string
		component string
		want      string
	}{
		{
			name:      "named component",
			component: "nftband",
			want:      "nftband v1.100.4-dev (git abc1234, build 2026-05-01T08:30:00Z)",
		},
		{
			name:      "another named component",
			component: "nftban-core",
			want:      "nftban-core v1.100.4-dev (git abc1234, build 2026-05-01T08:30:00Z)",
		},
		{
			name:      "empty component falls back to ProductName",
			component: "",
			want:      "NFTBan v1.100.4-dev (git abc1234, build 2026-05-01T08:30:00Z)",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := Line(tc.component); got != tc.want {
				t.Errorf("Line(%q) = %q\n  want %q", tc.component, got, tc.want)
			}
		})
	}
}

// Uninjected-build path: Line() must still return a stable shape
// (with sentinel "dev"/"unknown") rather than panic or print garbage.
// Release tooling and operators rely on the leading-component-token
// shape so they can distinguish "build with no metadata" from a
// genuine version line.
func TestLine_UninjectedBuild_StableShape(t *testing.T) {
	origVersion, origCommit, origDate := Version, GitCommit, BuildDate
	defer func() {
		Version, GitCommit, BuildDate = origVersion, origCommit, origDate
	}()

	Version = "dev"
	GitCommit = "dev"
	BuildDate = "unknown"

	got := Line("nftban-core")
	want := "nftban-core vdev (git dev, build unknown)"
	if got != want {
		t.Errorf("Line on uninjected build:\n  got  %q\n  want %q", got, want)
	}
	if !strings.HasPrefix(got, "nftban-core ") {
		t.Errorf("Line must always start with the component name; got %q", got)
	}
	if !strings.Contains(got, "(git ") {
		t.Errorf("Line must always contain `(git ` segment; got %q", got)
	}
}
