[CmdletBinding()]
param(
  [string]$ExtensionsRoot = '',
  [string]$CodexPath = '',
  [string]$ClaudePath = '',
  [string]$TraeExe = '',
  [switch]$ForceTraeRuntime,
  [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
$PatchId = 'trae-ai-shared-right-group-v7'
try {
  [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
  [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
  $OutputEncoding = [Console]::OutputEncoding
} catch { }

function Write-Utf8NoBom([string]$Path, [string]$Content) {
  [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Assert-Json([string]$Path) {
  $null = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
}

function Find-TraeExe([string]$ExplicitPath) {
  if (![string]::IsNullOrWhiteSpace($ExplicitPath)) {
    $trimmed = $ExplicitPath.Trim().Trim('"')
    if (!(Test-Path -LiteralPath $trimmed -PathType Leaf)) { throw "指定的 TRAE 主程序不存在：$trimmed" }
    $resolved = (Resolve-Path -LiteralPath $trimmed).Path
    if ([IO.Path]::GetFileName($resolved) -notin @('Trae.exe', 'Trae CN.exe')) { throw "不支持的主程序名称：$resolved。只接受 Trae.exe 或 Trae CN.exe。" }
    return $resolved
  }

  # 支持国际版/国内版；修复文件可位于主程序同级或下一级 helpAI。
  $roots = @($PSScriptRoot, (Split-Path -Parent $PSScriptRoot), (Get-Location).Path) | Select-Object -Unique
  $candidates = foreach ($root in $roots) {
    Join-Path $root 'Trae.exe'
    Join-Path $root 'Trae CN.exe'
  }
  $found = @()
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $found += (Resolve-Path -LiteralPath $candidate).Path }
  }
  $found = @($found | Select-Object -Unique)
  if ($found.Count -eq 1) { return $found[0] }
  if ($found.Count -gt 1) { throw "发现多个 TRAE 主程序，无法安全选择。请通过 -TraeExe 指定其中一个：$($found -join '；')" }
  return ''
}

function Get-TraeProduct([string]$ExePath) {
  if ([string]::IsNullOrWhiteSpace($ExePath)) { throw '未提供 TRAE 主程序。' }
  $installRoot = Split-Path -Parent $ExePath
  $productPath = Join-Path $installRoot 'resources\app\product.json'
  if (!(Test-Path -LiteralPath $productPath -PathType Leaf)) { throw "无法验证 TRAE 安装：缺少 $productPath" }
  $product = [IO.File]::ReadAllText($productPath) | ConvertFrom-Json
  if ([string]::IsNullOrWhiteSpace([string]$product.dataFolderName)) { throw "TRAE 产品信息缺少 dataFolderName：$productPath" }
  return [pscustomobject]@{
    Name = if ($product.nameLong) { [string]$product.nameLong } else { [IO.Path]::GetFileNameWithoutExtension($ExePath) }
    DataFolderName = [string]$product.dataFolderName
    ExtensionsRoot = Join-Path (Join-Path $env:USERPROFILE ([string]$product.dataFolderName)) 'extensions'
  }
}

function Get-JavaScriptRuntime([string]$DetectedTraeExe, [bool]$PreferTrae) {
  if ($PreferTrae -and ![string]::IsNullOrWhiteSpace($DetectedTraeExe)) {
    return [pscustomobject]@{ Path = $DetectedTraeExe; Electron = $true; Label = 'TRAE 内置 Node.js' }
  }
  $node = Get-Command node -ErrorAction SilentlyContinue
  if ($node) { return [pscustomobject]@{ Path = $node.Source; Electron = $false; Label = '系统 Node.js' } }
  if (![string]::IsNullOrWhiteSpace($DetectedTraeExe)) {
    return [pscustomobject]@{ Path = $DetectedTraeExe; Electron = $true; Label = 'TRAE 内置 Node.js' }
  }
  throw '既未找到系统 Node.js，也未找到 TRAE 主程序。请将两个修复文件放到 Trae.exe/Trae CN.exe 同级或下一级 helpAI，或通过 -TraeExe 指定主程序。'
}

function Test-TraeRunning([string]$DetectedTraeExe) {
  if ([string]::IsNullOrWhiteSpace($DetectedTraeExe)) { return $false }
  $target = [IO.Path]::GetFullPath($DetectedTraeExe)
  foreach ($process in @(Get-Process -Name @('Trae', 'Trae CN') -ErrorAction SilentlyContinue)) {
    try {
      if ([IO.Path]::GetFullPath($process.Path) -eq $target) { return $true }
    } catch { }
  }
  return $false
}

function Assert-JavaScript([string]$Path) {
  $oldElectronMode = [Environment]::GetEnvironmentVariable('ELECTRON_RUN_AS_NODE', 'Process')
  try {
    if ($Script:JavaScriptRuntime.Electron) { $env:ELECTRON_RUN_AS_NODE = '1' }
    if ($Script:JavaScriptRuntime.Electron) {
      $process = Start-Process -FilePath $Script:JavaScriptRuntime.Path -ArgumentList @('--check', $Path) -Wait -PassThru -NoNewWindow
      $exitCode = $process.ExitCode
    } else {
      & $Script:JavaScriptRuntime.Path --check $Path
      $exitCode = $LASTEXITCODE
    }
    if ($exitCode -ne 0) { throw "JavaScript 语法验证失败（退出码 $exitCode）：$Path" }
  } finally {
    if ($null -eq $oldElectronMode) { [Environment]::SetEnvironmentVariable('ELECTRON_RUN_AS_NODE', $null, 'Process') }
    else { [Environment]::SetEnvironmentVariable('ELECTRON_RUN_AS_NODE', $oldElectronMode, 'Process') }
  }
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

$TraeExe = Find-TraeExe $TraeExe
$TraeProduct = Get-TraeProduct $TraeExe
if ([string]::IsNullOrWhiteSpace($ExtensionsRoot)) { $ExtensionsRoot = $TraeProduct.ExtensionsRoot }
$Script:JavaScriptRuntime = Get-JavaScriptRuntime $TraeExe $ForceTraeRuntime.IsPresent
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
Write-Host "TRAE 版本类型：$($TraeProduct.Name)（数据目录 $($TraeProduct.DataFolderName)）"
Write-Host "TRAE 主程序：$TraeExe"
Write-Host "语法验证运行时：$($Script:JavaScriptRuntime.Label)"
Write-Host "Codex：$($codexPackage.version)  $CodexPath"
Write-Host "Claude：$($claudePackage.version)  $ClaudePath"
if (Test-TraeRunning $TraeExe) {
  Write-Warning '检测到 TRAE 正在运行。脚本可以完成落盘验证，但必须重启 TRAE 或重新加载窗口后，新补丁才会生效。'
}

# Codex：优先复用已有 Codex/Claude 编辑器组；首次没有 AI 标签时才在右侧拆分。
# 不传 initialRoute，Codex 使用扩展默认首页（任务历史），而不是 /extension/panel/new 空白会话。
$codexOld = @(
  'async createNewPanel(){let e=ST("/extension/panel/new"),r=ke.window.activeTextEditor?.viewColumn??ke.ViewColumn.Active;await ke.commands.executeCommand("vscode.openWith",e,t.customEditorViewType,{viewColumn:r,preserveFocus:!1,preview:!1})}',
  'async createNewPanel(){let e=CA("/extension/panel/new"),r=Pe.window.activeTextEditor?.viewColumn??Pe.ViewColumn.Active;await Pe.commands.executeCommand("vscode.openWith",e,t.customEditorViewType,{viewColumn:r,preserveFocus:!1,preview:!1})}',
  'async createNewPanel(){await this.createEditorPanel({viewColumn:Pe.ViewColumn.Beside,preserveFocus:!1,title:Pye,initialRoute:"/extension/panel/new"})}',
  'async createNewPanel(){let e=Pe.window.tabGroups.all.find(r=>r.tabs.some(n=>{let o=n.input;return o instanceof Pe.TabInputWebview&&(o.viewType===t.panelViewType||o.viewType==="claudeVSCodePanel")})),r=e?.viewColumn??Pe.ViewColumn.Beside;await this.createEditorPanel({viewColumn:r,preserveFocus:!1,title:Pye})}',
  'async createNewPanel(){let e=Pe.window.tabGroups.all.find(r=>r.tabs.some(n=>{let o=n.input;return o instanceof Pe.TabInputWebview&&(o.viewType===t.panelViewType||o.viewType.includes("claudeVSCodePanel"))})),r=e?.viewColumn??Pe.ViewColumn.Beside;await this.createEditorPanel({viewColumn:r,preserveFocus:!1,title:Pye})}'
)
$codexNew = 'async createNewPanel(){let e=ke.window.tabGroups.all.find(r=>r.tabs.some(n=>{let o=n.input;return o instanceof ke.TabInputWebview&&o.viewType.includes("claudeVSCodePanel")||o instanceof ke.TabInputCustom&&o.viewType===t.customEditorViewType})),r=e?.viewColumn??ke.ViewColumn.Beside,n=ST("/extension/panel/new");await ke.commands.executeCommand("vscode.openWith",n,t.customEditorViewType,{viewColumn:r,preserveFocus:!1,preview:!1})}'
$codexResult = Replace-One $codexJs $codexOld $codexNew 'Codex createNewPanel'
$codexJs = $codexResult.Content
$codexPackageChanged = Set-CommandIcon $codexPackage 'chatgpt.newCodexPanel' 'resources/blossom-black.svg' 'resources/blossom-white.svg'
$codexPackageChanged = (Set-EditorTitleCommand $codexPackage 'chatgpt.openSidebar' 'chatgpt.newCodexPanel') -or $codexPackageChanged
$codexPackageChanged = (Move-ViewContainerToActivityBar $codexPackage 'codexSecondaryViewContainer' 'Codex') -or $codexPackageChanged

# Claude：原实现只复用“全是 Claude 标签”的组；改为复用含 Codex 或 Claude Webview 的共享组。
$claudeOld = @(
  'let a=Tt.window.tabGroups.all.find((c)=>{if(c.tabs.length===0)return!1;return c.tabs.every((l)=>{if(l.input instanceof Tt.TabInputWebview)return l.input.viewType.includes("claudeVSCodePanel");return!1})});if(a&&a.viewColumn)i=a.viewColumn;else i=this.findUnusedColumn(),n=!0',
  'let a=Tt.window.tabGroups.all.find(c=>c.tabs.some(l=>{let u=l.input;return u instanceof Tt.TabInputWebview&&(u.viewType.includes("claudeVSCodePanel")||u.viewType==="chatgpt.panelView")}));if(a&&a.viewColumn)i=a.viewColumn;else i=Tt.ViewColumn.Beside,n=!0'
)
$claudeNew = 'let a=Tt.window.tabGroups.all.find(c=>c.tabs.some(l=>{let u=l.input;return u instanceof Tt.TabInputWebview&&u.viewType.includes("claudeVSCodePanel")||u instanceof Tt.TabInputCustom&&u.viewType==="chatgpt.conversationEditor"}));if(a&&a.viewColumn)i=a.viewColumn;else i=Tt.ViewColumn.Beside,n=!0'
$claudeResult = Replace-One $claudeJs $claudeOld $claudeNew 'Claude createPanel'
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
  codexFullShell = $codexJs.Contains('commands.executeCommand("vscode.openWith"')
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
