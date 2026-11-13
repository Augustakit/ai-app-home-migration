<#
  DSH 迁移工具自测（在临时目录里，不碰真实数据）。

  用法：
    .\Test-DshMigrationToolkit.ps1
    .\Test-DshMigrationToolkit.ps1 -Root 'D:\Temp\dsh-tool-test'
#>
[CmdletBinding()]
param(
  [string]$Root = ''
)

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
$checks = New-Object System.Collections.ArrayList

function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  [void]$checks.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail })
  if ($Ok) { Write-Host "PASS $Name" -ForegroundColor Green }
  else { Write-Host "FAIL $Name  $Detail" -ForegroundColor Red }
}

function Run-Tool([string]$Name, [string[]]$Arguments) {
  $file = Join-Path $scriptDir $Name
  $base = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $file)
  & powershell.exe @base @Arguments | Out-Host
  return $LASTEXITCODE
}

$createdRoot = $false
if ([string]::IsNullOrWhiteSpace($Root)) {
  $Root = Join-Path $env:TEMP ("dsh-migration-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
  $createdRoot = $true
}
if (-not (Test-Path -LiteralPath $Root)) { New-Item -ItemType Directory -Path $Root -Force | Out-Null }
$Root = (Get-Item -LiteralPath $Root -Force).FullName
Write-Host "临时目录：$Root"

try {
  # ---------- 造假数据 ----------
  $src = Join-Path $Root 'home\.dsh'
  $profile = Join-Path $src 'profiles\desktop'
  New-Item -ItemType Directory -Path (Join-Path $profile 'node_modules') -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $profile 'package.json') -Value '{"name":"dsh-profile-desktop"}' -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $profile 'pnpm-workspace.yaml') -Value "packages:`n  - .`n" -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $profile 'pnpm-lock.yaml') -Value "lockfileVersion: '9.0'" -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $profile 'node_modules\.modules.yaml') -Value '{"storeDir":"D:\\FakeStore\\v11"}' -Encoding UTF8
  New-Item -ItemType Directory -Path (Join-Path $src 'storages') -Force | Out-Null
  $ws = Join-Path $Root 'workspace'
  New-Item -ItemType Directory -Path $ws -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $ws 'readme.txt') -Value 'workspace' -Encoding UTF8
  $wsJson = @{
    unit = @{ name = 'workspace'; version = 2 }
    global = @{ initialized = $true; workspaceIds = @('w1'); archivedSessionIds = @(); pinnedSessionIds = @() }
    tables = @{ workspaces = @{ w1 = @{ path = $ws; title = 'default-workspace'; sessionIds = @('session-1'); createdAt = '2026-01-01T00:00:00Z'; updatedAt = '2026-01-01T00:00:00Z' } } }
  } | ConvertTo-Json -Depth 8
  Set-Content -LiteralPath (Join-Path $src 'storages\workspace.json') -Value $wsJson -Encoding UTF8
  $session = Join-Path $src 'sessions\--fake--\session-1'
  New-Item -ItemType Directory -Path $session -Force | Out-Null
  [System.IO.File]::WriteAllBytes((Join-Path $session 'session.v4.jsonl.zstd'), [byte[]](1..32))
  Set-Content -LiteralPath (Join-Path $src '.credentials.yaml') -Value 'token: fake' -Encoding UTF8
  New-Item -ItemType Directory -Path (Join-Path $src 'attachments') -Force | Out-Null
  [System.IO.File]::WriteAllBytes((Join-Path $src 'attachments\a.bin'), [byte[]](1..100))
  Set-Content -LiteralPath (Join-Path $src 'root-file.txt') -Value 'root file' -Encoding UTF8

  $dst = Join-Path $Root 'target\.dsh'
  $stateDir = Join-Path $Root 'states'
  $backup = "$src.dshbak"

  # ---------- 演练 ----------
  $code = Run-Tool 'Migrate-DshHome.ps1' @('-TargetRoot', $dst, '-SourceRoot', $src, '-StateDir', $stateDir, '-SkipProcessGuard', '-SkipDshHomeGuard', '-WhatIf')
  Check '演练退出码 0' ($code -eq 0) "exit=$code"
  Check '演练未创建目标目录' (-not (Test-Path -LiteralPath $dst))

  # ---------- 正式迁移 ----------
  $code = Run-Tool 'Migrate-DshHome.ps1' @('-TargetRoot', $dst, '-SourceRoot', $src, '-StateDir', $stateDir, '-SkipProcessGuard', '-SkipDshHomeGuard')
  Check '迁移退出码 0' ($code -eq 0) "exit=$code"
  Check '目标目录已创建' (Test-Path -LiteralPath $dst)
  Check '目标里有 profile/package.json' (Test-Path -LiteralPath (Join-Path $dst 'profiles\desktop\package.json'))
  Check '目标里有 credentials' (Test-Path -LiteralPath (Join-Path $dst '.credentials.yaml'))
  Check '源路径变成 Junction' (([System.IO.File]::GetAttributes($src) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
  Check '退路存在' (Test-Path -LiteralPath $backup)
  $stateFiles = @(Get-ChildItem -LiteralPath $stateDir -Filter 'state-*.json' -File -ErrorAction SilentlyContinue)
  Check '写了 state 文件' ($stateFiles.Count -eq 1) "count=$($stateFiles.Count)"
  Check '探针文件已清理' (-not (Test-Path -LiteralPath (Join-Path $dst '_dsh-migration-probe.tmp')))

  # ---------- 核验 ----------
  $code = Run-Tool 'Verify-DshMigration.ps1' @('-DataRoot', $dst, '-SkipDshHomeCheck')
  Check '迁移后核验无 FAIL' ($code -eq 0) "exit=$code"

  # ---------- 回滚 ----------
  if ($stateFiles.Count -eq 1) {
    $code = Run-Tool 'Rollback-DshMigration.ps1' @('-StateFile', $stateFiles[0].FullName, '-Execute')
    Check '回滚退出码 0' ($code -eq 0) "exit=$code"
    $srcItem = Get-Item -LiteralPath $src -Force
    $isLink = (($srcItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or $srcItem.LinkType)
    Check '回滚后源路径恢复为真实目录' (-not $isLink)
    Check '回滚后旧文件回来' (Test-Path -LiteralPath (Join-Path $src 'profiles\desktop\package.json'))
    Check '回滚后目标数据仍在' (Test-Path -LiteralPath (Join-Path $dst 'profiles\desktop\package.json'))
  } else {
    Check '回滚测试跳过（没有 state）' $false
  }

  # ---------- pnpm 修复 ----------
  $fixHome = Join-Path $Root 'fix-home\.dsh'
  $fixProfile = Join-Path $fixHome 'profiles\desktop'
  New-Item -ItemType Directory -Path (Join-Path $fixProfile 'node_modules') -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $fixProfile 'node_modules\.modules.yaml') -Value '{"storeDir":"D:\\StoreX\\v11"}' -Encoding UTF8
  Set-Content -LiteralPath (Join-Path $fixProfile 'pnpm-workspace.yaml') -Value "packages:`n  - .`n" -Encoding UTF8
  $wsFile = Join-Path $fixProfile 'pnpm-workspace.yaml'
  $code = Run-Tool 'Repair-DshPnpm.ps1' @('-DataRoot', $fixHome)
  Check 'pnpm 检查模式退出码 0' ($code -eq 0) "exit=$code"
  Check 'pnpm 检查模式不写文件' (-not ((Get-Content -LiteralPath $wsFile -Raw) -match 'storeDir'))
  $code = Run-Tool 'Repair-DshPnpm.ps1' @('-DataRoot', $fixHome, '-Execute')
  Check 'pnpm 修复退出码 0' ($code -eq 0) "exit=$code"
  $after = Get-Content -LiteralPath $wsFile -Raw
  Check 'pnpm 修复写入 storeDir' (($after -match 'storeDir') -and ($after -match 'StoreX')) $after
  Check 'pnpm 修复保留备份' (@(Get-ChildItem -LiteralPath $fixProfile -Filter 'pnpm-workspace.yaml.bak-*').Count -ge 1)
  $code = Run-Tool 'Repair-DshPnpm.ps1' @('-DataRoot', $fixHome)
  $idemOut = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptDir 'Repair-DshPnpm.ps1') -DataRoot $fixHome) -join "`n"
  Check 'pnpm 修复是幂等的' (($code -eq 0) -and ($idemOut -match 'OK')) $idemOut
} finally {
  # 先删可能存在的 Junction（非递归），再删临时目录
  foreach ($dir in @($Root)) {
    if (Test-Path -LiteralPath $dir) {
      Get-ChildItem -LiteralPath $dir -Recurse -Force -Directory -ErrorAction SilentlyContinue |
        Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 } |
        ForEach-Object { try { [System.IO.Directory]::Delete($_.FullName, $false) } catch {} }
      Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
  if ($createdRoot -and (Test-Path -LiteralPath $Root)) { Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue }
}

$failed = @($checks | Where-Object { -not $_.Ok })
Write-Host ''
Write-Host ("{0}/{1} checks passed" -f ($checks.Count - $failed.Count), $checks.Count) -ForegroundColor Cyan
if ($failed.Count -gt 0) {
  $failed | ForEach-Object { Write-Host "  FAIL: $($_.Name) $($_.Detail)" -ForegroundColor Red }
  exit 1
}
Write-Host 'SELFTEST PASSED' -ForegroundColor Green
exit 0
