// =============================================================================
// NFTBan - Safe Integer Conversions
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="safeconv"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-02-14"
// meta:description="Safe integer conversion helpers to prevent overflow (gosec G115)"
// meta:input="Integer values of various types"
// meta:output="Converted values with bounds checking"
// meta:depends=""
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

// Package safeconv provides safe integer conversion functions that check bounds
// before converting between integer types, preventing silent overflow bugs.
//
// These helpers address gosec G115 warnings by making bounds explicit.
package safeconv

import (
	"fmt"
	"math"
)

// ToInt16 converts int to int16 with bounds checking.
// Use for config values known to be small (e.g., small counts, flags).
func ToInt16(v int) (int16, error) {
	if v < math.MinInt16 || v > math.MaxInt16 {
		return 0, fmt.Errorf("value %d out of int16 range [%d, %d]", v, math.MinInt16, math.MaxInt16)
	}
	return int16(v), nil
}

// ToInt16OrDefault converts int to int16, returning defaultVal on overflow.
// Use when a fallback is acceptable (e.g., config with defaults).
func ToInt16OrDefault(v int, defaultVal int16) int16 {
	if v < math.MinInt16 || v > math.MaxInt16 {
		return defaultVal
	}
	return int16(v)
}

// ToInt32 converts int to int32 with bounds checking.
// Use for IDs, partition numbers, etc.
func ToInt32(v int) (int32, error) {
	if v < math.MinInt32 || v > math.MaxInt32 {
		return 0, fmt.Errorf("value %d out of int32 range", v)
	}
	return int32(v), nil
}

// ToInt32OrDefault converts int to int32, returning defaultVal on overflow.
func ToInt32OrDefault(v int, defaultVal int32) int32 {
	if v < math.MinInt32 || v > math.MaxInt32 {
		return defaultVal
	}
	return int32(v)
}

// ToUint32 converts int to uint32 with bounds checking.
// Use for sizes, counts, and other non-negative bounded values.
func ToUint32(n int) (uint32, error) {
	if n < 0 || n > int(math.MaxUint32) {
		return 0, fmt.Errorf("value %d out of uint32 range [0, %d]", n, uint32(math.MaxUint32))
	}
	return uint32(n), nil
}

// ToUint32OrZero converts int to uint32, returning 0 on invalid input.
func ToUint32OrZero(n int) uint32 {
	if n < 0 || n > int(math.MaxUint32) {
		return 0
	}
	return uint32(n)
}

// ToUint64 converts int to uint64 with non-negative check.
// Use for sizes, lengths, and counts.
func ToUint64(n int) (uint64, error) {
	if n < 0 {
		return 0, fmt.Errorf("negative value cannot convert to uint64: %d", n)
	}
	return uint64(n), nil
}

// ToUint64OrZero converts int to uint64, returning 0 if negative.
func ToUint64OrZero(n int) uint64 {
	if n < 0 {
		return 0
	}
	return uint64(n)
}

// Int64ToUint64 converts int64 to uint64 with non-negative check.
// Use for timestamps, byte counts, etc.
func Int64ToUint64(v int64) (uint64, error) {
	if v < 0 {
		return 0, fmt.Errorf("negative int64 cannot convert to uint64: %d", v)
	}
	return uint64(v), nil
}

// Int64ToUint64OrZero converts int64 to uint64, returning 0 if negative.
func Int64ToUint64OrZero(v int64) uint64 {
	if v < 0 {
		return 0
	}
	return uint64(v)
}

// Uint64ToInt64 converts uint64 to int64 with overflow check.
func Uint64ToInt64(v uint64) (int64, error) {
	if v > math.MaxInt64 {
		return 0, fmt.Errorf("uint64 %d overflows int64", v)
	}
	return int64(v), nil
}

// Uint64ToInt64OrMax converts uint64 to int64, capping at MaxInt64.
func Uint64ToInt64OrMax(v uint64) int64 {
	if v > math.MaxInt64 {
		return math.MaxInt64
	}
	return int64(v)
}

// ToPort converts int to uint16 port number with validation.
// Valid range: 0-65535
func ToPort(v int) (uint16, error) {
	if v < 0 || v > 65535 {
		return 0, fmt.Errorf("invalid port number: %d (must be 0-65535)", v)
	}
	return uint16(v), nil
}

// ToPortOrDefault converts int to port, returning defaultPort on invalid.
func ToPortOrDefault(v int, defaultPort uint16) uint16 {
	if v < 0 || v > 65535 {
		return defaultPort
	}
	return uint16(v)
}

// UintptrToInt converts uintptr to int with overflow check.
// Use for memory mapping / pointer math on 64-bit systems.
func UintptrToInt(u uintptr) (int, error) {
	if u > uintptr(math.MaxInt) {
		return 0, fmt.Errorf("uintptr %d overflows int", u)
	}
	return int(u), nil
}

// UintptrToIntOrZero converts uintptr to int, returning 0 on overflow.
func UintptrToIntOrZero(u uintptr) int {
	if u > uintptr(math.MaxInt) {
		return 0
	}
	return int(u)
}

// IntToUintptr converts int to uintptr with non-negative check.
func IntToUintptr(n int) (uintptr, error) {
	if n < 0 {
		return 0, fmt.Errorf("negative int cannot convert to uintptr: %d", n)
	}
	return uintptr(n), nil
}

// IntToUintptrOrZero converts int to uintptr, returning 0 if negative.
func IntToUintptrOrZero(n int) uintptr {
	if n < 0 {
		return 0
	}
	return uintptr(n)
}

// RuneToByte converts rune to byte with bounds check.
// Only ASCII characters (0-127) are valid.
func RuneToByte(r rune) (byte, error) {
	if r < 0 || r > 127 {
		return 0, fmt.Errorf("rune %d (%c) out of ASCII byte range", r, r)
	}
	return byte(r), nil
}

// RuneToByteOrDefault converts rune to byte, returning defaultVal for non-ASCII.
func RuneToByteOrDefault(r rune, defaultVal byte) byte {
	if r < 0 || r > 127 {
		return defaultVal
	}
	return byte(r)
}

// Int8ToByte converts int8 to byte (always safe, just changes interpretation).
// Included for consistency; negative int8 becomes high byte values.
func Int8ToByte(v int8) byte {
	return byte(v)
}

// UintToInt64 converts uint to int64 with overflow check.
// On 64-bit systems, uint can exceed MaxInt64.
func UintToInt64(v uint) (int64, error) {
	if v > math.MaxInt64 {
		return 0, fmt.Errorf("uint %d overflows int64", v)
	}
	return int64(v), nil
}

// UintToInt64OrMax converts uint to int64, capping at MaxInt64 on overflow.
func UintToInt64OrMax(v uint) int64 {
	if v > math.MaxInt64 {
		return math.MaxInt64
	}
	return int64(v)
}
