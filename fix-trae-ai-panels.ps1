[CmdletBinding()]
param(
  [string]$ExtensionsRoot = (Join-Path $env:USERPROFILE '.trae-cn\extensions'),
  [string]$CodexPath = '',
  [string]$ClaudePath = '',
  [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
$PatchId = 'trae-ai-shared-right-group-v4'

function Write-Utf8NoBom([string]$Path, [string]$Content) {
  [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Assert-Json([string]$Path) {
  $null = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
}

function Assert-JavaScript([string]$Path) {
  $node = Get-Command node -ErrorAction SilentlyContinue
  if (!$node) { throw '未找到 node，无法执行 JavaScript 语法验证。' }
  & $node.Source --check $Path
  if ($LASTEXITCODE -ne 0) { throw "JavaScript 语法验证失败：$Path" }
}

function Get-Version([string]$Path) {
  $packagePath = Join-Path $Path 'package.json'
  if (!(Test-Path -LiteralPath $packagePath -PathType Leaf)) { return [version]'0.0.0.0' }
  try {
    $raw = [string](([IO.File]::ReadAllText($packagePath) | ConvertFrom-Json).version)
    $numeric = ($raw -replace '^v', '') -replace '[-+].*$', ''
    $parts = @($numeric.Split('.') | ForEach-Object { if ($_ -match '^\d+$') { [int]$_ } else { 0 } })
    while ($parts.Count -lt 4) { $parts += 0 }
    return [version](($parts[0..3] -join '.'))
  } catch { return [version]'0.0.0.0' }
}

function Find-Extension([string]$ExplicitPath, [string]$Pattern, [string]$Label) {
  if (![string]::IsNullOrWhiteSpace($ExplicitPath)) {
    if (!(Test-Path -LiteralPath $ExplicitPath -PathType Container)) { throw "$Label 扩展目录不存在：$ExplicitPath" }
    return (Resolve-Path -LiteralPath $ExplicitPath).Path
  }
  if (!(Test-Path -LiteralPath $ExtensionsRoot -PathType Container)) { throw "扩展根目录不存在：$ExtensionsRoot" }
  $items = @(Get-ChildItem -LiteralPath $ExtensionsRoot -Directory | Where-Object Name -like $Pattern)
  if ($items.Count -eq 0) { throw "未找到 $Label 扩展（$Pattern）。" }
  return ($items | Sort-Object @{ Expression = { Get-Version $_.FullName }; Descending = $true }, LastWriteTime -Descending | Select-Object -First 1).FullName
}

function Replace-One([string]$Content, [string[]]$OldValues, [string]$NewValue, [string]$Label) {
  if ($Content.Contains($NewValue)) { return @{ Content = $Content; Changed = $false; State = 'patched' } }
  $matches = @($OldValues | Where-Object { $Content.Contains($_) })
  if ($matches.Count -ne 1) { throw "$Label：无法唯一识别兼容代码（命中 $($matches.Count) 个）。" }
  $old = $matches[0]
  $first = $Content.IndexOf($old, [StringComparison]::Ordinal)
  if ($first -lt 0 -or $Content.IndexOf($old, $first + $old.Length, [StringComparison]::Ordinal) -ge 0) {
    throw "$Label：目标代码出现多次，拒绝修改。"
  }
  return @{ Content = $Content.Replace($old, $NewValue); Changed = $true; State = 'changed' }
}

function Set-CommandIcon($Package, [string]$CommandId, [string]$Light, [string]$Dark) {
  $commands = @($Package.contributes.commands | Where-Object command -eq $CommandId)
  if ($commands.Count -ne 1) { throw "命令 $CommandId 数量异常。" }
  $icon = $commands[0].icon
  if ($icon -and $icon.light -eq $Light -and $icon.dark -eq $Dark) { return $false }
  $commands[0].icon = [pscustomobject]@{ light = $Light; dark = $Dark }
  return $true
}

function Set-EditorTitleCommand($Package, [string]$OldCommand, [string]$NewCommand) {
  $items = @($Package.contributes.menus.'editor/title')
  $oldItems = @($items | Where-Object command -eq $OldCommand)
  $newItems = @($items | Where-Object command -eq $NewCommand)
  if ($oldItems.Count -gt 1) { throw "Codex editor/title 中 $OldCommand 数量异常。" }
  if ($oldItems.Count -eq 0 -and $newItems.Count -eq 0) { throw 'Codex editor/title 中未找到兼容入口。' }

  # 更新后若旧入口重新出现，必须在原位置改命令；已有的新入口随即去重。
  $keeper = if ($oldItems.Count -eq 1) { $oldItems[0] } else { $newItems[0] }
  $changed = $false
  if ($keeper.command -ne $NewCommand) { $keeper.command = $NewCommand; $changed = $true }
  $deduped = @()
  foreach ($item in $items) {
    if ([object]::ReferenceEquals($item, $keeper)) { $deduped += $keeper; continue }
    if ($item.command -eq $OldCommand) { $changed = $true; continue }
    if ($item.command -eq $NewCommand) { $changed = $true; continue }
    $deduped += $item
  }
  $Package.contributes.menus.'editor/title' = $deduped
  return $changed
}

function Move-ViewContainerToActivityBar($Package, [string]$ContainerId, [string]$Label) {
  $containers = $Package.contributes.viewsContainers
  if (!$containers) { throw "$Label：缺少 viewsContainers。" }
  $activity = @($containers.activitybar)
  $secondary = if ($containers.PSObject.Properties.Name -contains 'secondarySidebar') { @($containers.secondarySidebar) } else { @() }
  $matches = @($activity + $secondary | Where-Object id -eq $ContainerId)
  if ($matches.Count -eq 0) { throw "$Label：未找到容器 $ContainerId。" }

  $keeper = @($activity | Where-Object id -eq $ContainerId | Select-Object -First 1)
  $changed = $false
  if ($keeper.Count -eq 0) { $keeper = @($matches[0]); $changed = $true }
  $newActivity = @($activity | Where-Object id -ne $ContainerId) + $keeper[0]
  $newSecondary = @($secondary | Where-Object id -ne $ContainerId)
  if (@($activity | Where-Object id -eq $ContainerId).Count -ne 1) { $changed = $true }
  if ($newSecondary.Count -ne $secondary.Count) { $changed = $true }
  $containers.activitybar = $newActivity
  if ($containers.PSObject.Properties.Name -contains 'secondarySidebar') {
    $containers.secondarySidebar = $newSecondary
  }
  return $changed
}

$CodexPath = Find-Extension $CodexPath 'openai.chatgpt-*' 'Codex'
$ClaudePath = Find-Extension $ClaudePath 'anthropic.claude-code-*' 'Claude Code'
$codexPackagePath = Join-Path $CodexPath 'package.json'
$codexJsPath = Join-Path $CodexPath 'out\extension.js'
$claudePackagePath = Join-Path $ClaudePath 'package.json'
$claudeJsPath = Join-Path $ClaudePath 'extension.js'
foreach ($path in @($codexPackagePath, $codexJsPath, $claudePackagePath, $claudeJsPath)) {
  if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "缺少目标文件：$path" }
}

Assert-Json $codexPackagePath
Assert-Json $claudePackagePath
Assert-JavaScript $codexJsPath
Assert-JavaScript $claudeJsPath
$codexPackage = [IO.File]::ReadAllText($codexPackagePath) | ConvertFrom-Json
$claudePackage = [IO.File]::ReadAllText($claudePackagePath) | ConvertFrom-Json
$codexJs = [IO.File]::ReadAllText($codexJsPath)
$claudeJs = [IO.File]::ReadAllText($claudeJsPath)

Write-Host "TRAE 扩展目录：$ExtensionsRoot"
Write-Host "Codex：$($codexPackage.version)  $CodexPath"
Write-Host "Claude：$($claudePackage.version)  $ClaudePath"

# Codex：优先复用已有 Codex/Claude 编辑器组；首次没有 AI 标签时才在右侧拆分。
# 不传 initialRoute，Codex 使用扩展默认首页（任务历史），而不是 /extension/panel/new 空白会话。
$codexOld = @(
  'async createNewPanel(){let e=CA("/extension/panel/new"),r=Pe.window.activeTextEditor?.viewColumn??Pe.ViewColumn.Active;await Pe.commands.executeCommand("vscode.openWith",e,t.customEditorViewType,{viewColumn:r,preserveFocus:!1,preview:!1})}',
  'async createNewPanel(){await this.createEditorPanel({viewColumn:Pe.ViewColumn.Beside,preserveFocus:!1,title:Pye,initialRoute:"/extension/panel/new"})}',
  'async createNewPanel(){let e=Pe.window.tabGroups.all.find(r=>r.tabs.some(n=>{let o=n.input;return o instanceof Pe.TabInputWebview&&(o.viewType===t.panelViewType||o.viewType==="claudeVSCodePanel")})),r=e?.viewColumn??Pe.ViewColumn.Beside;await this.createEditorPanel({viewColumn:r,preserveFocus:!1,title:Pye})}'
)
$codexNew = 'async createNewPanel(){let e=Pe.window.tabGroups.all.find(r=>r.tabs.some(n=>{let o=n.input;return o instanceof Pe.TabInputWebview&&(o.viewType===t.panelViewType||o.viewType.includes("claudeVSCodePanel"))})),r=e?.viewColumn??Pe.ViewColumn.Beside;await this.createEditorPanel({viewColumn:r,preserveFocus:!1,title:Pye})}'
$codexResult = Replace-One $codexJs $codexOld $codexNew 'Codex createNewPanel'
$codexJs = $codexResult.Content
$codexPackageChanged = Set-CommandIcon $codexPackage 'chatgpt.newCodexPanel' 'resources/blossom-black.svg' 'resources/blossom-white.svg'
$codexPackageChanged = (Set-EditorTitleCommand $codexPackage 'chatgpt.openSidebar' 'chatgpt.newCodexPanel') -or $codexPackageChanged
$codexPackageChanged = (Move-ViewContainerToActivityBar $codexPackage 'codexSecondaryViewContainer' 'Codex') -or $codexPackageChanged

# Claude：原实现只复用“全是 Claude 标签”的组；改为复用含 Codex 或 Claude Webview 的共享组。
$claudeOld = 'let a=Tt.window.tabGroups.all.find((c)=>{if(c.tabs.length===0)return!1;return c.tabs.every((l)=>{if(l.input instanceof Tt.TabInputWebview)return l.input.viewType.includes("claudeVSCodePanel");return!1})});if(a&&a.viewColumn)i=a.viewColumn;else i=this.findUnusedColumn(),n=!0'
$claudeNew = 'let a=Tt.window.tabGroups.all.find(c=>c.tabs.some(l=>{let u=l.input;return u instanceof Tt.TabInputWebview&&(u.viewType.includes("claudeVSCodePanel")||u.viewType==="chatgpt.panelView")}));if(a&&a.viewColumn)i=a.viewColumn;else i=Tt.ViewColumn.Beside,n=!0'
$claudeResult = Replace-One $claudeJs @($claudeOld) $claudeNew 'Claude createPanel'
$claudeJs = $claudeResult.Content
$claudePackageChanged = Move-ViewContainerToActivityBar $claudePackage 'claude-sidebar-secondary' 'Claude'

$codexPackageText = $codexPackage | ConvertTo-Json -Depth 100
$claudePackageText = $claudePackage | ConvertTo-Json -Depth 100
$codexEditorTitle = @($codexPackage.contributes.menus.'editor/title')
$codexActivitybar = @($codexPackage.contributes.viewsContainers.activitybar)
$codexSecondarySidebar = if ($codexPackage.contributes.viewsContainers.PSObject.Properties.Name -contains 'secondarySidebar') { @($codexPackage.contributes.viewsContainers.secondarySidebar) } else { @() }
$claudeActivitybar = @($claudePackage.contributes.viewsContainers.activitybar)
$claudeSecondarySidebar = if ($claudePackage.contributes.viewsContainers.PSObject.Properties.Name -contains 'secondarySidebar') { @($claudePackage.contributes.viewsContainers.secondarySidebar) } else { @() }
$changed = $codexResult.Changed -or $claudeResult.Changed -or $codexPackageChanged -or $claudePackageChanged
$verification = [ordered]@{
  patchId = $PatchId
  codexVersion = [string]$codexPackage.version
  claudeVersion = [string]$claudePackage.version
  codexSharedGroup = $codexJs.Contains($codexNew)
  codexFullShell = !$codexJs.Contains('initialRoute:"/extension/panel/new"')
  claudeSharedGroup = $claudeJs.Contains($claudeNew)
  codexMenuNewPanelOnce = (@($codexEditorTitle | Where-Object command -eq 'chatgpt.newCodexPanel').Count -eq 1)
  codexMenuOldSidebarAbsent = (@($codexEditorTitle | Where-Object command -eq 'chatgpt.openSidebar').Count -eq 0)
  codexSecondaryInActivitybar = (@($codexActivitybar | Where-Object id -eq 'codexSecondaryViewContainer').Count -eq 1)
  codexUnsupportedSecondaryAbsent = (@($codexSecondarySidebar | Where-Object id -eq 'codexSecondaryViewContainer').Count -eq 0)
  claudeSecondaryInActivitybar = (@($claudeActivitybar | Where-Object id -eq 'claude-sidebar-secondary').Count -eq 1)
  claudeUnsupportedSecondaryAbsent = (@($claudeSecondarySidebar | Where-Object id -eq 'claude-sidebar-secondary').Count -eq 0)
}
if (@($verification.Values | Where-Object { $_ -is [bool] -and !$_ }).Count -gt 0) { throw "补丁状态验证失败：$($verification | ConvertTo-Json -Compress)" }
if ($VerifyOnly) {
  if ($changed) { throw "当前最新版扩展尚未处于目标状态，请不带 -VerifyOnly 运行脚本。" }
  Write-Host "验证通过（已安装且幂等）：$($verification | ConvertTo-Json -Compress)"
  exit 0
}
if (!$changed) { Write-Host "已是目标状态（幂等）：$($verification | ConvertTo-Json -Compress)"; exit 0 }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot = Join-Path $ExtensionsRoot ".trae-ai-panel-backup\$stamp"
$codexBackup = Join-Path $backupRoot 'codex'
$claudeBackup = Join-Path $backupRoot 'claude'
New-Item -ItemType Directory -Path $codexBackup, $claudeBackup -Force | Out-Null
[IO.File]::Copy($codexPackagePath, (Join-Path $codexBackup 'package.json'), $true)
[IO.File]::Copy($codexJsPath, (Join-Path $codexBackup 'extension.js'), $true)
[IO.File]::Copy($claudePackagePath, (Join-Path $claudeBackup 'package.json'), $true)
[IO.File]::Copy($claudeJsPath, (Join-Path $claudeBackup 'extension.js'), $true)
Write-Host "备份：$backupRoot"

$temps = @{
  CodexPackage = "$codexPackagePath.trae-fix.tmp.json"
  CodexJs = "$codexJsPath.trae-fix.tmp.js"
  ClaudePackage = "$claudePackagePath.trae-fix.tmp.json"
  ClaudeJs = "$claudeJsPath.trae-fix.tmp.js"
}
try {
  Write-Utf8NoBom $temps.CodexPackage $codexPackageText
  Write-Utf8NoBom $temps.CodexJs $codexJs
  Write-Utf8NoBom $temps.ClaudePackage $claudePackageText
  Write-Utf8NoBom $temps.ClaudeJs $claudeJs
  Assert-Json $temps.CodexPackage
  Assert-Json $temps.ClaudePackage
  Assert-JavaScript $temps.CodexJs
  Assert-JavaScript $temps.ClaudeJs
  [IO.File]::Copy($temps.CodexPackage, $codexPackagePath, $true)
  [IO.File]::Copy($temps.CodexJs, $codexJsPath, $true)
  [IO.File]::Copy($temps.ClaudePackage, $claudePackagePath, $true)
  [IO.File]::Copy($temps.ClaudeJs, $claudeJsPath, $true)
  Assert-Json $codexPackagePath
  Assert-Json $claudePackagePath
  Assert-JavaScript $codexJsPath
  Assert-JavaScript $claudeJsPath
  $installedCodexJs = [IO.File]::ReadAllText($codexJsPath)
  $installedClaudeJs = [IO.File]::ReadAllText($claudeJsPath)
  if (!$installedCodexJs.Contains($codexNew)) { throw 'Codex 落盘后幂等校验失败。' }
  if (!$installedClaudeJs.Contains($claudeNew)) { throw 'Claude 落盘后幂等校验失败。' }
} catch {
  [IO.File]::Copy((Join-Path $codexBackup 'package.json'), $codexPackagePath, $true)
  [IO.File]::Copy((Join-Path $codexBackup 'extension.js'), $codexJsPath, $true)
  [IO.File]::Copy((Join-Path $claudeBackup 'package.json'), $claudePackagePath, $true)
  [IO.File]::Copy((Join-Path $claudeBackup 'extension.js'), $claudeJsPath, $true)
  throw
} finally {
  foreach ($temp in $temps.Values) { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

Write-Host "补丁完成：$($verification | ConvertTo-Json -Compress)"
Write-Host '请在 TRAE 中执行“开发人员: 重新加载窗口”。'
