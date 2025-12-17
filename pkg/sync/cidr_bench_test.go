package sync

import (
	"fmt"
	"testing"
)

func BenchmarkMergeCIDRsIPv4(b *testing.B) {
	cidrs := []string{
		"10.0.0.0/24",
		"10.0.1.0/24",
		"10.0.2.0/24",
		"192.168.0.0/16",
		"172.16.0.0/12",
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, err := MergeCIDRs(cidrs, true)
		if err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkMergeCIDRsIPv6(b *testing.B) {
	cidrs := []string{
		"2001:db8::/32",
		"2001:db8:1::/48",
		"2001:db8:2::/48",
		"fe80::/10",
		"fc00::/7",
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, err := MergeCIDRs(cidrs, false)
		if err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkMergeCIDRsIPv6Large(b *testing.B) {
	// Generate 1000 IPv6 CIDRs
	cidrs := make([]string, 1000)
	for i := 0; i < 1000; i++ {
		cidrs[i] = fmt.Sprintf("2001:db8:%x::/48", i)
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_, err := MergeCIDRs(cidrs, false)
		if err != nil {
			b.Fatal(err)
		}
	}
}
