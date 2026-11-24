// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package render

// v1.238 D4: when the operator's declared SSH_PORT differs from the detected port, the installer says
// so; the detected port is still written (lockout prevention unchanged).

import (
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
)

func TestPersistSSHPortReportsDeclaredVsDetected(t *testing.T) {
	m := executor.NewMockExecutor()
	m.Files[confLocal] = []byte("# operator\nSSH_PORT=\"2222\"\nTCP_PORTS_IN=\"2222,443\"\n")
	log := newTestLogger()
	PersistSSHPort(m, 22, log)
	w := strings.Join(log.Warnings(), "\n")
	if !strings.Contains(w, "declared SSH_PORT=2222") || !strings.Contains(w, "detected on this host is 22") {
		t.Fatalf("missing declared/detected finding: %q", w)
	}
	if got := string(m.WrittenFiles[confLocal]); !strings.Contains(got, "SSH_PORT=22\n") {
		t.Fatalf("detected port not written (lockout prevention): %q", got)
	}
}

func TestPersistSSHPortSilentWhenSame(t *testing.T) {
	m := executor.NewMockExecutor()
	m.Files[confLocal] = []byte("SSH_PORT=22\nTCP_PORTS_IN=\"22\"\n")
	log := newTestLogger()
	PersistSSHPort(m, 22, log)
	for _, w := range log.Warnings() {
		if strings.Contains(w, "declared SSH_PORT") {
			t.Fatalf("unexpected finding when declared == detected: %q", w)
		}
	}
}
