# ================================================================
# measure.ps1 — ZCode 用户级数据目录摸底（只读，不改任何东西）
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File measure.ps1 [-Src <路径>]
# 纪律: 每行必有输出，不允许"静默跳过"（缺了行的报告等于没测）
# 长路径: 深度统计走 .NET \\?\ 枚举（PS 5.1 的 Get-ChildItem -Recurse 对
#         >260 字符路径会静默漏文件）；reparse 扫描用不进链接的栈遍历。
# ================================================================
param(
    [string]$Src = (Join-Path $env:USERPROFILE '.zcode')
)
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$Src = $Src.Trim('"').TrimEnd('\')

"════════ ZCode 数据目录摸底 ════════"
"源: $Src"

if (-not (Test-Path -LiteralPath $Src)) {
    "结果: 源目录不存在（未安装？或已迁移——用 Get-Item 查证历史 Junction）"
    exit 0
}
$i = Get-Item -LiteralPath $Src -Force
if ($i.LinkType) {
    "LinkType: $($i.LinkType)  ->  $($i.Target -join ',')"
    if ($i.LinkType -eq 'Junction') { "提示: 已是 Junction，迁移已完成；本报告仅做状态与增长巡检" }
} else {
    "LinkType: 真实目录（未迁移）"
}

# ---- 只读枚举助手 ----
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
        "  [遍历出错] $($_.Exception.Message)"
    }
    return $found
}
function Get-TreeStats([string]$Path) {
    # 返回 @{Count; Bytes; MaxRel}；出错时打印提示并返回已统计的部分
    $r = @{ Count = 0; Bytes = [long]0; MaxRel = 0 }
    try {
        $pfx = '\\?\' + (Get-Item -LiteralPath $Path -Force).FullName
        foreach ($f in [System.IO.Directory]::EnumerateFiles($pfx, '*', [System.IO.SearchOption]::AllDirectories)) {
            $rel = $f.Substring($pfx.Length + 1)
            $r.Count++
            $r.Bytes += ([System.IO.FileInfo]$f).Length
            if ($rel.Length -gt $r.MaxRel) { $r.MaxRel = $rel.Length }
        }
    } catch {
        "  [枚举出错] $($_.Exception.Message)（以下数字为部分统计）"
    }
    return $r
}

# ---- 源树内部 reparse point ----
"---- 源树内部 reparse point ----"
$rp = @(Get-ReparsePoints $Src)
$deepOk = $true
if ($rp.Count) {
    "发现 $($rp.Count) 个（/XJ 会跳过它们 → 不能直接整树拷，先处理）:"
    $rp | Select-Object -First 10 | ForEach-Object { "  $_" }
    "⚠ 检测到内部链接，深度统计已跳过（防循环）"
    $deepOk = $false
} else {
    "0 个（/XJ 安全）"
}

# ---- 体积（每行必有输出）----
if ($deepOk) {
    "---- 体积 ----"
    function Show-Size([string]$Label, [string]$Path) {
        if (-not (Test-Path -LiteralPath $Path)) {
            ("{0,-34} {1}" -f $Label, "(不存在)")
            return
        }
        $s = Get-TreeStats $Path
        ("{0,-34} {1,9} MB  ({2} 个文件)" -f $Label, [math]::Round($s.Bytes/1MB,1), $s.Count)
    }
    $total = Get-TreeStats $Src
    ("{0,-34} {1,9} MB  ({2} 个文件)" -f ".zcode 总计", [math]::Round($total.Bytes/1MB,1), $total.Count)
    Show-Size "  cli\db (会话库,大头)"  (Join-Path $Src 'cli\db')
    Show-Size "  cli\artifacts"        (Join-Path $Src 'cli\artifacts')
    Show-Size "  cli\plugins"          (Join-Path $Src 'cli\plugins')
    Show-Size "  cli\log (按天滚动)"   (Join-Path $Src 'cli\log')
    Show-Size "  cli\rollout (模型转录)" (Join-Path $Src 'cli\rollout')
    Show-Size "  cli\exec"             (Join-Path $Src 'cli\exec')
    Show-Size "  cli\memories"         (Join-Path $Src 'cli\memories')
    Show-Size "  cli\agents"           (Join-Path $Src 'cli\agents')
    Show-Size "  cli\image-cache"      (Join-Path $Src 'cli\image-cache')
    Show-Size "  cli\pdf-cache"        (Join-Path $Src 'cli\pdf-cache')
    Show-Size "  cli\node-fallback"    (Join-Path $Src 'cli\node-fallback')
    Show-Size "  v2 (引导配置+凭据)"    (Join-Path $Src 'v2')

    # ---- 深路径自检 ----
    "---- 最深相对路径 ----"
    if ($total.MaxRel -gt 240) {
        "$($total.MaxRel) 字符  ⚠ 偏深：目标根路径必须选短的（余量 $($total.MaxRel + 20 - 260) 字符以内）"
    } else {
        "$($total.MaxRel) 字符（安全，含目标开销后远离 260 上限）"
    }
}

# ---- 磁盘 ----
"---- 磁盘剩余空间 ----"
[System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady } | ForEach-Object {
    "{0}  剩余 {1,8} GB  ({2})" -f $_.Name, [math]::Round($_.AvailableFreeSpace/1GB,1), $_.DriveFormat
}

# ---- 锁探测（独占打开；异常 = 被占用）----
"---- 关键文件锁探测 ----"
foreach ($rel in @('cli\db\db.sqlite','cli\db\db.sqlite-wal','cli\db\db.sqlite-shm','cli\config.json','v2\setting.json')) {
    $f = Join-Path $Src $rel
    if (Test-Path -LiteralPath $f -PathType Leaf) {
        try { $fs = [System.IO.File]::Open($f,'Open','Read','None'); $fs.Close(); "FREE    $rel" }
        catch { "LOCKED  $rel  ($($_.Exception.GetType().Name))" }
    } else {
        "缺失    $rel"
    }
}

# ---- 进程 ----
"---- ZCode 进程 ----"
$z = @(Get-Process -Name 'ZCode' -ErrorAction SilentlyContinue)
if ($z.Count) { "运行中 (PID: $($z.Id -join ', ')) —— 阶段二收尾须完全退出（含托盘）" }
else { "未运行" }

"---- 提示 ----"
"若计划迁移: 目标盘剩余空间应 ≥ 源体积 × 1.2；目标路径给到 .zcode 这一层；NTFS、无中文空格、非 OneDrive"
