// NFTBan - durable apply-boundary never-ban exemption guard
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
//
// meta:name="nftbackend_exemption"
// meta:type="core"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-29"
// meta:description="Authoritative never-ban exemption resolver consulted by Backend.Ban() before any IP is written to a drop set. Establishes the never-ban invariant for admin/management/whitelist/system/live-SSH IPs at the durable apply boundary (NOT relying on firewall rule order or the unprivileged shell scanner gate). Range-aware (CIDR), v4+v6 parity, fail-safe (a resolver failure NEVER blocks a legitimate ban — it falls back to no-exemption + rule-order). Sources: whitelist.d (operator 99-manual / session 00-session / system 00-system, CIDR-aware via internal/whitelist), DetectSystemIPs (server/gateway/dns/loopback/current-SSH), live established SSH peers (/proc/net/tcp{,6}), and an optional NFTBAN_MANAGEMENT_IPS env. Also publishes the resolved exempt list to a scanner-readable file so the unprivileged BotScan scanner can suppress signals cheaply (no nft read)."
// meta:inventory.files="/etc/nftban/whitelist.d/*.conf,/proc/net/tcp,/proc/net/tcp6,/etc/ssh/sshd_config"
// meta:inventory.binaries=""
// meta:inventory.env_vars="NFTBAN_MANAGEMENT_IPS"
// meta:inventory.config_files="/etc/nftban/whitelist.d/*.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================

package nftbackend

import (
	"bufio"
	"encoding/binary"
	"encoding/hex"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/internal/safety"
	"github.com/itcmsgr/nftban/internal/whitelist"
)

// exemptResolver holds the never-ban exemption snapshot and refreshes it on a TTL.
// IsExempt reads the snapshot under an RLock; a stale snapshot triggers one refresh.
// Fail-safe: on any source error a previously-good snapshot is kept; if nothing has
// ever loaded the snapshot is simply empty (so bans proceed — a broken resolver must
// NEVER block legitimate bans; admin safety then degrades to the pre-existing rule
// order, not worse than before).
type exemptResolver struct {
	mu          sync.RWMutex
	configDir   string
	scannerFile string
	ttl         time.Duration

	loaded   bool
	loadedAt time.Time
	exact    map[string]struct{} // canonical single-IP strings
	prefixes []netip.Prefix      // CIDR ranges (incl. loopback)
}

func newExemptResolver(configDir, scannerFile string) *exemptResolver {
	// NOTE: does NOT Refresh here — the initial load must stay OFF the daemon startup
	// path (Refresh touches /proc, files, and host detection; it must never gate the
	// daemon reaching READY). EnableExemptionGuard warms it in a goroutine; IsExempt
	// also lazily refreshes on first use. Until first load, IsExempt returns
	// NOT-exempt (fail-safe: bans proceed; rule order still protects).
	return &exemptResolver{
		configDir:   configDir,
		scannerFile: scannerFile,
		ttl:         30 * time.Second,
		exact:       map[string]struct{}{},
	}
}

// canonPrefix returns p in the SAME canonical identity form the exact keys use.
// An IPv4-mapped IPv6 prefix ("::ffff:203.0.113.0/120") is rewritten to its IPv4
// equivalent ("203.0.113.0/24") so that a canonicalized (unmapped) lookup address
// compares correctly. Without this, canonicalizing only the lookup side would move
// the mismatch instead of removing it. Non-mapped prefixes are returned unchanged.
func canonPrefix(p netip.Prefix) netip.Prefix {
	if p.Addr().Is4In6() && p.Bits() >= 96 {
		if c := netip.PrefixFrom(p.Addr().Unmap(), p.Bits()-96); c.IsValid() {
			return c
		}
	}
	return p
}

