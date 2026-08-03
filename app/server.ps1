[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)]
    [int]$Port = 8787,
    [switch]$NoBrowser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$AppRoot = $PSScriptRoot
$Root = Split-Path -Parent $AppRoot
$WebRoot = Join-Path $AppRoot 'web'
. (Join-Path $Root 'ssh.ps1')

$PowerShellExecutable = if ($PSVersionTable.PSEdition -eq 'Core') {
    Join-Path $PSHOME 'pwsh.exe'
} else {
    Join-Path $PSHOME 'powershell.exe'
}
if (-not (Test-Path -LiteralPath $PowerShellExecutable -PathType Leaf)) {
    throw "The active PowerShell executable was not found: $PowerShellExecutable"
}
$PowerShellRuntimeEdition = [string]$PSVersionTable.PSEdition
$PowerShellRuntimeVersion = $PSVersionTable.PSVersion.ToString()

function New-ApiToken {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Send-Bytes {
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$ContentType,
        [int]$StatusCode = 200
    )
    $response = $Context.Response
    $response.StatusCode = $StatusCode
    $response.ContentType = $ContentType
    $response.ContentLength64 = $Bytes.Length
    $response.Headers['Cache-Control'] = 'no-store'
    $response.Headers['X-Content-Type-Options'] = 'nosniff'
    $response.Headers['X-Frame-Options'] = 'DENY'
    $response.Headers['Referrer-Policy'] = 'no-referrer'
    $response.Headers['Content-Security-Policy'] = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'"
    try { $response.OutputStream.Write($Bytes, 0, $Bytes.Length) } finally { $response.Close() }
}

function Send-Json {
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [AllowNull()][object]$Data,
        [int]$StatusCode = 200
    )
    $json = $Data | ConvertTo-Json -Depth 20 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    Send-Bytes $Context $bytes 'application/json; charset=utf-8' $StatusCode
}

function Read-RequestJson {
    param([Parameter(Mandatory)][System.Net.HttpListenerRequest]$Request)
    if ($Request.ContentLength64 -gt 12582912) { throw 'Request is larger than 12 MB.' }
    $reader = New-Object IO.StreamReader($Request.InputStream, [Text.Encoding]::UTF8)
    try { $body = $reader.ReadToEnd() } finally { $reader.Dispose() }
    if ([string]::IsNullOrWhiteSpace($body)) { return [pscustomobject]@{} }
    return $body | ConvertFrom-Json
}

function Get-PublicState {
    $runtime = Get-OpenSshStatus
    try {
        $config = Read-SshSpaceConfig
    } catch {
        return [ordered]@{
            servers = @()
            configPath = $ConfigPath
            workspace = $Root
            exportsPath = (Join-Path $Root 'exports')
            configError = $_.Exception.Message
            runtime = [ordered]@{
                sshAvailable = $runtime.Available
                version = $runtime.Version
                source = $runtime.Source
                sshPath = $runtime.SshPath
                powerShellEdition = $PowerShellRuntimeEdition
                powerShellVersion = $PowerShellRuntimeVersion
            }
        }
    }
    $servers = foreach ($entry in Get-ServerEntries $config) {
        $raw = $entry.Value
        $status = 'ready'
        $message = ''
        try { $settings = Get-ServerSettings $config $entry } catch { $status = 'invalid'; $message = $_.Exception.Message }
        $password = [string](Get-ObjectValue $raw 'password' '')
        $identityFile = [string](Get-ObjectValue $raw 'identityFile' '')
        $auth = if ($password) { 'password' } elseif ($identityFile) { 'key' } else { 'interactive' }
        [ordered]@{
            alias = $entry.Name
            host = [string](Get-ObjectValue $raw 'host' '')
            user = [string](Get-ObjectValue $raw 'user' '')
            port = [int](Get-ObjectValue $raw 'port' (Get-ObjectValue $config.defaults 'port' 22))
            identityFile = $identityFile
            hasPassword = -not [string]::IsNullOrEmpty($password)
            auth = $auth
            status = $status
            message = $message
            connectTimeoutSeconds = [int](Get-ObjectValue $raw 'connectTimeoutSeconds' (Get-ObjectValue $config.defaults 'connectTimeoutSeconds' 10))
            serverAliveIntervalSeconds = [int](Get-ObjectValue $raw 'serverAliveIntervalSeconds' (Get-ObjectValue $config.defaults 'serverAliveIntervalSeconds' 30))
            strictHostKeyChecking = [string](Get-ObjectValue $raw 'strictHostKeyChecking' (Get-ObjectValue $config.defaults 'strictHostKeyChecking' 'accept-new'))
        }
    }
    return [ordered]@{
        servers = @($servers)
        configPath = $ConfigPath
        workspace = $Root
        exportsPath = (Join-Path $Root 'exports')
        configError = ''
        runtime = [ordered]@{
            sshAvailable = $runtime.Available
            version = $runtime.Version
            source = $runtime.Source
            sshPath = $runtime.SshPath
            powerShellEdition = $PowerShellRuntimeEdition
            powerShellVersion = $PowerShellRuntimeVersion
        }
    }
}

