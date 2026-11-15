---
name: ai-app-home-migration
description: AI 桌面应用数据目录迁移的路由技能，仅覆盖 DSH / ZCode / WorkBuddy 三类（generic 仅在用户明确指定数据根时兜底）。先问用户迁哪个平台，一次只迁一个；整目录复制、Junction、两阶段收尾、逐文件核对、备份默认保留并在核验通过后清理。触发词：应用数据搬家、数据目录迁移、.dsh 搬家、.zcode 搬家、WorkBuddy 数据迁移、AppData 迁移、C 盘空间、Junction、DSH_HOME、ERR_PNPM_UNEXPECTED_STORE、迁移核验、迁移回滚。
---

# AI 桌面应用数据目录迁移（Windows，按平台路由）

**先问平台，一次只迁一个；整目录，不挑文件；备份默认，核验后清理；用户说不清位置就先请求只读搜索权限。** 这是数据迁移，保守优先于速度。

只依赖 Windows 自带 PowerShell 5.1 + `robocopy`；不需要 Python/Node；Junction 不需要管理员。

## 第 0 步：先问用户迁哪个平台（不要先检测、不要猜）

用一句话给出选项，等用户答：

> 这次要迁移哪个平台的数据？
> **A DSH（`.dsh`） B ZCode（`.zcode`） C WorkBuddy / 其他应用 D 不确定**

规则：

- 用户只说了一个平台 → 继续。
- **用户要求同时迁两个或以上 → 拒绝**：数据迁移必须一个一个来，前一个核验通过后再做下一个。说明原因，给出顺序建议。示例回复：“不能同时迁两个平台——数据要逐个核对，混在一起出问题无法判断是哪套。建议先迁 A，核验通过后再迁 B。” 不要因为用户坚持就并行执行。
- 用户说“不确定/你看着办” → 进入只读识别：先向用户申请权限，再跑 `scripts/Detect-Platform.ps1` 列出候选；仍然**由用户选**，不替用户决定。
- 用户说的是 DSH/ZCode/WorkBuddy 之外的某个应用 → 走 `generic`，并要求用户提供应用数据根（或授权搜索）。

**完成条件**：平台唯一、用户明确确认；不存在“先迁两个再说”。

## 第 1 步：定位数据根与精确路径

先问用户是否知道数据根；不知道时**请求只读搜索权限**：

> 我可以只读检查环境变量、常见数据目录和进程来定位数据吗？不会写入或修改任何文件。如果这些地方都没有，我可能还需要你授权在指定盘/用户目录按应用名做一次限定范围的只读搜索。

获得同意后：

```powershell
& '<SKILL_DIR>\scripts\Detect-Platform.ps1' -Json
# 或指定平台：
& '<SKILL_DIR>\scripts\Detect-Platform.ps1' -Platform dsh -Json
```

- 输出 `ambiguous: true` → 列出候选，让用户选；仍不猜。
- 输出 `platform: null` → 问应用名/数据根；标准目录都没有时，请求授权做限定范围的只读搜索（例如只在 `%USERPROFILE%` 与程序安装盘的已知目录按应用名/特征文件查找），并说明搜索范围和预计耗时。
- 用户已经给出路径 → 用 `Test-Path` / `Get-Item -Force` 验证存在、是否 Junction、是否指向别处，不直接相信描述。

**完成条件**：`dataRoot` 已确认（存在或是明确的新装目录）、`mechanism` 明确（Junction / DSH_HOME / 两阶段）、没有歧义。

## 第 2 步：防御性设问（一次列全，不要连环追问）

把需要用户决定的点一次列清，每项带默认值；用户答不齐就停：

1. **迁移范围**：默认**整个应用数据根**（`.dsh` / `.zcode` / `.workbuddy` 这一级）。不要默认只迁某个文件/子目录——以后新增内容还会长回原盘。要拆目录必须用户明确要求，并接受“根目录仍是真实目录、以后新增内容仍落原盘”的代价。
2. **目标精确路径**：给到数据根这一层（如 `X:\DSHData\.dsh`），不是父目录；本地 NTFS、非 OneDrive/网络/移动盘、路径尽量短（脚本会检查长度）。
3. **应用何时完全退出**：窗口 + 托盘 + 后台进程；如果 Agent 跑在该应用里，明确告诉用户：最后切换必须由用户在应用外执行，Agent 不能关掉宿主。
4. **备份策略**：默认保留退路，迁移后**逐文件核对**；发现缺失/不一致先补，全部核验通过后再清理退路。清理必须用户确认，且走覆盖闸门。
5. **失败预期**：确认用户接受“源目录只改名不删除、目标盘临时占用、失败可回滚”的前提。

**防御性确认**：真正执行前，把“将复制哪个根 → 哪个目标、预计大小、将保留哪个退路、不会删除什么、回滚命令是什么”复述一遍，用户明确说“开始”才执行。不要用“看起来应该可以”代替确认。

**完成条件**：范围、路径、停机、备份、失败处理五项明确；用户已确认执行计划。

## 第 3 步：只加载命中平台

| 平台 | 参考 | 入口脚本 | 默认机制 |
|---|---|---|---|
| `dsh` | `references/platform-dsh.md` | `scripts/dsh/Migrate-DshHome.ps1` → `Verify-DshMigration.ps1` | 整目录 Junction；可选 `-SetDshHome` |
| `zcode` | `references/platform-zcode.md` | `scripts/zcode/measure.ps1` → `precopy.ps1` → `finish_migration.ps1` | 两阶段：运行中预拷贝 + 退出后 `/MIR` 收尾 |
| `workbuddy` / `generic` | `references/platform-workbuddy.md` | `scripts/workbuddy/Migrate-WholeHome.ps1`（首选） | 整个 home 一次变 Junction；逐目录仅特殊场景 |

