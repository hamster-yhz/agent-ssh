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

Add-Candidate $env:SSH_SPACE_HOME

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
Add-Candidate (Join-Path $env:LOCALAPPDATA 'Programs\SSH Space')

$uninstallRoots = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -eq 'SSH Space' } |
    ForEach-Object { $_.InstallLocation }
foreach ($root in $uninstallRoots) { Add-Candidate $root }

foreach ($candidate in $candidates | Select-Object -Unique) {
    if ((Test-Path -LiteralPath (Join-Path $candidate 'ssh.ps1') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $candidate 'app\server.ps1') -PathType Leaf)) {
        Write-Output $candidate
        exit 0
    }
}

throw 'SSH Space was not found. Install it, extract the portable package, set SSH_SPACE_HOME, or run Codex inside its directory.'
