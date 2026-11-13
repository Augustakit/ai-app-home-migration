# 平台：WorkBuddy（+ 明确指定的同类应用）

WorkBuddy 的迁移工具本身是**通用 Windows 应用数据迁移器**：把一个应用写在用户目录/AppData 里的数据整体或按目录搬到其他本地 NTFS 盘，用 Junction 保持原路径可用。

本技能只把它用于 **WorkBuddy**，以及用户明确提供数据根、明确要求迁移的同类 AI 桌面应用；**不声明支持任意 Windows 应用**。generic 兜底必须由用户给出 `-AppHome`/数据根，不由 AI 猜。

## 两种模式

| 模式 | 脚本 | 适用 |
|---|---|---|
| **整体 home（默认，首选）** | `Migrate-WholeHome.ps1` | 整个数据根都搬走；散文件、以后新建内容都落到新盘 |
| 逐目录（特殊场景，非默认） | `Migrate-AppDataDirs.ps1` | 用户明确只搬几个大目录，并接受根目录仍是真目录、以后新增内容仍落原盘 |

**默认迁整个应用数据根**（如 `.workbuddy` / AppData 下整个应用目录），不要默认挑单个文件/子目录；只搬子目录会让根目录继续在原盘长东西。

## 备份与核验

- 迁移默认保留 `.migbak` 退路；完成之后逐文件核对目标 ↔ 退路。
- 发现缺失/不一致先从退路补齐，再核验一次。
- 全部通过、用户确认应用正常后，按覆盖闸门及时清理退路；不要长期保留占空间。
- 清理有覆盖闸门：退路中的非链接内容必须已被目标覆盖；不通过就保留。

## 执行入口

```powershell
$s = '<SKILL_DIR>\scripts\workbuddy'

# 整体迁移：先填好源/目标/进程名占位符，再演练
& "$s\Migrate-WholeHome.ps1" -SourceRoot '<APP_HOME>' -TargetRoot '<TARGET_ROOT>' -GuardProcess '<PROCESS>' -WhatIf
# 正式执行：去掉 -WhatIf
& "$s\Migrate-WholeHome.ps1" -SourceRoot '<APP_HOME>' -TargetRoot '<TARGET_ROOT>' -GuardProcess '<PROCESS>'

# 逐目录迁移：
#   改 Run-Migration.bat 顶部 SRC/DST/NAMES/GUARD，先双击演练，再去掉 -WhatIf

# 核验（整体/逐目录自动识别）
& "$s\Verify-Migration.ps1" -SourceRoot '<APP_HOME>' -TargetRoot '<TARGET_ROOT>' [-Directories @('dir1','dir2')]
```

## 关键约束

- 应用必须完全退出（整体/逐目录都一样；进程守卫会检查）。
- 目标必须是本地固定 NTFS，路径短；源/目标不能是盘根或互相嵌套。
- `robocopy` 必须带 `/XJ`；退出码 `0–7` 正常、`>=8` 失败。
- 退路默认保留（`.migbak`）；清理有覆盖闸门：退路中的非链接内容必须已被目标覆盖，静态文件建议 SHA256 核对。
- 删除 Junction 必须非递归；含子链接的退路必须“先删链接、再删内容、最后删根”。
- **不要用“经 Junction 读到的源”和“目标”比对**：两者读的是同一份数据，是假校验；要用备份本体和目标比对。
- 应用运行中扫描的字节数/哈希可能变化（日志、数据库在写），不能当迁移失败；判据是相对路径集合、静态文件哈希、写入探针、磁盘剩余空间变化。
- 整体迁移后子目录不再是链接；核验脚本会自动识别整体模式，不要用“每个子目录都必须是 Junction”的旧标准。

## 详细手册

- `workbuddy-handbook.md`：完整方法论、决策表、备份覆盖闸门、清理模式、验证清单、回滚、踩坑。
