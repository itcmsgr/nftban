// =============================================================================
// NFTBan - R-11 render-effective honours NFTBAN_BASELINE_TCP_IN (v1.234)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="cmd_ports_inbound_floor_r11_v1234_test"
// meta:type="test"
// meta:version="1.234.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="End-to-end through the CLI authority that the rebuild render, the boot projection render and the transition-health verifier all call (`nftban-core ports render-effective`), loading the REAL nftban.conf + nftban.conf.local layering. Owner ruling 2026-09-29: unset -> 80/443 kept; explicit non-empty -> exactly the configured ports, 80/443 NOT appended; explicit empty -> no baseline ports, defaults NOT restored; an explicit empty in .local beats a value in .conf. SSH on 55000 with 22/80/443 absent from ports.d: 55000 always present, 22 never. Each configuration runs in its own child process because Load() is a process-wide sync.Once. Uses only interfaces that also exist on v1.233.1, so it EXECUTES against the historical subject: unset passes there, every explicit configuration fails (80/443 re-added)."
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars="NFTBAN_EFFECTIVE_SSH_PORTS,R11_HELPER_CONF"
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/nftbanconf"
	"github.com/itcmsgr/nftban/internal/ports"
)

// TestR11RenderEffectiveHelperProcess is NOT a test on its own: it is the child
// body for the table below. It binds Load() to the sandbox conf named by
// R11_HELPER_CONF and prints render-effective's output.
func TestR11RenderEffectiveHelperProcess(t *testing.T) {
	conf := os.Getenv("R11_HELPER_CONF")
	if conf == "" {
		t.Skip("helper process only")
	}
	nftbanconf.DefaultConfigFile = conf
	// v1.235: never the host's panel state (the test must not depend on, or read, the host).
	ports.PanelStateFile = filepath.Join(filepath.Dir(conf), "panels", "enabled.conf")
	cfg, err := nftbanconf.Load()
	if err != nil {
		os.Stdout.WriteString("LOAD_ERROR " + err.Error() + "\n")
		os.Exit(3)
	}
	if cfg.ConfigDir != filepath.Dir(conf) {
		os.Stdout.WriteString("PRECONDITION_CONFIGDIR " + cfg.ConfigDir + "\n")
		os.Exit(4)
	}
	if err := cmdPortsRenderEffective(cfg); err != nil {
		os.Stdout.WriteString("RENDER_ERROR " + err.Error() + "\n")
		os.Exit(5)
	}
	os.Exit(0)
}

func r11Render(t *testing.T, confBody, localBody string, withLocal bool) (tin string, raw string, code int) {
	t.Helper()
	dir := t.TempDir()
	pd := filepath.Join(dir, "ports.d")
	if err := os.MkdirAll(pd, 0o755); err != nil {
		t.Fatal(err)
	}
	// SSH moved to 55000; 22, 80 and 443 appear in NO ports.d file.
	if err := os.WriteFile(filepath.Join(pd, "00-ssh.conf"), []byte("55000/T/I\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(pd, "90-custom.conf"), []byte("18765/T/I\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	conf := filepath.Join(dir, "nftban.conf")
	if err := os.WriteFile(conf, []byte("NFTBAN_CONFIG_DIR=\""+dir+"\"\n"+confBody), 0o644); err != nil {
		t.Fatal(err)
	}
	if withLocal {
		if err := os.WriteFile(conf+".local", []byte(localBody), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	cmd := exec.Command(os.Args[0], "-test.run=^TestR11RenderEffectiveHelperProcess$")
	// The SSH-detection authority's output, as the shell render passes it.
	cmd.Env = append(os.Environ(), "R11_HELPER_CONF="+conf, "NFTBAN_EFFECTIVE_SSH_PORTS=55000")
	out, err := cmd.Output()
	code = 0
	if ee, ok := err.(*exec.ExitError); ok {
		code = ee.ExitCode()
	} else if err != nil {
		t.Fatalf("helper did not execute: %v", err)
	}
	raw = string(out)
	for _, l := range strings.Split(raw, "\n") {
		if strings.HasPrefix(l, "NFTBAN_SVC_TCP_IN=") {
			tin = strings.TrimPrefix(l, "NFTBAN_SVC_TCP_IN=")
		}
	}
	return tin, raw, code
}

func TestR11RenderEffective_OwnerRulingMatrix(t *testing.T) {
	cases := []struct {
		name, conf, local string
		withLocal         bool
		want              string
	}{
		{"unset keeps the established 80/443", "", "", false, "80, 443, 18765, 55000"},
		{"explicit non-empty is exact, 80/443 not appended", "NFTBAN_BASELINE_TCP_IN=\"8443\"\n", "", false, "8443, 18765, 55000"},
		{"explicit empty removes the baseline, defaults not restored", "NFTBAN_BASELINE_TCP_IN=\"\"\n", "", false, "18765, 55000"},
		{"explicit empty, unquoted", "NFTBAN_BASELINE_TCP_IN=\n", "", false, "18765, 55000"},
		{"none is a synonym for empty", "NFTBAN_BASELINE_TCP_IN=none\n", "", false, "18765, 55000"},
		{".local empty beats .conf value", "NFTBAN_BASELINE_TCP_IN=\"8443\"\n", "NFTBAN_BASELINE_TCP_IN=\"\"\n", true, "18765, 55000"},
		{".local value beats .conf empty", "NFTBAN_BASELINE_TCP_IN=\"\"\n", "NFTBAN_BASELINE_TCP_IN=\"443\"\n", true, "443, 18765, 55000"},
		{".local without the key keeps .conf empty", "NFTBAN_BASELINE_TCP_IN=\"\"\n", "NFTBAN_LOG_LEVEL=info\n", true, "18765, 55000"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			tin, raw, code := r11Render(t, c.conf, c.local, c.withLocal)
			if code != 0 {
				t.Fatalf("render-effective child exited %d:\n%s", code, raw)
			}
			if tin != c.want {
				t.Fatalf("tcp_ports_in = %q, want %q", tin, c.want)
			}
			for _, tok := range strings.Split(tin, ", ") {
				if tok == "22" {
					t.Fatalf("22 present although sshd is on 55000 and nothing configures 22: %q", tin)
				}
			}
		})
	}
}

func TestR11RenderEffective_InvalidValueFailsClosed(t *testing.T) {
	_, raw, code := r11Render(t, "NFTBAN_BASELINE_TCP_IN=\"80,http\"\n", "", false)
	if code == 0 {
		t.Fatalf("an invalid floor must fail the render (existing firewall preserved), got success:\n%s", raw)
	}
	if strings.Contains(raw, "NFTBAN_SVC_TCP_IN=") {
		t.Fatalf("an invalid floor must emit NO element lines:\n%s", raw)
	}
}

// Kept from cf70ecc3: the single-configuration reproducer, now via the child.
func TestR11RenderEffective_AdminRemovalOf80And443Honoured(t *testing.T) {
	tin, raw, code := r11Render(t, "NFTBAN_BASELINE_TCP_IN=\"none\"\n", "", false)
	if code != 0 {
		t.Fatalf("child exited %d:\n%s", code, raw)
	}
	if tin != "18765, 55000" {
		t.Fatalf("tcp_ports_in = %q; want exactly the SSH safeguard + ports.d (\"18765, 55000\"): an administrator's removal of 80/443 must not be reversed", tin)
	}
}
