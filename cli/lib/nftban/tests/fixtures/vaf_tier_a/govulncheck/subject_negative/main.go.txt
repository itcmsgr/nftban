// SYNTHETIC VAF Tier-A control subject — does NOT call the symbol.
// Expected: GO-9999-0001 STILL PRESENT, at level=note (present, not proven reachable).
// ⛔ The negative arm asserts a LEVEL TRANSITION, not an absence.
package main

func main() {
	println("vaf control: symbol not called")
}
