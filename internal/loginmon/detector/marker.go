// NFTBan - LoginMon detector marker location
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
//
// meta:name="loginmon_detector_marker"
// meta:type="core"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-08-14"
// meta:description="Case-insensitive ASCII marker location that operates directly on the ORIGINAL log bytes, so a marker offset is always valid for slicing the same buffer it was derived from. Replaces the pattern of indexing a lowercased copy and slicing the original, which was a proven detection-evasion vector (v1.229.1 TRACK 2)."
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package detector

// INVARIANT: INDEX_SOURCE == SLICE_SOURCE.
//
// PROVEN EVASION this removes (v1.229.1 TRACK 2, runtime-proven through Detect()):
// the affected paths located " from " with bytes.LastIndex on a LOWERCASED copy of
// the line and then sliced the ORIGINAL line at that offset. bytes.ToLower does not
// preserve byte length, so attacker-controlled text before the marker desynchronised
// the two buffers and the IP was sliced at the wrong offset:
//
//	corpus (synthetic)        lower delta   detected
//	ascii username             +0           yes
//	username with U+0130 (İ)   -1           NO   <- evaded
//	username with U+1E9E (ẞ)   -1           NO   <- evaded
//	username with U+212A (K)   -2           NO   <- evaded
//
// One character in a username suppressed the login-failure verdict entirely.
//
// The fix is to stop crossing representations at all, NOT to compensate for the
// delta. Offset arithmetic would pass the corpus above and still fail on the next
// case-mapping that changes length by a different amount (U+212A already differs
// from U+0130), and a per-character correction table is unmaintainable. A lowercased
// copy remains fine for BOOLEAN signature matching, where no offset is transferred.

// lastIndexFoldASCII returns the index of the LAST occurrence of lowerMarker in s,
// comparing ASCII case-insensitively, or -1.
//
// lowerMarker MUST already be ASCII-lowercase; only s is folded during comparison.
// Non-ASCII bytes in s are compared verbatim, which is correct here because every
// marker this package locates is ASCII — a non-ASCII byte can never be part of a
// match, and is never transformed, so the returned offset always addresses s.
func lastIndexFoldASCII(s, lowerMarker []byte) int {
	n := len(lowerMarker)
	if n == 0 || len(s) < n {
		return -1
	}
	for i := len(s) - n; i >= 0; i-- {
		matched := true
		for j := 0; j < n; j++ {
			c := s[i+j]
			if c >= 'A' && c <= 'Z' {
				c += 'a' - 'A'
			}
			if c != lowerMarker[j] {
				matched = false
				break
			}
		}
		if matched {
			return i
		}
	}
	return -1
}

// indexFoldASCII is lastIndexFoldASCII's FIRST-occurrence counterpart, for markers
// whose first match is the intended one (e.g. "ip="). Same invariant: the returned
// offset addresses s, because s is what was searched.
func indexFoldASCII(s, lowerMarker []byte) int {
	n := len(lowerMarker)
	if n == 0 || len(s) < n {
		return -1
	}
	for i := 0; i+n <= len(s); i++ {
		matched := true
		for j := 0; j < n; j++ {
			c := s[i+j]
			if c >= 'A' && c <= 'Z' {
				c += 'a' - 'A'
			}
			if c != lowerMarker[j] {
				matched = false
				break
			}
		}
		if matched {
			return i
		}
	}
	return -1
}
