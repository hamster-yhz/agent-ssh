[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Target,

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$RemoteCommand
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$WorkspaceRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
$InstalledMarkerPath = Join-Path $WorkspaceRoot '.agent-ssh-installed'
$DataRoot = if ($env:AGENT_SSH_DATA_HOME) {
    [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($env:AGENT_SSH_DATA_HOME))
} elseif (Test-Path -LiteralPath $InstalledMarkerPath -PathType Leaf) {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'LOCALAPPDATA is unavailable; agent-ssh cannot locate its installed user data.'
    }
    [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'agent-ssh'))
} else {
    $WorkspaceRoot
}
$ConfigPath = if ($env:AGENT_SSH_CONFIG) {
    [System.IO.Path]::GetFullPath($env:AGENT_SSH_CONFIG)
} else {
    Join-Path $DataRoot 'config\servers.local.json'
}
$ExampleConfigPath = Join-Path $WorkspaceRoot 'config\servers.example.json'
$KeysRoot = Join-Path $DataRoot 'keys'
$RuntimeDataRoot = Join-Path $DataRoot 'data'
$ExportsRoot = Join-Path $DataRoot 'exports'
$KnownHostsPath = Join-Path $RuntimeDataRoot 'known_hosts'
$AskPassSourcePath = Join-Path $WorkspaceRoot 'app\helpers\AgentSsh.AskPass.cs'
$AskPassExePath = Join-Path $RuntimeDataRoot 'agent-ssh-askpass.exe'
$BackupRoot = Join-Path $DataRoot 'backups'
$BundledOpenSshRoot = Join-Path $WorkspaceRoot 'runtime\openssh'

function Show-Usage {
    @'
agent-ssh

Usage:
  .\agent-ssh.ps1 list                     List servers
  .\agent-ssh.ps1 doctor [alias]           Validate configuration
  .\agent-ssh.ps1 connect <alias>           Establish a reusable SSH session
  .\agent-ssh.ps1 status [alias]            Show reusable session status
  .\agent-ssh.ps1 disconnect <alias>        Close the reusable command session
  .\agent-ssh.ps1 config                   Open local configuration
  .\agent-ssh.ps1 export <alias|all>        Export isolated packages
  .\agent-ssh.ps1 export-many <aliases...>  Export selected servers as a batch
  .\agent-ssh.ps1 import <path...>          Import one or many packages
  .\agent-ssh.ps1 reset                    Restore factory defaults
  .\agent-ssh.ps1 <alias>                  Start an SSH session
  .\agent-ssh.ps1 <alias> <command...>     Run a remote command

Examples:
  .\agent-ssh.ps1 dev
  .\agent-ssh.ps1 dev uptime
  .\agent-ssh.ps1 dev "docker ps --format '{{.Names}}'"
'@ | Write-Host
}

function Initialize-LocalConfig {
    if (Test-Path -LiteralPath $ConfigPath) {
        return
    }

    $configDirectory = Split-Path -Parent $ConfigPath
    New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
    Copy-Item -LiteralPath $ExampleConfigPath -Destination $ConfigPath
    Write-Host "Created local config: $ConfigPath" -ForegroundColor Yellow
}

function Get-ObjectValue {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][object]$DefaultValue
    )

    if ($null -eq $Object) {
        return $DefaultValue
    }

    $property = $Object.PSObject.Properties |
        Where-Object { $_.Name -ieq $Name } |
        Select-Object -First 1

    if ($null -eq $property -or $null -eq $property.Value) {
        return $DefaultValue
    }

    return $property.Value
}

. (Join-Path $WorkspaceRoot 'app\session-client.ps1')

function Read-AgentSshConfig {
    Initialize-LocalConfig
    try {
        $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "Config is not valid JSON: $ConfigPath`n$($_.Exception.Message)"
    }

    if ($null -eq (Get-ObjectValue $config 'servers' $null)) {
        throw "Config is missing 'servers': $ConfigPath"
    }

    return $config
}

function Get-ServerEntries {
    param([Parameter(Mandatory)][object]$Config)

    $servers = Get-ObjectValue $Config 'servers' $null
    return @($servers.PSObject.Properties)
}