function Save-ServerFromRequest {
    param([Parameter(Mandatory)][object]$Body)
    $config = Read-SshSpaceConfig
    $alias = [string](Get-ObjectValue $Body 'alias' '')
    $originalAlias = [string](Get-ObjectValue $Body 'originalAlias' '')
    if (-not (Test-ServerAlias $alias)) { throw 'Alias must use 1-64 Unicode letters, numbers, dots, underscores, or hyphens.' }

    $existingEntry = $null
    if ($originalAlias) {
        $existingEntry = Get-ServerEntry $config $originalAlias
    }
    $collision = Get-ServerEntries $config | Where-Object { $_.Name -ieq $alias -and $_.Name -ine $originalAlias } | Select-Object -First 1
    if ($null -ne $collision) { throw "Server alias '$alias' already exists." }

    $passwordAction = [string](Get-ObjectValue $Body 'passwordAction' 'keep')
    $existingPassword = if ($null -ne $existingEntry) { [string](Get-ObjectValue $existingEntry.Value 'password' '') } else { '' }
    $password = switch ($passwordAction) {
        'set' { [string](Get-ObjectValue $Body 'password' '') }
        'clear' { '' }
        'keep' { $existingPassword }
        default { throw 'Invalid password action.' }
    }

    $server = [pscustomobject][ordered]@{
        host = [string](Get-ObjectValue $Body 'host' '')
        user = [string](Get-ObjectValue $Body 'user' '')
        port = [int](Get-ObjectValue $Body 'port' 22)
        identityFile = [string](Get-ObjectValue $Body 'identityFile' '')
        password = $password
        connectTimeoutSeconds = [int](Get-ObjectValue $Body 'connectTimeoutSeconds' 10)
        serverAliveIntervalSeconds = [int](Get-ObjectValue $Body 'serverAliveIntervalSeconds' 30)
        strictHostKeyChecking = [string](Get-ObjectValue $Body 'strictHostKeyChecking' 'accept-new')
    }
    $validationEntry = New-Object System.Management.Automation.PSNoteProperty($alias, $server)
    [void](Get-ServerSettings $config $validationEntry)

    if ($originalAlias) { $config.servers.PSObject.Properties.Remove($originalAlias) }
    $config.servers | Add-Member -MemberType NoteProperty -Name $alias -Value $server
    Save-SshSpaceConfig $config
    return $alias
}

function Remove-ServerFromRequest {
    param([Parameter(Mandatory)][object]$Body)
    $alias = [string](Get-ObjectValue $Body 'alias' '')
    $config = Read-SshSpaceConfig
    [void](Get-ServerEntry $config $alias)
    $config.servers.PSObject.Properties.Remove($alias)
    Save-SshSpaceConfig $config
}

