Set-StrictMode -Version Latest

$script:SshSpaceRepository = 'hamster-yhz/agent-ssh'
$script:SshSpaceUpdateCache = $null
$script:SshSpaceUpdateCacheMinutes = 30
$script:SshSpaceMaximumInstallerBytes = 209715200

function ConvertTo-SshSpaceVersion {
    param([Parameter(Mandatory)][string]$Value)
    $normalized = $Value.Trim().TrimStart('v')
    if ($normalized -notmatch '^\d+\.\d+\.\d+$') {
        throw "Invalid SSH Space version: $Value"
    }
    return [Version]$normalized
}

function Get-SshSpaceApplicationVersion {
    $versionPath = Join-Path $Root 'VERSION'
    if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) {
        throw "SSH Space version metadata is missing: $versionPath"
    }
    $version = [IO.File]::ReadAllText($versionPath, [Text.Encoding]::UTF8).Trim()
    [void](ConvertTo-SshSpaceVersion $version)
    return $version
}

function Invoke-SshSpaceGitHubApi {
    param([Parameter(Mandatory)][string]$Uri)
    if (-not $Uri.StartsWith("https://api.github.com/repos/$script:SshSpaceRepository/", [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to query an unexpected update API endpoint.'
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    return Invoke-RestMethod -Uri $Uri -Headers @{
        Accept = 'application/vnd.github+json'
        'User-Agent' = 'SSH-Space-Updater'
        'X-GitHub-Api-Version' = '2022-11-28'
    } -TimeoutSec 20
}

function Assert-SshSpaceAssetUrl {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$FileName
    )
    $expected = "https://github.com/$script:SshSpaceRepository/releases/download/v$Version/$FileName"
    if (-not [string]::Equals($Uri, $expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Release asset URL is not trusted: $FileName"
    }
}

function Get-SshSpaceLatestRelease {
    param([switch]$Force)
    if (-not $Force -and $null -ne $script:SshSpaceUpdateCache -and
        ((Get-Date).ToUniversalTime() - $script:SshSpaceUpdateCache.CheckedAt).TotalMinutes -lt $script:SshSpaceUpdateCacheMinutes) {
        return $script:SshSpaceUpdateCache.Release
    }

    $release = Invoke-SshSpaceGitHubApi "https://api.github.com/repos/$script:SshSpaceRepository/releases/latest"
    $tag = [string]$release.tag_name
    if ($tag -notmatch '^v(?<version>\d+\.\d+\.\d+)$') {
        throw "The latest GitHub Release has an invalid tag: $tag"
    }
    $version = $Matches.version
    $setupName = "SSH-Space-$version-Setup.exe"
    $checksumName = 'SHA256SUMS.txt'
    $setupAsset = @($release.assets | Where-Object { $_.name -ceq $setupName }) | Select-Object -First 1
    $checksumAsset = @($release.assets | Where-Object { $_.name -ceq $checksumName }) | Select-Object -First 1
    if ($null -eq $setupAsset -or $null -eq $checksumAsset) {
        throw "Release $tag does not contain the required installer and checksum assets."
    }
    if ([long]$setupAsset.size -le 0 -or [long]$setupAsset.size -gt $script:SshSpaceMaximumInstallerBytes) {
        throw "Release installer size is outside the allowed range: $($setupAsset.size) bytes"
    }
    Assert-SshSpaceAssetUrl ([string]$setupAsset.browser_download_url) $version $setupName
    Assert-SshSpaceAssetUrl ([string]$checksumAsset.browser_download_url) $version $checksumName

    $result = [pscustomobject][ordered]@{
        version = $version
        tag = $tag
        name = [string]$release.name
        notes = ([string]$release.body).Substring(0, [Math]::Min(([string]$release.body).Length, 20000))
        publishedAt = [string]$release.published_at
        releaseUrl = [string]$release.html_url
        setupName = $setupName
        setupUrl = [string]$setupAsset.browser_download_url
        setupSize = [long]$setupAsset.size
        checksumName = $checksumName
        checksumUrl = [string]$checksumAsset.browser_download_url
    }
    $script:SshSpaceUpdateCache = [pscustomobject]@{
        CheckedAt = (Get-Date).ToUniversalTime()
        Release = $result
    }
    return $result
}

function Get-SshSpaceUpdateInfo {
    param([switch]$Force)
    $current = Get-SshSpaceApplicationVersion
    $release = Get-SshSpaceLatestRelease -Force:$Force
    $available = (ConvertTo-SshSpaceVersion $release.version) -gt (ConvertTo-SshSpaceVersion $current)
    return [ordered]@{
        currentVersion = $current
        latestVersion = $release.version
        updateAvailable = $available
        releaseName = $release.name
        notes = $release.notes
        publishedAt = $release.publishedAt
        releaseUrl = $release.releaseUrl
        downloadSize = $release.setupSize
    }
}

function Get-SshSpaceExpectedHash {
    param(
        [Parameter(Mandatory)][string]$ChecksumText,
        [Parameter(Mandatory)][string]$FileName
    )
    foreach ($line in ($ChecksumText -split "`r?`n")) {
        if ($line -match '^(?<hash>[a-fA-F0-9]{64})\s+\*?(?<name>.+)$' -and $Matches.name.Trim() -ceq $FileName) {
            return $Matches.hash.ToLowerInvariant()
        }
    }
    throw "SHA256SUMS.txt does not contain a checksum for $FileName."
}

function Save-SshSpaceReleasePackage {
    param([Parameter(Mandatory)][object]$Release)
    $version = [string]$Release.version
    [void](ConvertTo-SshSpaceVersion $version)
    $setupName = [string]$Release.setupName
    $checksumName = [string]$Release.checksumName
    Assert-SshSpaceAssetUrl ([string]$Release.setupUrl) $version $setupName
    Assert-SshSpaceAssetUrl ([string]$Release.checksumUrl) $version $checksumName

    $directory = Join-Path $Root "data\updates\$version"
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $setupPath = Join-Path $directory $setupName
    $checksumPath = Join-Path $directory $checksumName
    $setupDownload = "$setupPath.download"
    $checksumDownload = "$checksumPath.download"
    try {
        Invoke-WebRequest -UseBasicParsing -Uri ([string]$Release.checksumUrl) -OutFile $checksumDownload -TimeoutSec 30
        if ((Get-Item -LiteralPath $checksumDownload).Length -gt 1048576) {
            throw 'SHA256SUMS.txt is unexpectedly large.'
        }
        $checksumText = [IO.File]::ReadAllText($checksumDownload, [Text.Encoding]::UTF8)
        $expectedHash = Get-SshSpaceExpectedHash $checksumText $setupName

        $reuseExisting = $false
        if (Test-Path -LiteralPath $setupPath -PathType Leaf) {
            $existingHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $setupPath).Hash.ToLowerInvariant()
            $reuseExisting = $existingHash -ceq $expectedHash
        }
        if (-not $reuseExisting) {
            Invoke-WebRequest -UseBasicParsing -Uri ([string]$Release.setupUrl) -OutFile $setupDownload -TimeoutSec 180
            $downloadedFile = Get-Item -LiteralPath $setupDownload
            if ($downloadedFile.Length -le 0 -or $downloadedFile.Length -gt $script:SshSpaceMaximumInstallerBytes) {
                throw "Downloaded installer size is outside the allowed range: $($downloadedFile.Length) bytes"
            }
            $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $setupDownload).Hash.ToLowerInvariant()
            if ($actualHash -cne $expectedHash) {
                throw 'Downloaded installer failed SHA-256 verification.'
            }
            Move-Item -LiteralPath $setupDownload -Destination $setupPath -Force
        }
        Move-Item -LiteralPath $checksumDownload -Destination $checksumPath -Force

        $verifiedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $setupPath).Hash.ToLowerInvariant()
        if ($verifiedHash -cne $expectedHash) {
            throw 'Cached installer failed SHA-256 verification.'
        }
        return [ordered]@{
            version = $version
            fileName = $setupName
            path = $setupPath
            sha256 = $expectedHash
            size = (Get-Item -LiteralPath $setupPath).Length
            verified = $true
        }
    } finally {
        foreach ($temporaryPath in @($setupDownload, $checksumDownload)) {
            if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
        }
    }
}