// IsExempt reports whether ipStr (a single IP literal) must never be banned, plus a
// short reason. Returns false for non-single-IP inputs (CIDR ban requests are not the
// admin/session class this guard protects). Range-aware, v4+v6, and IPv4-mapped-IPv6
// aware: the input is canonicalized before any membership comparison.
func (r *exemptResolver) IsExempt(ipStr string) (bool, string) {
	addr, err := netip.ParseAddr(strings.TrimSpace(ipStr))
	if err != nil {
		return false, ""
	}
	// CANONICAL IDENTITY BEFORE THE SECURITY DECISION.
	//
	// The store canonicalizes every exact key with Unmap() (see :addExact); the
	// lookup did not. An IPv4-mapped IPv6 form of an exempt address therefore
	// missed BOTH membership paths and the ban proceeded:
	//
	//   stored key                 "203.0.113.5"
	//   addr.String()              "::ffff:203.0.113.5"  -> exact MISS
	//   v4prefix.Contains(mapped)   false (family mismatch) -> cidr MISS
	//
	// That is a never-ban BYPASS at the authority itself, not a downstream
	// suppression gap: Ban(), IsExempt() and the AddElement guard all resolve
	// through this one function, so all three inherited the miss.
	//
	// Canonicalizing here — once, at the parse boundary, before any comparison —
	// fixes every consumer rather than patching each membership path. Prefixes are
	// canonicalized to the same form at store time (see canonPrefix), because
	// comparing a canonical address against a non-canonical prefix would simply
	// move the mismatch: a stored "::ffff:203.0.113.0/120" Contains() the mapped
	// form but NOT the unmapped one, so unmapping only here would have broken a
	// case that previously worked.
	addr = addr.Unmap()
	r.maybeRefresh()

	r.mu.RLock()
	defer r.mu.RUnlock()
	if _, ok := r.exact[addr.String()]; ok {
		return true, "exact"
	}
	for _, p := range r.prefixes {
		if p.Contains(addr) {
			return true, "cidr"
		}
	}
	return false, ""
}

// =============================================================================
// P1S-A — PREFIX-AWARE NEVER-BAN AUTHORITY (v1.231.0)
// =============================================================================
//
// WHY A SECOND METHOD EXISTS, AND WHY IsExempt COULD NOT BE REUSED.
//
// IsExempt answers "is THIS ADDRESS exempt". Every bulk producer of
// blacklist_ipv4/_ipv6 content emits PREFIXES, never addresses:
// cmd/nftband/daemon_handlers_sync.go rewrites every feed single IP to "<ip>/32"
// before the unified replace, geoban is CIDR-native, and blacklist.d CIDRs are
// CIDRs by definition. IsExempt returns false for all of them (it fails the
// netip.ParseAddr at :89), so dropping an IsExempt call into the unified replace
// loop would have been a NO-OP that merely looked like a guard.
//
// Making IsExempt itself prefix-aware was REJECTED: IsExempt is also the input to
// Backend.Ban and to exemptAddRejection, where a true answer REFUSES the whole
// operation. A wide feed prefix containing one admin IP would then be refused
// outright — a denial of service caused by the exemption itself, and a silent
// regression for the legitimate "add a CIDR to an enforcement set" path.
//
// So the prefix question gets its own answer with its own remedy: SUBTRACT the
// exempt address space from the prefix and keep the rest. The exempt snapshot,
// its TTL, its canonicalisation and its fail-safe semantics are shared with
// IsExempt — there is exactly ONE exemption source.

// maxSplitPerPrefix bounds the output of a single subtraction. Splitting a prefix
// around k holes costs O(k * prefixlen) output prefixes, so a pathological input
// (a very wide IPv6 prefix riddled with exempt singletons) could otherwise
// allocate without bound on a path that already accepts up to 1M feed CIDRs.
// Exceeding the bound DROPS the input prefix rather than emitting it: the
// invariant that nothing covering an exempt address reaches a drop set is
// absolute, and the bound is far above anything a real exempt snapshot produces.
const maxSplitPerPrefix = 4096

