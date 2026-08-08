// =============================================================================
// NFTBan v1.73 - Installer Mock Executor
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-executor-mock"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="In-memory mock executor for unit testing"
// meta:inventory.files="internal/installer/executor/mock.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package executor

import (
	"context"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"
)

// MockExecutor implements Executor with in-memory state for testing.
type MockExecutor struct {
	mu sync.Mutex

	// Commands records every command executed (for assertion).
	Commands []RecordedCommand

	// RunResults maps "name:arg1:arg2" to a preset Result.
	// If a command is not in RunResults it returns exit 0 with empty output —
	// UNLESS StrictUnregistered is set, which turns an unmatched key into a loud
	// exit-255 failure instead of a silent success. Note the key is derived from
	// the COLON-JOINED argv, so adding or removing an argument in production code
	// invalidates every key for that command.
	RunResults map[string]Result

	// RunResultSeq maps a command key ("name:arg1:arg2") to an ORDERED list of
	// Results; each Run of that exact key returns the next element in sequence.
	// TEST-ONLY (v1.223.0 verdict-truth): lets a test model live systemd state
	// CHANGING between two internal validation passes (e.g. VALIDATE_1
	// FALLBACK_UNDERSIZED then VALIDATE_2 ACTIVE_MATCH). When a key's sequence is
	// EXHAUSTED, Run returns a LOUD sentinel error Result (exit 255 + a marker on
	// Stderr) and still records the command, so an unexpected extra call is
	// detectable — it never silently falls back. Keys NOT present here fall through
	// to the existing static RunResults behavior EXACTLY (all other tests unchanged).
	// No production code path consults this map.
	RunResultSeq map[string][]Result
	seqCursor    map[string]int

	// Files maps path -> content for ReadFile/FileExists.
	Files map[string][]byte

	// FileStats maps path -> FileMeta for Stat. PR-26-code-C
	// addition. When a path is in Files but absent from FileStats,
	// Stat synthesizes a default-mode (0644 root:root) FileMeta with
	// Size derived from the in-memory content. Tests that need to
	// pin specific mode/uid/gid populate FileStats explicitly.
	FileStats map[string]FileMeta

	// WrittenFiles records what was written via WriteFileAtomic.
	WrittenFiles map[string][]byte

	// Dirs records directories created via MkdirAll.
	Dirs map[string]bool

	// NftTables maps "family:table" -> exists.
	NftTables map[string]bool
	// NftDeleteTableCalls records every NftDeleteTable invocation as
	// "family:table", in order. Deletion is destructive, so tests assert on
	// the CALL rather than only on the resulting state: a guard that must not
	// delete has to be shown never to have tried.
	NftDeleteTableCalls []string

	// NftSets maps "family:table:set" -> element list as string.
	NftSets map[string]string

	// Services maps "unit" -> active.
	Services map[string]bool

	// ServicesEnabled maps "unit" -> enabled (is-enabled). v1.135 timer assertion.
	ServicesEnabled map[string]bool

	// Users maps "name" -> exists.
	Users map[string]bool

	// Groups maps "name" -> exists.
	Groups map[string]bool

	// Env maps "key" -> value.
	Env map[string]string

	// ExistingCommands maps "name" -> exists.
	ExistingCommands map[string]bool

	// PR-26-code-B: typed-method error injection. When set non-nil,
	// the corresponding typed method returns the assigned error
	// instead of nil. Mirrors the RunResults pattern that controls
	// Run() exit codes.
	ServiceMaskErr        error
	ServiceUnmaskErr      error
	ServiceResetFailedErr error
	RenameErr             error
	// v1.222.1 Lane 2 edge tests: inject FS/systemd failures. When non-nil the
	// corresponding method returns the error (and performs no state change).
	WriteFileAtomicErr error
	MkdirAllErr        error
	DaemonReloadErr    error
	RemoveErr          error

	// StrictUnregistered makes an UNREGISTERED command key a LOUD failure
	// (exit 255 + a marker on Stderr) instead of the permissive zero-value
	// Result{ExitCode: 0}. Set this in any test that asserts a SPECIFIC exit
	// code, where a stale or missing fixture key must never be able to
	// masquerade as a successful command. See unregisteredResult. v1.228.5.
	StrictUnregistered bool

	// unmatched records every command key that ran without a registered Result,
	// in call order, regardless of StrictUnregistered. Read via UnmatchedCommands.
	unmatched []string

	// callbacks maps "name:args" -> function to call when command is executed.
	callbacks map[string]func()
}

// RecordedCommand tracks a command that was executed.
type RecordedCommand struct {
	Name string
	Args []string
}

var _ Executor = (*MockExecutor)(nil)

