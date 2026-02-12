// SPDX-License-Identifier: MPL-2.0
// meta:name="opqueue/bench_netlink_test" meta:type="test" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Netlink throughput benchmarks for nftables operations"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
//
// NOTE: These benchmarks require root privileges and a real nftables setup.
// Run with: sudo go test -bench=BenchmarkNetlink -benchtime=3s -v ./pkg/opqueue/...
//
// These benchmarks measure ACTUAL kernel/netlink throughput, not mocked operations.

package opqueue

import (
	"context"
	"fmt"
	"os"
	"runtime"
	"testing"
	"time"
)

// skipIfNotRoot skips the test if not running as root
func skipIfNotRoot(t testing.TB) {
	if os.Getuid() != 0 {
		t.Skip("Skipping: requires root privileges for netlink operations")
	}
}

// BenchmarkNetlinkAddElements measures raw netlink AddElements throughput
// Tests batch sizes: 1k, 5k, 10k, 20k elements
func BenchmarkNetlinkAddElements_1k(b *testing.B) {
	benchmarkNetlinkAddElements(b, 1000)
}

func BenchmarkNetlinkAddElements_5k(b *testing.B) {
	benchmarkNetlinkAddElements(b, 5000)
}

func BenchmarkNetlinkAddElements_10k(b *testing.B) {
	benchmarkNetlinkAddElements(b, 10000)
}

func BenchmarkNetlinkAddElements_20k(b *testing.B) {
	benchmarkNetlinkAddElements(b, 20000)
}

func benchmarkNetlinkAddElements(b *testing.B, batchSize int) {
	skipIfNotRoot(b)

	backend, err := NewStandaloneBackend()
	if err != nil {
		b.Fatalf("Failed to create backend: %v", err)
	}
	defer backend.Close()

	// Pre-generate IPs to avoid allocation in hot loop
	elements := make([]SetElement, batchSize)
	for i := 0; i < batchSize; i++ {
		elements[i] = SetElement{
			Value:  fmt.Sprintf("10.%d.%d.%d", (i>>16)&255, (i>>8)&255, i&255),
			TTL:    3600,
			IsIPv6: false,
		}
	}

	setName := "bench_ipv4"
	table := "nftban"

	b.ResetTimer()
	b.ReportAllocs()

	for i := 0; i < b.N; i++ {
		// Flush before each iteration to ensure consistent state
		_ = backend.FlushSet(table, setName)

		// Measure AddElements
		if err := backend.AddElements(table, setName, elements); err != nil {
			b.Fatalf("AddElements failed: %v", err)
		}
	}

	b.ReportMetric(float64(batchSize), "elements/op")
	b.ReportMetric(float64(batchSize)*float64(b.N)/b.Elapsed().Seconds(), "elements/sec")
}

// BenchmarkNetlinkFlushSet measures FlushSet latency for various set sizes
func BenchmarkNetlinkFlushSet_10k(b *testing.B) {
	benchmarkNetlinkFlushSet(b, 10000)
}

func BenchmarkNetlinkFlushSet_100k(b *testing.B) {
	benchmarkNetlinkFlushSet(b, 100000)
}

func benchmarkNetlinkFlushSet(b *testing.B, setSize int) {
	skipIfNotRoot(b)

	backend, err := NewStandaloneBackend()
	if err != nil {
		b.Fatalf("Failed to create backend: %v", err)
	}
	defer backend.Close()

	setName := "bench_ipv4"
	table := "nftban"

	// Pre-populate set
	elements := make([]SetElement, setSize)
	for i := 0; i < setSize; i++ {
		elements[i] = SetElement{
			Value:  fmt.Sprintf("10.%d.%d.%d", (i>>16)&255, (i>>8)&255, i&255),
			TTL:    3600,
			IsIPv6: false,
		}
	}

	b.ResetTimer()
	b.ReportAllocs()

	for i := 0; i < b.N; i++ {
		b.StopTimer()
		// Re-populate for each iteration
		_ = backend.FlushSet(table, setName)
		for j := 0; j < setSize; j += 5000 {
			end := j + 5000
			if end > setSize {
				end = setSize
			}
			_ = backend.AddElements(table, setName, elements[j:end])
		}
		b.StartTimer()

		// Measure FlushSet
		if err := backend.FlushSet(table, setName); err != nil {
			b.Fatalf("FlushSet failed: %v", err)
		}
	}

	b.ReportMetric(float64(setSize), "elements_flushed/op")
}

