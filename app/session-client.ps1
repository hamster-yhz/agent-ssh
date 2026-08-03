Set-StrictMode -Version Latest

$script:SshSpaceSessionDescriptorPath = Join-Path $WorkspaceRoot 'data\session-host.json'
$script:SshSpaceSessionHostScript = Join-Path $WorkspaceRoot 'app\session-host.ps1'

function Get-SshSpaceSessionDescriptor {
    if (-not (Test-Path -LiteralPath $script:SshSpaceSessionDescriptorPath -PathType Leaf)) { return $null }
    try {
        $descriptor = [IO.File]::ReadAllText($script:SshSpaceSessionDescriptorPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $root = [IO.Path]::GetFullPath([string](Get-ObjectValue $descriptor 'root' ''))
        if (-not [string]::Equals($root.TrimEnd('\'), ([IO.Path]::GetFullPath($WorkspaceRoot)).TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { return $null }
        $port = [int](Get-ObjectValue $descriptor 'port' 0)
        $processId = [int](Get-ObjectValue $descriptor 'pid' 0)
        $token = [string](Get-ObjectValue $descriptor 'token' '')
        if ($port -lt 1024 -or $port -gt 65535 -or $processId -le 0 -or $token -notmatch '^[A-Za-z0-9_-]{32,128}$') { return $null }
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($null -eq $process -or $process.HasExited) { return $null }
        return [pscustomobject]@{ Port = $port; Pid = $processId; Token = $token; Root = $root }
    } catch {
        return $null
    }
}

function Get-SshSpaceSessionApiError {
    param([Parameter(Mandatory)][object]$ErrorRecord)
    try {
        $detail = [string]$ErrorRecord.ErrorDetails.Message
        if ($detail) {
            $parsedDetail = $detail | ConvertFrom-Json
            $detailMessage = [string](Get-ObjectValue $parsedDetail 'error' '')
            if ($detailMessage) { return $detailMessage }
        }
        $response = $ErrorRecord.Exception.Response
        if ($null -ne $response) {
            $stream = $response.GetResponseStream()
            if ($null -ne $stream) {
                $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
                try {
                    $body = $reader.ReadToEnd()
                    if ($body) {
                        $parsed = $body | ConvertFrom-Json
                        $message = [string](Get-ObjectValue $parsed 'error' '')
                        if ($message) { return $message }
                    }
                } finally { $reader.Dispose() }
            }
        }
    } catch {}
    return [string]$ErrorRecord.Exception.Message
}

function Invoke-SshSpaceSessionApi {
    param(
        [Parameter(Mandatory)][object]$Descriptor,
        [Parameter(Mandatory)][ValidateSet('GET', 'POST')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][object]$Body,
        [ValidateRange(1, 180)][int]$TimeoutSeconds = 15
    )
    $uri = "http://127.0.0.1:$($Descriptor.Port)$Path"
    $parameters = @{
        Uri = $uri
        Method = $Method
        Headers = @{ 'X-SSH-Space-Session-Token' = $Descriptor.Token }
        TimeoutSec = $TimeoutSeconds
        UseBasicParsing = $true
    }
    if ($Method -eq 'POST') {
        $parameters.ContentType = 'application/json; charset=utf-8'
        $parameters.Body = if ($null -eq $Body) { '{}' } else { $Body | ConvertTo-Json -Depth 10 -Compress }
    }
    try {
        return Invoke-RestMethod @parameters
    } catch {
        throw (Get-SshSpaceSessionApiError $_)
    }
}

function Test-SshSpaceSessionHost {
    param([AllowNull()][object]$Descriptor)
    if ($null -eq $Descriptor) { return $false }
    try {
        $health = Invoke-SshSpaceSessionApi $Descriptor 'GET' '/health' $null 2
        return [bool](Get-ObjectValue $health 'ok' $false)
    } catch { return $false }
}

function Ensure-SshSpaceSessionHost {
    $descriptor = Get-SshSpaceSessionDescriptor
    if (Test-SshSpaceSessionHost $descriptor) { return $descriptor }
    if (-not (Test-Path -LiteralPath $script:SshSpaceSessionHostScript -PathType Leaf)) {
        throw "SSH Space session host is missing: $script:SshSpaceSessionHostScript"
    }

    $powerShellExecutable = if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'powershell.exe' }
    if (-not (Test-Path -LiteralPath $powerShellExecutable -PathType Leaf)) { throw 'The active PowerShell executable is unavailable.' }
    $scriptPathBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script:SshSpaceSessionHostScript))
    $launcher = "`$p=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$scriptPathBase64'));& `$p"
    $encodedLauncher = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($launcher))
    Start-Process -FilePath $powerShellExecutable -ArgumentList @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedLauncher
    ) -WindowStyle Hidden | Out-Null

    foreach ($attempt in 1..60) {
        Start-Sleep -Milliseconds 200
        $descriptor = Get-SshSpaceSessionDescriptor
        if (Test-SshSpaceSessionHost $descriptor) { return $descriptor }
    }
    throw 'The local SSH session host did not become ready within 12 seconds.'
}

