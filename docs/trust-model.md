# Trust model

Read this before enabling previews on a repository that accepts outside
contributions.

## What a preview is, security-wise

A preview executes **unmerged code** as a shared system user on a shared
host. All previews of all projects run as the same user (`services.
pr-previews.user`), on the same kernel, behind the same Caddy. There is no
container or VM boundary between previews, and no boundary between a preview
and the state dirs of its neighbors beyond ordinary file permissions.

The module's job is mechanics; **trust decisions live in your CI**. The
server-side attack surface is deliberately small — the CI user's sudo
whitelist is exactly `<name>-preview-create`, `<name>-preview-destroy`, and
scoped `systemctl` verbs on the project's own template unit — but whatever
code the created instance runs, runs.

## Rules

1. **Never auto-deploy fork PRs.** Gate preview creation on the PR author
   being a trusted contributor, or on an explicit label applied by a
   maintainer. If you use `pull_request_target` for secrets access, follow
   GitHub's guidance: never check out the fork head in the privileged
   workflow without an explicit gate, and deploy the exact SHA the gate
   approved (a label race lets an attacker push after approval). The
   reference implementation is opencouncil's author-gated deploy workflow
   (author allowlist + fork-checkout opt-in).
   Fork checks alone also miss **machine-authored same-repo PRs**: Dependabot
   (and similar bots) push branches to the repository itself, so a
   `head.repo == repository` guard passes and a dependency-bump PR gets built
   with secrets access — a supply-chain exposure with zero preview value.
   Exclude bot actors explicitly (see `examples/github-actions/`).
2. **Preview env files contain preview-grade secrets only.** The per-project
   `envFile` is readable by every instance of that project — including a
   preview of a malicious PR if your gating fails. Use dummy API keys
   (most apps boot fine and only fail on actual use — that is acceptable for
   testing UI, auth flows, and admin panels), staging credentials at worst,
   production credentials never.
3. **Databases:** previews sharing a staging database can read and corrupt
   each other's data by construction. For isolation, provision a per-PR
   database in a `createHook` (see the opencouncil `--with-db` pattern) and
   tear it down in `destroyHook`.
4. **The web surface is public.** Anything a preview serves is reachable by
   anyone who can guess `pr-N.preview.your.domain` (DNS is a wildcard, so
   enumeration is trivial). Do not put previews of non-public code on a
   public wildcard without an auth layer in front.

## Stronger isolation

If you need to run genuinely untrusted code, a shared-user host is the wrong
tier — you want per-preview containers (systemd-nspawn) or microVMs. The
config interface here is substrate-agnostic on purpose (`startScript` says
how to run the app given a store path, not what supervises it), so a
container/VM execution backend can land without breaking consumers. See the
[roadmap](roadmap.md).
