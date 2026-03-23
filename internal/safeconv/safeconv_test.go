// =============================================================================
// NFTBan - Safe Integer Conversion Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="safeconv_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-19"
// meta:description="Test cases for safe integer conversion helpers"
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

package safeconv

import (
	"math"
	"testing"
)

// =============================================================================
// ToInt16 / ToInt16OrDefault
// =============================================================================

func TestToInt16(t *testing.T) {
	tests := []struct {
		name    string
		input   int
		want    int16
		wantErr bool
	}{
		{"zero", 0, 0, false},
		{"positive in range", 100, 100, false},
		{"negative in range", -100, -100, false},
		{"max int16", math.MaxInt16, math.MaxInt16, false},
		{"min int16", math.MinInt16, math.MinInt16, false},
		{"overflow above max", math.MaxInt16 + 1, 0, true},
		{"overflow below min", math.MinInt16 - 1, 0, true},
		{"large positive", 100000, 0, true},
		{"large negative", -100000, 0, true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := ToInt16(tc.input)
			if (err != nil) != tc.wantErr {
				t.Errorf("ToInt16(%d) error = %v, wantErr %v", tc.input, err, tc.wantErr)
				return
			}
			if got != tc.want {
				t.Errorf("ToInt16(%d) = %d, want %d", tc.input, got, tc.want)
			}
		})
	}
}

func TestToInt16OrDefault(t *testing.T) {
	tests := []struct {
		name       string
		input      int
		defaultVal int16
		want       int16
	}{
		{"in range returns value", 42, -1, 42},
		{"zero returns zero", 0, -1, 0},
		{"max int16", math.MaxInt16, -1, math.MaxInt16},
		{"min int16", math.MinInt16, -1, math.MinInt16},
		{"overflow returns default", math.MaxInt16 + 1, -1, -1},
		{"underflow returns default", math.MinInt16 - 1, 99, 99},
		{"large value returns default", 999999, 50, 50},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := ToInt16OrDefault(tc.input, tc.defaultVal)
			if got != tc.want {
				t.Errorf("ToInt16OrDefault(%d, %d) = %d, want %d", tc.input, tc.defaultVal, got, tc.want)
			}
		})
	}
}

// =============================================================================
// ToInt32 / ToInt32OrDefault
// =============================================================================

func TestToInt32(t *testing.T) {
	tests := []struct {
		name    string
		input   int
		want    int32
		wantErr bool
	}{
		{"zero", 0, 0, false},
		{"positive in range", 12345, 12345, false},
		{"negative in range", -12345, -12345, false},
		{"max int32", math.MaxInt32, math.MaxInt32, false},
		{"min int32", math.MinInt32, math.MinInt32, false},
		{"overflow above max", math.MaxInt32 + 1, 0, true},
		{"overflow below min", math.MinInt32 - 1, 0, true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := ToInt32(tc.input)
			if (err != nil) != tc.wantErr {
				t.Errorf("ToInt32(%d) error = %v, wantErr %v", tc.input, err, tc.wantErr)
				return
			}
			if got != tc.want {
				t.Errorf("ToInt32(%d) = %d, want %d", tc.input, got, tc.want)
			}
		})
	}
}

func TestToInt32OrDefault(t *testing.T) {
	tests := []struct {
		name       string
		input      int
		defaultVal int32
		want       int32
	}{
		{"in range returns value", 500, -1, 500},
		{"zero returns zero", 0, -1, 0},
		{"max int32", math.MaxInt32, -1, math.MaxInt32},
		{"min int32", math.MinInt32, -1, math.MinInt32},
		{"overflow returns default", math.MaxInt32 + 1, 77, 77},
		{"underflow returns default", math.MinInt32 - 1, 88, 88},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := ToInt32OrDefault(tc.input, tc.defaultVal)
			if got != tc.want {
				t.Errorf("ToInt32OrDefault(%d, %d) = %d, want %d", tc.input, tc.defaultVal, got, tc.want)
			}
		})
	}
}

// =============================================================================
// ToUint32 / ToUint32OrZero
// =============================================================================