// SubtractExempt removes never-ban-exempt address space from a list of elements
// destined for an enforcement (drop) set.
//
// Each input is kept, split, or dropped:
//   - covers no exempt address      -> kept VERBATIM (the original string, untouched)
//   - covers some exempt addresses  -> SPLIT into the minimal set of prefixes that
//     cover the input minus the exempt addresses
//   - is entirely exempt (an exempt /32, or any prefix inside an exempt CIDR)
//     -> dropped, emitting nothing
//
// removed counts INPUT elements that covered exempt space and were therefore split
// or dropped. It is not the number of addresses withheld and not the number of
// output prefixes; it is the count a silent regression would drive to zero.
//
// FAIL-SAFE (this must never block a legitimate feed load): a nil resolver, an
// empty input, a snapshot that has never loaded, or a snapshot with nothing in it
// all subtract NOTHING and return the input unchanged. There is no error return —
// a resolver problem degrades to the pre-existing behaviour, never to a refusal.
//
// Accepts both "a.b.c.d/nn" and a bare "a.b.c.d"; an input it cannot parse is
// passed through untouched for the downstream CIDR filter to reject or keep.
// v4 + v6 parity, and IPv4-mapped-IPv6 inputs are canonicalised through the same
// canonPrefix the snapshot is stored with — but a mapped input that gets split is
// re-emitted in mapped form, because the caller has already routed it to the v6
// set and rewriting its family there would corrupt the element.
func (r *exemptResolver) SubtractExempt(cidrs []string) ([]string, int) {
	if r == nil || len(cidrs) == 0 {
		return cidrs, 0
	}
	r.maybeRefresh()

	r.mu.RLock()
	loaded := r.loaded
	holes := make([]netip.Prefix, 0, len(r.exact)+len(r.prefixes))
	for ip := range r.exact {
		a, err := netip.ParseAddr(ip)
		if err != nil {
			continue
		}
		a = a.Unmap()
		holes = append(holes, netip.PrefixFrom(a, a.BitLen()))
	}
	holes = append(holes, r.prefixes...)
	r.mu.RUnlock()

	if !loaded || len(holes) == 0 {
		return cidrs, 0
	}

	kept := make([]string, 0, len(cidrs))
	removed := 0
	for _, raw := range cidrs {
		p, mapped, ok := parseElementPrefix(raw)
		if !ok {
			kept = append(kept, raw)
			continue
		}
		if !anyHoleInside(p, holes) && !anyHoleCovers(p, holes) {
			// FAST PATH — and the ONLY path that reaches the kernel byte-for-byte
			// as the producer wrote it. Never re-render an element we did not change.
			kept = append(kept, raw)
			continue
		}
		removed++
		var out []netip.Prefix
		subtractPrefix(p, holes, &out)
		if len(out) > maxSplitPerPrefix {
			continue
		}
		for _, q := range out {
			kept = append(kept, formatElement(q, mapped))
		}
	}
	return kept, removed
}

// parseElementPrefix canonicalises one set element into the identity form the
// exempt snapshot uses. wasMapped records that the caller's element was
// IPv4-mapped-IPv6 so a split can be re-emitted in the family the caller routed it
// to.
func parseElementPrefix(s string) (p netip.Prefix, wasMapped, ok bool) {
	s = strings.TrimSpace(s)
	if s == "" {
		return netip.Prefix{}, false, false
	}
	if strings.Contains(s, "/") {
		q, err := netip.ParsePrefix(s)
		if err != nil {
			return netip.Prefix{}, false, false
		}
		c := canonPrefix(q)
		return c, q.Addr().Is4In6() && c.Addr().Is4(), c.IsValid()
	}
	a, err := netip.ParseAddr(s)
	if err != nil {
		return netip.Prefix{}, false, false
	}
	mapped := a.Is4In6()
	a = a.Unmap()
	return netip.PrefixFrom(a, a.BitLen()), mapped, true
}

// formatElement renders a subtraction result, restoring IPv4-mapped-IPv6 form when
// the input carried it.
func formatElement(p netip.Prefix, remap bool) string {
	if remap && p.Addr().Is4() {
		if m := netip.PrefixFrom(netip.AddrFrom16(p.Addr().As16()), p.Bits()+96); m.IsValid() {
			return m.String()
		}
	}
	return p.String()
}

// anyHoleCovers reports whether some hole contains p ENTIRELY (p is wholly exempt).
func anyHoleCovers(p netip.Prefix, holes []netip.Prefix) bool {
	for _, h := range holes {
		if h.Bits() <= p.Bits() && h.Contains(p.Addr()) {
			return true
		}
	}
	return false
}

