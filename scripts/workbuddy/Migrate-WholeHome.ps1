<#
  整体 home 迁移（首选方案）
  把应用数据根目录本身改成一个目录联接，而不是逐个目录建链接。
  好处：根目录里的散文件、以后新建的任何内容，全部自动落到目标盘。

  用法示例（先把尖括号占位符换成真实值）：
    .\scripts\Migrate-WholeHome.ps1 -SourceRoot '<APP_HOME>' -TargetRoot '<TARGET_ROOT>' -GuardProcess '<PROCESS>' -WhatIf

  迁移已完成、只想清退路时，再运行一次并加 -CleanupBackup 即可。
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$SourceRoot,
  [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$TargetRoot,
  [string]$GuardProcess = '<PROCESS>',
  [string]$BackupSuffix = '.migbak',
  [switch]$CleanupBackup
)

$ErrorActionPreference = 'Stop'
# -WhatIf only controls this script's own plan branch; do not let read-only cmdlets inherit it.
$PlanOnly = [bool]$WhatIfPreference
$WhatIfPreference = $false

function Say([string]$Text) { Write-Host $Text }
function TrimPath([string]$p) { return $p.TrimEnd([char]92) }
function Get-Tree([string]$Root) {
  $r = TrimPath $Root
  @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File -ErrorAction SilentlyContinue |
    ForEach-Object { "{0}|{1}" -f $_.FullName.Substring($r.Length + 1), $_.Length } | Sort-Object)
}

function Remove-BackupSafely([string]$BakPath, [string]$TargetPath) {
  Say ""
  Say "退路：$BakPath"
  $bkItems = @(Get-ChildItem -LiteralPath $BakPath -Force)
  $childLinks = @($bkItems | Where-Object { $_.Attributes -match 'ReparsePoint' -or $_.LinkType })
  Say "其中含 $($childLinks.Count) 个子链接，指向目标盘的真实数据。"
  Say "绝对不要用 -Recurse 删除这个退路：递归会顺着链接删掉目标盘数据。"

  # 硬闸门：备份中的非链接内容必须已被目标盘覆盖（允许目标多出应用新写入的文件）
  $gateBad = @()
  foreach ($it in @($bkItems | Where-Object { $_.Attributes -notmatch 'ReparsePoint' -and -not $_.LinkType })) {
    if ($it.PSIsContainer) {
      foreach ($line in (Get-Tree $it.FullName)) {
        $rel = ($line -split '\|')[0]
        if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $TargetPath $it.Name) $rel))) {
          $gateBad += "$($it.Name)\$rel"
        }
      }
    } else {
      if (-not (Test-Path -LiteralPath (Join-Path $TargetPath $it.Name))) { $gateBad += $it.Name }
    }
  }
  if ($gateBad.Count -gt 0) {
    Say "清理闸门未通过：目标盘缺少 $($gateBad.Count) 个备份中的条目，退路保留。"
    $gateBad | Select-Object -First 10 | ForEach-Object { Say "  $_" }
    return $false
  }
  Say "清理闸门通过：备份中的非链接内容已被目标盘完整覆盖。"

  # 递归复查整棵子树，LinkType 可能为空，ReparsePoint 才是可靠依据
  $nested = @(Get-ChildItem -LiteralPath $BakPath -Recurse -Force -Directory -ErrorAction SilentlyContinue |
              Where-Object { $_.Attributes -match 'ReparsePoint' })
  foreach ($l in $nested) {
    try { [System.IO.Directory]::Delete($l.FullName, $false) }
    catch { Say "无法移除嵌套链接：$($l.FullName)。退路保留。"; return $false }
  }
  foreach ($l in $childLinks) {
    if (Test-Path -LiteralPath $l.FullName) { [System.IO.Directory]::Delete($l.FullName, $false) }
  }
  Say "已非递归删除 $($childLinks.Count) 个顶层子链接。"

  # 此时树里已无链接，才能安全删除真实内容
  foreach ($it in @(Get-ChildItem -LiteralPath $BakPath -Force)) {
    if ($it.PSIsContainer) {
      Get-ChildItem -LiteralPath $it.FullName -Recurse -Force -File -ErrorAction SilentlyContinue |
        ForEach-Object { try { [System.IO.File]::SetAttributes($_.FullName, [System.IO.FileAttributes]::Normal) } catch {} }
      [System.IO.Directory]::Delete($it.FullName, $true)
    } else {
      try { [System.IO.File]::SetAttributes($it.FullName, [System.IO.FileAttributes]::Normal) } catch {}
      [System.IO.File]::Delete($it.FullName)
    }
  }
  [System.IO.Directory]::Delete($BakPath, $false)
  Say "退路已安全清除，原盘只剩一个链接。"
  return $true
}

