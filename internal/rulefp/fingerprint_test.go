// =============================================================================
// NFTBan - Ruleset fingerprint tests (SEC-RULEFP, v1.138 PR-A)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="rulefp_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-27"
// meta:description="Unit tests for the SEC-RULEFP fingerprint: deterministic digest; immune to counter/handle/timestamp/dynamic-set-element churn; detects an injected accept rule and a chain-policy flip; Verify returns OK/MISMATCH/BASELINE_MISSING. No nft/root required (pure text fixtures)."
// meta:input="in-test ruleset fixtures"
// meta:output="None"
// meta:depends="testing,path/filepath"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package rulefp

import (
	"os"
	"path/filepath"
	"testing"
)

const baseRuleset = `# family ip
table ip nftban {
	set blacklist_manual {
		type ipv4_addr
		flags timeout
		elements = { 1.2.3.4 timeout 3600s, 5.6.7.8 timeout 7200s }
	}
	chain input {
		type filter hook input priority 0; policy drop;
		ct state established,related accept
		ip saddr @whitelist_manual accept
		ip saddr @blacklist_manual counter packets 12 bytes 340 drop
	}
	chain output {
		type filter hook output priority 0; policy accept;
	}
}
`

// same structure, counters ticked + different element set + a timer + a handle
const churnedRuleset = `# family ip
table ip nftban {
	set blacklist_manual {
		type ipv4_addr
		flags timeout
		elements = { 9.9.9.9 timeout 100s, 8.8.8.8 timeout 5s, 7.7.7.7 timeout 42s }
	}
	chain input {
		type filter hook input priority 0; policy drop;
		ct state established,related accept
		ip saddr @whitelist_manual accept
		ip saddr @blacklist_manual counter packets 998877 bytes 1234567 drop # handle 19
	}
	chain output {
		type filter hook output priority 0; policy accept;
	}
}
`

// multi-line elements block (nft wraps long sets) — element churn must still be ignored
const multilineElems = `# family ip
table ip nftban {
	set blacklist_manual {
		type ipv4_addr
		flags timeout
		elements = {
			1.1.1.1 timeout 10s,
			2.2.2.2 timeout 20s,
			3.3.3.3 timeout 30s
		}
	}
	chain input {
		type filter hook input priority 0; policy drop;
		ip saddr @blacklist_manual counter packets 1 bytes 1 drop
	}
}
`

// B-8: an injected accept rule inside the input chain (structural change)
const injectedAccept = `# family ip
table ip nftban {
	set blacklist_manual {
		type ipv4_addr
		flags timeout
		elements = { 1.2.3.4 timeout 3600s, 5.6.7.8 timeout 7200s }
	}
	chain input {
		type filter hook input priority 0; policy drop;
		ct state established,related accept
		ip saddr 6.6.6.6 accept
		ip saddr @whitelist_manual accept
		ip saddr @blacklist_manual counter packets 12 bytes 340 drop
	}
	chain output {
		type filter hook output priority 0; policy accept;
	}
}
`

// B-9: input chain policy flipped drop → accept (structural change)
const policyFlip = `# family ip
table ip nftban {
	set blacklist_manual {
		type ipv4_addr
		flags timeout
		elements = { 1.2.3.4 timeout 3600s, 5.6.7.8 timeout 7200s }
	}
	chain input {
		type filter hook input priority 0; policy accept;
		ct state established,related accept
		ip saddr @whitelist_manual accept
		ip saddr @blacklist_manual counter packets 12 bytes 340 drop
	}
	chain output {
		type filter hook output priority 0; policy accept;
	}
}
`

func TestDigest_Deterministic(t *testing.T) {
	// Capture both calls into named locals: same input -> identical digest.
	// (Splitting the call sites also keeps staticcheck SA4000 happy without
	// changing the semantics of the determinism check.)
	a := Digest(baseRuleset)
	b := Digest(baseRuleset)
	if a != b {
		t.Fatalf("digest not deterministic for identical input: %s vs %s", a, b)
	}
}

func TestDigest_IgnoresChurn(t *testing.T) {
	// counters + dynamic-set elements + handles + timers must not move the digest.
	if Digest(baseRuleset) != Digest(churnedRuleset) {
		t.Errorf("digest changed under counter/element/handle churn:\n base=%s\n churn=%s",
			Digest(baseRuleset), Digest(churnedRuleset))
	}
}

func TestDigest_IgnoresMultilineElementChurn(t *testing.T) {
	a := Digest(multilineElems)
	// swap the multi-line element list contents only
	b := Digest(`# family ip
table ip nftban {
	set blacklist_manual {
		type ipv4_addr
		flags timeout
		elements = {
			9.9.9.9 timeout 99s
		}
	}
	chain input {
		type filter hook input priority 0; policy drop;
		ip saddr @blacklist_manual counter packets 50 bytes 60 drop
	}
}
`)
	if a != b {
		t.Errorf("multi-line element churn changed the digest: %s vs %s", a, b)
	}
}

func TestDigest_DetectsInjectedAccept(t *testing.T) {
	if Digest(baseRuleset) == Digest(injectedAccept) {
		t.Error("injected accept rule did NOT change the digest (B-8 undetected)")
	}
}

func TestDigest_DetectsPolicyFlip(t *testing.T) {
	if Digest(baseRuleset) == Digest(policyFlip) {
		t.Error("chain-policy flip did NOT change the digest (B-9 undetected)")
	}
}

func TestVerify_MatchMismatchMissing(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ruleset_fingerprint.json")

	// missing baseline
	if st, _, _ := Verify(path, baseRuleset); st != StatusBaselineMissing {
		t.Errorf("no baseline: got %s, want BASELINE_MISSING", st)
	}

	// capture, then identical → OK (incl. churn immunity)
	if err := CaptureBaseline(path, baseRuleset); err != nil {
		t.Fatalf("CaptureBaseline: %v", err)
	}
	if st, exp, act := Verify(path, churnedRuleset); st != StatusOK {
		t.Errorf("churned-but-same-structure: got %s (exp=%s act=%s), want OK", st, exp, act)
	}

	// injected accept → MISMATCH
	if st, exp, act := Verify(path, injectedAccept); st != StatusMismatch {
		t.Errorf("injected accept: got %s (exp=%s act=%s), want MISMATCH", st, exp, act)
	}
	// policy flip → MISMATCH
	if st, _, _ := Verify(path, policyFlip); st != StatusMismatch {
		t.Errorf("policy flip: got %s, want MISMATCH", st)
	}
}

// TestVerify_DoesNotRefreshBaseline is the core SEC-RULEFP invariant: a verify
// that finds a MISMATCH must NEVER rewrite the baseline (no auto-heal/self-heal),
// otherwise an injected rule could silently become the new "truth".
func TestVerify_DoesNotRefreshBaseline(t *testing.T) {
	path := filepath.Join(t.TempDir(), "ruleset_fingerprint.json")
	if err := CaptureBaseline(path, baseRuleset); err != nil {
		t.Fatalf("CaptureBaseline: %v", err)
	}
	before, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read baseline: %v", err)
	}

	if st, _, _ := Verify(path, injectedAccept); st != StatusMismatch {
		t.Fatalf("expected MISMATCH, got %s", st)
	}

	after, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read baseline after verify: %v", err)
	}
	if string(before) != string(after) {
		t.Error("Verify MUTATED the baseline on mismatch (auto-refresh/self-heal is forbidden)")
	}
}
