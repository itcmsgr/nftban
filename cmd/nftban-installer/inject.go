// SPDX-License-Identifier: MPL-2.0
// meta:name="nftban-installer-inject"
// meta:type="cmd"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-07-20"
// meta:description="v1.223.0 verdict-truth: per-call, data-only test-injection carrier for the installer validation path. PRODUCTION never constructs one (nil), so all default behavior is byte-identical: real host systemd-payload gather + canonical safety.HealthServiceMemoryLimits tier. Tests set the carrier on config/phaseData to force a deterministic host-class tier and a fixture systemd-payload input WITHOUT any mutable package global or var-func seam."
// meta:inventory.files="cmd/nftban-installer/inject.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
package main

import (
	lr "github.com/itcmsgr/nftban/internal/logretention"
	coresafety "github.com/itcmsgr/nftban/internal/safety"

	"github.com/itcmsgr/nftban/internal/installer/validate"
)

// assertionTestInjection is the DATA dependency-injection carrier threaded through
// config → phaseData for the validation path. It is NEVER populated in production
// (nil), so nothing about the default install/upgrade/repair/revalidate behavior
// changes: the systemd-payload assertions gather from the real host, and the
// health-resource verdict resolves against the canonical safety RAM-tier authority.
//
// Owner constraint: no mutable package globals, no `var xFunc = ...` seams, no new
// public API. The carrier is an unexported type with unexported fields set only by
// tests (never by flag parsing).
type assertionTestInjection struct {
	// systemdPayload, when non-nil, is used verbatim by RunAssertionsWithOpts
	// instead of gathering from the live host. A zero/empty value is validated
	// exactly like an empty real gather (fail-safe preserved — no PASS shortcut).
	systemdPayload *validate.SystemdPayloadInputs
	// healthProfile, when non-nil, forces a deterministic host-class tier into
	// ResolveHealthResourceVerdict so execution-path tests are host-independent.
	// nil → the canonical safety.HealthServiceMemoryLimits() (real /proc facts).
	healthProfile *coresafety.HealthResourceProfile
	// logRetentionValidator, when non-nil, overrides the logrotate policy validator
	// for the logretention_policy_ready assertion so execution-path tests do not
	// depend on the `logrotate` binary (absent in CI). nil → real `logrotate -d`.
	logRetentionValidator lr.Validator
}

// payload returns the injected systemd-payload input (nil-safe on a nil carrier).
func (i *assertionTestInjection) payload() *validate.SystemdPayloadInputs {
	if i == nil {
		return nil
	}
	return i.systemdPayload
}

// profile returns the injected health-resource profile (nil-safe on a nil carrier).
func (i *assertionTestInjection) profile() *coresafety.HealthResourceProfile {
	if i == nil {
		return nil
	}
	return i.healthProfile
}

// logValidator returns the injected logrotate validator (nil-safe on a nil carrier).
func (i *assertionTestInjection) logValidator() lr.Validator {
	if i == nil {
		return nil
	}
	return i.logRetentionValidator
}
