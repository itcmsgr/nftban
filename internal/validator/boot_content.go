// =============================================================================
// NFTBan — v1.237: no PROTECTED after a failed boot-content load until restoration is evidenced
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="validator-boot-content"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-11-10"
// meta:description="Read-only check for BUG-STATUS-PROTECTED-DURING-BOOT-SET-LOAD-WINDOW: when THIS boot's nftban-boot-content load failed or was refused, the verdict stays DEGRADED until every durable ban element is present in the kernel (positive evidence). A daemon start or a sync attempt alone is not evidence."
// meta:inventory.files="/run/nftban/boot-content.state,/proc/stat"
// meta:inventory.binaries="nft"
// meta:inventory.privileges="CAP_NET_ADMIN (kernel set read via the registered verifier; only after a failed load)"
// =============================================================================
//
// Since v1.236 nftban-boot-content.service loads the durable contents (whitelist.d,
// blacklist.d, feeds) before network-pre.target and records its outcome in
// /run/nftban/boot-content.state. When that load fails, the ban sets stay empty until the
// daemon's first sync — and the verdict used to read PROTECTED during that window.
//
// Owner decisions 2026-11-10 (v1.237 rev 4 item 1.4):
//   - the validator stays the single authority (no shell recomputation);
//   - only the boot-content state of the CURRENT boot counts;
//   - after a failed or refused load, PROTECTED requires POSITIVE evidence that the required
//     ban sets are restored: every durable ban element present in the kernel. A daemon start
//     or a sync attempt is not evidence;
//   - zero expected durable bans is restored by definition: empty sets alone never degrade.
//
// Expected content = ruleset.Render (the renderer boot-content itself uses) with an EMPTY
// kernel reader, so nothing is carried and only durable sources count; supplied through the
// registered BootContentVerifier (import cycle: internal/metrics imports this package). Required sets: the
// ban sets blacklist_manual_ipv4/6 (single addresses: exact membership) and blacklist_ipv4/6
// (interval sets with auto-merge: each expected address/prefix must lie inside one kernel
// element). Anything that prevents establishing this (state unreadable after failure, render
// or kernel read error) is reported, never assumed restored.
package validator

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"net/netip"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// BootContentVerifier supplies what this package cannot import (internal/metrics imports the
// validator, and the renderer's dependencies import internal/metrics): the durable content
// keys per "family/set" as the boot-content renderer produces them with nothing carried, and
// the element keys of one kernel set. Registered by every binary that produces a verdict
// (ruleset.RegisterBootContentVerifier). Unregistered = restoration NOT verifiable: after a
// failed load that is reported (VAL-BOOT-002), never assumed restored.
type BootContentVerifier struct {
	Expected   func() (map[string][]string, error)
	KernelKeys func(family, set string) ([]string, error)
}

var bootVerifier *BootContentVerifier

// SetBootContentVerifier registers the verifier for this process.
func SetBootContentVerifier(v BootContentVerifier) { bootVerifier = &v }

var errNoBootVerifier = errors.New("no boot-content verifier registered in this binary")

// Seams (tests replace them).
var (
	bootContentStatePath = "/run/nftban/boot-content.state"
	// The state file lives in /run/nftban, which the nftban service account owns: only a
	// root-owned regular file is trusted (tests run unprivileged and replace this).
	bootStateOwnerOK = func(uid uint32) bool { return uid == 0 }
	bootTimeFn       = readBootTime
	bootExpectFn     = func() (map[string][]string, error) {
		if bootVerifier == nil || bootVerifier.Expected == nil {
			return nil, errNoBootVerifier
		}
		return bootVerifier.Expected()
	}
	bootKernelFn = func(family, set string) ([]string, error) {
		if bootVerifier == nil || bootVerifier.KernelKeys == nil {
			return nil, errNoBootVerifier
		}
		return bootVerifier.KernelKeys(family, set)
	}
)

// bootBanSets are the sets whose restoration is required. exact = hash set of single
// addresses; otherwise an interval set (containment).
var bootBanSets = []struct {
	fam, set string
	exact    bool
}{
	{"ip", "blacklist_manual_ipv4", true},
	{"ip6", "blacklist_manual_ipv6", true},
	{"ip", "blacklist_ipv4", false},
	{"ip6", "blacklist_ipv6", false},
}

type bootContentState struct {
	Outcome string
	At      time.Time
	HasAt   bool
	Detail  string
}

