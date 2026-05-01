// =============================================================================
// NFTBan v1.100.x PR26.8 - cPanel/WHM Panel Adapter
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-panelfw-cpanel"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-01"
// meta:description="cPanel/WHM adapter for the panelfw framework — control-plane any-of {2087, 2083} + canonical conf.d port surface"
// meta:inventory.files="internal/installer/panelfw/adapters/cpanel/cpanel.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/conf.d/panels/cpanel/main.conf"
// meta:inventory.systemd_units="cpanel.service"
// meta:inventory.network="tcp/2087 (WHM HTTPS), tcp/2083 (cPanel HTTPS)"
// meta:inventory.privileges="root"
// =============================================================================
//
// PR26.8 — cPanel/WHM adapter under the PR26.2 panelfw contract. Third
// adapter shipped (after PR26.3+PR26.4 DirectAdmin and PR26.7+PR26.7.1
// Plesk). Source evidence: read-only audit on lab4 (rebuilt clean
// AlmaLinux 9.7 / cPanel 11.132.0.19, 2026-05-01) frozen at sha256
// bc7c09722ad4774febd35371c59e9b2d77e9743c95ba09d288fd10b4385e56b7.
//
// SCOPE
// -----
// CONTROL PLANE — ValidateReachability tests the cPanel/WHM control
// surface using an **any-of {2087, 2083}** probe: WHM HTTPS (admin
// surface) OR cPanel HTTPS (user surface) listening means the panel
// is reachable. Either alone is sufficient evidence the panel is up.
// Failure (neither listening) ⇒ PANEL-SURVIVAL-001 fires unless
// --no-panel.
//
// FULL PORT SURFACE — RequiredPorts consults the canonical
// /etc/nftban/conf.d/panels/cpanel/main.conf via
// internal/ports/panel_loader.LoadPanelConfig("cpanel") and returns
// the conf.d-declared TCP_IN / UDP_IN port set. The adapter does NOT
// invent a port list. Conf.d is the single source of truth.
//
// Differences from Plesk (PR26.7+26.7.1):
//
//  1. **Two-port any-of control plane.** cPanel splits admin (WHM,
//     2087) and user (cPanel, 2083) surfaces over two distinct
//     control-plane ports. Either listening counts as control-plane
//     reachable. Plesk has only 8443; this is a PR26.8-specific
//     enhancement of the framework.
//
//  2. **Single E3 systemd unit.** lab4 evidence shows `cpanel.service`
//     is the orchestrator (active+enabled) that spawns `cpsrvd`
//     processes which actually serve 2087/2083. `cpsrvd.service` is
//     INACTIVE on a healthy host (the unit name does not correspond
//     to the running daemon — it's spawned without its own systemd
//     unit). Adapter probes `cpanel.service` ONLY. NO any-of probe
//     here; cPanel's reality is simpler than Ubuntu Plesk's where
//     `plesk.service` did not exist at all.
//
//  3. **CPANEL-RPCBIND-111-DIRECTIVE applies.** Portmapper / rpcbind
//     TCP/UDP 111 is operator/service-specific RPC surface, NOT a
//     cPanel panel-survival port. The adapter does NOT include 111
//     in Detect / RequiredPorts / ValidateReachability. NFS/RPC needs
//     a separate operator-services lane (custom ports.d, future
//     service-profile, explicit allowlist) — never via panel conf.d.
//
// Fail-closed contract (matches DA / Plesk):
//   - Missing conf.d main.conf → RequiredPorts returns error →
//     PanelResult.Fatal=true via panelfw.finalizeDetected.
//   - Loaded conf.d with empty TCP_IN → returns error (a cPanel host
//     with zero declared inbound ports is malformed).
//
// Read-only by interface contract:
//   - Detect:               filesystem stat + service-active query + ss listener parse
//   - RequiredPorts:        canonical conf.d load via panel_loader (read-only)
//   - ValidateReachability: ss -lnt output parse for the any-of control ports
//
// Out of scope (deferred to future evidence-gated PRs):
//   - chkservd CSF-watchdog clearing (PANEL-WATCHDOG-COHERENCE-001
//     generalization for cPanel-with-CSF hosts; lab4 has no CSF so
//     coding it now would be untested speculation)
//   - cPHulk integration (cPanel's brute-force protection — not a
//     firewall surface; nftban login monitoring supersedes it)
//   - imunify360 / mod_security (application-layer; not in firewall scope)
//   - WHM CSF plugin presence detection (informational warn — future PR)
//   - conf.d additions for TCP 4190 (managesieve) / TCP 2091 (cpdavd
//     auxiliary) — separate hygiene PRs after PR26.8 lands
//
// =============================================================================

