# Parity report — April `generic-preview.nix` vs `services.pr-previews`

Built 2026-08-19 via `dev/parity.nix` (one opencouncil-shaped project, both
modules, same nixpkgs `50ab793` = the production server's rev). Store hashes
normalized before diffing. Verdict: **full parity — every hunk is on the
intended-differences list; nothing unexplained.**

## Verified identical

- Script names: `opencouncil-preview-{create,destroy,list,logs}` in systemPackages.
- Template unit name `opencouncil-preview@.service`; instance key = PORT.
- `User=opencouncil`, `Environment=NODE_ENV=production IS_PREVIEW=true PORT=%i`,
  `Restart=on-failure`, `RestartSec=5s`, hardening keys (NoNewPrivileges,
  PrivateTmp, ProtectHome, ReadWritePaths).
- previews dir `/var/lib/opencouncil-previews/pr-N` with `app` symlink.
- Caddy config file `/etc/caddy/conf.d/opencouncil-pr-$pr_num.conf`; legacy
  cleanup of `pr-N.conf` / `tasks-pr-N.conf`; identical vhost body and reload flow.
- Sudo rules: identical 8-command set (systemctl start/stop/enable/disable/
  status on `opencouncil-preview@*`, reload caddy, create/destroy via
  /run/current-system/sw/bin).
- All user-facing output text of create/destroy/list/logs.
- Shell variable names exposed to app fragments: `pr_num/pr_dir/store_path/port`
  (create/destroy), `PORT/PR_NUM/PR_DIR/APP_DIR` (start).

## Intended differences (allowed list)

1. **create**: `ln -sfn` + conditional realise → unconditional
   `nix-store --realise "$store_path" --add-root "$pr_dir/app" --indirect`
   (the GC-root fix; realise is a no-op when the path is local).
2. **All scripts**: `writeShellApplication` preamble — `set -o errexit/nounset/
   pipefail` + explicit PATH export — replaces bare `set -euo pipefail`.
   Shellcheck now runs at build time.
3. **Unit additions**: `SyslogIdentifier=opencouncil-preview@%i`,
   `X-RestartIfChanged=false` (running instances no longer bounce on rebuild),
   ExecStart path shape `.../bin/opencouncil-preview-start` (package layout,
   same behavior).
4. **Hostname rendering**: `pr-${pr_num}.domain` vs `pr-$pr_num.domain` —
   byte-different, shell-identical (hostPattern substitution).
5. Comment punctuation in two comments.

## Not covered by this harness

Hooks/createExtraArgs/extraConfig parity is exercised by the real opencouncil
conversion (Task 10) + `make dry-run` (Task 12), since those fragments are
app-supplied and identical by construction (same strings, new call sites).
