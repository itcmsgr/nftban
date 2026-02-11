// =============================================================================
// NFTBan - Set Implementation Benchmarks
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="set_bench_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Benchmarks for generic set operations"
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
// =============================================================================

package util

import (
	"fmt"
	"testing"
)

func BenchmarkSetAdd(b *testing.B) {
	s := NewSet[string]()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		s.Add(fmt.Sprintf("192.168.1.%d", i%256))
	}
}

func BenchmarkSetHas(b *testing.B) {
	s := NewSet[string]()
	for i := 0; i < 1000; i++ {
		s.Add(fmt.Sprintf("192.168.1.%d", i%256))
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = s.Has(fmt.Sprintf("192.168.1.%d", i%256))
	}
}

func BenchmarkSetUnion(b *testing.B) {
	s1 := NewSet[string]()
	s2 := NewSet[string]()

	for i := 0; i < 1000; i++ {
		s1.Add(fmt.Sprintf("10.0.%d.%d", i/256, i%256))
		s2.Add(fmt.Sprintf("172.16.%d.%d", i/256, i%256))
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = s1.Union(s2)
	}
}

func BenchmarkSetIntersection(b *testing.B) {
	s1 := NewSet[string]()
	s2 := NewSet[string]()

	for i := 0; i < 1000; i++ {
		s1.Add(fmt.Sprintf("10.0.%d.%d", i/256, i%256))
	}
	for i := 500; i < 1500; i++ {
		s2.Add(fmt.Sprintf("10.0.%d.%d", i/256, i%256))
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = s1.Intersection(s2)
	}
}

func BenchmarkSetDifference(b *testing.B) {
	s1 := NewSet[string]()
	s2 := NewSet[string]()

	for i := 0; i < 1000; i++ {
		s1.Add(fmt.Sprintf("10.0.%d.%d", i/256, i%256))
	}
	for i := 500; i < 1500; i++ {
		s2.Add(fmt.Sprintf("10.0.%d.%d", i/256, i%256))
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = s1.Difference(s2)
	}
}

func BenchmarkSetToSlice(b *testing.B) {
	s := NewSet[string]()
	for i := 0; i < 10000; i++ {
		s.Add(fmt.Sprintf("192.168.%d.%d", i/256, i%256))
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = s.ToSlice()
	}
}
