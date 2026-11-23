// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package util

import "testing"

// v1.238 D1/D2: one truth table for module enable switches (same as the shell module gate).
func TestModuleSwitchValue(t *testing.T) {
	for _, c := range []struct {
		in        string
		on, valid bool
	}{
		{"true", true, true}, {"YES", true, true}, {"1", true, true}, {"on", true, true}, {"enabled", true, true},
		{"false", false, true}, {"no", false, true}, {"0", false, true}, {"off", false, true}, {"", false, true},
		{"maybe", false, false}, {"tru", false, false},
	} {
		on, valid := ModuleSwitchValue(c.in)
		if on != c.on || valid != c.valid {
			t.Errorf("ModuleSwitchValue(%q) = %v,%v want %v,%v", c.in, on, valid, c.on, c.valid)
		}
	}
}
