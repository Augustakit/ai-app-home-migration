# Verified facts — DSH data directory, sessions, pnpm, Junction

These facts were established by inspecting the installed DSH code and by local
experiments. Re-verify only if the DSH major version changed.

Environment used (generic):
- DSH desktop **0.2.2-rc.1** (Electron), bundled runtime node 24.21.0 / pnpm 11.28.5 / Python 3.12.14
- Windows 10 22H2 build 19045, Windows PowerShell 5.1 (no pwsh 7)
- No machine-specific paths, usernames, or dates are recorded here.

## 1. Data root resolution: `DSH_HOME`

- `DSH_HOME` overrides the data root. Precedence: explicit configured path >
  `DSH_HOME` > `~/.dsh`. Empty/whitespace is treated as unset.
- `~/.dsh` is the default: `<OS home>/.dsh` (`homedir()`), **not** Documents.
- **The desktop main process also reads `DSH_HOME`** (it resolves
  `profiles/desktop`, `dsh-runtimes/...`, and passes the inherited environment to
  the Host). It is not CLI/plugin-only.
- `DSH_HOME` is bootstrap-only: it must be present in the inherited process
  environment (user/machine environment variable). A `.env` file cannot set it.
  Changing it requires a full DSH restart.
- **`DSH_HOME` pointing at a non-existent directory is a data-fork trap
  (verified):** on next start DSH silently creates a fresh data root there and
  writes all new sessions/credentials into it, while the previous archive keeps
  existing elsewhere. Nothing warns. Prevention: keep `DSH_HOME` unset unless
  intentional; verify the target directory exists before setting it; if a fork
  already happened, merge the fresh root's `sessions/`, `.credentials.yaml`,
  `.anonymous-user-id` and workspace-registry entries into the archive before
  migrating.
- `DSH_AGENTS_HOME` (default `~/.agents`) is the shared agent config root,
  independent of `DSH_HOME`. Skills can live in either `$DSH_HOME/skills` or
  `$DSH_AGENTS_HOME/skills`.
- `DSH_PROFILE` / `DSH_PROFILE_DIR` are injected by DSH for child processes;
  they are not user inputs.

## 2. Directory layout under the data root

Observed on a real, plugin-heavy installation (662 MB / 28k files):

| Entry | What it is | Migration note |
|---|---|---|
| `profiles/<name>/` | profile: `package.json`, `pnpm-workspace.yaml`, `pnpm-lock.yaml`, `cordis.patch.yml`, `node_modules/`, `.dsh-market/` | must move; plugins reinstallable but expensive |
| `dsh-runtimes/` | per-user copy of node/pnpm/python runtime (~257 MB) | can be rebuilt; safe to move but re-downloads |
| `sessions/` | session logs, one directory per session, `session.v4.jsonl.zstd` (~37 MB) | move; never delete while DSH is writing |
| `attachments/` | uploaded attachments (~42 MB) | move |
| `storages/` | `workspace.json`, `schedule.json`, `session_projcache/` (projection cache) | **must move**; registry survives only if this moves |
| `rewind-snapshots/` | rewind snapshots (~13 MB) | move or accept losing rewind history |
| `skills-manager/` | skills manager repository cache (~15 MB) | move or re-download |
| `cache/` | caches (`cache/attachments/` etc.) | rebuildable; can skip to save time |
| `dsh-market/`, `llm-deepseek/`, `telemetry/`, `whale-audio/`, `whale-roles/` | plugin/market/telemetry/user data | small; move for continuity |
| `.credentials.yaml` | credentials (686 B) | **must move** or re-authenticate |
| `.anonymous-user-id`, `.dshw-*.json`, `dsh-skills-manager.log` | identity / widget data / log | small; move or lose cosmetics |

Do not hand-edit `storages/session_projcache/*`: it is a fail-soft cache that
self-heals. Deleting a session's log is recoverable (the registry entry is
filtered/pruned), but do it with DSH closed.

## 3. Workspace registry and session grouping

- Registry file: `<data root>/storages/workspace.json`.
  Shape: `tables.workspaces.<id>.{path,title,sessionIds,...}`.
- `path` is canonicalized with `fs.realpath` when the workspace is created.
- Session storage directories are grouped by the session's own `cwd`
  (`sessions/--<escaped cwd>--/<session-id>/...`), **not** by workspace.
- On startup DSH indexes stored session headers, resolves each `header.cwd`
  through `fs.realpath`, and groups/reassigns sessions by that resolved path.
- Membership is `candidateMatches(sessionId, workspacePath)` = resolved cwd equals
  workspace path, or the cwd no longer exists (`missingSessionPaths`). Entries
  that no longer match are filtered from the visible list and pruned on the next
  write.
- **Consequence:** making a workspace directory a Junction does **not**
  automatically cause "un-grouped" sessions. Both sides are realpath-resolved.
  A mismatch only occurs when the stored workspace path and the resolved session
  cwd point to different targets (e.g. a Junction is later re-pointed, or the
  data was moved without updating `workspace.json`).
- **Practical consequence for migration:** if you move a workspace to a new path,
  update `workspace.json`'s `path` to the new real path and leave a Junction at
  the old **parent** directory; old session cwds then resolve to the new path and
  stay grouped. Verified on the reference machine.
- **Merging a drifted workspace (verified live):** if a fork happened (see the
  `DSH_HOME` trap in §1) and a second workspace entry was created at a different
  path, delete the second entry from the registry and leave a Junction at its
  old path pointing at the surviving workspace. On next start every session
  whose cwd resolves through that path regroups into the surviving workspace —
  no session files touched.