// NewMockExecutor creates a MockExecutor with all maps initialized.
func NewMockExecutor() *MockExecutor {
	return &MockExecutor{
		RunResults:       make(map[string]Result),
		RunResultSeq:     make(map[string][]Result),
		Files:            make(map[string][]byte),
		FileStats:        make(map[string]FileMeta),
		WrittenFiles:     make(map[string][]byte),
		Dirs:             make(map[string]bool),
		NftTables:        make(map[string]bool),
		NftSets:          make(map[string]string),
		Services:         make(map[string]bool),
		ServicesEnabled:  make(map[string]bool),
		Users:            make(map[string]bool),
		Groups:           make(map[string]bool),
		Env:              make(map[string]string),
		ExistingCommands: make(map[string]bool),
	}
}

func (m *MockExecutor) recordCommand(name string, args ...string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.Commands = append(m.Commands, RecordedCommand{Name: name, Args: args})
}

func (m *MockExecutor) lookupResult(name string, args ...string) (Result, bool) {
	key := name + ":" + strings.Join(args, ":")
	m.mu.Lock()
	defer m.mu.Unlock()
	r, ok := m.RunResults[key]
	return r, ok
}

func (m *MockExecutor) Run(name string, args ...string) Result {
	m.recordCommand(name, args...)
	// Fire callback if registered
	key := name + ":" + strings.Join(args, ":")
	m.mu.Lock()
	cb, hasCb := m.callbacks[key]
	m.mu.Unlock()
	if hasCb && cb != nil {
		cb()
	}
	// TEST-ONLY sequential responses take precedence over static RunResults for
	// keys explicitly populated in RunResultSeq (v1.223.0). Absent keys are
	// untouched and fall through to the static behavior below.
	if r, ok := m.nextSeqResult(name, args...); ok {
		return r
	}
	if r, ok := m.lookupResult(name, args...); ok {
		return r
	}
	return m.unregisteredResult(key)
}

// unregisteredResult decides what an UNREGISTERED command key returns, and always
// records it for post-hoc assertion via UnmatchedCommands.
//
// v1.228.5 — why this exists. The default fall-through below is PERMISSIVE: a key
// with no registered Result yields Result{ExitCode: 0}, i.e. a SUCCESSFUL command
// execution. That converts a missing test fixture into a passing command, so a
// negative test asserting a failure exit code can flip to a false pass with no
// diagnostic. This is not hypothetical: when switchop.Rebuild gained the
// --install-context argument, the argv-derived keys in rebuild_test.go went stale
// and three tests asserting exit 1 and exit 2 received exit 0 instead. The mock did
// not report a miss; it reported success.
//
// StrictUnregistered turns that into a LOUD failure using the SAME sentinel shape
// the RunResultSeq exhaustion path already uses (exit 255 + a marker on Stderr), so
// the harness has ONE recognisable "the fixture is wrong" signal rather than two.
//
// Strict is OPT-IN, deliberately. MEASURED in this checkout: 504 NewMockExecutor
// construction sites against 225 RunResults registrations, so the large majority of
// existing tests legitimately rely on the permissive default for commands whose
// result they do not care about. Flipping the default would fail hundreds of tests
// that have no defect, which is a migration of its own and not this lane's scope.
// Tests that assert a SPECIFIC exit code should set StrictUnregistered — for those,
// an unmatched key is never a valid outcome.
func (m *MockExecutor) unregisteredResult(key string) Result {
	m.mu.Lock()
	m.unmatched = append(m.unmatched, key)
	strict := m.StrictUnregistered
	m.mu.Unlock()
	if strict {
		return Result{
			ExitCode: 255,
			Stderr: "MockExecutor: UNREGISTERED command key " + key +
				" (no RunResults/RunResultSeq entry; refusing to report success)",
		}
	}
	return Result{ExitCode: 0}
}

// UnmatchedCommands returns every command key that ran without a registered
// Result, in call order. Recorded regardless of StrictUnregistered so a test can
// assert its fixtures actually matched even when it does not opt into strict mode.
func (m *MockExecutor) UnmatchedCommands() []string {
	m.mu.Lock()
	defer m.mu.Unlock()
	return append([]string(nil), m.unmatched...)
}

