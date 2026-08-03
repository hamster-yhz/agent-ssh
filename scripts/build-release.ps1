[CmdletBinding()]
param(
    [string]$Version = '2.0.0',
    [switch]$SkipInstaller,
    [switch]$RebuildDesktop
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$buildRoot = Join-Path $root 'build\release'
$stage = Join-Path $buildRoot 'SSH Space'
$dist = Join-Path $root 'dist'
$stagePrefix = [IO.Path]::GetFullPath($buildRoot).TrimEnd('\') + '\'
if (-not ([IO.Path]::GetFullPath($stage)).StartsWith($stagePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Release staging path escaped the build directory.'
}

& (Join-Path $PSScriptRoot 'get-openssh.ps1')
New-Item -ItemType Directory -Path $buildRoot -Force | Out-Null
$releaseExecutable = Join-Path $buildRoot 'SSH Space.exe'
if ($RebuildDesktop -or -not (Test-Path -LiteralPath (Join-Path $root 'SSH Space.exe') -PathType Leaf)) {
    & (Join-Path $PSScriptRoot 'build-desktop.ps1') -OutputPath 'build\release\SSH Space.exe'
} else {
    Copy-Item -LiteralPath (Join-Path $root 'SSH Space.exe') -Destination $releaseExecutable -Force
}

if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage, $dist -Force | Out-Null

Copy-Item -LiteralPath $releaseExecutable -Destination $stage
Copy-Item -LiteralPath (Join-Path $root 'ssh.ps1') -Destination $stage
Copy-Item -LiteralPath (Join-Path $root 'README.md') -Destination $stage
Copy-Item -LiteralPath (Join-Path $root 'THIRD-PARTY-NOTICES.md') -Destination $stage
Copy-Item -LiteralPath (Join-Path $root 'src\desktop\SshSpace.ico') -Destination $stage
Copy-Item -LiteralPath (Join-Path $root 'app') -Destination $stage -Recurse
Copy-Item -LiteralPath (Join-Path $root 'runtime') -Destination $stage -Recurse
Copy-Item -LiteralPath (Join-Path $root 'skills') -Destination $stage -Recurse
New-Item -ItemType Directory -Path (Join-Path $stage 'scripts') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'scripts\install-codex-skill.ps1') -Destination (Join-Path $stage 'scripts')

foreach ($directory in @('config', 'keys', 'data', 'exports', 'backups')) {
    New-Item -ItemType Directory -Path (Join-Path $stage $directory) -Force | Out-Null
}
Copy-Item -LiteralPath (Join-Path $root 'config\servers.example.json') -Destination (Join-Path $stage 'config')
foreach ($directory in @('keys', 'data', 'exports', 'backups')) {
    Copy-Item -LiteralPath (Join-Path $root "$directory\.gitkeep") -Destination (Join-Path $stage $directory)
}

$portable = Join-Path $dist "SSH-Space-$Version-Portable.zip"
if (Test-Path -LiteralPath $portable) { Remove-Item -LiteralPath $portable -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $portable -CompressionLevel Optimal

$installer = $null
if (-not $SkipInstaller) {
    $iscc = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
    if (-not $iscc) {
        throw 'Inno Setup 6 is required to build the installer. Install it or use -SkipInstaller.'
    }
    & $iscc "/DSourceDir=$stage" "/DOutputDir=$dist" "/DAppVersion=$Version" (Join-Path $root 'installer\SSH Space.iss')
    if ($LASTEXITCODE -ne 0) { throw 'Inno Setup failed to build the installer.' }
    $installer = Join-Path $dist "SSH-Space-$Version-Setup.exe"
}

$artifacts = @($portable)
if ($installer) { $artifacts += $installer }
$checksums = foreach ($artifact in $artifacts) {
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $artifact).Hash.ToLowerInvariant()
    "$hash  $([IO.Path]::GetFileName($artifact))"
}
[IO.File]::WriteAllLines((Join-Path $dist 'SHA256SUMS.txt'), $checksums, (New-Object Text.UTF8Encoding($false)))
$artifacts | ForEach-Object { Write-Host "Release artifact: $_" -ForegroundColor Green }
