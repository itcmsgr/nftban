package safety

import (
	"fmt"
	"strings"
	"time"

	"github.com/google/nftables"
)

const minChunk = 256

// AddChunkedWithRetry adds elements in chunks with ENOBUFS retry logic
// Automatically reduces chunk size and retries on netlink buffer errors
func AddChunkedWithRetry(conn *nftables.Conn, set *nftables.Set, elems []nftables.SetElement) error {
	chunk := 4096
	i := 0

	for i < len(elems) {
		j := i + chunk
		if j > len(elems) {
			j = len(elems)
		}

		err := conn.SetAddElements(set, elems[i:j])
		if err != nil {
			// Check for netlink buffer errors
			if strings.Contains(err.Error(), "ENOBUFS") || strings.Contains(err.Error(), "message too long") {
				if chunk <= minChunk {
					return fmt.Errorf("netlink buffer too small even at min chunk %d: %w", minChunk, err)
				}
				// Exponential backoff: halve chunk and wait
				chunk /= 2
				time.Sleep(100 * time.Millisecond)
				fmt.Printf("⚠️  Netlink ENOBUFS, reducing chunk to %d and retrying\n", chunk)
				continue // Retry same position with smaller chunk
			}
			// Other errors are fatal
			return fmt.Errorf("add elements chunk %d-%d: %w", i, j, err)
		}

		// Success, move to next chunk
		i = j
	}

	return nil
}
