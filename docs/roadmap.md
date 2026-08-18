# Roadmap

v1 is deliberately minimal: parity with the battle-tested OpenCouncil
preview infrastructure, plus GC roots. These are the planned directions,
each small enough to land independently. The interface invariants
(deterministic `<project>` + `<id>` naming, policy-in-CI/mechanics-in-module,
substrate-agnostic `startScript`) are what keep them cheap.

## Idle reaping (TTL)

Stop instances that received no traffic for N hours; PR-close teardown stays
the fast path, the reaper is the backstop. garnix ran previews with a 12h
traffic-aware TTL as the *only* reaper; on a RAM-bound single host you want
both. Mechanism: a timer reads Caddy access logs per vhost and stops idle
instances. A stopped preview 404s until redeployed.

## Wake-on-request (socket activation)

The fancier alternative to reaping: systemd socket activation per instance —
the port keeps listening while the app is stopped, and the next request
transparently boots it. Slower first hit, but preview URLs never die. Fits
the template-unit architecture naturally.

## Reconcile sweep

Event-driven teardown alone misses closures (GitHub's `closed` event can
silently not fire for merge-conflicted PRs). A periodic job diffs open PRs
(forge API) against running instances and destroys the difference —
reconcile-to-plan, the shape garnix's deploy planner used. Deterministic
naming makes this a pure sweep.

## Resource limits

`MemoryMax`/`MemoryHigh`/`CPUQuota`/`TasksMax` options per project, applied
to the template unit. Host-level OOM from unlimited previews is the classic
single-host failure; cgroup v2 makes the fix one option away.

## First-class per-PR Postgres

Promote the proven `createHook`-based pattern (isolated cluster per PR,
migrations + seed on create) into typed module options, including
N-databases-per-cluster for paired services. Worth noting for self-hosters:
PostgreSQL 18's `file_copy_method = clone` on a reflink filesystem makes
template-database clones near-instant.

## Fork-safe secrets typing

A first-class distinction between env entries that are safe on any preview
and entries withheld unless the PR is trusted — today this is policy in the
trust model doc; it could be mechanism.

## Persistence-name keyed state

Opt-in `persistence` name per project (garnix's idea): instances with the
same persistence key reuse a state dir across re-creations, so seeded data
survives redeploys. Default stays throwaway-per-PR.

## Watchdog canary

A tiny end-to-end health check: push a dated commit to a fixture repo, wait
for its preview to serve that date, alert otherwise. Proves the whole
pipeline (CI → cache → SSH → create → route) continuously.

## Stronger isolation substrates

Per-preview systemd-nspawn containers (via extra-container) or microvm.nix
microVMs as alternative execution backends behind the same project
interface — required before running genuinely untrusted code.
