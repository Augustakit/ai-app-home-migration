# ZCode Desktop 数据目录迁移指南（Windows）

> 把 ZCode 在 C 盘用户目录下的数据（`%USERPROFILE%\.zcode`，几百 MB，会随使用持续增长）搬到数据盘。
>
> 本文自足：Junction 与 robocopy 的要点见下面「概念 30 秒」，正文讲 **ZCode 特有的架构与"应用运行中怎么搬"的两阶段解法**。
>
> 本文所有路径均为通用写法，可直接照抄。

---

## 概念 30 秒（Junction 与 robocopy 要点）

- **Junction（目录联接）**：Windows 文件系统层的"目录转发"——程序访问源路径时被自动引到目标路径，程序毫无感知。对"数据实体搬去别的盘、原路径照常可用"的需求，它是唯一全覆盖方案。
- 创建**不需要管理员**：`New-Item -ItemType Junction -Path 源 -Target 目标`。
- 删除 Junction 用 `cmd /c rmdir "源路径"`——**只删链接、不删目标数据**；不要对链接用 `Remove-Item -Recurse`。
- 资源管理器里 Junction 显示成普通文件夹，**肉眼看不出来**：永远用 `Get-Item 路径 -Force | Select-Object Name, LinkType, Target` 确认。
- `Get-ChildItem -Recurse` 会**穿透** Junction 统计目标盘内容——迁移后再统计仍显示几百 MB 是假象；判断 C 盘是否释放只能看磁盘剩余空间差（`[System.IO.DriveInfo]`）。
- robocopy 复制可能含链接的树必须带 **/XJ**（跳过 Junction，防复制循环）；其退出码是位掩码，**0-7 正常、≥8 才是失败**。
- 核心安全策略：**旧目录只改名不删除**（`.zcode.old-<时间戳>`），确认无误数天后才清理。

---

## 快速导航

