// =============================================================================
// NFTBan v1.236 - safety lane stage 1: batched permanent adds (kernel arm)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="permanent_batch_kernel_v1236_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-20"
// meta:description="v1.236 safety lane stage 1 (BUG-UPGRADE-SYNC-SCALES-WITH-PERMANENT-BANS-TIMEOUT-AND-ENFORCEMENT-GAP). Drives the REAL NFTManager.AddPermanentIPsBatch against a REAL kernel and asserts the per-element semantics of AddIPWithTimeout(ip, 0): absent -> permanent; timed -> permanent in the same transaction (audit H11, no expires left); already permanent -> unchanged; duplicates counted once; wrong-family and non-IP input reported Invalid, nothing written; IPv6 set; a 3000-element batch (several chunks) ends with every element present and permanent, and its duration is logged against the per-IP path on the same data. Runs ONLY as root with NFTBAN_NETNS_KERNEL_TEST=1 and refuses to run if an ip/ip6 nftban table already exists (start it inside a throwaway network namespace). Skipped everywhere else (CI)."
// meta:input="None"
// meta:output="t.Fatal/t.Error on any semantic difference; t.Logf of batch vs per-IP durations"
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
	"fmt"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/google/nftables"
)

func TestAddPermanentIPsBatch_Kernel(t *testing.T) {
	if os.Getenv("NFTBAN_NETNS_KERNEL_TEST") != "1" || os.Geteuid() != 0 {
		t.Skip("kernel arm: root + NFTBAN_NETNS_KERNEL_TEST=1 inside a throwaway network namespace only")
	}
	for _, fam := range []string{"ip", "ip6"} {
		if err := exec.Command("nft", "list", "table", fam, "nftban").Run(); err == nil {
			t.Fatalf("a %s nftban table already exists: refusing (run inside a fresh network namespace)", fam)
		}
	}
	nftOut(t, "add", "table", "ip", "nftban")
	nftOut(t, "add", "table", "ip6", "nftban")
	t.Cleanup(func() {
		_ = exec.Command("nft", "delete", "table", "ip", "nftban").Run()
		_ = exec.Command("nft", "delete", "table", "ip6", "nftban").Run()
	})
	nftOut(t, "add", "set", "ip", "nftban", "blacklist_manual_ipv4", "{ type ipv4_addr; flags timeout; }")
	nftOut(t, "add", "set", "ip6", "nftban", "blacklist_manual_ipv6", "{ type ipv6_addr; flags timeout; }")

	m, err := NewNFTManager()
	if err != nil {
		t.Fatalf("NewNFTManager: %v", err)
	}
	conn, err := nftables.New()
	if err != nil {
		t.Fatalf("nftables.New: %v", err)
	}
	set4, err := conn.GetSetByName(&nftables.Table{Name: "nftban", Family: nftables.TableFamilyIPv4}, "blacklist_manual_ipv4")
	if err != nil {
		t.Fatalf("GetSetByName v4: %v", err)
	}
	set6, err := conn.GetSetByName(&nftables.Table{Name: "nftban", Family: nftables.TableFamilyIPv6}, "blacklist_manual_ipv6")
	if err != nil {
		t.Fatalf("GetSetByName v6: %v", err)
	}

	// --- 1. mixed semantics, IPv4 ------------------------------------------------------------
	const (
		timedIP = "198.51.100.7"  // present WITH a timeout -> must become permanent (H11)
		permIP  = "198.51.100.8"  // present permanent      -> unchanged
		freshIP = "198.51.100.20" // absent                 -> added permanent
	)
	nftOut(t, "add", "element", "ip", "nftban", "blacklist_manual_ipv4", "{ "+timedIP+" timeout 1h }")
	nftOut(t, "add", "element", "ip", "nftban", "blacklist_manual_ipv4", "{ "+permIP+" }")
	in := []string{timedIP, permIP, freshIP, freshIP, "2001:db8::1", "not-an-ip"}
	res, err := m.AddPermanentIPsBatch(set4, in)
	if err != nil {
		t.Fatalf("v4 batch: %v", err)
	}
	if res.Added != 1 || res.Replaced != 1 || res.Unchanged != 1 || res.Invalid != 2 {
		t.Errorf("v4 effect counts: got %+v, want Added=1 Replaced=1 Unchanged=1 Invalid=2 (duplicate counted once)", res)
	}
	got := nftOut(t, "list", "set", "ip", "nftban", "blacklist_manual_ipv4")
	for _, ip := range []string{timedIP, permIP, freshIP} {
		if !strings.Contains(got, ip) {
			t.Errorf("v4: %s missing after the batch:\n%s", ip, got)
		}
	}
	if strings.Contains(got, "expires") || strings.Contains(got, "timeout 1h") {
		t.Errorf("v4: a timed element KEPT its timeout (H11 regression):\n%s", got)
	}
	if strings.Contains(got, "2001:db8") {
		t.Errorf("v4: a wrong-family element was written:\n%s", got)
	}

	// --- 2. IPv6 ------------------------------------------------------------------------------
	nftOut(t, "add", "element", "ip6", "nftban", "blacklist_manual_ipv6", "{ 2001:db8::7 timeout 1h }")
	res6, err := m.AddPermanentIPsBatch(set6, []string{"2001:db8::7", "2001:db8::20", "198.51.100.1"})
	if err != nil {
		t.Fatalf("v6 batch: %v", err)
	}
	if res6.Added != 1 || res6.Replaced != 1 || res6.Invalid != 1 {
		t.Errorf("v6 effect counts: got %+v, want Added=1 Replaced=1 Invalid=1", res6)
	}
	if got6 := nftOut(t, "list", "set", "ip6", "nftban", "blacklist_manual_ipv6"); strings.Contains(got6, "expires") || !strings.Contains(got6, "2001:db8::20") {
		t.Errorf("v6: want both permanent:\n%s", got6)
	}

	// --- 3. scale: 3000 elements, several chunks, with timed ones mixed in --------------------
	nftOut(t, "flush", "set", "ip", "nftban", "blacklist_manual_ipv4")
	big := make([]string, 0, 3000)
	for i := 0; i < 3000; i++ {
		big = append(big, fmt.Sprintf("23.129.%d.%d", 64+i/250, 1+i%250))
	}
	for i := 0; i < 30; i++ { // 30 of them already timed (the fixture's timed bans)
		nftOut(t, "add", "element", "ip", "nftban", "blacklist_manual_ipv4", "{ "+big[i*97]+" timeout 2h }")
	}
	t0 := time.Now()
	resBig, err := m.AddPermanentIPsBatch(set4, big)
	batchDur := time.Since(t0)
	if err != nil {
		t.Fatalf("3000 batch: %v", err)
	}
	if resBig.Added != 2970 || resBig.Replaced != 30 || resBig.Invalid != 0 {
		t.Errorf("3000 batch effect: got %+v, want Added=2970 Replaced=30", resBig)
	}
	all := nftOut(t, "list", "set", "ip", "nftban", "blacklist_manual_ipv4")
	if n := strings.Count(all, "23.129."); n != 3000 {
		t.Errorf("3000 batch: %d elements present, want 3000", n)
	}
	if strings.Contains(all, "expires") {
		t.Errorf("3000 batch: timed elements kept a timeout (H11 regression)")
	}
	// Idempotent re-run: everything already permanent.
	again, err := m.AddPermanentIPsBatch(set4, big)
	if err != nil || again.Unchanged != 3000 || again.Added+again.Replaced != 0 {
		t.Errorf("re-run: got %+v err=%v, want Unchanged=3000", again, err)
	}

	// The per-IP path on the same data, for the record (the regression this stage removes).
	nftOut(t, "flush", "set", "ip", "nftban", "blacklist_manual_ipv4")
	t1 := time.Now()
	for _, ip := range big {
		if err := m.AddIPWithTimeout(set4, ip, 0); err != nil {
			t.Fatalf("per-IP %s: %v", ip, err)
		}
	}
	perIPDur := time.Since(t1)
	t.Logf("3000 permanent adds: batch %v vs per-IP %v", batchDur, perIPDur)
}