// BenchmarkReplaceSetStreaming measures end-to-end streaming replace_set
func BenchmarkReplaceSetStreaming_100k(b *testing.B) {
	benchmarkReplaceSetStreaming(b, 100000)
}

func BenchmarkReplaceSetStreaming_500k(b *testing.B) {
	benchmarkReplaceSetStreaming(b, 500000)
}

func benchmarkReplaceSetStreaming(b *testing.B, numElements int) {
	skipIfNotRoot(b)

	backend, err := NewStandaloneBackend()
	if err != nil {
		b.Fatalf("Failed to create backend: %v", err)
	}
	defer backend.Close()

	// Create temp file with IPs
	tmpFile, err := os.CreateTemp("/tmp", "nftban-bench-*.txt")
	if err != nil {
		b.Fatalf("Failed to create temp file: %v", err)
	}
	defer os.Remove(tmpFile.Name())

	for i := 0; i < numElements; i++ {
		fmt.Fprintf(tmpFile, "10.%d.%d.%d\n", (i>>16)&255, (i>>8)&255, i&255)
	}
	tmpFile.Close()

	// Create queue with backend
	config := DefaultQueueConfig()
	config.MaxBatchSize = 10000
	queue := NewOpQueue(backend, config)

	ctx := context.Background()
	queue.Start(ctx)
	defer queue.Stop()

	setName := "bench_ipv4"
	batchConfig := StreamingBatchConfig{BatchSize: 10000}

	// Measure memory before
	var memBefore runtime.MemStats
	runtime.ReadMemStats(&memBefore)

	b.ResetTimer()
	b.ReportAllocs()

	for i := 0; i < b.N; i++ {
		count, err := queue.EnqueueReplaceFromFile(setName, tmpFile.Name(), "bench", batchConfig)
		if err != nil {
			b.Fatalf("EnqueueReplaceFromFile failed: %v", err)
		}
		if count != numElements {
			b.Fatalf("Expected %d elements, got %d", numElements, count)
		}
	}

	// Measure memory after
	var memAfter runtime.MemStats
	runtime.ReadMemStats(&memAfter)

	b.ReportMetric(float64(numElements), "elements/op")
	b.ReportMetric(float64(numElements)*float64(b.N)/b.Elapsed().Seconds(), "elements/sec")
	b.ReportMetric(float64(memAfter.TotalAlloc-memBefore.TotalAlloc)/float64(b.N)/1024/1024, "MB_alloc/op")
}

// BenchmarkFastLaneDuringBulk measures fast lane latency while bulk is running
func BenchmarkFastLaneDuringBulk(b *testing.B) {
	skipIfNotRoot(b)

	backend, err := NewStandaloneBackend()
	if err != nil {
		b.Fatalf("Failed to create backend: %v", err)
	}
	defer backend.Close()

	config := DefaultQueueConfig()
	scheduler := NewScheduler(backend, config)

	ctx := context.Background()
	scheduler.Start(ctx)
	defer scheduler.Stop()

	// Start a bulk job in background
	bulkElements := make([]string, 100000)
	for i := 0; i < len(bulkElements); i++ {
		bulkElements[i] = fmt.Sprintf("10.%d.%d.%d", (i>>16)&255, (i>>8)&255, i&255)
	}

	// Enqueue bulk job (runs in background)
	go func() {
		for i := 0; i < 10; i++ {
			_ = scheduler.EnqueueBulk("feeds_ipv4", bulkElements, "bench")
			time.Sleep(100 * time.Millisecond)
		}
	}()

	// Let bulk start
	time.Sleep(50 * time.Millisecond)

	// Measure fast lane latency
	b.ResetTimer()

	var totalLatency time.Duration
	for i := 0; i < b.N; i++ {
		start := time.Now()
		op := &SetOp{
			Type:    OpAdd,
			Element: fmt.Sprintf("192.168.1.%d", i%255),
			TTL:     3600,
		}
		_ = scheduler.EnqueueFast("auto_ipv4", op)
		totalLatency += time.Since(start)
	}

	avgLatency := totalLatency / time.Duration(b.N)
	b.ReportMetric(float64(avgLatency.Microseconds()), "µs/op")
}
