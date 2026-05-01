// =============================================================================
// NFTBan v1.100.x PR26.7 - Plesk Panel Adapter
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-panelfw-plesk"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-30"
// meta:description="Plesk adapter for the panelfw framework — control-plane reachability + canonical conf.d port surface"
// meta:inventory.files="internal/installer/panelfw/adapters/plesk/plesk.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/conf.d/panels/plesk/main.conf"
// meta:inventory.systemd_units="plesk.service"
// meta:inventory.network="tcp/8443 (Plesk control plane HTTPS, fixed)"
// meta:inventory.privileges="root"
// =============================================================================
//
// PR26.7 — Plesk adapter under the PR26.2 panelfw contract. Second
// adapter shipped (after PR26.3+PR26.4 DirectAdmin). cPanel is PR26.8;
// CyberPanel/CWP/InterWorx/Vesta land later under the same framework.
//
// SCOPE
// -----
// CONTROL PLANE — ValidateReachability tests the Plesk control port
// only (TCP 8443, HTTPS). Failure ⇒ PANEL-SURVIVAL-001 fires unless
// --no-panel.
//
// FULL PORT SURFACE — RequiredPorts consults the canonical
// /etc/nftban/conf.d/panels/plesk/main.conf via
// internal/ports/panel_loader.LoadPanelConfig("plesk") and returns the
// conf.d-declared TCP_IN / UDP_IN port set. The adapter does NOT
// invent a port list. Conf.d is the single source of truth.
//
// Differences from DirectAdmin (PR26.3+26.4):
//
//  1. No per-host control-port override. DirectAdmin reads `port=N`
//     from /usr/local/directadmin/conf/directadmin.conf to support
//     non-default panel ports. Plesk ships TCP 8443 fixed at install
//     time and does not expose a comparable per-host override path.
//     The adapter therefore returns the constant default 8443; if a
//     future Plesk version exposes an override, this is the place to
//     add it (mirroring DA's readConfiguredPort path).
//
//  2. TCP 8447 (Plesk Updater) is intentionally NOT control-plane.
//     8443 is the panel surface; 8447 is the auto-installer/repository
//     channel and may be absent on a panel that has been updated and
//     since stopped serving 8447. Conf.d declares 8447 as part of the
//     full TCP_IN surface; the adapter probes 8443 only.
//
// Fail-closed contract (matches DA):
//   - Missing conf.d main.conf → RequiredPorts returns error →
//     PanelResult.Fatal=true via panelfw.finalizeDetected.
//   - Loaded conf.d with empty TCP_IN → returns error (a Plesk panel
//     host with zero declared inbound ports is malformed).
//
// Read-only by interface contract:
//   - Detect:               filesystem stat + service-active query + ss listener parse
//   - RequiredPorts:        canonical conf.d load via panel_loader (read-only)
//   - ValidateReachability: ss -lnt output parse for the control port
//
// =============================================================================

package plesk

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
// detect.PanelPlesk / nftban panel-name convention and the conf.d
// directory name (etc/nftban/conf.d/panels/plesk/).
const adapterID panelfw.PanelID = "plesk"

// defaultPort is Plesk's control-panel HTTPS port. Plesk ships 8443
// fixed at install time. Unlike DirectAdmin (which exposes a per-host
// override at /usr/local/directadmin/conf/directadmin.conf `port=N`),
// Plesk has no canonical per-host override path. Operators who retune
// Plesk's panel port do so via Plesk-internal admin actions that this
// adapter does not parse; the adapter probes 8443 only.
const defaultPort = 8443

// Filesystem evidence paths. Constants kept here so test fixtures
// reference the same canonical names. Marker bin path comes from
// etc/nftban/conf.d/panels/plesk/main.conf NFTBAN_PLESK_MARKER_BIN.
const (
	installDir = "/usr/local/psa"
	binaryPath = "/usr/local/psa/admin/bin/httpdmng"
)

// systemdUnits is the ordered any-of list of systemd units that, if any
// one is active, count as E3 evidence that Plesk is running.
//
// PR26.7.1 calibration: the original adapter probed `plesk.service`
// alone, which does NOT exist on Ubuntu Plesk Obsidian — verified by
// the read-only audit on 203.0.113.229 (frozen evidence sha256
// c1a72266e2eb3489768a188d40d4cebcd242e1ed2bb3ba45ad0d316b549b21c3).
// Real Ubuntu Plesk units:
//
//	sw-cp-server.service   active running   enabled  ← owns 8443/8880 listener
//	sw-engine.service      active running   enabled  ← PHP-FPM panel backend
//	psa.service            active(exited)   enabled  ← orchestrator (one-shot)
//
// `plesk.service` is absent from `systemctl list-unit-files` on Ubuntu.
//
// Order matters for evidence reporting (first match wins): we list the
// strongest indicator (the daemon that actually owns the panel listener)
// first and the legacy compat unit last. Detect must NOT broaden so
// far that a non-Plesk host with a coincidentally-named service trips a
// signal — Plesk-specific filesystem markers (E1/E2) and/or the 8443
// listener (E4) remain required for any positive Detect.
var systemdUnits = []string{
	"sw-cp-server.service", // primary: owns 8443/8880 listener (sw-cp-serverd)
	"psa.service",          // orchestrator: active(exited) on healthy host
	"plesk.service",        // legacy/compat: present on some non-Ubuntu Plesk distros
}

// panelConfDLoader is the function the adapter calls to load the
// canonical conf.d panel config. Defaults to the package-public
// internal/ports/panel_loader.LoadPanelConfig at process startup.
//
// Tests inject a fixture loader by writing to this var; production
// code never reassigns it. The seam is here (rather than passing the
// loader down through every call site) because PanelAdapter's
// interface is fixed by panelfw.
var panelConfDLoader func(configDir, panelName string) (*ports.PanelConfig, error) = ports.LoadPanelConfig