func TestToUint32(t *testing.T) {
	tests := []struct {
		name    string
		input   int
		want    uint32
		wantErr bool
	}{
		{"zero", 0, 0, false},
		{"positive in range", 1000, 1000, false},
		{"max uint32", int(math.MaxUint32), math.MaxUint32, false},
		{"one", 1, 1, false},
		{"negative", -1, 0, true},
		{"large negative", -999999, 0, true},
		{"overflow above max", int(math.MaxUint32) + 1, 0, true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := ToUint32(tc.input)
			if (err != nil) != tc.wantErr {
				t.Errorf("ToUint32(%d) error = %v, wantErr %v", tc.input, err, tc.wantErr)
				return
			}
			if got != tc.want {
				t.Errorf("ToUint32(%d) = %d, want %d", tc.input, got, tc.want)
			}
		})
	}
}

func TestToUint32OrZero(t *testing.T) {
	tests := []struct {
		name  string
		input int
		want  uint32
	}{
		{"positive in range", 42, 42},
		{"zero", 0, 0},
		{"max uint32", int(math.MaxUint32), math.MaxUint32},
		{"negative returns zero", -1, 0},
		{"overflow returns zero", int(math.MaxUint32) + 1, 0},
		{"large negative returns zero", -1000000, 0},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := ToUint32OrZero(tc.input)
			if got != tc.want {
				t.Errorf("ToUint32OrZero(%d) = %d, want %d", tc.input, got, tc.want)
			}
		})
	}
}

// =============================================================================
// ToUint64 / ToUint64OrZero
// =============================================================================

func TestToUint64(t *testing.T) {
	tests := []struct {
		name    string
		input   int
		want    uint64
		wantErr bool
	}{
		{"zero", 0, 0, false},
		{"positive", 999, 999, false},
		{"max int", math.MaxInt, uint64(math.MaxInt), false},
		{"one", 1, 1, false},
		{"negative", -1, 0, true},
		{"large negative", -9999999, 0, true},
		{"min int", math.MinInt, 0, true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := ToUint64(tc.input)
			if (err != nil) != tc.wantErr {
				t.Errorf("ToUint64(%d) error = %v, wantErr %v", tc.input, err, tc.wantErr)
				return
			}
			if got != tc.want {
				t.Errorf("ToUint64(%d) = %d, want %d", tc.input, got, tc.want)
			}
		})
	}
}

func TestToUint64OrZero(t *testing.T) {
	tests := []struct {
		name  string
		input int
		want  uint64
	}{
		{"positive", 123, 123},
		{"zero", 0, 0},
		{"max int", math.MaxInt, uint64(math.MaxInt)},
		{"negative returns zero", -1, 0},
		{"min int returns zero", math.MinInt, 0},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := ToUint64OrZero(tc.input)
			if got != tc.want {
				t.Errorf("ToUint64OrZero(%d) = %d, want %d", tc.input, got, tc.want)
			}
		})
	}
}

// =============================================================================
// Int64ToUint64 / Int64ToUint64OrZero
// =============================================================================

func TestInt64ToUint64(t *testing.T) {
	tests := []struct {
		name    string
		input   int64
		want    uint64
		wantErr bool
	}{
		{"zero", 0, 0, false},
		{"positive", 42, 42, false},
		{"max int64", math.MaxInt64, uint64(math.MaxInt64), false},
		{"one", 1, 1, false},
		{"negative", -1, 0, true},
		{"min int64", math.MinInt64, 0, true},
		{"large negative", -999999999, 0, true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := Int64ToUint64(tc.input)
			if (err != nil) != tc.wantErr {
				t.Errorf("Int64ToUint64(%d) error = %v, wantErr %v", tc.input, err, tc.wantErr)
				return
			}
			if got != tc.want {
				t.Errorf("Int64ToUint64(%d) = %d, want %d", tc.input, got, tc.want)
			}
		})
	}
}

