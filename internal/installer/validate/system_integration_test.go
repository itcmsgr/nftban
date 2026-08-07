// SPDX-License-Identifier: MPL-2.0

package validate

import (
	"strings"
	"testing"
)

// v1.228.5 controls for NFTBAN_UNIT_PREFIX != NFTBAN_FAILURE_OWNERSHIP.
//
// The MEASURED defect: INSTALL_STATE reached COMMITTED on an EL9 Enforcing fixture while
// logrotate.service was failed because of NFTBan's own generated stanza. The gate filtered
// on the unit NAME, so a system unit NFTBan had broken was never even gathered.

func exists(paths ...string) func(string) bool {
	set := map[string]bool{}
	for _, p := range paths {
		set[p] = true
	}
	return func(p string) bool { return set[p] }
}

// The regression itself: logrotate.service failing WITH an NFTBan stanza present is ours,
// and must block COMMITTED.
func TestClassify_LogrotateWithNftbanStanza_IsOursAndBlocks(t *testing.T) {
	own, why := ClassifyFailedUnit("logrotate.service", nil, exists("/etc/logrotate.d/nftban"))
	if own != OwnNftbanAffectedSystem {
		t.Fatalf("want NFTBAN_AFFECTED_SYSTEM_UNIT, got %s (%s)", own, why)
	}
	if !own.Blocks() {
		t.Fatal("an NFTBan-caused system failure MUST block COMMITTED")
	}
	if why == "" {
		t.Fatal("attribution must explain WHY a non-nftban unit is attributed to NFTBan")
	}
}

// The other half, and the reason this is not "count every failed unit": with no NFTBan
// stanza installed, the same failing unit is NOT ours and must not block.
func TestClassify_LogrotateWithoutNftbanStanza_IsNotOurs(t *testing.T) {
	pre := map[string]bool{"logrotate.service": true}
	own, _ := ClassifyFailedUnit("logrotate.service", pre, exists("/etc/logrotate.d/apache2"))
	if own != OwnPreexistingUnrelated {
		t.Fatalf("want PREEXISTING_UNRELATED_UNIT, got %s", own)
	}
	if own.Blocks() {
		t.Fatal("unrelated host debt must NOT block an NFTBan install")
	}
}

// Package units keep their existing ownership.
func TestClassify_NftbanUnit_IsPackageUnit(t *testing.T) {
	own, _ := ClassifyFailedUnit("nftban-core-geoip.service", nil, exists())
	if own != OwnNftbanPackageUnit || !own.Blocks() {
		t.Fatalf("want blocking NFTBAN_PACKAGE_UNIT, got %s", own)
	}
}

// Fail closed: a unit that became failed during OUR transaction, with no established
// cause, is ours until proven otherwise. Reading it as unrelated is how a real regression
// would slip through.
func TestClassify_NewlyFailedUnknown_FailsClosed(t *testing.T) {
	own, _ := ClassifyFailedUnit("some-other.service", map[string]bool{}, exists())
	if own != OwnNewUnclassified {
		t.Fatalf("want NEW_UNCLASSIFIED_UNIT, got %s", own)
	}
	if !own.Blocks() {
		t.Fatal("an unexplained NEW failure during our transaction must fail closed")
	}
}

// Platform coverage: the control is not SELinux- or EL-specific. Debian/Ubuntu's
// confinement and tmpfiles authorities must be attributable the same way.
func TestClassify_DebianFamilyIntegrations(t *testing.T) {
	for _, tc := range []struct{ unit, artifact string }{
		{"apparmor.service", "/etc/apparmor.d/usr.lib.nftban.bin.nftband"},
		{"systemd-tmpfiles-setup.service", "/usr/lib/tmpfiles.d/nftban.conf"},
		{"nftables.service", "/etc/nftables.conf"},
	} {
		own, why := ClassifyFailedUnit(tc.unit, nil, exists(tc.artifact))
		if own != OwnNftbanAffectedSystem {
			t.Fatalf("%s with %s: want NFTBAN_AFFECTED_SYSTEM_UNIT, got %s (%s)",
				tc.unit, tc.artifact, own, why)
		}
	}
}

// Every declared integration must name at least one artifact, otherwise the presence gate
// can never fire and the entry is inert — the "declared but unenforceable" class.
func TestSystemIntegrations_AllHaveArtifactsAndRationale(t *testing.T) {
	igs := NftbanSystemIntegrations()
	if len(igs) == 0 {
		t.Fatal("integration table is empty — every classification would fall through")
	}
	for _, ig := range igs {
		if len(ig.Artifacts) == 0 {
			t.Fatalf("%s declares no artifacts — its presence gate can never fire", ig.Unit)
		}
		if ig.Why == "" {
			t.Fatalf("%s has no rationale — an operator cannot act on an unexplained block", ig.Unit)
		}
		if IsNftbanUnit(ig.Unit) {
			t.Fatalf("%s is already an nftban-* unit; it belongs to the package-unit path", ig.Unit)
		}
	}
}

// v1.228.5 CAUSALITY controls for the PRODUCTION entry point.
//
// Participation (our stanza exists) must NOT be enough to attribute a failure. logrotate
// can fail on another package's stanza while ours is present and fine; blocking the
// install for that would be the mirror of the bug being fixed.

func TestOwnership_ParticipationWithoutCausality_DoesNotBlock(t *testing.T) {
	// Our stanza IS present (participation holds), but the failure names someone else's file.
	own, why := classifyOwnershipWithProbes("logrotate.service",
		"error: stat of /etc/logrotate.d/apache2 failed",
		exists("/etc/logrotate.d/nftban"), nil, nil)
	if own == OwnNftbanAffectedSystem {
		t.Fatalf("participation alone must NOT attribute: got %s (%s)", own, why)
	}
	if own.Blocks() {
		t.Fatalf("another package's stanza failure must not block our install (got %s)", own)
	}
}

func TestOwnership_CausalityFromDetail_Blocks(t *testing.T) {
	// The measured production shape: the failure text names an NFTBan-owned path.
	own, why := classifyOwnershipWithProbes("logrotate.service",
		"error: stat of /var/lib/nftban/permissions_audit.log failed: Permission denied",
		exists("/etc/logrotate.d/nftban"), nil, nil)
	if own != OwnNftbanAffectedSystem {
		t.Fatalf("failure naming an NFTBan path MUST attribute to NFTBan: got %s (%s)", own, why)
	}
	if !own.Blocks() {
		t.Fatal("an NFTBan-caused system failure must block COMMITTED")
	}
	if !strings.Contains(why, "/var/lib/nftban") {
		t.Fatalf("attribution must cite the evidence, got %q", why)
	}
}
