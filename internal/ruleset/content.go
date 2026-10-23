// =============================================================================
// NFTBan - Ruleset content: the set elements a reload/rebuild loads in ONE transaction
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="ruleset"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-22"
// meta:description="Renders the derived and carried set elements that a firewall reload/rebuild appends to the rendered schema so the whole replacement is one nft transaction (v1.236 Stage 2, plan §11.2 / design §9.6)"
// meta:inventory.files="/etc/nftban/whitelist.d/*.conf,/etc/nftban/blacklist.d/*.conf,/etc/nftban/geoban.d/*.conf,/var/lib/nftban/feeds/*.txt,/var/lib/nftban/trust/*.txt"
// meta:inventory.binaries="nft"
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/nftban.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
//
// Why: the rendered schema (install/nftables/nftables.conf.tpl) starts with
// `delete table ip/ip6 nftban` and declares every set EMPTY. Loading it alone emptied
// every ban and feed set until later steps refilled them: measured on lab2 2026-10-22,
// banned sources were admitted during update, reload and rebuild. Appending the set
// contents to the SAME file makes the kernel go from the old complete state to the new
// complete state in one commit (nft -f is one netlink batch; a rejected file changes
// nothing: txscale T3).
//
// What is rendered vs carried (design §9.6, step A):
//   - whitelist_*: whitelist.d (durable, incl. system IPs and timed entries with
//     remaining lifetime) + kernel elements with a timeout (runtime) + kernel permanent
//     elements covered by a trust cache file. Other kernel-only permanent whitelist
//     entries are NOT carried: a removed whitelist.d entry must disappear.
//   - blacklist_manual_*: blacklist.d single IPs + every kernel element (kernel-only
//     permanent bans and timed bans with remaining TTL); blacklist.d permanence wins.
//   - blacklist_*: union of feed files, geoban.d and blacklist.d CIDRs (as the daemon's
//     full sync builds it) + kernel elements with a timeout.
//   - http_bot_*, port_allow_*: every kernel element, remaining TTL.
//   - never-ban: every element bound for a drop set passes the same authority Ban() uses.
//   - port sets, ssh_ports, forwarding sets: rendered by the schema itself, not here.
//   - meters / connlimit sets: dynamic, reset (stated).
// Remaining TTL is computed from the read and shortened by Options.CommitMargin, so a
// carried element never outlives its original expiry.
// =============================================================================

package ruleset

import (
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/feeds"
	"github.com/itcmsgr/nftban/internal/geoban"
	"github.com/itcmsgr/nftban/internal/netutil"
	"github.com/itcmsgr/nftban/internal/runtime"
	nftsync "github.com/itcmsgr/nftban/internal/setsync"
)

// Exemption is the never-ban authority (nftbackend.NewExemption).
type Exemption interface {
	IsExempt(ip string) (bool, string)
	SubtractExempt(cidrs []string) (kept []string, removed int, omitted []string)
}

// Element is one kernel set element as read back. Remaining is the time left before
// it expires (0 with HasTimeout=false = permanent).
type Element struct {
	Key        string // nft syntax: "1.2.3.4", "10.0.0.0/8", "a-b", "1.2.3.4 . 443"
	HasTimeout bool
	Remaining  time.Duration
}

// SetReader reads one kernel set (family "ip"/"ip6", table "nftban"). A set that does
// not exist returns (nil, nil).
type SetReader func(family, set string) ([]Element, error)

// Options configures one render.
type Options struct {
	ConfigDir string
	DataDir   string
	// CommitMargin is subtracted from every carried remaining TTL (the time between the
	// read and the commit); an element with less than CommitMargin left is dropped.
	CommitMargin time.Duration
	// MaxElements refuses the render (ErrOversized) above this many elements; 0 = no limit.
	MaxElements int
}

// ErrOversized is returned before anything is rendered when the replacement would exceed
// Options.MaxElements (design §9.4: refuse before mutation; existing protection untouched).
var ErrOversized = fmt.Errorf("ruleset content exceeds the supported transaction size")

