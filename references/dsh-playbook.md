# DSH 数据目录迁移手册（执行版）

配套 `SKILL.md`；事实依据 `dsh-facts.md`；工作区搬迁见 `dsh-workspace-move.md`。

## 0. 方案选择

| 方案 | 命令 | 结果 | 适用 |
|---|---|---|---|
| 整目录 + Junction（默认） | `Migrate-DshHome.ps1 -TargetRoot '<新路径>'` | C 盘原路径变链接；DSH 继续用 `%USERPROFILE%\.dsh` | 普通情况；用户级 `DSH_HOME` 未设置或已指向目标 |
| 再加 `DSH_HOME` | `... -SetDshHome` | Junction + 用户级 `DSH_HOME` 都指新路径 | 想彻底摆脱 `~/.dsh` 依赖 |
| 只修 pnpm | `Repair-DshPnpm.ps1 -Execute` | 修 `.modules.yaml` / `pnpm-workspace.yaml` 的 store 记录 | 插件报 `ERR_PNPM_UNEXPECTED_STORE` |

**注意**：如果用户级 `DSH_HOME` 已设置且不等于目标路径，默认方案会被脚本停止（否则 DSH 仍读 `DSH_HOME`，Junction 白建）。此时二选一：加 `-SetDshHome`，或先清掉 `DSH_HOME` 再迁移。

## 1. 铁律

1. 迁移前必须完全退出 DSH（窗口 + 托盘/后台进程）。
2. 目标必须是本地固定盘 + NTFS，空间 ≥ 源 × 1.15，路径尽量短。
3. 不删源、不删退路；删除旧数据是用户在核验通过后的显式动作。
4. `Junction` 不需要管理员；不要改用 `mklink /D`。
5. 不要手工删 pnpm store；只通过 `Repair-DshPnpm.ps1` 改配置。
6. 每个脚本先看清楚再执行；迁移脚本默认支持 `-WhatIf` 演练。

## 2. 标准流程（工具）

```powershell
$scripts = '<本目录>\scripts'
cd $scripts

# 1) 只读核验当前状态（可选，但建议先看）
.\Verify-DshMigration.ps1

# 2) 演练：只打印计划，不改任何文件
.\Migrate-DshHome.ps1 -TargetRoot 'X:\DSHData\.dsh' -WhatIf

# 3) 完全退出 DSH 后正式迁移
.\Migrate-DshHome.ps1 -TargetRoot 'X:\DSHData\.dsh'
#    需要同时切 DSH_HOME：加 -SetDshHome

# 4) 完全重启 DSH，然后核验（退路 vs 目标逐文件）
.\Verify-DshMigration.ps1 -StateFile '<第 3 步输出的 state 文件>' -VerifyBackup
#    发现差异：加 -RepairFromBackup 从退路补齐，再核验一次

# 5) 全部通过、DSH 正常后，及时清理退路
#    如果用了 -SetDshHome，必须同时给 -SourceRoot '<旧数据根>'
.\Migrate-DshHome.ps1 -SourceRoot '<旧数据根>' -TargetRoot 'X:\DSHData\.dsh' -CleanupBackup
```

迁移脚本内部顺序：源/目标检查 → 进程守卫 → NTFS/空间/路径检查 → `robocopy /E /XJ` → 逐文件相对路径+大小比对 → 写 state → 原目录改名 `.dshbak` → `New-Item -ItemType Junction` → 写入探针（经原路径写文件，确认出现在目标盘）→ 可选设 `DSH_HOME` → 可选清退路。

失败处理：
- 复制/校验失败：源目录未动；目标目录保留供检查，删掉它再重试。
- 建 Junction 失败：脚本自动把退路名改回原路径。
- 探针失败：Junction 已建但不通；按输出的 state 文件用回滚脚本处理。

## 3. 核验项（`Verify-DshMigration.ps1`）

