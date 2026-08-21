# pr-previews

**Self-hosted per-PR preview environments for NixOS. One module, systemd +
Caddy + your flake. No Docker, no Kubernetes.**

Every pull request gets its own running instance of your app at
`https://pr-N.preview.your.domain`, on your own server:

1. CI builds your app with Nix and pushes the closure to a binary cache.
2. CI SSHes to your server: `sudo myapp-preview-create <PR> <STORE_PATH>`.
3. The server fetches the closure (GC-rooted), starts a systemd instance,
   and drops a Caddy vhost — the preview is live seconds later.
4. On PR close, CI runs `sudo myapp-preview-destroy <PR>` and everything is
   gone: unit, state dir, GC root, vhost.

Anything that can SSH can drive it — GitHub Actions, GitLab CI (Review Apps
`on_stop` maps 1:1 onto create/destroy), Forgejo Actions, or your laptop.

## Quickstart (host side)

```nix
# flake.nix (your server's flake)
{
  inputs.pr-previews.url = "github:schemalabz/pr-previews";

  outputs = { nixpkgs, pr-previews, ... }: {
    nixosConfigurations.myserver = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        pr-previews.nixosModules.default
        {
          services.pr-previews = {
            enable = true;
            projects.myapp = {
              hostPattern = "pr-@id@.preview.example.com";
              basePort = 4000;    # instance port = 4000 + PR number
              # Exec the entrypoint YOUR build produced — the app runs on the
              # toolchain that built it (see "Runtime ownership" below).
              startScript = _: ctx: ''
                exec "$APP_DIR/bin/start"
              '';
            };
          };
        }
        ./configuration.nix
      ];
    };
  };
}
```

That ~12-line project definition generates: a `myapp-preview@` systemd
template unit, `myapp-preview-{create,destroy,list,logs}` commands, per-PR
Caddy vhosts, scoped sudo rules for your CI user, per-instance Nix GC roots,
and a state dir under `/var/lib/myapp-previews/`.

## The `previews` export convention

Keep app-specific preview config in the app's own flake, exported as a
`previews` attrset of one or more projects:

```nix
# your-app/flake.nix outputs
previews.myapp = {
  hostPattern = "pr-@id@.preview.example.com";
  basePort = 4000;
  startScript = _: ctx: ''exec "$APP_DIR/bin/start"'';
};
```

The host then just merges: `projects = myapp.previews // other.previews;`.
Monorepos export several projects from one flake. `nix flake check` warns
about the unknown `previews` output name; that is expected and harmless
(same convention as home-manager's `homeConfigurations` or deploy-rs's
`deploy`).

### Paired services (`siblings`)

When one flake exports multiple projects that must find each other per PR
(e.g. a main app and a satellite service), every script function receives a
`siblings` context with the other projects' values computed for the same PR
number:

```nix
previews.satellite = {
  hostPattern = "satellite-pr-@id@.preview.example.com";
  basePort = 5000;
  startScript = _: ctx: ''
    export MAIN_APP_URL="${ctx.siblings.myapp.url}"
    exec "$APP_DIR/bin/start"
  '';
};
```

## Runtime ownership

**The application must run on the toolchain that built it.** Your app's Nix
build produces an entrypoint (`$out/bin/start` or similar) whose closure
carries the app's own runtime — Node, Python, ffmpeg, whatever it needs —
and the start script simply execs it. Never launch the app through the
`hostPkgs` argument: `''${hostPkgs.nodejs}/bin/node server.js` runs the
**host's** Node against output built by *your* Node, and the two nixpkgs
coincide only by accident. When they drift (you upgrade nixpkgs, the host
does not), previews break with runtime errors that look like the PR's
fault — the worst kind of false signal a preview system can produce.

Done right, this also means per-PR toolchain fidelity: a PR that bumps your
nixpkgs runs its preview on the new toolchain while every other preview
keeps its own — store paths coexist, and each closure carries its runtime.

The `hostPkgs` argument exists for host-side auxiliary tooling in *hooks*
(psql, curl, jq) — things that are not part of the application runtime.

## `ctx` reference

Script functions have signature `hostPkgs: ctx: string` and return a shell
fragment. `ctx` fields are shell expansions valid at that call site:

