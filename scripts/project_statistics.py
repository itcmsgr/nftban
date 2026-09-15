#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan — Project download & traffic statistics collector (internal-first)
# =============================================================================
# Evidence-bounded. Counts GitHub Release *asset download requests* and GitHub
# repository *traffic*. These are NOT unique users, installations, active
# systems, mirrors, CI jobs, or fleet size. Do not relabel them as such.
#
# Outputs (written under --out, intended for the orphan `stats` branch):
#   current.json  snapshots.csv  package-history.csv  github-traffic-daily.csv
#   platform-totals.csv  release-totals.csv  asset-classification.json
#   collection-report.txt
#
# Auth: release/repo data works with the Actions GITHUB_TOKEN. The /traffic
# endpoints do NOT (GITHUB_TOKEN => "Resource not accessible by integration"),
# so a PAT with Administration:Read must be provided via STATS_TRAFFIC_TOKEN.
# Missing/denied traffic auth is RECORDED, never silently omitted.
# =============================================================================
import os, re, sys, json, csv, subprocess, argparse
from datetime import datetime, timezone, timedelta

OWNER_REPO = "itcmsgr/nftban"

PLATFORMS = [
    ("Ubuntu 22.04", r'^nftban-ubuntu22\.04-.*\.deb$', "DEB"),
    ("Ubuntu 24.04", r'^nftban-ubuntu24\.04-.*\.deb$', "DEB"),
    ("Ubuntu 26.04", r'^nftban-ubuntu26\.04-.*\.deb$', "DEB"),
    ("Debian 12",    r'^nftban-debian12-.*\.deb$',     "DEB"),
    ("Debian 13",    r'^nftban-debian13-.*\.deb$',     "DEB"),
    ("EL9",          r'^nftban-el9-.*\.rpm$',          "RPM"),
    ("EL10",         r'^nftban-el10-.*\.rpm$',         "RPM"),
    ("Fedora 42",    r'^nftban-fc42-.*\.rpm$',         "RPM"),
    ("Fedora 43",    r'^nftban-fc43-.*\.rpm$',         "RPM"),
]
PLATFORMS = [(n, re.compile(p), f) for n, p, f in PLATFORMS]
META_RX = re.compile(r'(\.intoto\.jsonl$|\.spdx\.json$|^sbom|SHA256SUMS|MANIFEST|VERIFY|\.sig$|\.pem$|\.asc$)', re.I)
STANDALONE_RX = re.compile(r'^(nftban-core-|nftband-)')
# legacy package-looking assets from early releases (e.g. nftban-core_1.0.0_amd64.deb, nftban-x86_64.rpm)
PKG_EXT_RX = re.compile(r'\.(deb|rpm)$', re.I)


def gh(path, token_env=None, paginate=False):
    """Call `gh api`. token_env: name of env var whose value overrides GH_TOKEN."""
    cmd = ["gh", "api"]
    if paginate:
        cmd += ["--paginate", "--slurp"]
    cmd.append(path)
    env = dict(os.environ)
    if token_env and os.environ.get(token_env):
        env["GH_TOKEN"] = os.environ[token_env]
        env["GITHUB_TOKEN"] = os.environ[token_env]
    p = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if p.returncode != 0:
        return None, (p.stderr or "").strip()
    return json.loads(p.stdout), None


def classify_releases(release_pages):
    rels = [r for page in release_pages for r in page]
    plat = {n: 0 for n, _, _ in PLATFORMS}
    deb = rpm = pkg = standalone = meta = allrel = legacy = 0
    rc = ac = prerel = 0
    unclassified = []
    per_release = {}
    for r in rels:
        if r.get("draft"):
            continue
        rc += 1
        if r.get("prerelease"):
            prerel += 1
        tag = r.get("tag_name")
        rtotal = 0
        for a in r.get("assets", []):
            n, d = a["name"], a["download_count"]
            ac += 1; allrel += d; rtotal += d
            if META_RX.search(n):
                meta += d; continue
            hit = False
            for name, rx, fam in PLATFORMS:
                if rx.match(n):
                    plat[name] += d; pkg += d
                    deb += d if fam == "DEB" else 0
                    rpm += d if fam == "RPM" else 0
                    hit = True; break
            if hit:
                continue
            if STANDALONE_RX.match(n):
                standalone += d; continue
            if PKG_EXT_RX.search(n):     # package-looking but no platform match => legacy/other
                legacy += d
                unclassified.append({"name": n, "downloads": d, "tag": tag})
        per_release[tag] = rtotal
    return {
        "releases_measured": rc, "prereleases": prerel, "assets_scanned": ac,
        "package_downloads": pkg, "deb_downloads": deb, "rpm_downloads": rpm,
        "standalone_binary_downloads": standalone, "metadata_downloads": meta,
        "legacy_package_downloads": legacy, "all_release_asset_downloads": allrel,
        "per_platform": plat, "unclassified": unclassified, "per_release": per_release,
    }


