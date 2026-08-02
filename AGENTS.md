# SSH Space agent guide

- Use `.\ssh.ps1 list` to discover configured server aliases.
- Use `.\ssh.ps1 doctor [alias]` to validate configuration without connecting.
- Use `.\ssh.ps1 <alias> <command...>` for remote commands and `.\ssh.ps1 <alias>` for an interactive session.
- Use `.\app\server.ps1` for foreground service diagnostics. It listens on `127.0.0.1` only.
- Use `SSH Space.exe` or `SSH Space.bat` for the primary embedded desktop console.
- Use `.\ssh.ps1 export <alias|all>` and `.\ssh.ps1 import <path...>` for isolated configuration packages.
- Never print, copy, or commit `config/servers.local.json`, private keys under `keys/`, or generated files under `data/`.
- Treat `exports/` as sensitive because packages may contain passwords and private keys.
- Prefer key authentication. Do not put passwords directly in shell commands.
- Ask the user before running destructive remote commands or changing remote system state beyond the stated task.