Say "=== 整体 home 迁移 ==="
Say "--- 准备阶段 ---"

# 0 占位符守卫：未替换的尖括号在 Windows 路径里是非法字符
$unresolved = @($SourceRoot, $TargetRoot, $GuardProcess) | Where-Object { $_ -match '<[A-Z_]+>' }
if ($unresolved.Count -gt 0) {
  Say "以下占位符还没替换，请先改成真实值："
  $unresolved | ForEach-Object { Say "  $_" }
  Say "脚本已停止，未改动任何文件。"
  exit 1
}

$srcTrim = TrimPath $SourceRoot
$bak = "$srcTrim$BackupSuffix"

# 源/目标不能是盘根，不能互相嵌套（防止自我复制）
$srcTrim = $srcTrim.TrimEnd([char]92)
$tgtTrim = (TrimPath $TargetRoot).TrimEnd([char]92)
if ($srcTrim -match '^[A-Za-z]:\\?$' -or $tgtTrim -match '^[A-Za-z]:\\?$') { throw '源/目标不能是盘根，必须指向具体目录' }
$fullSrc = [System.IO.Path]::GetFullPath($srcTrim + '\')
$fullTgt = [System.IO.Path]::GetFullPath($tgtTrim + '\')
if ([string]::Equals($fullSrc, $fullTgt, [StringComparison]::OrdinalIgnoreCase)) { throw '源与目标是同一目录' }
if ($fullTgt.StartsWith($fullSrc, [StringComparison]::OrdinalIgnoreCase)) { throw '目标在源目录内部——会自我复制' }
if ($fullSrc.StartsWith($fullTgt, [StringComparison]::OrdinalIgnoreCase)) { throw '源在目标目录内部' }

# 1 源检查。已完成迁移时，允许用 -CleanupBackup 单独清退路（不需要应用退出）
if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) { throw "源目录不存在：$SourceRoot" }
$srcItem = Get-Item -LiteralPath $SourceRoot -Force
if ($srcItem.LinkType) {
  if ($CleanupBackup -and (Test-Path -LiteralPath $bak)) {
    Say "根目录已是链接，进入退路清理模式。"
    if (Remove-BackupSafely $bak $TargetRoot) { exit 0 } else { exit 1 }
  }
  Say "源目录本身已经是 $($srcItem.LinkType)，无需重复迁移。未改动任何文件。"
  if (Test-Path -LiteralPath $bak) { Say "退路仍在；如需清理，请加 -CleanupBackup 再运行一次。" }
  exit 0
}

# 2 进程守卫（正式迁移必须完全退出应用）
$running = @(Get-Process -Name $GuardProcess -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) {
  Say "应用仍在运行（$($running.Count) 个进程）。"
  if ($PlanOnly) {
    Say "演练（-WhatIf）允许应用运行；正式执行前必须从托盘完全退出。"
  } else {
    Say "请从托盘完全退出并在任务管理器确认无残留。脚本已停止，未改动任何文件。"
    exit 1
  }
} else {
  Say "进程守卫通过：应用已完全退出。"
}

# 3 目标盘检查（.NET DriveInfo：不受 -WhatIf 影响，避免 CIM 继承 WhatIf 返回空）
$driveId = ([System.IO.Path]::GetPathRoot($TargetRoot)).TrimEnd([char]92)
try {
  $di = New-Object System.IO.DriveInfo($driveId + '\')
  $vol = [pscustomobject]@{ DriveType = [int]$di.DriveType; FileSystem = $di.DriveFormat }
} catch { throw "无法读取目标盘信息：$driveId" }
if ($vol.DriveType -ne 3) { throw "目标盘不是本地固定盘" }
if ($vol.FileSystem -ne 'NTFS') { throw "目标盘不是 NTFS，目录联接要求 NTFS" }
if (Test-Path -LiteralPath $TargetRoot) {
  $ti = Get-Item -LiteralPath $TargetRoot -Force
  if ($ti.LinkType) { throw "目标根本身是链接，拒绝操作（递归删除会伤到链接指向的数据）" }
}

$top   = @(Get-ChildItem -LiteralPath $SourceRoot -Force)
$links = @($top | Where-Object { $_.Attributes -match 'ReparsePoint' -or $_.LinkType })
$real  = @($top | Where-Object { $_.Attributes -notmatch 'ReparsePoint' -and -not $_.LinkType })
Say "源目录顶层 $($top.Count) 项：已有链接 $($links.Count) 个，待复制 $($real.Count) 个。"
Say "目标根：$TargetRoot"
Say "--- 开始复制 ---"
if ($PlanOnly) {
  Say "【演练】将执行：复制 $($real.Count) 个真实项目（/XJ 跳过已有链接）→ 逐文件校验 → 原目录改名留退路 → 整目录建 Junction → 写入探针验证。"
  Say "【演练】未改动任何文件。去掉 -WhatIf 才会正式执行。"
  exit 0
}

# 4 复制：/XJ 必须带，否则会跟随已有的子 Junction
New-Item -ItemType Directory -Path $TargetRoot -Force | Out-Null
& robocopy $SourceRoot $TargetRoot /E /COPY:DAT /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "复制失败，robocopy 退出码 $LASTEXITCODE。原目录未改动。" }
Say "复制完成（robocopy 退出码 $LASTEXITCODE）。"

# 5 校验：每个真实顶层项在目标侧存在，且内容逐文件一致
$missing = @($real | Where-Object { -not (Test-Path -LiteralPath (Join-Path $TargetRoot $_.Name)) })
if ($missing.Count -gt 0) {
  Say "校验失败：目标盘缺少 $($missing.Count) 项，原目录未改动。"
  $missing | Select-Object -First 10 | ForEach-Object { Say "  $($_.Name)" }
  exit 1
}
$bad = @()
foreach ($it in $real) {
  if ($it.PSIsContainer) {
    $a = Get-Tree $it.FullName
    $b = Get-Tree (Join-Path $TargetRoot $it.Name)
    $d = @(Compare-Object -ReferenceObject $a -DifferenceObject $b)
    if ($d.Count -ne 0) { $bad += "$($it.Name):$($d.Count)" }
  } else {
    $t = Get-Item -LiteralPath (Join-Path $TargetRoot $it.Name) -Force
    if ($t.Length -ne $it.Length) { $bad += "$($it.Name):size" }
  }
}
if ($bad.Count -gt 0) {
  Say "逐文件校验失败：$($bad -join ', ')。原目录未改动。"
  exit 1
}
Say "逐文件校验通过（$($real.Count) 项）。"

# 6 改名留退路 + 整目录建 Junction
if (Test-Path -LiteralPath $bak) { throw "退路已存在，请先处理：$bak" }
$leaf = [System.IO.Path]::GetFileName($srcTrim)
Rename-Item -LiteralPath $SourceRoot -NewName "$leaf$BackupSuffix" -ErrorAction Stop
Say "原目录已改名为退路：$bak"
try {
  $link = New-Item -ItemType Junction -Path $SourceRoot -Target $TargetRoot -ErrorAction Stop
  if ($link.LinkType -ne 'Junction') { throw "LinkType 不是 Junction" }
} catch {
  Rename-Item -LiteralPath $bak -NewName $leaf -ErrorAction SilentlyContinue
  Say "建链接失败，已回滚：$($_.Exception.Message)"
  exit 1
}
Say "根目录 Junction 已建立。"

# 7 穿透验证 + 写入探针（证明以后新建的内容也落到目标盘）
$check = Get-Item -LiteralPath $SourceRoot -Force
$targetOk = [string]::Equals((TrimPath (@($check.Target)[0])), (TrimPath $TargetRoot), [StringComparison]::OrdinalIgnoreCase)
if (-not $targetOk) { Say "警告：链接目标与预期不完全一致，请人工核对。" }
$probeName = '_whole_home_probe.tmp'
[System.IO.File]::WriteAllText((Join-Path $SourceRoot $probeName), 'probe')
$probeOk = Test-Path -LiteralPath (Join-Path $TargetRoot $probeName)
if ($probeOk) { [System.IO.File]::Delete((Join-Path $TargetRoot $probeName)) }
if (-not $probeOk) {
  Say "写入探针失败：经原路径新建的文件没有出现在目标盘，请检查链接。"
  exit 1
}
Say "写入探针通过：经原路径新建的文件直接出现在目标盘，原盘不会再长出新数据。"

# 8 退路处理：默认保留，必须显式选择才清理
if ($CleanupBackup) {
  if (-not (Remove-BackupSafely $bak $TargetRoot)) { exit 1 }
} else {
  Say ""
  Say "退路：$bak"
  Say "其中含 $($links.Count) 个子链接，指向目标盘的真实数据。"
  Say "绝对不要用 -Recurse 删除这个退路：递归会顺着链接删掉目标盘数据。"
  Say "本次保留退路。确认应用一切正常后，加 -CleanupBackup 再运行一次即可安全清除。"
}

Say ""
Say "完成。以后应用在这个目录里新建的任何文件和子目录，都会直接落到目标盘。"