| 你的情况 | 直接跳转 |
|---|---|
| 只想照着做 | [第三部分](#第三部分两阶段迁移核心) |
| 想知道为什么必须用 Junction | [1.3 节](#13-为什么只能用-junction实测证据链) |
| 不知道该搬什么 | [1.1 节](#11-zcode-的数据放在哪实测架构) |
| "agent 在 ZCode 里干活，没法退出应用怎么办" | [3.1 节](#31-为什么分两阶段) |
| 搬完验证 | [第四部分](#第四部分迁移后验证) |
| 出问题回滚 | [附录 B](#附录-b-回滚) |
| 想看实测踩过的坑 | [第六部分](#第六部分踩坑实录) |

---

# 第一部分：ZCode 的数据放在哪（实测架构）

## 1.1 四块地盘

```
┌─────────────────────────────────────────────────────────────┐
│ ① 程序安装目录                       【不能搬】              │
│    如 X:\ZCode\  (ZCode.exe / resources / app.asar)         │
│    注册表登记了卸载信息，搬了会坏                            │
├─────────────────────────────────────────────────────────────┤
│ ② 用户级数据目录 %USERPROFILE%\.zcode  【本文主角，Junction 搬】│
│    cli\                                                     │
│      db\          会话数据库 db.sqlite（几百 MB，★大头）     │
│      artifacts\   会话产物                                   │
│      plugins\     插件缓存（个别插件自带 node_modules）       │
│      rollout\     模型转录（单会话可暴涨，默认会被清理）      │
│      log\ image-cache\ pdf-cache\ exec\ …                   │
│      memories\    跨会话记忆                                 │
│      config.json 配置                                        │
│    v2\            引导配置与凭据（setting.json、credentials）│
├─────────────────────────────────────────────────────────────┤
│ ③ 工作区级数据 {dataBaseDir}\.zcode    【不用 Junction 搬】   │
│    workspace\ visualizations\ backup\ v2\（运行时部分）      │
│    位置由设置界面/配置文件里的 dataBaseDir 决定，            │
│    改它走应用自带迁移，不要手动搬                            │
├─────────────────────────────────────────────────────────────┤
│ ④ Electron 系统级缓存                 【体积小，忽略】        │
└─────────────────────────────────────────────────────────────┘
```

体量参考（一台使用了数周至数月的机器）：②共数百 MB 量级；`cli\db`（会话库）通常是大头，其次是 `artifacts`、`plugins`、`log`、`rollout`。以 measure 脚本的实测输出为准。

**增长认知**：迁移只解决"放在哪个盘"，不解决"会不会长大"。实测 `db.sqlite`（会话库）是主要持续增长项（重度使用一天可 +几十 MB）；`rollout`（模型转录）单会话可暴涨数十 MB，但默认保留策略（`modelIoFullRetentionEnabled: false`，实测旧转录会被清理）使其不无限增长；`cli\log` 按天一个文件稳定累积。

## 1.2 dataBaseDir 管不了 ②——这是最容易搞错的一点

ZCode 设置里有 `dataBaseDir`（数据目录）选项，改它应用会自带"复制+需重启"的迁移流程。**但实测它只搬 ③ 工作区级数据。**

证据链：
- 实测：`dataBaseDir` 已指向数据盘时，③ 的 `workspace/visualizations/v2` 确实在数据盘，**但 `cli\db\db.sqlite` 仍在 `%USERPROFILE%\.zcode\cli\db`**，且运行中被主进程锁定；
- 逆向（对 app.asar 做字节级检索）：内部解析函数为"运行时覆盖（来自 setting.json 的 dataBaseDir）→ `ZCODE_DATA_BASE_DIR` 环境变量 → `HOME`/`homedir()`"，工作区、v2 走这条链；而 `cli` 侧的解析直接 `join(homedir(), ".zcode", "cli")` 写死锚定用户目录。

## 1.3 为什么只能用 Junction（实测证据链）

程序内确实存在三个环境变量的名字：`ZCODE_HOME`、`ZCODE_DATA_BASE_DIR`、`ZCODE_STORAGE_DIR`。别高兴太早，逐个验证后：

| 环境变量 | 能证明覆盖的范围 | 结论 |
|---|---|---|
| `ZCODE_HOME` | 仅 computer-use 辅助器的安装根（解析函数明确：有它用它，否则 `$HOME/.zcode`） | 不赌 |
| `ZCODE_DATA_BASE_DIR` | 等价于 dataBaseDir，只管 ③ | 管不了 ② |
| `ZCODE_STORAGE_DIR` | CLI 子进程的 `cli\exec` 等局部路径；主进程不认 | 不完整 |

**赌"环境变量能整体搬家"的后果**：部分组件认、部分组件不认 → C 盘照旧长出 `.zcode`，数据分裂在两个盘——这正是"软件无视环境变量重新创建默认目录"的经典情形。

**结论：② 是被 `homedir()` 写死锚定的应用数据目录——用 Junction（同类应用的通行做法）。** Junction 对一切路径解析透明，不存在"哪个组件没跟上"的问题。

---

# 第二部分：迁移前测量

普通权限 PowerShell，整段粘贴（纪律：**每行必有输出，不存在"静默跳过"**——缺了行的报告等于没测）：

```powershell
function Show-Size([string]$Label, [string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        ("{0,-40} {1}" -f $Label, "(不存在)")
        return
    }
    $items = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue)
    $sum = ($items | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { $sum = 0 }
    $mb = [math]::Round($sum / 1MB, 2)
    $link = (Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue).LinkType
    $tag = if ($link) { "  [$link]" } else { "" }
    "{0,-40} {1,10} MB  ({2} 个文件){3}" -f $Label, $mb, $items.Count, $tag
}

"===== ZCode 用户级数据 ====="
Show-Size ".zcode 总计"          "$env:USERPROFILE\.zcode"
Show-Size "  └ cli\db"           "$env:USERPROFILE\.zcode\cli\db"
Show-Size "  └ cli\plugins"      "$env:USERPROFILE\.zcode\cli\plugins"
Show-Size "  └ cli\artifacts"    "$env:USERPROFILE\.zcode\cli\artifacts"
Show-Size "  └ cli\log"          "$env:USERPROFILE\.zcode\cli\log"
Show-Size "  └ cli\rollout"      "$env:USERPROFILE\.zcode\cli\rollout"
Show-Size "  └ cli\memories"     "$env:USERPROFILE\.zcode\cli\memories"
Show-Size "  └ v2"               "$env:USERPROFILE\.zcode\v2"

"`n===== 磁盘剩余空间 ====="
[System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady } | ForEach-Object {
    "{0}  剩余 {1,7} GB" -f $_.Name, [math]::Round($_.AvailableFreeSpace/1GB,1)
}
```

> 注：此手动脚本用 `Get-ChildItem` 统计，对超过 260 字符的深路径会**静默漏计**——精确数字以技能的 measure.ps1 为准。

记下数字，迁移后对比。**判断 C 盘是否释放只能用磁盘剩余空间差**（`Get-ChildItem -Recurse` 会穿透 Junction，迁移后这里仍会显示几百 MB，是假象）。

**目标盘要求**：非系统盘、NTFS、无中文无空格、不在 OneDrive 里、路径别太深。下文以 `X:\ZCodeHome\.zcode` 代指（把 X 换成你的盘符）。

**迁移前安全检查（重要，别省）**：扫描源树内部有没有已存在的 Junction/符号链接——有的话 `robocopy /XJ` 会把它们跳过，造成目标缺数据：

```powershell
Get-ChildItem -LiteralPath "$env:USERPROFILE\.zcode" -Recurse -Force `
    -Attributes ReparsePoint -ErrorAction SilentlyContinue |
    Select-Object FullName, LinkType
```

- 无输出 → 安全，可以往下走
- 有输出 → 不能直接用 `/XJ` 整树拷，需针对这些链接单独处理

常见情形是 0 个；但个别工具/插件可能装出符号链接或 junction（如自带依赖的插件），它们正是 /XJ 会跳过的对象——以扫描结果为准。

---

# 第三部分：两阶段迁移（核心）

## 3.1 为什么分两阶段

这类迁移要求"应用完全退出"，因为：
- 应用运行中，数据库文件被锁定，目录改不了名；
- 活着把文件搬走 = 应用的新写入还落在旧位置，Junction 指向的是旧快照 → **数据分叉**。

ZCode 同理，实测锁占用（用独占打开探测，**不要凭猜测**）：

```
LOCKED  cli\db\db.sqlite        ← 会话库，主进程全程持有
LOCKED  cli\db\db.sqlite-wal
LOCKED  cli\db\db.sqlite-shm
FREE    cli\config.json         ← 并不是所有文件都锁着
FREE    v2\setting.json
FREE    cli\rollout\*.jsonl     ← 转录文件反而没锁（写入器按需开关句柄）
```

但有个新问题：**如果你是让 agent 在 ZCode 里干活，agent 杀不死宿主应用**——"先退出应用"这一步它做不到；而由人来做，人又要先等 agent 干完。

解法：**把"复制"和"切换"拆开**。

```
阶段一（应用运行中，随时可做）
    robocopy 全量预拷贝 → 逐文件校验
    （拷走的是"热快照"，活跃文件允许有差异，收尾时兜底）
        ↓
阶段二（ZCode 完全退出后，一键完成）
    增量重同步 ×2 → 严格校验（零差异）→ C 盘原目录改名留回滚
    → 建 Junction → 自检 → 可选启动 ZCode
```

阶段一先跑的好处：数百 MB 的大头在应用运行时就拷完了，阶段二只剩几秒到几十秒的增量同步，应用停机窗口极短。

## 3.2 阶段一：预拷贝 + 校验（应用运行中可做）

**纪律：脚本放在两棵操作树之外**（脚本若在被操作的树里，复制和校验会撞上脚本自己）。下例放 `X:\migration-work\`。

```powershell
# phaseA_precopy.ps1 —— 存到操作树之外再运行
$Src = Join-Path $env:USERPROFILE '.zcode'
$Dst = 'X:\ZCodeHome\.zcode'    # 改成你的目标

if (-not (Test-Path -LiteralPath $Src)) { throw "源不存在: $Src" }
if ((Get-Item -LiteralPath $Src -Force).LinkType) { throw "源已是链接，无需迁移" }
New-Item -ItemType Directory -Path $Dst -Force | Out-Null

# robocopy 两遍：第二遍补第一遍拷贝期间被写动的文件
#   /E 含空目录  /COPY:DAT /DCOPY:DAT 保数据属性时间戳
#   /R:2 /W:2 限重试  /XJ 跳过 Junction  /MT:16 多线程
foreach ($pass in 1..2) {
    & robocopy $Src $Dst /E /COPY:DAT /DCOPY:DAT /R:2 /W:2 /XJ /MT:16 /NFL /NDL /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy 失败（退出码 $LASTEXITCODE）" }  # 0-7 均为正常，≥8 才是失败
    "pass $pass 完成"
}

# 逐文件大小字典比对（比"总数+总字节"更严，能抓同字节置换）
function Get-SizeMap([string]$Path) {
    $map = @{}
    Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
        ForEach-Object { $map[$_.FullName.Substring($Path.Length + 1)] = $_.Length }
    return $map
}
$sm = Get-SizeMap $Src; $dm = Get-SizeMap $Dst
$diff = @()
foreach ($k in $sm.Keys) {
    if (-not $dm.ContainsKey($k)) { $diff += "缺少: $k" }
    elseif ($dm[$k] -ne $sm[$k])  { $diff += "大小不同: $k" }
}
# 应用运行中，活跃文件（db.sqlite* / rollout / log）允许差异，收尾脚本会兜底重同步
$live = $diff | Where-Object { $_ -match 'db\.sqlite|^rollout|^log' }
$bad  = $diff | Where-Object { $_ -notmatch 'db\.sqlite|^rollout|^log' }
if ($bad)  { $bad;  throw "存在非预期差异，重跑本脚本是安全的（增量）" }
if ($live) { "活跃文件差异（预期内）: $($live -join '; ')" }
"校验通过: 源 $($sm.Count) 个文件 / 目标 $($dm.Count) 个文件"
```

预期结果：两遍后逐文件比对完全一致；第一遍拷贝期间被写动的活跃文件通常会被第二遍补齐。

## 3.3 阶段二：收尾脚本（ZCode 完全退出后一键完成）

写一个 `ZCode-migration-finisher.ps1`（**必须保存为 UTF-8 with BOM**，否则 Windows PowerShell 5.1 会按 GBK 解析中文注释直接报语法错——实测踩过的坑），旁边放一个双击入口 `.cmd`（**必须 CRLF + 纯 ASCII 内容**，LF-only 的批处理会被 cmd 解析成"半行执行"——实测踩过的坑；ps1 文件名含中文时在 cmd 里用通配符匹配，别把中文写进批处理）：

```cmd
@echo off
rem Double-click launcher. Requirement: ZCode FULLY exited (check tray).
for %%f in ("%~dp0ZCode-*.ps1") do set "PS1=%%~ff"
if not defined PS1 (
  echo [ERROR] finisher .ps1 not found next to this file.
  pause
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
echo.
pause
```

收尾脚本完整动作（按序，任何一步失败立即中止并回滚，**绝不删除源数据**）：

```
0. 前置检查
   ├─ Get-Process ZCode 有输出 → 中止（"请完全退出 ZCode 含托盘"）
   ├─ 源已是 Junction → 报告"早已完成"，退出
   └─ 源/目标存在性、目标不是链接
0.5 清理预告：列出目标侧残留（源已合法删除的文件旧拷贝）
1. 镜像同步 ×2：robocopy /MIR（= 复制差异 + 清理目标侧多余文件）
   ⚠ 必须用 /MIR 而非 /E：应用干净关闭时会"合法删除"部分文件
   （SQLite 关闭时把 WAL 合并回主库并删除 -wal/-shm；shell 快照被轮换清理）。
   这些文件在目标盘的旧拷贝若不清掉：一校验必挂；二旧 WAL 幸存会让下次
   启动对已 checkpoint 的会话库做误恢复（损坏风险）。/MIR 使目标=源的精确镜像。
2. 严格校验：逐文件大小字典比对，零差异才放行
   （应用已退出，任何差异都说明有程序还在占用，中止并提示排查）
3. 原目录改名 %USERPROFILE%\.zcode → %USERPROFILE%\.zcode.old-<时间戳>
   （改名而不是删除 —— 回滚的救命稻草，整套方案的核心安全策略）
4. 建 Junction：New-Item -ItemType Junction -Path 源 -Target 目标
   （不需要管理员权限；失败则把 .old 改名回去再中止）
5. 自检：LinkType=Junction、Target 正确、经链接读取文件数=直读目标、
   经链接能读到 cli\config.json 与 db.sqlite
6. 打印完成信息 + 保留 .old 的删除命令（注释状态）+ 询问是否启动 ZCode
```

**操作步骤**：

1. 关闭所有 ZCode 窗口 → **检查托盘区**，右键退出后台进程
2. 关闭一切停在 `.zcode` 目录里的资源管理器窗口 / 终端 / 编辑器（否则第 3 步改名会失败——脚本会明确告诉你这个原因）
3. 双击 `应用迁移.cmd`
4. 全绿后脚本可帮你重启 ZCode

**手动分步版**（不放心脚本的话，等价命令；确认 ZCode 已退出后逐条执行）：

```powershell
$Src = "$env:USERPROFILE\.zcode"
$Dst = 'X:\ZCodeHome\.zcode'
$Bak = "$Src.old-manual"

# 1) 镜像同步两遍（/MIR 含清理目标残留，见坑 I）
robocopy $Src $Dst /MIR /COPY:DAT /DCOPY:DAT /R:2 /W:2 /XJ /MT:16 /NFL /NDL /NP
robocopy $Src $Dst /MIR /COPY:DAT /DCOPY:DAT /R:2 /W:2 /XJ /MT:16 /NFL /NDL /NP

# 2) 校验（数字必须完全一致，否则停；深路径树(>260字符)用 GCI 计数会漏——精确校验用技能脚本）
$s = Get-ChildItem -LiteralPath $Src -Recurse -Force -File
$d = Get-ChildItem -LiteralPath $Dst -Recurse -Force -File
"源  : $($s.Count) 个文件, $([math]::Round(($s|Measure-Object Length -Sum).Sum/1MB,2)) MB"
"目标: $($d.Count) 个文件, $([math]::Round(($d|Measure-Object Length -Sum).Sum/1MB,2)) MB"

# 3) 改名留退路
Rename-Item -LiteralPath $Src -NewName (Split-Path $Bak -Leaf)

# 4) 建 Junction（失败就把 .old 改回去）
New-Item -ItemType Junction -Path $Src -Target $Dst

# 5) 确认
Get-Item -LiteralPath $Src -Force | Select-Object Name, LinkType, Target
```

---

# 第四部分：迁移后验证

## 4.1 验证清单（照着打勾）

```
【链接层】
□ 1. Get-Item "$env:USERPROFILE\.zcode" -Force 的 LinkType=Junction、Target=目标路径
□ 2. 经链接读取文件数 = 直读目标文件数（Junction 对读路径透明）
□ 3. 经链接能读到 cli\config.json、cli\db\db.sqlite（收尾脚本已自动做）

【空间层】
□ 4. C 盘剩余空间变大（用 [System.IO.DriveInfo] 差值 —— 别用递归统计，穿透假象）
□ 5. 目标盘剩余空间相应变小
□ 6. 删掉 .zcode.old-* 后 C 盘才真正释放全部空间（.old 在删之前是真占用）

【功能层】★最直观
□ 7. ZCode 正常启动
□ 8. 历史会话列表完整、旧会话能打开（db 就在迁移集里）
□ 9. 跨会话记忆还在（问一句"你还记得我之前让你记的事吗"）
□ 10. 插件列表完整、MCP/插件正常工作（plugins 缓存已在目标盘）
□ 11. 新开一个会话干点活，然后确认 %USERPROFILE%\.zcode 没有重新长成真实目录
```

验证 11 的命令（应显示 Junction 而不是真实目录）：

```powershell
Get-Item "$env:USERPROFILE\.zcode" -Force | Select-Object Name, LinkType, Target
```

## 4.2 清理备份（确认稳定运行数天后）

```powershell
# 先列出看看
Get-ChildItem -LiteralPath $env:USERPROFILE -Force -Directory -Filter '.zcode.old-*' |
    ForEach-Object { $_.FullName }
# 确认无误后逐个删除（去掉注释执行）
# Get-ChildItem -LiteralPath $env:USERPROFILE -Force -Directory -Filter '.zcode.old-*' |
#     Remove-Item -Recurse -Force
```

---

# 第五部分：常见问题

**Q1：设置界面的 dataBaseDir 能替代这一切吗？**
不能。它只管工作区级数据（③），`cli`（会话库/插件/记忆）仍锚定 `%USERPROFILE%\.zcode`。两者互补：③ 用设置改，② 用 Junction 搬。

**Q2：为什么不赌 `ZCODE_HOME` 等环境变量？**
见 1.3 节证据链。环境变量方案的前提是"所有相关代码路径都认"，而逆向只能证明它管一小块。Junction 无此风险。

**Q3：Junction 之后 ZCode 更新会出事吗？**
更新改的是安装目录（①），不动用户目录。但每次大版本更新后建议跑一次第二部分的测量，确认 `%USERPROFILE%\.zcode` 还是 Junction、C 盘没有重新长出真实目录。

**Q4：卸载重装 ZCode 呢？**
Junction 是文件系统对象，一般不受影响。但若某天发现 `.zcode` 变回了真实目录（被卸载程序删了重建），重新做一遍阶段二即可（数据都在目标盘）。

**Q5：应用运行中双击收尾脚本会怎样？**
被前置检查拦住，直接中止，零改动。守护是故意的。

**Q6：多 Windows 账户？**
每个账户各自的 `%USERPROFILE%\.zcode` 是独立数据，各迁各的。

**Q7：如果插件缓存里有硬链接（个别插件自带 node_modules 时），跨盘后失效吗？**
跨盘拷贝后硬链接自动退化为普通文件，功能无影响，只是插件间不再共享相同文件的存储。若某插件因此损坏，重装插件即可（重装会走新位置的正常流程）。

**Q8：会话库会不会越长越大，最后把目标盘也吃掉？**
会。定期（比如每月）跑第二部分测量。真正持续增长的是会话库 `db.sqlite` 与按天日志 `cli\log\`；`rollout` 的 `model-io-*.jsonl` 单文件可达几十 MB，但默认保留策略（`modelIoFullRetentionEnabled: false`，实测）会清理旧转录，不无限累积。

---

# 第六部分：踩坑实录

以下是实测踩到/验证过的坑，每条按"症状 → 原因 → 正确做法"排列：

**坑 A：PowerShell 5.1 + 无 BOM 的 UTF-8 脚本 = 中文全变乱码 + 语法报错**
症状：ps1 明明写对了，运行报"表达式或语句中包含意外的标记"。
原因：PS 5.1 对无 BOM 文件按系统 ANSI（GBK）解码。
正确做法：**ps1 保存为 UTF-8 with BOM**（`printf '\xef\xbb\xbf' | cat - 脚本 > 新文件` 即可补）。

**坑 B：批处理 LF-only 换行 = "半行执行"**
症状：`应用迁移.cmd` 运行时把 `rem ZCode` 执行成 `ode ...`、`chcp 65001` 执行成 `5001 ...`。
原因：Write 工具写出的是 LF 换行，cmd 解析批处理对 LF-only 极不友好。
正确做法：**批处理必须 CRLF**（`printf '...\r\n'` 逐行写），且内容尽量纯 ASCII；ps1 文件名含中文时，批处理里用 `for %%f in ("%~dp0ZCode-*.ps1")` 通配符定位，不把中文写进批处理。

**坑 C：锁占用必须实测，不能猜**
用独占打开探测（`[System.IO.File]::Open($path,'Open','Read','None')`，异常=被占用）。实测推翻直觉：`db.sqlite` 三件套确实锁着，但正在写的 `rollout\*.jsonl` 反而是 FREE 的（写入器按需开关句柄）。**凡是"哪些文件被锁"的判断，跑探测，别脑补。**

**坑 D：robocopy /XJ 之前先扫 reparse point**
`/XJ` 跳过 Junction 是防循环的保命参数，但如果源树内部本来就有 Junction/符号链接（比如某些工具装的），它们会被静默跳过 → 目标缺数据。先跑 `Get-ChildItem -Recurse -Attributes ReparsePoint` 扫一遍，确认为零再用 `/XJ`。

**坑 E：两遍 robocopy + 逐文件字典比对**
一遍拷贝期间文件还在被写动，第一遍结果必不干净；第二遍补齐。比对不用"总数+总字节"（两个文件同字节互换抓不到），用"相对路径→大小"字典逐文件比对。

**坑 F：应用内 agent 迁移宿主数据的死结**
agent 跑在 ZCode 里 → 不能杀宿主 → "完全退出后再搬"不可行 → 拆两阶段（运行中预拷贝 + 退出后收尾脚本）。收尾脚本必须自带"检测到 ZCode 运行就中止"的守护，并且**先在应用运行中实测一次守护逻辑**（此刻中止是零风险的），确认脚本本身没问题。

**坑 G：逆向大 bundle 的检索姿势**
对几百 MB 的 app.asar 找路径解析逻辑：`grep -b` 拿字节偏移 + `dd skip/count` 提取片段，比正则上下文匹配可靠（超长行上 `.{0,N}` 上下文正则会撞复杂度上限直接报错）。提取出的解析函数是"实证级证据"，比网上道听途说靠谱。

**坑 H：脚本与交付物的存放位置**
收尾脚本放目标盘根目录（两棵操作树之外）；操作脚本放临时工作目录。任何脚本都别放进源树或目标树内。

**坑 I：干净关闭后，源树反而变"干净"——收尾同步必须 /MIR，不能用 /E（实测首跑即中招）**
症状：收尾脚本在"ZCode 已完全退出、两遍增量同步完成后"，严格校验报 `目标多出: cli\db\db.sqlite-wal`、`db.sqlite-shm`、一个 shell 快照——"明明后台都关闭了，怎么还有差异？"
原因：**正因为关干净了**。应用运行中这些文件存在，被阶段一拷进了目标；干净关闭那一刻 SQLite 做 checkpoint——把 WAL 合并回主库并**删除** `-wal/-shm`（主库 mtime=关闭时刻为证）；shell 快照平时也会被轮换清理。`robocopy /E` 只增不删，目标里留下这些"源侧已合法消失的文件"的旧尸体。
为什么这拦截是对的：那个数 MB 的旧 WAL 若跟着 Junction 幸存，下次启动 ZCode 会拿它对已经 checkpoint 过的新主库做误恢复——**会话库有损坏风险**。严格校验在 Junction 建好之前把它拦下，是整套流程里价值最高的一次中止。
正确做法：收尾同步用 **`/MIR`**（镜像=复制差异+清理目标多余），目标必须成为源的精确镜像；阶段一（应用运行中）继续用 `/E` 即可，残留交给收尾兜底。教训：**"拷贝"语义和"镜像"语义的区别，在源树会自行删除文件的场景里是正确与错误的区别。**

---

# 附录 A：速查

```powershell
# ─── 关键路径 ───
"$env:USERPROFILE\.zcode"            # 用户级数据（本文主角，Junction 后物理在数据盘）
"$env:USERPROFILE\.zcode\cli\db"     # 会话库（★大头、运行中被锁）
"$env:USERPROFILE\.zcode\cli\rollout"  # 模型转录（★增长最快）
# 工作区级数据的根 = 设置里的 dataBaseDir（改它走应用自带迁移）

# ─── 判断是不是 Junction ───
Get-Item "$env:USERPROFILE\.zcode" -Force | Select-Object Name, LinkType, Target

# ─── 建 Junction（不需要管理员）───
New-Item -ItemType Junction -Path "$env:USERPROFILE\.zcode" -Target 'X:\目标路径\.zcode'

# ─── 删 Junction（只删链接不删数据，比 Remove-Item -Recurse 安全）───
cmd /c rmdir "$env:USERPROFILE\.zcode"

# ─── 安全复制（跳过 Junction；0-7 正常，≥8 才是失败）───
robocopy 源 目标 /E /COPY:DAT /DCOPY:DAT /R:2 /W:2 /XJ /MT:16 /NFL /NDL /NP

# ─── 源树内部链接扫描（/XJ 之前必做）───
Get-ChildItem -LiteralPath 源 -Recurse -Force -Attributes ReparsePoint

# ─── 文件锁探测（异常=被占用）───
try { $fs=[System.IO.File]::Open('文件','Open','Read','None'); $fs.Close(); 'FREE' } catch { 'LOCKED' }

# ─── C 盘空间验证（唯一不受 Junction 欺骗的方法）───
[System.IO.DriveInfo]::GetDrives() | Where-Object IsReady |
    ForEach-Object { '{0} 剩余 {1} GB' -f $_.Name, [math]::Round($_.AvailableFreeSpace/1GB,1) }
```

# 附录 B：回滚

```powershell
# 1) 删 Junction（不删目标盘数据）
cmd /c rmdir "$env:USERPROFILE\.zcode"
# 2) 把备份改回原名（时间戳以实际为准，Tab 补全）
Rename-Item -LiteralPath "$env:USERPROFILE\.zcode.old-<时间戳>" -NewName '.zcode'
# 3) 完成 —— 一切回到迁移前。目标盘那份副本可留可删。
```