1. 数据根存在且可访问。
2. 原路径 / 默认 `~/.dsh` 如果是 Junction，目标指向数据根。
3. 用户级 `DSH_HOME` 与数据根一致（或未设置）。
4. profile 的 `package.json`、`pnpm-workspace.yaml`、`pnpm-lock.yaml` 存在。
5. `.modules.yaml` 的 `storeDir` == DSH 自带 pnpm 的 `store path`。
6. `storages/workspace.json` 可解析，工作区路径可访问。
7. `sessions` 目录有内容。
8. 数据根所在卷是 NTFS，剩余空间合理。
9. DSH 进程提醒（建议重启后再核验）。
10. `-VerifyBackup`：退路 vs 目标逐文件核对；缺失/不一致时用 `-RepairFromBackup` 从退路补齐。
11. `-Deep` 时长路径检查（≤259 或 `LongPathsEnabled=1`）。

没有 FAIL 才算过；WARN 需逐条解释。

## 4. pnpm store 修复

症状：安装/卸载插件报 `ERR_PNPM_UNEXPECTED_STORE` / "different store"。

```powershell
.\Repair-DshPnpm.ps1            # 只检查：显示 modules.yaml 记录、pnpm 当前解析、计划
.\Repair-DshPnpm.ps1 -Execute   # 写入 pnpm-workspace.yaml 顶层 storeDir，留 .bak-时间戳
```

原理：`.modules.yaml` 记录了构建 `node_modules` 的 store；把同一路径写进 `pnpm-workspace.yaml` 的顶层 `storeDir:`，pnpm 就会用回那个 store，**不用重装**。
例外：错误明确说 "different major version of pnpm" 时，`storeDir` 修不好，只能使用对应 pnpm 大版本或重装 profile 依赖。

**不要先删 `node_modules`**：DSH 启动不会自动 `pnpm install`，删了插件会被跳过，要手动 `dsh plugin install` 才能恢复。

## 5. 手动兜底（脚本不可用时）

```powershell
$src = if ($env:DSH_HOME) { $env:DSH_HOME } else { "$env:USERPROFILE\.dsh" }
$dst = 'X:\DSHData\.dsh'
$bak = "$src.dshbak"

# 0) 完全退出 DSH
# 1) 复制（/XJ 必须带）
robocopy $src $dst /E /COPY:DAT /R:1 /W:1 /XJ /NFL /NDL /NJH /NJS /NP
if ($LASTEXITCODE -ge 8) { throw "robocopy 失败：$LASTEXITCODE" }

# 2) 核对文件数 + 总字节（不要只看“复制成功”）
$s = @(Get-ChildItem -LiteralPath $src -Recurse -Force -File -ErrorAction SilentlyContinue)
$d = @(Get-ChildItem -LiteralPath $dst -Recurse -Force -File -ErrorAction SilentlyContinue)
if ($s.Count -ne $d.Count) { throw '文件数不一致' }
if (($s | Measure-Object Length -Sum).Sum -ne ($d | Measure-Object Length -Sum).Sum) { throw '总字节不一致' }

# 3) 改名留退路 + 建 Junction
Rename-Item -LiteralPath $src -NewName (Split-Path $bak -Leaf)
cmd /c mklink /J "$src" "$dst"
Get-Item -LiteralPath $src -Force | Select-Object LinkType, Target

# 4) 可选：用户级 DSH_HOME
[Environment]::SetEnvironmentVariable('DSH_HOME', $dst, 'User')
```

回滚：`cmd /c rmdir <junction>`（只删链接）→ 把 `.dshbak` 改回原名 → 恢复 `DSH_HOME` 旧值。

## 6. 故障排查

