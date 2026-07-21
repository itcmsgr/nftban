// SPDX-License-Identifier: MPL-2.0
// meta:name="systemd.go"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.222.1 shared `systemctl show` property parser for the health-resource surface. ONE parser used by both the installer reconciler (internal/installer/services) and the read-only `nftban-core resources` CLI — no duplicate parser. Machine-readable properties only (never human `systemctl status`)."
// meta:inventory.files="internal/healthresource/systemd.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
package healthresource

import (
	"math"
	"strconv"
	"strings"
)

// InfinityBytes is the sentinel for systemd's "infinity" (unset) memory limit.
// The v1.222.1 bounded policy treats it as INVALID, never as "large and safe".
const InfinityBytes = math.MaxInt64

// ShowProps parses `systemctl show` KEY=VALUE output into a map. Order-independent,
// tolerant of blank lines and values that themselves contain '='.
func ShowProps(out string) map[string]string {
	m := make(map[string]string)
	for _, ln := range strings.Split(out, "\n") {
		ln = strings.TrimRight(ln, "\r")
		if ln == "" {
			continue
		}
		if i := strings.IndexByte(ln, '='); i > 0 {
			m[ln[:i]] = ln[i+1:]
		}
	}
	return m
}

// ParseMemBytes parses a systemd memory/tasks property value. Bare integers are
// bytes; "infinity"/"[not set]" → (InfinityBytes, true); "" → (0, false). A
// non-numeric non-infinity value returns (0, false) with ok=false.
func ParseMemBytes(s string) (v int64, infinity bool, ok bool) {
	s = strings.TrimSpace(s)
	switch s {
	case "":
		// PARSEMEMBYTES-EMPTY-OK-TRUE: empty / whitespace-only is MISSING evidence, not
		// a valid 0-byte limit. ok=false so callers distinguish "unset" from a real value.
		return 0, false, false
	case "infinity", "[not set]":
		return InfinityBytes, true, true
	}
	if n, err := strconv.ParseInt(s, 10, 64); err == nil {
		// PARSEMEMBYTES-NEGATIVE-ACCEPTED: systemd never emits a negative memory limit;
		// a negative parse is malformed. Reject rather than clamp or use as a sentinel.
		if n < 0 {
			return 0, false, false
		}
		return n, false, true
	}
	// Older systemd prints infinity as the numeric uint64 max (18446744073709551615)
	// rather than the word — treat that as infinity too, not as unparseable.
	if u, err := strconv.ParseUint(s, 10, 64); err == nil && u == math.MaxUint64 {
		return InfinityBytes, true, true
	}
	return 0, false, false
}