| Field | startScript | create/destroy hooks | Value |
|---|---|---|---|
| `id` / `prNum` | `$PR_NUM` | `$pr_num` | PR number |
| `port` | `$PORT` | `$port` | basePort + PR |
| `dir` / `prDir` | `$PR_DIR` | `$pr_dir` | instance state dir |
| `appDir` | `$APP_DIR` | — | GC-rooted app symlink |
| `storePath` | — | `$store_path` (create only) | the deployed closure |
| `host` / `url` | hostPattern with the PR number substituted | same | |
| `cfg` | project config (+ shared `user`/`group`); free-form values under `cfg.settings` | same | |
| `siblings.<name>` | `{ port, host, url }` of other projects, same PR | same | |

Optional per-project options: `redirectFrom` (legacy hostname patterns
that 301 to the current one — see "Moving domains"), `envFile` (shared
per-project EnvironmentFile), and hooks: `createHook` (after fetch, before
start — DB provisioning lives here), `destroyHook` (after stop, before
cleanup), `createSummary`, `createExtraArgs` (add flags like `--with-db` to
the create script), `extraConfig` (arbitrary NixOS config, e.g. an auxiliary per-PR
database template unit — may target `systemd`/`environment`/`security`/
`users`/`networking`/`nix`, not `services.*`), `extraPackages`,
`extraSudoCommands`, `settings` (free-form values for your hooks).

The ultimate escape hatch is standard NixOS: override anything on
`systemd.services."<name>-preview@"` from your own config.

## DNS and TLS requirements

- A wildcard DNS record: `*.preview.example.com → your server`.
- Certificates, two options:
  - **Per-hostname (default, zero setup)**: Caddy issues an HTTP-01 cert per
    preview hostname on first request. Works out of the box and is what the
    reference deployment runs. Mind Let's Encrypt's ~50 new certs per
    registered domain per week — fine for typical PR volume, an issue for
    very high churn.
  - **Wildcard (for scale)**: one DNS-01 cert covers unlimited PRs, but
    Caddy needs a [caddy-dns plugin](https://github.com/caddy-dns) for your
    DNS provider.
- Keep `hostPattern` a **single DNS label** under one parent
  (`myapp-pr-@id@.preview.example.com`, never
  `pr-@id@.myapp.preview.example.com`) — it keeps all projects under one
  wildcard DNS record, one cookie parent for paired services, and one
  wildcard cert if you use one.
- Cookie scope: all instances under one parent share that parent's cookie
  scope. That is deliberate for paired services (suffix your cookies per PR);
  use host-only cookies otherwise.

## Moving domains

Set the new `hostPattern` and list the old pattern in `redirectFrom`:

```nix
hostPattern = "pr-@id@.new-domain.example";
redirectFrom = [ "pr-@id@.old-domain.example" ];
```

Every preview then also answers on the legacy hostname with a 301 to the
new one. Existing previews migrate on their next deploy; drop
`redirectFrom` once old links are out of circulation. (301s are reliable
for browsers; API clients that persisted old URLs may mishandle redirected
non-GET requests — they pick up the new URL on their next redeploy.)

## Migrating an existing preview setup

Adopting the module for previews that already exist on a host? Three
continuity rules, learned the hard way:

1. **Keep the user, group, and per-project `previewsDir`** your instances
   already use — existing state dirs and DB clusters must stay owned and
   found.
2. **Pin `homeDir` to the user's original home.** sshd resolves the CI
   deploy key's `~/.ssh/authorized_keys` relative to it; changing the home
   silently breaks CI SSH with "Permission denied (publickey)".
3. Script names, unit names, and Caddy config filenames derive from the
   project name — keep the name and running instances survive the switch
   untouched (units carry `restartIfChanged = false`).

## CI wiring

See `examples/github-actions/` for a complete deploy + cleanup pair
(build → cachix push → SSH create; on close → SSH destroy). The server-side
interface is just the two sudo-whitelisted commands, so any forge works.
Fork-PR safety is your CI's job — read
[docs/trust-model.md](docs/trust-model.md) before enabling previews on a
public repo.

## Docs

- [Trust model](docs/trust-model.md) — what previews may run, secrets policy,
  fork-PR gating.
- [Roadmap](docs/roadmap.md) — idle reaping, reconcile sweep, resource
  limits, per-PR Postgres, and friends.
- Option reference: `nix build .#options-doc`.

## License

MIT.
