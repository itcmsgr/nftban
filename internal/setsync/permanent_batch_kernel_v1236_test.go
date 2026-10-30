// =============================================================================
// NFTBan v1.236 - safety lane stage 1: permanent upsert (kernel arm)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="permanent_batch_kernel_v1236_test"
// meta:type="test"
// meta:version="1.1.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-20"
// meta:description="v1.236 safety lane stage 1 (BUG-UPGRADE-SYNC-SCALES-WITH-PERMANENT-BANS-TIMEOUT-AND-ENFORCEMENT-GAP). Drives the REAL NFTManager.UpsertPermanentElements against a REAL kernel: absent -> permanent; timed -> permanent (audit H11, no expires left); already permanent -> unchanged; other elements of the set KEPT (additive, no flush); duplicates once; wrong-family/non-IP counted invalid and not written; IPv6; 3000 elements with 30 timed in ONE transaction (duration logged against the per-IP path). Injected races at the kernel boundary: a timed ban added for a wanted key after the read (durable permanent wins via the corrective commit); a timed element deleted (expired) after the read (rejected commit re-planned, counted once); an unban after the commit is re-added (documented current behaviour, stage 2 owns the snapshot boundary). Runs ONLY as root with NFTBAN_NETNS_KERNEL_TEST=1 and refuses to run if an ip/ip6 nftban table already exists (throwaway network namespace). Skipped everywhere else (CI)."
// meta:input="None"
// meta:output="t.Fatal/t.Error on any semantic difference; t.Logf of upsert vs per-IP durations"
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

// hookReader runs after() once GetSetElements has returned: a deterministic stand-in for
// "another writer changed the set between our read and our commit".
type hookReader struct {
	r     setReader
	after func()
}

func (h hookReader) GetSetElements(s *nftables.Set) ([]nftables.SetElement, error) {
	e, err := h.r.GetSetElements(s)
	if h.after != nil {
		h.after()
	}
	return e, err
}

