[CmdletBinding()]
param(
    [string]$Destination,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$version = '10.0.0.0p2-Preview'
$assetName = 'OpenSSH-Win64.zip'
$assetUrl = "https://github.com/PowerShell/Win32-OpenSSH/releases/download/$version/$assetName"
$sha256 = '23f50f3458c4c5d0b12217c6a5ddfde0137210a30fa870e98b29827f7b43aba5'
$root = Split-Path -Parent $PSScriptRoot
$runtimeRoot = if ([string]::IsNullOrWhiteSpace($Destination)) {
    Join-Path $root 'runtime\openssh'
} else {
    [IO.Path]::GetFullPath((Join-Path $root $Destination))
}
$workspacePrefix = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
if (-not $runtimeRoot.StartsWith($workspacePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'OpenSSH destination must stay inside the agent-ssh workspace.'
}

$sshExe = Join-Path $runtimeRoot 'ssh.exe'
if ((Test-Path -LiteralPath $sshExe -PathType Leaf) -and -not $Force) {
    $uppercaseMarker = Join-Path $runtimeRoot 'AGENT-SSH-VERSION.txt'
    if (Test-Path -LiteralPath $uppercaseMarker -PathType Leaf) { Remove-Item -LiteralPath $uppercaseMarker -Force }
    $legacyMarker = Join-Path $runtimeRoot 'SSH-SPACE-VERSION.txt'
    if (Test-Path -LiteralPath $legacyMarker -PathType Leaf) { Remove-Item -LiteralPath $legacyMarker -Force }
    [IO.File]::WriteAllText((Join-Path $runtimeRoot 'agent-ssh-version.txt'), "$version`r`n$sha256`r`n", (New-Object Text.UTF8Encoding($false)))
    Write-Host "OpenSSH runtime is ready: $runtimeRoot" -ForegroundColor Green
    return
}

$cache = Join-Path $root 'build\cache\openssh'
$archive = Join-Path $cache "$version-$assetName"
$download = "$archive.download"
New-Item -ItemType Directory -Path $cache -Force | Out-Null

$archiveValid = $false
if (Test-Path -LiteralPath $archive -PathType Leaf) {
    $archiveValid = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash -ieq $sha256
}
if (-not $archiveValid) {
    Write-Host "Downloading official Win32-OpenSSH $version..." -ForegroundColor Cyan
    $curlArguments = @('-L', '--fail', '--retry', '3', '--connect-timeout', '30', '--max-time', '900')
    if ((Test-Path -LiteralPath $download -PathType Leaf) -and (Get-Item -LiteralPath $download).Length -gt 0) {
        $curlArguments += @('-C', '-')
    }
    $curlArguments += @('-o', $download, $assetUrl)
    & curl.exe @curlArguments
    if ($LASTEXITCODE -ne 0) { throw 'Could not download the official Win32-OpenSSH package.' }
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $download).Hash.ToLowerInvariant()
    if ($actualHash -ne $sha256) {
        Remove-Item -LiteralPath $download -Force
        throw "OpenSSH package checksum mismatch. Expected $sha256 but received $actualHash."
    }
    Move-Item -LiteralPath $download -Destination $archive -Force
}

$expanded = Join-Path $cache ("expanded-" + [Guid]::NewGuid().ToString('N'))
try {
    Expand-Archive -LiteralPath $archive -DestinationPath $expanded
    $source = Join-Path $expanded 'OpenSSH-Win64'
    if (-not (Test-Path -LiteralPath (Join-Path $source 'ssh.exe') -PathType Leaf)) {
        throw 'The official OpenSSH archive has an unexpected layout.'
    }
    if (Test-Path -LiteralPath $runtimeRoot) {
        Remove-Item -LiteralPath $runtimeRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $runtimeRoot -Force | Out-Null
    $clientFiles = @(
        'ssh.exe', 'scp.exe', 'sftp.exe', 'ssh-add.exe', 'ssh-agent.exe',
        'ssh-keygen.exe', 'ssh-keyscan.exe', 'ssh-pkcs11-helper.exe', 'ssh-sk-helper.exe',
        'libcrypto.dll', 'LICENSE.txt', 'NOTICE.txt', 'moduli'
    )
    foreach ($fileName in $clientFiles) {
        $sourceFile = Join-Path $source $fileName
        if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
            throw "The official OpenSSH archive is missing a client file: $fileName"
        }
        Copy-Item -LiteralPath $sourceFile -Destination (Join-Path $runtimeRoot $fileName)
    }
    [IO.File]::WriteAllText((Join-Path $runtimeRoot 'agent-ssh-version.txt'), "$version`r`n$sha256`r`n", (New-Object Text.UTF8Encoding($false)))
    Write-Host "Installed bundled OpenSSH: $runtimeRoot" -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $expanded) { Remove-Item -LiteralPath $expanded -Recurse -Force }
}
