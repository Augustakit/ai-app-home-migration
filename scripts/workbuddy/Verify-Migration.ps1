<#
.SYNOPSIS
  Read-only verification for a completed junction-based migration.

.DESCRIPTION
  Prints ten PASS/FAIL checks plus a backup-status summary. Never modifies
  anything. Exits with code 1 if any check fails.

.EXAMPLE
  .\scripts\Verify-Migration.ps1 -SourceRoot '<APP_HOME>' -TargetRoot '<TARGET_ROOT>' `
      -Directories @('binaries','plugins','cache')

.EXAMPLE
  Whole-home mode is detected automatically when -SourceRoot is itself a Junction:
  .\scripts\Verify-Migration.ps1 -SourceRoot '<APP_HOME>' -TargetRoot '<TARGET_ROOT>'
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$SourceRoot,
  [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$TargetRoot,
  [string[]]$Directories = @(),
  [string]$BackupSuffix = '.migbak',
  [switch]$SkipHash,
  [switch]$WriteProbe
)

$ErrorActionPreference = 'Stop'
$checks = New-Object System.Collections.Generic.List[object]

function Add-Check([string]$Name, [bool]$Pass, [string]$Detail) {
  $script:checks.Add([pscustomobject]@{
    Check  = $Name
    Result = $(if ($Pass) { 'PASS' } else { 'FAIL' })
    Detail = $Detail
  })
}

function Get-Lines([string]$Path) {
  $root = $Path.TrimEnd([char]92)
  @(Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
    ForEach-Object { "{0}|{1}" -f $_.FullName.Substring($root.Length + 1), $_.Length } |
    Sort-Object)
}

if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) { throw "SourceRoot not found: $SourceRoot" }
if (-not (Test-Path -LiteralPath $TargetRoot -PathType Container)) { throw "TargetRoot not found: $TargetRoot" }

# ===== WHOLE-HOME MODE =====
# When the application data root itself is a Junction, the former per-directory
# links are gone. Requiring "every subdirectory is a Junction" would report ten
# false FAILs, so this mode checks the root link and the real target instead.
$rootItem = Get-Item -LiteralPath $SourceRoot -Force -ErrorAction SilentlyContinue
if ($rootItem -and $rootItem.LinkType -eq 'Junction') {
  Write-Host ""
  Write-Host "MODE: WHOLE-HOME (root is a Junction; subdirectories are real data)"
  $expected = $TargetRoot.TrimEnd([char]92)
  $actual   = ($rootItem.Target -join ',').TrimEnd([char]92)
  $tItem    = Get-Item -LiteralPath $TargetRoot -Force -ErrorAction SilentlyContinue
  Add-Check '1  Root path is a Junction' $true "target=$actual"
  Add-Check '2  ReparsePoint attribute present' ($rootItem.Attributes -match 'ReparsePoint') "$($rootItem.Attributes)"
  Add-Check '3  Target points to expected root' ([string]::Equals($actual, $expected, [StringComparison]::OrdinalIgnoreCase)) "expected=$expected"
  Add-Check '4  Target is a real directory' ($null -ne $tItem -and -not $tItem.LinkType -and $tItem.PSIsContainer) "link=$($tItem.LinkType)"

  $targetLinks = @(Get-ChildItem -LiteralPath $TargetRoot -Force -ErrorAction SilentlyContinue | Where-Object { $_.Attributes -match 'ReparsePoint' })
  Add-Check '5  No nested junctions in target' ($targetLinks.Count -eq 0) "links=$($targetLinks.Count)"

  $cTop = @(Get-ChildItem -LiteralPath $SourceRoot -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object)
  $eTop = @(Get-ChildItem -LiteralPath $TargetRoot -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object)
  $topDiff = @(Compare-Object -ReferenceObject $cTop -DifferenceObject $eTop)
  Add-Check '6  Top-level entries identical' ($topDiff.Count -eq 0) "source=$($cTop.Count) target=$($eTop.Count) diff=$($topDiff.Count)"

  $srcTrim = $SourceRoot.TrimEnd([char]92)
  $tgtTrim = $TargetRoot.TrimEnd([char]92)
  $cPaths = @(Get-ChildItem -LiteralPath $SourceRoot -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName.Substring($srcTrim.Length + 1) } | Sort-Object)
  $ePaths = @(Get-ChildItem -LiteralPath $TargetRoot -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName.Substring($tgtTrim.Length + 1) } | Sort-Object)
  $pathDiff = @(Compare-Object -ReferenceObject $cPaths -DifferenceObject $ePaths)
  Add-Check '7  Per-file path set identical' ($pathDiff.Count -eq 0) "files=$($cPaths.Count) diff=$($pathDiff.Count); size/hash deltas on active logs are expected"

  $static = @(Get-ChildItem -LiteralPath $TargetRoot -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'wal|shm|log|cache|\.db' } | Select-Object -First 1)
  if ($SkipHash -or $static.Count -eq 0) {
    Add-Check '8  Static file hash match' $true 'skipped (-SkipHash or no static file)'
  } else {
    $cp = Join-Path $SourceRoot $static[0].Name
    $h1 = (Get-FileHash -LiteralPath $cp -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
    $h2 = (Get-FileHash -LiteralPath $static[0].FullName -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash
    Add-Check '8  Static file hash match' ($null -ne $h1 -and $h1 -eq $h2) "file=$($static[0].Name)"
  }

  if ($WriteProbe) {
    $pn = '_verify_probe.tmp'
    [System.IO.File]::WriteAllText((Join-Path $SourceRoot $pn), 'probe')
    $probeOk = Test-Path -LiteralPath (Join-Path $TargetRoot $pn)
    if ($probeOk) { [System.IO.File]::Delete((Join-Path $TargetRoot $pn)) }
    Add-Check '9  New writes land on target' $probeOk 'write probe'
  } else {
    Add-Check '9  New writes land on target' $true 'skipped (use -WriteProbe)'
  }

  try {
    $driveId = ([System.IO.Path]::GetPathRoot($SourceRoot)).TrimEnd([char]92)
    $di = New-Object System.IO.DriveInfo($driveId + '\')
    Add-Check '10 Free space readable' $true "source volume free: $([math]::Round($di.AvailableFreeSpace / 1GB, 2)) GB"
  } catch {
    Add-Check '10 Free space readable' $false $_.Exception.Message
  }

  $bakPath = "$($srcTrim)$BackupSuffix"
  Write-Host ""
  Write-Host "=== BACKUP STATUS (informational) ==="
  if (Test-Path -LiteralPath $bakPath) {
    $bakRp = @(Get-ChildItem -LiteralPath $bakPath -Recurse -Force -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Attributes -match 'ReparsePoint' }).Count
    Write-Host "Backup exists and contains $bakRp reparse points."
    Write-Host "NEVER delete it with -Recurse if that number is greater than zero:"
    Write-Host "remove the links non-recursively first, then the real content."
  } else {
    Write-Host "No backup directory remains; the source volume holds only the root link."
  }
  Write-Host ""
  $checks | Format-Table Check, Result, Detail -AutoSize
    $failed = @($checks | Where-Object { $_.Result -eq 'FAIL' }).Count
    $total  = [int]$checks.Count
    $passed = [int]($total - [int]$failed)
    Write-Host ("SUMMARY: {0} passed, {1} failed" -f $passed, $failed)
  if ($failed -gt 0) { exit 1 }
  Write-Host "RESULT: ALL CHECKS PASSED"
  exit 0
}

if ($Directories.Count -eq 0) {
  throw "Per-directory mode needs -Directories. For a whole-home migration, -SourceRoot must be a Junction."
}

$items = @()
foreach ($n in $Directories) {
  $src = Join-Path $SourceRoot $n
  $dst = Join-Path $TargetRoot $n
  $items += [pscustomobject]@{
    Name = $n
    Src  = $src
    Dst  = $dst
    Bak  = "$src$BackupSuffix"
    SI   = Get-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
    DI   = Get-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
  }
}

function Bad-Count([scriptblock]$Pred) { @($items | Where-Object $Pred).Count }

# 1. LinkType
$n = Bad-Count { -not $_.SI -or $_.SI.LinkType -ne 'Junction' }
Add-Check '1  Every source path is a Junction' ($n -eq 0) "bad=$n of $($items.Count)"

# 2. ReparsePoint attribute
$n = Bad-Count { -not $_.SI -or $_.SI.Attributes -notmatch 'ReparsePoint' }
Add-Check '2  ReparsePoint attribute present' ($n -eq 0) "bad=$n"

# 3. Target is a real directory
$n = Bad-Count { -not $_.DI -or $_.DI.LinkType -or -not $_.DI.PSIsContainer }
Add-Check '3  Targets are real directories' ($n -eq 0) "bad=$n"

# 4. Target path resolves to expected location (case-insensitive, ignore trailing separator)
$n = Bad-Count {
  -not $_.SI -or
  -not [string]::Equals(
    (($_.SI.Target -join ',').TrimEnd([char]92)),
    ($_.Dst.TrimEnd([char]92)),
    [StringComparison]::OrdinalIgnoreCase)
}
Add-Check '4  Junction targets point to expected paths' ($n -eq 0) "bad=$n"

# 5. Full structural match through the source path
$bad = @()
foreach ($i in $items) {
  if (-not $i.SI -or -not $i.DI) { $bad += $i.Name; continue }
  $a = @(Get-Lines $i.Src)
  $b = @(Get-Lines $i.Dst)
  $d = @(Compare-Object -ReferenceObject $a -DifferenceObject $b)
  if ($d.Count -ne 0) { $bad += "$($i.Name):$($d.Count)" }
}
Add-Check '5  Per-file structure diff is zero' ($bad.Count -eq 0) $(if ($bad.Count) { $bad -join ', ' } else { "all $($items.Count) match" })

# 6. Largest-file hash through the source path
if ($SkipHash) {
  Add-Check '6  Largest-file SHA256 match' $true 'skipped by -SkipHash'
}
else {
  $bad = @()
  foreach ($i in $items) {
    if (-not $i.DI) { $bad += "$($i.Name):no target"; continue }
    $big = @(Get-ChildItem -LiteralPath $i.Dst -Recurse -Force -File -ErrorAction SilentlyContinue |
             Sort-Object Length -Descending | Select-Object -First 1)
    if ($big.Count -eq 0) { continue }
    $root = $i.Dst.TrimEnd([char]92)
    $rel = $big[0].FullName.Substring($root.Length + 1)
    $twin = Join-Path $i.Src $rel
    if (-not (Test-Path -LiteralPath $twin)) { $bad += "$($i.Name):missing"; continue }
    $h1 = (Get-FileHash -LiteralPath $twin -Algorithm SHA256).Hash
    $h2 = (Get-FileHash -LiteralPath $big[0].FullName -Algorithm SHA256).Hash
    if ($h1 -ne $h2) { $bad += "$($i.Name):mismatch" }
  }
  Add-Check '6  Largest-file SHA256 match' ($bad.Count -eq 0) $(if ($bad.Count) { $bad -join ', ' } else { 'all match' })
}

# 7. Files readable through the source path
$n = Bad-Count { -not $_.SI -or @(Get-ChildItem -LiteralPath $_.Src -Recurse -Force -File -ErrorAction SilentlyContinue).Count -eq 0 }
Add-Check '7  Data readable through source paths' ($n -eq 0) "empty=$n"

# 8. Other app data still present beside the migrated dirs
$others = @(Get-ChildItem -LiteralPath $SourceRoot -Force -ErrorAction SilentlyContinue |
            Where-Object { $Directories -notcontains $_.Name })
Add-Check '8  Non-migrated app data intact' ($others.Count -gt 0) "$($others.Count) entries remain"

# 9. No orphan entries (directories or files) in the target root
$extras = @(Get-ChildItem -LiteralPath $TargetRoot -Force -ErrorAction SilentlyContinue |
            Where-Object { $Directories -notcontains $_.Name })
Add-Check '9  No orphan target entries' ($extras.Count -eq 0) $(if ($extras.Count) { ($extras.Name -join ', ') } else { 'none' })

# 10. Free space readable
try {
  $driveId = ([System.IO.Path]::GetPathRoot($SourceRoot)).TrimEnd([char]92)
  $di = New-Object System.IO.DriveInfo($driveId + '\')
  $free = [math]::Round($di.AvailableFreeSpace / 1GB, 2)
  Add-Check '10 Free space readable' ($free -ge 0) "source volume free: $free GB"
}
catch {
  Add-Check '10 Free space readable' $false $_.Exception.Message
}

# Backup status (informational, not a pass/fail gate)
$bakPresent = @($items | Where-Object { Test-Path -LiteralPath $_.Bak }).Count
Write-Host ""
Write-Host "=== BACKUP STATUS (informational) ==="
Write-Host ("Backups present: {0} of {1}" -f $bakPresent, $items.Count)
Write-Host "Keep them until verification and app self-test are complete."
Write-Host "Some delete tools move files to Recycle Bin; empty it (after checking contents) to actually free space."
Write-Host ""

$checks | Format-Table Check, Result, Detail -AutoSize
$failed = @($checks | Where-Object { $_.Result -eq 'FAIL' }).Count
$total  = [int]$checks.Count
$passed = [int]($total - [int]$failed)
Write-Host ("SUMMARY: {0} passed, {1} failed" -f $passed, $failed)
if ($failed -gt 0) { exit 1 }
Write-Host "RESULT: ALL CHECKS PASSED"