function Save-UploadedKey {
    param([Parameter(Mandatory)][object]$Body)
    $alias = [string](Get-ObjectValue $Body 'alias' 'server')
    if (-not (Test-ServerAlias $alias)) { throw 'Enter a valid server alias before uploading a key.' }
    $fileName = Get-SafeFileName ([string](Get-ObjectValue $Body 'name' 'identity.key'))
    $content = [string](Get-ObjectValue $Body 'content' '')
    try { $bytes = [Convert]::FromBase64String($content) } catch { throw 'Key content is not valid base64.' }
    if ($bytes.Length -eq 0 -or $bytes.Length -gt 524288) { throw 'Key file must be between 1 byte and 512 KB.' }
    $directory = New-IsolatedDirectory (Join-Path $Root 'keys\uploads') $alias
    $destination = Join-Path $directory $fileName
    [IO.File]::WriteAllBytes($destination, $bytes)
    $relative = $destination.Substring($Root.TrimEnd('\').Length + 1) -replace '\\', '/'
    return $relative
}

function Import-UploadedPackages {
    param([Parameter(Mandatory)][object]$Body)
    $files = @(Get-ObjectValue $Body 'files' @())
    if ($files.Count -eq 0 -or $files.Count -gt 200) { throw 'Select between 1 and 200 package files.' }
    $stagingRoot = New-IsolatedDirectory (Join-Path $Root 'data\import-staging') 'upload'
    $totalBytes = 0
    try {
        foreach ($file in $files) {
            $relativePath = ([string](Get-ObjectValue $file 'relativePath' (Get-ObjectValue $file 'name' ''))).Replace('/', '\')
            if ([string]::IsNullOrWhiteSpace($relativePath) -or [IO.Path]::IsPathRooted($relativePath)) { throw 'Invalid uploaded path.' }
            $destination = [IO.Path]::GetFullPath((Join-Path $stagingRoot $relativePath))
            $stagingPrefix = [IO.Path]::GetFullPath($stagingRoot).TrimEnd('\') + '\'
            if (-not $destination.StartsWith($stagingPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Uploaded path escapes the staging directory.' }
            try { $bytes = [Convert]::FromBase64String([string](Get-ObjectValue $file 'content' '')) } catch { throw 'Uploaded content is not valid base64.' }
            $totalBytes += $bytes.Length
            if ($totalBytes -gt 10485760) { throw 'Imported files exceed 10 MB.' }
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            [IO.File]::WriteAllBytes($destination, $bytes)
        }
        $config = Read-SshSpaceConfig
        return @(Import-SshServerPackages $config @($stagingRoot))
    } finally {
        if (Test-Path -LiteralPath $stagingRoot) { Remove-Item -LiteralPath $stagingRoot -Recurse -Force }
    }
}

function ConvertTo-EncodedPowerShell {
    param([Parameter(Mandatory)][string]$Code)
    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Code))
}

function Get-ChildPowerShellCode {
    param([Parameter(Mandatory)][string]$Alias, [string]$Command)
    $scriptB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Join-Path $Root 'ssh.ps1')))
    $aliasB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Alias))
    $commandB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$Command))
    return "`$ProgressPreference='SilentlyContinue';`$s=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$scriptB64'));`$a=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$aliasB64'));`$c=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$commandB64'));if(`$c){& `$s `$a `$c}else{& `$s `$a};exit `$LASTEXITCODE"
}

function Open-ServerTerminal {
    param([Parameter(Mandatory)][string]$Alias)
    $config = Read-SshSpaceConfig
    [void](Get-ServerSettings $config (Get-ServerEntry $config $Alias))
    $encoded = ConvertTo-EncodedPowerShell (Get-ChildPowerShellCode $Alias '')
    Start-Process -FilePath $PowerShellExecutable -ArgumentList @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) | Out-Null
}

function Invoke-RemoteCommandProcess {
    param([Parameter(Mandatory)][string]$Alias, [Parameter(Mandatory)][string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { throw 'Remote command cannot be empty.' }
    $config = Read-SshSpaceConfig
    [void](Get-ServerSettings $config (Get-ServerEntry $config $Alias))
    $encoded = ConvertTo-EncodedPowerShell (Get-ChildPowerShellCode $Alias $Command)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $PowerShellExecutable
    $info.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(120000)) {
        try { $process.Kill() } catch {}
        throw 'Remote command timed out after 120 seconds.'
    }
    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    $combined = ($stdout + $stderr)
    if ($combined.Length -gt 524288) { $combined = $combined.Substring(0, 524288) + "`n[output truncated]" }
    return [ordered]@{ exitCode = $process.ExitCode; output = $combined }
}

function Get-ContentType {
    param([Parameter(Mandatory)][string]$Path)
    switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.html' { 'text/html; charset=utf-8' }
        '.css' { 'text/css; charset=utf-8' }
        '.js' { 'application/javascript; charset=utf-8' }
        '.png' { 'image/png' }
        '.ico' { 'image/x-icon' }
        default { 'application/octet-stream' }
    }
}

