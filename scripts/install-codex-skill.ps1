[CmdletBinding()]
param(
    [string]$Destination
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $root 'skills\agent-ssh'
$target = if ([string]::IsNullOrWhiteSpace($Destination)) {
    Join-Path $env:USERPROFILE '.codex\skills\agent-ssh'
} else {
    [IO.Path]::GetFullPath($Destination)
}

if (-not (Test-Path -LiteralPath (Join-Path $source 'SKILL.md') -PathType Leaf)) {
    throw "agent-ssh Skill source was not found: $source"
}

New-Item -ItemType Directory -Path $target -Force | Out-Null
Get-ChildItem -LiteralPath $source -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $target -Recurse -Force
}

Write-Host "Installed agent-ssh Skill: $target" -ForegroundColor Green
Write-Host 'Restart Codex to discover the new Skill.' -ForegroundColor DarkGray
