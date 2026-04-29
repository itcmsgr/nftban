// =============================================================================
// NFTBan v1.100.x PR26.3 - DirectAdmin Panel Adapter
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-panelfw-directadmin"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-29"
// meta:description="DirectAdmin adapter for the panelfw framework — first specimen under PR26.2 contract"
// meta:inventory.files="internal/installer/panelfw/adapters/directadmin/directadmin.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/usr/local/directadmin/conf/directadmin.conf"
// meta:inventory.systemd_units="directadmin.service"
// meta:inventory.network="tcp/2222 (or override per directadmin.conf)"
// meta:inventory.privileges="root"
// =============================================================================
//
// PR26.3 / PR26.4 — DirectAdmin adapter under the PR26.2 panelfw
// contract. First and only adapter shipped in this PR. cPanel/Plesk/
// etc. live in future PRs (PR26.5+) under the same framework.
//
// SCOPE
// -----
// CONTROL PLANE — ValidateReachability tests the DirectAdmin control
// port only (default TCP 2222, per-config override via
// directadmin.conf `port=N`). Failure ⇒ PANEL-SURVIVAL-001 fires
// unless --no-panel.
//
// FULL PORT SURFACE — RequiredPorts consults the canonical
// /etc/nftban/conf.d/panels/directadmin/main.conf via
// internal/ports/panel_loader.LoadPanelConfig("directadmin") and
// returns the conf.d-declared TCP_IN / UDP_IN port set. The adapter
// does NOT invent or duplicate a DirectAdmin port list. Conf.d wins
// over the legacy shell library (per the audit four-truth resolution:
// SSH port 22 is managed separately via /etc/nftban/ports.d/00-ssh.conf
// and is intentionally absent from panel TCP_IN).
//
// Fail-closed contract:
//   - Missing conf.d main.conf → RequiredPorts returns error →
//     PanelResult.Fatal=true via panelfw.finalizeDetected.
//   - Loaded conf.d with empty TCP_IN → returns error (a DirectAdmin
//     panel host with zero declared inbound ports is malformed).
//
// PR26.4 status (this commit):
//   - Full port-surface LOAD wired through panel_loader.
//   - Full port-surface REACHABILITY probing remains out of scope —
//     only the control plane is probed in ValidateReachability.
//   - The existing bash-subshell parser inside panel_loader is
//     untouched; its Go-native rewrite is PR26.7's lane.
//
// Read-only by interface contract:
//   - Detect:               filesystem stat + service-active query + ss listener parse
//   - RequiredPorts:        canonical conf.d load via panel_loader (read-only)
//   - ValidateReachability: ss -lnt output parse for the control port
//
// No new mutation surface in PR26.4: panel_loader's existing read-only
// bash-subshell sourcing is the only added I/O path.
//
// =============================================================================

package directadmin

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/fhs"
	"github.com/itcmsgr/nftban/internal/installer/panelfw"
	"github.com/itcmsgr/nftban/internal/ports"
)

// adapterID is the canonical PanelID for this adapter. Matches the
// detect.PanelDirectAdmin / nftban panel-name convention.
const adapterID panelfw.PanelID = "directadmin"

// Default control-panel port. DirectAdmin's installer ships TCP 2222
// as the default and operators rarely change it; the override lives
// in /usr/local/directadmin/conf/directadmin.conf as `port=N`.
const defaultPort = 2222

// Filesystem evidence paths. Constants kept here so test fixtures
// reference the same canonical names.
const (
	installDir    = "/usr/local/directadmin"
	binaryPath    = "/usr/local/directadmin/directadmin"
	configPath    = "/usr/local/directadmin/conf/directadmin.conf"
	systemdUnit   = "directadmin.service"
	confidenceKey = "port"
)

// panelConfDLoader is the function the adapter calls to load the
// canonical conf.d panel config. Defaults to the package-public
// internal/ports/panel_loader.LoadPanelConfig at process startup.
//
// Tests inject a fixture loader by writing to this var; production
// code never reassigns it. The seam is here (rather than passing the
// loader down through every call site) because PanelAdapter's
// interface is fixed by panelfw and we can't add a constructor
// argument without breaking the contract.
var panelConfDLoader func(configDir, panelName string) (*ports.PanelConfig, error) = ports.LoadPanelConfig

