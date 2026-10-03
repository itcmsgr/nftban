// =============================================================================
// NFTBan v1.234.0 - BotScan shared CDN edge guard (daemon apply boundary)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// Package: botguard
// Purpose: Never apply a BotScan ban to an address inside a published CDN edge /
//          platform egress range (BUG-BOTSCAN-BANS-CDN-EDGE-IPS-WHEN-WEB-LOG-RECORDS-PROXY-ADDRESS).
//          When a web server behind a CDN does not restore the real client IP, the access
//          log records the EDGE as the client; banning it drops every visitor routed through
//          it. The shell scanner already skips such signals; this is the second, authoritative
//          check at the apply boundary (it also covers signals written before an upgrade).
//          It is a refusal in the BotScan path only: nothing is whitelisted or accepted by the
//          firewall and no other detector is affected.
//
// meta:name="botguard_botscan_shared_edge"
// meta:type="library"
// meta:version="1.0.0"
// meta:package="botguard"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-01"
// meta:description="Shared CDN edge range set (packaged snapshot + optional trust cache) consulted before any BotScan batch-signal ban is applied"
// meta:inventory.files="botscan_shared_edge.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/usr/lib/nftban/data/botscan_shared_edges.tsv"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package botguard

import (
	"bufio"
	"net/netip"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// DefaultSharedEdgeFiles: the packaged snapshot first (always present, works offline),
// then newer published lists fetched by `nftban trust` (optional, read-only).
func DefaultSharedEdgeFiles() []string {
	return []string{
		"/usr/lib/nftban/data/botscan_shared_edges.tsv",
		"/var/cache/nftban/trust/cloudflare-ipv4.txt",
		"/var/cache/nftban/trust/cloudflare-ipv6.txt",
		"/var/cache/nftban/trust/fastly-ipv4.txt",
		"/var/cache/nftban/trust/fastly-ipv6.txt",
		"/var/cache/nftban/trust/quiccloud-ipv4.txt",
	}
}

type edgePrefix struct {
	p     netip.Prefix
	label string
}

// sharedEdgeSet is reloaded when any source file's mtime/size changes.
type sharedEdgeSet struct {
	mu       sync.Mutex
	files    []string
	stamp    string
	prefixes []edgePrefix
}

func newSharedEdgeSet(files []string) *sharedEdgeSet {
	return &sharedEdgeSet{files: files}
}

func (s *sharedEdgeSet) currentStamp() string {
	var b strings.Builder
	for _, f := range s.files {
		if st, err := os.Stat(f); err == nil {
			b.WriteString(f)
			b.WriteByte('|')
			b.WriteString(st.ModTime().Format(time.RFC3339Nano))
			b.WriteByte('|')
			b.WriteString(strconv.FormatInt(st.Size(), 10))
		}
		b.WriteByte(';')
	}
	return b.String()
}

// admitEdgePrefix applies the same admission rule as the shell (v4 >= /8, v6 >= /16):
// an over-broad entry must never exempt the whole address space.
func admitEdgePrefix(cidr string) (netip.Prefix, bool) {
	p, err := netip.ParsePrefix(strings.TrimSpace(cidr))
	if err != nil {
		return netip.Prefix{}, false
	}
	p = p.Masked()
	if p.Addr().Is4() && p.Bits() < 8 {
		return netip.Prefix{}, false
	}
	if p.Addr().Is6() && p.Bits() < 16 {
		return netip.Prefix{}, false
	}
	return p, true
}

func (s *sharedEdgeSet) reloadLocked() {
	var out []edgePrefix
	for _, f := range s.files {
		fh, err := os.Open(filepath.Clean(f)) // #nosec G304 -- fixed package/cache paths from config
		if err != nil {
			continue
		}
		sc := bufio.NewScanner(fh)
		base := filepath.Base(f)
		for sc.Scan() {
			line := sc.Text()
			if i := strings.IndexByte(line, '#'); i >= 0 {
				line = line[:i]
			}
			line = strings.TrimSpace(line)
			if line == "" {
				continue
			}
			label := base
			cidr := line
			if fields := strings.Split(line, "\t"); len(fields) == 3 {
				label = fields[0] + " " + fields[1]
				cidr = fields[2]
			}
			if p, ok := admitEdgePrefix(cidr); ok {
				out = append(out, edgePrefix{p: p, label: label + " " + p.String()})
			}
		}
		_ = fh.Close()
	}
	s.prefixes = out
}

// Match reports whether ip is inside a shared-edge range (IPv4-mapped IPv6 is unmapped).
func (s *sharedEdgeSet) Match(ip netip.Addr) (string, bool) {
	if s == nil {
		return "", false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if st := s.currentStamp(); st != s.stamp {
		s.reloadLocked()
		s.stamp = st
	}
	ip = ip.Unmap()
	for _, e := range s.prefixes {
		if e.p.Contains(ip) {
			return e.label, true
		}
	}
	return "", false
}

// Size returns the number of loaded ranges (0 = no data: edges NOT protected).
func (s *sharedEdgeSet) Size() int {
	if s == nil {
		return 0
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if st := s.currentStamp(); st != s.stamp {
		s.reloadLocked()
		s.stamp = st
	}
	return len(s.prefixes)
}

// botscanSharedEdgeSkip returns true (and logs + counts the visible reason) when a BotScan
// signal targets a shared CDN edge and must NOT be applied.
func (m *Module) botscanSharedEdgeSkip(sig *BatchSignal, ip netip.Addr) bool {
	m.sharedEdgesOnce.Do(func() {
		files := DefaultSharedEdgeFiles()
		if m.config != nil && len(m.config.SharedEdgeFiles) > 0 {
			files = m.config.SharedEdgeFiles
		}
		m.sharedEdges = newSharedEdgeSet(files)
	})
	if m.sharedEdges.Size() == 0 {
		// No range data readable by the daemon (missing file, or a confinement denial on an
		// enforcing host): the daemon-side refusal is inactive. The scanner's own guard still
		// runs before any signal is written. Say so once instead of failing silently.
		m.sharedEdgesWarnOnce.Do(func() {
			if m.logger != nil {
				m.logger.LogEvent("WARN", "botscan shared-edge ranges UNMEASURED in the daemon (no readable data in "+
					strings.Join(m.sharedEdges.files, ", ")+"): daemon-side CDN edge refusal inactive; the scanner-side guard still applies")
			}
		})
		return false
	}
	label, ok := m.sharedEdges.Match(ip)
	if !ok {
		return false
	}
	m.mu.Lock()
	m.stats.BatchSignalsSharedEdgeSkipped++
	m.mu.Unlock()
	reason := ""
	if sig != nil && len(sig.Reasons) > 0 {
		reason = strings.Join(sig.Reasons, "; ")
	}
	if m.logger != nil {
		m.logger.LogEvent("WARN", "botscan ban skipped: "+ip.String()+" is a shared CDN edge ("+label+
			"); the web log records the proxy, not the client; configure real-IP restoration in the web server — "+reason)
	}
	return true
}