| 现象 | 原因 | 处理 |
|---|---|---|
| 迁移脚本说 DSH 在运行 | 托盘/后台进程未退 | 完全退出后重试 |
| 改名探测失败 / 改名退路失败 | 源目录句柄被外部进程占用（资源管理器窗口/终端工作目录；DSH 进程守卫抓不到） | 关闭所有资源管理器窗口与停在源目录的终端后重跑；续作模式会跳过已完成的复制 |
| 目标已存在且非空 | 上次 Cutover 中途失败（正常）或路径填错 | 直接重跑，续作模式会校验源/目标一致后继续；确认路径填错才换空目录 |
| 路径超长 | 目标根太长，`LongPathsEnabled=0` | 用短路径（如 `X:\DSH\.dsh`） |
| 校验失败 | 复制期间 DSH 还在写 / 文件被锁 | 关 DSH 重跑；续作校验不一致时会提示人工核对清理目标 |
| 重启后还是旧数据 | 用户级 `DSH_HOME` 指向别处 | `Verify` 看 `DSH_HOME`；改对或加 `-SetDshHome` |
| 插件全没 | 删过 `node_modules`，DSH 不会自动装 | `Repair-DshPnpm.ps1`；仍缺包则 `dsh plugin install` |
| `ERR_PNPM_UNEXPECTED_STORE` | store 记录与当前 pnpm 解析不一致 | `Repair-DshPnpm.ps1 -Execute` |
| 会话跑到别的工作区/消失 | `workspace.json` 的 `path` 与 session cwd 的真实路径不一致 | 见 `workspace-move.md`；数据没丢 |
| 退路删不掉 | 里面有链接 / 权限 | 先按 `-CleanupBackup` 的安全流程；不要右键递归删除 |
| `mklink /J` 被拒绝 | 目标不是 NTFS / 杀软 / 目标已存在 | 换本地 NTFS；加杀软排除；先处理旧链接 |

## 6b. 合并工作区 / 归组漂移会话（已验证）

场景：数据分叉后出现两个工作区（典型：`DSH_HOME` 误指向空目录，DSH 在新位置自建了全新数据根，见 `dsh-facts.md` §1），或会话 cwd 与注册工作区路径漂移后落入"未分组"。

前提：DSH 完全退出；旧位置若有真实内容，先逐项并入存续数据根（`sessions/` 子目录、`.credentials.yaml`、`.anonymous-user-id`、工作区注册表条目），确认无独有数据后再动路径。

步骤：

1. 编辑存续数据根的 `storages/workspace.json`：删除多余的工作区条目（`global.workspaceIds` + `tables.workspaces` 两处），保留目标工作区。**文件必须按 UTF-8（无 BOM）读写**：PowerShell 5.1 的 `Get-Content` 默认按 ANSI 解码无 BOM 文件，中文标题会变乱码——用 `[System.IO.File]::ReadAllText/WriteAllText` 并显式传 UTF-8 编码。
2. 在被删工作区的旧路径留 Junction，指向存续工作区真实路径：
   `New-Item -ItemType Junction -Path '<旧工作区路径>' -Target '<存续工作区路径>'`（旧路径若还有同名真实目录，确认已并入后删除再建）。
3. 重启 DSH：会话按 `fs.realpath(旧路径) → 存续路径` 自动归组，不需要改任何会话文件（机制见 `dsh-facts.md` §3）。
4. 边界：没有任何已选工作区的空会话（wwd 为空）不会被 Junction 捕获，重启后仍是"未分组"——这类通常是空壳，DSH 关闭时直接删除该会话文件夹即可，注册表残留引用会自愈。

## 7. 工作区目录（可选）

工具只搬 `.dsh` 数据根。如果还要把工作区文件也搬到新盘，按 `workspace-move.md`：复制 → 改 `storages/workspace.json` 的 `path` → 旧父目录留 Junction → 重启核验。不要只 junction 工作区目录而不改注册表。

## 8. 不要做

- 不要在 DSH 运行时迁移。
- 不要 `Remove-Item -Recurse` 删 Junction 或退路。
- 不要只搬 `profiles/` 或 `node_modules/`；搬整个数据根。
- 不要把 `DSH_HOME` 设成父目录（它是精确数据根）。
- 不要把数据根放 OneDrive/网络盘/移动硬盘。
- 不要删 `storages/workspace.json` 来“修”会话。
- 不要在没有核验、没有重启成功前删除退路。
