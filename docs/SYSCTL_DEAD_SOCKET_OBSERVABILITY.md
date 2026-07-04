# Sysctl dead-socket risk guard — idle-age observability

As of v1.216.1, NFTBan's read-only sysctl risk guard (surfaced by the watchdog and `nftban support`)
classifies a local TCP database connection pool by **idle age** relative to the live conntrack
established timeout, rather than warning on any pool. This avoids false alarms on actively-polled
monitoring connections (e.g. a local `zabbix-agent2` PostgreSQL plugin) while still catching genuinely
long-idle sessions that conntrack can evict before TCP keepalive probes.

## Classification

- **CLEAN** — no local TCP DB pool.
- **INFO** — a pool exists but is safe: either its sessions are actively refreshed (max idle well below
  the established timeout), or `nf_conntrack_tcp_timeout_established >= tcp_keepalive_time` (keepalive
  probes before conntrack evicts).
- **WARN** — one or more sessions are long-idle (max idle at or above ~50% of the established timeout)
  while `established < keepalive` — the dead-socket precondition. Only WARN elevates the watchdog.
- **UNKNOWN** — a pool exists but idle age cannot be measured on this host. This is honest, not an error:
  it is never silently treated as CLEAN, and it does not raise a dead-socket WARN.

## Idle-age source, by distribution

Idle age is read host-only (no database credentials, no queries) from conntrack's remaining-timeout
(`idle ≈ established_timeout − remaining`). The available source differs by distribution family:

| Family | Source | Result |
|---|---|---|
| RHEL family (CentOS Stream / AlmaLinux / Rocky, EL9/EL10) | `/proc/net/nf_conntrack` (kernel `CONFIG_NF_CONNTRACK_PROCFS=y`) | **Full** classification (CLEAN/INFO/WARN) |
| Debian / Ubuntu (with the `conntrack` package) | `conntrack -L` (userspace tool) | **Full** classification |
| Debian / Ubuntu (without `conntrack`) | none | **UNKNOWN** when a DB pool is present |

Debian and Ubuntu kernels ship `CONFIG_NF_CONNTRACK_PROCFS=n`, so `/proc/net/nf_conntrack` is absent
there. NFTBan therefore falls back to the `conntrack` userspace tool when present.

## Recommendation for Debian / Ubuntu

Install the `conntrack` package for full idle-age classification:

```
apt install conntrack
```

NFTBan's DEB package lists `conntrack` under **Recommends** (installed by default with apt, and
removable) — it is recommended, not mandatory. Without it, the guard reports **UNKNOWN** for any local
TCP DB pool, which is a safe and honest limited-observability state.

## Where the source is reported

`nftban support` records the active source in `sysctl/idle-age-source.txt`
(`idle_age_source=procfs | conntrack-tool | none | unknown-format`), and the risk-scan lines include an
`[idle_age_source=…]` tag, so an operator can see why a host classified CLEAN / INFO / WARN / UNKNOWN.

A dependency-free reader (via nfnetlink, so Debian/Ubuntu needs no extra package) is planned as a later
enhancement.
