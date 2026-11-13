<#
  平台识别（只读）。给路由技能和 AI 用：先证明“这是哪个应用”，再决定加载哪套迁移流程。
  输出 JSON 时包含：
    platform      推荐平台：dsh / zcode / workbuddy / generic / null
    ambiguous     是否同时命中多个平台（true 时必须问用户，不能猜）
    candidates[]  每个候选：数据根、是否 Junction、指向、进程、机制、证据
    dataRoot      推荐平台的数据根（真实路径，供执行脚本使用）
    displayRoot   脱敏后的数据根（可粘贴进报告/文档）

  用法：
    .\Detect-Platform.ps1
    .\Detect-Platform.ps1 -Platform dsh
    .\Detect-Platform.ps1 -Json
    .\Detect-Platform.ps1 -AppName 'SomeApp' -AppHome 'D:\SomeAppData' -Platform generic
#>
[CmdletBinding()]
param(
  [ValidateSet('auto', 'dsh', 'zcode', 'workbuddy', 'generic')][string]$Platform = 'auto',
  [string]$AppName = '',
  [string]$AppHome = '',
  [switch]$Json
)

$ErrorActionPreference = 'Stop'
$Candidates = New-Object System.Collections.ArrayList
$processCache = @(Get-Process -ErrorAction SilentlyContinue)

function Get-ProcNames {
  return @($processCache | ForEach-Object { $_.ProcessName })
}

function Test-Proc([string]$Pattern) {
  return @($processCache | Where-Object { $_.ProcessName -like $Pattern }).Count -gt 0
}

function Get-ProcessPaths([string]$Pattern) {
  return @($processCache | Where-Object { $_.ProcessName -like $Pattern } | ForEach-Object {
    try { $_.Path } catch { $null }
  } | Where-Object { $_ })
}

