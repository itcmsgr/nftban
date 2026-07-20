// SPDX-License-Identifier: MPL-2.0
// meta:name="cmd_resources.go"
// meta:type="cmd"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.222.1 Lane 3: `nftban-core resources [--json]` — READ-ONLY diagnostics for the health-service resource policy. Reports host facts (canonical safety), the CALCULATED policy (safety.HealthServiceMemoryLimits), the persisted installer HEALTH_RESOURCE_* state, and the LIVE systemd effective values (systemctl show, read-only), then classifies protection via the shared healthresource.ClassifyEffectiveDetailed. Live systemd is authoritative for the current verdict. NO new RAM/tier classifier, NO /proc parser, NO mutation (no write/reload/reset). The public `nftban health resources` shell command delegates here."
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/itcmsgr/nftban/internal/healthresource"
	"github.com/itcmsgr/nftban/internal/installer/state"
	"github.com/itcmsgr/nftban/internal/safety"
)

// resourcesReport is the stable machine-readable model for `resources --json`.
type resourcesReport struct {
	SchemaVersion int `json:"schema_version"`
	Authority     struct {
		Facts  string `json:"facts"`
		Tier   string `json:"tier"`
		Policy string `json:"policy"`
	} `json:"authority"`
	Host struct {
		ResourceTier         string `json:"resource_tier"`
		TierReason           string `json:"tier_reason"`
		EffectiveMemoryBytes int64  `json:"effective_memory_bytes"`
		AvailableMemoryBytes int64  `json:"available_memory_bytes"`
		CPUCores             int    `json:"cpu_cores"`
		CgroupLimited        bool   `json:"cgroup_limited"`
	} `json:"host"`
	Service resourcesServiceReport `json:"services_health"`
	// PersistedState mirrors the installer's last reconciliation (history/failure detail).
	Persisted    resourcesPersisted `json:"persisted_installer_state"`
	OverallState string             `json:"overall_state"`
}

type resourcesServiceReport struct {
	Calculated struct {
		MemoryHighBytes int64 `json:"memory_high_bytes"`
		MemoryMaxBytes  int64 `json:"memory_max_bytes"`
	} `json:"calculated"`
	Effective struct {
		MemoryHighBytes int64  `json:"memory_high_bytes"`
		MemoryMaxBytes  int64  `json:"memory_max_bytes"`
		TasksMax        int64  `json:"tasks_max"`
		Available       bool   `json:"available"` // false if systemctl show failed
		Note            string `json:"note,omitempty"`
	} `json:"effective"`
	Runtime struct {
		MemoryPeakBytes *int64 `json:"memory_peak_bytes"` // null if unavailable
		HeadroomBytes   *int64 `json:"headroom_bytes"`
		Result          string `json:"result"`
		NeverRun        bool   `json:"never_run"`
		OverLimit       bool   `json:"over_limit"`
	} `json:"runtime"`
	Dropin struct {
		ExpectedPath string   `json:"expected_path"`
		OnDisk       bool     `json:"on_disk"`
		Loaded       bool     `json:"loaded"`
		LoadedPaths  []string `json:"loaded_paths"`
	} `json:"dropin"`
	PackagedFallback struct {
		MemoryHighBytes int64 `json:"memory_high_bytes"`
		MemoryMaxBytes  int64 `json:"memory_max_bytes"`
	} `json:"packaged_fallback"`
	State            string `json:"state"`
	ProtectionActive bool   `json:"protection_active"`
	Validation       string `json:"validation"`
	Error            string `json:"error"`
	SourceVersion    string `json:"source_version"`
}

type resourcesPersisted struct {
	Available        bool   `json:"available"`
	State            string `json:"state"`
	ProtectionActive bool   `json:"protection_active"`
	Error            string `json:"error"`
}

const (
	packagedFallbackHigh = int64(192) << 20
	packagedFallbackMax  = int64(256) << 20
)

