# 平台识别（Detect-Platform.ps1）

**先问用户迁哪个平台，不要用检测结果替用户选。** 检测只做两件事：用户说不清时列出候选；用户已指定平台时确认数据根。一次只迁一个平台。

## 什么时候才跑检测

1. 用户已经明确平台 → 可以用 `-Platform` 确认数据根，但不要再拿别的候选劝用户改。
2. 用户说“不确定/你看着办” → 先向用户申请**只读搜索权限**（环境变量、常见数据目录、进程；不写文件），再跑检测。
3. 用户给了一个路径 → 先 `Test-Path` / `Get-Item -Force` 验证，不直接跑全盘检测。

## 命令

```powershell
$scripts = '<SKILL_DIR>\scripts'
& "$scripts\Detect-Platform.ps1"            # 人类可读
& "$scripts\Detect-Platform.ps1" -Json      # 给路由/自动化解析
& "$scripts\Detect-Platform.ps1" -Platform dsh
& "$scripts\Detect-Platform.ps1" -Platform generic -AppName '<APP_NAME>' -AppHome '<APP_DATA_ROOT>'
```

## 检测优先级

1. **用户明确说平台** → `-Platform` 直接用（仍会解析数据根）。
2. **进程**：`DeepSeek Harness.exe` / `ZCode.exe` / `WorkBuddy*`。
3. **环境变量**：`DSH_HOME`（DSH）；`ZCODE_HOME` 只作为辅助证据，ZCode 不依赖它迁移。
4. **已知目录**：`%USERPROFILE%\.dsh`、`%USERPROFILE%\.zcode`、`%USERPROFILE%\.workbuddy`、`%APPDATA%\WorkBuddy`、`%LOCALAPPDATA%\WorkBuddy`。
5. **调用方环境**：`DSH_DESKTOP_NODE_EXECUTABLE` 等宿主变量。
6. 都没有 → 问用户应用名/数据根；或 `-AppHome` 指定 generic。

## JSON 合同

```json
{
  "platform": "dsh|zcode|workbuddy|generic|null",
  "confidence": "high|medium|low",
  "ambiguous": false,
  "dataRoot": "<真实路径>",
  "displayRoot": "<脱敏路径>",
  "mechanism": "dsh-home|junction|default-path",
  "running": true,
  "candidates": [
    {
      "platform": "dsh",
      "confidence": "high",
      "dataRoot": "<真实路径>",
      "displayRoot": "%USERPROFILE%\\.dsh",
      "exists": true,
      "isJunction": false,
      "junctionTarget": null,
      "running": true,
      "mechanism": "dsh-home",
      "evidence": ["env DSH_HOME 指向数据根", "数据根存在", "进程：DeepSeek Harness"]
    }
  ],
  "recommendedAction": "加载 references/platform-dsh.md 与 scripts/dsh/"
}
```

规则：

- `ambiguous: true` → `platform`/`dataRoot` 会是 `null`；**必须问用户**“要迁移哪个平台”，不得自动选。候选列表在 `candidates` 里。
- `platform: null` → 问应用名/数据根，或用 `-AppHome` 指定 generic。
- `dataRoot` 给脚本执行用；**写进报告/文档时用 `displayRoot`**。
- 同一台机器同时装 DSH、ZCode、WorkBuddy 很正常（本机就同时命中）；这不是错误。

## 识别后的加载策略

- 只加载命中的那一份 `references/platform-*.md` 和 `scripts/<platform>/`。
- 不要把三个平台的事实混在一起：DSH 认 `DSH_HOME`，ZCode 明确不赌环境变量，WorkBuddy 是通用 AppData 兜底（仅限用户明确指定数据根）。
- 识别结果与用户说法冲突时，以用户明确指定的平台为准，并在报告中记录证据。