// nextSeqResult returns the next ordered Result for a command key registered in
// RunResultSeq, advancing that key's cursor. ok=false when the key is not
// registered (caller falls through to static RunResults). When the sequence is
// exhausted it returns a LOUD sentinel error Result (ok=true) so the test detects
// an unexpected extra call rather than silently getting a static/zero result.
func (m *MockExecutor) nextSeqResult(name string, args ...string) (Result, bool) {
	key := name + ":" + strings.Join(args, ":")
	m.mu.Lock()
	defer m.mu.Unlock()
	seq, ok := m.RunResultSeq[key]
	if !ok {
		return Result{}, false
	}
	if m.seqCursor == nil {
		m.seqCursor = make(map[string]int)
	}
	i := m.seqCursor[key]
	if i >= len(seq) {
		return Result{
			ExitCode: 255,
			Stderr:   "MockExecutor: RunResultSeq exhausted for key " + key + " (unexpected extra call)",
		}, true
	}
	m.seqCursor[key]++
	return seq[i], true
}

func (m *MockExecutor) RunContext(_ context.Context, name string, args ...string) Result {
	return m.Run(name, args...)
}

func (m *MockExecutor) RunTimeout(_ time.Duration, name string, args ...string) Result {
	return m.Run(name, args...)
}

func (m *MockExecutor) ReadFile(path string) ([]byte, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	data, ok := m.Files[path]
	if !ok {
		return nil, &os.PathError{Op: "open", Path: path, Err: os.ErrNotExist}
	}
	return data, nil
}

func (m *MockExecutor) WriteFileAtomic(path string, data []byte, _ os.FileMode) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.WriteFileAtomicErr != nil {
		return m.WriteFileAtomicErr // no partial write recorded (atomic contract)
	}
	m.WrittenFiles[path] = data
	m.Files[path] = data
	return nil
}

func (m *MockExecutor) FileExists(path string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	_, ok := m.Files[path]
	if ok {
		return true
	}
	_, ok = m.Dirs[path]
	return ok
}

func (m *MockExecutor) MkdirAll(path string, _ os.FileMode) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.MkdirAllErr != nil {
		return m.MkdirAllErr
	}
	m.Dirs[path] = true
	return nil
}

func (m *MockExecutor) Chown(_ string, _, _ int) error      { return nil }
func (m *MockExecutor) Chmod(_ string, _ os.FileMode) error { return nil }

func (m *MockExecutor) Remove(path string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.RemoveErr != nil {
		return m.RemoveErr
	}
	delete(m.Files, path)
	delete(m.Dirs, path)
	return nil
}

func (m *MockExecutor) Symlink(_, _ string) error { return nil }

// Stat returns FileMeta from FileStats if explicitly set; otherwise
// synthesizes a default-mode (0644 root:root) entry with Size derived
// from the in-memory content. Returns os.ErrNotExist if neither
// FileStats nor Files contains the path. PR-26-code-C addition.
func (m *MockExecutor) Stat(path string) (FileMeta, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if meta, ok := m.FileStats[path]; ok {
		return meta, nil
	}
	if data, ok := m.Files[path]; ok {
		return FileMeta{Mode: 0644, UID: 0, GID: 0, Size: int64(len(data))}, nil
	}
	return FileMeta{}, &os.PathError{Op: "stat", Path: path, Err: os.ErrNotExist}
}

// Rename simulates atomic rename in the mock's in-memory file map and
// records a "rename" command for trace assertions. Returns
// m.RenameErr (nil by default); when non-nil, the file map is left
// unchanged (matching real-world atomic-rename failure semantics).
// PR-26-code-B addition.
func (m *MockExecutor) Rename(oldpath, newpath string) error {
	m.recordCommand("rename", oldpath, newpath)
	if m.RenameErr != nil {
		return m.RenameErr
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if data, ok := m.Files[oldpath]; ok {
		m.Files[newpath] = data
		delete(m.Files, oldpath)
	}
	return nil
}

// --- nftables ---

func (m *MockExecutor) NftTableExists(family, table string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.NftTables[family+":"+table]
}

func (m *MockExecutor) NftListSet(family, table, set string) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	key := family + ":" + table + ":" + set
	data, ok := m.NftSets[key]
	if !ok {
		return "", fmt.Errorf("set %s does not exist", key)
	}
	return data, nil
}

func (m *MockExecutor) NftAddElement(family, table, set string, element string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	key := family + ":" + table + ":" + set
	existing := m.NftSets[key]
	if existing == "" {
		m.NftSets[key] = element
	} else {
		m.NftSets[key] = existing + ", " + element
	}
	return nil
}

func (m *MockExecutor) NftDeleteTable(family, table string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.NftDeleteTableCalls = append(m.NftDeleteTableCalls, family+":"+table)
	delete(m.NftTables, family+":"+table)
	return nil
}

func (m *MockExecutor) NftCheck(_ string) error { return nil }

// --- systemd ---

func (m *MockExecutor) ServiceActive(unit string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.Services[unit]
}

func (m *MockExecutor) ServiceEnabled(unit string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.ServicesEnabled[unit]
}

