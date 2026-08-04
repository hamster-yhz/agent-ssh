<div align="center">

# agent-ssh

### 一台 Windows 电脑，管理你的所有 SSH 连接

桌面控制台、PowerShell CLI 与本地 Agent 共用同一套配置。<br>
不需要数据库，不需要 Node.js，也不需要另外安装 OpenSSH。

[![Windows](https://img.shields.io/badge/Windows-10%20%2F%2011-0078D4?logo=windows11&logoColor=white)](https://github.com/hamster-yhz/agent-ssh/releases)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%2F%207-5391FE?logo=powershell&logoColor=white)](https://github.com/PowerShell/PowerShell)
[![Bundled OpenSSH](https://img.shields.io/badge/OpenSSH-Bundled-34A853?logo=openssh&logoColor=white)](https://github.com/PowerShell/Win32-OpenSSH)
[![Build and release](https://github.com/hamster-yhz/agent-ssh/actions/workflows/release.yml/badge.svg)](https://github.com/hamster-yhz/agent-ssh/actions/workflows/release.yml)

[下载最新版本](https://github.com/hamster-yhz/agent-ssh/releases) · [查看构建产物](https://github.com/hamster-yhz/agent-ssh/actions) · [命令行用法](#命令行与-agent)

</div>

---

## 它适合谁？

agent-ssh 面向希望简单管理多台 Linux 服务器的 Windows 用户。你可以在桌面应用里填写 IP、端口、用户名和认证方式，然后点击连接；同一份配置也能被脚本或 Codex 等本地 Agent 安全调用。

| 能力 | 使用体验 |
| --- | --- |
| 🖥️ 桌面控制台 | 新建、编辑、搜索服务器，并在应用内运行远程命令 |
| ⚡ 持久连接 | Agent 与应用命令自动复用认证连接，空闲 10 分钟后释放 |
| 📦 批量迁移 | 单台、任意多选或全部导出，支持文件和目录批量导入 |
| 🤖 Agent 友好 | 提供稳定的 `agent-ssh.ps1` CLI 和配套 Codex Skill |
| 🔐 自带 OpenSSH | 正式安装包和便携版内置官方 Win32-OpenSSH |
| 🧩 保持轻量 | 无数据库、无 Node.js、无前端框架运行时 |

## 三步开始

### 1. 下载

前往 [GitHub Releases](https://github.com/hamster-yhz/agent-ssh/releases)，根据需要选择：

- **`agent-ssh-*-Setup.exe`**：推荐。按当前用户安装，不需要管理员权限。
- **`agent-ssh-*-Portable.zip`**：解压即用，不写入安装信息。
- **`SHA256SUMS.txt`**：用于核对下载文件完整性。

如果 Releases 暂时没有正式版本，也可以从 [Actions](https://github.com/hamster-yhz/agent-ssh/actions/workflows/release.yml) 最近一次成功运行中下载 Windows 构建产物。

### 2. 打开

运行 `agent-ssh.exe`。安装版会创建开始菜单入口，并可选择桌面快捷方式；便携版直接从解压目录启动。

### 3. 添加服务器

点击“新建服务器”，填写：

- 容易识别的服务器别名；
- IP 地址或域名；
- SSH 端口和用户名；
- 密码、私钥，或留空后连接时交互输入。

保存后即可打开独立终端，或直接在应用页面执行命令。

> [!TIP]
> 推荐优先使用 Ed25519 私钥认证。密码模式可以使用，但本地配置和导出包可能包含明文密码，请像保护私钥一样保护它们。

## 应用内更新

agent-ssh 会在启动后静默检查 GitHub 的最新稳定 Release，也可以点击右上角的下载图标手动检查。自动检查失败不会影响服务器管理和 SSH 连接。

发现新版本时，应用会：

1. 显示当前版本、最新版本、安装包大小和 Release Notes。
2. 仅从 `hamster-yhz/agent-ssh` 官方 Release 下载 Setup 与 `SHA256SUMS.txt`。
3. 在本机计算安装包 SHA-256，并与发布校验文件逐字比对。
4. 只有校验成功后才启用“立即安装”。
5. 经用户再次确认后启动标准安装器，关闭当前应用并在更新完成后重新打开。

更新器只接受更高的三段式稳定版本，不会自动降级，也不会静默强制安装。安装版的下载文件缓存在 `%LOCALAPPDATA%\agent-ssh\data\updates\版本号`；手动从 GitHub Release 下载始终可以作为兜底。便携版使用应用内更新时会启动标准用户安装程序。

安装版更新只替换 `%LOCALAPPDATA%\Programs\agent-ssh` 中的程序文件，用户配置、密钥和运行数据独立保存在 `%LOCALAPPDATA%\agent-ssh`，不会被安装或卸载覆盖。便携版的数据仍保存在解压目录旁。

## 桌面应用里可以做什么？

- 新建、编辑、删除和搜索服务器。
- 查看内置 OpenSSH 与配置健康状态。
- 上传私钥到当前 agent-ssh 工作区。
- 打开交互式 SSH 终端。
- 主动连接或断开服务器，并查看实时连接状态。
- 在控制台内复用远程 Shell 执行命令并查看真实退出码。
- 多选服务器并批量导入或导出。
- 在修改配置前自动创建可恢复快照。
- 通过强确认短语恢复出厂设置。

桌面界面由原生 WinForms 窗口承载，并使用 WebView2 渲染。内部服务只监听 `127.0.0.1`，每次启动都会生成随机 API 令牌，不对局域网或公网提供接口。

## 导入与导出

每次导出都会创建带时间戳和随机后缀的新目录，不会覆盖之前的结果。

- 单台导出包含一个 `server.json`。
- 使用私钥时，导出包还会包含对应密钥文件。
- 批量导出时，每台服务器放在独立子目录中。
- 导入遇到重名会生成 `-imported-2` 等新别名。
- 导入的密钥会复制到隔离目录，不会覆盖已有密钥。

> [!WARNING]
> 导出包可能包含明文密码或私钥。不要把 `exports/` 上传到 GitHub、网盘或聊天工具，也不要把它当作普通配置文件分享。

## 命令行与 Agent

桌面应用适合日常管理，`agent-ssh.ps1` 适合自动化和本地 Agent。两者使用同一份服务器配置。

```powershell
# 查看别名和检查配置，不连接服务器
.\agent-ssh.ps1 list
.\agent-ssh.ps1 doctor
.\agent-ssh.ps1 doctor prod

# 可选：主动管理可复用命令会话
.\agent-ssh.ps1 connect prod
.\agent-ssh.ps1 status prod
.\agent-ssh.ps1 disconnect prod

# 打开独立交互终端或执行远程命令
.\agent-ssh.ps1 prod
.\agent-ssh.ps1 prod uptime
.\agent-ssh.ps1 prod "docker ps"

# 单台、全部或指定多台导出
.\agent-ssh.ps1 export prod
.\agent-ssh.ps1 export all
.\agent-ssh.ps1 export-many prod test staging

# 导入一个文件、整个目录或多个包
.\agent-ssh.ps1 import .\package\server.json
.\agent-ssh.ps1 import .\batch-package
.\agent-ssh.ps1 import .\package-a .\package-b
```

执行远程命令时无需先运行 `connect`：首次命令会自动连接，后续命令复用同一个已认证远程 Shell，并保留工作目录和环境变量。会话连续空闲 10 分钟后自动断开；网络断开后，下一条命令会建立新连接。`disconnect` 只关闭 Agent/命令面板使用的会话，不会关闭用户已经打开的独立终端。

### Codex Skill

安装程序可以同时安装 agent-ssh Codex Skill。安装时勾选 **Install the agent-ssh Skill for Codex**，完成后重启 Codex 即可。

便携版或源码目录也可以手动安装：

```powershell
.\scripts\install-codex-skill.ps1
```

Skill 位于 `%USERPROFILE%\.codex\skills\agent-ssh`。Agent 通过公开的 CLI 工作，不调用桌面应用内部 API；它会先运行 `list` 和 `doctor`，并在执行破坏性远程操作前请求确认。

## 配置与认证

普通用户建议直接在桌面应用中维护配置，不需要手写 JSON。安装版和便携版使用不同的数据位置：

```text
安装版：%LOCALAPPDATA%\agent-ssh\config\servers.local.json
便携版：<解压目录>\config\servers.local.json
```

同一数据根目录下还包含 `keys`、`data`、`exports` 和 `backups`。程序文件与用户数据彻底分离。

配置格式示例：

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

认证选择规则：

1. 填写 `identityFile` 时使用私钥。
2. 未填写私钥但填写 `password` 时使用密码。
3. 两者都留空时，由 OpenSSH 在连接时交互询问。

也可以把配置放在工作区之外：

```powershell
$env:AGENT_SSH_CONFIG = 'D:\private\my-servers.json'
& '.\agent-ssh.exe'
```

如需整体指定数据目录，可在启动前设置 `AGENT_SSH_DATA_HOME`；这会同时改变配置、密钥、运行数据、导出和备份的位置。

## 安全与隐私

- 正式发布包不包含开发者的服务器配置、密码、密钥、导出包或备份。
- 密码不会出现在 `ssh.exe` 命令行参数中，而是通过临时 `SSH_ASKPASS` 环境交给 OpenSSH。
- `known_hosts` 独立保存在 agent-ssh 数据目录中。
- 便携/源码目录中的 `config/servers.local.json`、`keys/`、`data/`、`exports/` 和 `backups/` 已被 Git 忽略。
- 桌面内部 API 仅绑定回环地址，并使用每次启动随机生成的令牌。
- 恢复出厂设置前会移动现有配置、密钥和 `known_hosts` 到备份目录。

恢复出厂设置必须逐字输入：

```text
RESET agent-ssh
```

历史导出包不会被恢复出厂设置删除。

## 安装程序会修改什么？

安装版是标准的 Windows 按用户安装程序：

- 默认安装到 `%LOCALAPPDATA%\Programs\agent-ssh`。
- 将用户配置、密钥、会话数据、导出包和备份保存在 `%LOCALAPPDATA%\agent-ssh`。
- 在当前用户的程序卸载列表中登记 agent-ssh。
- 创建开始菜单入口，可选创建桌面快捷方式。
- 可选安装 Codex Skill 到用户目录。
- 卸载时提供标准卸载入口。

它不会安装 Windows 服务、驱动、计划任务，不会修改防火墙，也不会替换系统 OpenSSH 或强制写入 `PATH`。便携版则不会写入程序卸载列表。

安装目录只放程序文件，卸载程序默认不删除 `%LOCALAPPDATA%\agent-ssh` 中的用户数据。便携版仍把程序和数据放在同一个解压目录，适合 U 盘或免安装使用。

## 常见问题

<details>
<summary><strong>电脑没有安装 OpenSSH，可以连接吗？</strong></summary>

可以。正式安装包和便携版内置经过固定 SHA-256 校验的官方 Win32-OpenSSH。开发目录缺少内置运行时时才会回退到系统 OpenSSH。

</details>

<details>
<summary><strong>用户安装的是 PowerShell 7，没有 5.1 可以运行吗？</strong></summary>

可以。agent-ssh 优先使用 Windows 自带的 PowerShell 5.1；如果系统没有 5.1，会自动检测官方 PowerShell 7 安装目录。应用启动后会在底部显示实际使用的 PowerShell 版本，并让终端和远程命令继续复用同一运行时。

</details>

<details>
<summary><strong>怎么确认当前使用的是内置还是系统 OpenSSH？</strong></summary>

运行：

```powershell
.\agent-ssh.ps1 doctor
```

输出会标明 `bundled`、`system` 或 `missing`。

</details>

<details>
<summary><strong>手工把配置文件改坏了怎么办？</strong></summary>

agent-ssh 会停止使用损坏配置并显示 JSON 错误，不会拿错误内容继续连接。正常保存前还会在数据目录的 `backups\auto-save_*` 创建快照，可用于人工恢复。

</details>

<details>
<summary><strong>为什么其他 SSH 工具能连，agent-ssh 却提示失败？</strong></summary>

先运行 `.\agent-ssh.ps1 doctor 别名` 检查端口、认证方式和 OpenSSH 状态。若配置正常，请在 [Issues](https://github.com/hamster-yhz/agent-ssh/issues) 中附上错误文字，但不要上传本地配置、密码、私钥或导出包。

</details>

## 从源码构建

重新构建桌面入口：

```powershell
.\scripts\build-desktop.ps1
```

生成安装程序、便携包和校验文件：

```powershell
.\scripts\build-release.ps1
```

仅构建便携 ZIP：

```powershell
.\scripts\build-release.ps1 -SkipInstaller
```

发布流水线位于 `.github/workflows/release.yml`：

- 推送到 `main`：自动构建，产物在 Actions 中保留 14 天。
- 推送 `vX.Y.Z` 形式的标签：自动创建 GitHub Release 并上传全部文件。
- Actions 页面手动运行：生成可下载的工作流产物。

```powershell
git tag v2.4.0
git push origin main --tags
```

## 项目结构

```text
agent-ssh.exe                   桌面应用入口
agent-ssh.ps1                  用户与 Agent 的 CLI
app/                           本地服务、持久会话宿主与桌面界面
src/desktop/                   WinForms / WebView2 宿主源码
scripts/                       构建和安装脚本
skills/agent-ssh/              Codex Skill
config/ keys/ data/            便携/源码模式的本地数据
exports/ backups/              便携/源码模式的敏感数据
```

第三方组件与许可证信息见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。

---

<div align="center">

**把服务器连接留在本地，把日常操作变得简单。**

</div>
