# Metrics truth

**Last verified: v1.218.5.**

This page explains what NFTBan's metrics layer is, where its data lives, and — importantly — what it
does and does not prove. It is a reference for reading metrics correctly, not a tuning guide, and it
does not change any metrics behavior. Known exporter defects are noted and routed to the metrics lane,
not fixed here.

## Prerequisites

- Root or `nftban` group membership to read `/var/cache/nftban/metrics/` and query the daemon socket.
- `jq` for reading the JSON cache.

## 1. The unified stats cache is the source of truth

NFTBan collects metrics into a single JSON cache:

```
/var/cache/nftban/metrics/stats.json
```

It is written by the unified exporter (`/usr/lib/nftban/exporters/nftban_unified_exporter.sh`, run by
`nftban-unified-exporter.timer`). The cache carries a `schema_version`; consumers reject a cache
without a valid one. Its freshness window is 300 seconds (5 minutes) — a reading older than that is
considered stale and recollected.

Real field paths (examples):

```bash
jq .blacklist.total                 /var/cache/nftban/metrics/stats.json
jq .blacklist.ipv4.permanent        /var/cache/nftban/metrics/stats.json
jq .activity.total_bans             /var/cache/nftban/metrics/stats.json
jq .nftables.apply_latency_ms       /var/cache/nftban/metrics/stats.json
```

## 2. `nftban stats export` vs `nftban metrics`

These are different tools — do not confuse them:

- **`nftban export`** is an alias for **`nftban stats export`**. It emits the stats in **`json`
  (default) or `csv`**, optionally to `--output FILE`. There is no Prometheus format on this path.
- **`nftban metrics`** manages the **Prometheus metrics collection integration** (Prometheus /
  node_exporter). It enables or disables that integration; it is not the exporter itself.

```bash
nftban stats export --format json                 # or: --format csv
nftban stats export --format json --output /tmp/stats.json
```

## 3. Prometheus output

When a node_exporter textfile directory is present, the unified exporter writes a **single** file:

```
/var/lib/node_exporter/textfile_collector/nftban.prom
```

(The directory and filename are overridable via `NFTBAN_PROMETHEUS_TEXTFILE_DIR` /
`NFTBAN_PROMETHEUS_OUTPUT_FILE`.) Prometheus export auto-enables only when that textfile directory
already exists. There are no per-module `.prom` files — everything is in `nftban.prom`.

## 4. The daemon HTTP endpoint (`:9580`)

The daemon binds an HTTP endpoint on **`127.0.0.1:9580` (loopback) by default**, and the bind is
**enforced**, not merely defaulted:

- A loopback bind address is accepted as-is.
- A non-loopback bind address (a routable IP, `0.0.0.0`, `::`, a hostname, or an empty host) is
  **refused and the daemon falls back to loopback**, unless the operator explicitly sets
  `NFTBAN_API_ALLOW_INSECURE_BIND=YES` (the SEC-P1-3a escape hatch).
- The `/metrics` path is additionally restricted to `127.0.0.1` / `::1` and returns HTTP 403 from any
  other client.

The bind address is configurable via the daemon's `APIAddr` config. Treat `:9580` as a local-only
endpoint unless you have deliberately opened it.

## 5. Metrics are a report layer — the kernel is the truth

Metrics and CLI summaries describe state; they do not enforce it. Two consequences an operator must
keep in mind:

- **Enforcement truth is the kernel.** To know an IP is actually banned, read the set:
  `nft list set ip nftban blacklist_ipv4` (see [Ban forensics](BAN_FORENSICS.md)). The four-axis
  health view is built on the Go validator precisely so the CLI does not compute health independently.
- **The daemon's HTTP `/health` is not a posture signal.** It returns a fixed `{"status":"ok"}`
  regardless of real state. Use `nftban validate` and `nft list tables` to judge protection, not the
  HTTP health route.

## 6. Known metrics defects — tracked in the metrics lane

These are open items owned by the observability/metrics lane, not by this doc. They are listed here so
operators reading metrics know the caveats; the fixes are scoped and gated separately.

- **`EXPORTER-PROM-MULTIWRITER` (P1):** the Go collector and the shell exporter can write the same
  `nftban.prom` without a shared lock. Tracked in the metrics lane
  (`NFTBAN_ROADMAP/NFTBAN_PENDINGS_AND_BUGS_CURRENT.md`, Cluster D).
- **`DAEMON-HTTP-HEALTH-ALWAYS-OK` (P3):** the daemon `/health` route is hardcoded to `ok`
  (`cmd/nftband/daemon_http.go`), which is why kernel/validator checks — not HTTP `/health` — are the
  posture truth. Tracked in the same lane.

Report new metrics-accuracy issues to the metrics lane rather than working around them in
integrations.

## Failure modes and caveats

- **A 5-minute-old cache is expected.** `stats.json` has a 300s freshness window; a reading is not
  "live to the second."
- **`nftban.prom` only appears if node_exporter's textfile directory exists.** No directory, no
  `.prom` file — that is by design, not a fault.
- **`:9580` is loopback by default and refuses insecure binds** unless `NFTBAN_API_ALLOW_INSECURE_BIND=YES`
  is set. If you expect remote scraping and see nothing, that guard is why.

## References

- Unified cache / exporter: `cli/lib/nftban/core/nftban_stats.sh`, `exporters/nftban_unified_exporter.sh`, `exporters/nftban_unified_exporter_export.sh`
- JSON field compat: `cli/lib/nftban/exporters/nftban_exporter_json_compat.sh`
- Export / metrics commands: `cli/lib/nftban/cli/cmd_stats.sh`, `cmd_metrics.sh`
- Daemon HTTP bind rules: `cmd/nftband/daemon_http.go`, `daemon_types.go`
- Related: [Ban forensics](BAN_FORENSICS.md), [Production baseline](PRODUCTION_BASELINE.md)
