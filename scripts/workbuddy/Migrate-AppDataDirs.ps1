<#
.SYNOPSIS
  Move large, static subdirectories of a Windows application data home to
  another local NTFS volume using directory junctions.

.DESCRIPTION
  Generic and machine-independent: no user names, drive letters, dates or
  product paths are hard-coded. Run it ONLY after the target app is closed.

  Pipeline per directory:
    copy (robocopy /XJ) -> verify (count + bytes + per-file structure)
    -> rename source to .migbak -> create Junction -> verify through source
    -> on any failure, roll that single item back automatically.

  Backups are NEVER removed by default. Cleanup is opt-in via -CleanupMode,
  and every cleanup first runs Test-BackupCoverage, which checks that the
  BACKUP ITSELF is fully covered by the target. The target is allowed to have
  extra files written after the migration, but every backup path must exist.

.EXAMPLE
  .\scripts\Migrate-AppDataDirs.ps1 -SourceRoot '<APP_HOME>' -TargetRoot '<TARGET_ROOT>' `
      -Directories @('binaries','plugins','cache') -GuardProcess '<PROCESS>' -WhatIf

.EXAMPLE
  .\scripts\Migrate-AppDataDirs.ps1 -SourceRoot '<APP_HOME>' -TargetRoot '<TARGET_ROOT>' `
      -Directories @('binaries','plugins','cache') -GuardProcess '<PROCESS>' `
      -CleanupMode Delete -PurgeOrphans
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$SourceRoot,
  [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$TargetRoot,
  [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string[]]$Directories,
  [string]$GuardProcess = '',
  [string]$BackupSuffix = '.migbak',
  [ValidateSet('Keep','Recycle','Delete','Archive')][string]$CleanupMode = 'Keep',
  [switch]$Interactive,
  [string]$ArchivePath = '',
  [switch]$PurgeOrphans,
  [switch]$RebuildTarget
)

$ErrorActionPreference = 'Stop'
# -WhatIf only controls this script's own plan branch; do not let read-only cmdlets inherit it.
$PlanOnly = [bool]$WhatIfPreference
$WhatIfPreference = $false

# 源/目标不能是盘根，不能互相嵌套（防止自我复制）
$srcCheck = $SourceRoot.Trim('"').TrimEnd([char]92)
$tgtCheck = $TargetRoot.Trim('"').TrimEnd([char]92)
if ($srcCheck -match '^[A-Za-z]:\\?$' -or $tgtCheck -match '^[A-Za-z]:\\?$') { throw '源/目标不能是盘根，必须指向具体目录' }
$fullSrc = [System.IO.Path]::GetFullPath($srcCheck + '\')
$fullTgt = [System.IO.Path]::GetFullPath($tgtCheck + '\')
if ([string]::Equals($fullSrc, $fullTgt, [StringComparison]::OrdinalIgnoreCase)) { throw '源与目标是同一目录' }
if ($fullTgt.StartsWith($fullSrc, [StringComparison]::OrdinalIgnoreCase)) { throw '目标在源目录内部——会自我复制' }
if ($fullSrc.StartsWith($fullTgt, [StringComparison]::OrdinalIgnoreCase)) { throw '源在目标目录内部' }

# ---------- Placeholder guard ----------
$placeholderPattern = '<[A-Za-z_][A-Za-z0-9_]*>'
$unresolved = @()
foreach ($entry in @(
  @{ Name = '-SourceRoot';   Value = $SourceRoot },
  @{ Name = '-TargetRoot';   Value = $TargetRoot },
  @{ Name = '-GuardProcess'; Value = $GuardProcess },
  @{ Name = '-ArchivePath';  Value = $ArchivePath }
)) {
  if ($entry.Value -and [regex]::IsMatch($entry.Value, $placeholderPattern)) {
    $unresolved += "$($entry.Name) = $($entry.Value)"
  }
}
if ($unresolved.Count -gt 0) {
  Write-Host "STOP: angle-bracket placeholders are still in place. Replace them before running."
  $unresolved | ForEach-Object { Write-Host "  $_" }
  Write-Host "  -SourceRoot   : the real application data directory containing the -Directories folders"
  Write-Host "  -TargetRoot   : a short ASCII folder on another local fixed NTFS drive"
  Write-Host "  -GuardProcess : the application process name without .exe, so the running-app guard works"
  Write-Host "  -ArchivePath  : only needed when -CleanupMode Archive is used"
  Write-Host "No files were changed."
  exit 1
}

function Get-Facts([string]$Path) {
  $root = $Path.TrimEnd([char]92)
  $items = @(Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue)
  $sum = ($items | Measure-Object -Property Length -Sum).Sum
  if ($null -eq $sum) { $sum = 0 }
  $lines = @($items | ForEach-Object {
      "{0}|{1}" -f $_.FullName.Substring($root.Length + 1), $_.Length
  } | Sort-Object)
  return @{ Count = $items.Count; Bytes = [long]$sum; Lines = $lines }
}

function Assert-Match($A, $B, [string]$Label) {
  if ($A.Count -ne $B.Count -or $A.Bytes -ne $B.Bytes) {
    throw "$Label : count/bytes mismatch (a $($A.Count)/$($A.Bytes) vs b $($B.Count)/$($B.Bytes))"
  }
  $diff = @(Compare-Object -ReferenceObject $A.Lines -DifferenceObject $B.Lines)
  if ($diff.Count -ne 0) { throw "$Label : structural diff on $($diff.Count) lines" }
}

function Test-BackupCoverage([string]$Bak, [string]$Target, [string]$Label) {
  $b = Get-Facts $Bak
  $t = Get-Facts $Target
  if ($b.Count -eq 0) { throw "$Label : backup is empty, refuse to delete" }
  $bRels = @($b.Lines | ForEach-Object { ($_ -split '\|')[0] } | Sort-Object -Unique)
  $tRels = @($t.Lines | ForEach-Object { ($_ -split '\|')[0] } | Sort-Object -Unique)
  $missing = @(Compare-Object -ReferenceObject $bRels -DifferenceObject $tRels |
               Where-Object { $_.SideIndicator -eq '<=' })
  if ($missing.Count -ne 0) { throw "$Label : $($missing.Count) backup paths missing in target" }
  $big = @(Get-ChildItem -LiteralPath $Bak -Recurse -Force -File -ErrorAction SilentlyContinue |
           Sort-Object Length -Descending | Select-Object -First 1)
  if ($big.Count -gt 0) {
    $root = $Bak.TrimEnd([char]92)
    $rel = $big[0].FullName.Substring($root.Length + 1)
    $twin = Join-Path $Target $rel
    if (-not (Test-Path -LiteralPath $twin)) { throw "$Label : largest backup file missing in target" }
    $h1 = (Get-FileHash -LiteralPath $big[0].FullName -Algorithm SHA256).Hash
    $h2 = (Get-FileHash -LiteralPath $twin -Algorithm SHA256).Hash
    if ($h1 -ne $h2) { throw "$Label : largest file hash mismatch (target may have been rewritten)" }
  }
  Write-Host ("BACKUP COVERAGE OK: {0} backup paths all present in target ({1} target paths)" -f $bRels.Count, $tRels.Count)
}

function Remove-DirSafe([string]$Path, [string]$How) {
  if ($PlanOnly) { Write-Host "WHATIF: would apply '$How' to $Path"; return }
  switch ($How) {
    'Delete' {
      Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
      Write-Host "PERMANENTLY DELETED: $Path"
    }
    'Recycle' {
      try {
        $uo = [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs
        $ro = [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
        $uc = [Microsoft.VisualBasic.FileIO.UICancelOption]::DoNothing
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($Path, $uo, $ro, $uc)
        Write-Host "MOVED TO RECYCLE BIN: $Path"
      } catch {
        Write-Host "RECYCLE UNAVAILABLE, backup kept: $Path :: $($_.Exception.Message)"
      }
    }
    'Archive' {
      if (-not $ArchivePath) { throw 'Archive mode needs -ArchivePath' }
      if (-not (Test-Path -LiteralPath $ArchivePath)) {
        New-Item -ItemType Directory -Path $ArchivePath -Force | Out-Null
      }
      $dest = Join-Path $ArchivePath (Split-Path -Path $Path -Leaf)
      if (Test-Path -LiteralPath $dest) { throw "Archive destination already exists: $dest" }
      Move-Item -LiteralPath $Path -Destination $dest -Force -ErrorAction Stop
      Write-Host "ARCHIVED: $Path -> $dest"
    }
  }
}

# ---------- 0. Guards ----------
if ($GuardProcess) {
  $running = @(Get-Process -Name $GuardProcess -ErrorAction SilentlyContinue)
  if ($running.Count -gt 0) {
    if ($PlanOnly) {
      Write-Host "WARN: $($running.Count) '$GuardProcess' process(es) still running; -WhatIf is allowed, but the real run requires complete exit."
    } else {
      Write-Host "STOP: $($running.Count) '$GuardProcess' process(es) still running."
      Write-Host "Close the application completely (tray + Task Manager), then run again."
      exit 1
    }
  } else {
    Write-Host "Guard OK: no '$GuardProcess' process."
  }
}

try {
  $sourceOk = Test-Path -LiteralPath $SourceRoot -PathType Container
}
catch {
  Write-Host "STOP: -SourceRoot contains illegal characters or cannot be read: $SourceRoot"
  Write-Host "Replace every angle-bracket placeholder with a real path before running."
  Write-Host "No files were changed."
  exit 1
}
if (-not $sourceOk) { throw "SourceRoot not found: $SourceRoot" }

try {
  $driveId = ([System.IO.Path]::GetPathRoot($TargetRoot)).TrimEnd([char]92)
  $di = New-Object System.IO.DriveInfo($driveId + '\')
  $vol = [pscustomobject]@{ DriveType = [int]$di.DriveType; FileSystem = $di.DriveFormat }
} catch {
  Write-Host "STOP: -TargetRoot is not a usable drive path: $TargetRoot"
  Write-Host "No files were changed."
  exit 1
}
if (-not $vol) { throw "Target drive not found: $driveId" }
if ($vol.DriveType -ne 3) { throw "Target must be a local fixed drive (DriveType 3), got $($vol.DriveType)" }
if ($vol.FileSystem -ne 'NTFS') { throw "Target must be NTFS for junctions, got $($vol.FileSystem)" }
Write-Host "Target volume OK: $driveId  NTFS  local fixed."

if (-not (Test-Path -LiteralPath $TargetRoot)) {
  if ($PSCmdlet.ShouldProcess($TargetRoot, 'create target root')) {
    New-Item -ItemType Directory -Path $TargetRoot -Force | Out-Null
  }
}

Write-Host ("Source: {0}" -f $SourceRoot)
Write-Host ("Target: {0}" -f $TargetRoot)
Write-Host ("Items : {0}" -f ($Directories -join ', '))
Write-Host ("Mode  : {0}" -f $(if ($Interactive) { 'Interactive' } else { $CleanupMode }))
Write-Host ""

# ---------- 1. Migrate ----------
$results = @()
foreach ($name in $Directories) {
  $src = Join-Path $SourceRoot $name
  $dst = Join-Path $TargetRoot $name
  $bak = "$src$BackupSuffix"
  $renamed = $false
  Write-Host "=== $name ==="

  try {
    if (-not (Test-Path -LiteralPath $src)) { Write-Host "SKIP: source missing."; continue }

    $si = Get-Item -LiteralPath $src -Force
    if ($si.LinkType) {
      Write-Host "EXISTING: already a $($si.LinkType), migration skipped."
      $results += [pscustomobject]@{ Name = $name; Status = 'EXISTING'; Files = 0; Bytes = 0; Target = $dst }
      continue
    }
    if (Test-Path -LiteralPath $bak) { throw "Backup already exists: $bak" }

    $factsBefore = Get-Facts $src
    if ($factsBefore.Count -eq 0) { Write-Host "WARNING: source directory contains no files." }

    if (Test-Path -LiteralPath $dst) {
      if (-not $RebuildTarget) { throw "Target already exists: $dst (use -RebuildTarget to rebuild a dirty copy)" }
      $di = Get-Item -LiteralPath $dst -Force
      if ($di.LinkType) {
        if ($PSCmdlet.ShouldProcess($dst, 'remove target junction')) {
          [System.IO.Directory]::Delete($dst, $false)
        }
      } else {
        if ($PSCmdlet.ShouldProcess($dst, 'rebuild target')) {
          Remove-Item -LiteralPath $dst -Recurse -Force -ErrorAction Stop
        }
      }
    }

    if (-not $PSCmdlet.ShouldProcess($src, 'migrate')) { continue }

    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    & robocopy $src $dst /E /COPY:DAT /R:1 /W:1 /XJ /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed (exit $LASTEXITCODE)" }
    Write-Host "COPY OK (robocopy exit $LASTEXITCODE)"

    $a = Get-Facts $src
    $b = Get-Facts $dst
    Assert-Match $a $b 'copy verify'
    Write-Host ("VERIFY OK: {0} files / {1} bytes" -f $a.Count, $a.Bytes)

    Rename-Item -LiteralPath $src -NewName "$name$BackupSuffix" -ErrorAction Stop
    $renamed = $true
    Write-Host "RENAMED -> $bak"

    $link = New-Item -ItemType Junction -Path $src -Target $dst -ErrorAction Stop
    if ($link.LinkType -ne 'Junction') { throw "LinkType is '$($link.LinkType)', expected Junction" }

    $c = Get-Facts $src
    Assert-Match $c $b 'junction verify'
    Write-Host ("JUNCTION OK -> {0}" -f ($link.Target -join ','))
    Write-Host ("VIA SOURCE OK: {0} files / {1} bytes" -f $c.Count, $c.Bytes)
    Write-Host "DONE OK"

    $results += [pscustomobject]@{ Name = $name; Status = 'OK'; Files = $b.Count; Bytes = $b.Bytes; Target = $dst }
  }
  catch {
    Write-Host ("FAILED: {0}" -f $_.Exception.Message)
    if ($renamed -and -not (Test-Path -LiteralPath $src)) {
      Rename-Item -LiteralPath $bak -NewName $name -ErrorAction SilentlyContinue
      Write-Host "ROLLED BACK that item."
    }
    $results += [pscustomobject]@{ Name = $name; Status = 'FAILED'; Files = 0; Bytes = 0; Target = '' }
  }
}

# ---------- 2. Choose cleanup mode (user option) ----------
$mode = $CleanupMode
if ($Interactive -and -not $PlanOnly -and [Environment]::UserInteractive) {
  Write-Host ""
  Write-Host "=== CHOOSE BACKUP HANDLING ==="
  Write-Host "All items verified. Backups are still on the source volume."
  Write-Host "  [K] Keep backups (default, safest)"
  Write-Host "  [R] Move to Recycle Bin (recoverable, space NOT freed)"
  Write-Host "  [D] Delete permanently (frees space, not recoverable)"
  Write-Host "  [A] Archive to -ArchivePath (frees source, keeps a copy)"
  $choice = Read-Host "Your choice [K/R/D/A]"
  switch ($choice.Trim().ToUpperInvariant()) {
    'R' { $mode = 'Recycle' }
    'D' { $mode = 'Delete' }
    'A' { $mode = 'Archive' }
    default { $mode = 'Keep' }
  }
  Write-Host "Selected: $mode"
}
elseif ($Interactive) {
  Write-Host "Interactive prompt skipped (dry run or non-interactive host); mode remains $CleanupMode."
}

# ---------- 3. Cleanup with hard gate ----------
Write-Host ""
Write-Host "=== BACKUP CLEANUP ==="
$ok = @($results | Where-Object { $_.Status -eq 'OK' -or $_.Status -eq 'EXISTING' })
if ($ok.Count -ne $Directories.Count) {
  Write-Host "SKIP cleanup: not every item succeeded (or some were skipped). No backup removed."
}
elseif ($mode -eq 'Keep') {
  Write-Host "Mode Keep: backups retained as a rollback path."
  Write-Host "Re-run with -CleanupMode <Recycle|Delete|Archive> or -Interactive after verification."
}
else {
  foreach ($r in $ok) {
    $src = Join-Path $SourceRoot $r.Name
    $bak = "$src$BackupSuffix"
    if (-not (Test-Path -LiteralPath $bak)) { continue }
    try {
      $li = Get-Item -LiteralPath $src -Force
      if ($li.LinkType -ne 'Junction') { Write-Host "KEEP (not a junction): $($r.Name)"; continue }
      $ti = Get-Item -LiteralPath $r.Target -Force
      if ($ti.LinkType) { Write-Host "KEEP (target is a link): $($r.Name)"; continue }
      Test-BackupCoverage $bak $r.Target $r.Name
      Remove-DirSafe $bak $mode
    }
    catch {
      Write-Host "KEEP (gate failed): $($r.Name) :: $($_.Exception.Message)"
    }
  }
  Write-Host "NOTE: some delete tools move files to Recycle Bin instead of freeing space."
  Write-Host "Check Recycle Bin, confirm it holds nothing else you need, then empty it."
}

# ---------- 4. Optional orphan purge ----------
if ($PurgeOrphans) {
  Write-Host ""
  Write-Host "=== ORPHAN TARGETS ==="
  $extras = @(Get-ChildItem -LiteralPath $TargetRoot -Directory -Force |
              Where-Object { $Directories -notcontains $_.Name })
  if ($extras.Count -eq 0) { Write-Host "None found." }
  foreach ($x in $extras) {
    if ($x.LinkType) { Write-Host "SKIP (is a link): $($x.FullName)"; continue }
    Write-Host "ORPHAN: $($x.FullName)"
    if ($PSCmdlet.ShouldProcess($x.FullName, 'purge orphan target')) {
      Remove-Item -LiteralPath $x.FullName -Recurse -Force -ErrorAction Stop
      Write-Host "PURGED: $($x.FullName)"
    }
  }
}

# ---------- 5. Final state ----------
Write-Host ""
Write-Host "=== FINAL ==="
$results | Format-Table Name, Status, Files, Bytes, Target -AutoSize
foreach ($name in $Directories) {
  $p = Join-Path $SourceRoot $name
  if (Test-Path -LiteralPath $p) {
    $i = Get-Item -LiteralPath $p -Force
    Write-Host ("{0,-24} {1,-9} -> {2}  backup={3}" -f $name, $i.LinkType, ($i.Target -join ','), (Test-Path -LiteralPath "$p$BackupSuffix"))
  }
}
Write-Host "Run scripts/Verify-Migration.ps1 next, then restart the app and test its features."
Write-Host "Verify free space with Get-Volume / Win32_LogicalDisk, not by folder size."
