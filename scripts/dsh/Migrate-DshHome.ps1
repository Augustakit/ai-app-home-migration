<#
  DSH 数据目录整目录迁移（Windows PowerShell 5.1，无第三方运行时）

  做法：把 %USERPROFILE%\.dsh（或 DSH_HOME 指向的目录）整体复制到目标盘，
  逐文件校验、原目录改名留退路、在原位置建 Junction、写入探针验证，
  最后可选把用户级 DSH_HOME 指到新目录（-SetDshHome）。

  默认演练：加 -WhatIf 只打印计划，不改任何文件。
  正式迁移：去掉 -WhatIf。迁移前必须完全退出 DSH。

  示例：
    .\Migrate-DshHome.ps1 -TargetRoot 'E:\DSHData\.dsh' -WhatIf
    .\Migrate-DshHome.ps1 -TargetRoot 'E:\DSHData\.dsh'
    .\Migrate-DshHome.ps1 -TargetRoot 'E:\DSHData\.dsh' -SetDshHome
    .\Migrate-DshHome.ps1 -TargetRoot 'E:\DSHData\.dsh' -CleanupBackup

  退路默认保留；确认 DSH 正常后，用 -CleanupBackup 再运行一次安全清理。
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$TargetRoot,
  [string]$SourceRoot = '',
  [switch]$SetDshHome,
  [switch]$CleanupBackup,
  [string]$BackupSuffix = '.dshbak',
  [string]$StateDir = '',
  [switch]$AllowLongPaths,
  [switch]$SkipProcessGuard,
  [switch]$SkipDshHomeGuard,
  [switch]$AllowPartial
)

$ErrorActionPreference = 'Stop'
# -WhatIf 只用于本脚本的预检分支；置 false 以免它沿管道传给只读 cmdlet
# （Get-CimInstance/Get-PSDrive 等在 -WhatIf 下会返回空/0，造成假失败）。
$PlanOnly = [bool]$WhatIfPreference
$WhatIfPreference = $false
$ToolName = 'dsh-home-migration'
$ToolVersion = '2.0.0'
$DshHomeEnv = 'DSH_HOME'

function Say([string]$Text) { Write-Host $Text }

