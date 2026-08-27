// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
package switchop

import (
	"fmt"
	"os"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
)

// publishResult installs a RunHook that plays the role of the SHELL: it reads the
// --result-file / --operation-id the installer allocated and publishes a final record.
//
// ⛔ THIS IS THE CONTRACT UNDER TEST. A mock that does NOT call this is simulating a shell
// that published nothing — which MUST be fatal. Several legacy tests relied on rc alone and
// are migrated accordingly.
// redirectResultDir points the per-operation result base at a test temp dir. CI runners are
// not root and cannot write /run/nftban; production keeps the tmpfs path.
func redirectResultDir(t *testing.T) {
	t.Helper()
	old := rebuildResultBaseDir
	rebuildResultBaseDir = t.TempDir()
	t.Cleanup(func() { rebuildResultBaseDir = old })
}

func publishResult(t *testing.T, m *executor.MockExecutor, disposition string, rc int, extra map[string]string) {
	t.Helper()
	redirectResultDir(t)
	m.RunHook = func(_ string, args []string) (executor.Result, bool) {
		var path, opID string
		for i, a := range args {
			if a == "--result-file" && i+1 < len(args) {
				path = args[i+1]
			}
			if a == "--operation-id" && i+1 < len(args) {
				opID = args[i+1]
			}
		}
		if path == "" {
			return executor.Result{}, false
		}
		if v, ok := extra["operation_id"]; ok { // stale/foreign-record cases
			opID = v
		}
		committed := "false"
		txReason := "FAILURE"
		switch disposition {
		case "COMPLETE":
			committed, txReason = "true", "COMMITTED"
		case "DEFERRED_RUNTIME":
			txReason = "DEFERRED_CONVERGENCE"
		}
		schema := "1"
		if v, ok := extra["schema_version"]; ok {
			schema = v
		}
		body := fmt.Sprintf(`{"schema_version":%q,"operation_id":%q,"context":"install-deferred",
"disposition":%q,"reason_codes":["TEST"],"rollback_performed":false,
"transaction":{"committed":%s,"reason":%q},"retry":{"reason":"NONE"},
"pre_status":"protected","post_status":"degraded","emitted_at":"2026-08-27T00:00:00Z"}`,
			schema, opID, disposition, committed, txReason)
		if v, ok := extra["raw"]; ok {
			body = v
		}
		_ = os.MkdirAll(strings.TrimSuffix(path, "/"+path[strings.LastIndex(path, "/")+1:]), 0o750)
		_ = os.WriteFile(path, []byte(body), 0o640)
		return executor.Result{ExitCode: rc}, true
	}
}

// runNoRecord plays a shell that EXITS WITHOUT PUBLISHING A RECORD — the legacy
// rc/text-only behaviour. Under the new contract this must never authorize continuation,
// whatever the rc or the human-readable text says.
func runNoRecord(t *testing.T, m *executor.MockExecutor, rc int, stderr, stdout string) {
	t.Helper()
	redirectResultDir(t)
	m.RunHook = func(_ string, args []string) (executor.Result, bool) {
		for _, a := range args {
			if a == "--result-file" {
				return executor.Result{ExitCode: rc, Stderr: stderr, Stdout: stdout}, true
			}
		}
		return executor.Result{}, false
	}
}
