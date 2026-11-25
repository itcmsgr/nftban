// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package main

import (
	"reflect"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/uninstall"
)

// v1.238: the uninstall quiesces the same table writers as the CSF restore (A.6b).
func TestUninstallTableWriterUnitsMatchCSFRestore(t *testing.T) {
	want := append([]string{nftbandSocketUnit}, nftbanTableTouchingTimers...)
	if !reflect.DeepEqual(uninstall.TableWriterUnits, want) {
		t.Errorf("uninstall.TableWriterUnits = %v, CSF restore quiesces %v", uninstall.TableWriterUnits, want)
	}
}
