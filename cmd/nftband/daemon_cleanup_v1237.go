// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="nftband_cleanup_v1237"
// meta:type="daemon"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.237 permanent-ban cleanup repair (design V1237_CLEANUP_REPAIR_DESIGN_2026_11_14 §0): dry-run, execute and stats use the single EvaluateCleanup calculation; execute re-validates eligibility, protection and the remaining reasons under the shared reason-file lock set, removes only the eligible reason, deletes the kernel element only when no reason remains, and records an intent marker so an interrupted removal is finished by the next run. protect works for every durable ban."
// meta:inventory.files="/etc/nftban/blacklist.d,/var/lib/nftban/permanent_bans.json"
// meta:inventory.privileges="root"

package main

import (
	"fmt"
	"sort"
	"time"

	"github.com/itcmsgr/nftban/internal/persistence"
	"github.com/itcmsgr/nftban/internal/safety"
)

// cleanupKernel is the kernel side of a removal (the daemon's backend Unban; a fake in tests).
type cleanupKernel interface {
	Unban(ip string) error
}

// cleanupHooks are test-only interruption points; nil in production.
type cleanupHooks struct {
	beforeLock   func(ip string)       // between selection and the locked re-check
	afterMark    func(ip string) error // after the intent marker, before the durable removal
	afterDurable func(ip string) error // after the durable removal, before kernel / tracking
}

// cleanupItem is the per-IP result of a run.
type cleanupItem struct {
	IP     string `json:"ip"`
	Source string `json:"source,omitempty"`
	Result string `json:"result"` // removed | reason-removed-kernel-kept | skipped:<why> | failed:<err> | finished-pending
}

// cleanupReport is the outcome of evaluate / execute: counters follow the real result.
type cleanupReport struct {
	Examined  int            `json:"examined"`
	Eligible  int            `json:"eligible"`
	Removed   int            `json:"removed"`
	Finished  int            `json:"finished_pending"`
	Failed    int            `json:"failed"`
	Excluded  map[string]int `json:"excluded"`
	Items     []cleanupItem  `json:"items"`
	Selected  []string       `json:"ips"` // eligible IPs (dry-run) or acted-on IPs (execute)
	Protected int            `json:"protected"`
	Tracked   int            `json:"tracked"`
}

func cleanupEvaluate(configDir string, now time.Time) ([]safety.CleanupDecision, *safety.PermanentBansState, error) {
	reasons, err := persistence.ReasonsForAll(configDir)
	if err != nil {
		return nil, nil, err
	}
	st, err := safety.LoadPermanentBansForCleanup()
	if err != nil {
		return nil, nil, err
	}
	return safety.EvaluateCleanup(reasons, st, now, safety.BanAgeThresholdDays), st, nil
}

// cleanupSummarize builds the report from decisions (dry-run / stats); eligible capped at count, oldest first.
func cleanupSummarize(decs []safety.CleanupDecision, st *safety.PermanentBansState, count int) cleanupReport {
	r := cleanupReport{Excluded: map[string]int{}}
	var elig []safety.CleanupDecision
	for _, d := range decs {
		r.Examined++
		if d.Eligible {
			elig = append(elig, d)
			continue
		}
		r.Excluded[d.Exclusion]++
		r.Items = append(r.Items, cleanupItem{IP: d.IP, Source: d.Source, Result: "excluded:" + d.Exclusion})
	}
	sort.SliceStable(elig, func(i, j int) bool { return elig[i].AddedAt.Before(elig[j].AddedAt) })
	r.Eligible = len(elig)
	for i, d := range elig {
		if count > 0 && i >= count {
			break
		}
		r.Selected = append(r.Selected, d.IP)
		r.Items = append(r.Items, cleanupItem{IP: d.IP, Source: d.Source, Result: "eligible"})
	}
	for _, b := range st.Bans {
		r.Tracked++
		if b.Protected {
			r.Protected++
		}
	}
	return r
}

// cleanupExecute runs one cleanup: finish interrupted removals, then remove up to count eligible reasons.
func cleanupExecute(configDir string, now time.Time, count int, k cleanupKernel, h cleanupHooks) (cleanupReport, error) {
	decs, st, err := cleanupEvaluate(configDir, now)
	if err != nil {
		return cleanupReport{}, err
	}
	r := cleanupSummarize(decs, st, count)
	r.Items, r.Selected = nil, nil
	for _, d := range decs {
		if d.FinishPending {
			res := cleanupFinishPending(configDir, d.IP, k)
			if res == "finished-pending" {
				r.Finished++
			} else if len(res) > 7 && res[:7] == "failed:" {
				r.Failed++
			}
			r.Items = append(r.Items, cleanupItem{IP: d.IP, Source: d.Source, Result: res})
		}
	}
	var elig []safety.CleanupDecision
	for _, d := range decs {
		if d.Eligible {
			elig = append(elig, d)
		}
	}
	sort.SliceStable(elig, func(i, j int) bool { return elig[i].AddedAt.Before(elig[j].AddedAt) })
	for i, d := range elig {
		if count > 0 && i >= count {
			break
		}
		if h.beforeLock != nil {
			h.beforeLock(d.IP)
		}
		res, stop := cleanupRemoveOne(configDir, d.IP, d.Source, now, k, h)
		r.Items = append(r.Items, cleanupItem{IP: d.IP, Source: d.Source, Result: res})
		r.Selected = append(r.Selected, d.IP)
		switch {
		case res == "removed" || res == "reason-removed-kernel-kept":
			r.Removed++
		case len(res) > 7 && res[:7] == "failed:":
			r.Failed++
		}
		if stop {
			break // a test interruption: leave the rest exactly as a crash would
		}
	}
	return r, nil
}

