// =============================================================================
// NFTBan - R-11 render-effective honours the administrator's inbound floor (v1.234)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="cmd_ports_inbound_floor_r11_v1234_test"
// meta:type="test"
// meta:version="1.234.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="End-to-end through the CLI authority the shell render, the boot projection and the transition-health verifier all call (`nftban-core ports render-effective`): with nftban.conf declaring NFTBAN_BASELINE_TCP_IN=none, SSH on 55000 and no 22/80/443 in ports.d, tcp_ports_in must be exactly the SSH safeguard + ports.d. Uses only interfaces that also exist on v1.233.1, so it EXECUTES against the historical subject and fails there (80/443 re-added)."
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars="NFTBAN_EFFECTIVE_SSH_PORTS"
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package main

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/nftbanconf"
)

func TestR11RenderEffective_AdminRemovalOf80And443Honoured(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "ports.d"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "ports.d", "00-ssh.conf"), []byte("55000/T/I\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "ports.d", "90-custom.conf"), []byte("18765/T/I\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	conf := filepath.Join(dir, "nftban.conf")
	body := "NFTBAN_CONFIG_DIR=\"" + dir + "\"\nNFTBAN_BASELINE_TCP_IN=\"none\"\n"
	if err := os.WriteFile(conf, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}

	// Load() is a process-wide sync.Once; this is the only test in the package
	// that calls it, and it must bind to the sandbox or the result means nothing.
	nftbanconf.DefaultConfigFile = conf
	cfg, err := nftbanconf.Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.ConfigDir != dir {
		t.Fatalf("precondition: config not bound to the sandbox (ConfigDir=%q) — result would be about the host, not the fixture", cfg.ConfigDir)
	}

	t.Setenv("NFTBAN_EFFECTIVE_SSH_PORTS", "55000")
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	orig := os.Stdout
	os.Stdout = w
	runErr := cmdPortsRenderEffective(cfg)
	w.Close()
	os.Stdout = orig
	out, _ := io.ReadAll(r)
	if runErr != nil {
		t.Fatalf("render-effective failed: %v", runErr)
	}

	var tin string
	for _, l := range strings.Split(string(out), "\n") {
		if strings.HasPrefix(l, "NFTBAN_SVC_TCP_IN=") {
			tin = strings.TrimPrefix(l, "NFTBAN_SVC_TCP_IN=")
		}
	}
	if tin != "18765, 55000" {
		t.Fatalf("tcp_ports_in = %q; want exactly the SSH safeguard + ports.d (\"18765, 55000\"): an administrator's removal of 80/443 must not be reversed", tin)
	}
}
