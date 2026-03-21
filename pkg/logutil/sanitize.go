// =============================================================================
// NFTBan - Log Sanitization Utilities
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="logutil"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-21"
// meta:description="Sanitize user-controlled values before logging to prevent log injection"
// meta:input="Untrusted strings (IP, username, action, path)"
// meta:output="Sanitized strings safe for log.Printf"
// meta:depends=""
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package logutil

import "strings"

// Sanitize strips newlines and control characters from user-controlled
// values before logging, preventing log injection / log forging attacks.
func Sanitize(s string) string {
	return strings.Map(func(r rune) rune {
		if r == '\n' || r == '\r' || r < 0x20 {
			return '_'
		}
		return r
	}, s)
}
