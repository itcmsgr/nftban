// =============================================================================
// NFTBan v1.148 - DisarmSystemConf (Shape-B include restore-disarm) tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="render-disarm-v148-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.148 DisarmSystemConf (Shape-B include restore-strip) unit tests"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// DisarmSystemConf is the restore-time inverse of IntegrateSystemConf: it strips
// the nftban-managed include from the distro nftables.conf so nftables.service
// cannot recreate ip/ip6 nftban tables on boot. Must preserve non-nftban
// content, back up before editing, and be idempotent.
// =============================================================================

package render

import (
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

func TestDisarmSystemConf_StripsIncludePreservesRest_v148(t *testing.T) {
	log := logging.New("", false)
	const conf = "/etc/nftables.conf"
	armed := "#!/usr/sbin/nft -f\n" +
		"table inet operator_fw { chain c { type filter hook input priority 0; } }\n" +
		IncludeBeginMarker + "\n" + IncludeDirective + "\n" + IncludeEndMarker + "\n"

	m := executor.NewMockExecutor()
	m.Files[conf] = []byte(armed)
	if err := DisarmSystemConf(m, conf, log); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	out := string(m.Files[conf])
	if strings.Contains(out, "/etc/nftban/nftables.conf") {
		t.Errorf("nftban include not stripped from %s:\n%s", conf, out)
	}
	if strings.Contains(out, IncludeBeginMarker) || strings.Contains(out, IncludeEndMarker) {
		t.Errorf("fence markers not removed")
	}
	if !strings.Contains(out, "table inet operator_fw") {
		t.Errorf("non-nftban operator content was lost")
	}
	// Backup written before editing.
	if _, ok := m.WrittenFiles[conf+".nftban-restore.bak"]; !ok {
		t.Errorf("no backup written before disarm")
	}
}

func TestDisarmSystemConf_Idempotent_v148(t *testing.T) {
	log := logging.New("", false)
	const conf = "/etc/nftables.conf"
	// Already free of the nftban include.
	clean := "#!/usr/sbin/nft -f\ntable inet operator_fw { }\n"
	m := executor.NewMockExecutor()
	m.Files[conf] = []byte(clean)
	if err := DisarmSystemConf(m, conf, log); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if _, ok := m.WrittenFiles[conf]; ok {
		t.Errorf("idempotent disarm rewrote a file with no nftban include")
	}
	if _, ok := m.WrittenFiles[conf+".nftban-restore.bak"]; ok {
		t.Errorf("idempotent disarm wrote a backup unnecessarily")
	}
}

func TestDisarmSystemConf_AbsentFile_NoOp_v148(t *testing.T) {
	log := logging.New("", false)
	m := executor.NewMockExecutor()
	if err := DisarmSystemConf(m, "/etc/sysconfig/nftables.conf", log); err != nil {
		t.Fatalf("absent file should be a no-op, got: %v", err)
	}
}
