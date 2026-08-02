# SSH Space

SSH Space 是一个轻量的 Windows 桌面 SSH 控制台。用户和本地 Agent 共用一份服务器配置，既可以在桌面应用里管理和连接，也可以直接调用 PowerShell 命令行。

项目没有 Node.js、数据库或前端框架依赖。Web 服务只监听 `127.0.0.1`，每次启动生成随机 API 令牌。

## 最简单的启动方式

主入口：

- `SSH Space.exe`：完整桌面应用。打开独立原生窗口，页面、服务器配置、导入导出和终端均在窗口内运行，不启动外部浏览器。
- `SSH Space.bat`：桌面应用的批处理入口，适合建立快捷方式或从其他脚本调用。

桌面应用使用系统 WebView2 渲染现代界面，并在后台启动或复用 `127.0.0.1` 本地服务。WebView2 组件已嵌入 EXE，首次运行会释放到用户本地缓存；Windows 缺少 WebView2 Runtime 时会显示明确错误。正式发布包同时内置官方 Win32-OpenSSH 客户端，不依赖用户另外安装 OpenSSH。

## 下载与安装

执行发布构建后，`dist\` 会生成：

- `SSH-Space-2.0.0-Setup.exe`：推荐普通用户使用的按用户安装程序，不需要管理员权限，提供开始菜单和可选桌面快捷方式。
- `SSH-Space-2.0.0-Portable.zip`：解压即用的便携版，适合 Agent 工作区或移动存储。
- `SHA256SUMS.txt`：用于校验下载文件完整性。

安装包和便携版都包含桌面程序、命令行脚本、Web 控制台和内置 OpenSSH，不包含开发者本机的服务器配置、密码、密钥、导出包、备份或运行数据。

仓库包含 GitHub Actions 发布流水线：推送到 `main` 会自动构建并保存 14 天的工作流产物；推送 `v2.0.0` 形式的标签会自动创建 GitHub Release，并上传安装包、便携版和校验文件，不需要手工上传。

```powershell
git tag v2.0.0
git push origin main --tags
```

也可以在 GitHub 的 Actions 页面手动运行 `Build and release`。手动运行会生成可下载的工作流产物，但只有版本标签会创建正式 Release。

需要排查桌面窗口时，可以在 PowerShell 中以前台模式运行内部服务：

```powershell
.\app\server.ps1
.\app\server.ps1 -NoBrowser
.\app\server.ps1 -Port 9000
```

## 桌面控制台

桌面控制台支持：

- 新建、编辑、删除服务器配置。
- 密钥、密码和连接时交互输入三种认证模式。
- 上传私钥到工作区内的隔离目录。
- 打开独立 SSH 终端，或直接在页面执行远程命令。
- 搜索、多选、单台导出、任意多选批量导出。
- 选择多个文件导入，或选择整个批量导出目录导入。
- OpenSSH 环境状态提示和配置错误提示。
- 带备份和强确认短语的恢复出厂设置。

## 命令行

```powershell
# 查看和检查配置，不发起连接
.\ssh.ps1 list
.\ssh.ps1 doctor
.\ssh.ps1 doctor prod

# 交互登录或执行远程命令
.\ssh.ps1 prod
.\ssh.ps1 prod uptime
.\ssh.ps1 prod "docker ps"

# 单台、全部或指定多台导出
.\ssh.ps1 export prod
.\ssh.ps1 export all
.\ssh.ps1 export-many prod test staging

# 导入文件、目录或多个路径
.\ssh.ps1 import .\exports\prod_xxx\server.json
.\ssh.ps1 import .\exports\batch_xxx
.\ssh.ps1 import .\package-a .\package-b

