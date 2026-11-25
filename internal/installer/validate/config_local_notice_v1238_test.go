// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package validate

// v1.238 D5 (owner 2026-11-23): one advisory line after install/upgrade when operator *.conf.local
// settings need attention; file:line and key only (no values); never fails the run.

import (
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/fhs"
)

const doctorKey = fhs.NftbanCLI + ":config:local:doctor:--json"

func TestConfigLocalNoticeListsLocationsNotValues(t *testing.T) {
	m := executor.NewMockExecutor()
	m.RunResults[doctorKey] = executor.Result{ExitCode: 1, Stdout: `[
	  {"path":"/etc/nftban/conf.d/feeds.conf.local","syntax":"OK","keys":[
	    {"key":"FEED_A5LOCAL_URL","line":3,"class":"OK","message":""},
	    {"key":"FEED_A5LOCAL_ENABELD","line":4,"class":"UNKNOWN_KEY","message":"UNKNOWN"}]},
	  {"path":"/etc/nftban/conf.d/ddos/main.conf.local","syntax":"OK","keys":[
	    {"key":"DDOS_WHITELIST_FILE","line":2,"class":"DEPRECATED_KEY","message":"deprecated"}]}]`}
	log := nolog()
	RunConfigLocalNotice(m, log)
	w := strings.Join(log.Warnings(), "\n")
	if log.WarnCount() != 1 {
		t.Fatalf("want exactly one advisory line, got %d: %q", log.WarnCount(), w)
	}
	for _, want := range []string{"2 setting(s)", "/etc/nftban/conf.d/feeds.conf.local:4 FEED_A5LOCAL_ENABELD",
		"/etc/nftban/conf.d/ddos/main.conf.local:2 DDOS_WHITELIST_FILE", "nftban config local doctor", "not changed"} {
		if !strings.Contains(w, want) {
			t.Errorf("notice lacks %q: %q", want, w)
		}
	}
	if strings.Contains(w, "FEED_A5LOCAL_URL") {
		t.Errorf("OK keys must not be listed: %q", w)
	}
}

func TestConfigLocalNoticeSilentWhenCleanOrUnavailable(t *testing.T) {
	for name, res := range map[string]executor.Result{
		"clean":       {ExitCode: 0, Stdout: `[{"path":"/etc/nftban/nftban.conf.local","syntax":"OK","keys":[{"key":"SSH_PORT","line":1,"class":"OK","message":""}]}]`},
		"unavailable": {ExitCode: 127, Stdout: ""},
	} {
		m := executor.NewMockExecutor()
		m.RunResults[doctorKey] = res
		log := nolog()
		RunConfigLocalNotice(m, log)
		if log.WarnCount() != 0 {
			t.Errorf("%s: want no notice, got %q", name, log.Warnings())
		}
	}
}
