# TRAE Codex + Claude 右侧标签修复

这是一个面向 Windows 版 TRAE CN 的本地补丁工具，用于调整 Codex 与 Claude Code 扩展的面板入口和标签分组行为。

## 功能

- 将 Codex 与 Claude Code 的视图容器从次级侧边栏调整到活动栏。
- 将 Codex 编辑器标题入口改为“新建 Codex 面板”。
- 新建 Codex 面板时，优先复用已有 Codex/Claude 编辑器组。
- 新建 Claude 面板时，优先复用已有 Codex/Claude 编辑器组。
- 在没有可复用分组时，在当前编辑器旁打开面板。
- 保留 Codex 默认首页，而不是强制进入空白新会话路由。
- 修改前验证 JSON 和 JavaScript 语法，修改后再次验证。
- 支持幂等运行和 `-VerifyOnly` 只验证模式。
- 修改失败时自动用本次运行前创建的本地备份回滚。

## 原理

脚本在用户扩展目录中查找最新版：

- `openai.chatgpt-*`（Codex）
- `anthropic.claude-code-*`（Claude Code）

随后对两个扩展的 `package.json` 与已打包 JavaScript 入口执行严格、可识别的定点修改。脚本要求兼容代码只能唯一命中；未命中或多次命中都会停止，不会进行模糊替换。写入采用临时文件，并在写入前后执行 JSON 解析与 Node.js `--check` 语法检查。

本仓库不包含、分发或还原任何第三方扩展源文件。

## 安装与使用

### 前提

- Windows 10 或 Windows 11。
- 已安装 TRAE CN、Codex 扩展和 Claude Code 扩展。
- `node` 命令可用。TRAE 自带运行时不一定会自动加入终端的 `PATH`；如命令不可用，请先安装 Node.js 或将可用的 Node.js 加入 `PATH`。

### 一键运行

1. 下载本仓库中的两个脚本，并放在同一目录。
2. 退出正在运行的相关扩展任务，建议先关闭 TRAE。
3. 双击 `一键修复TRAE-AI右侧标签.cmd`。
4. 成功后打开 TRAE，执行命令“开发人员: 重新加载窗口”。

### PowerShell 运行

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\fix-trae-ai-panels.ps1
```

仅检查当前最新版扩展是否已处于目标状态：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\fix-trae-ai-panels.ps1 -VerifyOnly
```

如果扩展安装在其他目录，可明确指定根目录或两个扩展目录：

```powershell
.\fix-trae-ai-panels.ps1 -ExtensionsRoot '扩展根目录'
.\fix-trae-ai-panels.ps1 -CodexPath 'Codex扩展目录' -ClaudePath 'Claude扩展目录'
```

路径参数应指向你自己的本机目录；请勿在公开 Issue 中粘贴包含用户名等隐私信息的完整路径。

## 支持版本

脚本按扩展目录中的 `package.json` 版本号选择最新版，不绑定 TRAE 的固定版本号。当前补丁仅支持同时满足以下结构的版本：

- Codex 扩展 ID 目录匹配 `openai.chatgpt-*`，入口为 `out/extension.js`。
- Claude Code 扩展 ID 目录匹配 `anthropic.claude-code-*`，入口为 `extension.js`。
- 打包代码与脚本内列出的兼容片段一致。

扩展升级可能改变打包代码。遇到不兼容版本时，脚本会以“无法唯一识别兼容代码”等错误停止。停止是安全保护，不代表可以强行跳过验证。提交兼容性报告时，请只提供 TRAE、Codex、Claude Code 的版本号和脱敏后的错误信息。

## 扩展更新后

扩展更新会覆盖补丁。每次更新 Codex 或 Claude Code 后，请重新运行脚本，再执行“开发人员: 重新加载窗口”。可先运行 `-VerifyOnly` 判断是否需要重新应用。

## 风险

- 本工具会直接修改已安装扩展的清单和打包 JavaScript，属于非官方补丁。
- 扩展签名、完整性检查、企业安全策略或后续更新可能使修改失效或导致扩展被禁用。
- 上游实现变化可能导致脚本拒绝执行；不要删除校验或手工扩大替换范围。
- 补丁可能影响面板布局、命令入口或扩展启动。重要环境中请先评估并自行承担使用风险。
- 运行期间会在扩展根目录的 `.trae-ai-panel-backup` 下生成本地恢复副本，其中可能包含第三方扩展代码；请勿上传、提交或分发该目录。

## 卸载与恢复

推荐使用以下任一方式恢复官方文件：

1. 在 TRAE 中卸载并重新安装 Codex 与 Claude Code 扩展；或
2. 关闭 TRAE，将 `.trae-ai-panel-backup` 中最近一次运行对应的文件复制回各自扩展目录，然后重新打开 TRAE。

恢复后可删除 `.trae-ai-panel-backup`。如果只想停止使用，无需卸载本仓库中的脚本；不要再次运行即可。扩展下一次更新通常也会覆盖补丁。

## 安全

请参阅 [SECURITY.md](SECURITY.md)。公开报告不得附带 API Key、访问令牌、扩展文件、备份、日志、个人路径或其他隐私数据。

## 许可

本仓库自有脚本与文档采用 [MIT License](LICENSE) 发布。Codex、Claude Code、TRAE 及其扩展归各自权利人所有。
