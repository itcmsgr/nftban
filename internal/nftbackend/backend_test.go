// =============================================================================
// NFTBan v1.58.0 - nftbackend Package Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="backend_test"
// meta:type="test"
// meta:version="1.58.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Unit tests for nftbackend — pure logic only, no kernel/netlink"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package nftbackend

import (
	"context"
	"github.com/itcmsgr/nftban/internal/bansource"
	"testing"
)

// =============================================================================
// isManualSource — set routing logic (hash vs interval)
// =============================================================================

// ⛔ v1.229.13 LANE-BST — ASSURANCE MIGRATED, NOT RETIRED.
// These previously called isManualSource(), an exact-match switch that decided
// storage from the SPELLING of the source. Routing now derives from a canonical
// Kind, so the assertions target storageIsReplaceManaged(). The PROPERTY is
// unchanged and EXTENDED: the families that were silently misrouted into the
// feed-owned interval sets are now covered explicitly.

func TestStorageRouting_DetectorAndOperatorSourcesAreNotReplaceManaged(t *testing.T) {
	// Every one of these must land in hash-like storage that bulk sync never
	// replaces. The second block is the set the old exact-match switch MISSED —
	// each was erased by the next feed sync.
	for _, src := range []string{
		// covered by the old table
		"manual", "cli", "login", "persistent", "suricata",
		"portscan", "portscan-classic", "portscan-suricata",
		"ddos", "ddos-classic", "ddos-suricata",
		// MISSED by the old table — the measured defect
		"loginmon", "botguard", "botscan", "botscan-404", "portscan-aggregate",
		// the per-service login vocabulary the shell monitor forwards verbatim
		"sshd", "ssh", "dovecot", "exim", "postfix",
		"vsftpd", "proftpd", "pureftpd", "directadmin", "cpanel",
	} {
		if storageIsReplaceManaged(src, bansource.OriginUnspecified) {
			t.Errorf("storageIsReplaceManaged(%q) = true, want false — a detector or "+
				"operator ban routed into the feed-owned interval set is erased by the "+
				"next feed synchronisation", src)
		}
	}
}

func TestStorageRouting_BulkSourcesAreReplaceManaged(t *testing.T) {
	for _, src := range []string{"feeds", "feed", "geoban", "blacklist", "threat-intel"} {
		if !storageIsReplaceManaged(src, bansource.OriginUnspecified) {
			t.Errorf("storageIsReplaceManaged(%q) = false, want true — bulk-synchronised "+
				"sources belong in the interval sets their own sync owns", src)
		}
	}
}

func TestStorageRouting_UnknownLabelFailsSafeNotReplaceManaged(t *testing.T) {
	// ⛔ An unrecognised label has NO lifecycle. This layer must not invent one, and
	// must not fail toward the destructive side. Losing enforcement silently is the
	// defect; keeping a ban slightly longer than ideal is not.
	for _, src := range []string{"", "unknown", "custom-feed", "blocklist-de", "spamhaus"} {
		if storageIsReplaceManaged(src, bansource.OriginUnspecified) {
			t.Errorf("storageIsReplaceManaged(%q) = true — an unclassified label must "+
				"fail safe into non-replaced storage, never into the set bulk sync flushes", src)
		}
	}
}

func TestStorageRouting_OriginOverridesLabel(t *testing.T) {
	// ⛔ THE CORE PROPERTY: producer context decides, the label is provenance.
	// An arbitrary operator label must be ManualPersistent because an OPERATOR
	// produced it — not because the string was recognised. This is the arm that
	// prevents replacing today's stale table with a newer stale table.
	if storageIsReplaceManaged("customer-rule-42", bansource.OriginOperator) {
		t.Error("an arbitrary operator label was routed to replace-managed storage; " +
			"--source <anything> from an operator command is a manual decision")
	}
	if storageIsReplaceManaged("totally-new-detector", bansource.OriginDetector) {
		t.Error("a detector-produced ban with an unrecognised label was routed to " +
			"replace-managed storage; the producer context must win over the table")
	}
	// And the label must NOT be able to override a bulk producer.
	if !storageIsReplaceManaged("loginmon", bansource.OriginBulkSync) {
		t.Error("OriginBulkSync must yield replace-managed storage regardless of label")
	}
}

// =============================================================================
// Ban/Unban input validation
// =============================================================================

func TestBan_InvalidIP_ReturnsError(t *testing.T) {
	b := &Backend{}

	_, err := b.Ban(context.Background(), BanRequest{
		IP:     "not-an-ip",
		Source: "manual",
	})

	if err == nil {
		t.Error("expected error for invalid IP, got nil")
	}
}

func TestUnban_InvalidIP_ReturnsError(t *testing.T) {
	b := &Backend{}

	var unbanErr error
	func() {
		defer func() { recover() }()
		_, unbanErr = b.Unban(context.Background(), UnbanRequest{
			IP: "not-an-ip",
		})
	}()

	if unbanErr == nil {
		t.Error("expected error for invalid IP, got nil")
	}
}

// =============================================================================
// Stats error tracking
// =============================================================================

func TestBackend_StatsErrorIncrement(t *testing.T) {
	b := &Backend{}

	func() {
		defer func() { recover() }()
		_, _ = b.Ban(context.Background(), BanRequest{IP: "garbage", Source: "manual"})
	}()

	if b.stats.Errors != 1 {
		t.Errorf("Errors = %d after invalid ban, want 1", b.stats.Errors)
	}
	if b.stats.LastError == "" {
		t.Error("LastError should be set after error")
	}
}

// =============================================================================
// Port-set routing (v1.145 PR-B2)
// =============================================================================

// TestIsPortSet locks the inet_service (port) set classification used by
// AddElement/DeleteElement to route to the port-aware path. ssh_ports MUST be
// classified as a port set; an IP set name MUST NOT. This is the guard that
// keeps generic element writes (nft_ipc_add_element) from treating a port
// number as an IP ("invalid IP or CIDR: <port>") for SSH-port reconciliation.
func TestIsPortSet(t *testing.T) {
	portSetNames := []string{
		"tcp_ports_in", "tcp_ports_out",
		"udp_ports_in", "udp_ports_out",
		"ssh_ports",
	}
	for _, name := range portSetNames {
		if !isPortSet(name) {
			t.Errorf("isPortSet(%q) = false, want true (port set)", name)
		}
	}

	ipSetNames := []string{
		"blacklist_ipv4", "whitelist_ipv6",
		"persistent_offenders_ipv4", "geoban_ipv6",
		"http_bot_ban", "port_allow_tcp_ipv4",
		"", "random",
	}
	for _, name := range ipSetNames {
		if isPortSet(name) {
			t.Errorf("isPortSet(%q) = true, want false (not a port set)", name)
		}
	}
}
