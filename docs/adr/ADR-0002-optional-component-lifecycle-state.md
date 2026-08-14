# ADR-0002 — Optional Component Lifecycle State

- **Status:** Accepted
- **Date:** 2026-08-14
- **Scope:** daemon components that may legitimately not exist at runtime, starting with the HTTP API
- **Relates to:** ADR-0001 (Runtime Mode Authority) — this is the same rule applied to component existence
  rather than to mode names

## Context

The HTTP API is optional by design. When another service already owns the configured port — Apache,
DirectAdmin, cPanel or nginx on a shared host — `startHTTP` deliberately continues and the daemon serves IPC
only. That intent was carried by a single implicit signal: `httpSrv == nil`.

Two consumers read that signal differently, and both were wrong.

**Shutdown** dereferenced it. `gracefulShutdown` called `httpSrv.Shutdown()` without a guard, so on those
hosts SIGTERM panicked on a nil receiver. It runs on the `handleSignals` goroutine, and the only `recover()`
is deferred in the goroutine that spawned it, which cannot catch a panic raised on another stack. The process
died and every remaining step was skipped — module `StopAll`, the OpQueue drain, the SourceIndex save, the
event-bus close, the final cache flush, `completeShutdown`, and PID-file removal — all after `STOPPING=1` had
already been sent to systemd. A lab witness recorded `Result=exit-code`, the unit in **failed** state,
`OnFailure=` dependencies triggered, and a stale PID file. Every shutdown on such a host took that path,
including package upgrades and reboots.

**Startup** asserted readiness regardless. `setHTTPReady(true)` ran unconditionally while `http_ready` sat in
the mandatory readiness tier, so systemd was told a mandatory prerequisite was satisfied by a component that
had never been created.

A third defect shared the same root. Every `net.Listen` error took the "API disabled" path, so a genuine
fault — a bind address that does not exist on the host, or a privileged port — produced a daemon that
reported itself healthy with its API merely switched off.

An audit of every conditionally-created component with a terminator found this to be the **only** such
deviation: `socketLn`, `opQueue` and `sourceIndex` were already nil-guarded in the same function, the
remaining fields are unconditionally constructed, and all four registered modules guard their optional fields
in `Stop()`. `httpSrv` escaped the convention because it is a bare `Daemon` field rather than a registry
module.

## Decision

**The state of an optional component is explicit and authoritative. It is never inferred from a pointer, and
it is represented consistently across startup, readiness, runtime reporting and shutdown.**

For the HTTP API the states are mutually exclusive:

| state | condition | readiness | shutdown |
|---|---|---|---|
| **Running** | listener established | `http_ready` mandatory and satisfied | terminator runs |
| **DisabledByDesign** | `errors.Is(err, syscall.EADDRINUSE)` | **degraded** tier — `READY=1` still sent | terminator skipped |
| **Failed** | any other bind/init error | never reached — `startHTTP` returns the error and startup fails | — |
| **Unknown** | zero value, not yet classified | can never satisfy readiness | — |

Three consequences of that table are load-bearing:

1. **Disabled-by-design belongs to the degraded tier, not the mandatory one.** `nft`, `opqueue` and
   `watchdog` already live there. Reporting `http_ready=false` while leaving it mandatory would be the
   opposite defect: an intentional port collision would become a fatal startup failure.
2. **Classification is by errno, not by message text**, through the wrapped error chain. The default arm is
   the failing one, so an errno we have not seen yet fails loudly rather than being silently tolerated.
3. **`Unknown` is retained as the zero value.** An incompletely initialised daemon must never be
   indistinguishable from a validly degraded one.

The state is also **operator-visible**. `http_ready=false` alone cannot distinguish "disabled on purpose"
from "startup is unhealthy", so status exposes `http_disabled_by_design` alongside it, and `nftban status`
renders the distinction in words.

## Consequences

`http_ready` now reports `false` on hosts where the API port is owned by another service. That is a
**semantic change to a published status field**: previously it was `true` on those hosts because startup
asserted it unconditionally. No shipped monitoring surface, health probe or document in this repository
consumes `http_ready`, so nothing required coordinated change — but any external check asserting
`http_ready == true` must be updated to accept `http_disabled_by_design == true` as healthy.

This ADR does not move `httpSrv` into the module registry. The audit showed the existing guard convention is
sufficient for the proven defect, and a registry migration would be redesign beyond it. A future component
with the same shape should either join the registry contract (`internal/module`) or mirror this convention
explicitly.

## Enforcement

Three behaviour arms — running, disabled-by-design, genuine failure — each verified by re-introducing the
defect: removing the shutdown guard, restoring the unconditional readiness assertion, and widening the
classifier to tolerate every bind error must each fail the suite. The classifier is a pure function so that
last inversion has something to fail against; an inline decision inside `startHTTP` could not be driven from
a test, and a semantic mutation of it passed until the arm existed.
