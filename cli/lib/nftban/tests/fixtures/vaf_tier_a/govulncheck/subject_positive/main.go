// SYNTHETIC VAF Tier-A control subject — CALLS the symbol the synthetic DB marks vulnerable.
// Expected: GO-9999-0001 at level=error (reachable).
package main

import "net/url"

func main() {
	u, err := url.Parse("https://example.com/vaf-control")
	if err != nil {
		return
	}
	println(u.Host)
}
