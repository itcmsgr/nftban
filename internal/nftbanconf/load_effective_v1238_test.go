// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package nftbanconf

// v1.238 D-1 (owner GO 2026-11-23): the feeds master switch is read NOW, through the same parser
// and override order as Load, and an unreadable configuration is an error, never "disabled".

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadEffectiveReadsCurrentSwitchWithOverrides(t *testing.T) {
	d := t.TempDir()
	base := filepath.Join(d, "nftban.conf")
	local := base + ".local"
	if err := os.WriteFile(base, []byte("NFTBAN_FEEDS_ENABLED=\"false\"\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	c, err := loadEffectiveFrom(base)
	if err != nil || c.FeedsEnabled {
		t.Fatalf("base only: %v enabled=%v", err, c != nil && c.FeedsEnabled)
	}
	// the operator switches feeds on in the central override: the next read sees it
	if err := os.WriteFile(local, []byte("NFTBAN_FEEDS_ENABLED=\"true\"\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	if c, err = loadEffectiveFrom(base); err != nil || !c.FeedsEnabled {
		t.Fatalf("override on: %v", err)
	}
	// and off again, without any cache in between
	if err := os.WriteFile(local, []byte("NFTBAN_FEEDS_ENABLED=\"false\"\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	if c, err = loadEffectiveFrom(base); err != nil || c.FeedsEnabled {
		t.Fatalf("override off: %v", err)
	}
}

func TestLoadEffectiveUnreadableIsAnErrorNotDisabled(t *testing.T) {
	d := t.TempDir()
	base := filepath.Join(d, "nftban.conf")
	// missing base config: Load falls back to defaults (feeds off); LoadEffective refuses
	if _, err := loadEffectiveFrom(base); err == nil {
		t.Fatal("a missing nftban.conf must be an error, not defaults")
	}
	if err := os.WriteFile(base, []byte("NFTBAN_FEEDS_ENABLED=\"true\"\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	// an override that exists but cannot be opened (a directory here; a permission error as
	// non-root) is an error: silently skipping it could hide NFTBAN_FEEDS_ENABLED="false"
	if err := os.Mkdir(base+".local", 0o750); err != nil {
		t.Fatal(err)
	}
	f, err := os.Open(base + ".local")
	if err == nil {
		f.Close()
		// a directory opens on Linux; make the override a file the caller cannot read instead
		_ = os.Remove(base + ".local")
		if err := os.WriteFile(base+".local", []byte("NFTBAN_FEEDS_ENABLED=\"false\"\n"), 0o000); err != nil {
			t.Fatal(err)
		}
		if os.Geteuid() == 0 {
			t.Skip("root reads a 0000 file; the unreadable-override arm needs a non-root run")
		}
	}
	if c, err := loadEffectiveFrom(base); err == nil {
		t.Fatalf("an unreadable override must be an error (got enabled=%v)", c.FeedsEnabled)
	}
}
