# AI 桌面应用数据迁移（DSH / ZCode / WorkBuddy）

把 AI 桌面应用写在用户目录里的数据（DSH 的 `.dsh`、ZCode 的 `.zcode`、WorkBuddy 的 AppData）搬到别的盘，不重装、不丢数据。

本技能主要面向 **C 盘空间不足**，或**不希望应用默认把数据放在 C 盘**的情况；如果磁盘空间充足、也不介意默认路径，可以忽略本技能。

> 范围说明：本技能**不做任意 Windows 应用**的通用迁移，只覆盖 DSH / ZCode / WorkBuddy 三类 AI 桌面应用；`generic` 仅在你明确给出应用数据根时作为兜底。

## 它是什么

一个**路由型技能**：先问用户迁哪个平台（一次只迁一个），再加载对应平台的迁移流程。不是“一键迁移所有应用”的工具。

- DSH：整目录 Junction；可选把用户级 `DSH_HOME` 指向新目录。
- ZCode：两阶段——运行中预拷贝，完全退出后 `/MIR` 收尾 + Junction（db/SQLite 有锁，不能直接热搬）。
- WorkBuddy（以及用户明确指定数据根的同类应用）：整个 home 或指定 AppData 目录做 Junction。

只依赖 Windows 自带 PowerShell 5.1 + `robocopy`；不需要 Python、Node.js，也不需要管理员权限。

## 安全模型（保守优先）

1. **先问平台，一次只迁一个**：用户要求同时迁多个 → 拒绝，建议前一个核验通过后再做下一个。
2. **默认整目录**：迁 `.dsh` / `.zcode` / `.workbuddy` 这类数据根本身，不默认挑单个文件或子目录；只迁子目录会让根目录继续在原盘长东西。
3. **用户说不清数据在哪**：先请求只读搜索权限，再检查环境变量/常见目录/进程；不猜路径。
4. **备份默认保留**：迁移后逐文件核对目标与退路；有缺失先从退路补；全部核验通过、用户确认后才清理退路（覆盖闸门，不自动删数据）。
5. **失败可回滚**：源目录只改名不删除；Junction 失败会尝试恢复原名；state 文件记录回滚信息。
6. **Agent 跑在目标应用里时不能自己执行最后切换**：关掉应用等于关掉 Agent；最后一步交给用户在应用外执行。

## 使用

1. 阅读 `SKILL.md`（执行流程与硬约束）。
2. 先问用户迁哪个平台；平台不确定时，在用户允许后运行：

   ```powershell
   & '<SKILL_DIR>\scripts\Detect-Platform.ps1' -Json
   ```

3. 按用户确认的平台加载 `references/platform-*.md`，按其中命令先演练、再正式执行。
4. 重启应用后逐文件核验；确认正常后清理退路。

## 目录

```
ai-app-home-migration/
├─ SKILL.md                    路由：平台先问 → 加载对应流程
├─ references/
│  ├─ common.md                五阶段、安全闸门、备份生命周期、防御性设问
│  ├─ detect.md                平台识别与 JSON 合同
│  ├─ privacy.md               脱敏规则、提问模板
│  ├─ platform-dsh.md          DSH 入口（+ dsh-facts/playbook/workspace-move）
│  ├─ platform-zcode.md        ZCode 入口（+ zcode-facts/guide）
│  ├─ platform-workbuddy.md    WorkBuddy（+ 明确指定的同类应用）入口（+ workbuddy-handbook）
├─ scripts/
│  ├─ Detect-Platform.ps1      只读识别平台/数据根/机制/进程
│  ├─ dsh/                     Migrate / Verify / Repair pnpm / Rollback / Wizard / Test
│  ├─ zcode/                   measure / precopy / finish / apply
│  └─ workbuddy/               Migrate-WholeHome / Migrate-AppDataDirs / Verify / 启动器
└─ scripts/Test-Toolkit.ps1    静态检查 + 平台识别 + DSH 迁移自测
```

## 测试

在 Windows PowerShell 5.1 下运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Test-Toolkit.ps1
```

会检查脚本编码/语法、平台识别输出，并在临时目录跑一遍 DSH 迁移（不碰真实数据）。当前：`9/9 checks passed`。

## 隐私

技能文件与报告不写用户名、主机名、日期、盘符、绝对个人路径、凭据、会话/数据库内容、对话历史或聊天记录。运行时给用户看的真实路径可以保留，但分享/提交前必须脱敏；规则见 `references/privacy.md`。

## 许可与来源

- 本仓库代码以 MIT 许可发布，详见 `LICENSE`。
- DSH 部分为本项目原创；ZCode 两阶段脚本与 WorkBuddy/通用 AppData 脚本改编自对应迁移工具包。来源与再分发注意事项见 `NOTICE.md`。

## 免责声明

数据迁移有风险。请先在非关键数据上演练、保留退路、逐文件核验；不要在没有备份和核验的情况下删除旧目录。使用者对自己的数据和操作负责。