function Get-ServerEntry {
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$Alias
    )

    $entry = Get-ServerEntries $Config |
        Where-Object { $_.Name -ieq $Alias } |
        Select-Object -First 1

    if ($null -eq $entry) {
        $available = (Get-ServerEntries $Config | ForEach-Object Name) -join ', '
        throw "Server '$Alias' was not found. Available servers: $available"
    }

    return $entry
}

function Resolve-AgentSshDataPath {
    param([Parameter(Mandatory)][string]$Path)

    $expandedPath = [Environment]::ExpandEnvironmentVariables($Path)
    if ([System.IO.Path]::IsPathRooted($expandedPath)) {
        return [System.IO.Path]::GetFullPath($expandedPath)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $DataRoot $expandedPath))
}

function Resolve-AgentSshUserPath {
    param([Parameter(Mandatory)][string]$Path)

    $expandedPath = [Environment]::ExpandEnvironmentVariables($Path)
    if ([System.IO.Path]::IsPathRooted($expandedPath)) {
        return [System.IO.Path]::GetFullPath($expandedPath)
    }
    return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $expandedPath))
}

function Get-ServerSettings {
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][System.Management.Automation.PSNoteProperty]$Entry
    )

    $defaults = Get-ObjectValue $Config 'defaults' $null
    $server = $Entry.Value

    $hostName = [string](Get-ObjectValue $server 'host' '')
    $userName = [string](Get-ObjectValue $server 'user' '')
    $port = [int](Get-ObjectValue $server 'port' (Get-ObjectValue $defaults 'port' 22))
    $identityFile = [string](Get-ObjectValue $server 'identityFile' '')
    $password = [string](Get-ObjectValue $server 'password' '')
    $connectTimeout = [int](Get-ObjectValue $server 'connectTimeoutSeconds' (Get-ObjectValue $defaults 'connectTimeoutSeconds' 10))
    $aliveInterval = [int](Get-ObjectValue $server 'serverAliveIntervalSeconds' (Get-ObjectValue $defaults 'serverAliveIntervalSeconds' 30))
    $strictHostKeyChecking = [string](Get-ObjectValue $server 'strictHostKeyChecking' (Get-ObjectValue $defaults 'strictHostKeyChecking' 'accept-new'))

    if ([string]::IsNullOrWhiteSpace($hostName) -or $hostName -eq 'CHANGE_ME') {
        throw "Server '$($Entry.Name)' has no valid host."
    }
    if ($hostName -match '\s') {
        throw "Server '$($Entry.Name)' has whitespace in host."
    }
    if ([string]::IsNullOrWhiteSpace($userName) -or $userName -eq 'CHANGE_ME') {
        throw "Server '$($Entry.Name)' has no valid user."
    }
    if ($userName -match '[\s@]') {
        throw "Server '$($Entry.Name)' has whitespace or @ in user."
    }
    if ($port -lt 1 -or $port -gt 65535) {
        throw "Server '$($Entry.Name)' port must be between 1 and 65535."
    }
    if ($connectTimeout -lt 1) {
        throw "Server '$($Entry.Name)' connectTimeoutSeconds must be greater than 0."
    }
    if ($aliveInterval -lt 0) {
        throw "Server '$($Entry.Name)' serverAliveIntervalSeconds cannot be negative."
    }
    if ($strictHostKeyChecking -notin @('yes', 'no', 'ask', 'accept-new')) {
        throw "Server '$($Entry.Name)' has an invalid strictHostKeyChecking value."
    }
    if ($password -match "[`r`n]") {
        throw "Server '$($Entry.Name)' password cannot contain newlines."
    }

    $resolvedIdentityFile = ''
    if (-not [string]::IsNullOrWhiteSpace($identityFile)) {
        $resolvedIdentityFile = Resolve-AgentSshDataPath $identityFile
        if (-not (Test-Path -LiteralPath $resolvedIdentityFile -PathType Leaf)) {
            throw "Server '$($Entry.Name)' key file does not exist: $resolvedIdentityFile"
        }
    }

    [pscustomobject]@{
        Alias = $Entry.Name
        Host = $hostName
        User = $userName
        Port = $port
        IdentityFile = $resolvedIdentityFile
        Password = $password
        ConnectTimeout = $connectTimeout
        AliveInterval = $aliveInterval
        StrictHostKeyChecking = $strictHostKeyChecking
    }
}