# 打开配置、恢复出厂设置
.\ssh.ps1 config
.\ssh.ps1 reset
```

## 配置

配置文件是 `config\servers.local.json`。也可以在桌面控制台中维护，通常不需要手写 JSON。

```json
{
  "defaults": {
    "port": 22,
    "connectTimeoutSeconds": 10,
    "serverAliveIntervalSeconds": 30,
    "strictHostKeyChecking": "accept-new"
  },
  "servers": {
    "prod": {
      "host": "203.0.113.10",
      "user": "root",
      "port": 22,
      "identityFile": "keys/prod_ed25519",
      "password": ""
    }
  }
}
```

认证规则：

- `identityFile` 非空时使用密钥。
- `identityFile` 为空且 `password` 非空时使用密码。
- 两者都为空时由 OpenSSH 在连接时交互询问。

推荐使用密钥：

```powershell
ssh-keygen -t ed25519 -f .\keys\prod_ed25519
```

工作区外的配置可以通过环境变量指定：

```powershell
$env:SSH_SPACE_CONFIG = 'D:\private\my-servers.json'
.\SSH Space.exe
```

## 导入和导出隔离

每次导出都会在 `exports\` 中创建带时间戳和随机后缀的新目录，不覆盖以前的结果。

单台服务器包包含一个 `server.json`；使用密钥时还包含一个私钥文件。批量导出时，每台服务器位于独立子目录。导入遇到重名会创建 `-imported-2` 等新别名，私钥复制到独立的 `keys\imports\...` 目录，不覆盖现有配置或密钥。

导出包可能含明文密码或私钥。`exports\`、本地配置、密钥、运行数据和备份均已加入 `.gitignore`，仍应把这些目录视为敏感数据，不要上传或分享。

## 脚本核心如何工作

`ssh.ps1` 是唯一的 SSH 业务入口：

1. 读取并验证 JSON，合并默认值和服务器配置。
2. 优先选择发布包内的 `runtime\openssh\ssh.exe`，便携源码缺少内置运行时时才回退系统 OpenSSH。
3. 把别名转换为一组受控的 `ssh.exe` 参数，包括端口、超时、保活、私钥和独立的 `known_hosts`。
4. 交互会话直接启动 OpenSSH；远程命令把剩余参数作为一条远程命令传给 OpenSSH。
5. 密码认证通过临时的 `SSH_ASKPASS` 环境完成，密码不会拼进命令行参数。
6. Web API 复用同一套 PowerShell 函数，因此网页和命令行的验证、导入导出及 SSH 行为一致。

`app\server.ps1` 使用 Windows 自带的 `HttpListener` 提供应用资源和本地 API。它只绑定回环地址，并要求界面启动时注入的随机令牌，其他页面不能直接调用执行接口。

## EXE 说明

- 根目录的 `SSH Space.exe` 是单实例 WinForms + WebView2 桌面程序。它承载完整控制台界面、管理本地服务生命周期，但不把服务器配置、密码或私钥打包进程序。
- 首次使用密码认证时，`ssh.ps1` 会在 `data\` 下从 `app\helpers\SshSpace.AskPass.cs` 本地编译 `ssh-space-askpass.exe`。它只把当前进程临时提供的密码交给 OpenSSH，避免密码出现在命令行中；它不是常驻服务。

修改桌面程序源码后可重新构建：

```powershell
.\scripts\build-desktop.ps1
```

生成完整发布包：

```powershell
.\scripts\build-release.ps1
```

发布脚本会从 Microsoft `PowerShell/Win32-OpenSSH` 官方仓库下载固定版本，并核对固定 SHA-256 后才放入运行目录。安装程序由 Inno Setup 6 构建；仅需要便携 ZIP 时可使用 `-SkipInstaller`。默认复用根目录已构建的桌面 EXE，桌面 C# 源码有变化时使用 `-RebuildDesktop`。

重建前应先关闭正在运行的 SSH Space 桌面窗口。

只修改 `app\web\`、`ssh.ps1` 或 `app\server.ps1` 不需要重建根目录 EXE。

## 项目结构

```text
SSH Space.exe / SSH Space.bat  桌面入口
ssh.ps1                        用户与 Agent 的 CLI 入口
app/                           应用运行文件
src/desktop/                   桌面程序源码和清单
scripts/                       构建脚本
config/ keys/ data/            本地配置、密钥和运行数据
exports/ backups/              敏感导出包与恢复备份
```

## OpenSSH 与配置损坏

正式发布包内置 OpenSSH。开发目录如果还没有 `runtime\openssh`，会自动回退系统 OpenSSH；两者都缺失时，服务器编辑、导入、导出和恢复仍然可用，连接和远程命令会提示重新安装。可以用下面的命令检查实际使用的是 `bundled` 还是 `system`：

```powershell
.\ssh.ps1 doctor
```

手工把 JSON 改坏时，命令行会给出 JSON 错误，Web 页面显示配置损坏状态，不会拿损坏内容继续连接。通过脚本或 Web 正常保存前都会在 `backups\auto-save_...` 创建快照。

恢复出厂设置必须逐字输入：

```text
RESET SSH SPACE
```

执行前，当前配置、工作区密钥和 `known_hosts` 会被移到 `backups\factory-reset_...`。历史导出包不会删除，备份可用于人工恢复。