// Result is the rendered content plus its accounting.
type Result struct {
	Script   string         // `add element` statements, ready to append to the schema
	Counts   map[string]int // elements per "family/set"
	Elements int
	Carried  int // elements taken from the kernel
	Expired  int // kernel elements dropped (expired, or less than CommitMargin left)
	Exempt   int // elements refused by the never-ban authority
	// Omitted are union inputs dropped WHOLE at the exemption split limit (a gap, named).
	Omitted []string
}

type family struct {
	name   string // "ip" / "ip6"
	suffix string // "ipv4" / "ipv6"
	v4     bool
}

var families = []family{{"ip", "ipv4", true}, {"ip6", "ipv6", false}}

// carriedTimedSets are carried whole from the kernel (runtime-only state).
var carriedTimedSets = map[bool][]string{
	true:  {"http_bot_suspect", "http_bot_pending", "http_bot_allow", "http_bot_grey", "http_bot_ban", "http_bot_emergency", "port_allow_tcp_ipv4", "port_allow_udp_ipv4"},
	false: {"http_bot_suspect6", "http_bot_pending6", "http_bot_allow6", "http_bot_grey6", "http_bot_ban6", "http_bot_emergency6", "port_allow_tcp_ipv6", "port_allow_udp_ipv6"},
}

// dropSets are the carried sets whose elements block traffic: never-ban applies.
var dropSets = map[string]bool{
	"http_bot_ban": true, "http_bot_emergency": true, "http_bot_ban6": true, "http_bot_emergency6": true,
}

