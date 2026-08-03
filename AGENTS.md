# SSH Space agent guide

- Use `.\ssh.ps1 list` to discover configured server aliases.
- Use `.\ssh.ps1 doctor [alias]` to validate configuration without connecting.
- Use `.\ssh.ps1 connect <alias>`, `.\ssh.ps1 status [alias]`, and `.\ssh.ps1 disconnect <alias>` to manage reusable command sessions.
- Use `.\ssh.ps1 <alias> <command...>` for remote commands. Commands auto-connect and reuse the same remote shell for 10 idle minutes.
- Use `.\ssh.ps1 <alias>` for a user-requested interactive terminal. It is independent from the reusable Agent command session.
- Use `.\app\server.ps1` for foreground service diagnostics. It listens on `127.0.0.1` only.
- Use `SSH Space.exe` for the primary embedded desktop console.
- Use `.\ssh.ps1 export <alias|all>` and `.\ssh.ps1 import <path...>` for isolated configuration packages.
- Never print, copy, or commit `config/servers.local.json`, private keys under `keys/`, or generated files under `data/`.
- Treat `exports/` as sensitive because packages may contain passwords and private keys.
- Prefer key authentication. Do not put passwords directly in shell commands.
- Do not disconnect a reusable session unless the user asks or the task is complete and owns that session. Disconnecting it never closes the user's independent interactive terminal.
- Ask the user before running destructive remote commands or changing remote system state beyond the stated task.
