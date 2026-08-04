[CmdletBinding()]
param(
    [string]$StartPath = (Get-Location).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$candidates = New-Object 'System.Collections.Generic.List[string]'
function Add-Candidate {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    try { $candidates.Add([IO.Path]::GetFullPath($Path)) } catch {}
}

Add-Candidate $env:AGENT_SSH_HOME

$current = if (Test-Path -LiteralPath $StartPath -PathType Leaf) {
    Split-Path -Parent ([IO.Path]::GetFullPath($StartPath))
} else {
    [IO.Path]::GetFullPath($StartPath)
}
while (-not [string]::IsNullOrWhiteSpace($current)) {
    Add-Candidate $current
    $parent = Split-Path -Parent $current
    if ($parent -eq $current) { break }
    $current = $parent
}

$skillRoot = Split-Path -Parent $PSScriptRoot
$packagedRoot = Split-Path -Parent (Split-Path -Parent $skillRoot)
Add-Candidate $packagedRoot
Add-Candidate (Join-Path $env:LOCALAPPDATA 'Programs\agent-ssh')

$uninstallRoots = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -eq 'agent-ssh' } |
    ForEach-Object { $_.InstallLocation }
foreach ($root in $uninstallRoots) { Add-Candidate $root }

foreach ($candidate in $candidates | Select-Object -Unique) {
    $hasCli = Test-Path -LiteralPath (Join-Path $candidate 'agent-ssh.ps1') -PathType Leaf
    if ($hasCli -and
        (Test-Path -LiteralPath (Join-Path $candidate 'app\server.ps1') -PathType Leaf)) {
        Write-Output $candidate
        exit 0
    }
}

throw 'agent-ssh was not found. Install it, extract the portable package, set AGENT_SSH_HOME, or run Codex inside its directory.'
