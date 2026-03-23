// =============================================================================
// NFTBan v1.0 - Suricata Config Generator Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="generator_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Unit tests for mergeUnique, applyFilters, and config loading"
// meta:input="Test cases"
// meta:output="Test results"
// meta:depends="testing"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package config

import (
	"os"
	"path/filepath"
	"testing"
)

// =============================================================================
// mergeUnique Tests
// =============================================================================

func TestMergeUnique(t *testing.T) {
	tests := []struct {
		name     string
		a        []string
		b        []string
		wantLen  int
		wantAll  []string
	}{
		{
			name:    "no_overlap",
			a:       []string{"a", "b"},
			b:       []string{"c", "d"},
			wantLen: 4,
			wantAll: []string{"a", "b", "c", "d"},
		},
		{
			name:    "with_duplicates",
			a:       []string{"a", "b", "c"},
			b:       []string{"b", "c", "d"},
			wantLen: 4,
			wantAll: []string{"a", "b", "c", "d"},
		},
		{
			name:    "identical",
			a:       []string{"a", "b"},
			b:       []string{"a", "b"},
			wantLen: 2,
			wantAll: []string{"a", "b"},
		},
		{
			name:    "empty_a",
			a:       []string{},
			b:       []string{"a", "b"},
			wantLen: 2,
			wantAll: []string{"a", "b"},
		},
		{
			name:    "empty_b",
			a:       []string{"a", "b"},
			b:       []string{},
			wantLen: 2,
			wantAll: []string{"a", "b"},
		},
		{
			name:    "both_empty",
			a:       []string{},
			b:       []string{},
			wantLen: 0,
			wantAll: []string{},
		},
		{
			name:    "nil_a",
			a:       nil,
			b:       []string{"a"},
			wantLen: 1,
			wantAll: []string{"a"},
		},
		{
			name:    "nil_b",
			a:       []string{"a"},
			b:       nil,
			wantLen: 1,
			wantAll: []string{"a"},
		},
		{
			name:    "preserves_order",
			a:       []string{"c", "a"},
			b:       []string{"b", "d"},
			wantLen: 4,
			wantAll: []string{"c", "a", "b", "d"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := mergeUnique(tt.a, tt.b)
			if len(got) != tt.wantLen {
				t.Errorf("mergeUnique() len = %d, want %d; got %v", len(got), tt.wantLen, got)
				return
			}

			// Check all expected items are present
			gotSet := make(map[string]bool)
			for _, item := range got {
				gotSet[item] = true
			}
			for _, want := range tt.wantAll {
				if !gotSet[want] {
					t.Errorf("mergeUnique() missing expected item %q; got %v", want, got)
				}
			}

			// For order-sensitive test, check exact match
			if tt.name == "preserves_order" {
				for i, want := range tt.wantAll {
					if got[i] != want {
						t.Errorf("mergeUnique()[%d] = %q, want %q", i, got[i], want)
					}
				}
			}
		})
	}
}

// =============================================================================
// applyFilters Tests
// =============================================================================

func TestApplyFilters_WhitelistOnly(t *testing.T) {
	items := []string{"a", "b", "c", "d"}
	whitelist := []string{"a", "c"}
	blacklist := []string{}

	got := applyFilters(items, whitelist, blacklist)

	if len(got) != 2 {
		t.Fatalf("expected 2 items, got %d: %v", len(got), got)
	}

	gotSet := make(map[string]bool)
	for _, item := range got {
		gotSet[item] = true
	}
	if !gotSet["a"] || !gotSet["c"] {
		t.Errorf("expected a and c, got %v", got)
	}
}

func TestApplyFilters_BlacklistOnly(t *testing.T) {
	items := []string{"a", "b", "c", "d"}
	whitelist := []string{}
	blacklist := []string{"b", "d"}

	got := applyFilters(items, whitelist, blacklist)

	if len(got) != 2 {
		t.Fatalf("expected 2 items, got %d: %v", len(got), got)
	}

	gotSet := make(map[string]bool)
	for _, item := range got {
		gotSet[item] = true
	}
	if !gotSet["a"] || !gotSet["c"] {
		t.Errorf("expected a and c, got %v", got)
	}
}