**只读命中的那一份 reference 和 scripts**，不要把 DSH 的 `DSH_HOME` 逻辑套到 ZCode。

**完成条件**：已加载且只加载一个平台；已按该平台流程进入 Discover。

## 第 4 步：Discover → Prepare → Cutover

按 `references/common.md` 的五阶段模型执行。每个平台脚本都会做前置检查（进程/锁、目标盘、空间、源树内部 reparse、路径嵌套）并区分演练/正式。

- **DSH**：关闭 DSH 后复制 → 逐文件校验 → 改名留退路 → Junction → 探针。若用户级 `DSH_HOME` 指向第三处，脚本会停。Cutover 中途失败（如目录句柄被资源管理器/终端占用）重跑即续作：跳过复制、从失败点继续。
- **ZCode**：运行中预拷贝 → 用户完全退出 → `/MIR` 镜像×2 → 零差异校验 → 改名 → Junction。
- **WorkBuddy/通用**：关闭应用 → **整个 home** 复制 → 校验 → 改名/建 Junction；逐目录模式不是默认。

**完成条件**：脚本退出码 0，输出里有退路位置和 state/回滚信息；源数据未删除。

## 第 5 步：逐文件核对 → 补 → 清理

1. 重启应用后跑平台 Verify；**必须逐文件核对**（相对路径 + 大小；静态文件可加 SHA256）。
2. 发现缺失/不一致：先按脚本提示从退路补到目标；补齐后再核验一次。**不要带着差异继续用**。
3. 核验全部通过、用户确认应用正常后，**及时清理退路**（用户确认 + 覆盖闸门）；不要长期留着占空间。
4. 任何失败：按平台回滚命令恢复旧目录/Junction，不删目标数据。

**完成条件**：Verify 无 FAIL + 用户确认应用正常 + 退路已按策略清理（或用户明确选择暂时保留并知道原因）。

## 硬约束

- **一个平台一次迁移**；用户要求同时迁多个 → 拒绝并建议顺序执行。
- **默认整目录**（`.dsh` / `.zcode` / `.workbuddy`）；不默认挑单个文件/子目录。
- **用户说不清数据在哪 → 先请求只读搜索权限**，再检测；不要猜路径。
- **Agent 跑在目标应用里（DSH/ZCode）时不能自己执行 Cutover**：关掉应用等于关掉自己；最后一步交给用户在应用外执行。
- 应用没完全退出，不做 Cutover；窗口、托盘、后台进程都算。
- 目标必须是本地固定 NTFS，源/目标不能是盘根或互相嵌套；`robocopy` 必须 `/XJ`，`0–7` 正常、`>=8` 失败。
- 源树内部先扫 reparse point；非零就停（`/XJ` 会静默跳过、导致缺数据）。
- 复制后逐文件比对，不能只比总数/总字节；空间验证用磁盘剩余空间差，不用递归目录大小。
- 旧目录只改名不删除；删 Junction 非递归；删退路前做覆盖闸门。
- `.ps1` 必须 UTF-8 BOM，`.cmd` 必须 CRLF + 纯 ASCII；长路径枚举用 `.NET \\?\`。
- **隐私**：技能文件/报告不写用户名、主机名、日期、盘符、绝对个人路径、凭据、会话/数据库内容、**对话历史/聊天记录/提示词**；分享用 `displayRoot` 或占位符。详见 `references/privacy.md`。

## 资源

| 路径 | 作用 |
|---|---|
| `scripts/Detect-Platform.ps1` | 只读识别平台/数据根/机制/进程，输出 JSON（含 `displayRoot`）；**仅在用户允许搜索或平台不确定时使用** |
| `references/common.md` | 五阶段、PS 5.1、安全闸门、备份生命周期、防御性设问 |
| `references/detect.md` | 检测优先级、JSON 合同、歧义处理 |
| `references/privacy.md` | 脱敏规则、提问模板、禁止记录的内容 |
| `references/platform-dsh.md` + `dsh-facts.md` / `dsh-playbook.md` | DSH 事实与流程 |
| `references/platform-zcode.md` + `zcode-facts.md` / `zcode-guide.md` | ZCode 两阶段事实与完整指南 |
| `references/platform-workbuddy.md` + `workbuddy-handbook.md` | WorkBuddy（+ 用户明确指定的同类应用）方法论 |
| `scripts/<platform>/` | 各平台脚本；DSH 含 Verify/Repair pnpm/Rollback/Wizard |

## 不适用

- 非 Windows；重装应用本体；只清理缓存；跨平台虚拟机数据盘。

## 报告格式（脱敏）

```text
结论: 成功/失败/需要用户操作
平台: dsh|zcode|workbuddy|generic（用户确认，非猜测）
范围: 整个数据根（.dsh/.zcode/.workbuddy）
路径: <DATA_ROOT 脱敏> -> <TARGET_ROOT 脱敏>  机制: Junction / 两阶段 / DSH_HOME
退路: <位置描述>（已清理 / 仍保留及原因）
核验: PASS/WARN/FAIL + 关键项（不贴真实用户名/主机名/对话内容）
回滚: <平台对应命令>
```
