// =============================================================================
// NFTBan v1.73 - Installer CT Limits Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-detect-ctlimits-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Tests for DDoS connection tracking limit reads"
// meta:inventory.files="internal/installer/detect/ctlimits_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package detect

import (
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
)

func TestReadCTLimits_Defaults(t *testing.T) {
	mock := executor.NewMockExecutor()
	limits := ReadCTLimits(mock, newTestLogger())
	if limits.SSH != 15 {
		t.Errorf("SSH = %d, want 15", limits.SSH)
	}
	if limits.HTTP != 200 {
		t.Errorf("HTTP = %d, want 200", limits.HTTP)
	}
	if limits.Mail != 30 {
		t.Errorf("Mail = %d, want 30", limits.Mail)
	}
}

func TestReadCTLimits_FromConfig(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Files[ddosConfPath] = []byte(`# DDoS Classic Config
DDOS_CLASSIC_SSH_CONN_LIMIT="25"
DDOS_CLASSIC_HTTP_CONN_LIMIT="500"
DDOS_CLASSIC_SMTP_CONN_LIMIT="50"
`)

	limits := ReadCTLimits(mock, newTestLogger())
	if limits.SSH != 25 {
		t.Errorf("SSH = %d, want 25", limits.SSH)
	}
	if limits.HTTP != 500 {
		t.Errorf("HTTP = %d, want 500", limits.HTTP)
	}
	if limits.Mail != 50 {
		t.Errorf("Mail = %d, want 50", limits.Mail)
	}
}

func TestReadCTLimits_LocalOverride(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Files[ddosConfPath] = []byte(`DDOS_CLASSIC_SSH_CONN_LIMIT="15"
DDOS_CLASSIC_HTTP_CONN_LIMIT="200"
`)
	mock.Files[ddosConfLocalPath] = []byte(`# Local override: increase SSH limit
DDOS_CLASSIC_SSH_CONN_LIMIT="100"
`)

	limits := ReadCTLimits(mock, newTestLogger())
	if limits.SSH != 100 {
		t.Errorf("SSH = %d, want 100 (local override)", limits.SSH)
	}
	if limits.HTTP != 200 {
		t.Errorf("HTTP = %d, want 200 (from main config)", limits.HTTP)
	}
}

func TestReadCTLimits_InvalidValues(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Files[ddosConfPath] = []byte(`DDOS_CLASSIC_SSH_CONN_LIMIT="abc"
DDOS_CLASSIC_HTTP_CONN_LIMIT="-5"
DDOS_CLASSIC_SMTP_CONN_LIMIT="0"
`)

	limits := ReadCTLimits(mock, newTestLogger())
	// All invalid → defaults
	if limits.SSH != 15 {
		t.Errorf("SSH = %d, want 15 (default for invalid)", limits.SSH)
	}
	if limits.HTTP != 200 {
		t.Errorf("HTTP = %d, want 200 (default for negative)", limits.HTTP)
	}
	if limits.Mail != 30 {
		t.Errorf("Mail = %d, want 30 (default for zero)", limits.Mail)
	}
}
