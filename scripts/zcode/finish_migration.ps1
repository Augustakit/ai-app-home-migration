# ================================================================
# finish_migration.ps1 — 阶段二：收尾（前提: ZCode 已完全退出含托盘）
# 动作: 守护→前置检查→清理预告→/MIR 镜像×2→零差异严格校验→原目录改名留回滚
#       →建 Junction→自检；任何一步失败立即中止并回滚，绝不删除源数据
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File finish_migration.ps1 `
#         -Dst "<目标\.zcode>" [-Src "<源>"] [-ZcodeExe "<ZCode.exe 完整路径>"]
# 关键: 同步必须 /MIR——应用干净关闭会合法删除文件（SQLite checkpoint 删
#       -wal/-shm、shell 快照轮换），目标旧拷贝必须清掉，旧 WAL 幸存有
#       会话库误恢复（损坏）风险。
# 长路径: 文件枚举统一走 .NET \\?\ 前缀（PS 5.1 的 Get-ChildItem -Recurse
#         对 >260 字符路径会静默漏文件）；reparse 扫描用不进链接的栈遍历。
# ================================================================
param(
    [string]$Src = (Join-Path $env:USERPROFILE '.zcode'),
    [string]$Dst = '',
    [string]$ZcodeExe = ''
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

function Abort([string]$msg) {
    ""
    "[中止] $msg"
    "未做任何破坏性改动（或已回滚）。源目录原样保留。"
    exit 1
}

# 入参规整: 去包裹引号、去尾部反斜杠；必填缺失显式报错（不用 Mandatory 提示——非交互场景会挂起）
$Src = $Src.Trim('"').TrimEnd('\')
$Dst = $Dst.Trim('"').TrimEnd('\')
$ZcodeExe = $ZcodeExe.Trim('"')
if (-not $Dst) { Abort "缺少 -Dst（目标 .zcode 完整路径，如 X:\ZCodeHome\.zcode）" }
if ($Src -match '^[A-Za-z]:$' -or $Dst -match '^[A-Za-z]:$') { Abort "源/目标不能是盘根，必须指向具体目录" }

# ---- 只读枚举助手（与本技能其他脚本保持同一实现）----
function Get-ReparsePoints([string]$Path) {
    # 手工栈遍历：不进入 reparse 目录（防循环），\\?\ 前缀（长路径安全）
    $found = @()
    try {
        $stack = [System.Collections.Generic.Stack[string]]::new()
        $stack.Push((Get-Item -LiteralPath $Path -Force).FullName)
        while ($stack.Count -gt 0) {
            $dir = $stack.Pop()
            foreach ($d in [System.IO.Directory]::EnumerateDirectories('\\?\' + $dir)) {
                $short = $d.Substring(4)
                if ([System.IO.File]::GetAttributes($d) -band [System.IO.FileAttributes]::ReparsePoint) { $found += $short }
                else { $stack.Push($short) }
            }
        }
    } catch {
        Abort "遍历 ${Path} 时出错: $($_.Exception.Message)"
    }
    return $found
}
function Get-SizeMap([string]$Path) {
    # .NET \\?\ 枚举：长路径安全
    $map = @{}
    try {
        $pfx = '\\?\' + (Get-Item -LiteralPath $Path -Force).FullName
        foreach ($f in [System.IO.Directory]::EnumerateFiles($pfx, '*', [System.IO.SearchOption]::AllDirectories)) {
            $map[$f.Substring($pfx.Length + 1)] = ([System.IO.FileInfo]$f).Length
        }
    } catch {
        Abort "枚举 ${Path} 出错: $($_.Exception.Message) —— 先处理权限/占用问题再重跑"
    }
    return $map
}
function Restore-FromBackup([string]$BakPath) {
    # 回滚辅助：删链接/清空重建目录 → 把备份改名回原位
    # 返回 'ok' 已回滚 / 'blocked' 发现被重建的非空 .zcode（不敢覆盖，交人工）/ 'missing' 备份不存在
    if (Test-Path -LiteralPath $Src) {
        $it = Get-Item -LiteralPath $Src -Force
        if ($it.LinkType) {
            cmd /c rmdir "$Src" 2>$null
        } elseif (@(Get-ChildItem -LiteralPath $Src -Recurse -Force -File -ErrorAction SilentlyContinue).Count -gt 0) {
            return 'blocked'
        } else {
            Remove-Item -LiteralPath $Src -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not (Test-Path -LiteralPath $BakPath)) { return 'missing' }
    Rename-Item -LiteralPath $BakPath -NewName '.zcode' -ErrorAction Stop
    return 'ok'
}

"════════ ZCode 数据迁移收尾 ════════"
"源  : $Src"
"目标: $Dst"
""

# ---------- 0. 前置检查 ----------
$zcode = Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue
if ($zcode) {
    Abort "检测到 ZCode 仍在运行 (PID: $($zcode.Id -join ', '))。请完全退出 ZCode（含托盘图标）后重跑本脚本。"
}
"[OK] ZCode 已完全退出"

if (-not (Test-Path -LiteralPath $Src)) { Abort "源目录不存在: $Src" }
$srcItem = Get-Item -LiteralPath $Src -Force
if ($srcItem.LinkType -eq 'Junction') {
    "[OK] 源已是 Junction → $($srcItem.Target)"
    "迁移早已完成，无需重复执行。"
    exit 0
}
if ($srcItem.LinkType) { Abort "源是其他类型的链接 ($($srcItem.LinkType))，请人工检查" }
if (-not (Test-Path -LiteralPath $Dst)) { Abort "目标不存在: $Dst（阶段一预拷贝未完成？）" }
$dstItem = Get-Item -LiteralPath $Dst -Force
if ($dstItem.LinkType) { Abort "目标是链接 ($($dstItem.LinkType))，配置异常，请人工检查" }

# 路径陷阱与目标盘类型（Junction 只支持本地固定 NTFS 盘）
$fullSrc = [System.IO.Path]::GetFullPath($Src.TrimEnd('\') + '\')
$fullDst = [System.IO.Path]::GetFullPath($Dst.TrimEnd('\') + '\')
if ($fullSrc -eq $fullDst) { Abort "源与目标相同" }
if ($fullDst.StartsWith($fullSrc, 'OrdinalIgnoreCase')) { Abort "目标在源树内部" }
if ($fullSrc.StartsWith($fullDst, 'OrdinalIgnoreCase')) { Abort "源在目标树内部" }
$root = [System.IO.Path]::GetPathRoot($fullDst)
if ($root -like '\\*') { Abort "目标不能是网络路径（UNC）——Junction 只支持本地固定磁盘" }
$drv = [System.IO.DriveInfo]($root.Substring(0,3))
if ($drv.DriveType -ne 'Fixed') { Abort "目标盘必须是本地固定磁盘（当前: $($drv.DriveType)）" }
if ($drv.DriveFormat -ne 'NTFS') { Abort "目标盘必须是 NTFS（当前: $($drv.DriveFormat)）" }

# 源树内部 reparse point：发现即中止（/MIR 与长路径枚举都不安全）
$rp = @(Get-ReparsePoints $Src)
if ($rp.Count) {
    Abort "源树内部发现 $($rp.Count) 个 reparse point（首见: $($rp[0])）。本技能面向无内部链接的场景：请先处理它们（迁移完成后可在目标树内重建），否则同步与枚举都不可靠。"
}

$oldDirs = @(Get-ChildItem -LiteralPath $env:USERPROFILE -Force -Directory -Filter '.zcode.old-*' -ErrorAction SilentlyContinue)
if ($oldDirs.Count) {
    "[警告] 已存在历史备份目录: $($oldDirs.FullName -join '; ')"
    "        本次将使用新的时间戳命名，互不影响。"
}

# ---------- 1. 清理预告：目标侧残留（源已合法删除的文件旧拷贝） ----------
$preSm = Get-SizeMap $Src
$preDm = Get-SizeMap $Dst
$extras = @($preDm.Keys | Where-Object { -not $preSm.ContainsKey($_) })
if ($extras.Count) {
    "[预告] 将清理目标侧 $($extras.Count) 个残留（应用关闭/轮换时合法删除的文件旧拷贝，如 db.sqlite-wal、shell 快照）:"
    $extras | Select-Object -First 20 | ForEach-Object { "    - $_" }
} else {
    "[OK] 无目标残留"
}

# ---------- 2. 镜像同步（/MIR = 复制差异 + 清理目标多余，两遍） ----------
function Sync-Pass([string]$label) {
    "[同步] $label ..."
    & robocopy $Src $Dst /MIR /COPY:DAT /DCOPY:DAT /R:2 /W:2 /XJ /MT:16 /NFL /NDL /NP | Out-Null
    $code = $LASTEXITCODE
    if ($code -ge 8) { Abort "robocopy 失败（退出码 $code）。源目录未改动。" }
}
Sync-Pass "第 1 遍镜像（拷贝差异 + 清理残留）"
Sync-Pass "第 2 遍镜像（补第一遍期间的写动）"

# ---------- 3. 严格校验（应用已退出，不允许任何差异） ----------
"[校验] 逐文件比对 ..."
$sm = Get-SizeMap $Src
$dm = Get-SizeMap $Dst
$mismatch = @()
foreach ($k in $sm.Keys) {
    if (-not $dm.ContainsKey($k)) { $mismatch += "缺少: $k" }
    elseif ($dm[$k] -ne $sm[$k])  { $mismatch += "大小不同: $k (源 $($sm[$k]) / 目标 $($dm[$k]))" }
}
foreach ($k in $dm.Keys) { if (-not $sm.ContainsKey($k)) { $mismatch += "目标多出: $k" } }
if ($mismatch.Count) {
    $mismatch | Select-Object -First 20 | ForEach-Object { "  $_" }
    Abort "严格校验未通过（共 $($mismatch.Count) 处差异）。/MIR 后仍不一致属真异常：请关闭所有可能占用 .zcode 的程序（资源管理器窗口、终端、编辑器、杀软实时扫描）后重跑。"
}
$srcBytes = ($sm.Values | Measure-Object -Sum).Sum
"[OK] 校验一致: $($sm.Count) 个文件, $([math]::Round($srcBytes/1MB,1)) MB"

# ---------- 4. 原目录改名（留回滚退路，不删除） ----------
$Bak = "$Src.old-$Stamp"
"[改名] $Src  →  $Bak"
try {
    Rename-Item -LiteralPath $Src -NewName (Split-Path $Bak -Leaf) -ErrorAction Stop
} catch {
    Abort "改名失败: $($_.Exception.Message)`n常见原因: 有资源管理器窗口/终端/编辑器停留在 .zcode 目录内，请全部关闭后重跑。"
}