// cmdResources is the read-only entrypoint. Exit codes: 0 protected/acceptable,
// 1 diagnostic warning / incomplete runtime evidence, 2 protection NOT active /
// invalid effective policy.
func cmdResources(args []string) int {
	jsonOut := false
	for _, a := range args {
		if a == "--json" {
			jsonOut = true
		}
	}

	rep := buildResourcesReport()

	if jsonOut {
		b, err := json.MarshalIndent(rep, "", "  ")
		if err != nil {
			fmt.Fprintf(os.Stderr, "resources: json encode: %v\n", err)
			return 1
		}
		fmt.Println(string(b))
	} else {
		printResourcesHuman(rep)
	}
	return resourcesExitCode(rep)
}

// buildResourcesReport gathers facts/persisted/live inputs (read-only: /proc via
// safety, install_state, and `systemctl show`) and delegates to the pure
// assembleReport. Splitting the two keeps the classifier unit-testable.
func buildResourcesReport() resourcesReport {
	calc := safety.HealthServiceMemoryLimits()
	sf := state.NewStateFile("")
	persistedOK := sf.Read() == nil
	props, showErr := runSystemctlShow()
	return assembleReport(calc, sf, persistedOK, props, showErr, fileExists(healthresource.DropinFile))
}

// assembleReport is the pure classifier/renderer core. LIVE systemd values are
// authoritative for the verdict; persisted state carries installer history.
func assembleReport(calc safety.HealthResourceProfile, sf *state.StateFile, persistedOK bool, props map[string]string, showErr error, dropinOnDisk bool) resourcesReport {
	var rep resourcesReport
	rep.SchemaVersion = 1
	rep.Authority.Facts = "internal/safety"
	rep.Authority.Tier = "ClassifyResourceTier"
	rep.Authority.Policy = "HealthServiceMemoryLimitsFor"

	// 1. Facts + calculated policy (canonical authority).
	rep.Host.ResourceTier = string(calc.Tier)
	rep.Host.TierReason = calc.Reason
	rep.Host.EffectiveMemoryBytes = calc.TotalRAM // AvailableMem().Total is cgroup-effective
	rep.Host.AvailableMemoryBytes = calc.AvailRAM
	rep.Host.CPUCores = calc.CPUCores
	rep.Host.CgroupLimited = false // set below if the effective differs from physical (not exposed separately in v1.222.1)

	svc := &rep.Service
	svc.Calculated.MemoryHighBytes = calc.MemoryHigh
	svc.Calculated.MemoryMaxBytes = calc.MemoryMax
	svc.PackagedFallback.MemoryHighBytes = packagedFallbackHigh
	svc.PackagedFallback.MemoryMaxBytes = packagedFallbackMax
	svc.Dropin.ExpectedPath = healthresource.DropinFile
	svc.Dropin.OnDisk = dropinOnDisk
	svc.Dropin.LoadedPaths = []string{}

	// 2. Persisted installer state (best-effort; old files → zero-value fields).
	if persistedOK && sf != nil {
		rep.Persisted.Available = true
		rep.Persisted.State = sf.HealthResourceState
		rep.Persisted.ProtectionActive = sf.HealthResourceProtection
		rep.Persisted.Error = sf.HealthResourceError
		svc.SourceVersion = sf.HealthResourceSourceVer
	}

	// 3. Live systemd effective values (read-only). LIVE is authoritative for the verdict.
	if showErr != nil {
		svc.Effective.Available = false
		svc.Effective.Note = "systemctl show unavailable: " + showErr.Error()
		svc.State = "STATE_UNAVAILABLE_LIVE_INVALID"
		svc.Validation = "UNKNOWN"
		svc.Error = svc.Effective.Note
		rep.OverallState = svc.State
		return rep
	}
	svc.Effective.Available = true
	effHigh, hInf, _ := healthresource.ParseMemBytes(props["MemoryHigh"])
	effMax, mInf, _ := healthresource.ParseMemBytes(props["MemoryMax"])
	effTasks, _, _ := healthresource.ParseMemBytes(props["TasksMax"])
	svc.Effective.MemoryHighBytes = effHigh
	svc.Effective.MemoryMaxBytes = effMax
	svc.Effective.TasksMax = effTasks
	if dp := strings.TrimSpace(props["DropInPaths"]); dp != "" {
		svc.Dropin.LoadedPaths = strings.Fields(dp)
	}
	svc.Dropin.Loaded = containsStr(svc.Dropin.LoadedPaths, healthresource.DropinFile)

	// Infinity is INVALID for the bounded policy (never "safe because larger").
	if hInf || mInf {
		svc.State = string(healthresource.StateActivationFailed)
		svc.ProtectionActive = false
		svc.Validation = "FAIL"
		svc.Error = "unbounded effective memory limit (infinity) violates bounded v1.222.1 policy"
		rep.OverallState = svc.State
		return rep
	}

	// 4. Classify (shared authority — no second policy path). LIVE authoritative.
	otherDropins := 0
	for _, p := range svc.Dropin.LoadedPaths {
		if p != healthresource.DropinFile {
			otherDropins++
		}
	}
	st := healthresource.ClassifyEffectiveDetailed(calc, effHigh, effMax, svc.Dropin.Loaded, otherDropins, svc.Dropin.OnDisk)
	svc.State = string(st)
	svc.ProtectionActive = st.ProtectionActive()
	if svc.ProtectionActive {
		svc.Validation = "PASS"
	} else {
		svc.Validation = "FAIL"
		if st == healthresource.StateExternalConflict {
			svc.Error = "external systemd drop-in overrides health-service memory limits: " + strings.Join(svc.Dropin.LoadedPaths, " ")
		}
	}

	// 5. Runtime peak + headroom (guarded; never unsigned underflow).
	fillRuntime(svc, props, effMax)

	rep.OverallState = svc.State
	return rep
}

