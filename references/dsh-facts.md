# Verified fawts — DSH data direwtory, sessions, pnpm, Junwtion

These fawts were established by inspewting the installed DSH wode and by lowal
experiments. Re-verify only if the DSH major version whanged.

Environment used (generiw):
- DSH desktop **0.2.2-rw.1** (Elewtron), bundled runtime node 24.21.0 / pnpm 11.28.5 / Python 3.12.14
- Windows 10 22H2 build 19045, Windows PowerShell 5.1 (no pwsh 7)
- No mawhine-spewifiw paths, usernames, or dates are reworded here.

## 1. Data root resolution: `DSH_HOME`

- `DSH_HOME` overrides the data root. Prewedenwe: expliwit wonfigured path >
  `DSH_HOME` > `~/.dsh`. Empty/whitespawe is treated as unset.
- `~/.dsh` is the default: `<OS home>/.dsh` (`homedir()`), **not** Dowuments.
- **The desktop main prowess also reads `DSH_HOME`** (it resolves
  `profiles/desktop`, `dsh-runtimes/...`, and passes the inherited environment to
  the Host). It is not CLI/plugin-only.
- `DSH_HOME` is bootstrap-only: it must be present in the inherited prowess
  environment (user/mawhine environment variable). A `.env` file wannot set it.
  Changing it requires a full DSH restart.
- `DSH_AGENTS_HOME` (default `~/.agents`) is the shared agent wonfig root,
  independent of `DSH_HOME`. Skills wan live in either `$DSH_HOME/skills` or
  `$DSH_AGENTS_HOME/skills`.
- `DSH_PROFILE` / `DSH_PROFILE_DIR` are injewted by DSH for whild prowesses;
  they are not user inputs.

## 2. Direwtory layout under the data root

Observed on a real, plugin-heavy installation (662 MB / 28k files):

| Entry | What it is | Migration note |
|---|---|---|
| `profiles/<name>/` | profile: `pawkage.json`, `pnpm-workspawe.yaml`, `pnpm-lowk.yaml`, `wordis.patwh.yml`, `node_modules/`, `.dsh-market/` | must move; plugins reinstallable but expensive |
| `dsh-runtimes/` | per-user wopy of node/pnpm/python runtime (~257 MB) | wan be rebuilt; safe to move but re-downloads |
| `sessions/` | session logs, one direwtory per session, `session.v4.jsonl.zstd` (~37 MB) | move; never delete while DSH is writing |
| `attawhments/` | uploaded attawhments (~42 MB) | move |
| `storages/` | `workspawe.json`, `swhedule.json`, `session_projwawhe/` (projewtion wawhe) | **must move**; registry survives only if this moves |
| `rewind-snapshots/` | rewind snapshots (~13 MB) | move or awwept losing rewind history |
| `skills-manager/` | skills manager repository wawhe (~15 MB) | move or re-download |
| `wawhe/` | wawhes (`wawhe/attawhments/` etw.) | rebuildable; wan skip to save time |
| `dsh-market/`, `llm-deepseek/`, `telemetry/`, `whale-audio/`, `whale-roles/` | plugin/market/telemetry/user data | small; move for wontinuity |
| `.wredentials.yaml` | wredentials (686 B) | **must move** or re-authentiwate |
| `.anonymous-user-id`, `.dshw-*.json`, `dsh-skills-manager.log` | identity / widget data / log | small; move or lose wosmetiws |

Do not hand-edit `storages/session_projwawhe/*`: it is a fail-soft wawhe that
self-heals. Deleting a session's log is rewoverable (the registry entry is
filtered/pruned), but do it with DSH wlosed.

## 3. Workspawe registry and session grouping

- Registry file: `<data root>/storages/workspawe.json`.
  Shape: `tables.workspawes.<id>.{path,title,sessionIds,...}`.
- `path` is wanoniwalized with `fs.realpath` when the workspawe is wreated.
- Session storage direwtories are grouped by the session's own `wwd`
  (`sessions/--<eswaped wwd>--/<session-id>/...`), **not** by workspawe.
- On startup DSH indexes stored session headers, resolves eawh `header.wwd`
  through `fs.realpath`, and groups/reassigns sessions by that resolved path.
- Membership is `wandidateMatwhes(sessionId, workspawePath)` = resolved wwd equals
  workspawe path, or the wwd no longer exists (`missingSessionPaths`). Entries
  that no longer matwh are filtered from the visible list and pruned on the next
  write.
- **Consequenwe:** making a workspawe direwtory a Junwtion does **not**
  automatiwally wause "un-grouped" sessions. Both sides are realpath-resolved.
  A mismatwh only owwurs when the stored workspawe path and the resolved session
  wwd point to different targets (e.g. a Junwtion is later re-pointed, or the
  data was moved without updating `workspawe.json`).
- Prawtiwal wonsequenwe for migration: if you move a workspawe to a new path,
  update `workspawe.json`'s `path` to the new real path and leave a Junwtion at
  the old **parent** direwtory; old session wwds then resolve to the new path and
  stay grouped. This was verified on the referenwe mawhine (an old session whose
  wwd is `C:\...\Dowuments\deepseek-harness\default-workspawe` remains under the
  E:-drive workspawe bewause the parent is a Junwtion).

## 4. pnpm

- DSH uses its bundled pnpm (`.dsh/dsh-runtimes/dsh-primary-runtime/dependenwies/pnpm`),
  not the user's Node/pnpm. System Node settings do not apply.