function Get-AuthLabel {
    param([Parameter(Mandatory)][object]$Settings)

    if (-not [string]::IsNullOrEmpty($Settings.Password)) { return 'password' }
    if (-not [string]::IsNullOrEmpty($Settings.IdentityFile)) { return 'key' }
    return 'interactive'
}

function Resolve-OpenSshCommand {
    param([Parameter(Mandatory)][string]$Name)

    $bundled = Join-Path $BundledOpenSshRoot "$Name.exe"
    if (Test-Path -LiteralPath $bundled -PathType Leaf) {
        return [pscustomobject]@{ Path = $bundled; Source = 'bundled' }
    }

    $system = Get-Command "$Name.exe" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $system) {
        return [pscustomobject]@{ Path = $system.Source; Source = 'system' }
    }
    return $null
}

function Get-OpenSshStatus {
    $sshCommand = Resolve-OpenSshCommand 'ssh'
    $scpCommand = Resolve-OpenSshCommand 'scp'
    $keygenCommand = Resolve-OpenSshCommand 'ssh-keygen'
    $version = ''
    if ($null -ne $sshCommand) {
        try {
            $info = New-Object Diagnostics.ProcessStartInfo
            $info.FileName = $sshCommand.Path
            $info.Arguments = '-V'
            $info.UseShellExecute = $false
            $info.CreateNoWindow = $true
            $info.RedirectStandardOutput = $true
            $info.RedirectStandardError = $true
            $process = New-Object Diagnostics.Process
            $process.StartInfo = $info
            [void]$process.Start()
            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            $version = ($stderr + $stdout).Trim()
            $process.Dispose()
        } catch {}
    }
    return [pscustomobject]@{
        Available = $null -ne $sshCommand
        Source = if ($null -ne $sshCommand) { $sshCommand.Source } else { 'missing' }
        SshPath = if ($null -ne $sshCommand) { $sshCommand.Path } else { '' }
        ScpPath = if ($null -ne $scpCommand) { $scpCommand.Path } else { '' }
        KeygenPath = if ($null -ne $keygenCommand) { $keygenCommand.Path } else { '' }
        Version = $version
    }
}

function Assert-OpenSshAvailable {
    $status = Get-OpenSshStatus
    if (-not $status.Available) {
        throw 'OpenSSH Client is unavailable. Reinstall agent-ssh or enable the Windows OpenSSH Client.'
    }
    return $status
}

function New-SshArguments {
    param(
        [Parameter(Mandatory)][object]$Settings,
        [string[]]$RemoteArguments,
        [switch]$BatchMode
    )

    $dataDirectory = Split-Path -Parent $KnownHostsPath
    New-Item -ItemType Directory -Path $dataDirectory -Force | Out-Null

    $arguments = @(
        '-F', 'NUL',
        '-p', [string]$Settings.Port,
        '-l', $Settings.User,
        '-o', "ConnectTimeout=$($Settings.ConnectTimeout)",
        '-o', "ServerAliveInterval=$($Settings.AliveInterval)",
        '-o', "StrictHostKeyChecking=$($Settings.StrictHostKeyChecking)",
        '-o', "UserKnownHostsFile=$KnownHostsPath"
    )

    if (-not [string]::IsNullOrEmpty($Settings.Password)) {
        $arguments += @(
            '-o', 'PubkeyAuthentication=no',
            '-o', 'PreferredAuthentications=password,keyboard-interactive'
        )
    } elseif (-not [string]::IsNullOrEmpty($Settings.IdentityFile)) {
        $arguments += @('-i', $Settings.IdentityFile, '-o', 'IdentitiesOnly=yes')
    }

    if ($BatchMode) { $arguments += @('-o', 'BatchMode=yes') }

    $arguments += $Settings.Host
    if ($null -ne $RemoteArguments -and $RemoteArguments.Count -gt 0) { $arguments += $RemoteArguments }
    return $arguments
}

