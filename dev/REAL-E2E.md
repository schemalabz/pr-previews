# Real application preview database verification

Verified on 2026-10-30 with `dev/real-e2e.nix`. The required VM test passed in 246 seconds, excluding builds.

## Run the test

Set these paths to local worktrees and a verified subset release directory:

```bash
export OC_WORKTREE=/path/to/opencouncil
export TASKS_WORKTREE=/path/to/opencouncil-tasks
export SEED_ARTIFACT_DIR=/path/to/seed-release
nix build --impure -f dev/real-e2e.nix -L --no-link
```

The seed directory must contain `manifest.json` and `subset.tar.zst`.
The VM receives both files through its store. It does not need network access to download the seed.

## Verified behavior

- The tasks preview serves HTTP without database declarations.
- OpenCouncil creates its cluster on port `30000 + PR number`.
- The packaged seed command restores the subset, applies migrations, and creates test accounts.
- The running app answers HTTP from its local database.
- Shared and per-preview staging URL overrides cannot replace the generated database URLs.
- Notis gets its own migrated database in the paired cluster.
- Its restricted login can read the admin-session view. PostgreSQL denies access to the `User` table.
- The paired processes receive matching session-cookie settings.
- Notis pages built without database credentials authenticate at runtime instead of caching a build-time login redirect.
- An equivalent closure preserves the database generation and a sentinel table.
- Unsupported data variants fail before replacing existing data.
- A changed seed fingerprint rebuilds OpenCouncil. Notis rebuilds on its next deployment because the owner generation changed.
- Destroy removes the Notis database, stops the owner cluster, and removes the owner preview directory.

The run used release `seed-2026-10-22`. Its subset SHA-256 was:

```text
002a410ee3ae1428a6f1e30f3085de77827d47492211b14ecdd8f196710a5d19
```

## Failures that the checks exposed

The seed restores omit roles and grants. Notis now provisions its restricted reader role and view grants after restoration.
An equivalent closure can contain symlinked migration files. Fingerprints follow those files to preserve unchanged preview data.

A credential-free Notis build could pre-render its protected pages as login redirects. Its session helper now reads request cookies before checking optional database configuration. The real-app test authenticates against the built pages and rejects those cached redirects.

The separate module VM test also verifies concurrent creation, failed initialization, retry, capacity checks, occupied ports, and old-port adoption.
It checks that an incompatible closure preserves the running application. An unresponsive database endpoint cannot stall readiness indefinitely.

The full preview-host build passes with the local application and module inputs.
The application unit suite passed all 545 suites, with four skipped tests. The TypeScript check and local development helper build passed.

A temporary NixOS container on the existing preview droplet also passed public seed download, trusted HTTPS, browser login, paired Notis access, role switching, logout, preservation, rebuilds, teardown, and recreation. The browser run reported no page errors; the 13 existing OpenCouncil previews still returned HTTP 200.

Live GitHub Actions secret routing, Cachix upload, the shared-host cutover, and staging credential removal remain rollout checks.