// Render builds the content. read must reflect the kernel at the moment of the call.
func Render(opts Options, read SetReader, ex Exemption) (*Result, error) {
	res := &Result{Counts: map[string]int{}}
	var script strings.Builder

	state := runtime.NewRuntimeState(opts.ConfigDir)
	if err := state.LoadWhitelists(); err != nil {
		return nil, fmt.Errorf("load whitelists: %w", err)
	}
	if err := state.LoadBlacklists(); err != nil {
		return nil, fmt.Errorf("load blacklists: %w", err)
	}
	wl4, wl6, wlExpiry := state.GetWhitelistSnapshotWithExpiry()
	bl4, bl6 := state.GetBlacklistSnapshot()

	unionV4, unionV6, err := durableUnion(opts, bl4, bl6)
	if err != nil {
		return nil, err
	}
	trust := trustPrefixes(filepath.Join(opts.DataDir, "trust"))
	now := time.Now()

	type plan struct {
		fam  family
		set  string
		keys []string
	}
	var plans []plan
	total := 0
	add := func(f family, set string, keys []string) {
		if len(keys) == 0 {
			return
		}
		plans = append(plans, plan{f, set, keys})
		total += len(keys)
	}

	for _, f := range families {
		wl, bl, union := wl4, bl4, unionV4
		if !f.v4 {
			wl, bl, union = wl6, bl6, unionV6
		}

		// whitelist_*: durable first; runtime timed + trust-covered permanent from the kernel.
		wset := "whitelist_" + f.suffix
		keyed := map[string]string{}
		for _, ip := range wl {
			if exp, ok := wlExpiry[ip]; ok {
				left := exp.Sub(now) - opts.CommitMargin
				if left < time.Second {
					res.Expired++
					continue
				}
				keyed[ip] = withTimeout(ip, left)
				continue
			}
			keyed[ip] = ip
		}
		kernel, err := read(f.name, wset)
		if err != nil {
			return nil, fmt.Errorf("read %s %s: %w", f.name, wset, err)
		}
		for _, e := range kernel {
			if _, durable := keyed[e.Key]; durable {
				continue
			}
			switch {
			case e.HasTimeout:
				if v, ok := carry(e, opts.CommitMargin, res); ok {
					keyed[e.Key] = v
				}
			case coveredBy(e.Key, trust):
				keyed[e.Key] = e.Key
				res.Carried++
			}
		}
		add(f, wset, values(keyed))

		// blacklist_manual_*: blacklist.d singles (permanent) + every kernel element.
		mset := "blacklist_manual_" + f.suffix
		singles, _ := splitCIDRs(bl)
		keyed = map[string]string{}
		for _, ip := range singles {
			if reject, _ := netutil.EnforcementClassReject(ip); reject {
				res.Exempt++
				continue
			}
			if ok, _ := ex.IsExempt(ip); ok {
				res.Exempt++
				continue
			}
			keyed[ip] = ip
		}
		kernel, err = read(f.name, mset)
		if err != nil {
			return nil, fmt.Errorf("read %s %s: %w", f.name, mset, err)
		}
		for _, e := range kernel {
			if _, durable := keyed[e.Key]; durable {
				continue // blacklist.d permanence wins over a kernel timed copy (H11)
			}
			if ok, _ := ex.IsExempt(e.Key); ok {
				res.Exempt++
				continue
			}
			if v, ok := carry(e, opts.CommitMargin, res); ok {
				keyed[e.Key] = v
			}
		}
		add(f, mset, values(keyed))

		// blacklist_*: the durable union + kernel timed elements (never-ban subtracted).
		bset := "blacklist_" + f.suffix
		kept, removed, omitted := ex.SubtractExempt(union)
		res.Exempt += removed
		res.Omitted = append(res.Omitted, omitted...)
		canon, _, err := nftsync.CanonicalCIDRElements(kept)
		if err != nil {
			return nil, fmt.Errorf("%s union: %w", bset, err)
		}
		keyed = map[string]string{}
		for _, c := range canon {
			keyed[c] = c
		}
		kernel, err = read(f.name, bset)
		if err != nil {
			return nil, fmt.Errorf("read %s %s: %w", f.name, bset, err)
		}
		for _, e := range kernel {
			if !e.HasTimeout {
				continue // permanent interval elements are re-derived from their sources
			}
			// A range key ("a-b", auto-merged by the kernel) cannot be split here; it is
			// carried as is. An address or prefix that covers a never-ban address is not.
			if !strings.Contains(e.Key, "-") {
				if _, removed, omitted := ex.SubtractExempt([]string{e.Key}); removed > 0 || len(omitted) > 0 {
					res.Exempt++
					continue
				}
			}
			if v, ok := carry(e, opts.CommitMargin, res); ok {
				keyed[e.Key] = v
			}
		}
		add(f, bset, values(keyed))

		// Runtime-only sets: carried whole.
		for _, set := range carriedTimedSets[f.v4] {
			kernel, err := read(f.name, set)
			if err != nil {
				return nil, fmt.Errorf("read %s %s: %w", f.name, set, err)
			}
			keyed = map[string]string{}
			for _, e := range kernel {
				if dropSets[set] {
					if ok, _ := ex.IsExempt(e.Key); ok {
						res.Exempt++
						continue
					}
				}
				if v, ok := carry(e, opts.CommitMargin, res); ok {
					keyed[e.Key] = v
				}
			}
			add(f, set, values(keyed))
		}
	}

	if opts.MaxElements > 0 && total > opts.MaxElements {
		return nil, fmt.Errorf("%w: %d elements > limit %d", ErrOversized, total, opts.MaxElements)
	}
	for _, p := range plans {
		writeAdds(&script, p.fam.name, p.set, p.keys)
		res.Counts[p.fam.name+"/"+p.set] = len(p.keys)
		res.Elements += len(p.keys)
	}
	res.Script = script.String()
	return res, nil
}

