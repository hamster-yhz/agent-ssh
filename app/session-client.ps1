Set-StrictMode -Version Latest

$script:AgentSshSessionDescriptorPath = Join-Path $RuntimeDataRoot 'session-host.json'
$script:AgentSshSessionHostScript = Join-Path $WorkspaceRoot 'app\session-host.ps1'

function Get-AgentSshSessionDescriptor {
    if (-not (Test-Path -LiteralPath $script:AgentSshSessionDescriptorPath -PathType Leaf)) { return $null }
    try {
        $descriptor = [IO.File]::ReadAllText($script:AgentSshSessionDescriptorPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $root = [IO.Path]::GetFullPath([string](Get-ObjectValue $descriptor 'root' ''))
        $dataRoot = [IO.Path]::GetFullPath([string](Get-ObjectValue $descriptor 'dataRoot' ''))
        if (-not [string]::Equals($root.TrimEnd('\'), $WorkspaceRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { return $null }
        if (-not [string]::Equals($dataRoot.TrimEnd('\'), $DataRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) { return $null }
        $port = [int](Get-ObjectValue $descriptor 'port' 0)
        $processId = [int](Get-ObjectValue $descriptor 'pid' 0)
        $token = [string](Get-ObjectValue $descriptor 'token' '')
        if ($port -lt 1024 -or $port -gt 65535 -or $processId -le 0 -or $token -notmatch '^[A-Za-z0-9_-]{32,128}$') { return $null }
        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($null -eq $process -or $process.HasExited) { return $null }
        return [pscustomobject]@{ Port = $port; Pid = $processId; Token = $token; Root = $root; DataRoot = $dataRoot }
    } catch {
        return $null
    }
}

function Get-AgentSshSessionApiError {
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

function Invoke-AgentSshSessionApi {
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
        Headers = @{ 'X-Agent-Ssh-Session-Token' = $Descriptor.Token }
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
        throw (Get-AgentSshSessionApiError $_)
    }
}

function Test-AgentSshSessionHost {
    param([AllowNull()][object]$Descriptor)
    if ($null -eq $Descriptor) { return $false }
    try {
        $health = Invoke-AgentSshSessionApi $Descriptor 'GET' '/health' $null 2
        return [bool](Get-ObjectValue $health 'ok' $false)
    } catch { return $false }
}

function Ensure-AgentSshSessionHost {
    $descriptor = Get-AgentSshSessionDescriptor
    if (Test-AgentSshSessionHost $descriptor) { return $descriptor }
    if (-not (Test-Path -LiteralPath $script:AgentSshSessionHostScript -PathType Leaf)) {
        throw "agent-ssh session host is missing: $script:AgentSshSessionHostScript"
    }

    $powerShellExecutable = if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'powershell.exe' }
    if (-not (Test-Path -LiteralPath $powerShellExecutable -PathType Leaf)) { throw 'The active PowerShell executable is unavailable.' }
    if ($script:AgentSshSessionHostScript.Contains('"')) { throw 'The session host path contains an unsupported quote character.' }
    $quotedScript = '"' + $script:AgentSshSessionHostScript + '"'
    Start-Process -FilePath $powerShellExecutable -ArgumentList @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $quotedScript
    ) -WindowStyle Hidden | Out-Null

    foreach ($attempt in 1..60) {
        Start-Sleep -Milliseconds 200
        $descriptor = Get-AgentSshSessionDescriptor
        if (Test-AgentSshSessionHost $descriptor) { return $descriptor }
    }
    throw 'The local SSH session host did not become ready within 12 seconds.'
}

function Invoke-AgentSshSessionRequest {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][object]$Body,
        [ValidateRange(1, 180)][int]$TimeoutSeconds = 15
    )
    $descriptor = Ensure-AgentSshSessionHost
    return Invoke-AgentSshSessionApi $descriptor $Method $Path $Body $TimeoutSeconds
}

function Connect-AgentSshSession {
    param([Parameter(Mandatory)][string]$Alias)
    return Invoke-AgentSshSessionRequest 'POST' '/connect' @{ alias = $Alias } 45
}

function Get-AgentSshSessionStatus {
    param([string]$Alias)
    $path = if ([string]::IsNullOrWhiteSpace($Alias)) { '/status' } else { "/status?alias=$([Uri]::EscapeDataString($Alias))" }
    return Invoke-AgentSshSessionRequest 'GET' $path $null 5
}

function Disconnect-AgentSshSession {
    param([Parameter(Mandatory)][string]$Alias)
    return Invoke-AgentSshSessionRequest 'POST' '/disconnect' @{ alias = $Alias } 10
}

function Disconnect-AgentSshSessionsIfRunning {
    param([string[]]$Aliases)
    $descriptor = Get-AgentSshSessionDescriptor
    if (-not (Test-AgentSshSessionHost $descriptor)) { return }
    try {
        if ($null -eq $Aliases -or $Aliases.Count -eq 0) {
            [void](Invoke-AgentSshSessionApi $descriptor 'POST' '/disconnect-all' @{} 10)
        } else {
            foreach ($alias in @($Aliases | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
                [void](Invoke-AgentSshSessionApi $descriptor 'POST' '/disconnect' @{ alias = $alias } 10)
            }
        }
    } catch {}
}

function Stop-AgentSshSessionHostIfIdle {
    $descriptor = Get-AgentSshSessionDescriptor
    if (-not (Test-AgentSshSessionHost $descriptor)) { return $true }
    try {
        $result = Invoke-AgentSshSessionApi $descriptor 'POST' '/shutdown' @{} 5
        return [bool](Get-ObjectValue $result 'ok' $false)
    } catch { return $false }
}

function Invoke-AgentSshSessionCommand {
    param(
        [Parameter(Mandatory)][string]$Alias,
        [Parameter(Mandatory)][string]$Command,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 120
    )
    if ([string]::IsNullOrWhiteSpace($Command)) { throw 'Remote command cannot be empty.' }
    return Invoke-AgentSshSessionRequest 'POST' '/execute' @{
        alias = $Alias
        command = $Command
        timeoutSeconds = $TimeoutSeconds
    } ([Math]::Min(180, $TimeoutSeconds + 15))
}