function Save-SshSpaceUpdatePackage {
    param([Parameter(Mandatory)][string]$Version)
    $update = Get-SshSpaceUpdateInfo
    if (-not $update.updateAvailable) { throw 'SSH Space is already up to date.' }
    if ($update.latestVersion -cne $Version) { throw 'The requested update is no longer the latest release.' }
    $release = Get-SshSpaceLatestRelease
    return Save-SshSpaceReleasePackage $release
}

function Get-VerifiedSshSpaceUpdatePackage {
    param([Parameter(Mandatory)][string]$Version)
    $release = Get-SshSpaceLatestRelease
    if ($release.version -cne $Version) { throw 'The requested update is no longer the latest release.' }
    $directory = Join-Path $Root "data\updates\$Version"
    $setupPath = Join-Path $directory ([string]$release.setupName)
    $checksumPath = Join-Path $directory ([string]$release.checksumName)
    if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf) -or -not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) {
        throw 'Download and verify the update before installing it.'
    }
    $checksumText = [IO.File]::ReadAllText($checksumPath, [Text.Encoding]::UTF8)
    $expectedHash = Get-SshSpaceExpectedHash $checksumText ([string]$release.setupName)
    $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $setupPath).Hash.ToLowerInvariant()
    if ($actualHash -cne $expectedHash) { throw 'Cached installer failed SHA-256 verification.' }
    return $setupPath
}

function Start-SshSpaceUpdateInstaller {
    param([Parameter(Mandatory)][string]$Version)
    $setupPath = Get-VerifiedSshSpaceUpdatePackage $Version
    $pathBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($setupPath))
    $launcher = "`$p=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$pathBase64'));Start-Sleep -Seconds 2;Start-Process -FilePath `$p -ArgumentList @('/SILENT','/SUPPRESSMSGBOXES','/NORESTART','/CLOSEAPPLICATIONS','/RESTARTAPPLICATIONS')"
    $encodedLauncher = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($launcher))
    Start-Process -FilePath $PowerShellExecutable -ArgumentList @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedLauncher
    ) -WindowStyle Hidden | Out-Null
    return [ordered]@{ ok = $true; version = $Version; launching = $true }
}

function Open-SshSpaceReleasePage {
    param([Parameter(Mandatory)][string]$Version)
    $release = Get-SshSpaceLatestRelease
    if ($release.version -cne $Version) { throw 'The requested release is no longer the latest release.' }
    $expectedUrl = "https://github.com/$script:SshSpaceRepository/releases/tag/v$Version"
    if (-not [string]::Equals([string]$release.releaseUrl, $expectedUrl, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Release page URL is not trusted.'
    }
    Start-Process $expectedUrl | Out-Null
}
