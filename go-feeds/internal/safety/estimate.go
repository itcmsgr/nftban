package safety

// Conservative per-element upper bounds; adjust with real measurements later
const (
	bytesPerV4 = int64(128)
	bytesPerV6 = int64(160)
)

// Projection holds estimated memory usage
type Projection struct {
	ElemsV4 int
	ElemsV6 int
	Bytes   int64
}

// ProjectBytes estimates kernel memory usage for nftables sets
func ProjectBytes(v4, v6 int) Projection {
	b := int64(v4)*bytesPerV4 + int64(v6)*bytesPerV6
	return Projection{ElemsV4: v4, ElemsV6: v6, Bytes: b}
}