// durableUnion is the feeds + geoban + blacklist.d CIDR union the daemon's full sync
// loads into blacklist_ipv4/_ipv6 (cmd/nftband/daemon_handlers_sync.go): every feed file
// in <data>/feeds, every geoban.d ban file, every blacklist.d CIDR.
func durableUnion(opts Options, bl4, bl6 []string) (v4, v6 []string, err error) {
	_, cidr4 := splitCIDRs(bl4)
	_, cidr6 := splitCIDRs(bl6)
	v4 = append(v4, cidr4...)
	v6 = append(v6, cidr6...)

	feedsDir := filepath.Join(opts.DataDir, "feeds")
	if entries, rerr := os.ReadDir(feedsDir); rerr == nil && len(entries) > 0 {
		ip4, ip6, cidrs4, cidrs6, _, ferr := feeds.LoadAllFeeds(feedsDir)
		if ferr != nil {
			return nil, nil, fmt.Errorf("load feeds: %w", ferr)
		}
		for ip := range ip4 {
			v4 = append(v4, ip+"/32")
		}
		for c := range cidrs4 {
			v4 = append(v4, c)
		}
		for ip := range ip6 {
			v6 = append(v6, ip+"/128")
		}
		for c := range cidrs6 {
			v6 = append(v6, c)
		}
	}

	geoDir := filepath.Join(opts.ConfigDir, "geoban.d")
	if hasGeobanBanFiles(geoDir) {
		data, gerr := geoban.Build(geoDir, nil)
		if gerr != nil {
			return nil, nil, fmt.Errorf("build geoban: %w", gerr)
		}
		if data != nil {
			v4 = append(v4, data.IPv4...)
			v6 = append(v6, data.IPv6...)
		}
	}
	return v4, v6, nil
}

func hasGeobanBanFiles(dir string) bool {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return false
	}
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), "50-ban-") && strings.HasSuffix(e.Name(), ".conf") {
			return true
		}
	}
	return false
}

// splitCIDRs separates single addresses from CIDR tokens (as the daemon's
// partitionCIDRTokens does for blacklist.d).
func splitCIDRs(items []string) (singles, cidrs []string) {
	for _, it := range items {
		if strings.Contains(it, "/") {
			cidrs = append(cidrs, it)
		} else {
			singles = append(singles, it)
		}
	}
	return singles, cidrs
}

// trustPrefixes reads the trust provider caches (<data>/trust/*.txt, the files the
// daemon's whitelist load_cidrs reads).
func trustPrefixes(dir string) []netip.Prefix {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var out []netip.Prefix
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".txt") {
			continue
		}
		data, err := os.ReadFile(filepath.Join(dir, e.Name())) // #nosec G304 -- fixed NFTBan data dir
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(data), "\n") {
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			if !strings.Contains(line, "/") {
				if a, err := netip.ParseAddr(line); err == nil {
					out = append(out, netip.PrefixFrom(a, a.BitLen()))
				}
				continue
			}
			if p, err := netip.ParsePrefix(line); err == nil {
				out = append(out, p.Masked())
			}
		}
	}
	return out
}

// coveredBy reports whether an element (address or prefix) lies inside one of the prefixes.
func coveredBy(key string, prefixes []netip.Prefix) bool {
	if len(prefixes) == 0 {
		return false
	}
	var p netip.Prefix
	if strings.Contains(key, "/") {
		var err error
		if p, err = netip.ParsePrefix(key); err != nil {
			return false
		}
	} else {
		a, err := netip.ParseAddr(key)
		if err != nil {
			return false
		}
		p = netip.PrefixFrom(a, a.BitLen())
	}
	for _, t := range prefixes {
		if t.Bits() <= p.Bits() && t.Contains(p.Addr()) {
			return true
		}
	}
	return false
}

// carry renders a kernel element with its remaining lifetime shortened by margin.
func carry(e Element, margin time.Duration, res *Result) (string, bool) {
	if !e.HasTimeout {
		res.Carried++
		return e.Key, true
	}
	left := e.Remaining - margin
	if left < time.Second {
		res.Expired++
		return "", false
	}
	res.Carried++
	return withTimeout(e.Key, left), true
}

func withTimeout(key string, left time.Duration) string {
	return fmt.Sprintf("%s timeout %ds", key, int64(left/time.Second))
}

func values(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for _, v := range m {
		out = append(out, v)
	}
	sort.Strings(out)
	return out
}

// writeAdds emits `add element` statements in batches of 10000 (the daemon's set-replace
// batch size, internal/setsync renderSetReplaceScript).
func writeAdds(b *strings.Builder, fam, set string, elems []string) {
	const batch = 10000
	for i := 0; i < len(elems); i += batch {
		j := i + batch
		if j > len(elems) {
			j = len(elems)
		}
		fmt.Fprintf(b, "add element %s nftban %s { %s }\n", fam, set, strings.Join(elems[i:j], ", "))
	}
}
