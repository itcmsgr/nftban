// SPDX-License-Identifier: MPL-2.0
// =============================================================================
// NFTBan v1.100 — Inline-verify primitive tests (PR-25 §21.1)
// =============================================================================
// meta:name="restore_inline_verify_test"
// meta:type="test"
// meta:version="1.100.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="PR-25 commit 3B inline-verify tests: §21.1 three-assertion truth table, dep-error wrapping, invalid-input refusal, no PR-26 / full-validator behavior, no host mutation in tests."
// meta:depends="github.com/itcmsgr/nftban/internal/installer/uninstall"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package restore

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/uninstall"
)

// fakeInlineVerifyDep records calls and lets each assertion's return
// value (and error) be set independently per test.
type fakeInlineVerifyDep struct {
	// Returns
	activeRet     bool
	activeErr     error
	authorityRet  uninstall.CurrentAuthority
	authorityErr  error
	safeRet       bool
	safeErr       error
	// Counters
	activeCalls    int
	authorityCalls int
	safeCalls      int
	// Last firewallType seen by IsTargetFirewallActive
	lastFirewallType string
}

func (f *fakeInlineVerifyDep) IsTargetFirewallActive(_ context.Context, fwt string) (bool, error) {
	f.activeCalls++
	f.lastFirewallType = fwt
	return f.activeRet, f.activeErr
}

func (f *fakeInlineVerifyDep) CurrentAuthorityClass(_ context.Context) (uninstall.CurrentAuthority, error) {
	f.authorityCalls++
	return f.authorityRet, f.authorityErr
}

func (f *fakeInlineVerifyDep) IsSafetyNetRemovalSafe(_ context.Context) (bool, error) {
	f.safeCalls++
	return f.safeRet, f.safeErr
}

// =============================================================================
// 1. Happy path — all three assertions pass; SafeToRemove = true
// =============================================================================

func TestInlineVerify_AllThreeAssertionsPass_SafeToRemoveTrue(t *testing.T) {
	dep := &fakeInlineVerifyDep{
		activeRet:    true,
		authorityRet: uninstall.AuthorityExternal,
		safeRet:      true,
	}
	res := InlineVerify(context.Background(), dep, "csf", uninstall.AuthorityExternal)
	if res.Err != nil {
		t.Fatalf("InlineVerify err: %v", res.Err)
	}
	if !res.TargetFirewallActive {
		t.Errorf("TargetFirewallActive = false; want true")
	}
	if !res.AuthorityClassCorrect {
		t.Errorf("AuthorityClassCorrect = false; want true")
	}
	if !res.SafetyNetRemovalSafe {
		t.Errorf("SafetyNetRemovalSafe = false; want true")
	}
	if !res.SafeToRemove {
		t.Errorf("SafeToRemove = false; want true (all three assertions passed)")
	}
	if res.ObservedAuthority != uninstall.AuthorityExternal {
		t.Errorf("ObservedAuthority = %q; want %q", res.ObservedAuthority, uninstall.AuthorityExternal)
	}
	// Three calls, one per assertion, in order.
	if dep.activeCalls != 1 || dep.authorityCalls != 1 || dep.safeCalls != 1 {
		t.Errorf("call counts = (active=%d, authority=%d, safe=%d); want (1,1,1)",
			dep.activeCalls, dep.authorityCalls, dep.safeCalls)
	}
	if dep.lastFirewallType != "csf" {
		t.Errorf("dep saw firewallType %q; want %q", dep.lastFirewallType, "csf")
	}
}

// =============================================================================
// 2. Assertion 1 fails (target firewall inactive) → SafeToRemove false
// =============================================================================

func TestInlineVerify_TargetFirewallInactive(t *testing.T) {
	dep := &fakeInlineVerifyDep{
		activeRet:    false, // <— this is the failing assertion
		authorityRet: uninstall.AuthorityExternal,
		safeRet:      true,
	}
	res := InlineVerify(context.Background(), dep, "csf", uninstall.AuthorityExternal)
	if res.Err != nil {
		t.Fatalf("dep didn't error; verification should NOT report Err for assertion-failure: %v", res.Err)
	}
	if res.TargetFirewallActive {
		t.Errorf("TargetFirewallActive = true; want false")
	}
	if res.SafeToRemove {
		t.Errorf("SafeToRemove = true on inactive target; §21.1 hard fail")
	}
}

// =============================================================================
// 3. Assertion 2 fails (authority class wrong) → SafeToRemove false
// =============================================================================

func TestInlineVerify_AuthorityClassWrong(t *testing.T) {
	dep := &fakeInlineVerifyDep{
		activeRet:    true,
		authorityRet: uninstall.AuthorityNFTBan, // <— not the expected External
		safeRet:      true,
	}
	res := InlineVerify(context.Background(), dep, "csf", uninstall.AuthorityExternal)
	if res.Err != nil {
		t.Fatalf("verification should not Err on assertion-fail: %v", res.Err)
	}
	if res.AuthorityClassCorrect {
		t.Errorf("AuthorityClassCorrect = true; observed=%q expected=%q",
			res.ObservedAuthority, uninstall.AuthorityExternal)
	}
	if res.SafeToRemove {
		t.Errorf("SafeToRemove = true on wrong authority; §21.1 hard fail")
	}
}