function Send-StaticFile {
    param([Parameter(Mandatory)][Net.HttpListenerContext]$Context, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Token)
    $relativePath = if ($Path -eq '/') { 'index.html' } else { $Path.TrimStart('/').Replace('/', '\') }
    $fullPath = [IO.Path]::GetFullPath((Join-Path $WebRoot $relativePath))
    $webPrefix = [IO.Path]::GetFullPath($WebRoot).TrimEnd('\') + '\'
    if (-not $fullPath.StartsWith($webPrefix, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        Send-Json $Context @{ error = 'Not found.' } 404
        return
    }
    if ([IO.Path]::GetFileName($fullPath) -ieq 'index.html') {
        $html = [IO.File]::ReadAllText($fullPath, [Text.Encoding]::UTF8).Replace('__API_TOKEN__', $Token)
        Send-Bytes $Context ([Text.Encoding]::UTF8.GetBytes($html)) (Get-ContentType $fullPath)
    } else {
        Send-Bytes $Context ([IO.File]::ReadAllBytes($fullPath)) (Get-ContentType $fullPath)
    }
}

$apiToken = New-ApiToken
$listener = New-Object Net.HttpListener
$selectedPort = $Port
while ($selectedPort -le [Math]::Min(65535, $Port + 20)) {
    $prefix = "http://127.0.0.1:$selectedPort/"
    $listener.Prefixes.Clear()
    $listener.Prefixes.Add($prefix)
    try { $listener.Start(); break } catch { $selectedPort++ }
}
if (-not $listener.IsListening) { throw "Could not start a local server on ports $Port-$selectedPort." }

Write-Host "SSH Space is running at $prefix" -ForegroundColor Cyan
Write-Host 'Press Ctrl+C to stop.' -ForegroundColor DarkGray
if (-not $NoBrowser) { Start-Process $prefix | Out-Null }

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        try {
            $request = $context.Request
            $path = $request.Url.AbsolutePath
            if (-not $path.StartsWith('/api/')) {
                Send-StaticFile $context $path $apiToken
                continue
            }
            if ($request.Headers['X-SSH-Space-Token'] -cne $apiToken) {
                Send-Json $context @{ error = 'Unauthorized.' } 403
                continue
            }

            switch ("$($request.HttpMethod) $path") {
                'GET /api/state' { Send-Json $context (Get-PublicState) }
                'POST /api/server/save' {
                    $alias = Save-ServerFromRequest (Read-RequestJson $request)
                    Send-Json $context @{ ok = $true; alias = $alias }
                }
                'POST /api/server/delete' {
                    Remove-ServerFromRequest (Read-RequestJson $request)
                    Send-Json $context @{ ok = $true }
                }
                'POST /api/factory-reset' {
                    $body = Read-RequestJson $request
                    $backup = Reset-SshSpaceFactoryDefaults ([string](Get-ObjectValue $body 'confirmation' ''))
                    Send-Json $context @{ ok = $true; backup = $backup }
                }
                'POST /api/key/upload' {
                    $path = Save-UploadedKey (Read-RequestJson $request)
                    Send-Json $context @{ ok = $true; path = $path }
                }
                'POST /api/terminal/open' {
                    $body = Read-RequestJson $request
                    Open-ServerTerminal ([string](Get-ObjectValue $body 'alias' ''))
                    Send-Json $context @{ ok = $true }
                }
                'POST /api/command/run' {
                    $body = Read-RequestJson $request
                    $result = Invoke-RemoteCommandProcess ([string](Get-ObjectValue $body 'alias' '')) ([string](Get-ObjectValue $body 'command' ''))
                    Send-Json $context $result
                }
                'POST /api/export' {
                    $body = Read-RequestJson $request
                    $aliases = @((Get-ObjectValue $body 'aliases' @()) | ForEach-Object { [string]$_ })
                    $config = Read-SshSpaceConfig
                    $result = Export-SshServerPackages $config $aliases ''
                    Send-Json $context @{ ok = $true; directory = $result.Directory; count = $result.Packages.Count }
                }
                'POST /api/import' {
                    $results = Import-UploadedPackages (Read-RequestJson $request)
                    Send-Json $context @{ ok = $true; imported = @($results) }
                }
                'POST /api/folder/open' {
                    $body = Read-RequestJson $request
                    $targetPath = [IO.Path]::GetFullPath([string](Get-ObjectValue $body 'path' ''))
                    $rootPrefix = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
                    if (-not $targetPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $targetPath)) { throw 'Folder path is outside this workspace.' }
                    Start-Process explorer.exe -ArgumentList @($targetPath) | Out-Null
                    Send-Json $context @{ ok = $true }
                }
                default { Send-Json $context @{ error = 'API route not found.' } 404 }
            }
        } catch {
            if ($context.Response.OutputStream.CanWrite) {
                try { Send-Json $context @{ error = $_.Exception.Message } 400 } catch { try { $context.Response.Abort() } catch {} }
            }
        }
    }
} finally {
    $listener.Stop()
    $listener.Close()
}
