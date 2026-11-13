<#
  修复 DSH 插件安装报错 ERR_PNPM_UNEXPECTED_STORE。

  原理：profile 的 node_modules/.modules.yaml 记录了当初安装它的 pnpm store；
  如果现在的 pnpm 解析到另一个 store，pnpm 会拒绝安装/卸载。把记录里的 store
  写进 profile 的 pnpm-workspace.yaml 顶层 storeDir，就能继续用原来的包，不必重装。

  默认只检查，不改文件；加 -Execute 才写入（会保留带时间戳的备份）。

  用法：
    .\Repair-DshPnpm.ps1
    .\Repair-DshPnpm.ps1 -Execute
#>
[CmdletBinding()]
param(
  [Alias('Home')][string]$DataRoot = '',
  [string]$Profile = '',
  [string]$PnpmPath = '',
  [switch]$Execute
)

$ErrorActionPreference = 'Stop'
$DshHomeEnv = 'DSH_HOME'

function TrimPath([string]$Path) { return $Path.TrimEnd([char]92, [char]47) }

function Get-DataRoot {
  if (-not [string]::IsNullOrWhiteSpace($DataRoot)) { return $DataRoot }
  if (-not [string]::IsNullOrWhiteSpace($env:DSH_HOME)) { return $env:DSH_HOME }
  return (Join-Path $env:USERPROFILE '.dsh')
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
  if (-not [string]::IsNullOrWhiteSpace($PnpmPath)) {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($node) {
      Push-Location $env:TEMP
      try { $out = & $node.Source $PnpmPath store path 2>$null; if ($LASTEXITCODE -eq 0 -and $out) { return @($out)[-1].Trim() } }
      finally { Pop-Location }
    }
  }
  $deps = Join-Path $DataRoot 'dsh-runtimes\dsh-primary-runtime\dependencies'
  $nodeExe = Join-Path $deps 'node\bin\node.exe'
  $pnpmCjs = Join-Path $deps 'pnpm\bin\pnpm.cjs'
  if ((Test-Path -LiteralPath $nodeExe) -and (Test-Path -LiteralPath $pnpmCjs)) {
    Push-Location $env:TEMP
    try { $out = & $nodeExe $pnpmCjs store path 2>$null; if ($LASTEXITCODE -eq 0 -and $out) { return @($out)[-1].Trim() } }
    finally { Pop-Location }
  }
  $pnpm = Get-Command pnpm -ErrorAction SilentlyContinue
  if ($pnpm) {
    Push-Location $env:TEMP
    try { $out = & $pnpm.Source store path 2>$null; if ($LASTEXITCODE -eq 0 -and $out) { return @($out)[-1].Trim() } }
    finally { Pop-Location }
  }
  return $null
}

function Quote-Yaml([string]$Value) { return "'" + $Value.Replace("'", "''") + "'" }

$root = TrimPath ((Get-DataRoot).Trim().Trim('"'))
$profilesDir = Join-Path $root 'profiles'
if ([string]::IsNullOrWhiteSpace($Profile)) {
  $Profile = 'desktop'
  if (-not (Test-Path -LiteralPath (Join-Path $profilesDir $Profile))) {
    $first = @(Get-ChildItem -LiteralPath $profilesDir -Force -Directory -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($first.Count -gt 0) { $Profile = $first[0].Name }
  }
}
$profileDir = Join-Path $profilesDir $Profile
Write-Host "=== 修复 DSH pnpm store 路径 ===" -ForegroundColor Cyan
Write-Host "数据根：$root"
Write-Host "profile：$profileDir"

$store = Get-ModulesStoreDir $profileDir
if (-not $store) { Write-Host '没有找到 node_modules/.modules.yaml 的 storeDir。' -ForegroundColor Red; exit 2 }
$wsFile = Join-Path $profileDir 'pnpm-workspace.yaml'
if (-not (Test-Path -LiteralPath $wsFile)) { Write-Host "没有 pnpm-workspace.yaml：$wsFile" -ForegroundColor Red; exit 2 }

$text = Get-Content -LiteralPath $wsFile -Raw
$pattern = [regex]'(?m)^storeDir\s*:\s*(.+)$'
$m = $pattern.Match($text)
$current = $null
if ($m.Success) { $current = $m.Groups[1].Value.Trim().Trim("'", '"') }

Write-Host "modules.yaml 记录：$store"
$actual = Get-PnpmStorePath $root
if ($actual) { Write-Host "pnpm 当前解析：$actual" } else { Write-Host 'pnpm 当前解析：无法读取（不影响修复）' }

if ($current) {
  $same = [string]::Equals((TrimPath ([System.IO.Path]::GetFullPath($current))), (TrimPath ([System.IO.Path]::GetFullPath($store))), [StringComparison]::OrdinalIgnoreCase)
  if ($same) { Write-Host "OK：pnpm-workspace.yaml 已固定同一个 storeDir，无需修改。" -ForegroundColor Green; exit 0 }
}
if (-not $current -and $actual) {
  $same = [string]::Equals((TrimPath ([System.IO.Path]::GetFullPath($actual))), (TrimPath ([System.IO.Path]::GetFullPath($store))), [StringComparison]::OrdinalIgnoreCase)
  if ($same) { Write-Host 'OK：pnpm 已经解析到同一个 store，无需修改。' -ForegroundColor Green; exit 0 }
}

$newLine = 'storeDir: ' + (Quote-Yaml $store)
if ($m.Success) {
  $updated = $pattern.Replace($text, $newLine, 1)
  $action = '替换已有 storeDir'
} else {
  $updated = $text
  if (-not $updated.EndsWith("`n")) { $updated += "`n" }
  $updated += $newLine + "`n"
  $action = '追加 storeDir'
}

Write-Host "计划：$action -> $store"
if (-not $Execute) {
  Write-Host '当前是只读检查；加 -Execute 才会写入（自动留 .bak-时间戳 备份）。' -ForegroundColor Yellow
  exit 0
}

$backup = "$wsFile.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Copy-Item -LiteralPath $wsFile -Destination $backup -Force
[System.IO.File]::WriteAllText($wsFile, $updated, (New-Object System.Text.UTF8Encoding($false)))
$check = Get-Content -LiteralPath $wsFile -Raw
if ($check -notmatch '(?m)^storeDir\s*:') { Write-Host '写入校验失败，备份保留：' + $backup -ForegroundColor Red; exit 2 }
Write-Host "已写入：$wsFile" -ForegroundColor Green
Write-Host "备份：$backup"
Write-Host '现在可以重试插件安装/卸载；DSH 开着的话先重启再试。'
exit 0