// =============================================================================
// 4. Assertion 3 fails (safety-net removal not safe) → SafeToRemove false
// =============================================================================

func TestInlineVerify_SafetyNetRemovalUnsafe(t *testing.T) {
	dep := &fakeInlineVerifyDep{
		activeRet:    true,
		authorityRet: uninstall.AuthorityExternal,
		safeRet:      false, // <— failing assertion
	}
	res := InlineVerify(context.Background(), dep, "csf", uninstall.AuthorityExternal)
	if res.Err != nil {
		t.Fatalf("verification should not Err on assertion-fail: %v", res.Err)
	}
	if res.SafetyNetRemovalSafe {
		t.Errorf("SafetyNetRemovalSafe = true; want false")
	}
	if res.SafeToRemove {
		t.Errorf("SafeToRemove = true; §21.3 hard invariant — must be false on unsafe-removal")
	}
}

// =============================================================================
// 5. Multiple assertions fail simultaneously
// =============================================================================

func TestInlineVerify_MultipleAssertionsFail(t *testing.T) {
	dep := &fakeInlineVerifyDep{
		activeRet:    false,
		authorityRet: uninstall.AuthorityNone,
		safeRet:      false,
	}
	res := InlineVerify(context.Background(), dep, "iptables", uninstall.AuthorityExternal)
	if res.Err != nil {
		t.Fatalf("verification should not Err: %v", res.Err)
	}
	if res.SafeToRemove {
		t.Errorf("SafeToRemove = true with all assertions failing")
	}
}

// =============================================================================
// 6. Dep error on assertion 1 short-circuits
// =============================================================================

func TestInlineVerify_DepErrorAssertion1(t *testing.T) {
	depErr := errors.New("simulated assertion-1 failure")
	dep := &fakeInlineVerifyDep{activeErr: depErr}
	res := InlineVerify(context.Background(), dep, "csf", uninstall.AuthorityExternal)
	if res.Err == nil {
		t.Fatalf("expected Err on dep failure")
	}
	if !errors.Is(res.Err, ErrInlineVerifyDepFailed) {
		t.Errorf("wrong error class: %v", res.Err)
	}
	if !strings.Contains(res.Err.Error(), "simulated assertion-1 failure") {
		t.Errorf("dep error not surfaced: %v", res.Err)
	}
	// Short-circuited: assertion 2 and 3 must not have been called.
	if dep.authorityCalls != 0 || dep.safeCalls != 0 {
		t.Errorf("dep error in assertion 1 must short-circuit later calls; got authority=%d safe=%d",
			dep.authorityCalls, dep.safeCalls)
	}
	if res.SafeToRemove {
		t.Errorf("SafeToRemove = true on dep-error path; want false")
	}
}

// =============================================================================
// 7. Dep error on assertion 2 short-circuits assertion 3
// =============================================================================

func TestInlineVerify_DepErrorAssertion2(t *testing.T) {
	depErr := errors.New("simulated classify failure")
	dep := &fakeInlineVerifyDep{activeRet: true, authorityErr: depErr}
	res := InlineVerify(context.Background(), dep, "csf", uninstall.AuthorityExternal)
	if res.Err == nil {
		t.Fatalf("expected Err")
	}
	if !errors.Is(res.Err, ErrInlineVerifyDepFailed) {
		t.Errorf("wrong error class: %v", res.Err)
	}
	if dep.safeCalls != 0 {
		t.Errorf("dep error in assertion 2 must short-circuit assertion 3; safeCalls=%d", dep.safeCalls)
	}
}

// =============================================================================
// 8. Dep error on assertion 3 — partial result still returned
// =============================================================================

func TestInlineVerify_DepErrorAssertion3(t *testing.T) {
	depErr := errors.New("simulated removal-safety failure")
	dep := &fakeInlineVerifyDep{
		activeRet:    true,
		authorityRet: uninstall.AuthorityExternal,
		safeErr:      depErr,
	}
	res := InlineVerify(context.Background(), dep, "csf", uninstall.AuthorityExternal)
	if res.Err == nil {
		t.Fatalf("expected Err")
	}
	if !errors.Is(res.Err, ErrInlineVerifyDepFailed) {
		t.Errorf("wrong error class: %v", res.Err)
	}
	// First two assertion outcomes are preserved on the error path.
	if !res.TargetFirewallActive {
		t.Errorf("TargetFirewallActive = false; partial result should preserve assertion 1")
	}
	if !res.AuthorityClassCorrect {
		t.Errorf("AuthorityClassCorrect = false; partial result should preserve assertion 2")
	}
	// SafetyNetRemovalSafe stays false on dep-error path; SafeToRemove false.
	if res.SafetyNetRemovalSafe {
		t.Errorf("SafetyNetRemovalSafe = true on dep-error; want zero value")
	}
	if res.SafeToRemove {
		t.Errorf("SafeToRemove = true on dep-error; want false")
	}
}

