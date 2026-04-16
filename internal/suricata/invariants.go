// =============================================================================
// NFTBan - Suricata Integration Invariants
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="invariants"
// meta:type="package"
// meta:version="1.92.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-16"
// meta:description="Architectural invariants for Suricata integration (INV-S-001..013)"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package suricata

// Suricata integration invariants — enforced by CI gates GS-001..GS-014.
// Source of truth: V192_FINAL_ARCHITECTURE_DECISION.md
const (
	// INV-S-001: Suricata runs IDS-only by default (default-rule-action: alert).
	// When Inline Exception Mode is enabled, default-rule-action remains alert.
	// Only approved SIDs receive per-rule action: drop override.
	InvIDSOnlyDefault = "INV-S-001"

	// INV-S-002: No broad IPS mode. NFQUEUE enabled ONLY when
	// INLINE_EXCEPTION_ENABLED=true. Even with NFQUEUE, all non-approved
	// rules remain alert-only.
	InvNoBroadIPS = "INV-S-002"

	// INV-S-003: NFTBan owns managed deployment baseline (install, config,
	// profiles, updates, verification, inline allowlist).
	InvManagedDeployment = "INV-S-003"

	// INV-S-004: All sustained IP bans go through daemon IPC → nftables.
	// Suricata inline drops are transient (one request) and do not
	// constitute sustained blocking.
	InvIPCOnlyBans = "INV-S-004"

	// INV-S-005: Suricata is optional. System achieves PROTECTED status
	// without Suricata. Suricata absence does not degrade health.
	InvSuricataOptional = "INV-S-005"

	// INV-S-006: User owns policy via detection.conf + actions.conf +
	// inline_exceptions.conf.
	InvUserOwnsPolicy = "INV-S-006"

	// INV-S-007: Kernel nftables is the default and primary enforcement
	// authority for all traffic blocking. Suricata inline exception
	// provides transient first-request protection for approved rules only.
	InvKernelPrimaryAuthority = "INV-S-007"

	// INV-S-008: Suricata MAY drop packets ONLY in Inline Exception Mode,
	// ONLY for SIDs listed in inline_exceptions.conf, ONLY when the SID's
	// category is also enabled.
	InvInlineAllowlistOnly = "INV-S-008"

	// INV-S-009: Inline exception allowlist capped at MAX_SIDS
	// (default: 50, hard max: 200). No wildcard, no auto-promotion.
	InvInlineSIDCap = "INV-S-009"

	// INV-S-010: Every Suricata inline drop MUST emit EVE alert.
	// EVE failure → inline auto-disabled (fail-safe to IDS-only).
	InvInlineRequiresEVE = "INV-S-010"

	// INV-S-011: All sustained blocking via kernel nftables.
	// Suricata inline drops are transient (one request).
	InvSustainedBlockingKernel = "INV-S-011"

	// INV-S-012: Event Rule Engine MUST NOT trigger inline behavior.
	// Inline = Suricata SID allowlist ONLY.
	InvRuleEngineNoInline = "INV-S-012"

	// INV-S-013: NFTBAN_INLINE_DISABLE=true is the global kill switch.
	// Instantly disables NFQUEUE, forces IDS-only.
	InvGlobalKillSwitch = "INV-S-013"

	// InlineExceptionMaxSIDsDefault is the default cap for inline-approved SIDs.
	InlineExceptionMaxSIDsDefault = 50

	// InlineExceptionMaxSIDsHard is the absolute maximum (cannot be overridden).
	InlineExceptionMaxSIDsHard = 200

	// AuthoritySuricataInline is the authority label for inline exception drops.
	AuthoritySuricataInline = "suricata-inline-exception"

	// AuthorityNFTBanKernel is the authority label for kernel nftables bans.
	AuthorityNFTBanKernel = "nftban-kernel"

	// AuthorityNFTBanIDS is the authority label for IDS-only detections.
	AuthorityNFTBanIDS = "nftban-ids"
)