// bootContentFinding returns nil when there is nothing to report.
func bootContentFinding() *Finding {
	st, present, err := readBootContentState(bootContentStatePath)
	if !present {
		// No outcome recorded in this boot (/run is per boot): the unit did not run, e.g. a
		// host upgraded to v1.236+ and not rebooted since. No claim either way.
		return nil
	}
	if err != nil {
		return &Finding{Code: CodeBootContentUnverifiable, Severity: SeverityError, Component: "boot",
			Message:     "boot-content state unreadable (" + err.Error() + "); restoration of the durable ban sets cannot be established",
			Remediation: "Check " + bootContentStatePath + " and `journalctl -b -u nftban-boot-content`."}
	}
	if st.Outcome != "content-failed" && st.Outcome != "content-refused" {
		return nil // content-loaded, or skipped (disabled / inert): nothing owed
	}
	// Current boot only. /run is tmpfs, so this is defence in depth against a copied file.
	if bt, ok := bootTimeFn(); ok && st.HasAt && st.At.Before(bt.Add(-2*time.Second)) {
		return nil
	}

	expected, err := bootExpectFn()
	if err != nil {
		return &Finding{Code: CodeBootContentUnverifiable, Severity: SeverityError, Component: "boot",
			Message:     "boot content load " + st.Outcome + " (" + st.Detail + "); the durable ban content could not be rendered to verify restoration: " + err.Error(),
			Remediation: "Run: nftban firewall reload (loads the durable content in one transaction), then re-check status."}
	}

	var missing []string
	total, miss := 0, 0
	for _, s := range bootBanSets {
		want := expected[s.fam+"/"+s.set]
		if len(want) == 0 {
			continue
		}
		total += len(want)
		have, err := bootKernelFn(s.fam, s.set)
		if err != nil {
			return &Finding{Code: CodeBootContentUnverifiable, Severity: SeverityError, Component: "boot",
				Message:     "boot content load " + st.Outcome + "; kernel set " + s.fam + "/" + s.set + " unreadable: " + err.Error(),
				Remediation: "Check nft access; restoration cannot be established."}
		}
		n := countMissing(want, have, s.exact)
		if n > 0 {
			miss += n
			missing = append(missing, fmt.Sprintf("%s/%s %d of %d", s.fam, s.set, n, len(want)))
		}
	}
	if miss == 0 {
		return nil // positive evidence: every durable ban element is enforced (or none is expected)
	}
	at := ""
	if st.HasAt {
		at = " at " + st.At.UTC().Format(time.RFC3339)
	}
	return &Finding{Code: CodeBootContentNotRestored, Severity: SeverityError, Component: "boot",
		Message: fmt.Sprintf("boot content load %s%s (%s); %d of %d durable ban elements are not in the kernel yet (%s)",
			st.Outcome, at, st.Detail, miss, total, strings.Join(missing, ", ")),
		Remediation: "Wait for the daemon's sync to complete, or run: nftban firewall reload. Cause: journalctl -b -u nftban-boot-content"}
}

// bootStateMaxBytes bounds the read (the real file is a few hundred bytes).
const bootStateMaxBytes = 64 << 10

// readBootContentState parses the key=value state file. present=false when it does not exist.
//
// Trust: /run/nftban is owned by the nftban service account, so the entry can be replaced by
// that account. The file is opened without following a symlink and without blocking (a FIFO),
// and is used only if it is a root-owned regular file of bounded size; anything else is
// returned as an error, which the caller reports (VAL-BOOT-002) instead of trusting.
// Residual: that account can delete the entry, which reads as "no outcome recorded" — the
// same as before this check existed.
func readBootContentState(path string) (bootContentState, bool, error) {
	var st bootContentState
	f, err := os.OpenFile(filepath.Clean(path), os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		if os.IsNotExist(err) {
			return st, false, nil
		}
		return st, true, err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return st, true, err
	}
	if !fi.Mode().IsRegular() {
		return st, true, fmt.Errorf("not a regular file (%s)", fi.Mode().Type())
	}
	if sys, ok := fi.Sys().(*syscall.Stat_t); !ok || !bootStateOwnerOK(sys.Uid) {
		return st, true, fmt.Errorf("not owned by root")
	}
	if fi.Size() > bootStateMaxBytes {
		return st, true, fmt.Errorf("unexpectedly large (%d bytes)", fi.Size())
	}
	sc := bufio.NewScanner(io.LimitReader(f, bootStateMaxBytes))
	for sc.Scan() {
		k, v, ok := strings.Cut(sc.Text(), "=")
		if !ok {
			continue
		}
		switch k {
		case "outcome":
			st.Outcome = strings.TrimSpace(v)
		case "at":
			if t, err := time.Parse(time.RFC3339, strings.TrimSpace(v)); err == nil {
				st.At, st.HasAt = t, true
			}
		case "detail":
			st.Detail = strings.TrimSpace(v)
		}
	}
	if err := sc.Err(); err != nil {
		return st, true, err
	}
	if st.Outcome == "" {
		return st, true, fmt.Errorf("no outcome line")
	}
	return st, true, nil
}