def fetch_traffic(kind, token_env):
    data, err = gh(f"repos/{OWNER_REPO}/traffic/{kind}", token_env=token_env)
    if data is None:
        return None, err
    key = kind  # 'clones' or 'views'
    per_day = [{"date": e["timestamp"][:10], "count": e["count"], "uniques": e["uniques"]}
               for e in data.get(key, [])]
    return {"count": data.get("count", 0), "uniques": data.get("uniques", 0), "days": per_day}, None


def read_csv(path):
    if not os.path.exists(path):
        return []
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def write_csv(path, rows, fields):
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields, restval="", extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow(r)


def fetch_referrers(token_env):
    """External referrer views. KNOWN for the rolling 14d window only."""
    data, err = gh(f"repos/{OWNER_REPO}/traffic/popular/referrers", token_env=token_env)
    if data is None:
        return None, err
    return [{"referrer": r.get("referrer"), "views": r.get("count"),
             "uniques": r.get("uniques")} for r in data], None


def fetch_ci_runs(since_date):
    """Our own workflow-run count. Used ONLY to attribute clone contamination.

    Clone counts are dominated by CI checkouts (observed ~2-7 clones per run),
    so clones must never be read as third-party interest without this denominator.
    """
    data, err = gh(f"repos/{OWNER_REPO}/actions/runs?created=>={since_date}&per_page=1")
    if data is None:
        return None, err
    return data.get("total_count"), None


def rolling_windows(outdir):
    """DERIVED rolling aggregates from the daily CSV.

    rolling_*_visitor_days is a SUM OF DAILY UNIQUES. That is visitor-days, NOT
    distinct people: GitHub deduplicates only within a window and exposes no
    cross-window identity, so distinct-visitor counts over any period longer than
    the API window are NOT_MEASURABLE.
    """
    rows = read_csv(os.path.join(outdir, "github-traffic-daily.csv"))
    rows = sorted(rows, key=lambda r: r["date"])
    out = {}
    for n in (7, 14, 45):
        tail = rows[-n:]
        v = sum(int(r.get("view_count", 0) or 0) for r in tail)
        vd = sum(int(r.get("unique_visitors", 0) or 0) for r in tail)
        c = sum(int(r.get("clone_count", 0) or 0) for r in tail)
        cd = sum(int(r.get("unique_cloners", 0) or 0) for r in tail)
        out[f"rolling_{n}d_views"] = v
        out[f"rolling_{n}d_visitor_days"] = vd
        out[f"rolling_{n}d_clones"] = c
        out[f"rolling_{n}d_cloner_days"] = cd
        out[f"rolling_{n}d_views_per_visitor_day"] = round(v / vd, 2) if vd else None
        out[f"rolling_{n}d_days_observed"] = len(tail)
    return out