package cpanel

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
// detect.PanelCPanel / nftban panel-name convention and the conf.d
// directory name (etc/nftban/conf.d/panels/cpanel/).
const adapterID panelfw.PanelID = "cpanel"

// Control-plane ports — used by both Detect (E4) and
// ValidateReachability (any-of). cPanel splits admin (WHM) and user
// surfaces over two distinct HTTPS ports; either listening is
// sufficient evidence the panel is reachable.
const (
	// portWHMSSL is WHM HTTPS — the admin-side cPanel control plane.
	// Ordered FIRST in the any-of probe because admin-side outage
	// is operationally more significant than user-side outage on a
	// host where both should be up.
	portWHMSSL = 2087

	// portCPanelSSL is cPanel HTTPS — the user-side panel surface.
	// Ordered second; either alone is enough for control-plane OK.
	portCPanelSSL = 2083
)

// controlPlanePorts is the ordered any-of probe list for
// ValidateReachability. Stops at the first listening port (admin
// preferred). Detect's E4 also uses this list; first-match-wins
// records `listener-tcp:<port>` evidence.
var controlPlanePorts = []int{portWHMSSL, portCPanelSSL}

// Filesystem evidence paths.
const (
	installDir  = "/usr/local/cpanel"
	binaryPath  = "/usr/local/cpanel/cpanel"
	systemdUnit = "cpanel.service"
)

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
// containing fixture conf.d/panels/cpanel/main.conf.
var panelConfDDir = fhs.EtcDir