// panelConfDDir is the configDir argument supplied to the loader.
// Default: fhs.EtcDir ("/etc/nftban"). Tests override to a tempdir
// containing fixture conf.d/panels/directadmin/main.conf.
var panelConfDDir = fhs.EtcDir

// adapter is the package-private DirectAdmin adapter type. The
// framework receives it via Register(); callers should not construct
// or reach into it directly.
type adapter struct{}

// New returns a fresh adapter instance. Exposed for tests that need
// to call EvaluateAdapters with an explicit slice; production code
// uses init()/panelfw.Register and never sees the constructor.
func New() panelfw.PanelAdapter { return &adapter{} }

func init() {
	panelfw.Register(New())
}

// ID implements panelfw.PanelAdapter.
func (a *adapter) ID() panelfw.PanelID { return adapterID }

// Detect implements panelfw.PanelAdapter. Read-only.
//
// Evidence collected (in order):
//
//	E1 — /usr/local/directadmin/             (canonical install dir)
//	E2 — /usr/local/directadmin/directadmin  (panel binary)
//	E3 — directadmin.service active          (systemd-managed run)
//	E4 — TCP <port> in LISTEN state          (panel actually serving)
//
// Confidence rule: 3+ indicators ⇒ "strong"; 1–2 ⇒ "weak"; 0 ⇒
// Detected=false. The required port is always declared (default 2222
// or per-config override) so the framework's downstream consumers
// have a port to reason about even when the panel is not yet running.
func (a *adapter) Detect(ctx context.Context, exec executor.Executor) panelfw.PanelDetection {
	det := panelfw.PanelDetection{ID: adapterID}

	port := readConfiguredPort(exec)
	det.RequiredTCP = []int{port}

	signals := 0

	if exec.FileExists(installDir) {
		det.Evidence = append(det.Evidence, "install-dir-present:"+installDir)
		signals++
	}
	if exec.FileExists(binaryPath) {
		det.Evidence = append(det.Evidence, "binary-present:"+binaryPath)
		signals++
	}
	if exec.ServiceActive(systemdUnit) {
		det.Evidence = append(det.Evidence, "service-active:"+systemdUnit)
		signals++
	}
	if portInListenState(exec, port) {
		det.Evidence = append(det.Evidence, fmt.Sprintf("listener-tcp:%d", port))
		signals++
	}

	if signals == 0 {
		det.Detected = false
		return det
	}
	det.Detected = true
	if signals >= 3 {
		det.Confidence = "strong"
	} else {
		det.Confidence = "weak"
		det.Warnings = append(det.Warnings,
			fmt.Sprintf("only %d of 4 indicators present; partial install or stopped panel", signals))
	}
	return det
}

// RequiredPorts implements panelfw.PanelAdapter. Read-only.
//
// PR26.4: returns the canonical conf.d-declared DirectAdmin TCP_IN /
// UDP_IN port surface, loaded via internal/ports/panel_loader.LoadPanelConfig.
//
// The adapter does NOT invent a port list — it reports exactly what
// /etc/nftban/conf.d/panels/directadmin/main.conf declares. Conf.d
// wins over the legacy shell library; SSH port 22 is intentionally
// absent because /etc/nftban/ports.d/00-ssh.conf manages it
// separately.
//
// Fail-closed contract:
//   - Missing main.conf → returns error.
//   - Loaded with empty TCP_IN → returns error (malformed for a real
//     DirectAdmin host; an empty inbound list cannot serve the panel).
//
// On error, panelfw.finalizeDetected sets PanelResult.Fatal=true per
// PANEL-SURVIVAL-001 unless --no-panel.
func (a *adapter) RequiredPorts(ctx context.Context, exec executor.Executor) ([]int, []int, error) {
	cfg, err := panelConfDLoader(panelConfDDir, string(adapterID))
	if err != nil {
		return nil, nil, fmt.Errorf("DirectAdmin conf.d load failed: %w (path: %s/conf.d/panels/%s/main.conf)",
			err, panelConfDDir, string(adapterID))
	}
	if cfg == nil {
		return nil, nil, fmt.Errorf("DirectAdmin conf.d load returned nil PanelConfig")
	}
	if len(cfg.TCPIn) == 0 {
		return nil, nil, fmt.Errorf(
			"DirectAdmin conf.d declares no TCP_IN ports (malformed: %s) — "+
				"a real DirectAdmin host must declare its inbound port surface",
			cfg.ConfigFile)
	}
	// Conf.d is the authoritative source; copy slices defensively so
	// the caller cannot mutate the loader's cached values.
	tcp := append([]int(nil), cfg.TCPIn...)
	udp := append([]int(nil), cfg.UDPIn...)
	return tcp, udp, nil
}