def merge_daily_traffic(outdir, clones, views, report):
    path = os.path.join(outdir, "github-traffic-daily.csv")
    # views_per_daily_unique is DERIVED. It is views divided by the uniques GitHub
    # deduplicated FOR THAT DAY. It is an engagement-depth ratio, NOT an adoption
    # measure: with ~30 reported uniques/week a few repeat readers move it materially.
    fields = ["date", "clone_count", "unique_cloners", "view_count", "unique_visitors",
              "views_per_daily_unique", "note"]
    raw = read_csv(path)
    seen, dup_raw = set(), 0
    for r in raw:                      # count duplicates BEFORE the dict collapses them
        if r.get("date") in seen:
            dup_raw += 1
        seen.add(r.get("date"))
    existing = {r["date"]: r for r in raw}
    cl = {d["date"]: d for d in (clones["days"] if clones else [])}
    vw = {d["date"]: d for d in (views["days"] if views else [])}
    for date in sorted(set(cl) | set(vw) | set(existing)):
        row = existing.get(date, {"date": date, "clone_count": 0, "unique_cloners": 0,
                                  "view_count": 0, "unique_visitors": 0, "note": ""})
        note = row.get("note", "") or ""
        for src, ck, uk in ((cl, "clone_count", "unique_cloners"), (vw, "view_count", "unique_visitors")):
            if date in src:
                for newv, k in ((src[date]["count"], ck), (src[date]["uniques"], uk)):
                    oldv = int(row.get(k, 0) or 0)
                    if newv < oldv and oldv > 0:      # nonzero -> lower: keep max, record anomaly
                        note = (note + f";ANOMALY {k} {oldv}->{newv} kept {oldv}").strip(";")
                        report.append(f"ANOMALY {date} {k}: observed {newv} < stored {oldv}; kept {oldv}")
                    else:
                        row[k] = newv
        uv = int(row.get("unique_visitors", 0) or 0)
        vc = int(row.get("view_count", 0) or 0)
        row["views_per_daily_unique"] = f"{vc / uv:.2f}" if uv > 0 else ""
        row["note"] = note
        existing[date] = row
    if dup_raw:
        # Refuse BEFORE writing: the on-disk series is already corrupt and a silent
        # dict-collapse would rewrite it as if it had always been clean, destroying
        # the evidence that duplicates existed.
        report.append(f"FATAL duplicate dates in {path}: {dup_raw}")
        return None, dup_raw
    rows = [existing[d] for d in sorted(existing)]
    write_csv(path, rows, fields)
    return len(rows), dup_raw


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--releases-file", help="optional pre-fetched releases JSON (list of pages)")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    now = datetime.now(timezone.utc)
    snap_date = now.strftime("%Y-%m-%d")
    snap_at = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    report = [f"NFTBan statistics collection @ {snap_at}"]

    # 1) releases
    if args.releases_file and os.path.exists(args.releases_file):
        pages = json.load(open(args.releases_file))
    else:
        pages, err = gh(f"repos/{OWNER_REPO}/releases?per_page=100", paginate=True)
        if pages is None:
            print(f"FATAL: cannot fetch releases: {err}", file=sys.stderr); sys.exit(2)
    rel = classify_releases(pages)
    report.append(f"releases_measured={rel['releases_measured']} assets={rel['assets_scanned']} "
                  f"package={rel['package_downloads']} unclassified_legacy={len(rel['unclassified'])}")

    # arithmetic reconciliation
    recon = (sum(rel["per_platform"].values()) == rel["package_downloads"]
             == rel["deb_downloads"] + rel["rpm_downloads"])
    report.append(f"reconcile package==sum(platforms)==DEB+RPM: {'PASS' if recon else 'FAIL'}")

    # 2) repo counters
    repo, rerr = gh(f"repos/{OWNER_REPO}")
    stars = repo.get("stargazers_count") if repo else None
    forks = repo.get("forks_count") if repo else None
    issues = repo.get("open_issues_count") if repo else None

    # 3) traffic (needs Administration:Read PAT; degrade gracefully)
    clones, cerr = fetch_traffic("clones", "STATS_TRAFFIC_TOKEN")
    views, verr = fetch_traffic("views", "STATS_TRAFFIC_TOKEN")
    traffic_ok = clones is not None and views is not None
    report.append(f"traffic_auth: {'PASS' if traffic_ok else 'FAIL'}"
                  + ("" if traffic_ok else f" (clones:{cerr} views:{verr}) -> need PAT with Administration:Read as STATS_TRAFFIC_TOKEN"))
    ndaily, dup_dates = merge_daily_traffic(args.out, clones, views, report)
    if ndaily is None:
        print(f"GATE FAILURE: {dup_dates} duplicate date(s) in the on-disk daily series; "
              "every rolling aggregate derived from it would be wrong.", file=sys.stderr)
        print("REFUSING TO EMIT: nothing written back; the corrupt file is preserved "
              "for inspection rather than silently de-duplicated.", file=sys.stderr)
        sys.exit(2)

    # 3b) contamination denominator + referrer attribution + derived rollups
    since = (now - timedelta(days=14)).strftime("%Y-%m-%d")
    ci_runs, ci_err = fetch_ci_runs(since)
    referrers, ref_err = fetch_referrers("STATS_TRAFFIC_TOKEN")
    rolling = rolling_windows(args.out)
    clones_per_run = (round(rolling["rolling_14d_clones"] / ci_runs, 2)
                      if ci_runs else None)
    ext_ref_views = (sum(r["views"] for r in referrers
                         if r["referrer"] not in ("github.com",))
                     if referrers else None)
    report.append(f"ci_workflow_runs_14d={ci_runs} clones_per_workflow_run={clones_per_run}"
                  + ("" if ci_runs else f" (ci_runs unavailable: {ci_err})"))
    report.append("clones are CI-CONTAMINATED and must not be read as third-party interest")

    # 4) snapshots.csv (one row per UTC date; deterministic update-in-place; delta vs previous)
    snap_path = os.path.join(args.out, "snapshots.csv")
    snaps = {r["snapshot_date"]: r for r in read_csv(snap_path)}
    prev_dates = sorted(d for d in snaps if d < snap_date)
    prev_pkg = int(snaps[prev_dates[-1]]["package_downloads"]) if prev_dates else rel["package_downloads"]
    delta = rel["package_downloads"] - prev_pkg
    snaps[snap_date] = {
        "snapshot_date": snap_date, "snapshot_at": snap_at,
        "package_downloads": rel["package_downloads"],
        "package_delta": delta,
        "deb_downloads": rel["deb_downloads"], "rpm_downloads": rel["rpm_downloads"],
        "standalone_binary_downloads": rel["standalone_binary_downloads"],
        "metadata_downloads": rel["metadata_downloads"],
        "all_release_asset_downloads": rel["all_release_asset_downloads"],
        "stars": stars, "forks": forks, "open_issues": issues,
        "rolling_14d_clones": clones["count"] if clones else "",
        "rolling_14d_unique_cloners": clones["uniques"] if clones else "",
        "rolling_14d_views": views["count"] if views else "",
        "rolling_14d_unique_visitors": views["uniques"] if views else "",
    }
    snap_fields = ["snapshot_date", "snapshot_at", "package_downloads", "package_delta",
                   "deb_downloads", "rpm_downloads", "standalone_binary_downloads",
                   "metadata_downloads", "all_release_asset_downloads", "stars", "forks",
                   "open_issues", "rolling_14d_clones", "rolling_14d_unique_cloners",
                   "rolling_14d_views", "rolling_14d_unique_visitors"]
    write_csv(snap_path, [snaps[d] for d in sorted(snaps)], snap_fields)

    # 5) package-history.csv (per-snapshot cumulative totals for the weekly-new trend)
    ph_path = os.path.join(args.out, "package-history.csv")
    ph = {r["snapshot_date"]: r for r in read_csv(ph_path)}
    ph[snap_date] = {"snapshot_date": snap_date, "package_downloads": rel["package_downloads"],
                     "package_delta": delta, "deb_downloads": rel["deb_downloads"],
                     "rpm_downloads": rel["rpm_downloads"]}
    write_csv(ph_path, [ph[d] for d in sorted(ph)],
              ["snapshot_date", "package_downloads", "package_delta", "deb_downloads", "rpm_downloads"])

    # 6) platform-totals.csv, release-totals.csv, asset-classification.json
    write_csv(os.path.join(args.out, "platform-totals.csv"),
              [{"platform": k, "downloads": v} for k, v in rel["per_platform"].items()],
              ["platform", "downloads"])
    # Version-aware sort so releases order semantically (v1.9.0 < v1.10.0 <
    # v1.220.8) and the newest release lands at the end — NOT lexical, which
    # buried every v1.1xx/v1.2xx release mid-file between v1.98 and v1.99.
    def _relkey(item):
        return tuple(int(p) for p in re.findall(r"\d+", item[0]))

    write_csv(os.path.join(args.out, "release-totals.csv"),
              [{"tag": t, "asset_downloads": n}
               for t, n in sorted(rel["per_release"].items(), key=_relkey)],
              ["tag", "asset_downloads"])
    json.dump({"snapshot_at": snap_at, "platforms": [n for n, _, _ in PLATFORMS],
               "unclassified_legacy": rel["unclassified"]},
              open(os.path.join(args.out, "asset-classification.json"), "w"), indent=2)

    # 7) current.json
    current = {
        "snapshot_at": snap_at, "snapshot_date": snap_date,
        "disclosure": (
            "GitHub Release asset download requests and repository traffic counters. These INCLUDE "
            "NFTBan-operated infrastructure: an ~11-host fleet (dns1-4, srv1-4, monitor, lab2, lab4) "
            "self-updates by downloading DEB/RPM assets from GitHub Releases, and package-native "
            "validation downloads official assets too. GitHub exposes aggregate counts only, with no "
            "downloader identity or IP, so NFTBan-owned traffic cannot be identified or removed and "
            "historical counts are NOT retroactively adjusted. Do not read raw package downloads or "
            "clones as purely external adoption, or as unique users, installations, active systems, "
            "mirrors, CI jobs, or fleet size. Unique visitors are substantially less fleet-contaminated "
            "(automated hosts do not browse the repository web UI); non-release-day package-download "
            "deltas are the cleanest external-interest signal. A typical release-day internal baseline "
            "is approximately 11 fleet hosts plus validation downloads -- this is an ESTIMATE and is "
            "never subtracted from the reported counts. Future mirror routing of fleet updates can "
            "reduce this contamination prospectively (see OPEN_FLEET_UPDATE_MIRROR_SOURCE_SCOPE)."),
        "fleet_contamination": {
            "raw_counts_include_nftban_infrastructure": True,
            "fleet_hosts_approx": 11,
            "fleet_hosts": ["dns1", "dns2", "dns3", "dns4", "srv1", "srv2", "srv3", "srv4",
                            "monitor", "lab2", "lab4"],
            "exact_deduplication_possible": False,
            "reason": "GitHub exposes aggregate counters only; no downloader identity/IP.",
            "release_day_internal_baseline_estimate": "~11 fleet hosts + package-native validation (ESTIMATE, not subtracted)",
            "cleaner_external_signals": ["unique_visitors", "non_release_day_package_delta"],
            "historical_counts_retroactively_adjusted": False,
            "fabricated_fleet_excluded_metric": False},
        "package_downloads": rel["package_downloads"], "package_delta": delta,
        "deb_downloads": rel["deb_downloads"], "rpm_downloads": rel["rpm_downloads"],
        "standalone_binary_downloads": rel["standalone_binary_downloads"],
        "metadata_downloads": rel["metadata_downloads"],
        "all_release_asset_downloads": rel["all_release_asset_downloads"],
        "per_platform": rel["per_platform"],
        "releases_measured": rel["releases_measured"], "assets_scanned": rel["assets_scanned"],
        "stars": stars, "forks": forks, "open_issues": issues,
        "rolling_14d": {"clones": clones["count"] if clones else None,
                        "unique_cloners": clones["uniques"] if clones else None,
                        "views": views["count"] if views else None,
                        "unique_visitors": views["uniques"] if views else None},
        "traffic_auth": "PASS" if traffic_ok else "FAIL",
        "reconciles": recon,
        "rolling_derived": rolling,
        "ci_workflow_runs_14d": ci_runs,
        "clones_per_workflow_run": clones_per_run,
        "external_referrer_views_14d": ext_ref_views,
        "referrers_14d": referrers,
        "metric_semantics": {
            "_": "How far each number may be pushed. Consumers MUST NOT promote a metric "
                 "to a stronger class than listed here.",
            "views": "KNOWN — page/repo views for the window.",
            "daily_unique_visitors": "KNOWN — GitHub-deduplicated for that DAY only.",
            "rolling_14d_unique_visitors": "KNOWN — GitHub-deduplicated within the current "
                                           "14-day window only.",
            "rolling_Nd_visitor_days": "DERIVED — a SUM OF DAILY UNIQUES. This is VISITOR-DAYS, "
                                       "not distinct people. One person returning on five days "
                                       "contributes five.",
            "distinct_visitors_over_any_period_longer_than_the_api_window":
                "NOT_MEASURABLE — the traffic API exposes a rolling window and no downloader or "
                "visitor identity, so cross-window deduplication is impossible. Never state a "
                "45-day distinct-visitor count.",
            "views_per_daily_unique": "DERIVED — engagement-depth ratio. At ~30 reported uniques "
                                      "per week a few repeat readers move it materially; a "
                                      "multi-week move is NOT a demonstrated trend without a "
                                      "variance check against daily noise.",
            "clones": "KNOWN_BUT_CI_CONTAMINATED — dominated by our own workflow checkouts "
                      "(observed ~2-7 clones per run). See clones_per_workflow_run.",
            "unique_cloners": "KNOWN_BUT_AUTOMATION_CONTAMINATED — mirrors, scrapers and CI "
                              "runners each register.",
            "package_downloads": "KNOWN — .deb/.rpm asset downloads only.",
            "all_release_asset_downloads": "KNOWN — includes SHA256SUMS, SBOM, manifests and "
                                           "standalone binaries. ALWAYS label which of the two "
                                           "is quoted; they differ materially.",
            "installations": "NOT_MEASURABLE — a download is not an install.",
            "users": "NOT_MEASURABLE — no identity is exposed at any layer.",
        },
    }
    json.dump(current, open(os.path.join(args.out, "current.json"), "w"), indent=2)

    # 8) badge (hand-rendered SVG, no external scripts) — package downloads
    badge = package_badge(rel["package_downloads"])
    os.makedirs(os.path.join(args.out, "badges"), exist_ok=True)
    open(os.path.join(args.out, "badges", "package-downloads.svg"), "w").write(badge)

    report.append(f"snapshot_date={snap_date} package_delta={delta} traffic_daily_rows={ndaily} dup_dates={dup_dates}")
    open(os.path.join(args.out, "collection-report.txt"), "w").write("\n".join(report) + "\n")

    print("\n".join(report))
    print(f"GATE reconcile={'PASS' if recon else 'FAIL'} traffic_auth={'PASS' if traffic_ok else 'FAIL'} "
          f"dup_dates={dup_dates} unclassified_pkg_alarm={len(rel['unclassified'])}")

    # ---- FAIL-LOUDLY GATE -----------------------------------------------------
    # Until now this gate only PRINTED. The workflow then ran `git add` + `git commit`
    # unconditionally, so an invalid collection was committed to the stats branch and
    # read back later as fact. That is a failed observation rendering as a successful
    # result — the exact class of defect these statistics are used to reason about.
    #
    # Two conditions make the OUTPUT semantically invalid, and both now exit non-zero
    # so the workflow stops BEFORE committing:
    #   * reconcile FAIL  — package_downloads != sum(platforms) != DEB+RPM
    #   * dup_dates > 0   — the daily series would carry duplicate dates
    #
    # traffic_auth FAIL is deliberately NOT fatal: collecting without a traffic PAT is a
    # documented degraded mode, and merge_daily_traffic adds no rows when traffic is
    # absent, so it cannot write zeros that would later read as real zeros. It is
    # reported loudly instead.
    fatal = []
    if not recon:
        fatal.append("reconcile=FAIL: package_downloads != sum(per_platform) != DEB+RPM; "
                     "download totals are internally inconsistent")
    if not traffic_ok:
        print("WARNING: traffic_auth=FAIL — collecting in documented degraded mode "
              "(no STATS_TRAFFIC_TOKEN). Release/star data still valid; traffic rows "
              "unchanged, NOT zero-filled.", file=sys.stderr)
    if fatal:
        for f in fatal:
            print(f"GATE FAILURE: {f}", file=sys.stderr)
        print("REFUSING TO EMIT: collection is semantically invalid and must not be "
              "committed. No partial data written back.", file=sys.stderr)
        sys.exit(2)


def package_badge(total):
    label, value = "package downloads", f"{total:,}"
    lw, vw = 118, 8 + len(value) * 7
    w = lw + vw
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="20" role="img" '
            f'aria-label="{label}: {value}"><linearGradient id="s" x2="0" y2="100%">'
            f'<stop offset="0" stop-color="#bbb" stop-opacity=".1"/><stop offset="1" stop-opacity=".1"/>'
            f'</linearGradient><rect rx="3" width="{w}" height="20" fill="#555"/>'
            f'<rect rx="3" x="{lw}" width="{vw}" height="20" fill="#4c1"/>'
            f'<rect rx="3" width="{w}" height="20" fill="url(#s)"/>'
            f'<g fill="#fff" text-anchor="middle" font-family="DejaVu Sans,Verdana,sans-serif" font-size="11">'
            f'<text x="{lw/2}" y="14">{label}</text>'
            f'<text x="{lw + vw/2}" y="14">{value}</text></g></svg>')


if __name__ == "__main__":
    main()
