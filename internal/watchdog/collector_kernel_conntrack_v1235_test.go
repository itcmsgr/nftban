// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
//
// meta:name="watchdog_conntrack_measured_v1235_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-05"
// meta:description="BUG-WATCHDOG-CONNTRACK-READ-FAILURE-REPORTED-AS-ZERO (v1.235): a failed conntrack read is UNMEASURED (gauges NaN), never 0"
// meta:input="None"
// meta:output="None"
// meta:depends="testing"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
package watchdog

import (
	"math"
	"os"
	"path/filepath"
	"testing"

	"github.com/prometheus/client_golang/prometheus"
	dto "github.com/prometheus/client_model/go"
)

func gaugeValue(t *testing.T, g prometheus.Gauge) float64 {
	t.Helper()
	var m dto.Metric
	if err := g.Write(&m); err != nil {
		t.Fatal(err)
	}
	return m.GetGauge().GetValue()
}

// withConntrackDir points the collector at a fixture directory for one test.
func withConntrackDir(t *testing.T, files map[string]string, dirs ...string) {
	t.Helper()
	d := t.TempDir()
	for name, body := range files {
		if err := os.WriteFile(filepath.Join(d, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range dirs {
		// A directory in place of the file: ReadFile fails, as a denied read does.
		if err := os.Mkdir(filepath.Join(d, name), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	old := conntrackProcDir
	conntrackProcDir = d
	t.Cleanup(func() { conntrackProcDir = old })
}

func collectKernelConntrack(t *testing.T) KernelMetrics {
	t.Helper()
	s := &Snapshot{}
	NewKernelCollector().collectConntrack(s)
	return s.Kernel
}

func TestConntrack_ReadOK_IsMeasured_v1235(t *testing.T) {
	withConntrackDir(t, map[string]string{"nf_conntrack_count": "16\n", "nf_conntrack_max": "65536\n"})
	k := collectKernelConntrack(t)
	if !k.ConntrackMeasured || k.ConntrackCount != 16 || k.ConntrackMax != 65536 {
		t.Fatalf("readable conntrack: got measured=%v count=%d max=%d", k.ConntrackMeasured, k.ConntrackCount, k.ConntrackMax)
	}
	if want := 16.0 / 65536.0; math.Abs(k.ConntrackUtilization-want) > 1e-12 {
		t.Errorf("utilization = %v, want %v", k.ConntrackUtilization, want)
	}
}

// TestConntrack_ReadFailure_IsUnmeasured_v1235 covers the measured defect: the
// limit (or count) cannot be read, and the collector used to report 0.
func TestConntrack_ReadFailure_IsUnmeasured_v1235(t *testing.T) {
	cases := []struct {
		name  string
		files map[string]string
		dirs  []string
	}{
		{"max unreadable (denied read shape)", map[string]string{"nf_conntrack_count": "16\n"}, []string{"nf_conntrack_max"}},
		{"count unreadable", map[string]string{"nf_conntrack_max": "65536\n"}, []string{"nf_conntrack_count"}},
		{"both missing", nil, nil},
		{"max not a number", map[string]string{"nf_conntrack_count": "16\n", "nf_conntrack_max": "x\n"}, nil},
		{"max zero", map[string]string{"nf_conntrack_count": "0\n", "nf_conntrack_max": "0\n"}, nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			withConntrackDir(t, tc.files, tc.dirs...)
			if k := collectKernelConntrack(t); k.ConntrackMeasured {
				t.Errorf("%s: reported as measured (count=%d max=%d)", tc.name, k.ConntrackCount, k.ConntrackMax)
			}
		})
	}
}

// TestConntrack_UnmeasuredGaugesAreNaN_v1235: the exported gauges must not
// carry 0 for an unmeasured read; a later measured read restores real values.
func TestConntrack_UnmeasuredGaugesAreNaN_v1235(t *testing.T) {
	m := NewMetricsExporter()
	state := NewPressureState()

	m.Update(&Snapshot{Kernel: KernelMetrics{ConntrackMeasured: false}}, state)
	for name, v := range map[string]float64{
		"nftban_conntrack_used":        gaugeValue(t, conntrackUsed),
		"nftban_conntrack_max":         gaugeValue(t, conntrackMax),
		"nftban_conntrack_utilization": gaugeValue(t, conntrackUtilization),
	} {
		if !math.IsNaN(v) {
			t.Errorf("unmeasured: %s = %v, want NaN (not a measurement)", name, v)
		}
	}

	m.Update(&Snapshot{Kernel: KernelMetrics{ConntrackMeasured: true, ConntrackCount: 16,
		ConntrackMax: 65536, ConntrackUtilization: 16.0 / 65536.0}}, state)
	if v := gaugeValue(t, conntrackMax); v != 65536 {
		t.Errorf("measured: nftban_conntrack_max = %v, want 65536", v)
	}
}
