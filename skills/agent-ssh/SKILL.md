---
name: agent-ssh
description: Safely operate an installed or portable agent-ssh desktop workspace through its supported PowerShell CLI. Use when a user asks Codex to discover or diagnose agent-ssh server aliases, run SSH commands, open an interactive session, import or export isolated server packages, locate the agent-ssh installation, or diagnose its local desktop service.
---

# agent-ssh

Use `agent-ssh.ps1` as the stable Agent interface. Do not automate the desktop's token-protected internal HTTP API.

## Locate the application

Run the bundled locator before operating outside an agent-ssh workspace:

```powershell
$agentSshRoot = & "<skill-directory>\scripts\find-agent-ssh.ps1"
$agentSshCli = Join-Path $agentSshRoot 'agent-ssh.ps1'
```

Resolve `<skill-directory>` from this `SKILL.md`. Prefer a workspace found at or above the current directory; otherwise use the per-user installation.

## Follow the safe workflow

1. Discover aliases without reading the configuration file:

   ```powershell
   & $agentSshCli list
   ```

2. Validate the selected alias without connecting:

   ```powershell
   & $agentSshCli doctor <alias>
   ```

3. Determine whether the requested remote command changes remote state. Ask the user before destructive commands or changes beyond the stated task.

4. Run the requested operation:

   ```powershell
   & $agentSshCli <alias> uptime
   & $agentSshCli <alias> "docker ps"
   & $agentSshCli <alias>
   ```

Use the last form only for a user-requested interactive session.

Remote command calls automatically establish and reuse a persistent remote shell. The connection closes after 10 idle minutes. Use the lifecycle commands when explicit control is useful:

```powershell
& $agentSshCli connect <alias>
& $agentSshCli status <alias>
& $agentSshCli disconnect <alias>
```

The interactive terminal is independent from the reusable Agent command session. Disconnecting the Agent session does not close a terminal the user has open.

## Import and export packages

```powershell
& $agentSshCli export <alias>
& $agentSshCli export all
& $agentSshCli export-many <alias1> <alias2>
& $agentSshCli import <path1> <path2>
```

Treat every export as sensitive because it can contain passwords or private keys. Do not print package contents.

## Protect secrets and local data

- Never print, copy into chat, or commit `%LOCALAPPDATA%\agent-ssh\config\servers.local.json` (installed) or `config/servers.local.json` (portable).
- Never print or copy private keys or generated data from the active data directory.
- Never place a password directly in a shell command.
- Prefer key authentication.
- Use the desktop application for routine configuration editing. Use package import for deterministic Agent-managed additions.
- Do not delete or reset local configuration unless the user explicitly requests it. Factory reset requires the exact confirmation text `RESET agent-ssh` and creates a backup.

## Diagnose local application issues

Run CLI diagnosis first:

```powershell
& $agentSshCli doctor
```

For a desktop service startup problem, run the service in the foreground from the located root:

```powershell
& (Join-Path $agentSshRoot 'app\server.ps1') -NoBrowser
```

The service listens only on `127.0.0.1`. Stop the foreground diagnostic after collecting the necessary local error. Do not expose it on another interface.