func TestInt64ToUint64OrZero(t *testing.T) {
	tests := []struct {
		name  string
		input int64
		want  uint64
	}{
		{"positive", 100, 100},
		{"zero", 0, 0},
		{"max int64", math.MaxInt64, uint64(math.MaxInt64)},
		{"negative returns zero", -1, 0},
		{"min int64 returns zero", math.MinInt64, 0},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := Int64ToUint64OrZero(tc.input)
			if got != tc.want {
				t.Errorf("Int64ToUint64OrZero(%d) = %d, want %d", tc.input, got, tc.want)
			}
		})
	}
}

// =============================================================================
// Uint64ToInt64 / Uint64ToInt64OrMax
// =============================================================================

func TestUint64ToInt64(t *testing.T) {
	tests := []struct {
		name    string
		input   uint64
		want    int64
		wantErr bool
	}{
		{"zero", 0, 0, false},
		{"small value", 42, 42, false},
		{"max int64 as uint64", uint64(math.MaxInt64), math.MaxInt64, false},
		{"one", 1, 1, false},
		{"overflow at max int64 + 1", uint64(math.MaxInt64) + 1, 0, true},
		{"max uint64", math.MaxUint64, 0, true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := Uint64ToInt64(tc.input)
			if (err != nil) != tc.wantErr {
				t.Errorf("Uint64ToInt64(%d) error = %v, wantErr %v", tc.input, err, tc.wantErr)
				return
			}
			if got != tc.want {
				t.Errorf("Uint64ToInt64(%d) = %d, want %d", tc.input, got, tc.want)
			}
		})
	}
}

func TestUint64ToInt64OrMax(t *testing.T) {
	tests := []struct {
		name  string
		input uint64
		want  int64
	}{
		{"small value", 10, 10},
		{"zero", 0, 0},
		{"max int64", uint64(math.MaxInt64), math.MaxInt64},
		{"overflow caps at max int64", uint64(math.MaxInt64) + 1, math.MaxInt64},
		{"max uint64 caps at max int64", math.MaxUint64, math.MaxInt64},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := Uint64ToInt64OrMax(tc.input)
			if got != tc.want {
				t.Errorf("Uint64ToInt64OrMax(%d) = %d, want %d", tc.input, got, tc.want)
			}
		})
	}
}

// =============================================================================
// ToPort / ToPortOrDefault
// =============================================================================

func TestToPort(t *testing.T) {
	tests := []struct {
		name    string
		input   int
		want    uint16
		wantErr bool
	}{
		{"port zero", 0, 0, false},
		{"port 80", 80, 80, false},
		{"port 443", 443, 443, false},
		{"port 8080", 8080, 8080, false},
		{"port 22", 22, 22, false},
		{"port 65535 (max)", 65535, 65535, false},
		{"port 1 (min valid)", 1, 1, false},
		{"negative port", -1, 0, true},
		{"port 65536 (overflow)", 65536, 0, true},
		{"very large port", 100000, 0, true},
		{"very negative", -50000, 0, true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := ToPort(tc.input)
			if (err != nil) != tc.wantErr {
				t.Errorf("ToPort(%d) error = %v, wantErr %v", tc.input, err, tc.wantErr)
				return
			}
			if got != tc.want {
				t.Errorf("ToPort(%d) = %d, want %d", tc.input, got, tc.want)
			}
		})
	}
}

func TestToPortOrDefault(t *testing.T) {
	tests := []struct {
		name        string
		input       int
		defaultPort uint16
		want        uint16
	}{
		{"valid port returns value", 8080, 80, 8080},
		{"zero port", 0, 80, 0},
		{"max port", 65535, 80, 65535},
		{"negative returns default", -1, 80, 80},
		{"overflow returns default", 65536, 443, 443},
		{"large value returns default", 999999, 22, 22},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := ToPortOrDefault(tc.input, tc.defaultPort)
			if got != tc.want {
				t.Errorf("ToPortOrDefault(%d, %d) = %d, want %d", tc.input, tc.defaultPort, got, tc.want)
			}
		})
	}
}

// =============================================================================
// UintptrToInt / UintptrToIntOrZero
// =============================================================================

