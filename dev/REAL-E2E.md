# Real-app e2e results — 2026-08-19 (overnight run)

Harness: `dev/real-e2e.nix` (impure VM test; real `previews` exports from the
converted app worktrees; real prod closures; dummy secrets).

## REQUIRED gate: opencouncil-tasks — PASS (6.1s)

- `opencouncil-tasks-preview-create 7 /nix/store/…-opencouncil-tasks-prod-1.0.0`
- `opencouncil-tasks-preview@4007` active; HTTP response on :4007
- Caddy vhost `/etc/caddy/conf.d/opencouncil-tasks-pr-7.conf` written
- GC root verified via `nix-store --query --roots … | grep pr-7`
- destroy: unit gone, vhost gone

Finding folded back into the harness: the tasks app **requires `API_TOKENS`**
(JSON array) at boot — first run crash-looped without it (exactly 20 restarts,
`Restart=on-failure` behaving as designed). Real deployments get it from the
shared envFile; any future synthetic env needs it too.

## BEST-EFFORT: opencouncil `--with-db` — FULL PASS, outcome `app-responds` (17.9s)

Every stage of the real DB flow ran:
1. `opencouncil-preview-db@9` — isolated Postgres cluster (initdb, port 5441)
2. `CREATE EXTENSION postgis`
3. `prisma migrate deploy` — **112 real migrations applied**
4. Seed loaded (43MB `seed_data.json` pre-placed; hook's download-skip path)
5. `opencouncil-preview@3009` active; Next.js boots with dummy secrets and
   serves — cache-warming queries (`MISS [cities:public:greece]` …) executing
   against the isolated DB

No env-validation blocker: `SKIP_ENV_VALIDATION=1` + dummies
(`NEXTAUTH_SECRET`, `ANTHROPIC_API_KEY`, `API_TOKENS`) suffice.

## Verdict

The full real stack — new module + converted app exports + real closures —
works end to end in a clean VM, including the hardest path (per-PR DB with
migrations and seed). Remaining untested surface: real DNS/TLS/CI, i.e. the
live canary (plan Task 12.7).
