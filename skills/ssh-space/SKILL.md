---
name: ssh-space
description: Safely operate an installed or portable SSH Space desktop workspace through its supported PowerShell CLI. Use when a user asks Codex to discover or diagnose SSH Space server aliases, run SSH commands, open an interactive session, import or export isolated server packages, locate the SSH Space installation, or diagnose its local desktop service.
---

# SSH Space

Use `ssh.ps1` as the stable Agent interface. Do not automate the desktop's token-protected internal HTTP API.

## Locate the application

Run the bundled locator before operating outside an SSH Space workspace:

```powershell
$sshSpaceRoot = & "<skill-directory>\scripts\find-ssh-space.ps1"
$sshSpaceCli = Join-Path $sshSpaceRoot 'ssh.ps1'
```

Resolve `<skill-directory>` from this `SKILL.md`. Prefer a workspace found at or above the current directory; otherwise use the per-user installation.

## Follow the safe workflow

1. Discover aliases without reading the configuration file:

   ```powershell
   & $sshSpaceCli list
   ```

2. Validate the selected alias without connecting:

   ```powershell
   & $sshSpaceCli doctor <alias>
   ```

3. Determine whether the requested remote command changes remote state. Ask the user before destructive commands or changes beyond the stated task.

4. Run the requested operation:

   ```powershell
   & $sshSpaceCli <alias> uptime
   & $sshSpaceCli <alias> "docker ps"
   & $sshSpaceCli <alias>
   ```

Use the last form only for a user-requested interactive session.

## Import and export packages

```powershell
& $sshSpaceCli export <alias>
& $sshSpaceCli export all
& $sshSpaceCli export-many <alias1> <alias2>
& $sshSpaceCli import <path1> <path2>
```

Treat every export as sensitive because it can contain passwords or private keys. Do not print package contents.

## Protect secrets and local data

- Never print, copy into chat, or commit `config/servers.local.json`.
- Never print or copy private keys under `keys/` or generated files under `data/`.
- Never place a password directly in a shell command.
- Prefer key authentication.
- Use the desktop application for routine configuration editing. Use package import for deterministic Agent-managed additions.
- Do not delete or reset local configuration unless the user explicitly requests it. Factory reset requires the exact confirmation text `RESET SSH SPACE` and creates a backup.

## Diagnose local application issues

Run CLI diagnosis first:

```powershell
& $sshSpaceCli doctor
```

For a desktop service startup problem, run the service in the foreground from the located root:

```powershell
& (Join-Path $sshSpaceRoot 'app\server.ps1') -NoBrowser
```

The service listens only on `127.0.0.1`. Stop the foreground diagnostic after collecting the necessary local error. Do not expose it on another interface.
