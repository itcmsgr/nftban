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
	// If a command is not in RunResults, it returns exit 0 with empty output.
	RunResults map[string]Result

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

	// NftSets maps "family:table:set" -> element list as string.
	NftSets map[string]string

	// Services maps "unit" -> active.
	Services map[string]bool

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
	ServiceUnmaskErr error
	RenameErr        error

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
		Files:            make(map[string][]byte),
		FileStats:        make(map[string]FileMeta),
		WrittenFiles:     make(map[string][]byte),
		Dirs:             make(map[string]bool),
		NftTables:        make(map[string]bool),
		NftSets:          make(map[string]string),
		Services:         make(map[string]bool),
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
	if r, ok := m.lookupResult(name, args...); ok {
		return r
	}
	return Result{ExitCode: 0}
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
	m.Dirs[path] = true
	return nil
}

func (m *MockExecutor) Chown(_ string, _, _ int) error { return nil }
func (m *MockExecutor) Chmod(_ string, _ os.FileMode) error { return nil }

func (m *MockExecutor) Remove(path string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
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

func (m *MockExecutor) ServiceEnable(unit string) error {
	m.recordCommand("systemctl", "enable", unit)
	return nil
}

func (m *MockExecutor) ServiceStart(unit string) error {
	m.recordCommand("systemctl", "start", unit)
	m.mu.Lock()
	m.Services[unit] = true
	m.mu.Unlock()
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
	return nil
}

func (m *MockExecutor) ServiceMask(unit string) error {
	m.recordCommand("systemctl", "mask", unit)
	return nil
}

// ServiceUnmask records a systemctl unmask call and returns
// m.ServiceUnmaskErr (nil by default). Mirrors ServiceMask semantics
// for parity. PR-26-code-B addition.
func (m *MockExecutor) ServiceUnmask(unit string) error {
	m.recordCommand("systemctl", "unmask", unit)
	return m.ServiceUnmaskErr
}

func (m *MockExecutor) DaemonReload() error {
	m.recordCommand("systemctl", "daemon-reload")
	return nil
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
