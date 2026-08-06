// SPDX-License-Identifier: MPL-2.0

package validate

import "strings"

// v1.228.5 — NFTBAN_UNIT_PREFIX != NFTBAN_FAILURE_OWNERSHIP.
//
// The post-install failed-unit gate filtered every candidate through IsNftbanUnit, so it
// could see nftban-core-geoip.service but never logrotate.service — even when logrotate
// failed BECAUSE OF NFTBan's own generated /etc/logrotate.d/nftban stanza. MEASURED on an
// AlmaLinux 9.7 Enforcing fixture 2026-08-06: INSTALL_STATE reached COMMITTED while
// logrotate.service was failed on an NFTBan-owned artifact.
//
// This file supplies the missing dimension: a failure is NFTBan's when NFTBan OWNS an
// artifact the failing unit consumes — regardless of the unit's name.
//
// DELIBERATELY PLATFORM-AGNOSTIC. SELinux is one consumer authority among many; the same
// class of defect exists on Debian/Ubuntu through AppArmor, PAM, tmpfiles and maintainer
// scripts. Integrations are therefore expressed as (system unit, NFTBan-owned artifacts)
// pairs that resolve identically on EL and Debian family hosts. Nothing here is
// SELinux-specific, and nothing is gated on a package format.
//
// ⛔ This must NOT become "count every failed system unit". Unrelated host debt would then
// block NFTBan installs. Each integration asserts ONLY when NFTBan has actually installed
// the artifact that unit consumes — presence of the artifact is the gate.

// SystemIntegration pairs a SYSTEM unit (one whose name does not begin with nftban-) with
// the NFTBan-owned artifacts it consumes. If any artifact is present, NFTBan is
// participating in that integration and owns failures arising from it.
type SystemIntegration struct {
	// Unit is the system unit name as systemd reports it.
	Unit string
	// Artifacts are absolute paths NFTBan installs or generates which this unit reads.
	// Presence of ANY of them means NFTBan participates in the integration. Absence means
	// NFTBan does not, and a failure of Unit is NOT attributable to NFTBan.
	Artifacts []string
	// Why documents the causal link, so an operator reading a blocked install understands
	// why a non-nftban unit is being attributed to NFTBan.
	Why string
}

// NftbanSystemIntegrations returns every system unit NFTBan can break through an artifact
// it owns. Covers both package families and both MAC implementations.
func NftbanSystemIntegrations() []SystemIntegration {
	return []SystemIntegration{
		{
			Unit: "logrotate.service",
			// /etc/logrotate.d/nftban is %ghost on RPM and generated at postinstall on
			// BOTH families from internal/logretention/inventory.go, so it is present on
			// EL and Debian alike.
			Artifacts: []string{
				"/etc/logrotate.d/nftban",
				"/etc/logrotate.d/nftban-suricata",
			},
			Why: "NFTBan installs logrotate stanzas; ONE invalid or inaccessible stanza fails the entire system-wide logrotate run",
		},
		{
			Unit: "systemd-tmpfiles-setup.service",
			Artifacts: []string{
				"/usr/lib/tmpfiles.d/nftban.conf",
				"/etc/tmpfiles.d/nftban.conf",
			},
			Why: "NFTBan ships tmpfiles rules; an invalid entry or a refused ownership transition fails the shared tmpfiles run",
		},
		{
			Unit: "nftables.service",
			Artifacts: []string{
				"/etc/nftables.conf",
				"/etc/sysconfig/nftables.conf",
			},
			Why: "NFTBan takes over firewall authority; a ruleset it renders can fail the distro nftables unit",
		},
		{
			// Debian/Ubuntu confinement authority. The EL-family equivalent (SELinux) has
			// no comparable per-service unit — its module load is asserted separately.
			Unit: "apparmor.service",
			Artifacts: []string{
				"/etc/apparmor.d/usr.lib.nftban.bin.nftband",
			},
			Why: "NFTBan ships an AppArmor profile; a malformed profile fails the shared apparmor unit at load",
		},
	}
}

// FailureOwnership classifies a failed unit by CAUSALITY, not by name.
type FailureOwnership string

const (
	// OwnNftbanPackageUnit is an nftban-* unit shipped by the package.
	OwnNftbanPackageUnit FailureOwnership = "NFTBAN_PACKAGE_UNIT"
	// OwnNftbanAffectedSystem is a system unit failing while consuming an NFTBan-owned
	// artifact. Blocks COMMITTED exactly like a package unit failure.
	OwnNftbanAffectedSystem FailureOwnership = "NFTBAN_AFFECTED_SYSTEM_UNIT"
	// OwnPreexistingUnrelated failed before the transaction with no NFTBan artifact
	// involved. Allowed, but ONLY when explicitly recorded.
	OwnPreexistingUnrelated FailureOwnership = "PREEXISTING_UNRELATED_UNIT"
	// OwnNewUnclassified became failed during the transaction with no established cause.
	// Fails closed: an unexplained new failure during our transaction is ours until proven
	// otherwise.
	OwnNewUnclassified FailureOwnership = "NEW_UNCLASSIFIED_UNIT"
)

// Blocks reports whether this ownership class must prevent INSTALL_STATE=COMMITTED.
func (o FailureOwnership) Blocks() bool {
	return o == OwnNftbanPackageUnit || o == OwnNftbanAffectedSystem || o == OwnNewUnclassified
}

// ClassifyFailedUnit determines who owns a failed unit.
//
//	unit        the failing unit name
//	preFailed   units already failed BEFORE the transaction (snapshot)
//	fileExists  presence probe for an absolute path; injected so this is testable and so
//	            the caller controls whether it inspects a live root or a staged one
//
// Ordering matters: an nftban-* unit is ours by name; otherwise a known integration whose
// artifact is PRESENT is ours by causality; otherwise a unit already failing beforehand is
// pre-existing; anything else newly failed during our transaction is unclassified and
// fails closed.
func ClassifyFailedUnit(unit string, preFailed map[string]bool, fileExists func(string) bool) (FailureOwnership, string) {
	if IsNftbanUnit(unit) {
		return OwnNftbanPackageUnit, "unit is shipped by the NFTBan package"
	}
	for _, ig := range NftbanSystemIntegrations() {
		if !strings.EqualFold(ig.Unit, unit) {
			continue
		}
		for _, art := range ig.Artifacts {
			if fileExists != nil && fileExists(art) {
				// Participation is PROVEN by the artifact's presence, not assumed from the
				// unit being in the table. If NFTBan ships no stanza, a logrotate failure
				// is genuinely not ours.
				return OwnNftbanAffectedSystem, ig.Why + " (NFTBan-owned artifact present: " + art + ")"
			}
		}
		// Known integration, but NFTBan installed nothing it consumes.
		break
	}
	if preFailed != nil && preFailed[unit] {
		return OwnPreexistingUnrelated, "already failed before this transaction; no NFTBan-owned artifact involved"
	}
	return OwnNewUnclassified, "became failed during this transaction with no established cause — failing closed"
}