# ---------- 5. 创建 Junction（失败则回滚改名） ----------
"[链接] New-Item Junction $Src → $Dst"
try {
    New-Item -ItemType Junction -Path $Src -Target $Dst -ErrorAction Stop | Out-Null
} catch {
    $r = Restore-FromBackup $Bak
    if ($r -eq 'ok') { Abort "创建 Junction 失败，已回滚: $($_.Exception.Message)" }
    if ($r -eq 'blocked') { Abort "创建 Junction 失败，且发现被重建的非空 .zcode，未自动回滚。真实数据在备份: $Bak —— 请人工检查。" }
    Abort "创建 Junction 失败，回滚受阻（备份不存在？）。请人工检查 $Bak 与 $Src。"
}
$link = Get-Item -LiteralPath $Src -Force
if ($link.LinkType -ne 'Junction') {
    $r = Restore-FromBackup $Bak
    if ($r -eq 'ok') { Abort "Junction 校验失败 (LinkType='$($link.LinkType)')，已回滚" }
    Abort "Junction 校验失败且回滚受阻（$r）。请人工检查 $Bak 与 $Src。"
}
"[OK] $Src → $($link.Target)"

# ---------- 6. 自检 ----------
"[自检] 通过 Junction 读取数据 ..."
$viaLink = @(Get-ChildItem -LiteralPath $Src -Recurse -Force -File -ErrorAction SilentlyContinue)
$direct  = @(Get-ChildItem -LiteralPath $Dst -Recurse -Force -File -ErrorAction SilentlyContinue)
if ($viaLink.Count -ne $direct.Count) {
    "  经链接: $($viaLink.Count)  直接: $($direct.Count)"
    $r = Restore-FromBackup $Bak
    if ($r -eq 'ok') { Abort "经 Junction 读到的文件数与目标不一致，已回滚" }
    Abort "自检不一致且回滚受阻（$r）。请人工检查 $Bak 与 $Src。"
}
$cfg = Join-Path $Src 'cli\config.json'
if (-not (Test-Path -LiteralPath $cfg)) {
    $r = Restore-FromBackup $Bak
    if ($r -eq 'ok') { Abort "经 Junction 读不到 cli\config.json，已回滚" }
    Abort "自检失败且回滚受阻（$r）。请人工检查 $Bak 与 $Src。"
}
$db = Get-Item -LiteralPath (Join-Path $Src 'cli\db\db.sqlite') -Force -ErrorAction SilentlyContinue
"[OK] 经 Junction 读取 $($viaLink.Count) 个文件正常"
if ($db) { "[OK] 会话库可见: $([math]::Round($db.Length/1MB,1)) MB" }

# ---------- 7. 完成 ----------
""
"════════ 迁移完成 ════════"
"C 盘原数据已整体改名保留为: $Bak"
"  · 建议正常使用 ZCode 数天后再删除它（届时 C 盘才真正释放空间）"
"  · 确认无误后的删除命令（去掉行首 # 再执行）:"
"    # Remove-Item -LiteralPath '$Bak' -Recurse -Force"
""
if ($ZcodeExe -and (Test-Path -LiteralPath $ZcodeExe)) {
    $ans = Read-Host "是否现在启动 ZCode? (y/n)"
    if ($ans -eq 'y') { Start-Process -FilePath $ZcodeExe }
} elseif ($ZcodeExe) {
    "未找到 $ZcodeExe ，请手动启动 ZCode。"
}
