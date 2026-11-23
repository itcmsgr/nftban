// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package botguard

// v1.238 D1/D2 (lab4): the central nftban.conf.local was looked up in conf.d/ (two Dir levels) and
// ignored; it must be read from the config dir and win, with the module truth table.

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadConfigReadsCentralOverride(t *testing.T) {
	d := t.TempDir()
	main := filepath.Join(d, "conf.d", "botguard", "main.conf")
	if err := os.MkdirAll(filepath.Dir(main), 0o755); err != nil {
		t.Fatal(err)
	}
	must := func(p, s string) {
		if err := os.WriteFile(p, []byte(s), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	must(main, "HTTP_BOTGUARD_ENABLED=\"false\"\n")
	must(main+".local", "HTTP_BOTGUARD_ENABLED=\"enabled\"\n")
	cfg, err := LoadConfig(main)
	if err != nil {
		t.Fatal(err)
	}
	if !cfg.Enabled {
		t.Fatal(`module .local "enabled" must be on (module truth table)`)
	}
	must(filepath.Join(d, "nftban.conf.local"), "HTTP_BOTGUARD_ENABLED=\"false\"\n")
	cfg, err = LoadConfig(main)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Enabled {
		t.Fatal("explicit central false must win (was ignored: wrong path)")
	}
}