// panelConfDDir is the configDir argument supplied to the loader.
// Default: fhs.EtcDir ("/etc/nftban"). Tests override to a tempdir
// containing fixture conf.d/panels/plesk/main.conf.
var panelConfDDir = fhs.EtcDir

// adapter is the package-private Plesk adapter type. The framework
// receives it via Register(); callers should not construct or reach
// into it directly.
type adapter struct{}

// New returns a fresh adapter instance.
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
//	E1 — /usr/local/psa/                      (canonical install dir)
//	E2 — /usr/local/psa/admin/bin/httpdmng    (panel binary marker)
//	E3 — any of {sw-cp-server.service,
//	             psa.service,
//	             plesk.service} active        (systemd-managed run)
//	E4 — TCP 8443 in LISTEN state             (panel actually serving)
//
// E3 is an any-of probe (PR26.7.1 calibration) because `plesk.service`
// does not exist on Ubuntu Plesk Obsidian — `sw-cp-server.service`
// owns the 8443 listener instead. The first matching unit wins for
// evidence reporting; `service-active:<unit>` records which one fired.
//
// Confidence rule: 3+ indicators ⇒ "strong"; 1–2 ⇒ "weak"; 0 ⇒
// Detected=false. The required port is always declared (8443) so the
// framework's downstream consumers have a port to reason about even
// when the panel is not yet running.
func (a *adapter) Detect(ctx context.Context, exec executor.Executor) panelfw.PanelDetection {
	det := panelfw.PanelDetection{ID: adapterID}

	port := defaultPort
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
	// E3 — any-of probe across the canonical Plesk service units.
	// Stops at the first active unit so Evidence carries exactly one
	// `service-active:<unit>` entry naming which one fired. Avoids
	// double-counting if multiple units happen to be active.
	for _, unit := range systemdUnits {
		if exec.ServiceActive(unit) {
			det.Evidence = append(det.Evidence, "service-active:"+unit)
			signals++
			break
		}
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
// Returns the canonical conf.d-declared Plesk TCP_IN / UDP_IN port
// surface, loaded via internal/ports/panel_loader.LoadPanelConfig.
//
// The adapter does NOT invent a port list — it reports exactly what
// /etc/nftban/conf.d/panels/plesk/main.conf declares. Conf.d wins
// over the legacy shell library; SSH port 22 is intentionally absent
// because /etc/nftban/ports.d/00-ssh.conf manages it separately.
//
// Fail-closed contract:
//   - Missing main.conf → returns error.
//   - Loaded with empty TCP_IN → returns error (malformed for a real
//     Plesk host; an empty inbound list cannot serve the panel).
//
// On error, panelfw.finalizeDetected sets PanelResult.Fatal=true per
// PANEL-SURVIVAL-001 unless --no-panel.
func (a *adapter) RequiredPorts(ctx context.Context, exec executor.Executor) ([]int, []int, error) {
	cfg, err := panelConfDLoader(panelConfDDir, string(adapterID))
	if err != nil {
		return nil, nil, fmt.Errorf("conf.d load failed for Plesk panel: %w (path: %s/conf.d/panels/%s/main.conf)",
			err, panelConfDDir, string(adapterID))
	}
	if cfg == nil {
		return nil, nil, fmt.Errorf("conf.d load returned nil PanelConfig for Plesk panel")
	}
	if len(cfg.TCPIn) == 0 {
		return nil, nil, fmt.Errorf(
			"conf.d for Plesk panel declares no TCP_IN ports (malformed: %s) — "+
				"a real Plesk host must declare its inbound port surface",
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
// Confirms the Plesk **control-plane** TCP port (8443 HTTPS) is in
// LISTEN state. Returns nil on success; a structured error otherwise.
// Does NOT mutate ports, services, or rules.
//
// Scope is the control plane only. RequiredPorts loads the full Plesk
// service-port surface from the canonical conf.d via panel_loader, but
// this method deliberately does NOT probe each conf.d-declared port —
// full-surface reachability probing is intentionally out of scope here
// and remains the broader rebuild/validate path's responsibility.
//
// Note: TCP 8447 (Plesk Updater / auto-installer) is part of the
// conf.d-declared full surface but is NOT the control plane; a
// well-functioning Plesk host may have 8447 closed without affecting
// panel reachability. Probing 8443 only is the correct scope.
func (a *adapter) ValidateReachability(ctx context.Context, exec executor.Executor) error {
	port := defaultPort
	if portInListenState(exec, port) {
		return nil
	}
	return fmt.Errorf(
		"control-plane port %d (Plesk) not in LISTEN state — control-plane unreachable "+
			"(this assertion probes the control plane only; the full Plesk port surface is loaded "+
			"from conf.d via RequiredPorts but not probed here)",
		port)
}

// portInListenState reports whether tcpPort is in LISTEN state on the
// host. Uses `ss -lnt` (no name resolution, no remote info, TCP
// listeners only). Read-only.
//
// Identical to the DA adapter's helper — kept package-local rather
// than refactored into a shared util because the panelfw contract is
// per-adapter and a future Plesk-specific tweak (e.g., probe the
// HTTPS handshake instead of just LISTEN state) belongs here, not in
// a shared file edited from multiple adapters.
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
		if !strings.EqualFold(fields[0], "LISTEN") {
			continue
		}
		local := fields[3]
		if !strings.HasSuffix(local, want) {
			continue
		}
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
