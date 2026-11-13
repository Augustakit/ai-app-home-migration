# 事实断言（facts.md）

> 本文件是 zcode-home-migration 技能的事实底座：所有"为什么"类问题先查这里。断言来源：真实环境实测 + 对 ZCode Desktop 程序包（app.asar）的字节级检索。规范会随版本变化，重大版本更新后建议重新验证标记为【逆向】的条目。

## 数据分布：四块地盘

| 块 | 位置 | 处置 |
|---|---|---|
| ① 程序安装目录 | 如 `X:\ZCode\`（ZCode.exe / resources / app.asar） | **不能搬**（注册表登记卸载信息） |
| ② 用户级数据 | `%USERPROFILE%\.zcode`（cli\{db,plugins,memories,rollout,log,artifacts,exec,agents,image-cache,pdf-cache,node-fallback} + v2 引导配置与凭据） | **本文主角，Junction 搬** |
| ③ 工作区级数据 | `{dataBaseDir}\.zcode`（workspace / v2 运行时 / visualizations / backup） | 走应用设置界面的 dataBaseDir 自带迁移 |
| ④ Electron 系统缓存 | %APPDATA% 相关 | 体积小，忽略 |

## dataBaseDir 的边界（为什么它替代不了本迁移）

- 【逆向】内部解析链：`getDataBaseDir()` = 运行时覆盖（setting.json 的 dataBaseDir）→ `ZCODE_DATA_BASE_DIR` 环境变量 → `HOME`/`homedir()`。工作区目录、v2（运行时）、visualizations、backup 都走这条链。
- 【实测】dataBaseDir 已指向数据盘时，`cli\db\db.sqlite` 仍在 `%USERPROFILE%\.zcode\cli\db` 且被主进程锁定 → **cli 不跟 dataBaseDir 走**。

## cli 的锚定机制（为什么只能 Junction）【逆向】

- 模型转录目录解析（resolveModelIODirs）：`join(homedir(), ".zcode", "cli")` 与另一个根的双路径查找——homedir 写死。
- `ZCODE_STORAGE_DIR`：仅 CLI 子进程认（如 `cli\exec` 的解析），主进程不认 → 不完整。
- `ZCODE_HOME`：仅证实覆盖 computer-use 辅助器安装根（解析函数明确：有它用它，否则 `$HOME/.zcode`）→ 覆盖面太小。
- 会话库路径【逆向】：`join(<根>, ".zcode", "cli", "db", "db.sqlite")`；【实测】运行中该库在 homedir 侧被锁。
- **结论**：环境变量方案覆盖面不可靠，赌它 = 数据分裂在两个盘。Junction 对一切路径解析透明，是唯一全覆盖方案。

## 锁占用实测（探测方法：独占打开）

```powershell
try { $fs=[System.IO.File]::Open('文件','Open','Read','None'); $fs.Close(); 'FREE' } catch { 'LOCKED' }
```

- **LOCKED**：`cli\db\db.sqlite`、`-wal`、`-shm`（主进程全程持有）
- **FREE**：`cli\config.json`、`v2\setting.json`、`v2\tasks-index.sqlite`、`cli\rollout\*.jsonl`（写入器按需开关句柄）
- 教训：**锁必须实测不能猜**——正在写的 rollout 文件反而是 FREE 的。

## 干净关闭的"合法删除"（收尾必须 /MIR 的依据）【实测】

- SQLite 干净关闭时 checkpoint：WAL 合并回主库并**删除** `-wal/-shm`（主库 mtime=关闭时刻为证）。
- shell 快照（`cli\exec\shell-snapshots\`）会被轮换清理。
- 后果：应用运行中拷的"热快照"里，这些文件在源侧已消失 → `robocopy /E` 只增不删 → 目标残留旧 WAL/快照 → 严格校验"目标多出"必拦。
- **风险**：旧 WAL 若随 Junction 幸存，下次启动会对已 checkpoint 的主库做误恢复 → 会话库损坏风险。所以收尾同步必须 `/MIR`（镜像），严格校验零差异是最后一道闸。

## 其他实测事实

- 源树内部 reparse point：实测 0 个。**任何源树都要先扫再 /XJ**：技能脚本用不进入链接的手工栈遍历（防 GCI 漏检、防枚举跟随链接死循环）。
- robocopy 退出码是位掩码：0-7 正常，**≥8 才是失败**。
- `Get-ChildItem -Recurse` 会穿透 Junction：迁移后再统计仍显示几百 MB——**假象**。验证 C 盘释放只能用 `[System.IO.DriveInfo]` 剩余空间差。
- 编码坑：PS 5.1 读无 BOM 的 UTF-8 脚本按 GBK 解析（中文语法报错）→ **ps1 必带 BOM**（注意幂等：已有 BOM 再补一次会变双 BOM，解析直接崩）；cmd 对 LF-only 批处理会"半行执行" → **cmd 必须 CRLF + 纯 ASCII**。
- 长路径实测：PS 5.1 的 `Get-ChildItem -Recurse` 对超过 260 字符的路径会**静默漏文件**（实测 5 文件小树漏 1 个 316 字符文件，GCI 只报 4 个）。典型 ZCode 数据树离上限很远——实测全树最深相对路径仅 ~150 字符（artifacts 的哈希文件名）；个别插件会自带 node_modules（如 computer-use 插件，101 个文件）。余量虽大，但 GCI 漏文件是**静默行为**，一旦未来出现深路径（第三方插件/未来版本）不会报错——所以脚本内枚举统一走 .NET `\\?\` 前缀（`Directory.EnumerateFiles`），这是零成本的"永不静默漏"保险。measure 会报告最深相对路径，>240 字符时目标根必须选短。
- 体量参考（中等使用强度的机器）：用户级目录通常为数百 MB 量级，其中 cli\db（会话库）约占一半。增长认知（实测）：db 是主要持续增长项（重度使用一天可 +几十 MB）；rollout（模型转录）单会话可暴涨数十 MB，但默认保留策略（setting.json 的 `modelIoFullRetentionEnabled: false`，实测旧转录会被清理）使其不无限增长；cli\log 按天一个 jsonl 稳定累积（实测每天约 10-13 MB）。