func TestUintptrToInt(t *testing.T) {
	tests := []struct {
		name    string
		input   uintptr
		want    int
		wantErr bool
	}{
		{"zero", 0, 0, false},
		{"small value", 100, 100, false},
		{"max int as uintptr", uintptr(math.MaxInt), math.MaxInt, false},
		{"one", 1, 1, false},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := UintptrToInt(tc.input)
			if (err != nil) != tc.wantErr {
				t.Errorf("UintptrToInt(%d) error = %v, wantErr %v", tc.input, err, tc.wantErr)
				return
			}
			if got != tc.want {
				t.Errorf("UintptrToInt(%d) = %d, want %d", tc.input, got, tc.want)
			}
		})
	}
}

func TestUintptrToIntOrZero(t *testing.T) {
	tests := []struct {
		name  string
		input uintptr
		want  int
	}{
		{"small value", 50, 50},
		{"zero", 0, 0},
		{"max int", uintptr(math.MaxInt), math.MaxInt},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := UintptrToIntOrZero(tc.input)
			if got != tc.want {
				t.Errorf("UintptrToIntOrZero(%d) = %d, want %d", tc.input, got, tc.want)
			}
		})
	}
}

// =============================================================================
// IntToUintptr / IntToUintptrOrZero
// =============================================================================

func TestIntToUintptr(t *testing.T) {
	tests := []struct {
		name    string
		input   int
		want    uintptr
		wantErr bool
	}{
		{"zero", 0, 0, false},
		{"positive", 256, 256, false},
		{"max int", math.MaxInt, uintptr(math.MaxInt), false},
		{"one", 1, 1, false},
		{"negative", -1, 0, true},
		{"large negative", -999999, 0, true},
		{"min int", math.MinInt, 0, true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := IntToUintptr(tc.input)
			if (err != nil) != tc.wantErr {
				t.Errorf("IntToUintptr(%d) error = %v, wantErr %v", tc.input, err, tc.wantErr)
				return
			}
			if got != tc.want {
				t.Errorf("IntToUintptr(%d) = %d, want %d", tc.input, got, tc.want)
			}
		})
	}
}

func TestIntToUintptrOrZero(t *testing.T) {
	tests := []struct {
		name  string
		input int
		want  uintptr
	}{
		{"positive", 64, 64},
		{"zero", 0, 0},
		{"max int", math.MaxInt, uintptr(math.MaxInt)},
		{"negative returns zero", -1, 0},
		{"min int returns zero", math.MinInt, 0},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := IntToUintptrOrZero(tc.input)
			if got != tc.want {
				t.Errorf("IntToUintptrOrZero(%d) = %d, want %d", tc.input, got, tc.want)
			}
		})
	}
}

// =============================================================================
// RuneToByte / RuneToByteOrDefault
// =============================================================================

func TestRuneToByte(t *testing.T) {
	tests := []struct {
		name    string
		input   rune
		want    byte
		wantErr bool
	}{
		{"ASCII letter A", 'A', 65, false},
		{"ASCII letter z", 'z', 122, false},
		{"ASCII digit 0", '0', 48, false},
		{"ASCII space", ' ', 32, false},
		{"ASCII null", 0, 0, false},
		{"ASCII DEL (127)", 127, 127, false},
		{"non-ASCII 128", 128, 0, true},
		{"unicode char", 0x00E9, 0, true},     // e with accent
		{"emoji", 0x1F600, 0, true},            // grinning face
		{"negative rune", -1, 0, true},
		{"large unicode", 0x10000, 0, true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := RuneToByte(tc.input)
			if (err != nil) != tc.wantErr {
				t.Errorf("RuneToByte(%d) error = %v, wantErr %v", tc.input, err, tc.wantErr)
				return
			}
			if got != tc.want {
				t.Errorf("RuneToByte(%d) = %d, want %d", tc.input, got, tc.want)
			}
		})
	}
}