// =============================================================================
// 9. Nil dep refuses cleanly
// =============================================================================

func TestInlineVerify_NilDep(t *testing.T) {
	res := InlineVerify(context.Background(), nil, "csf", uninstall.AuthorityExternal)
	if res.Err == nil {
		t.Fatalf("expected Err on nil dep")
	}
	if !errors.Is(res.Err, ErrInlineVerifyNilDep) {
		t.Errorf("wrong error class: %v", res.Err)
	}
	if res.SafeToRemove {
		t.Errorf("SafeToRemove = true on nil-dep path")
	}
}

// =============================================================================
// 10. Empty firewallType refused (caller must resolve panel before
//      calling — see ResolvePanelFirewall)
// =============================================================================

func TestInlineVerify_EmptyFirewallType(t *testing.T) {
	dep := &fakeInlineVerifyDep{}
	res := InlineVerify(context.Background(), dep, "", uninstall.AuthorityExternal)
	if res.Err == nil {
		t.Fatalf("expected Err on empty firewallType")
	}
	if !errors.Is(res.Err, ErrInlineVerifyEmptyFirewallType) {
		t.Errorf("wrong error class: %v", res.Err)
	}
	// dep must not have been called.
	if dep.activeCalls != 0 {
		t.Errorf("dep was called with empty firewallType; activeCalls=%d", dep.activeCalls)
	}
}

// =============================================================================
// 11. Invalid expectedAuthority refused (Ambiguous / unknown / empty)
// =============================================================================

func TestInlineVerify_InvalidExpectedAuthority(t *testing.T) {
	dep := &fakeInlineVerifyDep{}
	cases := []uninstall.CurrentAuthority{
		uninstall.AuthorityAmbiguous,
		uninstall.CurrentAuthority(""),
		uninstall.CurrentAuthority("not-a-class"),
	}
	for _, c := range cases {
		t.Run(string(c), func(t *testing.T) {
			res := InlineVerify(context.Background(), dep, "csf", c)
			if res.Err == nil {
				t.Fatalf("expected Err on invalid expectedAuthority %q", c)
			}
			if !errors.Is(res.Err, ErrInlineVerifyInvalidAuthority) {
				t.Errorf("wrong error class for %q: %v", c, res.Err)
			}
		})
	}
}

// =============================================================================
// 12. Acceptable expected authorities (valid set)
// =============================================================================

func TestInlineVerify_AcceptableExpectedAuthorities(t *testing.T) {
	for _, c := range []uninstall.CurrentAuthority{
		uninstall.AuthorityExternal,
		uninstall.AuthorityNFTBan,
		uninstall.AuthorityNone,
	} {
		t.Run(string(c), func(t *testing.T) {
			dep := &fakeInlineVerifyDep{
				activeRet:    true,
				authorityRet: c,
				safeRet:      true,
			}
			res := InlineVerify(context.Background(), dep, "csf", c)
			if res.Err != nil {
				t.Fatalf("unexpected Err: %v", res.Err)
			}
			if !res.SafeToRemove {
				t.Errorf("SafeToRemove = false on happy-path with expected=%q", c)
			}
		})
	}
}

// =============================================================================
// 13. No PR-26 / full-validator behavior — file-scan
// =============================================================================

func TestInlineVerify_NoFullValidatorBehavior_FileScan(t *testing.T) {
	// inline_verify.go must NOT reach for the full nftban-validate
	// binary, must NOT call broader module-health probes, must NOT
	// shell out, must NOT mutate.
	// Forbidden patterns. Concrete mutation/discovery surfaces only —
	// "PR-26" and "verification gate" are intentionally NOT forbidden
	// because the production-code comments legitimately document what
	// this primitive does NOT do, and substring matching can't tell
	// "is" from "is not".
	forbidden := []string{
		"os/exec",
		"exec.Command",
		"os.WriteFile",
		"os.Create",
		"os.Remove(",
		"os.Rename",
		"syscall.",
		`"nft "`,
		`"systemctl `,
		"nftban-validate",    // full validator binary
		"validator.Validate", // full validator function (if any)
		"botguard",
		"loginmon",
		"ddos",
		"portscan",
		"feeds",
		"geoip",
	}
	body, err := readSelf("inline_verify.go")
	if err != nil {
		t.Fatalf("read inline_verify.go: %v", err)
	}
	for _, pat := range forbidden {
		if strings.Contains(body, pat) {
			t.Errorf("inline_verify.go references forbidden pattern %q (PR-26 / full-validator surface)", pat)
		}
	}
}

// (No host-mutation file-scan on the test file itself: that test would
// be circular — listing forbidden patterns as string literals would
// make the file match its own forbidden list. The production-code
// file-scan in TestInlineVerify_NoFullValidatorBehavior_FileScan above
// is the real enforcement; tests in this file use the fake exclusively,
// by construction.)