// anyHoleInside reports whether some hole lies strictly INSIDE p (p must be split).
func anyHoleInside(p netip.Prefix, holes []netip.Prefix) bool {
	for _, h := range holes {
		if p.Bits() < h.Bits() && p.Contains(h.Addr()) {
			return true
		}
	}
	return false
}

// subtractPrefix appends to out the minimal prefix cover of p minus every hole.
// Two prefixes are either disjoint or nested, so at each step p is wholly exempt
// (emit nothing), wholly clean (emit p), or straddling (halve and recurse).
// Recursion is bounded by p.Addr().BitLen() — 32 for IPv4, 128 for IPv6.
func subtractPrefix(p netip.Prefix, holes []netip.Prefix, out *[]netip.Prefix) {
	if anyHoleCovers(p, holes) {
		return
	}
	if !anyHoleInside(p, holes) {
		*out = append(*out, p)
		return
	}
	lo, hi, ok := splitPrefix(p)
	if !ok {
		// Cannot narrow further yet a hole is reportedly inside: withhold rather
		// than emit. Unreachable for well-formed prefixes; fails toward the
		// never-ban invariant, not away from it.
		return
	}
	subtractPrefix(lo, holes, out)
	subtractPrefix(hi, holes, out)
}

// splitPrefix halves p into its two immediate sub-prefixes.
func splitPrefix(p netip.Prefix) (netip.Prefix, netip.Prefix, bool) {
	newBits := p.Bits() + 1
	if newBits > p.Addr().BitLen() {
		return netip.Prefix{}, netip.Prefix{}, false
	}
	lo := netip.PrefixFrom(p.Addr(), newBits)
	raw := p.Addr().AsSlice() // fresh slice; safe to mutate
	idx := (newBits - 1) / 8
	if idx >= len(raw) {
		return netip.Prefix{}, netip.Prefix{}, false
	}
	raw[idx] |= byte(1) << (7 - uint((newBits-1)%8))
	hiAddr, ok := netip.AddrFromSlice(raw)
	if !ok {
		return netip.Prefix{}, netip.Prefix{}, false
	}
	hi := netip.PrefixFrom(hiAddr, newBits)
	if !lo.IsValid() || !hi.IsValid() {
		return netip.Prefix{}, netip.Prefix{}, false
	}
	return lo, hi, true
}

func (r *exemptResolver) maybeRefresh() {
	r.mu.RLock()
	fresh := r.loaded && time.Since(r.loadedAt) <= r.ttl
	r.mu.RUnlock()
	if !fresh {
		r.Refresh()
	}
}