func (m *MockExecutor) ServiceEnable(unit string) error {
	m.recordCommand("systemctl", "enable", unit)
	m.mu.Lock()
	m.ServicesEnabled[unit] = true
	m.mu.Unlock()
	return nil
}

func (m *MockExecutor) ServiceStart(unit string) error {
	m.recordCommand("systemctl", "start", unit)
	m.mu.Lock()
	m.Services[unit] = true
	m.mu.Unlock()
	return nil
}

// ServiceTryRestart records a try-restart; it cycles (keeps active) iff the unit is
// currently active, mirroring `systemctl try-restart` (no-op when inactive). v1.185.
func (m *MockExecutor) ServiceTryRestart(unit string) error {
	m.recordCommand("systemctl", "try-restart", unit)
	// active stays active (a cycle); inactive stays inactive (no-op). No state flip.
	return nil
}

func (m *MockExecutor) ServiceStop(unit string) error {
	m.recordCommand("systemctl", "stop", unit)
	m.mu.Lock()
	m.Services[unit] = false
	m.mu.Unlock()
	return nil
}

func (m *MockExecutor) ServiceDisable(unit string) error {
	m.recordCommand("systemctl", "disable", unit)
	m.mu.Lock()
	m.ServicesEnabled[unit] = false
	m.mu.Unlock()
	return nil
}

func (m *MockExecutor) ServiceMask(unit string) error {
	m.recordCommand("systemctl", "mask", unit)
	return m.ServiceMaskErr
}

// ServiceUnmask records a systemctl unmask call and returns
// m.ServiceUnmaskErr (nil by default). Mirrors ServiceMask semantics
// for parity. PR-26-code-B addition.
func (m *MockExecutor) ServiceUnmask(unit string) error {
	m.recordCommand("systemctl", "unmask", unit)
	return m.ServiceUnmaskErr
}

// ServiceResetFailed records a systemctl reset-failed call and returns
// m.ServiceResetFailedErr (nil by default). Mirrors ServiceUnmask
// semantics for parity. PR-P1 addition (closes #524).
func (m *MockExecutor) ServiceResetFailed(unit string) error {
	m.recordCommand("systemctl", "reset-failed", unit)
	return m.ServiceResetFailedErr
}

func (m *MockExecutor) DaemonReload() error {
	m.recordCommand("systemctl", "daemon-reload")
	return m.DaemonReloadErr
}

// --- System ---

func (m *MockExecutor) CommandExists(name string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.ExistingCommands[name]
}

func (m *MockExecutor) UserExists(name string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.Users[name]
}

func (m *MockExecutor) GroupExists(name string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.Groups[name]
}

func (m *MockExecutor) Getenv(key string) string {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.Env[key]
}

// ─── v1.98 test helpers ─────────────────────────────────────────────────────

// OnCommand registers a callback that fires when a specific command is executed.
// Use for simulating side-effects (e.g., fixing a service state after permissions enforce).
func (m *MockExecutor) OnCommand(fn func(), name string, args ...string) {
	key := name + ":" + strings.Join(args, ":")
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.callbacks == nil {
		m.callbacks = make(map[string]func())
	}
	m.callbacks[key] = fn
}

// CommandCalled returns true if a command matching the given name and args prefix was recorded.
func (m *MockExecutor) CommandCalled(nameAndArgs ...string) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, cmd := range m.Commands {
		if matchCommand(cmd, nameAndArgs) {
			return true
		}
	}
	return false
}

// CommandCallCount returns how many times a command matching the given prefix was recorded.
func (m *MockExecutor) CommandCallCount(nameAndArgs ...string) int {
	m.mu.Lock()
	defer m.mu.Unlock()
	count := 0
	for _, cmd := range m.Commands {
		if matchCommand(cmd, nameAndArgs) {
			count++
		}
	}
	return count
}

func matchCommand(cmd RecordedCommand, prefix []string) bool {
	if len(prefix) == 0 {
		return false
	}
	// Match command name (may be full path)
	if !strings.HasSuffix(cmd.Name, prefix[0]) && cmd.Name != prefix[0] {
		// Also check if it's an arg match (e.g., "nftban" "permissions" "enforce")
		allParts := append([]string{cmd.Name}, cmd.Args...)
		return containsSubsequence(allParts, prefix)
	}
	if len(prefix) == 1 {
		return true
	}
	return containsSubsequence(cmd.Args, prefix[1:])
}

func containsSubsequence(haystack, needle []string) bool {
	if len(needle) > len(haystack) {
		return false
	}
	for i := 0; i <= len(haystack)-len(needle); i++ {
		match := true
		for j, n := range needle {
			if haystack[i+j] != n {
				match = false
				break
			}
		}
		if match {
			return true
		}
	}
	return false
}
