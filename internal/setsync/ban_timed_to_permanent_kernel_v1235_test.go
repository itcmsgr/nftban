// =============================================================================
// NFTBan v1.235 - audit H11: a permanent ban over a live timed ban (kernel arm)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="ban_timed_to_permanent_kernel_v1235_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-08"
// meta:description="Audit H11 (train D #1456). Drives the REAL NFTManager.AddIPWithTimeout against a REAL kernel: an element added with a 1h timeout and then added again as permanent (timeout 0) must end up WITHOUT a timeout, in both the non-interval timeout set (netlink path, blacklist_manual_ipv4) and the interval set (nft CLI path, blacklist_ipv4). Measured on lab4 2026-10-08: the kernel keeps the old timeout on a plain re-add (rc 0), so a permanent ban silently expired. Runs ONLY as root with NFTBAN_NETNS_KERNEL_TEST=1, and refuses to run if an ip nftban table already exists (it must be started inside a throwaway network namespace: ip netns exec <ns> go test ...). Skipped everywhere else (CI)."
// meta:input="None"
// meta:output="t.Fatal when the permanent re-add keeps the old timeout"
// meta:depends="testing,os/exec,github.com/google/nftables"
// meta:inventory.files=""
// meta:inventory.binaries="nft"
// meta:inventory.env_vars="NFTBAN_NETNS_KERNEL_TEST"
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root (inside a throwaway network namespace)"
// =============================================================================

package setsync

import (
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/google/nftables"
)

func nftOut(t *testing.T, args ...string) string {
	t.Helper()
	out, err := exec.Command("nft", args...).CombinedOutput()
	if err != nil {
		t.Fatalf("nft %s: %v: %s", strings.Join(args, " "), err, out)
	}
	return string(out)
}

func TestBanTimedToPermanent_Kernel_H11(t *testing.T) {
	if os.Getenv("NFTBAN_NETNS_KERNEL_TEST") != "1" || os.Geteuid() != 0 {
		t.Skip("kernel arm: root + NFTBAN_NETNS_KERNEL_TEST=1 inside a throwaway network namespace only")
	}
	// Never against a real ruleset: the namespace must be empty of NFTBan.
	if err := exec.Command("nft", "list", "table", "ip", "nftban").Run(); err == nil {
		t.Fatal("an ip nftban table already exists: refusing (run inside a fresh network namespace)")
	}
	nftOut(t, "add", "table", "ip", "nftban")
	t.Cleanup(func() { _ = exec.Command("nft", "delete", "table", "ip", "nftban").Run() })
	nftOut(t, "add", "set", "ip", "nftban", "blacklist_manual_ipv4", "{ type ipv4_addr; flags timeout; }")
	nftOut(t, "add", "set", "ip", "nftban", "blacklist_ipv4", "{ type ipv4_addr; flags interval,timeout; }")

	m, err := NewNFTManager()
	if err != nil {
		t.Fatalf("NewNFTManager: %v", err)
	}
	conn, err := nftables.New()
	if err != nil {
		t.Fatalf("nftables.New: %v", err)
	}
	tbl := &nftables.Table{Name: "nftban", Family: nftables.TableFamilyIPv4}

	const ip = "198.51.100.7"
	for _, name := range []string{"blacklist_manual_ipv4", "blacklist_ipv4"} {
		set, err := conn.GetSetByName(tbl, name)
		if err != nil {
			t.Fatalf("GetSetByName %s: %v", name, err)
		}
		if err := m.AddIPWithTimeout(set, ip, time.Hour); err != nil {
			t.Fatalf("%s: timed add: %v", name, err)
		}
		// "expires" belongs to an element; the set header itself always says "flags ...timeout".
		if before := nftOut(t, "list", "set", "ip", "nftban", name); !strings.Contains(before, "expires") {
			t.Fatalf("%s: precondition: the timed element carries no timeout:\n%s", name, before)
		}
		if err := m.AddIPWithTimeout(set, ip, 0); err != nil {
			t.Fatalf("%s: permanent add: %v", name, err)
		}
		after := nftOut(t, "list", "set", "ip", "nftban", name)
		if !strings.Contains(after, ip) {
			t.Fatalf("%s: the element is gone after the permanent add:\n%s", name, after)
		}
		if strings.Contains(after, "expires") || strings.Contains(after, "timeout 1h") {
			t.Errorf("%s: permanent ban over a live timed ban KEPT the old timeout (it will expire):\n%s", name, after)
		}
	}
}