// Refresh rebuilds the exemption snapshot from all sources. Each source is best-effort;
// a source error contributes nothing and never aborts the rebuild. The snapshot is
// swapped atomically; the scanner file is then published best-effort.
func (r *exemptResolver) Refresh() {
	exact := make(map[string]struct{})
	var prefixes []netip.Prefix

	addIP := func(ip net.IP) {
		if ip == nil {
			return
		}
		if a, ok := netip.AddrFromSlice(ip); ok {
			exact[a.Unmap().String()] = struct{}{}
		}
	}
	addEntry := func(value string, isCIDR bool) {
		value = strings.TrimSpace(value)
		if value == "" {
			return
		}
		if isCIDR || strings.Contains(value, "/") {
			if p, err := netip.ParsePrefix(value); err == nil {
				prefixes = append(prefixes, canonPrefix(p))
			}
			return
		}
		if a, err := netip.ParseAddr(value); err == nil {
			exact[a.Unmap().String()] = struct{}{}
		}
	}

	// 1. whitelist.d (operator 99-manual, live-session 00-session, system 00-system) — CIDR-aware.
	if r.configDir != "" {
		if v4, v6, err := whitelist.LoadAllWhitelistsTyped(r.configDir); err == nil {
			for _, m := range []map[string]whitelist.WhitelistEntry{v4, v6} {
				for _, e := range m {
					addEntry(e.Value, e.IsCIDR)
				}
			}
		}
	}

	// 2. System IPs that must never be blocked (server/gateway/dns/loopback/current-SSH).
	if sys, err := safety.DetectSystemIPs(); err == nil && sys != nil {
		for _, ip := range sys.ServerIPs {
			addIP(ip)
		}
		for _, ip := range sys.GatewayIPs {
			addIP(ip)
		}
		for _, ip := range sys.DNSServers {
			addIP(ip)
		}
		addIP(sys.CurrentUserIP)
		for i := range sys.LoopbackCIDRs {
			c := sys.LoopbackCIDRs[i]
			if p, err := netip.ParsePrefix(c.String()); err == nil {
				prefixes = append(prefixes, canonPrefix(p))
			}
		}
	}

	// 3. Live established inbound SSH peers — protects whoever is connected right now,
	//    even if not whitelisted (the strongest lockout guard).
	for _, ip := range detectActiveSSHPeers() {
		if a, err := netip.ParseAddr(ip); err == nil {
			exact[a.Unmap().String()] = struct{}{}
		}
	}

	// 4. Optional explicit operator management IPs/CIDRs.
	for _, tok := range strings.FieldsFunc(os.Getenv("NFTBAN_MANAGEMENT_IPS"), func(r rune) bool {
		return r == ',' || r == ' ' || r == '\t' || r == '\n'
	}) {
		addEntry(tok, strings.Contains(tok, "/"))
	}

	r.mu.Lock()
	// Fail-safe: only overwrite a good snapshot if we resolved at least something OR we
	// never loaded before. (An all-empty rebuild after a previously-populated snapshot
	// likely means a transient source failure — keep the last good set so admin
	// protection doesn't silently vanish.)
	if len(exact) > 0 || len(prefixes) > 0 || !r.loaded {
		r.exact = exact
		r.prefixes = prefixes
		r.loaded = true
		r.loadedAt = time.Now()
	} else {
		r.loadedAt = time.Now() // defer next retry by ttl; keep old snapshot
	}
	snapExact := r.exact
	snapPrefixes := r.prefixes
	r.mu.Unlock()

	r.writeScannerFile(snapExact, snapPrefixes)
}

// writeScannerFile publishes the resolved exempt list (one CIDR/IP per line) to a
// 0640 nftban-readable file so the unprivileged BotScan scanner can suppress signals
// without needing nft read. Best-effort; never fatal.
func (r *exemptResolver) writeScannerFile(exact map[string]struct{}, prefixes []netip.Prefix) {
	if r.scannerFile == "" {
		return
	}
	var b strings.Builder
	b.WriteString("# NFTBan never-ban exemption list (generated by nftband; do not edit)\n")
	for ip := range exact {
		b.WriteString(ip)
		b.WriteByte('\n')
	}
	for _, p := range prefixes {
		b.WriteString(p.String())
		b.WriteByte('\n')
	}
	// safety.SafeWriteFile is the project durability idiom (atomic temp+fsync+rename;
	// also satisfies the FSYNC-RESIDUAL guard). perm 0644 so the unprivileged BotScan
	// scanner (User=nftban) can read this as "other": the daemon runs as root WITHOUT
	// CAP_CHOWN (CapabilityBoundingSet = CAP_NET_ADMIN,CAP_DAC_OVERRIDE) so it cannot
	// chown to nftban. The parent dir /var/lib/nftban/botscan is 0750 nftban:nftban,
	// which already gates access to nftban+root only — no other local user can traverse
	// in — so 0644 here does NOT expose the (non-secret, whitelist/admin) IP list
	// further. Best-effort; the daemon guard is the authority regardless.
	_ = safety.SafeWriteFile(r.scannerFile, []byte(b.String()), 0o644)
}

// detectActiveSSHPeers returns the remote IPs of currently-ESTABLISHED inbound
// connections whose local port is an SSH listening port. Pure-Go via /proc/net/tcp{,6}
// (root-readable); returns nil on any error.
func detectActiveSSHPeers() []string {
	ports := sshListenPorts()
	if len(ports) == 0 {
		return nil
	}
	var peers []string
	for _, path := range []string{"/proc/net/tcp", "/proc/net/tcp6"} {
		peers = append(peers, parseProcNetTCP(path, ports)...)
	}
	return peers
}