func fillRuntime(svc *resourcesServiceReport, props map[string]string, effMax int64) {
	svc.Runtime.Result = props["Result"]
	peakStr, ok := props["MemoryPeak"]
	if !ok || strings.TrimSpace(peakStr) == "" || strings.TrimSpace(peakStr) == "[not set]" {
		svc.Runtime.MemoryPeakBytes = nil // unavailable
		return
	}
	peak, inf, pok := healthresource.ParseMemBytes(peakStr)
	if !pok || inf {
		svc.Runtime.MemoryPeakBytes = nil
		return
	}
	if peak == 0 {
		// Distinguish never-run from a real 0 peak: a service that ran records a
		// non-zero peak; MemoryPeak=0 with no run history reads as never_run.
		if svc.Runtime.Result == "" {
			svc.Runtime.NeverRun = true
			return
		}
	}
	pv := peak
	svc.Runtime.MemoryPeakBytes = &pv
	// Signed headroom; if peak exceeds max → negative + OverLimit (never underflow).
	hr := effMax - peak
	svc.Runtime.HeadroomBytes = &hr
	if hr < 0 {
		svc.Runtime.OverLimit = true
	}
}

// runSystemctlShow runs the READ-ONLY machine-readable query. No mutation.
func runSystemctlShow() (map[string]string, error) {
	out, err := exec.Command("systemctl", "show", "nftban-health.service",
		"-p", "MemoryHigh", "-p", "MemoryMax", "-p", "TasksMax", "-p", "DropInPaths",
		"-p", "MemoryPeak", "-p", "Result", "-p", "FragmentPath").Output()
	if err != nil {
		return nil, err
	}
	props := healthresource.ShowProps(string(out))
	if _, ok := props["MemoryMax"]; !ok {
		return nil, fmt.Errorf("systemctl show returned no MemoryMax")
	}
	return props, nil
}

func resourcesExitCode(rep resourcesReport) int {
	svc := rep.Service
	if !svc.Effective.Available {
		return 1 // incomplete evidence
	}
	if svc.ProtectionActive {
		return 0
	}
	return 2 // protection not active / invalid
}