func TestRuneToByteOrDefault(t *testing.T) {
	tests := []struct {
		name       string
		input      rune
		defaultVal byte
		want       byte
	}{
		{"ASCII returns value", 'X', '?', 'X'},
		{"null byte", 0, '?', 0},
		{"max ASCII", 127, '?', 127},
		{"non-ASCII returns default", 128, '?', '?'},
		{"unicode returns default", 0x00E9, '!', '!'},
		{"negative returns default", -1, '#', '#'},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := RuneToByteOrDefault(tc.input, tc.defaultVal)
			if got != tc.want {
				t.Errorf("RuneToByteOrDefault(%d, %d) = %d, want %d", tc.input, tc.defaultVal, got, tc.want)
			}
		})
	}
}

// =============================================================================
// Int8ToByte
// =============================================================================

func TestInt8ToByte(t *testing.T) {
	tests := []struct {
		name  string
		input int8
		want  byte
	}{
		{"zero", 0, 0},
		{"positive max", 127, 127},
		{"positive one", 1, 1},
		{"negative one wraps", -1, 255},
		{"min int8 wraps", -128, 128},
		{"negative fifty wraps", -50, 206},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := Int8ToByte(tc.input)
			if got != tc.want {
				t.Errorf("Int8ToByte(%d) = %d, want %d", tc.input, got, tc.want)
			}
		})
	}
}

// =============================================================================
// UintToInt64 / UintToInt64OrMax
// =============================================================================

func TestUintToInt64(t *testing.T) {
	tests := []struct {
		name    string
		input   uint
		want    int64
		wantErr bool
	}{
		{"zero", 0, 0, false},
		{"small value", 42, 42, false},
		{"one", 1, 1, false},
		{"max int64 as uint", uint(math.MaxInt64), math.MaxInt64, false},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := UintToInt64(tc.input)
			if (err != nil) != tc.wantErr {
				t.Errorf("UintToInt64(%d) error = %v, wantErr %v", tc.input, err, tc.wantErr)
				return
			}
			if got != tc.want {
				t.Errorf("UintToInt64(%d) = %d, want %d", tc.input, got, tc.want)
			}
		})
	}
}

func TestUintToInt64OrMax(t *testing.T) {
	tests := []struct {
		name  string
		input uint
		want  int64
	}{
		{"small value", 10, 10},
		{"zero", 0, 0},
		{"max int64", uint(math.MaxInt64), math.MaxInt64},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := UintToInt64OrMax(tc.input)
			if got != tc.want {
				t.Errorf("UintToInt64OrMax(%d) = %d, want %d", tc.input, got, tc.want)
			}
		})
	}
}

// =============================================================================
// Overflow boundary tests on 64-bit systems
// =============================================================================

func TestUintptrOverflow_64bit(t *testing.T) {
	// On 64-bit systems, uintptr can exceed MaxInt.
	// This test documents the overflow boundary.
	maxSafe := uintptr(math.MaxInt)

	got, err := UintptrToInt(maxSafe)
	if err != nil {
		t.Errorf("UintptrToInt(MaxInt) should succeed, got error: %v", err)
	}
	if got != math.MaxInt {
		t.Errorf("UintptrToInt(MaxInt) = %d, want %d", got, math.MaxInt)
	}

	// One past max should fail on 64-bit
	_, err = UintptrToInt(maxSafe + 1)
	if err == nil {
		t.Error("UintptrToInt(MaxInt+1) should return error on 64-bit")
	}
}

func TestUintOverflow_64bit(t *testing.T) {
	// On 64-bit systems, uint can exceed MaxInt64.
	maxSafe := uint(math.MaxInt64)

	got, err := UintToInt64(maxSafe)
	if err != nil {
		t.Errorf("UintToInt64(MaxInt64) should succeed, got error: %v", err)
	}
	if got != math.MaxInt64 {
		t.Errorf("UintToInt64(MaxInt64) = %d, want %d", got, math.MaxInt64)
	}

	// One past max should fail
	_, err = UintToInt64(maxSafe + 1)
	if err == nil {
		t.Error("UintToInt64(MaxInt64+1) should return error")
	}

	// OrMax variant should cap
	capped := UintToInt64OrMax(maxSafe + 1)
	if capped != math.MaxInt64 {
		t.Errorf("UintToInt64OrMax(MaxInt64+1) = %d, want %d", capped, math.MaxInt64)
	}
}