func TestUpsertPermanentElements_Kernel(t *testing.T) {
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
	list4 := func() string { return nftOut(t, "list", "set", "ip", "nftban", "blacklist_manual_ipv4") }

	// --- 1. semantics + additive (an unrelated runtime timed ban survives) ---------------------
	const (
		timedIP   = "198.51.100.7"  // present WITH a timeout -> permanent (H11)
		permIP    = "198.51.100.8"  // present permanent      -> unchanged
		freshIP   = "198.51.100.20" // absent                 -> added
		runtimeIP = "198.51.100.99" // NOT wanted, timed      -> must be KEPT with its timeout
	)
	nftOut(t, "add", "element", "ip", "nftban", "blacklist_manual_ipv4", "{ "+timedIP+" timeout 1h }")
	nftOut(t, "add", "element", "ip", "nftban", "blacklist_manual_ipv4", "{ "+permIP+" }")
	nftOut(t, "add", "element", "ip", "nftban", "blacklist_manual_ipv4", "{ "+runtimeIP+" timeout 1h }")
	st, err := m.UpsertPermanentElements(set4, []string{timedIP, permIP, freshIP, freshIP, "2001:db8::1", "not-an-ip"})
	if err != nil || !st.Converged {
		t.Fatalf("v4 upsert: err=%v stats=%+v", err, st)
	}
	if st.IPsAdded != 1 || st.IPsReplaced != 1 || st.IPsUnchanged != 1 || st.IPsInvalid != 2 {
		t.Errorf("v4 effects: got %+v, want added=1 replaced=1 unchanged=1 invalid=2", *st)
	}
	got := list4()
	for _, ip := range []string{timedIP, permIP, freshIP} {
		if !strings.Contains(got, ip) {
			t.Errorf("v4: %s missing:\n%s", ip, got)
		}
	}
	if strings.Contains(got, timedIP+" timeout") || strings.Contains(got, timedIP+" expires") {
		t.Errorf("v4: %s kept its timeout (H11 regression):\n%s", timedIP, got)
	}
	if !strings.Contains(got, runtimeIP+" timeout") {
		t.Errorf("v4: the unrelated runtime timed ban was removed or changed (upsert must be additive):\n%s", got)
	}

	// --- 2. IPv6 --------------------------------------------------------------------------------
	nftOut(t, "add", "element", "ip6", "nftban", "blacklist_manual_ipv6", "{ 2001:db8::7 timeout 1h }")
	st6, err := m.UpsertPermanentElements(set6, []string{"2001:db8::7", "2001:db8::20", "198.51.100.1"})
	if err != nil || st6.IPsAdded != 1 || st6.IPsReplaced != 1 || st6.IPsInvalid != 1 {
		t.Errorf("v6: err=%v stats=%+v, want added=1 replaced=1 invalid=1", err, st6)
	}
	if got6 := nftOut(t, "list", "set", "ip6", "nftban", "blacklist_manual_ipv6"); strings.Contains(got6, "expires") {
		t.Errorf("v6: kept a timeout:\n%s", got6)
	}

	// --- 3. injected race A: a timed ban for a wanted key appears AFTER our read ---------------
	const raceA = "198.51.100.30"
	readsA := 0
	stA, err := upsertPermanentElements(set4, []string{raceA},
		func() (setReader, error) {
			readsA++
			c, err := m.readConn()
			if readsA != 1 {
				return c, err
			}
			// After our FIRST read returns, before our commit: another writer adds it timed.
			return hookReader{c, func() {
				nftOut(t, "add", "element", "ip", "nftban", "blacklist_manual_ipv4", "{ "+raceA+" timeout 1h }")
			}}, err
		},
		func() (upsertConn, error) { return m.txConn() })
	if err != nil || !stA.Converged {
		t.Fatalf("race A: err=%v stats=%+v", err, stA)
	}
	if got := list4(); strings.Contains(got, raceA+" timeout") || strings.Contains(got, raceA+" expires") || !strings.Contains(got, raceA) {
		t.Errorf("race A: durable permanent must win over a concurrent timed ban:\n%s", got)
	}

	// --- 4. injected race B: a timed element expires (deleted) after our read -------------------
	const raceB = "198.51.100.31"
	nftOut(t, "add", "element", "ip", "nftban", "blacklist_manual_ipv4", "{ "+raceB+" timeout 1h }")
	readsB := 0
	stB, err := upsertPermanentElements(set4, []string{raceB},
		func() (setReader, error) {
			readsB++
			c, err := m.readConn()
			if readsB != 1 {
				return c, err
			}
			// After our FIRST read (it saw the timed element), before our commit: it expires.
			return hookReader{c, func() {
				nftOut(t, "delete", "element", "ip", "nftban", "blacklist_manual_ipv4", "{ "+raceB+" }")
			}}, err
		},
		func() (upsertConn, error) { return m.txConn() })
	if err != nil || !stB.Converged || stB.IPsAdded+stB.IPsReplaced != 1 {
		t.Fatalf("race B: err=%v stats=%+v, want converged and the key counted exactly once", err, stB)
	}
	if got := list4(); !strings.Contains(got, raceB) || strings.Contains(got, raceB+" timeout") {
		t.Errorf("race B: want %s present and permanent:\n%s", raceB, got)
	}

	// --- 5. injected race C: an unban AFTER our commit -> re-added (current behaviour) ----------
	const raceC = "198.51.100.32"
	readsC := 0
	stC, err := upsertPermanentElements(set4, []string{raceC},
		func() (setReader, error) {
			readsC++
			if readsC == 2 { // after the first commit, before the verification read
				nftOut(t, "delete", "element", "ip", "nftban", "blacklist_manual_ipv4", "{ "+raceC+" }")
			}
			return m.readConn()
		},
		func() (upsertConn, error) { return m.txConn() })
	t.Logf("race C (unban after commit, key still wanted): err=%v stats=%+v present=%v — re-added; stage 2 snapshot boundary owns unban-vs-sync ordering",
		err, stC, strings.Contains(list4(), raceC))

	// --- 6. scale: 3000 elements, 30 timed, ONE transaction ------------------------------------
	nftOut(t, "flush", "set", "ip", "nftban", "blacklist_manual_ipv4")
	big := make([]string, 0, 3000)
	for i := 0; i < 3000; i++ {
		big = append(big, fmt.Sprintf("23.129.%d.%d", 64+i/250, 1+i%250))
	}
	for i := 0; i < 30; i++ {
		nftOut(t, "add", "element", "ip", "nftban", "blacklist_manual_ipv4", "{ "+big[i*97]+" timeout 2h }")
	}
	t0 := time.Now()
	stBig, err := m.UpsertPermanentElements(set4, big)
	upsertDur := time.Since(t0)
	if err != nil || !stBig.Converged || stBig.IPsAdded != 2970 || stBig.IPsReplaced != 30 {
		t.Fatalf("3000: err=%v stats=%+v, want converged added=2970 replaced=30", err, stBig)
	}
	all := list4()
	if n := strings.Count(all, "23.129."); n != 3000 || strings.Contains(all, "expires") {
		t.Errorf("3000: %d present (want 3000), timeouts left=%v", n, strings.Contains(all, "expires"))
	}
	again, err := m.UpsertPermanentElements(set4, big)
	if err != nil || again.IPsUnchanged != 3000 || again.IPsAdded+again.IPsReplaced != 0 {
		t.Errorf("re-run: err=%v stats=%+v, want unchanged=3000", err, again)
	}
	nftOut(t, "flush", "set", "ip", "nftban", "blacklist_manual_ipv4")
	t1 := time.Now()
	for _, ip := range big {
		if err := m.AddIPWithTimeout(set4, ip, 0); err != nil {
			t.Fatalf("per-IP %s: %v", ip, err)
		}
	}
	t.Logf("3000 permanent adds: upsert %v vs per-IP %v", upsertDur, time.Since(t1))
}