function Write-JsonFile([string]$Path, $Data) {
  $json = ($Data | ConvertTo-Json -Depth 5)
  [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function TrimPath([string]$Path) {
  if ([string]::IsNullOrEmpty($Path)) { return $Path }
  return $Path.TrimEnd([char]92, [char]47)
}

function Get-DataRoot {
  if (-not [string]::IsNullOrWhiteSpace($SourceRoot)) { return $SourceRoot }
  if (-not [string]::IsNullOrWhiteSpace($env:DSH_HOME)) { return $env:DSH_HOME }
  return (Join-Path $env:USERPROFILE '.dsh')
}

function Assert-NoPlaceholders([string]$Value, [string]$Name) {
  if ($Value -match '<[A-Za-z_][A-Za-z0-9_]*>') {
    throw "$Name 里还有未替换的占位符：$Value（尖括号在 Windows 路径中非法）"
  }
}

function Test-IsReparse($Item) {
  if ($null -eq $Item) { return $false }
  if ($Item.LinkType) { return $true }
  return (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Get-TreeMap([string]$Root) {
  # .NET \\?\ 枚举：PS 5.1 的 Get-ChildItem -Recurse 对 >260 字符路径会静默漏文件。
  # 调用前必须已确认源树内部没有 reparse point（见 Get-ReparsePoints）。
  $map = @{}
  $full = (Get-Item -LiteralPath $Root -Force).FullName
  $pfx = '\\?\' + $full
  foreach ($f in [System.IO.Directory]::EnumerateFiles($pfx, '*', [System.IO.SearchOption]::AllDirectories)) {
    $map[$f.Substring($pfx.Length + 1)] = [int64]([System.IO.FileInfo]$f).Length
  }
  return $map
}

function Get-ReparsePoints([string]$Root) {
  # 手工栈遍历：不进入 reparse 目录（防循环/死链），\\?\ 前缀（长路径安全）。
  # 同时检查文件级 reparse（符号链接文件）；它们同样会被 /XJ 或读取逻辑跳过。
  $found = @()
  $stack = [System.Collections.Generic.Stack[string]]::new()
  $stack.Push((Get-Item -LiteralPath $Root -Force).FullName)
  while ($stack.Count -gt 0) {
    $dir = $stack.Pop()
    foreach ($d in [System.IO.Directory]::EnumerateDirectories('\\?\' + $dir)) {
      $short = $d.Substring(4)
      if ([System.IO.File]::GetAttributes($d) -band [System.IO.FileAttributes]::ReparsePoint) {
        $found += $short
      } else {
        $stack.Push($short)
      }
    }
    foreach ($f in [System.IO.Directory]::EnumerateFiles('\\?\' + $dir)) {
      if ([System.IO.File]::GetAttributes($f) -band [System.IO.FileAttributes]::ReparsePoint) {
        $found += $f.Substring(4)
      }
    }
  }
  return $found
}

function Get-TreeBytes([hashtable]$Map) {
  [int64]$sum = 0
  foreach ($v in $Map.Values) { $sum += [int64]$v }
  return $sum
}

function Get-MaxRelativeLength([hashtable]$Map) {
  $max = 0
  foreach ($k in $Map.Keys) { if ($k.Length -gt $max) { $max = $k.Length } }
  return $max
}

function Get-DshProcesses {
  return @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like '*DeepSeek*' })
}

function Get-LongPathsEnabled {
  try {
    $v = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -ErrorAction Stop
    return [int]$v.LongPathsEnabled
  } catch {
    return -1
  }
}

function Get-VolumeInfo([string]$Path) {
  # 用 .NET DriveInfo 而不是 Get-CimInstance：CIM 在 -WhatIf 下会继承 WhatIf
  # 并返回空结果，导致演练被误判为“无法读取目标盘”。DriveInfo 不受影响。
  try {
    $root = [System.IO.Path]::GetPathRoot($Path)
    $di = New-Object System.IO.DriveInfo($root)
    return [pscustomobject]@{
      DriveType = [int]$di.DriveType
      FileSystem = $di.DriveFormat
      Name = $root.TrimEnd('\')
      FreeSpace = [int64]$di.AvailableFreeSpace
    }
  } catch {
    return $null
  }
}

function Get-TargetFreeBytes([string]$Path) {
  $drive = ([System.IO.Path]::GetPathRoot($Path)).TrimEnd([char]92)
  $d = Get-PSDrive -Name $drive.TrimEnd([char]58) -ErrorAction SilentlyContinue
  if ($null -eq $d) { return $null }
  return [int64]$d.Free
}

function Get-UserDshHome {
  try { return [Environment]::GetEnvironmentVariable($DshHomeEnv, 'User') } catch { return $null }
}

function Remove-BackupSafely([string]$BakPath, [string]$TargetPath) {
  Say ''
  Say "退路：$BakPath"
  Say '清理前先核对：退路中的每个文件都必须在目标盘存在且大小一致。'
  $gateBad = @()
  $bakFiles = @(Get-ChildItem -LiteralPath $BakPath -Recurse -Force -File -ErrorAction SilentlyContinue |
                Where-Object { -not (Test-IsReparse $_) })
  foreach ($f in $bakFiles) {
    $rel = $f.FullName.Substring((TrimPath $BakPath).Length + 1)
    $t = Join-Path $TargetPath $rel
    if (-not (Test-Path -LiteralPath $t)) { $gateBad += $rel; continue }
    if ((Get-Item -LiteralPath $t -Force).Length -ne $f.Length) { $gateBad += "$rel (size)" }
  }
  if ($gateBad.Count -gt 0) {
    Say "清理闸门未通过：目标盘缺少或大小不一致 $($gateBad.Count) 个文件，退路保留。"
    $gateBad | Select-Object -First 10 | ForEach-Object { Say "  $_" }
    return $false
  }
  Say "清理闸门通过：$($bakFiles.Count) 个文件都已在目标盘核对一致。"

  # 退路里可能含子链接：必须先非递归删链接，再删真实内容。
  $nestedLinks = @(Get-ChildItem -LiteralPath $BakPath -Recurse -Force -Directory -ErrorAction SilentlyContinue |
                   Where-Object { Test-IsReparse $_ })
  foreach ($l in $nestedLinks) {
    try { [System.IO.Directory]::Delete($l.FullName, $false) }
    catch { Say "无法移除嵌套链接，退路保留：$($l.FullName)"; return $false }
  }
  foreach ($it in @(Get-ChildItem -LiteralPath $BakPath -Force -ErrorAction SilentlyContinue)) {
    if (Test-IsReparse $it) {
      try {
        if ($it.PSIsContainer) { [System.IO.Directory]::Delete($it.FullName, $false) }
        else { [System.IO.File]::Delete($it.FullName) }
      } catch { Say "无法移除链接，退路保留：$($it.FullName)"; return $false }
    }
  }

  # 然后才能安全删真实内容（非链接）。
  foreach ($it in @(Get-ChildItem -LiteralPath $BakPath -Force -ErrorAction SilentlyContinue)) {
    if (Test-IsReparse $it) { continue }
    try {
      if ($it.PSIsContainer) {
        Get-ChildItem -LiteralPath $it.FullName -Recurse -Force -File -ErrorAction SilentlyContinue |
          ForEach-Object { try { [System.IO.File]::SetAttributes($_.FullName, [System.IO.FileAttributes]::Normal) } catch {} }
        [System.IO.Directory]::Delete($it.FullName, $true)
      } else {
        try { [System.IO.File]::SetAttributes($it.FullName, [System.IO.FileAttributes]::Normal) } catch {}
        [System.IO.File]::Delete($it.FullName)
      }
    } catch {
      Say "删除失败，退路保留：$($it.FullName) — $($_.Exception.Message)"
      return $false
    }
  }
  try { [System.IO.Directory]::Delete($BakPath, $false) } catch { Say "无法删除退路根目录：$($_.Exception.Message)"; return $false }
  Say '退路已安全清除，原位置只剩 Junction。'
  return $true
}

# ---------------------------------------------------------------- main flow
Say "=== DSH 数据目录迁移（$ToolName $ToolVersion）==="

$src = TrimPath ((Get-DataRoot).Trim().Trim('"'))
$dst = TrimPath ($TargetRoot.Trim().Trim('"'))
Assert-NoPlaceholders $src 'SourceRoot'
Assert-NoPlaceholders $dst 'TargetRoot'
if (-not [System.IO.Path]::IsPathRooted($src)) { throw "源目录必须是绝对路径：$src" }
if (-not [System.IO.Path]::IsPathRooted($dst)) { throw "目标目录必须是绝对路径：$dst" }
if ($src -match '^[A-Za-z]:\\?$' -or $dst -match '^[A-Za-z]:\\?$') {
  throw '源/目标不能是盘根，必须指向具体的数据目录（例如 D:\DSHData\.dsh）'
}
$fullSrc = [System.IO.Path]::GetFullPath($src.TrimEnd('\') + '\')
$fullDst = [System.IO.Path]::GetFullPath($dst.TrimEnd('\') + '\')
if ([string]::Equals($fullSrc, $fullDst, [StringComparison]::OrdinalIgnoreCase)) { throw '源与目标是同一个目录' }
if ($fullDst.StartsWith($fullSrc, [StringComparison]::OrdinalIgnoreCase)) { throw '目标在源目录内部——会自我复制，已停止' }
if ($fullSrc.StartsWith($fullDst, [StringComparison]::OrdinalIgnoreCase)) { throw '源在目标目录内部——已停止' }
$bak = "$src$BackupSuffix"

Say ''
Say "源数据目录：$src"
Say "目标数据目录：$dst"
Say "退路（如已存在/迁移后）：$bak"

# 1) 源检查；已完成迁移时允许 -CleanupBackup 单独清退路
if (-not (Test-Path -LiteralPath $src -PathType Container)) {
  throw "源数据目录不存在：$src（如果 DSH_HOME 指错，请先修正）"
}
$srcItem = Get-Item -LiteralPath $src -Force
# 默认必须整目录（.dsh / DSH_HOME）：只迁子目录会让根目录继续在 C 盘长东西。
$looksLikeRoot = (Test-Path -LiteralPath (Join-Path $src 'profiles')) -and (Test-Path -LiteralPath (Join-Path $src 'storages'))
if (-not $looksLikeRoot -and $srcItem.Name -ne '.dsh' -and -not $AllowPartial) {
  throw "默认只迁移整个 DSH 数据根（包含 profiles/storages 的目录）；检测到 '$src' 不像完整数据根。确需只迁子目录请加 -AllowPartial，并接受根目录仍占原盘的代价。"
}
if (-not $looksLikeRoot -and $AllowPartial) { Say '警告：-AllowPartial 只迁部分数据；根目录仍会占原盘，以后新增内容仍可能落在原盘。' }
if (Test-IsReparse $srcItem) {
  $linkTarget = @($srcItem.Target)[0]
  Say "源目录已经是链接：$($srcItem.LinkType) -> $linkTarget"
  if ($CleanupBackup) {
    if (-not (Test-Path -LiteralPath $bak)) { Say "没有找到退路：$bak，无需清理。"; exit 0 }
    if (Remove-BackupSafely $bak $dst) { exit 0 } else { exit 1 }
  }
  Say '无需重复迁移。'
  if (Test-Path -LiteralPath $bak) {
    Say "退路仍在：$bak。确认 DSH 正常后，加 -CleanupBackup 再运行一次即可安全清理。"
  }
  exit 0
}

# 2) 进程守卫
if (-not $SkipProcessGuard) {
  $procs = Get-DshProcesses
  if ($procs.Count -gt 0) {
    Say "DSH 仍在运行（$($procs.Count) 个进程）：$($procs.ProcessName -join ', ')"
    if ($PlanOnly) {
      Say '演练（-WhatIf）允许应用运行；正式执行前必须完全退出 DSH。'
    } else {
      Say '请完全退出 DSH（窗口 + 托盘/后台进程）后再运行。脚本未改动任何文件。'
      exit 1
    }
  } else {
    Say '进程守卫通过：没有检测到 DSH 进程。'
  }
}

# 2b) 源树内部 reparse point：/XJ 会跳过它们 → 必须为零
$innerLinks = @(Get-ReparsePoints $src)
if ($innerLinks.Count -gt 0) {
  Say "源树内部发现 $($innerLinks.Count) 个 reparse point（链接/Junction）。"
  Say 'robocopy /XJ 会跳过它们，导致目标缺数据，且校验可能“假通过”。'
  $innerLinks | Select-Object -First 10 | ForEach-Object { Say "  $_" }
  throw '请先处理这些内部链接（迁移到目标后再重建，或排除在数据根之外），再重试。'
}
Say '源树内部 reparse point：0 个（/XJ 安全）。'

# 3) 目标检查；目标非空时进入续作模式（上次 Cutover 中途失败的恢复路径）
$ResumeCopy = $false
if (Test-Path -LiteralPath $dst) {
  $di = Get-Item -LiteralPath $dst -Force
  if (Test-IsReparse $di) { throw "目标路径本身是链接，拒绝操作：$dst" }
  if (@(Get-ChildItem -LiteralPath $dst -Force).Count -gt 0) {
    $ResumeCopy = $true
    Say "目标已存在且非空：$dst"
    Say '续作模式：跳过复制，先对源/目标做逐文件校验；一致则继续改名 + Junction，不一致则提示人工处理。'
  }
}
$vol = Get-VolumeInfo $dst
if ($null -eq $vol) { throw "无法读取目标盘信息：$dst" }
if ($vol.DriveType -ne 3) { throw "目标盘不是本地固定盘：$dst" }
if ($vol.FileSystem -ne 'NTFS') { throw "目标盘不是 NTFS，Junction 要求 NTFS：$dst" }

Say ''
Say '正在扫描源目录（只读，可能几秒）...'
$srcMap = Get-TreeMap $src
$srcBytes = Get-TreeBytes $srcMap
$maxRel = Get-MaxRelativeLength $srcMap
Say ("源目录：{0} 个文件，{1:N2} MB，最长相对路径 {2} 字符" -f $srcMap.Count, ($srcBytes / 1MB), $maxRel)

$free = [int64]$vol.FreeSpace
if ($null -eq $free) { throw "无法读取目标盘剩余空间：$dst" }
if (-not $ResumeCopy) {
  $needed = [int64]($srcBytes * 1.15)
  Say ("目标盘剩余：{0:N2} GB；需要至少 {1:N2} GB（源 × 1.15）" -f ($free / 1GB), ($needed / 1GB))
  if ($free -lt $needed) { throw "目标盘空间不足" }
} else {
  Say ("目标盘剩余：{0:N2} GB（续作模式：数据已在目标盘，跳过空间前置检查）" -f ($free / 1GB))
}

$longPaths = Get-LongPathsEnabled
$projected = $dst.Length + $maxRel
if ($longPaths -ne 1 -and $projected -gt 259) {
  if (-not $AllowLongPaths) { throw "目标路径预计最长 $projected 字符，超过 259（LongPathsEnabled=$longPaths）。请换短路径，或确认风险后加 -AllowLongPaths。" }
  Say "警告：预计最长路径 $projected 字符，已按 -AllowLongPaths 继续。"
} else {
  Say "路径长度检查：预计最长 $projected 字符（LongPathsEnabled=$longPaths）。"
}

# DSH_HOME 守卫：如果用户级 DSH_HOME 指向别处，Junction 不会被 DSH 使用
if (-not $SkipDshHomeGuard) {
  $userHome = Get-UserDshHome
  if (-not [string]::IsNullOrWhiteSpace($userHome)) {
    $u = TrimPath $userHome.Trim('"')
    $sameAsTarget = [string]::Equals((TrimPath ([System.IO.Path]::GetFullPath($u))), (TrimPath ([System.IO.Path]::GetFullPath($dst))), [StringComparison]::OrdinalIgnoreCase)
    if (-not $sameAsTarget -and -not $SetDshHome) {
      Say "注意：用户级 DSH_HOME 当前是 $u，不是本次目标 $dst。"
      Say '如果只建 Junction 而 DSH_HOME 不改，DSH 仍读 DSH_HOME 指向的目录。要同时切换，请加 -SetDshHome。'
      throw '为避免“搬了但 DSH 没用上”，已停止。'
    }
  }
}

if ($PlanOnly) {
  Say ''
  Say '【演练】将执行：'
  if ($ResumeCopy) {
    Say '  0. 续作模式：目标已有数据，跳过复制，先逐文件校验源/目标一致性'
    Say '  1. 原目录改名为退路（留退路）'
    Say "  2. 在 $src 建 Junction -> $dst"
    Say '  3. 写入探针，验证经原路径新建的文件出现在目标盘'
  } else {
    Say '  1. 改名探测（把源目录改名后立即改回，提前暴露目录句柄占用）'
    Say "  2. robocopy /E /XJ 复制 $($srcMap.Count) 个文件到 $dst"
    Say '  3. 逐文件比对相对路径 + 大小'
    Say "  4. 原目录改名为 $bak（留退路）"
    Say "  5. 在 $src 建 Junction -> $dst"
    Say '  6. 写入探针，验证经原路径新建的文件出现在目标盘'
  }
  if ($SetDshHome) { Say "  7. 设用户级 DSH_HOME=$dst" }
  Say '【演练】未改动任何文件。去掉 -WhatIf 才会正式执行。'
  exit 0
}

# 3b) 改名探测：目录句柄被资源管理器窗口/终端工作目录占用时，改名退路必然失败。
# 在复制之前把源目录改名后立即改回，把这类失败暴露在动手之前（未改动任何数据）。
Say ''
Say '--- 改名探测（提前暴露目录句柄占用）---'
$leaf = [System.IO.Path]::GetFileName($src.TrimEnd('\'))
$probeName = $leaf + '.__probe' + (Get-Random)
try {
  Rename-Item -LiteralPath $src -NewName $probeName -ErrorAction Stop
} catch {
  Say '改名探测失败：源目录句柄被外部进程占用，改名退路必然同样失败。'
  Say '常见原因：资源管理器窗口或某个终端的工作目录停在源目录（或其上级）。'
  Say '请关闭后重跑本脚本。未改动任何文件。'
  exit 1
}
$backOk = $false
foreach ($i in 1..3) {
  try {
    Rename-Item -LiteralPath (Join-Path (Split-Path -Parent $src) $probeName) -NewName $leaf -ErrorAction Stop
    $backOk = $true
    break
  } catch { Start-Sleep -Seconds 1 }
}
if (-not $backOk) {
  throw ("改名探测后无法把 {0} 改回 {1}（极少见）。请手工改回后重试。" -f (Join-Path (Split-Path -Parent $src) $probeName), $leaf)
}
Say '改名探测通过：源目录句柄未被占用。'

# 3c) 写 state（在复制/改名之前落盘，任何阶段失败都有回滚依据）
if ([string]::IsNullOrWhiteSpace($StateDir)) {
  $StateDir = Join-Path $env:LOCALAPPDATA 'dsh-migration'
}
New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$statePath = Join-Path $StateDir ("state-$stamp-$PID.json")
$envBefore = Get-UserDshHome
$state = [ordered]@{
  tool = $ToolName
  version = $ToolVersion
  createdAt = (Get-Date).ToString('s')
  status = 'preparing'
  mode = 'junction'
  source = $src
  target = $dst
  backup = $bak
  resume = [bool]$ResumeCopy
  setDshHome = [bool]$SetDshHome
  envBefore = $envBefore
  envAfter = $null
  files = $srcMap.Count
  bytes = $srcBytes
  copied = [bool]$ResumeCopy
  verified = $false
  junctionCreated = $false
}
Write-JsonFile $statePath $state
Say ''
Say "回滚状态文件：$statePath"

# 4) 复制（续作模式跳过：上次已复制并校验过，直接进入校验确认）
if ($ResumeCopy) {
  Say ''
  Say '--- 续作：跳过复制，直接进入逐文件校验 ---'
} else {
  Say ''
  Say '--- 开始复制 ---'
  New-Item -ItemType Directory -Path $dst -Force | Out-Null
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  & robocopy $src $dst /E /COPY:DAT /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "复制失败，robocopy 退出码 $LASTEXITCODE。源目录未改动。回滚状态文件：$statePath" }
  Say ("复制完成（robocopy 退出码 {0}，{1:N1} 秒）。" -f $LASTEXITCODE, $sw.Elapsed.TotalSeconds)
}
$state.copied = $true
$state.status = 'copied'
Write-JsonFile $statePath $state

# 5) 校验
Say '--- 逐文件校验 ---'
$dstMap = Get-TreeMap $dst
$missing = @()
$sizeBad = @()
foreach ($k in $srcMap.Keys) {
  if (-not $dstMap.ContainsKey($k)) { $missing += $k }
  elseif ($dstMap[$k] -ne $srcMap[$k]) { $sizeBad += $k }
}
$extra = @($dstMap.Keys | Where-Object { -not $srcMap.ContainsKey($_) })
if ($missing.Count -gt 0 -or $sizeBad.Count -gt 0) {
  Say "校验失败：缺失 $($missing.Count) 个、大小不一致 $($sizeBad.Count) 个。"
  ($missing + $sizeBad) | Select-Object -First 10 | ForEach-Object { Say "  $_" }
  if ($ResumeCopy) {
    Say '续作校验不一致：目标疑似中断残留或之后被改动。请人工核对后清理目标目录，'
    Say '清理后重跑本脚本将重新完整复制。源目录未改动。'
  } else {
    Say '源目录未改动；目标目录保留供检查。'
  }
  exit 1
}
if ($extra.Count -gt 0) { Say "注意：目标比源多 $($extra.Count) 个文件（可能是复制期间新写入，请人工确认）。" }
Say "逐文件校验通过：$($srcMap.Count) 个文件全部一致。"
$state.verified = $true
$state.status = 'verified'
Write-JsonFile $statePath $state

# 6) state 已在复制前落盘（含 resume/copied/verified 阶段标记），此处无需重建；
#    改名与建 Junction 失败时，直接重跑本脚本即可按续作模式继续。

# 7) 改名留退路 + 建 Junction
if (Test-Path -LiteralPath $bak) { throw "退路已存在，请先处理：$bak" }
$leaf = [System.IO.Path]::GetFileName($src)
try {
  Rename-Item -LiteralPath $src -NewName ($leaf + $BackupSuffix) -ErrorAction Stop
} catch {
  Say '改名退路失败：源目录句柄被外部进程占用（常见：资源管理器窗口/终端工作目录）。'
  Say '关闭后直接重跑本脚本——续作模式会跳过复制，从这一步继续。'
  Say "回滚状态文件：$statePath"
  exit 1
}
Say "原目录已改名：$bak"
try {
  $link = New-Item -ItemType Junction -Path $src -Target $dst -ErrorAction Stop
  if ($link.LinkType -ne 'Junction') { throw "LinkType 不是 Junction：$($link.LinkType)" }
} catch {
  Rename-Item -LiteralPath $bak -NewName $leaf -ErrorAction SilentlyContinue
  Say "建 Junction 失败，已回滚：$($_.Exception.Message)"
  Say '排除原因后直接重跑本脚本——续作模式会跳过复制，从这一步继续。'
  exit 1
}
$state.junctionCreated = $true
$state.status = 'junction-created'
Write-JsonFile $statePath $state
Say "Junction 已建立：$src -> $dst"

# 8) 穿透 + 写入探针
$probeName = '_dsh-migration-probe.tmp'
$probeViaSource = Join-Path $src $probeName
$probeViaTarget = Join-Path $dst $probeName
try {
  [System.IO.File]::WriteAllText($probeViaSource, 'probe')
  $probeOk = Test-Path -LiteralPath $probeViaTarget
  if ($probeOk) { [System.IO.File]::Delete($probeViaTarget) }
  if (-not $probeOk) { throw '经原路径写入的探针文件没有出现在目标盘' }
  Say '写入探针通过：经原路径新建的文件确实落在目标盘。'
} catch {
  $state.status = 'probe-failed'
  Write-JsonFile $statePath $state
  Say "探针失败：$($_.Exception.Message)"
  Say '请人工检查 Junction；如需回滚，请用 Rollback-DshMigration.ps1 -StateFile 上面那个文件。'
  exit 1
}

# 9) 可选设 DSH_HOME
if ($SetDshHome) {
  try {
    [Environment]::SetEnvironmentVariable($DshHomeEnv, $dst, 'User')
    $readback = Get-UserDshHome
    if ([string]::IsNullOrWhiteSpace($readback)) { throw '读取用户级 DSH_HOME 失败' }
    $state.envAfter = $readback
    Say "已设置用户级 DSH_HOME=$readback（DSH 需要完全重启才生效）"
  } catch {
    Say "设置 DSH_HOME 失败：$($_.Exception.Message)（Junction 已建立，可手工设置或回滚）"
    $state.status = 'env-failed'
    Write-JsonFile $statePath $state
    exit 1
  }
}
$state.status = 'complete'
Write-JsonFile $statePath $state

# 10) 退路处理
if ($CleanupBackup) {
  if (-not (Remove-BackupSafely $bak $dst)) { exit 1 }
} else {
  Say ''
  Say "退路已保留：$bak"
  Say '确认 DSH 重启后一切正常，再运行：'
  Say "  .\Migrate-DshHome.ps1 -TargetRoot '$dst' -CleanupBackup"
  Say '（脚本会识别源目录已是 Junction，只做安全清理，不会重复复制。）'
}

Say ''
Say '完成。下一步：'
Say '  1. 完全退出并重启 DSH'
Say '  2. 运行 Verify-DshMigration.ps1 做十项核验'
Say '  3. 打开 DSH 确认插件、工作区、会话正常'
Say "  回滚命令：.\Rollback-DshMigration.ps1 -StateFile '$statePath' -Execute"