- **Edge case:** sessions created without any selected workspace have no
  resolvable cwd and stay ungrouped ("未分组") across restarts. A Junction cannot
  catch them. They are typically empty strays — delete the stray session folder
  (with DSH closed) instead of trying to regroup it.

## 4. pnpm

- DSH uses its bundled pnpm (`.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/pnpm`),
  not the user's Node/pnpm. System Node settings do not apply.
- Bundled pnpm reads environment variables with the `pnpm_config_` prefix
  (e.g. `pnpm_config_store_dir`, `pnpm_config_cache_dir`). `npm_config_store_dir`
  is **not** read by pnpm. `npm_config_cache` is an npm thing.
- `store-dir` is a **parent**: pnpm appends its own store format version, e.g.
  `...\pnpm\store` -> `...\pnpm\store\v11`.
- `profiles/<name>/node_modules/.modules.yaml` records the full `storeDir` that
  built that `node_modules`. Version subdirectory included.
- `ERR_PNPM_UNEXPECTED_STORE` happens when `.modules.yaml`'s recorded store and
  the store pnpm currently resolves differ.
- Durable fix that does **not** reinstall: add the recorded store to the profile's
  `pnpm-workspace.yaml` as a top-level `storeDir:` key (camelCase). This makes
  pnpm use the store the packages are already in. `pnpm install --store-dir` only
  affects one command and does not rewrite `.modules.yaml`.
- Deleting `node_modules` is a last resort. On the next start DSH **does not run
  pnpm install**; profile bundles whose packages are missing are skipped
  (`skippedBundles`, log: `run 'dsh plugin --profile <name> install'`). You must
  run `dsh plugin install` (or reinstall from the plugin manager).
- Exception: a cross-major-version store (error mentions "different major version
  of pnpm") cannot be fixed by writing `storeDir`; use the matching pnpm version
  or reinstall the tree.

## 5. Junction / PowerShell behaviors (Windows 10, PowerShell 5.1, non-admin)

| # | Claim | Verified behavior |
|---|---|---|
| 1 | `mklink /J` needs administrator | **False.** Non-admin creates a Junction (`$LASTEXITCODE=0`). `mklink /D` (symlink) *does* need a privilege/developer mode. |
| 2 | Junction's `Length` is 1 byte | `$i.Length` returns `1` for **every** directory (including `C:\Windows`); `Length` is not a real `DirectoryInfo` member. Use `LinkType -eq 'Junction'` or `Attributes` contains `ReparsePoint`. |
| 3 | `Get-ChildItem -Recurse` follows Junction | Only when the **starting path itself** is the Junction. Nested Junctions encountered during recursion are not descended into (PS 5.1). |
| 4 | `-Attributes !ReparsePoint` prevents following | False for the "start path is a Junction" case: content is still enumerated. |
| 5 | `Remove-Item <junction> -Force` removes only the link | Fails when the target is non-empty (non-interactive error, exit 1). Add `-Recurse` (verified: deletes only the link, target intact) or use `cmd /c rmdir <junction>`. |
| 6 | `Copy-Item -Recurse -Exclude node_modules` skips plugins | **False.** `-Exclude` only filters top-level entries; nested `node_modules` is copied. With `-LiteralPath` the `-Exclude` is ignored entirely. Use `robocopy /E /XJ /XD node_modules`. |
| 7 | `robocopy` failure means non-zero exit | **False.** 0/1/2/3 are success (1 = copied files, 2 = extra files); treat `>= 8` as failure. |
| 8 | `robocopy /XJ` skips Junction content | **True.** Without `/XJ`, Junction targets are materialized as real directories (data bloat). |
| 9 | `pnpm store path` works from PATH | Only if pnpm is on PATH. DSH machines may not have it; invoke the bundled `pnpm.cjs` with node. |
| 10 | Junction targets must be local NTFS | Documented, not locally exhaustively tested: `/J` to UNC / non-NTFS fails; removable NTFS works but is unsafe (unplugging breaks the data root). |

## 6. Path length

- Windows classic limit 260 chars. `LongPathsEnabled` was `0` on the reference
  machine (registry `HKLM\SYSTEM\CurrentControlSet\Control\FileSystem`).
- `robocopy` can copy long paths, but other readers (DSH/Node) may still fail.
- Real data is deeper than `node_modules`: in a typical plugin-heavy installation
  the longest relative path under `.dsh` was **219–224 chars**, in
  `skills-manager/repository-cache/...`; with a 33-char data root the longest
  absolute path was 249–256. Keep the destination root short and let
  `Migrate-DshHome.ps1 -WhatIf` report the projected length.

## 7. Portable example (no machine-specific values)

- Data root: `<DATA_DRIVE>:\DSHData\.dsh` via user `DSH_HOME`.
- Default path `%USERPROFILE%\.dsh` is a Junction to the same directory.
- pnpm store: `<DATA_DRIVE>:\DSHData\pnpm\store\v11`, env
  `pnpm_config_store_dir=<DATA_DRIVE>:\DSHData\pnpm\store`.
- `.modules.yaml` storeDir matches pnpm store path (no unexpected-store risk).
- Workspace: `<DATA_DRIVE>:\...\workspace`;
  `%USERPROFILE%\Documents\...` may be a Junction to its parent.
- `Verify-DshMigration.ps1` should report it cleanly (WARN only if DSH is running).