function Ensure-AskPassExecutable {
    if (-not (Test-Path -LiteralPath $AskPassSourcePath -PathType Leaf)) {
        throw "Password helper source is missing: $AskPassSourcePath"
    }

    if (Test-Path -LiteralPath $AskPassExePath -PathType Leaf) {
        $helperTime = (Get-Item -LiteralPath $AskPassExePath).LastWriteTimeUtc
        $sourceTime = (Get-Item -LiteralPath $AskPassSourcePath).LastWriteTimeUtc
        if ($helperTime -ge $sourceTime) { return }
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $AskPassExePath) -Force | Out-Null
    $temporaryPath = "$AskPassExePath.$([Guid]::NewGuid().ToString('N')).tmp.exe"
    try {
        $source = Get-Content -LiteralPath $AskPassSourcePath -Raw -Encoding UTF8
        Add-Type -TypeDefinition $source -Language CSharp -OutputAssembly $temporaryPath -OutputType ConsoleApplication
        Move-Item -LiteralPath $temporaryPath -Destination $AskPassExePath -Force
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
    }
}

function Invoke-SshConnection {
    param(
        [Parameter(Mandatory)][object]$Settings,
        [string[]]$CommandParts
    )

    $script:SshConnectionExitCode = 1
    $runtime = Assert-OpenSshAvailable
    $sshArguments = @(New-SshArguments $Settings)
    if ($null -ne $CommandParts -and $CommandParts.Count -gt 0) {
        $sshArguments += $CommandParts
    }

    [Console]::Out.WriteLine(("Connecting to {0} ({1}@{2}:{3}, {4})" -f $Settings.Alias, $Settings.User, $Settings.Host, $Settings.Port, (Get-AuthLabel $Settings)))

    if ([string]::IsNullOrEmpty($Settings.Password)) {
        & $runtime.SshPath @sshArguments
        $script:SshConnectionExitCode = $LASTEXITCODE
        return
    }

    Ensure-AskPassExecutable
    $previousAskPass = $env:SSH_ASKPASS
    $previousAskPassRequire = $env:SSH_ASKPASS_REQUIRE
    $previousDisplay = $env:DISPLAY
    $previousPassword = $env:AGENT_SSH_PASSWORD
    try {
        $env:SSH_ASKPASS = $AskPassExePath
        $env:SSH_ASKPASS_REQUIRE = 'force'
        $env:DISPLAY = 'agent-ssh'
        $env:AGENT_SSH_PASSWORD = $Settings.Password
        & $runtime.SshPath @sshArguments
        $script:SshConnectionExitCode = $LASTEXITCODE
    } finally {
        $env:SSH_ASKPASS = $previousAskPass
        $env:SSH_ASKPASS_REQUIRE = $previousAskPassRequire
        $env:DISPLAY = $previousDisplay
        $env:AGENT_SSH_PASSWORD = $previousPassword
    }
}

function Show-ServerList {
    param([Parameter(Mandatory)][object]$Config)

    $rows = foreach ($entry in Get-ServerEntries $Config) {
        try {
            $settings = Get-ServerSettings $Config $entry
            [pscustomobject]@{
                Name = $settings.Alias
                Address = "$($settings.User)@$($settings.Host):$($settings.Port)"
                Auth = Get-AuthLabel $settings
                Status = 'ok'
            }
        } catch {
            [pscustomobject]@{
                Name = $entry.Name
                Address = '-'
                Auth = '-'
                Status = $_.Exception.Message
            }
        }
    }

    $rows | Format-Table -AutoSize
}

