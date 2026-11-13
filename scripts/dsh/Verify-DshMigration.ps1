<#
  DSH 数据目录迁移后的十项核验（只读，不改数据）

  用法：
    .\Verify-DshMigration.ps1
    .\Verify-DshMigration.ps1 -StateFile '<迁移时生成的 state 文件>'
    .\Verify-DshMigration.ps1 -Home 'X:\DSHData\.dsh'
    .\Verify-DshMigration.ps1 -StateFile '<state>' -VerifyBackup
    .\Verify-DshMigration.ps1 -StateFile '<state>' -RepairFromBackup
    .\Verify-DshMigration.ps1 -Deep

  退出码：0 = 全部通过；1 = 有 FAIL（需要处理）。
#>
[CmdletBinding()]
param(
  [Alias('Home')][string]$DataRoot = '',
  [string]$StateFile = '',
  [string]$Profile = '',
  [string]$BackupPath = '',
  [switch]$VerifyBackup,
  [switch]$RepairFromBackup,
  [switch]$Deep,
  [switch]$SkipDshHomeCheck
)

$ErrorActionPreference = 'Stop'
$DshHomeEnv = 'DSH_HOME'
$results = New-Object System.Collections.ArrayList

function Add-Result([string]$Level, [string]$Message) {
  [void]$results.Add([pscustomobject]@{ Level = $Level; Message = $Message })
  $color = 'Gray'
  if ($Level -eq 'PASS') { $color = 'Green' }
  elseif ($Level -eq 'WARN') { $color = 'Yellow' }
  elseif ($Level -eq 'FAIL') { $color = 'Red' }
  Write-Host ("[{0}] {1}" -f $Level, $Message) -ForegroundColor $color
}

function TrimPath([string]$Path) { return $Path.TrimEnd([char]92, [char]47) }

function Get-SizeMapLong([string]$Root) {
  $map = @{}
  $pfx = '\\?\' + (Get-Item -LiteralPath $Root -Force).FullName
  foreach ($f in [System.IO.Directory]::EnumerateFiles($pfx, '*', [System.IO.SearchOption]::AllDirectories)) {
    $map[$f.Substring($pfx.Length + 1)] = [int64]([System.IO.FileInfo]$f).Length
  }
  return $map
}

function Copy-MissingFromBackup([string]$Backup, [string]$Target, [string[]]$RelativePaths) {
  $copied = 0
  foreach ($rel in $RelativePaths) {
    $src = Join-Path $Backup $rel
    $dst = Join-Path $Target $rel
    $dstDir = Split-Path -Parent $dst
    if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
    Copy-Item -LiteralPath $src -Destination $dst -Force
    $copied++
  }
  return $copied
}