func TestApplyFilters_WhitelistAndBlacklist(t *testing.T) {
	items := []string{"a", "b", "c", "d", "e"}
	whitelist := []string{"a", "b", "c"} // Only keep a, b, c
	blacklist := []string{"b"}            // Then remove b

	got := applyFilters(items, whitelist, blacklist)

	if len(got) != 2 {
		t.Fatalf("expected 2 items, got %d: %v", len(got), got)
	}

	gotSet := make(map[string]bool)
	for _, item := range got {
		gotSet[item] = true
	}
	if !gotSet["a"] || !gotSet["c"] {
		t.Errorf("expected a and c, got %v", got)
	}
}

func TestApplyFilters_NoFilters(t *testing.T) {
	items := []string{"a", "b", "c"}
	whitelist := []string{}
	blacklist := []string{}

	got := applyFilters(items, whitelist, blacklist)

	if len(got) != 3 {
		t.Fatalf("expected 3 items (unchanged), got %d: %v", len(got), got)
	}
}

func TestApplyFilters_EmptyItems(t *testing.T) {
	items := []string{}
	whitelist := []string{"a"}
	blacklist := []string{"b"}

	got := applyFilters(items, whitelist, blacklist)

	if len(got) != 0 {
		t.Fatalf("expected 0 items, got %d: %v", len(got), got)
	}
}

// =============================================================================
// LoadConfig (with temp files) Tests
// =============================================================================

func TestLoadConfig_NonexistentFile(t *testing.T) {
	cfg := LoadConfig("/nonexistent/path/config.conf")

	// Should return empty config (not crash)
	if len(cfg.EnabledCategories) != 0 {
		t.Errorf("expected 0 enabled categories, got %d", len(cfg.EnabledCategories))
	}
	if len(cfg.DisabledCategories) != 0 {
		t.Errorf("expected 0 disabled categories, got %d", len(cfg.DisabledCategories))
	}
}

func TestLoadConfig_ValidFile(t *testing.T) {
	tmpDir := t.TempDir()
	confFile := filepath.Join(tmpDir, "test.conf")

	content := `# Test config
ENABLE_CATEGORY=emerging-exploit
ENABLE_CATEGORY=emerging-malware
DISABLE_CATEGORY=emerging-policy
ENABLE_SID=2100001
DISABLE_SID=2200001
`

	if err := os.WriteFile(confFile, []byte(content), 0644); err != nil {
		t.Fatalf("failed to write temp file: %v", err)
	}

	cfg := LoadConfig(confFile)

	if len(cfg.EnabledCategories) != 2 {
		t.Errorf("expected 2 enabled categories, got %d", len(cfg.EnabledCategories))
	}
	if len(cfg.DisabledCategories) != 1 {
		t.Errorf("expected 1 disabled category, got %d", len(cfg.DisabledCategories))
	}
	if len(cfg.EnabledSIDs) != 1 {
		t.Errorf("expected 1 enabled SID, got %d", len(cfg.EnabledSIDs))
	}
	if len(cfg.DisabledSIDs) != 1 {
		t.Errorf("expected 1 disabled SID, got %d", len(cfg.DisabledSIDs))
	}
}

func TestLoadConfig_SkipsComments(t *testing.T) {
	tmpDir := t.TempDir()
	confFile := filepath.Join(tmpDir, "test.conf")

	content := `# This is a comment
# ENABLE_CATEGORY=should-not-be-loaded
ENABLE_CATEGORY=real-category
`

	if err := os.WriteFile(confFile, []byte(content), 0644); err != nil {
		t.Fatalf("failed to write temp file: %v", err)
	}

	cfg := LoadConfig(confFile)

	if len(cfg.EnabledCategories) != 1 {
		t.Errorf("expected 1 enabled category, got %d", len(cfg.EnabledCategories))
	}
	if cfg.EnabledCategories[0] != "real-category" {
		t.Errorf("expected %q, got %q", "real-category", cfg.EnabledCategories[0])
	}
}

func TestLoadConfig_SkipsEmptyLines(t *testing.T) {
	tmpDir := t.TempDir()
	confFile := filepath.Join(tmpDir, "test.conf")

	content := `

ENABLE_CATEGORY=cat1

ENABLE_CATEGORY=cat2

`

	if err := os.WriteFile(confFile, []byte(content), 0644); err != nil {
		t.Fatalf("failed to write temp file: %v", err)
	}

	cfg := LoadConfig(confFile)

	if len(cfg.EnabledCategories) != 2 {
		t.Errorf("expected 2 enabled categories, got %d", len(cfg.EnabledCategories))
	}
}