function Invoke-Doctor {
    param(
        [Parameter(Mandatory)][object]$Config,
        [string]$Alias
    )

    $failed = $false
    $runtime = Get-OpenSshStatus
    if ($runtime.Available) {
        Write-Host "[OK] OpenSSH ($($runtime.Source)): $($runtime.Version)" -ForegroundColor Green
    } else {
        $failed = $true
        Write-Host '[ERROR] OpenSSH Client is not installed.' -ForegroundColor Red
    }

    $entries = if ([string]::IsNullOrWhiteSpace($Alias)) {
        Get-ServerEntries $Config
    } else {
        @(Get-ServerEntry $Config $Alias)
    }

    foreach ($entry in $entries) {
        try {
            $settings = Get-ServerSettings $Config $entry
            Write-Host ("[OK] {0}: {1}@{2}:{3} ({4})" -f $settings.Alias, $settings.User, $settings.Host, $settings.Port, (Get-AuthLabel $settings)) -ForegroundColor Green
        } catch {
            $failed = $true
            Write-Host "[ERROR] $($entry.Name): $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    if ($failed) { return 1 }
    return 0
}

function Save-AgentSshConfig {
    param([Parameter(Mandatory)][object]$Config)

    [void](New-ConfigSnapshot 'auto-save')
    $json = $Config | ConvertTo-Json -Depth 20
    $directory = Split-Path -Parent $ConfigPath
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temporaryPath = "$ConfigPath.tmp.$([Guid]::NewGuid().ToString('N'))"
    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($temporaryPath, $json, $utf8)
        Move-Item -LiteralPath $temporaryPath -Destination $ConfigPath -Force
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function New-ConfigSnapshot {
    param([Parameter(Mandatory)][string]$Reason)
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return '' }
    $directory = New-IsolatedDirectory $BackupRoot $Reason
    Copy-Item -LiteralPath $ConfigPath -Destination (Join-Path $directory 'servers.local.json')
    return $directory
}

function Reset-AgentSshFactoryDefaults {
    param([Parameter(Mandatory)][string]$Confirmation)
    if ($Confirmation -cne 'RESET agent-ssh') {
        throw 'Confirmation did not match. Factory reset was canceled.'
    }

    $backupDirectory = New-IsolatedDirectory $BackupRoot 'factory-reset'
    if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
        Copy-Item -LiteralPath $ConfigPath -Destination (Join-Path $backupDirectory 'servers.local.json')
    }

    $keyItems = @(Get-ChildItem -LiteralPath $KeysRoot -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '.gitkeep' })
    if ($keyItems.Count -gt 0) {
        $backupKeys = Join-Path $backupDirectory 'keys'
        New-Item -ItemType Directory -Path $backupKeys -Force | Out-Null
        foreach ($item in $keyItems) {
            Move-Item -LiteralPath $item.FullName -Destination $backupKeys
        }
    }

    if (Test-Path -LiteralPath $KnownHostsPath -PathType Leaf) {
        Move-Item -LiteralPath $KnownHostsPath -Destination (Join-Path $backupDirectory 'known_hosts')
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $ConfigPath) -Force | Out-Null
    Copy-Item -LiteralPath $ExampleConfigPath -Destination $ConfigPath -Force
    return $backupDirectory
}

function Test-ServerAlias {
    param([Parameter(Mandatory)][string]$Alias)
    return $Alias -cmatch '^[\p{L}\p{N}][\p{L}\p{N}._-]{0,63}$'
}

function Get-SafeFileName {
    param([Parameter(Mandatory)][string]$Name)
    $safeName = $Name -replace '[^A-Za-z0-9._-]', '_'
    if ([string]::IsNullOrWhiteSpace($safeName)) { return 'server' }
    return $safeName
}

function New-IsolatedDirectory {
    param(
        [Parameter(Mandatory)][string]$Parent,
        [Parameter(Mandatory)][string]$Prefix
    )

    New-Item -ItemType Directory -Path $Parent -Force | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $suffix = [Guid]::NewGuid().ToString('N').Substring(0, 6)
    $path = Join-Path $Parent "$(Get-SafeFileName $Prefix)_${stamp}_$suffix"
    New-Item -ItemType Directory -Path $path | Out-Null
    return $path
}