// sshListenPorts returns the set of SSH ports (default 22 + any `Port` in sshd_config
// and sshd_config.d/*.conf). Match blocks/Include subtleties are ignored — over-
// inclusion only widens exemption (safe; never widens accept).
func sshListenPorts() map[uint16]struct{} {
	ports := map[uint16]struct{}{22: {}}
	files := []string{"/etc/ssh/sshd_config"}
	if extra, err := filepath.Glob("/etc/ssh/sshd_config.d/*.conf"); err == nil {
		files = append(files, extra...)
	}
	for _, f := range files {
		fh, err := os.Open(filepath.Clean(f)) // #nosec G304 -- fixed sshd config paths
		if err != nil {
			continue
		}
		sc := bufio.NewScanner(fh)
		for sc.Scan() {
			line := strings.TrimSpace(sc.Text())
			if len(line) < 5 || line[0] == '#' {
				continue
			}
			if !strings.HasPrefix(strings.ToLower(line), "port") {
				continue
			}
			fields := strings.Fields(line)
			if len(fields) >= 2 && strings.EqualFold(fields[0], "Port") {
				if p, err := strconv.ParseUint(fields[1], 10, 16); err == nil && p > 0 {
					ports[uint16(p)] = struct{}{}
				}
			}
		}
		_ = fh.Close()
	}
	return ports
}

// parseProcNetTCP parses /proc/net/tcp{,6} and returns remote IPs of ESTABLISHED
// connections (st==01) whose local port is in ports.
func parseProcNetTCP(path string, ports map[uint16]struct{}) []string {
	fh, err := os.Open(filepath.Clean(path)) // #nosec G304 -- fixed /proc paths
	if err != nil {
		return nil
	}
	defer func() { _ = fh.Close() }()

	var out []string
	sc := bufio.NewScanner(fh)
	first := true
	for sc.Scan() {
		if first { // header
			first = false
			continue
		}
		fields := strings.Fields(sc.Text())
		if len(fields) < 4 {
			continue
		}
		if fields[3] != "01" { // 01 = TCP_ESTABLISHED
			continue
		}
		localPort, ok := hexPort(fields[1])
		if !ok {
			continue
		}
		if _, want := ports[localPort]; !want {
			continue
		}
		if remIP, ok := hexAddrIP(fields[2]); ok {
			out = append(out, remIP)
		}
	}
	return out
}

// hexPort parses the "ADDR:PORT" hex local/remote field's port part.
func hexPort(field string) (uint16, bool) {
	i := strings.LastIndexByte(field, ':')
	if i < 0 {
		return 0, false
	}
	p, err := strconv.ParseUint(field[i+1:], 16, 16)
	if err != nil {
		return 0, false
	}
	return uint16(p), true
}

// hexAddrIP parses the "ADDR:PORT" hex address part into a canonical IP string.
// IPv4 addr is 8 hex chars (little-endian); IPv6 is 32 hex chars (4 LE words).
func hexAddrIP(field string) (string, bool) {
	i := strings.LastIndexByte(field, ':')
	if i < 0 {
		return "", false
	}
	raw := field[:i]
	b, err := hex.DecodeString(raw)
	if err != nil {
		return "", false
	}
	switch len(b) {
	case 4: // IPv4 stored little-endian → network-order IP is the reversed bytes
		ip := net.IPv4(b[3], b[2], b[1], b[0])
		if a, ok := netip.AddrFromSlice(ip.To4()); ok {
			return a.String(), true
		}
	case 16: // IPv6, four little-endian 32-bit words
		ipb := make([]byte, 16)
		for w := 0; w < 4; w++ {
			word := binary.LittleEndian.Uint32(b[w*4 : w*4+4])
			binary.BigEndian.PutUint32(ipb[w*4:w*4+4], word)
		}
		if a, ok := netip.AddrFromSlice(ipb); ok {
			return a.Unmap().String(), true
		}
	}
	return "", false
}