// readBootTime returns the boot time from /proc/stat (btime).
func readBootTime() (time.Time, bool) {
	f, err := os.Open("/proc/stat")
	if err != nil {
		return time.Time{}, false
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		if v, ok := strings.CutPrefix(sc.Text(), "btime "); ok {
			if n, err := strconv.ParseInt(strings.TrimSpace(v), 10, 64); err == nil {
				return time.Unix(n, 0), true
			}
		}
	}
	return time.Time{}, false
}

// countMissing counts expected keys not enforced by the kernel element keys.
func countMissing(want []string, have []string, exact bool) int {
	if exact {
		set := make(map[string]bool, len(have))
		for _, k := range have {
			set[canonKey(k)] = true
		}
		n := 0
		for _, k := range want {
			if !set[canonKey(k)] {
				n++
			}
		}
		return n
	}
	ranges := make([]addrRange, 0, len(have))
	for _, k := range have {
		if r, ok := keyRange(k); ok {
			ranges = append(ranges, r)
		}
	}
	sort.Slice(ranges, func(i, j int) bool { return ranges[i].lo.Less(ranges[j].lo) })
	// maxHi[i] = the largest hi among ranges[0..i]. The range holding it starts at or before
	// any lo >= ranges[i].lo, so r is covered by ONE kernel element iff maxHi of the last range
	// starting at or before r.lo reaches r.hi.
	maxHi := make([]netip.Addr, len(ranges))
	for i, c := range ranges {
		maxHi[i] = c.hi
		if i > 0 && c.hi.Less(maxHi[i-1]) {
			maxHi[i] = maxHi[i-1]
		}
	}
	n := 0
	for _, k := range want {
		r, ok := keyRange(k)
		if !ok || !coveredByOne(r, ranges, maxHi) {
			n++
		}
	}
	return n
}

// canonKey normalises an address key; other keys are compared as written (timeout suffix cut).
func canonKey(k string) string {
	k, _, _ = strings.Cut(strings.TrimSpace(k), " ")
	if a, err := netip.ParseAddr(k); err == nil {
		return a.Unmap().String()
	}
	return k
}

type addrRange struct{ lo, hi netip.Addr }

// keyRange turns "a", "a/n" or "a-b" (a carried " timeout" suffix ignored) into an inclusive range.
func keyRange(k string) (addrRange, bool) {
	k, _, _ = strings.Cut(strings.TrimSpace(k), " ")
	if lo, hi, ok := strings.Cut(k, "-"); ok {
		a, e1 := netip.ParseAddr(strings.TrimSpace(lo))
		b, e2 := netip.ParseAddr(strings.TrimSpace(hi))
		if e1 != nil || e2 != nil {
			return addrRange{}, false
		}
		return addrRange{a.Unmap(), b.Unmap()}, true
	}
	if strings.Contains(k, "/") {
		p, err := netip.ParsePrefix(k)
		if err != nil {
			return addrRange{}, false
		}
		p = p.Masked()
		return addrRange{p.Addr().Unmap(), lastAddr(p)}, true
	}
	a, err := netip.ParseAddr(k)
	if err != nil {
		return addrRange{}, false
	}
	a = a.Unmap()
	return addrRange{a, a}, true
}

func lastAddr(p netip.Prefix) netip.Addr {
	b := p.Addr().Unmap().AsSlice()
	bits := p.Bits()
	for i := range b {
		for j := 0; j < 8; j++ {
			if i*8+j >= bits {
				b[i] |= 0x80 >> uint(j)
			}
		}
	}
	a, _ := netip.AddrFromSlice(b)
	return a
}

// coveredByOne reports whether r lies inside a single kernel range (auto-merge keeps
// contiguous coverage in one element; without auto-merge the exact element is present).
// One family per set, so all addresses share a bit length.
func coveredByOne(r addrRange, sorted []addrRange, maxHi []netip.Addr) bool {
	i := sort.Search(len(sorted), func(i int) bool { return r.lo.Less(sorted[i].lo) })
	if i == 0 {
		return false // no kernel range starts at or before r.lo
	}
	h := maxHi[i-1]
	return h.BitLen() == r.hi.BitLen() && !h.Less(r.hi)
}