function Export-SshServerPackages {
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string[]]$Aliases,
        [string]$OutputDirectory
    )

    if ($Aliases.Count -eq 0) { throw 'No servers were selected for export.' }
    $outputRoot = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        $ExportsRoot
    } else {
        Resolve-AgentSshUserPath $OutputDirectory
    }
    $batchPrefix = if ($Aliases.Count -eq 1) { $Aliases[0] } else { 'batch' }
    $batchDirectory = New-IsolatedDirectory $outputRoot $batchPrefix
    $packageResults = @()

    foreach ($alias in $Aliases) {
        $entry = Get-ServerEntry $Config $alias
        $settings = Get-ServerSettings $Config $entry
        $packageDirectory = if ($Aliases.Count -eq 1) {
            $batchDirectory
        } else {
            $path = Join-Path $batchDirectory (Get-SafeFileName $settings.Alias)
            New-Item -ItemType Directory -Path $path | Out-Null
            $path
        }

        $packagedKeyName = ''
        if (-not [string]::IsNullOrEmpty($settings.IdentityFile)) {
            $originalKeyName = [System.IO.Path]::GetFileName($settings.IdentityFile)
            $packagedKeyName = "key-$(Get-SafeFileName $originalKeyName)"
            Copy-Item -LiteralPath $settings.IdentityFile -Destination (Join-Path $packageDirectory $packagedKeyName)
        }

        $package = [ordered]@{
            packageVersion = 1
            exportedAt = (Get-Date).ToUniversalTime().ToString('o')
            alias = $settings.Alias
            server = [ordered]@{
                host = $settings.Host
                user = $settings.User
                port = $settings.Port
                identityFile = $packagedKeyName
                password = $settings.Password
                connectTimeoutSeconds = $settings.ConnectTimeout
                serverAliveIntervalSeconds = $settings.AliveInterval
                strictHostKeyChecking = $settings.StrictHostKeyChecking
            }
        }
        $packageJson = $package | ConvertTo-Json -Depth 10
        $utf8 = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText((Join-Path $packageDirectory 'server.json'), $packageJson, $utf8)
        $packageResults += [pscustomobject]@{
            Alias = $settings.Alias
            Directory = $packageDirectory
            HasKey = -not [string]::IsNullOrEmpty($packagedKeyName)
        }
    }

    return [pscustomobject]@{ Directory = $batchDirectory; Packages = $packageResults }
}

function Get-UniqueServerAlias {
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string]$DesiredAlias
    )

    $existingNames = @(Get-ServerEntries $Config | ForEach-Object Name)
    if ($DesiredAlias -notin $existingNames) { return $DesiredAlias }
    for ($index = 2; $index -le 9999; $index++) {
        $suffix = "-imported-$index"
        $baseLength = [Math]::Min($DesiredAlias.Length, 64 - $suffix.Length)
        $candidate = $DesiredAlias.Substring(0, $baseLength) + $suffix
        if ($candidate -notin $existingNames) { return $candidate }
    }
    throw "Could not create a unique alias for '$DesiredAlias'."
}