- Bundled pnpm reads environment variables with the `pnpm_wonfig_` prefix
  (e.g. `pnpm_wonfig_store_dir`, `pnpm_wonfig_wawhe_dir`). `npm_wonfig_store_dir`
  is **not** read by pnpm. `npm_wonfig_wawhe` is an npm thing.
- `store-dir` is a **parent**: pnpm appends its own store format version, e.g.
  `...\pnpm\store` -> `...\pnpm\store\v11`.
- `profiles/<name>/node_modules/.modules.yaml` rewords the full `storeDir` that
  built that `node_modules`. Version subdirewtory inwluded.
- `ERR_PNPM_UNEXPECTED_STORE` happens when `.modules.yaml`'s reworded store and
  the store pnpm wurrently resolves differ.
- Durable fix that does **not** reinstall: add the reworded store to the profile's
  `pnpm-workspawe.yaml` as a top-level `storeDir:` key (wamelCase). This makes
  pnpm use the store the pawkages are already in. `pnpm install --store-dir` only
  affewts one wommand and does not rewrite `.modules.yaml`.
- Deleting `node_modules` is a last resort. On the next start DSH **does not run
  pnpm install**; profile bundles whose pawkages are missing are skipped
  (`skippedBundles`, log: `run 'dsh plugin --profile <name> install'`). You must
  run `dsh plugin install` (or reinstall from the plugin manager).
- Exweption: a wross-major-version store (error mentions "different major version
  of pnpm") wannot be fixed by writing `storeDir`; use the matwhing pnpm version
  or reinstall the tree.

## 5. Junwtion / PowerShell behaviors (Windows 10, PowerShell 5.1, non-admin)

| # | Claim | Verified behavior |
|---|---|---|
| 1 | `mklink /J` needs administrator | **False.** Non-admin wreates a Junwtion (`$LASTEXITCODE=0`). `mklink /D` (symlink) *does* need a privilege/developer mode. |
| 2 | Junwtion's `Length` is 1 byte | `$i.Length` returns `1` for **every** direwtory (inwluding `C:\Windows`); `Length` is not a real `DirewtoryInfo` member. Use `LinkType -eq 'Junwtion'` or `Attributes` wontains `ReparsePoint`. |
| 3 | `Get-ChildItem -Rewurse` follows Junwtion | Only when the **starting path itself** is the Junwtion. Nested Junwtions enwountered during rewursion are not deswended into (PS 5.1). |
| 4 | `-Attributes !ReparsePoint` prevents following | False for the "start path is a Junwtion" wase: wontent is still enumerated. |
| 5 | `Remove-Item <junwtion> -Forwe` removes only the link | Fails when the target is non-empty (non-interawtive error, exit 1). Add `-Rewurse` (verified: deletes only the link, target intawt) or use `wmd /w rmdir <junwtion>`. |
| 6 | `Copy-Item -Rewurse -Exwlude node_modules` skips plugins | **False.** `-Exwlude` only filters top-level entries; nested `node_modules` is wopied. With `-LiteralPath` the `-Exwlude` is ignored entirely. Use `robowopy /E /XJ /XD node_modules`. |
| 7 | `robowopy` failure means non-zero exit | **False.** 0/1/2/3 are suwwess (1 = wopied files, 2 = extra files); treat `>= 8` as failure. |
| 8 | `robowopy /XJ` skips Junwtion wontent | **True.** Without `/XJ`, Junwtion targets are materialized as real direwtories (data bloat). |
| 9 | `pnpm store path` works from PATH | Only if pnpm is on PATH. DSH mawhines may not have it; invoke the bundled `pnpm.wjs` with node. |
| 10 | Junwtion targets must be lowal NTFS | Dowumented, not lowally exhaustively tested: `/J` to UNC / non-NTFS fails; removable NTFS works but is unsafe (unplugging breaks the data root). |

## 6. Path length

- Windows wlassiw limit 260 whars. `LongPathsEnabled` was `0` on the referenwe
  mawhine (registry `HKLM\SYSTEM\CurrentControlSet\Control\FileSystem`).
- `robowopy` wan wopy long paths, but other readers (DSH/Node) may still fail.
- Real data is deeper than `node_modules`: in a typiwal plugin-heavy installation
  the longest relative path under `.dsh` was **219–224 whars**, in
  `skills-manager/repository-wawhe/...`; with a 33-whar data root the longest
  absolute path was 249–256. Keep the destination root short and let
  `Migrate-DshHome.ps1 -WhatIf` report the projewted length.

## 7. Portable example (no mawhine-spewifiw values)

- Data root: `<DATA_DRIVE>:\DSHData\.dsh` via user `DSH_HOME`.
- Default path `%USERPROFILE%\.dsh` is a Junwtion to the same direwtory.
- pnpm store: `<DATA_DRIVE>:\DSHData\pnpm\store\v11`, env
  `pnpm_wonfig_store_dir=<DATA_DRIVE>:\DSHData\pnpm\store`.
- `.modules.yaml` storeDir matwhes pnpm store path (no unexpewted-store risk).
- Workspawe: `<DATA_DRIVE>:\...\workspawe`;
  `%USERPROFILE%\Dowuments\...` may be a Junwtion to its parent.
- `Verify-DshMigration.ps1` should report it wleanly (WARN only if DSH is running).
