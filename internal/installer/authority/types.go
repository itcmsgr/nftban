// =============================================================================
// NFTBan v1.73 - Installer Authority Types
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-authority-types"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Authority decision enum and types"
// meta:inventory.files="internal/installer/authority/types.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars="NFTBAN_TAKEOVER"
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package authority

// Decision represents the authority classification for the install.
type Decision string

const (
	// Update means NFTBan already owns the firewall (table + chain + daemon).
	// PR-22B tightened this predicate — a table or chain without an active
	// nftband.service is NOT Update; it is Ambiguous.
	Update Decision = "UPDATE"

	// Fresh means no conflicting firewalls — clean slate.
	Fresh Decision = "FRESH"

	// Takeover means conflicts exist but takeover is approved
	// (via env var, --takeover flag, or panel auto-approve when explicitly
	// enabled by --panel-auto-takeover).
	Takeover Decision = "TAKEOVER"

	// Abort means conflicts exist and takeover is not approved.
	Abort Decision = "ABORT"

	// Ambiguous means the host is in a half-installed / crashed state —
	// an ip nftban table exists in the kernel but the daemon is not
	// active, OR the detection is inconclusive. PR-22B added this state
	// on the install side to close the audit finding that orphan-table
	// hosts silently classified as Update and skipped the emergency SSH
	// injection path. phaseSwitch must treat Ambiguous with the same
	// pre-switch safety as Takeover — never silent-continue.
	Ambiguous Decision = "AMBIGUOUS"
)
