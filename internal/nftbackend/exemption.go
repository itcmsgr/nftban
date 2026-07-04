// NFTBan - durable apply-boundary never-ban exemption guard
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
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

// IsExempt reports whether ipStr (a single IP literal) must never be banned, plus a
// short reason. Returns false for non-single-IP inputs (CIDR ban requests are not the
// admin/session class this guard protects). Range-aware, v4+v6.
func (r *exemptResolver) IsExempt(ipStr string) (bool, string) {
	addr, err := netip.ParseAddr(strings.TrimSpace(ipStr))
	if err != nil {
		return false, ""
	}
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
				prefixes = append(prefixes, p)
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
				prefixes = append(prefixes, p)
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