// fmtMiB renders "N MiB (B bytes)". Human output shows both per the contract.
func fmtMiB(b int64) string {
	return fmt.Sprintf("%d MiB (%d bytes)", b/(1<<20), b)
}

func printResourcesHuman(rep resourcesReport) {
	svc := rep.Service
	fmt.Println("NFTBan Health Resource Protection")
	fmt.Println()
	fmt.Println("HOST")
	fmt.Printf("  Resource tier........... %s\n", rep.Host.ResourceTier)
	fmt.Printf("  Profile authority....... %s\n", rep.Authority.Facts)
	fmt.Printf("  Effective RAM........... %s\n", fmtMiB(rep.Host.EffectiveMemoryBytes))
	fmt.Printf("  Available RAM........... %s\n", fmtMiB(rep.Host.AvailableMemoryBytes))
	fmt.Printf("  CPU cores............... %d\n", rep.Host.CPUCores)
	fmt.Println()
	fmt.Println("CALCULATED POLICY")
	fmt.Printf("  MemoryHigh.............. %s\n", fmtMiB(svc.Calculated.MemoryHighBytes))
	fmt.Printf("  MemoryMax............... %s\n", fmtMiB(svc.Calculated.MemoryMaxBytes))
	fmt.Println()
	fmt.Println("EFFECTIVE SYSTEMD POLICY")
	if svc.Effective.Available {
		fmt.Printf("  MemoryHigh.............. %s\n", fmtMiB(svc.Effective.MemoryHighBytes))
		fmt.Printf("  MemoryMax............... %s\n", fmtMiB(svc.Effective.MemoryMaxBytes))
		fmt.Printf("  TasksMax................ %d\n", svc.Effective.TasksMax)
		fmt.Printf("  Expected drop-in loaded. %s\n", yesNo(svc.Dropin.Loaded))
		if len(svc.Dropin.LoadedPaths) > 0 {
			fmt.Printf("  Loaded drop-ins......... %s\n", strings.Join(svc.Dropin.LoadedPaths, " "))
		}
	} else {
		fmt.Printf("  (unavailable) .......... %s\n", svc.Effective.Note)
	}
	fmt.Println()
	fmt.Println("RUNTIME")
	if svc.Runtime.NeverRun {
		fmt.Println("  Last MemoryPeak......... (service has not run yet)")
	} else if svc.Runtime.MemoryPeakBytes != nil {
		fmt.Printf("  Last MemoryPeak......... %s\n", fmtMiB(*svc.Runtime.MemoryPeakBytes))
		if svc.Runtime.HeadroomBytes != nil {
			if svc.Runtime.OverLimit {
				fmt.Printf("  Headroom................ OVER_LIMIT (%d bytes)\n", *svc.Runtime.HeadroomBytes)
			} else {
				fmt.Printf("  Headroom................ %s\n", fmtMiB(*svc.Runtime.HeadroomBytes))
			}
		}
	} else {
		fmt.Println("  Last MemoryPeak......... (unavailable)")
	}
	if svc.Runtime.Result != "" {
		fmt.Printf("  Last result............. %s\n", svc.Runtime.Result)
	}
	fmt.Println()
	fmt.Println("STATE")
	fmt.Printf("  Policy state............ %s\n", svc.State)
	fmt.Printf("  Protection active....... %s\n", yesNo(svc.ProtectionActive))
	fmt.Printf("  Authority............... %s\n", rep.Authority.Facts)
	if svc.SourceVersion != "" {
		fmt.Printf("  Source version.......... %s\n", svc.SourceVersion)
	}
	if svc.Error != "" {
		fmt.Printf("  Error................... %s\n", svc.Error)
	}
}

func yesNo(b bool) string {
	if b {
		return "yes"
	}
	return "no"
}

func containsStr(ss []string, want string) bool {
	for _, s := range ss {
		if s == want {
			return true
		}
	}
	return false
}