function Test-IsReparse($Item) {
  if ($null -eq $Item) { return $false }
  if ($Item.LinkType) { return $true }
  return (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Get-UserDshHome {
  try { return [Environment]::GetEnvironmentVariable($DshHomeEnv, 'User') } catch { return $null }
}

function Get-ModulesStoreDir([string]$ProfileDir) {
  $f = Join-Path $ProfileDir 'node_modules\.modules.yaml'
  if (-not (Test-Path -LiteralPath $f)) { return $null }
  $text = Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue
  if ($text -match '"storeDir"\s*:\s*"((?:[^"\\]|\\.)*)"') { return ($matches[1] -replace '\\\\', '\') }
  if ($text -match '(?m)^\s*storeDir\s*:\s*[''"]?([^''"\r\n]+)') { return $matches[1].Trim() }
  return $null
}

function Get-PnpmStorePath([string]$DataRoot) {
  $deps = Join-Path $DataRoot 'dsh-runtimes\dsh-primary-runtime\dependencies'
  $node = Join-Path $deps 'node\bin\node.exe'
  $pnpmCjs = Join-Path $deps 'pnpm\bin\pnpm.cjs'
  if ((Test-Path -LiteralPath $node) -and (Test-Path -LiteralPath $pnpmCjs)) {
    Push-Location $env:TEMP
    try {
      $out = & $node $pnpmCjs store path 2>$null
      if ($LASTEXITCODE -eq 0 -and $out) { return @($out)[-1].Trim() }
    } finally { Pop-Location }
  }
  $pnpm = Get-Command pnpm -ErrorAction SilentlyContinue
  if ($pnpm) {
    Push-Location $env:TEMP
    try {
      $out = & $pnpm.Source store path 2>$null
      if ($LASTEXITCODE -eq 0 -and $out) { return @($out)[-1].Trim() }
    } finally { Pop-Location }
  }
  return $null
}

function Get-DshProcesses {
  return @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like '*DeepSeek*' })
}

$state = $null
if (-not [string]::IsNullOrWhiteSpace($StateFile)) {
  if (-not (Test-Path -LiteralPath $StateFile)) { throw "state 文件不存在：$StateFile" }
  $state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
  if ([string]::IsNullOrWhiteSpace($DataRoot)) { $DataRoot = [string]$state.target }
}

if ([string]::IsNullOrWhiteSpace($DataRoot)) {
  if (-not [string]::IsNullOrWhiteSpace($env:DSH_HOME)) { $DataRoot = $env:DSH_HOME }
  else { $DataRoot = Join-Path $env:USERPROFILE '.dsh' }
}
$DataRoot = TrimPath ($DataRoot.Trim().Trim('"'))
$defaultHome = Join-Path $env:USERPROFILE '.dsh'

Write-Host "=== DSH 数据目录迁移核验 ===" -ForegroundColor Cyan
Write-Host "数据根：$DataRoot"
Write-Host ''

# 1 数据根存在
if (Test-Path -LiteralPath $DataRoot -PathType Container) { Add-Result 'PASS' '数据根存在且可访问' }
else { Add-Result 'FAIL' "数据根不存在：$DataRoot"; }
$homeItem = Get-Item -LiteralPath $DataRoot -Force -ErrorAction SilentlyContinue

# 2 原路径是否为 Junction（整体迁移模式）
$sourcePath = $null
if ($state) { $sourcePath = [string]$state.source }
elseif ([string]::Equals((TrimPath $DataRoot), (TrimPath $defaultHome), [StringComparison]::OrdinalIgnoreCase)) {
  $sourcePath = $DataRoot
}
if ($sourcePath) {
  $si = Get-Item -LiteralPath $sourcePath -Force -ErrorAction SilentlyContinue
  if (Test-IsReparse $si) {
    $target = @($si.Target)[0]
    if ($target -and $target -match '^(?i)Global\\') { $target = $target.Substring(7) }
    $ok = $target -and [string]::Equals((TrimPath ([System.IO.Path]::GetFullPath($target))), (TrimPath ([System.IO.Path]::GetFullPath($DataRoot))), [StringComparison]::OrdinalIgnoreCase)
    if ($ok) { Add-Result 'PASS' "原路径 Junction 指向数据根：$sourcePath -> $target" }
    else { Add-Result 'FAIL' "原路径 Junction 目标不符：$sourcePath -> $target（期望 $DataRoot）" }
  } else {
    Add-Result 'WARN' "原路径不是 Junction：$sourcePath（如果用的是 DSH_HOME 方案，这是正常的）"
  }
} else {
  Add-Result 'PASS' '未指定原路径，跳过 Junction 检查'
}

# 3 DSH_HOME 一致性
if (-not $SkipDshHomeCheck) {
  $userHome = Get-UserDshHome
  if ([string]::IsNullOrWhiteSpace($userHome)) {
    Add-Result 'PASS' '用户级 DSH_HOME 未设置（使用默认路径或 Junction）'
  } else {
    $sh = TrimPath $userHome
    $same = [string]::Equals((TrimPath ([System.IO.Path]::GetFullPath($sh))), (TrimPath ([System.IO.Path]::GetFullPath($DataRoot))), [StringComparison]::OrdinalIgnoreCase)
    if ($same) { Add-Result 'PASS' "用户级 DSH_HOME 指向数据根：$userHome" }
    else { Add-Result 'FAIL' "用户级 DSH_HOME 是 $userHome，与数据根 $DataRoot 不一致" }
  }
} else {
  Add-Result 'PASS' '已按 -SkipDshHomeCheck 跳过 DSH_HOME 检查'
}

# 3b 默认路径 ~/.dsh 如果是 Junction，检查它指向数据根
if (-not [string]::Equals((TrimPath $DataRoot), (TrimPath $defaultHome), [StringComparison]::OrdinalIgnoreCase)) {
  $di = Get-Item -LiteralPath $defaultHome -Force -ErrorAction SilentlyContinue
  if (Test-IsReparse $di) {
    $dt = @($di.Target)[0]
    if ($dt -and $dt -match '^(?i)Global\\') { $dt = $dt.Substring(7) }
    $ok = $dt -and [string]::Equals((TrimPath ([System.IO.Path]::GetFullPath($dt))), (TrimPath ([System.IO.Path]::GetFullPath($DataRoot))), [StringComparison]::OrdinalIgnoreCase)
    if ($ok) { Add-Result 'PASS' "默认路径 Junction 指向数据根：$defaultHome -> $dt" }
    else { Add-Result 'WARN' "默认路径 Junction 指向别处：$defaultHome -> $dt（DSH_HOME 优先，所以 DSH 可能仍正常）" }
  } elseif (Test-Path -LiteralPath $defaultHome) {
    Add-Result 'WARN' "默认路径是真实目录，但当前数据根是 $DataRoot（确认 DSH_HOME 已设置且生效）"
  }
}

# 4 profile 配置文件
if ([string]::IsNullOrWhiteSpace($Profile)) {
  $Profile = 'desktop'
  $profilesDir = Join-Path $DataRoot 'profiles'
  if (-not (Test-Path -LiteralPath (Join-Path $profilesDir $Profile)) -and (Test-Path -LiteralPath $profilesDir)) {
    $first = @(Get-ChildItem -LiteralPath $profilesDir -Force -Directory -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($first.Count -gt 0) { $Profile = $first[0].Name }
  }
}
$profileDir = Join-Path (Join-Path $DataRoot 'profiles') $Profile
foreach ($name in @('package.json', 'pnpm-workspace.yaml', 'pnpm-lock.yaml')) {
  $p = Join-Path $profileDir $name
  if (Test-Path -LiteralPath $p) { Add-Result 'PASS' "profile 文件存在：$name" }
  else {
    $lvl = if ($name -eq 'package.json') { 'FAIL' } else { 'WARN' }
    Add-Result $lvl "profile 文件缺失：$p"
  }
}

# 5 pnpm storeDir 一致性
$modulesStore = Get-ModulesStoreDir $profileDir
$pnpmStore = Get-PnpmStorePath $DataRoot
if ($modulesStore -and $pnpmStore) {
  $same = [string]::Equals((TrimPath ([System.IO.Path]::GetFullPath($modulesStore))), (TrimPath ([System.IO.Path]::GetFullPath($pnpmStore))), [StringComparison]::OrdinalIgnoreCase)
  if ($same) { Add-Result 'PASS' "pnpm store 一致：$modulesStore" }
  else { Add-Result 'FAIL' "pnpm store 不一致：.modules.yaml=$modulesStore，pnpm=$pnpmStore（运行 Repair-DshPnpm.ps1 -Execute）" }
} elseif ($modulesStore) {
  Add-Result 'WARN' "无法解析 pnpm 实际 store（modules.yaml 记录 $modulesStore）"
} else {
  Add-Result 'WARN' '没有读到 node_modules/.modules.yaml 的 storeDir（profile 可能尚未安装依赖）'
}

# 6 工作区注册表
$wsFile = Join-Path $DataRoot 'storages\workspace.json'
if (Test-Path -LiteralPath $wsFile) {
  try {
    $ws = Get-Content -LiteralPath $wsFile -Raw | ConvertFrom-Json
    $rows = @($ws.tables.workspaces.PSObject.Properties)
    Add-Result 'PASS' "工作区注册表存在：$($rows.Count) 个工作区"
    $missing = @()
    foreach ($row in $rows) {
      $wp = [string]$row.Value.path
      if ($wp -and -not (Test-Path -LiteralPath $wp)) { $missing += $wp }
    }
    if ($missing.Count -gt 0) { Add-Result 'WARN' "有 $($missing.Count) 个工作区路径当前不存在：$($missing[0])" }
    else { Add-Result 'PASS' '所有工作区路径当前都可访问' }
  } catch {
    Add-Result 'FAIL' "工作区注册表无法解析：$($_.Exception.Message)"
  }
} else {
  Add-Result 'FAIL' "工作区注册表缺失：$wsFile"
}

# 7 会话目录
$sessionsDir = Join-Path $DataRoot 'sessions'
if (Test-Path -LiteralPath $sessionsDir) {
  $buckets = @(Get-ChildItem -LiteralPath $sessionsDir -Force -Directory -ErrorAction SilentlyContinue)
  $count = 0
  foreach ($b in $buckets) { $count += @(Get-ChildItem -LiteralPath $b.FullName -Force -Directory -ErrorAction SilentlyContinue).Count }
  if ($count -gt 0) { Add-Result 'PASS' "会话目录：$count 个" }
  else { Add-Result 'WARN' '会话目录为空（新安装可能正常）' }
} else {
  Add-Result 'WARN' "没有 sessions 目录：$sessionsDir"
}

# 8 磁盘 / 文件系统
$drive = ([System.IO.Path]::GetPathRoot($DataRoot)).TrimEnd([char]92)
try {
  $di = New-Object System.IO.DriveInfo($drive + '\')
  Add-Result 'PASS' ("数据根所在卷：{0} {1}，剩余 {2:N1} GB" -f $di.Name, $di.DriveFormat, ($di.AvailableFreeSpace / 1GB))
} catch {
  Add-Result 'WARN' "无法读取数据根所在卷信息：$drive — $($_.Exception.Message)"
}

# 9 进程提醒
$procs = Get-DshProcesses
if ($procs.Count -gt 0) { Add-Result 'WARN' "DSH 正在运行（$($procs.Count) 个进程）；核验前建议重启后再确认" }
else { Add-Result 'PASS' '没有检测到 DSH 进程' }

# 10 退路逐文件核对（-VerifyBackup / -RepairFromBackup）
if ($VerifyBackup -or $RepairFromBackup) {
  $backup = $BackupPath
  if (-not $backup -and $state -and $state.backup) { $backup = [string]$state.backup }
  if (-not $backup) { $backup = Join-Path $env:USERPROFILE '.dsh.dshbak' }
  if (-not (Test-Path -LiteralPath $backup -PathType Container)) {
    Add-Result 'WARN' "没有找到退路，跳过退路核对：$backup"
  } else {
    try {
      $bakMap = Get-SizeMapLong $backup
      $tgtMap = Get-SizeMapLong $DataRoot
      $missing = @(); $diff = @()
      foreach ($k in $bakMap.Keys) {
        if (-not $tgtMap.ContainsKey($k)) { $missing += $k }
        elseif ($tgtMap[$k] -ne $bakMap[$k]) { $diff += $k }
      }
      if ($missing.Count -eq 0 -and $diff.Count -eq 0) {
        Add-Result 'PASS' "退路逐文件核对通过：$($bakMap.Count) 个文件全部在目标且大小一致"
      } else {
        ($missing + $diff) | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" }
        if ($RepairFromBackup) {
          $bad = @($missing + $diff | Select-Object -Unique)
          $n = Copy-MissingFromBackup -Backup $backup -Target $DataRoot -RelativePaths $bad
          $bakMap2 = Get-SizeMapLong $backup
          $tgtMap2 = Get-SizeMapLong $DataRoot
          $still = @()
          foreach ($k in $bakMap2.Keys) {
            if (-not $tgtMap2.ContainsKey($k) -or $tgtMap2[$k] -ne $bakMap2[$k]) { $still += $k }
          }
          if ($still.Count -eq 0) {
            Add-Result 'PASS' "退路核对发现 $($bad.Count) 个差异，已从退路补回 $n 个文件并通过复核"
          } else {
            Add-Result 'FAIL' "补齐后仍有 $($still.Count) 个文件不一致"
          }
        } else {
          Add-Result 'FAIL' "退路核对发现缺失 $($missing.Count) 个、大小不一致 $($diff.Count) 个"
          Add-Result 'WARN' '如确认缺失，请加 -RepairFromBackup 从退路补齐，然后重跑核验'
        }
      }
    } catch {
      Add-Result 'FAIL' "退路核对失败：$($_.Exception.Message)"
    }
  }
}

# 11 可选深度检查（.NET \\?\ 枚举，避免 PS 5.1 GCI 对长路径静默漏文件）
if ($Deep) {
  $max = 0
  $fileCount = 0
  $bytes = [int64]0
  try {
    $pfx = '\\?\' + (Get-Item -LiteralPath $DataRoot -Force).FullName
    foreach ($f in [System.IO.Directory]::EnumerateFiles($pfx, '*', [System.IO.SearchOption]::AllDirectories)) {
      $rel = $f.Substring($pfx.Length + 1)
      $fileCount++
      $bytes += ([System.IO.FileInfo]$f).Length
      if ($rel.Length -gt $max) { $max = $rel.Length }
    }
    Add-Result 'PASS' ("深度枚举：{0} 个文件，{1:N2} MB" -f $fileCount, ($bytes / 1MB))
  } catch {
    Add-Result 'WARN' "深度枚举失败：$($_.Exception.Message)"
  }
  $projected = $DataRoot.Length + $max
  if ($projected -le 259) { Add-Result 'PASS' "最长路径预计 $projected 字符" }
  else { Add-Result 'WARN' "最长路径预计 $projected 字符，超过 259（LongPathsEnabled 需为 1）" }
}

$fails = @($results | Where-Object { $_.Level -eq 'FAIL' })
$warns = @($results | Where-Object { $_.Level -eq 'WARN' })
Write-Host ''
Write-Host ("结果：{0} PASS / {1} WARN / {2} FAIL" -f (@($results | Where-Object { $_.Level -eq 'PASS' }).Count), $warns.Count, $fails.Count) -ForegroundColor Cyan
if ($fails.Count -gt 0) {
  Write-Host '需要先处理 FAIL 项；数据本身通常还在，不要急着删退路。' -ForegroundColor Red
  exit 1
}
if ($warns.Count -gt 0) {
  Write-Host '没有 FAIL；WARN 项建议人工确认（尤其是 DSH 正在运行时）。' -ForegroundColor Yellow
}
exit 0
