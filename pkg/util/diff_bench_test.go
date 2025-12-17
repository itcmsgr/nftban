package util

import (
	"fmt"
	"testing"
)

func BenchmarkComputeDiffSmall(b *testing.B) {
	desired := make([]string, 100)
	current := make([]string, 100)

	for i := 0; i < 100; i++ {
		desired[i] = fmt.Sprintf("192.168.1.%d", i)
		current[i] = fmt.Sprintf("192.168.1.%d", i+50)
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = ComputeDiff(desired, current)
	}
}

func BenchmarkComputeDiffMedium(b *testing.B) {
	desired := make([]string, 10000)
	current := make([]string, 10000)

	for i := 0; i < 10000; i++ {
		desired[i] = fmt.Sprintf("10.%d.%d.%d", i/256/256, (i/256)%256, i%256)
		current[i] = fmt.Sprintf("10.%d.%d.%d", (i+5000)/256/256, ((i+5000)/256)%256, (i+5000)%256)
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = ComputeDiff(desired, current)
	}
}

func BenchmarkComputeDiffLarge(b *testing.B) {
	desired := make([]string, 100000)
	current := make([]string, 100000)

	for i := 0; i < 100000; i++ {
		desired[i] = fmt.Sprintf("10.%d.%d.%d", i/256/256, (i/256)%256, i%256)
		current[i] = fmt.Sprintf("10.%d.%d.%d", (i+50000)/256/256, ((i+50000)/256)%256, (i+50000)%256)
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = ComputeDiff(desired, current)
	}
}

func BenchmarkComputeDiffNoChanges(b *testing.B) {
	// Benchmark when everything is unchanged
	data := make([]string, 10000)
	for i := 0; i < 10000; i++ {
		data[i] = fmt.Sprintf("192.168.%d.%d", i/256, i%256)
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = ComputeDiff(data, data)
	}
}

func BenchmarkComputeDiffAllChanges(b *testing.B) {
	// Worst case: everything changes
	desired := make([]string, 10000)
	current := make([]string, 10000)

	for i := 0; i < 10000; i++ {
		desired[i] = fmt.Sprintf("10.%d.%d.%d", i/256/256, (i/256)%256, i%256)
		current[i] = fmt.Sprintf("172.%d.%d.%d", i/256/256, (i/256)%256, i%256)
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = ComputeDiff(desired, current)
	}
}
