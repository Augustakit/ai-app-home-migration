<#
  合并技能的静态/冒烟自测（只读 + 临时目录）。
  - 所有 .ps1：UTF-8 BOM + 语法可解析
  - 所有 .cmd/.bat：CRLF + 纯 ASCII
  - Detect-Platform.ps1 能输出 JSON
  - DSH 迁移工具自测（临时目录，不碰真实数据）
#>
[CmdletBinding()]
param(
  [switch]$SkipDshSelftest
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$checks = New-Object System.Collections.ArrayList

function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  [void]$checks.Add([pscustomobject]@{ Name = $Name; Ok = $Ok; Detail = $Detail })
  if ($Ok) { Write-Host "PASS $Name" -ForegroundColor Green }
  else { Write-Host "FAIL $Name  $Detail" -ForegroundColor Red }
}

Write-Host "=== 静态检查 ==="

$ps1 = @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.ps1' -File)
$badBom = @(); $badSyntax = @()
foreach ($f in $ps1) {
  $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
  $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191
  if (-not $hasBom) { $badBom += $f.FullName.Substring($root.Length + 1) }
  $tokens = $null; $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) { $badSyntax += "$($f.FullName.Substring($root.Length + 1)): $($errors[0].Message)" }
}
Check "PS1 全部带 UTF-8 BOM（$($ps1.Count) 个）" ($badBom.Count -eq 0) ($badBom -join ', ')
Check 'PS1 全部语法可解析' ($badSyntax.Count -eq 0) (($badSyntax | Select-Object -First 3) -join '; ')

$bats = @(Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.Extension -in '.bat', '.cmd' })
$badBat = @()
foreach ($f in $bats) {
  $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
  $nonAscii = @($bytes | Where-Object { $_ -gt 127 })
  $text = [System.Text.Encoding]::ASCII.GetString($bytes)
  $lfOnly = ($text -match "(?<!`r)`n")
  if ($nonAscii.Count -gt 0 -or $lfOnly) { $badBat += $f.FullName.Substring($root.Length + 1) }
}
Check "CMD/BAT 纯 ASCII + CRLF（$($bats.Count) 个）" ($badBat.Count -eq 0) ($badBat -join ', ')

# ---- 平台识别 ----
$detect = Join-Path $root 'scripts\Detect-Platform.ps1'
$jsonText = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $detect -Json 2>$null
try {
  $det = $jsonText | ConvertFrom-Json
  Check 'Detect-Platform 输出 JSON' ($null -ne $det -and $det.PSObject.Properties.Name -contains 'candidates')
  $candidateCount = @($det.candidates).Count
  Check 'Detect-Platform 有 candidates 字段' ($det.PSObject.Properties.Name -contains 'candidates')
  Check 'Detect-Platform 提供 displayRoot 字段' ($det.PSObject.Properties.Name -contains 'displayRoot')
  Check 'Detect-Platform 有 ambiguous 字段' ($det.PSObject.Properties.Name -contains 'ambiguous')
  if ($det.ambiguous) {
    Check '歧义时 platform 必须为空' ($null -eq $det.platform) "platform=$($det.platform)"
  } elseif ($candidateCount -gt 0) {
    Check '非歧义时 platform 必须是已知平台' ($det.platform -in @('dsh', 'zcode', 'workbuddy', 'generic')) "platform=$($det.platform)"
  } else {
    Check '无候选时 platform 为空' ($null -eq $det.platform) "platform=$($det.platform)"
  }
} catch {
  Check 'Detect-Platform 输出 JSON' $false $_.Exception.Message
}

# ---- DSH 自测 ----
if (-not $SkipDshSelftest) {
  $dshTest = Join-Path $root 'scripts\dsh\Test-DshMigrationToolkit.ps1'
  $tmp = Join-Path $env:TEMP ("ai-app-home-migration-dsh-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dshTest -Root $tmp | Out-Host
  $code = $LASTEXITCODE
  Check 'DSH 迁移工具自测通过' ($code -eq 0) "exit=$code"
}

$failed = @($checks | Where-Object { -not $_.Ok })
Write-Host ''
Write-Host ("{0}/{1} checks passed" -f ($checks.Count - $failed.Count), $checks.Count) -ForegroundColor Cyan
if ($failed.Count -gt 0) { exit 1 }
Write-Host 'TOOLKIT SELFTEST PASSED' -ForegroundColor Green
exit 0
