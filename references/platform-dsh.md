# 平台：DSH（DeepSeek Harness）

## 识别特征

- 进程：`DeepSeek Harness.exe`
- 数据根：`%USERPROFILE%\.dsh`，可被用户级 `DSH_HOME` 覆盖（优先）
- 默认路径通常是 Junction，指向 `DSH_HOME`
- 环境变量 `DSH_DESKTOP_NODE_EXECUTABLE` 存在时，说明当前进程在 DSH 宿主环境里

## 数据根与机制（关键）

- `DSH_HOME` 优先级：显式配置 > `DSH_HOME` > `~/.dsh`；空白视为未设置。
- 当前 DSH 桌面主进程、Host、CLI、插件**都读** `DSH_HOME`；改完必须完全重启 DSH。
- 迁移有两种落点：
  - **默认**：整目录复制 + 原路径 Junction。DSH 继续按 `%USERPROFILE%\.dsh` 读；用户级 `DSH_HOME` 不能被指到别处（脚本会拦）。
  - **`-SetDshHome`**：同时把用户级 `DSH_HOME` 指到目标目录。适合想彻底不依赖 `~/.dsh` 的环境。
- 若用户级 `DSH_HOME` 已指向目标路径，脚本视为一致；指向第三处时会停止，要求先处理，避免“搬了但 DSH 没用上”。

## 执行入口

```powershell
$s = '<SKILL_DIR>\scripts\dsh'
& "$s\Verify-DshMigration.ps1"                                   # 只读核验现状
& "$s\Migrate-DshHome.ps1" -TargetRoot '<TARGET_ROOT>' -WhatIf    # 演练
& "$s\Migrate-DshHome.ps1" -TargetRoot '<TARGET_ROOT>'            # 正式迁移（先退出 DSH）
& "$s\Verify-DshMigration.ps1" -StateFile '<STATE_FILE>' -VerifyBackup
#    发现差异：加 -RepairFromBackup 补，再核验
& "$s\Migrate-DshHome.ps1" -SourceRoot '<OLD_DATA_ROOT>' -TargetRoot '<TARGET_ROOT>' -CleanupBackup  # 确认后清退路
```

> 如果迁移时用了 `-SetDshHome`，清理退路要同时给 `-SourceRoot '<旧数据根>'`；否则脚本默认从当前 `DSH_HOME`（新目标）找源，找不到旧退路。

另可双击 `scripts\dsh\Run-Wizard.bat` 走中文菜单。

## 默认范围：整个 `.dsh`

默认迁移整个数据根（`DSH_HOME` / `%USERPROFILE%\.dsh`），**不默认只迁 `profiles`、`sessions` 或某个文件**。只迁子目录会让根目录仍是真目录，以后新增内容继续落在 C 盘。确实只迁部分时必须由用户明确要求，并在报告里写清“根目录仍占原盘、以后新增内容仍回原盘”的代价。

## 一次只迁一个平台

用户要求同时迁 DSH 和其它平台时拒绝：先完成 DSH、逐文件核验通过，再做下一个。

## 备份与补文件（默认流程）

1. 迁移脚本默认保留退路（`<源>.dshbak`），不删除。
2. 迁移后逐文件核对：用**退路本体**与目标比对（相对路径 + 大小）；`Verify-DshMigration.ps1 -VerifyBackup` 会做这项检查。
3. 发现缺失/大小不一致：先按提示从退路补到目标（`-RepairFromBackup`），再重新核验。
4. 全部通过、用户确认 DSH 正常后，**及时清理退路**：`Migrate-DshHome.ps1 -TargetRoot '<TARGET_ROOT>' -CleanupBackup`（有覆盖闸门）。不要长期保留占空间。
5. 核验/清理过程中不要把真实用户名、路径、会话内容写进报告；用 `displayRoot`。

## 关键约束

- **如果 Agent 跑在 DSH 里**：不能自己关闭宿主再执行 Cutover。Agent 可以完成 Discover/Prepare/Verify 的准备与说明，**最后一步必须由用户在 DSH 外双击向导或在外部终端执行**。不要尝试杀 DSH 进程。
- 目标必须是本地 NTFS、非盘根、不在源树内、空间 ≥ 源 × 1.15、路径尽量短（脚本会检查）。
- **源树内部 reparse point 必须为 0**：脚本会先扫描；非零会停，因为 `/XJ` 会跳过它们导致缺数据。
- **迁移前关闭所有资源管理器窗口与停在源/目标目录里的终端**：目录句柄被外部进程占用时，改名退路必然失败（DSH 进程守卫抓不到这类占用）。脚本启动时做改名探测提前暴露；若 Cutover 阶段仍被占，关闭后直接重跑即可。
- **Cutover 中途失败可重跑（续作模式）**：复制/校验完成后的任何失败（句柄占用、Junction 建立失败等），重跑脚本会检测到目标已有数据，跳过复制、直接校验源/目标一致后从失败点继续。state 文件记录 `resume/copied/verified/junctionCreated` 阶段标记。
- 复制后逐文件比对相对路径 + 大小；旧目录改名 `*.dshbak`，不删除。
- 迁移后核验项：Junction 目标、`DSH_HOME`、profile 三件套、`.modules.yaml` 的 `storeDir` == DSH 自带 pnpm 的 `store path`、`storages/workspace.json` 可读、sessions 数量、卷 NTFS。
- 插件报 `ERR_PNPM_UNEXPECTED_STORE`：用 `Repair-DshPnpm.ps1 -Execute`，**不要先删 `node_modules`**（DSH 启动不会自动重装，会跳过插件）。
- 工作区文件搬迁是另一件事，见 `dsh-workspace-move.md`；只改 `.dsh` 时不需要动工作区。

## 事实与详细手册

- `dsh-facts.md`：DSH_HOME、会话归属、pnpm、Junction/PowerShell 实测事实。
- `dsh-playbook.md`：完整流程、故障排查、手动命令。
- `dsh-workspace-move.md`：工作区搬迁（可选）。
