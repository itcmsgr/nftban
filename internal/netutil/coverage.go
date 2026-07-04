// =============================================================================
// NFTBan - Whitelist range-coverage oracle
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="coverage"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-25"
// meta:description="Range-aware whitelist coverage oracle: single IP / CIDR / nft interval normalized to [start,end] big.Int ranges (IPv4+IPv6) and compared by COVERAGE not strings, so coalesced kernel intervals (e.g. 104.16.0.0/13 + 104.24.0.0/14 == 104.16.0.0-104.27.255.255) are not reported as drift. CLI-only (internal/netutil); does not touch the nftband daemon."
// meta:depends="net,math/big"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package netutil

import (
	"fmt"
	"math/big"
	"net"
	"sort"
	"strings"
)

// IPRange is an inclusive [Start,End] address range within one family (V6 flag).
type IPRange struct {
	Start *big.Int
	End   *big.Int
	V6    bool
}

// ipToBig converts a net.IP to a big.Int (4-byte for IPv4, 16-byte for IPv6).
func ipToBig(ip net.IP) (*big.Int, bool, bool) {
	if ip == nil {
		return nil, false, false
	}
	if v4 := ip.To4(); v4 != nil {
		return new(big.Int).SetBytes(v4), false, true
	}
	if v16 := ip.To16(); v16 != nil {
		return new(big.Int).SetBytes(v16), true, true
	}
	return nil, false, false
}

// ParseRangeToken parses a single IP, a CIDR, or an nft interval ("a-b") into an
// inclusive IPRange. Trailing nft decorations (comment/timeout) must be stripped
// by the caller. Returns an error on anything unparseable.
func ParseRangeToken(tok string) (*IPRange, error) {
	tok = strings.TrimSpace(tok)
	if tok == "" {
		return nil, fmt.Errorf("empty token")
	}
	// Interval "a-b" (nft coalesced form). Guard against IPv6 "::" by requiring
	// no "/" and a '-' that separates two parseable IPs.
	if !strings.Contains(tok, "/") {
		if i := strings.IndexByte(tok, '-'); i > 0 {
			aStr := strings.TrimSpace(tok[:i])
			bStr := strings.TrimSpace(tok[i+1:])
			a := net.ParseIP(aStr)
			b := net.ParseIP(bStr)
			if a != nil && b != nil {
				as, av6, ok1 := ipToBig(a)
				bs, bv6, ok2 := ipToBig(b)
				if !ok1 || !ok2 || av6 != bv6 {
					return nil, fmt.Errorf("interval family mismatch: %q", tok)
				}
				if as.Cmp(bs) > 0 {
					as, bs = bs, as
				}
				return &IPRange{Start: as, End: bs, V6: av6}, nil
			}
		}
	}
	// CIDR
	if strings.Contains(tok, "/") {
		_, ipnet, err := net.ParseCIDR(tok)
		if err != nil {
			return nil, err
		}
		start, v6, ok := ipToBig(ipnet.IP)
		if !ok {
			return nil, fmt.Errorf("bad CIDR base: %q", tok)
		}
		ones, bits := ipnet.Mask.Size()
		hostBits := bits - ones
		// ParseCIDR guarantees 0 <= ones <= bits, so hostBits is in [0,128]; guard
		// the lower bound explicitly so the uint conversion cannot underflow.
		if hostBits < 0 || hostBits > 128 {
			return nil, fmt.Errorf("invalid CIDR mask for %q", tok)
		}
		size := new(big.Int).Lsh(big.NewInt(1), uint(hostBits)) //#nosec G115 -- hostBits guarded to [0,128] above
		end := new(big.Int).Add(start, size)
		end.Sub(end, big.NewInt(1))
		return &IPRange{Start: start, End: end, V6: v6}, nil
	}
	// Single IP
	ip := net.ParseIP(tok)
	if ip == nil {
		return nil, fmt.Errorf("bad IP: %q", tok)
	}
	s, v6, ok := ipToBig(ip)
	if !ok {
		return nil, fmt.Errorf("bad IP: %q", tok)
	}
	return &IPRange{Start: s, End: new(big.Int).Set(s), V6: v6}, nil
}

