# ================================================================
# precopy.ps1 — 阶段一：预拷贝 + 校验（应用运行中可安全执行）
# 拷走的是"热快照"，活跃文件差异属预期，由收尾脚本 /MIR 最终兜底。
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File precopy.ps1 -Dst "<目标\.zcode>" [-Src <路径>]
# 长路径: 文件枚举统一走 .NET \\?\ 前缀（PS 5.1 的 Get-ChildItem -Recurse
#         对 >260 字符路径会静默漏文件）；reparse 扫描用不进链接的栈遍历。
# ================================================================
param(
    [string]$Src = (Join-Path $env:USERPROFILE '.zcode'),
    [string]$Dst = ''
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# 入参规整: 去包裹引号、去尾部反斜杠；必填缺失显式报错（不用 Mandatory——非交互场景会挂起）
$Src = $Src.Trim('"').TrimEnd('\')
$Dst = $Dst.Trim('"').TrimEnd('\')
if (-not $Dst) { throw "缺少 -Dst（目标 .zcode 完整路径，如 X:\ZCodeHome\.zcode）" }
if ($Src -match '^[A-Za-z]:$' -or $Dst -match '^[A-Za-z]:$') { throw "源/目标不能是盘根，必须指向具体目录" }

"════════ 阶段一：预拷贝 ════════"
"源  : $Src"
"目标: $Dst"

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
        throw "遍历 ${Path} 时出错: $($_.Exception.Message) —— 先处理权限问题再重跑"
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
        throw "枚举 ${Path} 出错: $($_.Exception.Message) —— 先处理权限/占用问题再重跑"
    }
    return $map
}

# ---- 前置检查 ----
if (-not (Test-Path -LiteralPath $Src)) { throw "源不存在: $Src" }
$srcItem = Get-Item -LiteralPath $Src -Force
if ($srcItem.LinkType) { throw "源已是链接（$($srcItem.LinkType)），无需迁移" }
$fullSrc = [System.IO.Path]::GetFullPath($Src.TrimEnd('\') + '\')
$fullDst = [System.IO.Path]::GetFullPath($Dst.TrimEnd('\') + '\')
if ($fullSrc -eq $fullDst) { throw "源与目标相同" }
if ($fullDst.StartsWith($fullSrc, 'OrdinalIgnoreCase')) { throw "目标在源树内部——换到源树之外" }
if ($fullSrc.StartsWith($fullDst, 'OrdinalIgnoreCase')) { throw "源在目标树内部——换目标" }

# 源树内部 reparse point：发现即停（/XJ 会跳过它们；且后续枚举不安全）
$rp = @(Get-ReparsePoints $Src)
if ($rp.Count) { throw "源树内部发现 $($rp.Count) 个 reparse point（首见: $($rp[0])）。/XJ 会跳过它们导致缺数据，请先处理再重跑。" }

# 目标盘类型与空间
$root = [System.IO.Path]::GetPathRoot($fullDst)
if ($root -like '\\*') { throw "目标不能是网络路径（UNC）——Junction 只支持本地固定磁盘" }
$drive = [System.IO.DriveInfo]($root.Substring(0,3))
if ($drive.DriveType -ne 'Fixed') { throw "目标盘必须是本地固定磁盘（当前: $($drive.DriveType)）" }
if ($drive.DriveFormat -ne 'NTFS') { throw "目标盘必须是 NTFS（当前: $($drive.DriveFormat)）" }
# 源体积用 .NET 枚举（与校验同源；GCI 对长路径树会低估）
$smPre = Get-SizeMap $Src
$srcBytes = ($smPre.Values | Measure-Object -Sum).Sum
if ($null -eq $srcBytes) { $srcBytes = 0 }
"源体积: $([math]::Round($srcBytes/1MB,1)) MB（$($smPre.Count) 个文件）    目标盘($($drive.Name))剩余: $([math]::Round($drive.AvailableFreeSpace/1GB,1)) GB"
if ($drive.AvailableFreeSpace -lt $srcBytes * 1.2) { throw "目标盘剩余空间不足（需 ≥ 源体积 × 1.2）" }

New-Item -ItemType Directory -Path $Dst -Force | Out-Null

# ---- robocopy 两遍（第二遍补第一遍期间的写动）----
foreach ($pass in 1..2) {
    "robocopy pass $pass ..."
    & robocopy $Src $Dst /E /COPY:DAT /DCOPY:DAT /R:2 /W:2 /XJ /MT:16 /NFL /NDL /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy 失败（退出码 $LASTEXITCODE；0-7 均为正常）" }
}

# ---- 逐文件大小字典比对 ----
$sm = Get-SizeMap $Src
$dm = Get-SizeMap $Dst
"源  : $($sm.Count) 个文件    目标: $($dm.Count) 个文件"

$missing = @(); $diff = @(); $extra = @()
foreach ($k in $sm.Keys) {
    if (-not $dm.ContainsKey($k)) { $missing += $k }
    elseif ($dm[$k] -ne $sm[$k])  { $diff += "$k (源 $($sm[$k]) / 目标 $($dm[$k]))" }
}
foreach ($k in $dm.Keys) { if (-not $sm.ContainsKey($k)) { $extra += $k } }

# 活跃白名单: 应用正在写/即将合法删除的文件，差异属预期，收尾 /MIR 兜底
$livePatterns = @('^cli\\db\\db\.sqlite', '^cli\\rollout\\', '^cli\\log\\', '^v2\\logs\\')
function Test-Live([string]$rel) {
    foreach ($p in $livePatterns) { if ($rel -match $p) { return $true } }
    return $false
}
$liveMissing = @($missing | Where-Object { Test-Live $_ })
$liveDiff    = @($diff    | Where-Object { Test-Live (($_ -split ' ')[0]) })
$liveExtra   = @($extra   | Where-Object { Test-Live $_ })
$badMissing  = @($missing | Where-Object { -not (Test-Live $_) })
$badDiff     = @($diff    | Where-Object { -not (Test-Live (($_ -split ' ')[0])) })
$badExtra    = @($extra   | Where-Object { -not (Test-Live $_) })

if ($liveMissing.Count) { "[预期内·活跃] 目标缺少(前10/共$($liveMissing.Count)): $(@($liveMissing | Select-Object -First 10) -join '; ')" }
if ($liveDiff.Count)    { "[预期内·活跃] 大小不同(前10/共$($liveDiff.Count)): $(@($liveDiff | Select-Object -First 10) -join '; ')" }
if ($liveExtra.Count)   { "[预期内·活跃] 目标多出(前10/共$($liveExtra.Count)): $(@($liveExtra | Select-Object -First 10) -join '; ')" }

if ($badMissing.Count -or $badDiff.Count -or $badExtra.Count) {
    "[!!] 非预期差异:"
    if ($badMissing.Count) { "  缺少(前10/共$($badMissing.Count)): $(@($badMissing | Select-Object -First 10) -join '; ')" }
    if ($badDiff.Count)    { "  大小不同(前10/共$($badDiff.Count)): $(@($badDiff | Select-Object -First 10) -join '; ')" }
    if ($badExtra.Count)   { "  多出(前10/共$($badExtra.Count)): $(@($badExtra | Select-Object -First 10) -join '; ')" }
    throw "校验存在非预期差异。重跑本脚本是安全的（增量）；反复失败则排查占用方。"
}

$dstBytes = ($dm.Values | Measure-Object -Sum).Sum
$srcBytesFinal = ($sm.Values | Measure-Object -Sum).Sum
"════ 校验通过 ════"
"源  总字节: $srcBytesFinal ($([math]::Round($srcBytesFinal/1MB,1)) MB)"
"目标总字节: $dstBytes ($([math]::Round($dstBytes/1MB,1)) MB)"
"下一步: 部署收尾脚本到目标盘根 → ZCode 完全退出后执行收尾（见 SKILL.md 第 3-4 步）"
