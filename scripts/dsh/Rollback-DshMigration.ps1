<#
  回滚一次 DSH 数据目录迁移（依据迁移时生成的 state 文件）。

  只恢复：Junction（删链接）、原目录名（把退路改回来）、用户级 DSH_HOME。
  不会删除目标盘的新数据。

  用法：
    .\Rollback-DshMigration.ps1 -StateFile '<state 文件>' -WhatIf
    .\Rollback-DshMigration.ps1 -StateFile '<state 文件>' -Execute
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$StateFile,
  [switch]$Execute
)

$ErrorActionPreference = 'Stop'
$DshHomeEnv = 'DSH_HOME'

function TrimPath([string]$Path) { return $Path.TrimEnd([char]92, [char]47) }
function Test-IsReparse($Item) {
  if ($null -eq $Item) { return $false }
  if ($Item.LinkType) { return $true }
  return (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

if (-not (Test-Path -LiteralPath $StateFile)) { throw "state 文件不存在：$StateFile" }
$state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
$src = TrimPath ([string]$state.source)
$dst = TrimPath ([string]$state.target)
$bak = [string]$state.backup

Write-Host '=== 回滚 DSH 数据目录迁移 ===' -ForegroundColor Cyan
Write-Host "源路径：$src"
Write-Host "目标路径：$dst"
Write-Host "退路：$bak"
Write-Host "模式：$($state.mode)；state 状态：$($state.status)"

if (-not $Execute) {
  Write-Host '当前是检查：加 -Execute 才会真正回滚。' -ForegroundColor Yellow
  exit 0
}

$si = Get-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
if (Test-IsReparse $si) {
  Write-Host "将删除 Junction（只删链接）：$src" -ForegroundColor Yellow
  if ($PSCmdlet.ShouldProcess($src, '删除 Junction')) {
    try { [System.IO.Directory]::Delete($src, $false) }
    catch { $null = & cmd.exe /c ('rmdir "' + $src + '"'); if (Test-Path -LiteralPath $src) { throw "删除 Junction 失败：$($_.Exception.Message)" } }
  }
} elseif (Test-Path -LiteralPath $src) {
  Write-Host "源路径现在是真实目录，跳过删除：$src"
}

if (Test-Path -LiteralPath $bak) {
  if (Test-Path -LiteralPath $src) {
    throw "无法把退路改回原路径：$src 仍然存在。请先人工处理。"
  }
  Write-Host "将把退路改回原路径：$bak -> $src" -ForegroundColor Yellow
  if ($PSCmdlet.ShouldProcess($src, '恢复原目录')) {
    Rename-Item -LiteralPath $bak -NewName ([System.IO.Path]::GetFileName($src)) -ErrorAction Stop
  }
} else {
  Write-Host "没有找到退路（可能已清理）：$bak"
}

if ($state.setDshHome) {
  $before = $state.envBefore
  Write-Host "将恢复用户级 $DshHomeEnv 为：$before" -ForegroundColor Yellow
  if ($PSCmdlet.ShouldProcess($DshHomeEnv, '恢复环境变量')) {
    if ([string]::IsNullOrWhiteSpace($before)) {
      [Environment]::SetEnvironmentVariable($DshHomeEnv, $null, 'User')
    } else {
      [Environment]::SetEnvironmentVariable($DshHomeEnv, $before, 'User')
    }
  }
}

Write-Host ''
Write-Host '回滚步骤完成。目标盘数据仍保留在：' + $dst
Write-Host '确认不再需要后，可手动删除目标目录（不要删错成其他目录）。'
exit 0