function Invoke-SshSpaceSessionRequest {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][object]$Body,
        [ValidateRange(1, 180)][int]$TimeoutSeconds = 15
    )
    $descriptor = Ensure-SshSpaceSessionHost
    return Invoke-SshSpaceSessionApi $descriptor $Method $Path $Body $TimeoutSeconds
}

function Connect-SshSpaceSession {
    param([Parameter(Mandatory)][string]$Alias)
    return Invoke-SshSpaceSessionRequest 'POST' '/connect' @{ alias = $Alias } 45
}

function Get-SshSpaceSessionStatus {
    param([string]$Alias)
    $path = if ([string]::IsNullOrWhiteSpace($Alias)) { '/status' } else { "/status?alias=$([Uri]::EscapeDataString($Alias))" }
    return Invoke-SshSpaceSessionRequest 'GET' $path $null 5
}

function Disconnect-SshSpaceSession {
    param([Parameter(Mandatory)][string]$Alias)
    return Invoke-SshSpaceSessionRequest 'POST' '/disconnect' @{ alias = $Alias } 10
}

function Disconnect-SshSpaceSessionsIfRunning {
    param([string[]]$Aliases)
    $descriptor = Get-SshSpaceSessionDescriptor
    if (-not (Test-SshSpaceSessionHost $descriptor)) { return }
    try {
        if ($null -eq $Aliases -or $Aliases.Count -eq 0) {
            [void](Invoke-SshSpaceSessionApi $descriptor 'POST' '/disconnect-all' @{} 10)
        } else {
            foreach ($alias in @($Aliases | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
                [void](Invoke-SshSpaceSessionApi $descriptor 'POST' '/disconnect' @{ alias = $alias } 10)
            }
        }
    } catch {}
}

function Stop-SshSpaceSessionHostIfIdle {
    $descriptor = Get-SshSpaceSessionDescriptor
    if (-not (Test-SshSpaceSessionHost $descriptor)) { return $true }
    try {
        $result = Invoke-SshSpaceSessionApi $descriptor 'POST' '/shutdown' @{} 5
        return [bool](Get-ObjectValue $result 'ok' $false)
    } catch { return $false }
}

function Invoke-SshSpaceSessionCommand {
    param(
        [Parameter(Mandatory)][string]$Alias,
        [Parameter(Mandatory)][string]$Command,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 120
    )
    if ([string]::IsNullOrWhiteSpace($Command)) { throw 'Remote command cannot be empty.' }
    return Invoke-SshSpaceSessionRequest 'POST' '/execute' @{
        alias = $Alias
        command = $Command
        timeoutSeconds = $TimeoutSeconds
    } ([Math]::Min(180, $TimeoutSeconds + 15))
}