function Test-IsReparse([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  $i = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  if (-not $i) { return $false }
  return ($i.LinkType -or (($i.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0))
}

function Get-LinkTarget([string]$Path) {
  if (-not (Test-IsReparse $Path)) { return $null }
  $i = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
  if (-not $i) { return $null }
  $t = @($i.Target)[0]
  if ($t -and $t -match '^(?i)Global\\') { $t = $t.Substring(7) }
  return $t
}

function Convert-PathForDisplay([string]$Path) {
  if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
  $s = $Path
  if ($env:USERPROFILE) { $s = $s.Replace($env:USERPROFILE, '%USERPROFILE%') }
  if ($env:LOCALAPPDATA) { $s = $s.Replace($env:LOCALAPPDATA, '%LOCALAPPDATA%') }
  if ($env:APPDATA) { $s = $s.Replace($env:APPDATA, '%APPDATA%') }
  $s = [regex]::Replace($s, '^[A-Za-z]:\\', '<DRIVE>:\')
  return $s
}

function Add-Candidate {
  param(
    [string]$Name,
    [string]$DataRoot,
    [string]$Confidence,
    [string]$Mechanism,
    [bool]$Running,
    [object[]]$Evidence
  )
  if ([string]::IsNullOrWhiteSpace($DataRoot)) { return }
  $exists = Test-Path -LiteralPath $DataRoot -PathType Container
  $isLink = Test-IsReparse $DataRoot
  $target = Get-LinkTarget $DataRoot
  [void]$Candidates.Add([pscustomobject]@{
    platform = $Name
    confidence = $Confidence
    dataRoot = $DataRoot
    displayRoot = Convert-PathForDisplay $DataRoot
    exists = $exists
    isJunction = $isLink
    junctionTarget = $target
    displayTarget = if ($target) { Convert-PathForDisplay $target } else { $null }
    running = $Running
    mechanism = $Mechanism
    evidence = @($Evidence | Where-Object { $_ })
  })
}

# ---------- 1) DSH ----------
$dshRunning = Test-Proc '*DeepSeek*'
$dshRoot = if (-not [string]::IsNullOrWhiteSpace($env:DSH_HOME)) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
$dshEvidence = @()
if (-not [string]::IsNullOrWhiteSpace($env:DSH_HOME)) { $dshEvidence += "env DSH_HOME 指向数据根" }
if (Test-Path -LiteralPath $dshRoot) { $dshEvidence += "数据根存在" }
if (Test-IsReparse $dshRoot) { $dshEvidence += "数据根是 Junction" }
if ($dshRunning) { $dshEvidence += "进程：DeepSeek Harness" }
if ($env:DSH_DESKTOP_NODE_EXECUTABLE) { $dshEvidence += "env DSH_DESKTOP_NODE_EXECUTABLE 存在（DSH 宿主环境）" }
$dshConfidence = if ($dshRunning -or $dshEvidence.Count -ge 2) { 'high' } elseif ($dshEvidence.Count -eq 1) { 'medium' } else { 'low' }
Add-Candidate -Name 'dsh' -DataRoot $dshRoot -Confidence $dshConfidence -Mechanism ($(if (Test-IsReparse $dshRoot) { 'junction' } elseif ($env:DSH_HOME) { 'dsh-home' } else { 'default-path' })) -Running $dshRunning -Evidence $dshEvidence

# ---------- 2) ZCode ----------
$zRunning = Test-Proc 'ZCode*'
$zRoot = Join-Path $env:USERPROFILE '.zcode'
$zEvidence = @()
if (Test-Path -LiteralPath $zRoot) { $zEvidence += "数据根 %USERPROFILE%\.zcode 存在" }
if (Test-IsReparse $zRoot) { $zEvidence += "数据根是 Junction" }
if ($zRunning) { $zEvidence += "进程：ZCode" }
$zConfidence = if ($zRunning -or $zEvidence.Count -ge 2) { 'high' } elseif ($zEvidence.Count -eq 1) { 'medium' } else { 'low' }
Add-Candidate -Name 'zcode' -DataRoot $zRoot -Confidence $zConfidence -Mechanism ($(if (Test-IsReparse $zRoot) { 'junction' } else { 'default-path' })) -Running $zRunning -Evidence $zEvidence

# ---------- 3) WorkBuddy / 通用应用 ----------
$wRunning = Test-Proc '*WorkBuddy*'
$wRoots = @(
  (Join-Path $env:USERPROFILE '.workbuddy'),
  (Join-Path $env:APPDATA 'WorkBuddy'),
  (Join-Path $env:LOCALAPPDATA 'WorkBuddy')
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
$wEvidence = @()
foreach ($r in $wRoots) { $wEvidence += "发现数据目录：$(Convert-PathForDisplay $r)" }
if ($wRunning) { $wEvidence += "进程：WorkBuddy" }
if ($wRoots.Count -gt 0 -or $wRunning) {
  $wRoot = @($wRoots)[0]
  $wConfidence = if ($wRunning) { 'high' } else { 'medium' }
  Add-Candidate -Name 'workbuddy' -DataRoot $wRoot -Confidence $wConfidence -Mechanism ($(if (Test-IsReparse $wRoot) { 'junction' } else { 'default-path' })) -Running $wRunning -Evidence $wEvidence
}

if (-not [string]::IsNullOrWhiteSpace($AppHome)) {
  Add-Candidate -Name 'generic' -DataRoot $AppHome -Confidence 'high' -Mechanism ($(if (Test-IsReparse $AppHome) { 'junction' } else { 'default-path' })) -Running $false -Evidence @("用户指定 AppHome: $(Convert-PathForDisplay $AppHome)", $(if ($AppName) { "应用名：$AppName" } else { $null }))
}

# ---------- 选择 ----------
$valid = @($Candidates | Where-Object { $_.exists -or $_.running -or $_.platform -eq 'generic' })
$chosen = $null
$ambiguous = $false

if ($Platform -ne 'auto') {
  $chosen = @($Candidates | Where-Object { $_.platform -eq $Platform } | Select-Object -First 1)
  if (-not $chosen) {
    throw "没有找到平台 $Platform 的候选（可用 -AppHome 指定 generic 数据根）"
  }
} else {
  $strong = @($valid | Where-Object { $_.confidence -eq 'high' })
  $medium = @($valid | Where-Object { $_.confidence -eq 'medium' })
  if ($strong.Count -eq 1) {
    $chosen = $strong[0]
  } elseif ($strong.Count -gt 1) {
    $ambiguous = $true
    $chosen = $strong[0]
  } elseif ($medium.Count -eq 1) {
    $chosen = $medium[0]
  } elseif ($medium.Count -gt 1) {
    $ambiguous = $true
    $chosen = $medium[0]
  } elseif ($valid.Count -eq 1) {
    $chosen = $valid[0]
  } elseif ($valid.Count -gt 1) {
    $ambiguous = $true
    $chosen = $valid[0]
  }
}

$result = [pscustomobject]@{
  platform = if ($chosen -and -not $ambiguous) { $chosen.platform } else { $null }
  confidence = if ($chosen -and -not $ambiguous) { $chosen.confidence } else { $null }
  ambiguous = $ambiguous
  dataRoot = if ($chosen -and -not $ambiguous) { $chosen.dataRoot } else { $null }
  displayRoot = if ($chosen -and -not $ambiguous) { $chosen.displayRoot } else { $null }
  mechanism = if ($chosen -and -not $ambiguous) { $chosen.mechanism } else { $null }
  running = if ($chosen -and -not $ambiguous) { $chosen.running } else { $false }
  candidates = @($Candidates)
  recommendedAction = if ($ambiguous) {
    '同时命中多个平台：先问用户要迁移哪个，不要猜。'
  } elseif ($chosen) {
    "加载 references/platform-$($chosen.platform).md 与 scripts/$($chosen.platform)/"
  } else {
    '未识别到平台：问用户应用名/数据根，或用 -AppHome 指定 generic。'
  }
}

if ($Json) {
  $result | ConvertTo-Json -Depth 8
  exit 0
}

"=== 平台识别（只读） ==="
"候选："
$Candidates | ForEach-Object {
  "  - {0,-9} confidence={1,-6} running={2,-5} root={3}" -f $_.platform, $_.confidence, $_.running, $_.displayRoot
}
""
if ($ambiguous) {
  "结论：同时命中多个平台（ambiguous=true）。请先问用户要迁移哪个，不要猜。"
} elseif ($chosen) {
  "结论：$($chosen.platform)（confidence=$($chosen.confidence)），数据根：$($chosen.displayRoot)"
  "机制：$($chosen.mechanism)；运行中：$($chosen.running)"
  "下一步：$($result.recommendedAction)"
} else {
  "结论：未识别到平台。请提供应用名/数据根，或使用 -AppHome 指定 generic。"
}