// adapter is the package-private cPanel adapter type. The framework
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
//	E1 — /usr/local/cpanel/                   (canonical install dir)
//	E2 — /usr/local/cpanel/cpanel             (panel binary)
//	E3 — cpanel.service active                (orchestrator)
//	E4 — TCP 2087 OR TCP 2083 in LISTEN state (panel actually serving)
//
// E3 probes `cpanel.service` ONLY. cpsrvd processes are spawned by
// the orchestrator and do not have their own systemd unit on a
// healthy host (lab4 evidence: cpsrvd.service inactive while cpsrvd
// processes are listening on 2082/2083/2086/2087/2095/2096).
//
// E4 uses the same any-of {2087, 2083} as ValidateReachability.
// First match wins for evidence reporting; either alone counts as 1
// signal toward the confidence calculation.
//
// Confidence rule: 3+ indicators ⇒ "strong"; 1–2 ⇒ "weak"; 0 ⇒
// Detected=false. RequiredTCP is declared as the full control-plane
// list (`{2087, 2083}`) so framework consumers know both are valid
// reach-targets even when neither is currently listening.
func (a *adapter) Detect(ctx context.Context, exec executor.Executor) panelfw.PanelDetection {
	det := panelfw.PanelDetection{ID: adapterID}

	// Declare BOTH control-plane ports for downstream consumers — the
	// any-of probe makes both legitimate reach-targets.
	det.RequiredTCP = append([]int(nil), controlPlanePorts...)

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
	// E4 — any-of listener probe. First-match-wins for evidence; only
	// one signal counted regardless of how many control-plane ports
	// are listening. Avoids inflating confidence on a host where
	// both 2087 AND 2083 happen to be up (the common healthy case).
	for _, port := range controlPlanePorts {
		if portInListenState(exec, port) {
			det.Evidence = append(det.Evidence, fmt.Sprintf("listener-tcp:%d", port))
			signals++
			break
		}
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
// Returns the canonical conf.d-declared cPanel TCP_IN / UDP_IN port
// surface, loaded via internal/ports/panel_loader.LoadPanelConfig.
//
// CPANEL-RPCBIND-111-DIRECTIVE: the adapter does NOT inject TCP/UDP
// 111 (rpcbind/portmapper) into the surface. If 111 is in the conf.d
// declaration, it appears here verbatim — but the canonical conf.d
// shipped in PR26.5 omits 111 by design. Operator-required NFS/RPC
// allowlisting must go through the operator-services lane (custom
// ports.d / future service-profile), not via panel conf.d.
//
// The adapter does NOT invent a port list — it reports exactly what
// /etc/nftban/conf.d/panels/cpanel/main.conf declares. Conf.d wins
// over the legacy shell library; SSH port 22 is intentionally absent
// because /etc/nftban/ports.d/00-ssh.conf manages it separately.
//
// Fail-closed contract:
//   - Missing main.conf → returns error.
//   - Loaded with empty TCP_IN → returns error (malformed for a real
//     cPanel host; an empty inbound list cannot serve the panel).
//
// On error, panelfw.finalizeDetected sets PanelResult.Fatal=true per
// PANEL-SURVIVAL-001 unless --no-panel.
func (a *adapter) RequiredPorts(ctx context.Context, exec executor.Executor) ([]int, []int, error) {
	cfg, err := panelConfDLoader(panelConfDDir, string(adapterID))
	if err != nil {
		return nil, nil, fmt.Errorf("conf.d load failed for cPanel panel: %w (path: %s/conf.d/panels/%s/main.conf)",
			err, panelConfDDir, string(adapterID))
	}
	if cfg == nil {
		return nil, nil, fmt.Errorf("conf.d load returned nil PanelConfig for cPanel panel")
	}
	if len(cfg.TCPIn) == 0 {
		return nil, nil, fmt.Errorf(
			"conf.d for cPanel panel declares no TCP_IN ports (malformed: %s) — "+
				"a real cPanel host must declare its inbound port surface",
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
// Confirms at least ONE of the cPanel control-plane TCP ports is in
// LISTEN state — any-of {2087 (WHM HTTPS), 2083 (cPanel HTTPS)}.
// Returns nil on the first listening port found (admin preferred).
// On failure (neither listening), returns a structured error that
// names BOTH probed ports + scope-disciplines the message to "control
// plane only" (mirrors PR26.7 wording).
//
// Does NOT mutate ports, services, or rules.
//
// Scope is the control plane only. RequiredPorts loads the full
// cPanel service-port surface from the canonical conf.d via
// panel_loader, but this method deliberately does NOT probe each
// conf.d-declared port — full-surface reachability probing is
// intentionally out of scope here and remains the broader
// rebuild/validate path's responsibility.
//
// Note: TCP 2095/2096 (Webmail), 2086 (WHM HTTP redirect to 2087),
// 2082 (cPanel HTTP redirect to 2083) are part of the conf.d full
// surface but are NOT control-plane and are NOT probed here.
func (a *adapter) ValidateReachability(ctx context.Context, exec executor.Executor) error {
	for _, port := range controlPlanePorts {
		if portInListenState(exec, port) {
			return nil
		}
	}
	// Format the probed-port list for the failure message so the
	// error tells the operator exactly which ports were checked.
	probed := make([]string, len(controlPlanePorts))
	for i, p := range controlPlanePorts {
		probed[i] = strconv.Itoa(p)
	}
	return fmt.Errorf(
		"control-plane ports {%s} (cPanel) not in LISTEN state — control-plane unreachable "+
			"(this assertion probes the control plane only via any-of {WHM 2087, cPanel 2083}; "+
			"the full cPanel port surface is loaded from conf.d via RequiredPorts but not probed here)",
		strings.Join(probed, ", "))
}

// portInListenState reports whether tcpPort is in LISTEN state on the
// host. Uses `ss -lnt` (no name resolution, no remote info, TCP
// listeners only). Read-only.
//
// Identical to the DA / Plesk adapter helpers — kept package-local
// rather than refactored into a shared util because the panelfw
// contract is per-adapter and a future cPanel-specific tweak (e.g.,
// probe the HTTPS handshake instead of just LISTEN state, or honor a
// per-host control-port override) belongs here, not in a shared file
// edited from multiple adapters.
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