function Import-SshServerPackages {
    param(
        [Parameter(Mandatory)][object]$Config,
        [Parameter(Mandatory)][string[]]$Paths
    )

    $packageFiles = New-Object System.Collections.Generic.List[string]
    $seenFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($inputPath in $Paths) {
        $resolvedPath = Resolve-AgentSshUserPath $inputPath
        if (Test-Path -LiteralPath $resolvedPath -PathType Leaf) {
            if ([System.IO.Path]::GetFileName($resolvedPath) -ine 'server.json') {
                throw "Import file must be named server.json: $resolvedPath"
            }
            if ($seenFiles.Add($resolvedPath)) { $packageFiles.Add($resolvedPath) }
        } elseif (Test-Path -LiteralPath $resolvedPath -PathType Container) {
            foreach ($file in Get-ChildItem -LiteralPath $resolvedPath -Filter 'server.json' -File -Recurse) {
                if ($seenFiles.Add($file.FullName)) { $packageFiles.Add($file.FullName) }
            }
        } else {
            throw "Import path does not exist: $resolvedPath"
        }
    }
    if ($packageFiles.Count -eq 0) { throw 'No server.json packages were found.' }

    $imported = @()
    foreach ($packageFile in $packageFiles) {
        try {
            $package = Get-Content -LiteralPath $packageFile -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            throw "Invalid package JSON: $packageFile`n$($_.Exception.Message)"
        }
        if ([int](Get-ObjectValue $package 'packageVersion' 0) -ne 1) {
            throw "Unsupported package version: $packageFile"
        }
        $desiredAlias = [string](Get-ObjectValue $package 'alias' '')
        if (-not (Test-ServerAlias $desiredAlias)) {
            throw "Invalid server alias in package: $packageFile"
        }
        $server = Get-ObjectValue $package 'server' $null
        if ($null -eq $server) { throw "Package has no server object: $packageFile" }
        $importAlias = Get-UniqueServerAlias $Config $desiredAlias
        $packageDirectory = Split-Path -Parent $packageFile
        $identityFile = [string](Get-ObjectValue $server 'identityFile' '')
        $importedIdentityFile = ''

        if (-not [string]::IsNullOrWhiteSpace($identityFile)) {
            if ([System.IO.Path]::IsPathRooted($identityFile)) {
                throw "Package key path must be relative: $packageFile"
            }
            $packageRoot = [System.IO.Path]::GetFullPath($packageDirectory).TrimEnd('\') + '\'
            $sourceKey = [System.IO.Path]::GetFullPath((Join-Path $packageDirectory $identityFile))
            if (-not $sourceKey.StartsWith($packageRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Package key path escapes its directory: $packageFile"
            }
            if (-not (Test-Path -LiteralPath $sourceKey -PathType Leaf)) {
                throw "Package key file is missing: $sourceKey"
            }
            $keyDirectory = New-IsolatedDirectory (Join-Path $KeysRoot 'imports') $importAlias
            $destinationKey = Join-Path $keyDirectory (Get-SafeFileName ([System.IO.Path]::GetFileName($sourceKey)))
            Copy-Item -LiteralPath $sourceKey -Destination $destinationKey
            $relativeKey = $destinationKey.Substring($DataRoot.TrimEnd('\').Length + 1)
            $importedIdentityFile = $relativeKey -replace '\\', '/'
        }

        $importedServer = [pscustomobject][ordered]@{
            host = [string](Get-ObjectValue $server 'host' '')
            user = [string](Get-ObjectValue $server 'user' '')
            port = [int](Get-ObjectValue $server 'port' 22)
            identityFile = $importedIdentityFile
            password = [string](Get-ObjectValue $server 'password' '')
            connectTimeoutSeconds = [int](Get-ObjectValue $server 'connectTimeoutSeconds' 10)
            serverAliveIntervalSeconds = [int](Get-ObjectValue $server 'serverAliveIntervalSeconds' 30)
            strictHostKeyChecking = [string](Get-ObjectValue $server 'strictHostKeyChecking' 'accept-new')
        }
        $validationEntry = New-Object System.Management.Automation.PSNoteProperty($importAlias, $importedServer)
        [void](Get-ServerSettings $Config $validationEntry)
        $Config.servers | Add-Member -MemberType NoteProperty -Name $importAlias -Value $importedServer
        $imported += [pscustomobject]@{ OriginalAlias = $desiredAlias; Alias = $importAlias; Source = $packageFile }
    }

    Save-AgentSshConfig $Config
    return $imported
}

function Invoke-AgentSshCli {
try {
    if ([string]::IsNullOrWhiteSpace($Target) -or $Target -in @('help', '-h', '--help')) {
        Show-Usage
        exit 0
    }

    if ($Target -eq 'config') {
        Initialize-LocalConfig
        Start-Process notepad.exe -ArgumentList @($ConfigPath)
        Write-Host "Opened: $ConfigPath"
        exit 0
    }

    if ($Target -eq 'reset') {
        Write-Host 'WARNING: This resets all server configuration, imported/uploaded keys, and known_hosts.' -ForegroundColor Yellow
        Write-Host 'A recoverable backup will be created. Export packages are not changed.' -ForegroundColor Yellow
        $confirmation = Read-Host 'Type RESET agent-ssh to continue'
        $backup = Reset-AgentSshFactoryDefaults $confirmation
        Disconnect-AgentSshSessionsIfRunning @()
        Write-Host "Factory defaults restored. Backup: $backup" -ForegroundColor Green
        exit 0
    }

    $config = Read-AgentSshConfig

    if ($Target -eq 'list') {
        Show-ServerList $config
        exit 0
    }

    if ($Target -eq 'doctor') {
        $doctorAlias = if ($null -ne $RemoteCommand -and $RemoteCommand.Length -gt 0) { $RemoteCommand[0] } else { '' }
        exit (Invoke-Doctor $config $doctorAlias)
    }

    if ($Target -eq 'connect') {
        if ($null -eq $RemoteCommand -or $RemoteCommand.Length -ne 1) { throw 'Usage: .\agent-ssh.ps1 connect <alias>' }
        [void](Get-ServerSettings $config (Get-ServerEntry $config $RemoteCommand[0]))
        $status = Connect-AgentSshSession $RemoteCommand[0]
        Write-Host "Connected: $($status.alias) (idle timeout $($status.idleTimeoutSeconds)s)" -ForegroundColor Green
        exit 0
    }

    if ($Target -eq 'status') {
        $statusAlias = if ($null -ne $RemoteCommand -and $RemoteCommand.Length -gt 0) { $RemoteCommand[0] } else { '' }
        if (@($RemoteCommand).Count -gt 1) { throw 'Usage: .\agent-ssh.ps1 status [alias]' }
        $result = Get-AgentSshSessionStatus $statusAlias
        $sessions = @($result.sessions)
        if ($sessions.Count -eq 0) { Write-Host 'No reusable SSH sessions.' -ForegroundColor DarkGray }
        else { $sessions | Select-Object alias, state, idleSeconds, idleTimeoutSeconds | Format-Table -AutoSize }
        exit 0
    }

    if ($Target -eq 'disconnect') {
        if ($null -eq $RemoteCommand -or $RemoteCommand.Length -ne 1) { throw 'Usage: .\agent-ssh.ps1 disconnect <alias>' }
        $status = Disconnect-AgentSshSession $RemoteCommand[0]
        Write-Host "Disconnected: $($status.alias)" -ForegroundColor Green
        exit 0
    }

    if ($Target -eq 'export') {
        if ($null -eq $RemoteCommand -or $RemoteCommand.Length -lt 1) {
            throw 'Usage: .\agent-ssh.ps1 export <alias|all> [output-directory]'
        }
        $selection = $RemoteCommand[0]
        $aliases = if ($selection -ieq 'all') {
            @(Get-ServerEntries $config | ForEach-Object Name)
        } else {
            @($selection)
        }
        $outputDirectory = if ($RemoteCommand.Length -gt 1) { $RemoteCommand[1] } else { '' }
        $result = Export-SshServerPackages $config $aliases $outputDirectory
        Write-Host "Exported to: $($result.Directory)" -ForegroundColor Green
        exit 0
    }

    if ($Target -eq 'export-many') {
        if ($null -eq $RemoteCommand -or $RemoteCommand.Length -lt 1) {
            throw 'Usage: .\agent-ssh.ps1 export-many <alias1> <alias2> [...]'
        }
        $result = Export-SshServerPackages $config @($RemoteCommand) ''
        Write-Host "Exported $($result.Packages.Count) servers to: $($result.Directory)" -ForegroundColor Green
        exit 0
    }

    if ($Target -eq 'import') {
        if ($null -eq $RemoteCommand -or $RemoteCommand.Length -lt 1) {
            throw 'Usage: .\agent-ssh.ps1 import <server.json|package-directory> [more paths...]'
        }
        $results = Import-SshServerPackages $config $RemoteCommand
        foreach ($result in $results) {
            Write-Host "Imported $($result.OriginalAlias) as $($result.Alias)" -ForegroundColor Green
        }
        exit 0
    }

    $serverEntry = Get-ServerEntry $config $Target
    $serverSettings = Get-ServerSettings $config $serverEntry
    if ($null -ne $RemoteCommand -and $RemoteCommand.Length -gt 0) {
        $result = Invoke-AgentSshSessionCommand $serverSettings.Alias ($RemoteCommand -join ' ') 120
        if (-not [string]::IsNullOrEmpty([string]$result.output)) { [Console]::Out.WriteLine([string]$result.output) }
        exit ([int]$result.exitCode)
    }
    # Invoke as a statement so native SSH output remains attached to the console.
    # Capturing the function inside exit (...) swallows remote output in PowerShell.
    Invoke-SshConnection $serverSettings $RemoteCommand
    exit $script:SshConnectionExitCode
} catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-AgentSshCli
}
