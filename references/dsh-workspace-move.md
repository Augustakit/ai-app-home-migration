# 搬迁 DSH 工作区目录（可选）

`.dsh` 数据根的迁移是主任务；工作区文件是另一件事。只有用户明确要把工作区也搬到新盘时才做。

## 关键事实

- `storages\workspace.json` 的 `path` 是工作区创建时的 `fs.realpath` 规范化路径。
- 每个 session 的 header 存着自己的 `cwd`；DSH 启动时把 `cwd` 过 `fs.realpath` 后和 workspace 的 `path` 比较，一致才归入该工作区。
- 所以：**工作区搬到新盘后，要把 `workspace.json` 的 `path` 改成新真实路径，并在旧父目录留 Junction**；否则旧 session 的 cwd 解析到新路径、注册表还写着旧路径，会话会从工作区列表消失（数据不丢）。
- 不要只把工作区目录做成 Junction 却不改 `workspace.json`。

## 步骤

1. 完全退出 DSH（窗口 + 托盘/后台进程）。
2. 复制工作区（不跟随已有链接）：

   ```powershell
   robocopy 'X:\old\path\workspace' 'Y:\new\path\workspace' /E /COPY:DAT /R:1 /W:1 /XJ /NFL /NDL /NJH /NJS /NP
   if ($LASTEXITCODE -ge 8) { throw "robocopy 失败：$LASTEXITCODE" }
   ```

   核对文件数 + 总字节。

3. 备份并修改 `workspace.json` 的匹配项（只改 `path`，不要动 `sessionIds`）：

   ```powershell
   # 先备份
   $home = if ($env:DSH_HOME) { $env:DSH_HOME } else { "$env:USERPROFILE\.dsh" }
   $reg = Join-Path $home 'storages\workspace.json'
   Copy-Item -LiteralPath $reg -Destination "$reg.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

   # 找出旧路径对应的 workspace，改 path
   $old = [System.IO.Path]::GetFullPath('X:\old\path\workspace')
   $new = [System.IO.Path]::GetFullPath('Y:\new\path\workspace')
   $json = Get-Content -LiteralPath $reg -Raw | ConvertFrom-Json
   $matched = @()
   foreach ($p in $json.tables.workspaces.PSObject.Properties) {
     $wp = [string]$p.Value.path
     if ($wp -and ([System.IO.Path]::GetFullPath($wp)).Equals($old, [StringComparison]::OrdinalIgnoreCase)) {
       $p.Value.path = $new
       $matched += $p.Name
     }
   }
   if ($matched.Count -ne 1) { throw "匹配到 $($matched.Count) 个工作区，未写入" }
   $json | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $reg -Encoding UTF8
   "已更新：$($matched[0]) -> $new"
   ```

4. 在旧**父目录**建 Junction（推荐），让旧 session 的 cwd 还能解析到新真实路径：

   ```powershell
   # 例：旧工作区是 %USERPROFILE%\Documents\deepseek-harness\default-workspace，
   # 就把整个 deepseek-harness 目录做成 Junction 指向新盘的 deepseek-harness。
   cmd /c mklink /J "%USERPROFILE%\Documents\deepseek-harness" "Y:\new\path\deepseek-harness"
   ```

   如果旧路径没有历史会话指向它，这一步可以省略。

5. 重启 DSH，确认工作区和会话都在；打不开会话时才回看 `workspace.json` 的 `path` 是否等于 session cwd 的真实路径。

6. 回滚：关闭 DSH → 恢复 `workspace.json` 备份 → `cmd /c rmdir <junction>` → 视需要删除复制出来的工作区。

## 不要做

- 不要只搬一半文件，也不要用 `git clone` 代替完整复制。
- 不要删除旧工作区，直到 UI 里确认工作区和会话都正常。
- 不要把工作区目录做成 Junction 后仍让注册表指向旧字面路径。
- 不要把 `workspace.json` 删掉“重建”，那会丢工作区归属。