// mergeFamily sorts and coalesces overlapping/adjacent ranges of ONE family.
func mergeFamily(rs []*IPRange) []*IPRange {
	if len(rs) == 0 {
		return nil
	}
	sort.Slice(rs, func(i, j int) bool { return rs[i].Start.Cmp(rs[j].Start) < 0 })
	out := []*IPRange{{Start: new(big.Int).Set(rs[0].Start), End: new(big.Int).Set(rs[0].End), V6: rs[0].V6}}
	one := big.NewInt(1)
	for _, r := range rs[1:] {
		last := out[len(out)-1]
		// adjacent or overlapping if r.Start <= last.End + 1
		thresh := new(big.Int).Add(last.End, one)
		if r.Start.Cmp(thresh) <= 0 {
			if r.End.Cmp(last.End) > 0 {
				last.End.Set(r.End)
			}
		} else {
			out = append(out, &IPRange{Start: new(big.Int).Set(r.Start), End: new(big.Int).Set(r.End), V6: r.V6})
		}
	}
	return out
}

// splitFamilies merges ranges per family and returns (v4merged, v6merged).
func splitFamilies(rs []*IPRange) ([]*IPRange, []*IPRange) {
	var v4, v6 []*IPRange
	for _, r := range rs {
		if r.V6 {
			v6 = append(v6, r)
		} else {
			v4 = append(v4, r)
		}
	}
	return mergeFamily(v4), mergeFamily(v6)
}

// covered reports whether r is fully contained in the union represented by the
// pre-merged family slice `merged`.
func covered(r *IPRange, merged []*IPRange) bool {
	for _, m := range merged {
		if m.Start.Cmp(r.Start) <= 0 && m.End.Cmp(r.End) >= 0 {
			return true
		}
	}
	return false
}

// CoverageResult holds the real (range-aware) drift between baseline and kernel.
type CoverageResult struct {
	MissingFromKernel []string // baseline tokens whose coverage is NOT in the kernel union
	ExtraInKernel     []string // kernel tokens whose coverage is NOT in baseline∪sessions union
	BadBaseline       []string // unparseable baseline tokens (surfaced, not silently dropped)
	BadKernel         []string // unparseable kernel tokens
}

type parsed struct {
	tok string
	r   *IPRange
}

func parseAll(toks []string) ([]parsed, []string) {
	var ok []parsed
	var bad []string
	for _, t := range toks {
		t = strings.TrimSpace(t)
		if t == "" {
			continue
		}
		r, err := ParseRangeToken(t)
		if err != nil {
			bad = append(bad, t)
			continue
		}
		ok = append(ok, parsed{tok: t, r: r})
	}
	return ok, bad
}

// CoverageDiff compares the durable baseline against the live kernel set using
// range coverage. A kernel element is "extra" only if it is covered by neither
// the durable baseline NOR the (allowed) session/runtime entries. CIDR<->interval
// representation differences are NOT reported (coverage-equivalent == match).
func CoverageDiff(baseline, kernel, sessions []string) CoverageResult {
	bP, bBad := parseAll(baseline)
	kP, kBad := parseAll(kernel)
	sP, _ := parseAll(sessions)

	var bRanges, kRanges, sRanges []*IPRange
	for _, p := range bP {
		bRanges = append(bRanges, p.r)
	}
	for _, p := range kP {
		kRanges = append(kRanges, p.r)
	}
	for _, p := range sP {
		sRanges = append(sRanges, p.r)
	}

	k4, k6 := splitFamilies(kRanges)
	// baseline∪sessions for the "extra" direction
	bs4, bs6 := splitFamilies(append(append([]*IPRange{}, bRanges...), sRanges...))

	res := CoverageResult{BadBaseline: bBad, BadKernel: kBad}
	for _, p := range bP {
		m := k4
		if p.r.V6 {
			m = k6
		}
		if !covered(p.r, m) {
			res.MissingFromKernel = append(res.MissingFromKernel, p.tok)
		}
	}
	for _, p := range kP {
		m := bs4
		if p.r.V6 {
			m = bs6
		}
		if !covered(p.r, m) {
			res.ExtraInKernel = append(res.ExtraInKernel, p.tok)
		}
	}
	return res
}
