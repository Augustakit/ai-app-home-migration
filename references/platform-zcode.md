# 平台：ZCode Desktop

## 识别特征

- 进程：`ZCode.exe`
- 数据根：`%USERPROFILE%\.zcode`（通常是 Junction）
- 环境变量 `ZCODE_HOME` / `ZCODE_DATA_BASE_DIR` / `ZCODE_STORAGE_DIR` 存在但**覆盖面不可靠**，不能作为迁移方案

## 为什么是两阶段

1. ZCode 运行时独占锁 `cli\db\db.sqlite`、`-wal`、`-shm`；关掉之前不能做最终同步。
2. Agent 常跑在 ZCode 里，**不能杀宿主**；所以：
   - **阶段一**：应用运行中预拷贝（`/E`，活跃文件差异属预期）
   - **阶段二**：用户完全退出 ZCode 后，收尾脚本 `/MIR` 镜像 + 零差异校验 + 改名留回滚 + Junction

## 执行入口

```powershell
$s = '<SKILL_DIR>\scripts\zcode'

# 0) 只读摸底：体积、锁、内部链接、进程
& "$s\measure.ps1"

# 1) 阶段一：应用运行中可做
& "$s\precopy.ps1" -Dst '<TARGET_ROOT>'

# 2) 部署收尾入口到目标盘根（两棵操作树之外），先趁运行中实测一次守护
#    把 finish_migration.ps1 + apply_migration.cmd 复制到 <TARGET_DRIVE>:\<MIGRATION_WORK>\
& "<TARGET_DRIVE>:\<MIGRATION_WORK>\finish_migration.ps1" -Dst '<TARGET_ROOT>'
#    预期：检测到 ZCode 仍在运行 → 退出码 1、零改动

# 3) 阶段二：用户完全退出 ZCode 后，由用户双击 apply_migration.cmd
```

## 关键约束

- **收尾同步必须 `/MIR`，不能用 `/E`**：干净关闭会合法删除 WAL/快照，旧副本残留会导致会话库误恢复风险。
- **`/XJ` 之前必须扫源树内部 reparse point**：非零先处理，否则会静默缺数据。
- 脚本内文件枚举统一走 `.NET \\?\`（PS 5.1 的 GCI 对 >260 路径静默漏文件）。
- 源树内部有链接时 `measure.ps1` 会提示；`precopy.ps1` / `finish_migration.ps1` 会拒绝继续。
- `.ps1` 必须 UTF-8 BOM；`.cmd` 必须 CRLF + 纯 ASCII；中文文件名不要写进批处理。
- **Agent 跑在 ZCode 里时，阶段二必须由用户在 ZCode 外执行**（双击 `apply_migration.cmd`）；Agent 不要试图关闭宿主。
- 旧目录改名 `.zcode.old-<时间戳>`，默认保留；删除需用户明确确认。
- 数据根目标必须是本地 NTFS、非盘根、路径短；源/目标不能互相嵌套。

## 事实与详细指南

- `zcode-facts.md`：dataBaseDir 边界、cli 锚定、锁实测、/MIR 依据、长路径/编码坑。
- `zcode-guide.md`：完整用户指南（验证清单、FAQ、手动分步、回滚、踩坑实录），可直接交给最终用户。
