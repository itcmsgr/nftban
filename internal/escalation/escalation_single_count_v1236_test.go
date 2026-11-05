// =============================================================================
// NFTBan v1.236 - one genuine ban = one escalation contribution
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="escalation-single-count-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-22"
// meta:description="BUG-ESCALATION-TEMP-BAN-WRITES-TWO-BANNED-ROWS: CountRecentBans skips the pre-v1.236 'temp ban from <src>' echo rows (no BAN_ID); no escalation path calls LogTempBan"
// meta:inventory.files="internal/escalation/escalation_single_count_v1236_test.go"
// meta:inventory.privileges="none"
// =============================================================================

package escalation

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The lab2 shape (bans.log 2026-10-20): each genuine module ban (BAN_ID set) followed
// by its echo row "temp ban from loginmon" (country UNK, no BAN_ID, timeout 0).
func TestCountRecentBansSkipsEscalationEchoRows(t *testing.T) {
	path := filepath.Join(t.TempDir(), "bans.log")
	now := time.Now()
	d, tm := now.Format("2006-01-02"), now.Format("15:04:05")
	var lines []string
	for i := 0; i < 5; i++ {
		lines = append(lines,
			fmt.Sprintf("%s|%s|login|61.222.211.114|TW|BANNED|ssh_preauth_disconnect|%016x|900|temp", d, tm, i+1),
			fmt.Sprintf("%s|%s|loginmon|61.222.211.114|UNK|BANNED|temp ban from loginmon||0|temp", d, tm))
	}
	// A genuine ban whose operator reason happens to start like an echo still counts:
	// it carries a BAN_ID.
	lines = append(lines, fmt.Sprintf("%s|%s|manual|61.222.211.114|TW|BANNED|temp ban from manual review|abcd|600|manual", d, tm))
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := CountRecentBans(path, "61.222.211.114", time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	if got != 6 {
		t.Fatalf("CountRecentBans = %d, want 6 genuine bans (the 5 echo rows are not bans; pre-v1.236 this read 11 and escalated at threshold 10 after 5 real bans)", got)
	}
}

// No escalation path may write a second row for a ban (source guard).
func TestNoEscalationPathCallsLogTempBan(t *testing.T) {
	for _, f := range []string{"../../cmd/nftband/daemon_handlers_ban.go", "../../cmd/nftban-core/cmd_ban.go"} {
		src, err := os.ReadFile(f)
		if err != nil {
			t.Fatalf("read %s: %v", f, err)
		}
		if strings.Contains(string(src), "escalation.LogTempBan(") {
			t.Fatalf("%s calls escalation.LogTempBan: every temp ban would count twice toward the persistent-offender threshold", f)
		}
	}
}
