<#
  DSH 数据迁移向导（纯 PowerShell 5.1，无 Python/Node 依赖）
  双击 Run-Wizard.bat 启动。
#>
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Show-Header {
  Clear-Host
  Write-Host '==============================================' -ForegroundColor Cyan
  Write-Host '        DSH 数据迁移工具（向导）' -ForegroundColor Cyan
  Write-Host '==============================================' -ForegroundColor Cyan
  Write-Host ''
}

function Pause-Menu { Write-Host ''; Read-Host '按回车返回菜单' | Out-Null }

function Invoke-Child([string]$ScriptName, [string[]]$ExtraArgs) {
  $script = Join-Path $here $ScriptName
  $base = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script)
  & powershell.exe @base @ExtraArgs | Out-Host
  return $LASTEXITCODE
}

function Ask-Target {
  $p = Read-Host '新数据目录的完整路径（例如 E:\DSHData\.dsh）'
  if ([string]::IsNullOrWhiteSpace($p)) { return $null }
  return $p.Trim().Trim('"')
}

$running = $true
while ($running) {
  Show-Header
  Write-Host '  1. 检查当前状态（只读）'
  Write-Host '  2. 演练一次迁移（只读，检查目标盘和空间）'
  Write-Host '  3. 正式迁移（复制数据；必须完全退出 DSH）'
  Write-Host '  4. 迁移后核验（重启 DSH 之后做）'
  Write-Host '  5. 修复插件安装报错（pnpm store 不一致）'
  Write-Host '  6. 回滚上一次迁移'
  Write-Host '  0. 退出'
  Write-Host ''
  $choice = Read-Host '请输入序号'

  switch ($choice) {
    '1' {
      Invoke-Child 'Verify-DshMigration.ps1' @() | Out-Null
      Pause-Menu
    }
    '2' {
      $dest = Ask-Target
      if ($dest) { Invoke-Child 'Migrate-DshHome.ps1' @('-TargetRoot', $dest, '-WhatIf') | Out-Null }
      Pause-Menu
    }
    '3' {
      Write-Host ''
      Write-Host '这个步骤会复制数据。请先完全退出 DSH（含右下角托盘/后台进程）。' -ForegroundColor Yellow
      $dest = Ask-Target
      if (-not $dest) { Pause-Menu; break }
      Write-Host ''
      Write-Host '先做只读演练：' -ForegroundColor Cyan
      $code = Invoke-Child 'Migrate-DshHome.ps1' @('-TargetRoot', $dest, '-WhatIf')
      if ($code -ne 0) {
        Write-Host ''
        Write-Host '演练没有通过，先按上面的提示处理。没有复制任何东西。' -ForegroundColor Red
        Pause-Menu
        break
      }
      Write-Host ''
      Write-Host '确认 DSH 已完全退出后，输入大写 YES 才开始复制。'
      $confirm = Read-Host '确认开始？(YES/其他=取消)'
      if ($confirm -ne 'YES') { Write-Host '已取消，没有复制任何东西。'; Pause-Menu; break }
      Invoke-Child 'Migrate-DshHome.ps1' @('-TargetRoot', $dest) | Out-Null
      Write-Host ''
      Write-Host '完成后：完全重启 DSH，再回到菜单选 4 做核验。' -ForegroundColor Green
      Pause-Menu
    }
    '4' {
      Write-Host ''
      $state = Read-Host '迁移时生成的 state 文件路径（直接回车则手动输入数据目录）'
      $target = ''
      $source = ''
      if ([string]::IsNullOrWhiteSpace($state)) {
        $home = Ask-Target
        if ($home) {
          $target = $home
          $code = Invoke-Child 'Verify-DshMigration.ps1' @('-Home', $home, '-VerifyBackup')
        } else { $code = 1 }
      } else {
        $statePath = $state.Trim().Trim('"')
        try {
          $stateObj = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
          $target = [string]$stateObj.target
          $source = [string]$stateObj.source
        } catch { Write-Host "state 文件读不出来：$($_.Exception.Message)" -ForegroundColor Red }
        $code = Invoke-Child 'Verify-DshMigration.ps1' @('-StateFile', $statePath, '-VerifyBackup')
      }
      if ($code -eq 0 -and $target) {
        Write-Host ''
        Write-Host '核验通过（退路逐文件核对也通过）。按流程应尽快清理退路，释放空间。' -ForegroundColor Green
        $clean = Read-Host '现在清理退路？(YES/其他=暂不清理)'
        if ($clean -eq 'YES') {
          $cleanArgs = @('-TargetRoot', $target, '-CleanupBackup')
          if ($source) { $cleanArgs += @('-SourceRoot', $source) }
          Invoke-Child 'Migrate-DshHome.ps1' $cleanArgs | Out-Null
        } else {
          Write-Host '已保留退路。确认稳定后再次运行本向导选 4 或手动执行 -CleanupBackup。'
        }
      }
      Pause-Menu
    }
    '5' {
      Write-Host ''
      Write-Host '先只检查，不改文件：' -ForegroundColor Cyan
      Invoke-Child 'Repair-DshPnpm.ps1' @() | Out-Null
      Write-Host ''
      $confirm = Read-Host '输入 YES 才写入修复（会自动留备份）'
      if ($confirm -eq 'YES') { Invoke-Child 'Repair-DshPnpm.ps1' @('-Execute') | Out-Null }
      else { Write-Host '未修改。' }
      Pause-Menu
    }
    '6' {
      Write-Host ''
      $state = Read-Host '粘贴迁移时生成的 state 文件路径'
      if (-not [string]::IsNullOrWhiteSpace($state)) {
        $state = $state.Trim().Trim('"')
        $confirm = Read-Host '输入 YES 确认回滚（不会删除目标盘数据）'
        if ($confirm -eq 'YES') { Invoke-Child 'Rollback-DshMigration.ps1' @('-StateFile', $state, '-Execute') | Out-Null }
        else { Write-Host '未回滚。' }
      }
      Pause-Menu
    }
    '0' { $running = $false }
    default { Write-Host '没有这个序号，请重新输入。' -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
  }
}
Write-Host '已退出。'