// ValidateReachability implements panelfw.PanelAdapter. Read-only.
//
// Confirms the DirectAdmin **control-plane** TCP port is in LISTEN
// state. Returns nil on success; a structured error otherwise. Does
// NOT mutate ports, services, or rules.
//
// Scope is the control plane (default 2222) only. The full DirectAdmin
// service-port surface (mail/web/SSH/etc.) is NOT validated here —
// see the file-level "PR26.4 follow-up" comment.
func (a *adapter) ValidateReachability(ctx context.Context, exec executor.Executor) error {
	port := readConfiguredPort(exec)
	if portInListenState(exec, port) {
		return nil
	}
	return fmt.Errorf(
		"DirectAdmin control-plane port %d not in LISTEN state — control-plane unreachable "+
			"(note: this assertion validates the control plane only; full DirectAdmin port surface validated in PR26.4)",
		port)
}

// readConfiguredPort returns the configured control port from
// /usr/local/directadmin/conf/directadmin.conf, falling back to the
// default 2222 when the file is unreadable or has no `port=` line.
//
// The directadmin.conf format is `key=value` per line; we look for
// the first `port=N` entry and parse N. Whitespace/comments are
// tolerated.
func readConfiguredPort(exec executor.Executor) int {
	if !exec.FileExists(configPath) {
		return defaultPort
	}
	data, err := exec.ReadFile(configPath)
	if err != nil {
		return defaultPort
	}
	for _, raw := range strings.Split(string(data), "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		eq := strings.IndexByte(line, '=')
		if eq <= 0 {
			continue
		}
		k := strings.TrimSpace(line[:eq])
		v := strings.TrimSpace(line[eq+1:])
		if k != confidenceKey {
			continue
		}
		// Strip an inline comment on the value side, if present.
		if hash := strings.IndexByte(v, '#'); hash >= 0 {
			v = strings.TrimSpace(v[:hash])
		}
		n, perr := strconv.Atoi(v)
		if perr != nil {
			return defaultPort
		}
		if n <= 0 || n > 65535 {
			return defaultPort
		}
		return n
	}
	return defaultPort
}

// portInListenState reports whether tcpPort is in LISTEN state on the
// host. Uses `ss -lnt` (no name resolution, no remote info, TCP
// listeners only). Read-only.
//
// Output line shape (after header):
//
//	State Recv-Q Send-Q  Local Address:Port  Peer Address:Port  Process
//	LISTEN 0     128     0.0.0.0:22          0.0.0.0:*
//	LISTEN 0     128     [::]:2222           [::]:*
//
// We split each line on whitespace and look for the local-address
// field's :port suffix matching tcpPort.
func portInListenState(exec executor.Executor, tcpPort int) bool {
	res := exec.Run("ss", "-lnt")
	if res.ExitCode != 0 {
		return false
	}
	want := ":" + strconv.Itoa(tcpPort)
	for _, line := range strings.Split(res.Stdout, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 4 {
			continue
		}
		// First field is "State" (LISTEN). The 4th column is local
		// address:port. ss prints headers; skip a non-LISTEN row.
		if !strings.EqualFold(fields[0], "LISTEN") {
			continue
		}
		local := fields[3]
		if !strings.HasSuffix(local, want) {
			continue
		}
		// Guard against false matches like ":22222" matching ":2222"
		// when a non-:port-aligned suffix happens to share digits.
		// Re-extract the colon-separated tail.
		idx := strings.LastIndexByte(local, ':')
		if idx < 0 {
			continue
		}
		if local[idx:] == want {
			return true
		}
	}
	return false
}
