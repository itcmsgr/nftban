# Community trial telemetry — schema_version 3 (private, opt-in)

**Last verified: v1.218.7.** **Status: TRIAL (internal analysis only, not a public launch).**

This is the client-side contract for the **v3 trial** community telemetry: a private, opt-in, minimal,
privacy-safe payload built by NFTBan and sent to `stats.nftban.com` **only when the operator explicitly
enables it**. It exists so the project can analyze real-world deployment shape (versions, distros,
module/health state) on the current v1.218.7 product before building the paid Pro dashboard.

## Why v3 (and why v2 is untouched)

`schema_version 2` was designed against NFTBan **v1.95**. It is **not wrong** — it is **frozen legacy**
and keeps working for existing clients. But it predates BotGuard, BotScan, Suricata EVE, RBL/RBLMON,
Tunnel, and the central-comms Communication health component, so it under-reports current reality.
**v3 is the current-state (v1.218.7) trial payload.** v2 is never edited; the client can emit either.

## Non-negotiable privacy invariants

The v3 FREE community payload contains **only non-identifying, bucketed, class-level data**. It MUST NOT
contain any of:

- IP addresses (source, banned, listed, bind, peer) · hostnames · domains · email addresses · usernames
- tokens/secrets · admin ports · network topology · ban lists
- raw logs · raw Suricata/EVE events or signatures · raw RBL/DNSBL/provider-bounce results · config file contents
- any customer-identifying data

The only identifier is a random, stable, anonymous `install_id` (generated locally at `enable` time).

## Consent model (opt-in, no silent enablement)

- **Default: OFF.** `COMMUNITY_STATS_ENABLED=no` out of the box; nothing is ever sent until the operator opts in.
- `nftban pro community show` — prints the **exact** payload that would be sent (preview before consent).
- `nftban pro community enable` — requires an **explicit yes** confirmation; only then does it flip the flag and generate the anonymous id.
- `nftban pro community send-test` — sends **one** payload and prints the server response.
- `nftban pro community disable` — stops all future sends.
- `nftban pro community status` — shows enrollment state, id, endpoint, schema version.
- **No automatic periodic sends occur until explicitly enabled.** The one-time `/install-result` heartbeat is **NOT** sent without the same opt-in (default off; gated behind community-enable).

## v3 payload (field-for-field)

```json
{
  "schema_version": 3,
  "trial_mode": true,
  "internal_analysis_only": true,
  "consent_version": "1",
  "nftban_version": "1.218.7",
  "payload_created_at": "2026-07-08T00:00:00Z",
  "anonymous_install_id": "<16hex>-<8hex>",
  "package_type": "deb|rpm|source|docker|unknown",
  "update_channel": "stable|unknown",

  "platform": {
    "os_family": "debian|rhel|unknown",
    "distro": "debian|ubuntu|almalinux|rocky|centos|fedora|rhel|unknown",
    "distro_version": "12",
    "kernel_major_minor": "6.1",
    "architecture": "x86_64|aarch64|unknown",
    "cpu_count_bucket": "1|2|2-4|4-8|8-16|16+",
    "ram_bucket": "<=1GB|1-2GB|2-4GB|4-8GB|8-16GB|16-32GB|32GB+",
    "container": "true|false|unknown"
  },

  "modules": {
    "ddos": "STATE", "portscan": "STATE", "loginmon": "STATE", "geoban": "STATE",
    "feeds": "STATE", "botguard": "STATE", "botscan": "STATE", "suricata": "STATE",
    "rbl": "STATE", "rblmon": "STATE", "tunnel": "STATE", "communication": "STATE",
    "watchdog": "STATE", "metrics": "STATE", "api": "STATE"
  },

  "health": {
    "validator_schema_version": "1.84.0",
    "overall_status": "OK|WARN|DEGRADED|FATAL|UNKNOWN",
    "ok_count": 0, "warn_count": 0, "degraded_count": 0, "fatal_count": 0,
    "daemon_active": "true|false|unknown",
    "nft_table_present": "true|false|unknown",
    "failed_nftban_units_count": 0,
    "last_validate_age_bucket": "live|<1h|<1d|>1d|unknown"
  },

  "communication": {
    "central_comms_available": "true|false|unknown",
    "alert_transport_classes": "none|local|email|webhook|mixed"
  },
  "api_metrics": {
    "api_enabled": "true|false|unknown",
    "api_bind_class": "loopback|private_lan|public_or_all_interfaces|unix_socket|disabled|unknown",
    "metrics_available": "true|false|unknown"
  },
  "rbl": {
    "rbl_enabled": "true|false|unknown",
    "rblmon_enabled": "true|false|unknown",
    "rblmon_watchlist_empty": "true|false|unknown"
  },
  "suricata": {
    "suricata_available": "true|false|unknown",
    "suricata_enabled": "true|false|unknown",
    "eve_source_visible": "true|false|unknown"
  },

  "payload_hash": "<sha256-of-canonical-payload>",
  "last_send_result": "ok|http_<code>|error|none"
}
```

**Module `STATE` values:** `unavailable` (not installed) · `installed_disabled` · `enabled_ok` ·
`enabled_warn` · `enabled_degraded` · `enabled_fatal` · `unknown`.

Every `communication`/`api_metrics`/`rbl`/`suricata` field is a **class or boolean** — never a value:
no recipients, no bind IP/hostname, no listed IPs, no DNSBL results, no EVE events/signatures.

## Receiver contract (implemented by the portal/stats project — `nftbanpro_cms`, NOT this repo)

The receiver at `stats.nftban.com` MUST: accept both `schema_version 2` (legacy, unchanged) and
`schema_version 3`; validate strictly and **reject unknown/forbidden fields**; reject any payload
carrying raw logs/config/event bodies; use source IP only for rate-limiting then **discard/hash it —
never store it as product data**; store the normalized payload only; mark v3 records
`source=community_trial`, `visibility=internal_only`, `public=false`; expose ingestion metrics
(`accepted_count`, `rejected_count`, `schema_version_count`, `last_seen`, `rejection_reason_class`);
carry a retention marker. **This client repo does not implement the receiver or DB.**

## Rollout (gated, not fleet-wide)

Phase 0 dev-only → Phase 1 owner lab/fleet only (no public docs, no auto-enable) → Phase 2 invite-only,
explicit ack, preview-before-send, internal dashboard only. **No fleet-wide enablement without a
separate GO.** No public marketing, no paid-feature/AI/SSO/webhook claims until implemented and real.

## Not in scope of this client

Paid Pro dashboard, portal customer copy, receiver/DB, archive cleanup — all owned elsewhere. This
repo ships only the opt-in client + this contract.