// cleanupRemoveOne is the locked transaction for one (ip, source). Order (design §0.4):
// re-check -> intent marker -> durable reason removal -> kernel delete only if no reason remains ->
// tracking removal / marker clear. Every step is idempotent; a retry re-evaluates from durable state.
func cleanupRemoveOne(configDir, ip, source string, now time.Time, k cleanupKernel, h cleanupHooks) (res string, stop bool) {
	unlock, err := persistence.LockAllReasons(configDir)
	if err != nil {
		return "failed:" + err.Error(), false
	}
	defer unlock()

	reasons, err := persistence.ReasonsForIP(configDir, ip)
	if err != nil {
		return "failed:" + err.Error(), false
	}
	st, err := safety.LoadPermanentBansForCleanup()
	if err != nil {
		return "failed:" + err.Error(), false
	}
	// Re-validate with the full tracking state (bulk windows need it) under the lock set.
	ok := false
	why := "no-longer-a-candidate"
	for _, d := range safety.EvaluateCleanup(map[string][]string{ip: reasons}, st, now, safety.BanAgeThresholdDays) {
		if d.IP == ip && d.Source == source {
			ok, why = d.Eligible, d.Exclusion
		}
	}
	if !ok {
		return "skipped:" + why, false
	}
	if err := safety.SetCleanupPending(ip, source); err != nil {
		return "failed:" + err.Error(), false
	}
	if h.afterMark != nil {
		if err := h.afterMark(ip); err != nil {
			return "failed:" + err.Error(), true
		}
	}
	if _, err := persistence.RemoveIPFromSourceLocked(configDir, ip, source); err != nil {
		return "failed:" + err.Error(), false
	}
	if h.afterDurable != nil {
		if err := h.afterDurable(ip); err != nil {
			return "failed:" + err.Error(), true
		}
	}
	remaining, err := persistence.ReasonsForIP(configDir, ip)
	if err != nil {
		return "failed:" + err.Error(), false
	}
	if len(remaining) > 0 {
		// another authority still requires the ban: keep the kernel element, clear the marker
		if err := safety.SetCleanupPending(ip, ""); err != nil {
			return "failed:" + err.Error(), false
		}
		return "reason-removed-kernel-kept", false
	}
	if err := k.Unban(ip); err != nil {
		return "failed:kernel:" + err.Error(), false // marker stays: the next run finishes it
	}
	if err := safety.RemovePermanentBan(ip); err != nil {
		return "failed:tracking:" + err.Error(), false
	}
	return "removed", false
}

// cleanupFinishPending finishes an interrupted removal under the lock set: if the marked entry has no
// durable reason left, delete the kernel element and the tracking entry; if a reason still exists
// (the removal never reached the durable step, or a new reason arrived), only clear the marker.
func cleanupFinishPending(configDir, ip string, k cleanupKernel) string {
	unlock, err := persistence.LockAllReasons(configDir)
	if err != nil {
		return "failed:" + err.Error()
	}
	defer unlock()
	st, err := safety.LoadPermanentBansForCleanup()
	if err != nil {
		return "failed:" + err.Error()
	}
	tr := st.Bans[ip]
	if tr == nil || tr.CleanupPending == "" || tr.Protected {
		return "skipped:not-pending"
	}
	reasons, err := persistence.ReasonsForIP(configDir, ip)
	if err != nil {
		return "failed:" + err.Error()
	}
	if len(reasons) > 0 {
		if err := safety.SetCleanupPending(ip, ""); err != nil {
			return "failed:" + err.Error()
		}
		return "skipped:reason-present-marker-cleared"
	}
	if err := k.Unban(ip); err != nil {
		return "failed:kernel:" + err.Error()
	}
	if err := safety.RemovePermanentBan(ip); err != nil {
		return "failed:tracking:" + err.Error()
	}
	return "finished-pending"
}

// cleanupProtect marks ip protected under the lock set. A durable ban without tracking history is
// tracked with an UNKNOWN age (never invented) and protected (design §0.5). A non-durable IP is refused.
func cleanupProtect(configDir, ip string, protected bool) error {
	return persistence.WithAllReasonLocks(configDir, func() error {
		st, err := safety.LoadPermanentBans()
		if err != nil {
			return err
		}
		if _, ok := st.Bans[ip]; ok {
			return safety.SetBanProtected(ip, protected)
		}
		if !protected {
			return fmt.Errorf("IP %s is not tracked; nothing to unprotect", ip)
		}
		reasons, err := persistence.ReasonsForIP(configDir, ip)
		if err != nil {
			return err
		}
		if len(reasons) == 0 {
			return fmt.Errorf("IP %s is not a durable ban (no blacklist.d entry); nothing to protect", ip)
		}
		return safety.TrackDurableUnknownAge(ip, reasons[0], true)
	})
}

// trackAtBanTime records a permanent ban AT BAN TIME under the lock set (shared write boundary).
func trackAtBanTime(configDir, ip, reason, source string, protected bool) error {
	return persistence.WithAllReasonLocks(configDir, func() error {
		return safety.TrackPermanentBan(ip, reason, source, protected)
	})
}
