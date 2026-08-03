[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)][int]$Port = 8810,
    [ValidateRange(60, 86400)][int]$IdleTimeoutSeconds = 600,
    [ValidateRange(300, 86400)][int]$HostShutdownSeconds = 1800
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $Root 'agent-ssh.ps1')

$script:Sessions = @{}
$script:LastHostActivityUtc = [DateTime]::UtcNow
$script:ShutdownRequested = $false
$script:SessionFingerprintKey = New-Object byte[] 32
$fingerprintRng = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $fingerprintRng.GetBytes($script:SessionFingerprintKey) } finally { $fingerprintRng.Dispose() }
$descriptorPath = Join-Path $Root 'data\session-host.json'

function New-SessionToken {
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-SessionSettings {
    param([Parameter(Mandatory)][string]$Alias)
    $config = Read-AgentSshConfig
    return Get-ServerSettings $config (Get-ServerEntry $config $Alias)
}

function Get-SettingsFingerprint {
    param([Parameter(Mandatory)][object]$Settings)
    $material = @(
        $Settings.Alias, $Settings.Host, $Settings.Port, $Settings.User, $Settings.IdentityFile,
        $Settings.Password, $Settings.ConnectTimeout, $Settings.AliveInterval, $Settings.StrictHostKeyChecking
    ) -join "`0"
    $hmac = New-Object -TypeName Security.Cryptography.HMACSHA256 -ArgumentList (,$script:SessionFingerprintKey)
    try { return [Convert]::ToBase64String($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($material))) } finally { $hmac.Dispose() }
}

function ConvertTo-ProcessArgument {
    param([AllowEmptyString()][Parameter(Mandatory)][string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Get-SessionErrorText {
    param([Parameter(Mandatory)][object]$Session)
    try {
        if ($null -ne $Session.ErrorTask -and $Session.ErrorTask.IsCompleted) {
            return ([string]$Session.ErrorTask.Result).Trim()
        }
    } catch {}
    return ''
}

function Stop-SessionObject {
    param([Parameter(Mandatory)][object]$Session)
    try { $Session.Process.StandardInput.WriteLine('exit') } catch {}
    try { $Session.Process.StandardInput.Close() } catch {}
    try {
        if (-not $Session.Process.HasExited -and -not $Session.Process.WaitForExit(1000)) { $Session.Process.Kill() }
    } catch {}
    try { $Session.Process.Dispose() } catch {}
}

function Remove-PersistentSession {
    param([Parameter(Mandatory)][string]$Alias)
    if ($script:Sessions.ContainsKey($Alias)) {
        $session = $script:Sessions[$Alias]
        $script:Sessions.Remove($Alias)
        Stop-SessionObject $session
    }
}

function Read-SessionLine {
    param(
        [Parameter(Mandatory)][object]$Session,
        [Parameter(Mandatory)][Diagnostics.Stopwatch]$Stopwatch,
        [Parameter(Mandatory)][int]$TimeoutMilliseconds
    )
    $remaining = $TimeoutMilliseconds - [int]$Stopwatch.ElapsedMilliseconds
    if ($remaining -le 0) { throw 'Remote command timed out.' }
    try {
        $readTask = $Session.Process.StandardOutput.ReadLineAsync()
        if (-not $readTask.Wait($remaining)) { throw 'Remote command timed out.' }
        $line = $readTask.Result
    } catch {
        if ($_.Exception.Message -match 'timed out') { throw }
        $errorText = Get-SessionErrorText $Session
        if ($errorText) { throw $errorText }
        throw 'The reusable SSH connection closed unexpectedly.'
    }
    if ($null -eq $line) {
        $errorText = Get-SessionErrorText $Session
        if ($errorText) { throw $errorText }
        throw 'The reusable SSH connection closed unexpectedly.'
    }
    return [string]$line
}

function Start-PersistentSession {
    param([Parameter(Mandatory)][object]$Settings)
    if ([string]::IsNullOrEmpty($Settings.Password) -and [string]::IsNullOrEmpty($Settings.IdentityFile)) {
        throw 'Reusable sessions require saved password or key authentication. Use the interactive terminal for manual authentication.'
    }

    $runtime = Assert-OpenSshAvailable
    if (-not [string]::IsNullOrEmpty($Settings.Password)) { Ensure-AskPassExecutable }
    $batchMode = [string]::IsNullOrEmpty($Settings.Password)
    $sshArguments = @(New-SshArguments $Settings @('sh', '-s') -BatchMode:$batchMode)
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $runtime.SshPath
    $info.Arguments = (($sshArguments | ForEach-Object { ConvertTo-ProcessArgument ([string]$_) }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    if (-not [string]::IsNullOrEmpty($Settings.Password)) {
        $info.EnvironmentVariables['SSH_ASKPASS'] = $AskPassExePath
        $info.EnvironmentVariables['SSH_ASKPASS_REQUIRE'] = 'force'
        $info.EnvironmentVariables['DISPLAY'] = 'agent-ssh'
        $info.EnvironmentVariables['AGENT_SSH_PASSWORD'] = $Settings.Password
    }

    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    if (-not $process.Start()) { throw 'Failed to start the bundled OpenSSH client.' }
    $process.StandardInput.AutoFlush = $true
    $session = [pscustomobject]@{
        Alias = $Settings.Alias
        Process = $process
        ErrorTask = $process.StandardError.ReadToEndAsync()
        Fingerprint = Get-SettingsFingerprint $Settings
        ConnectedAtUtc = [DateTime]::UtcNow
        LastUsedUtc = [DateTime]::UtcNow
        Busy = $false
    }
    try {
        $readyMarker = "__AGENT_SSH_READY_$([Guid]::NewGuid().ToString('N'))__"
        $process.StandardInput.WriteLine("printf '%s\n' '$readyMarker'")
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $timeout = ([int]$Settings.ConnectTimeout + 15) * 1000
        while ($true) {
            $line = Read-SessionLine $session $watch $timeout
            if ($line -ceq $readyMarker) { break }
        }
        $script:Sessions[$Settings.Alias] = $session
        return $session
    } catch {
        Stop-SessionObject $session
        throw
    }
}

function Get-PersistentSession {
    param([Parameter(Mandatory)][object]$Settings, [switch]$Create)
    if ($script:Sessions.ContainsKey($Settings.Alias)) {
        $session = $script:Sessions[$Settings.Alias]
        if ($session.Process.HasExited -or $session.Fingerprint -cne (Get-SettingsFingerprint $Settings)) {
            Remove-PersistentSession $Settings.Alias
        } else {
            return $session
        }
    }
    if ($Create) { return Start-PersistentSession $Settings }
    return $null
}

function Get-PersistentSessionStatus {
    param([Parameter(Mandatory)][string]$Alias, [AllowNull()][object]$Session)
    if ($null -eq $Session) {
        return [ordered]@{ alias = $Alias; state = 'disconnected'; idleSeconds = 0; idleTimeoutSeconds = $IdleTimeoutSeconds; busy = $false }
    }
    $idleSeconds = [Math]::Max(0, [int]([DateTime]::UtcNow - $Session.LastUsedUtc).TotalSeconds)
    return [ordered]@{
        alias = $Alias
        state = if ($Session.Busy) { 'busy' } else { 'connected' }
        connectedAt = $Session.ConnectedAtUtc.ToString('o')
        lastUsedAt = $Session.LastUsedUtc.ToString('o')
        idleSeconds = $idleSeconds
        idleTimeoutSeconds = $IdleTimeoutSeconds
        busy = [bool]$Session.Busy
    }
}

function Connect-PersistentSession {
    param([Parameter(Mandatory)][string]$Alias)
    $settings = Get-SessionSettings $Alias
    $session = Get-PersistentSession $settings -Create
    $session.LastUsedUtc = [DateTime]::UtcNow
    return Get-PersistentSessionStatus $settings.Alias $session
}

function Invoke-PersistentCommand {
    param(
        [Parameter(Mandatory)][string]$Alias,
        [Parameter(Mandatory)][string]$Command,
        [ValidateRange(1, 120)][int]$TimeoutSeconds
    )
    if ([string]::IsNullOrWhiteSpace($Command)) { throw 'Remote command cannot be empty.' }
    $settings = Get-SessionSettings $Alias
    $session = Get-PersistentSession $settings -Create
    if ($session.Busy) { throw "Server '$Alias' already has a command in progress." }
    $session.Busy = $true
    $session.LastUsedUtc = [DateTime]::UtcNow
    try {
        $id = [Guid]::NewGuid().ToString('N')
        $delimiter = "__AGENT_SSH_COMMAND_${id}__"
        while ($Command.Contains($delimiter)) { $id = [Guid]::NewGuid().ToString('N'); $delimiter = "__AGENT_SSH_COMMAND_${id}__" }
        $beginMarker = "__AGENT_SSH_BEGIN_${id}__"
        $endMarker = "__AGENT_SSH_END_${id}__"
        $payload = @(
            "printf '%s\n' '$beginMarker'",
            'set +e',
            "eval `"`$(cat <<'$delimiter'",
            $Command,
            $delimiter,
            ')" 2>&1',
            '__agent_ssh_code=$?',
            "printf '\n%s:%s\n' '$endMarker' `"`$__agent_ssh_code`""
        ) -join "`n"
        $session.Process.StandardInput.WriteLine($payload)

        $watch = [Diagnostics.Stopwatch]::StartNew()
        $timeoutMilliseconds = $TimeoutSeconds * 1000
        while ((Read-SessionLine $session $watch $timeoutMilliseconds) -cne $beginMarker) {}
        $lines = New-Object Collections.Generic.List[string]
        $outputLength = 0
        $truncated = $false
        $exitCode = 1
        while ($true) {
            $line = Read-SessionLine $session $watch $timeoutMilliseconds
            $match = [regex]::Match($line, "^$([regex]::Escape($endMarker)):(?<code>\d+)$")
            if ($match.Success) { $exitCode = [int]$match.Groups['code'].Value; break }
            if (-not $truncated) {
                $outputLength += $line.Length + 1
                if ($outputLength -le 524288) { $lines.Add($line) } else { $truncated = $true }
            }
        }
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
        $output = $lines -join "`n"
        if ($truncated) { $output += "`n[output truncated]" }
        return [ordered]@{ alias = $settings.Alias; exitCode = $exitCode; output = $output; reused = $true }
    } catch {
        Remove-PersistentSession $settings.Alias
        throw
    } finally {
        if ($script:Sessions.ContainsKey($settings.Alias)) {
            $script:Sessions[$settings.Alias].Busy = $false
            $script:Sessions[$settings.Alias].LastUsedUtc = [DateTime]::UtcNow
        }
    }
}

function Remove-IdleSessions {
    $now = [DateTime]::UtcNow
    foreach ($alias in @($script:Sessions.Keys)) {
        $session = $script:Sessions[$alias]
        if ($session.Process.HasExited -or (-not $session.Busy -and ($now - $session.LastUsedUtc).TotalSeconds -ge $IdleTimeoutSeconds)) {
            Remove-PersistentSession $alias
        }
    }
}

function Send-SessionJson {
    param([Parameter(Mandatory)][Net.HttpListenerContext]$Context, [AllowNull()][object]$Data, [int]$StatusCode = 200)
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Data | ConvertTo-Json -Depth 10 -Compress))
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = 'application/json; charset=utf-8'
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.Headers['Cache-Control'] = 'no-store'
    try { $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length) } finally { $Context.Response.Close() }
}

function Read-SessionRequestJson {
    param([Parameter(Mandatory)][Net.HttpListenerRequest]$Request)
    if ($Request.ContentLength64 -gt 1048576) { throw 'Session request is larger than 1 MB.' }
    $reader = New-Object IO.StreamReader($Request.InputStream, [Text.Encoding]::UTF8)
    try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
    if ([string]::IsNullOrWhiteSpace($text)) { return [pscustomobject]@{} }
    return $text | ConvertFrom-Json
}

$rootBytes = [Text.Encoding]::UTF8.GetBytes(([IO.Path]::GetFullPath($Root)).ToLowerInvariant())
$sha256 = [Security.Cryptography.SHA256]::Create()
try { $rootHash = ([BitConverter]::ToString($sha256.ComputeHash($rootBytes))).Replace('-', '').Substring(0, 20) } finally { $sha256.Dispose() }
$createdNew = $false
$hostMutex = New-Object Threading.Mutex($true, "Local\AgentSshSessionHost_$rootHash", [ref]$createdNew)
if (-not $createdNew) { $hostMutex.Dispose(); exit 0 }

$apiToken = New-SessionToken
$listener = $null
$selectedPort = $Port
while ($selectedPort -le [Math]::Min(65535, $Port + 20)) {
    $candidateListener = New-Object Net.HttpListener
    $candidateListener.Prefixes.Add("http://127.0.0.1:$selectedPort/")
    try {
        $candidateListener.Start()
        $listener = $candidateListener
        break
    } catch {
        try { $candidateListener.Close() } catch {}
        $selectedPort++
    }
}
if ($null -eq $listener -or -not $listener.IsListening) { $hostMutex.ReleaseMutex(); $hostMutex.Dispose(); throw 'Could not start the local SSH session host.' }

New-Item -ItemType Directory -Path (Split-Path -Parent $descriptorPath) -Force | Out-Null
$descriptor = [ordered]@{ pid = $PID; port = $selectedPort; token = $apiToken; root = [IO.Path]::GetFullPath($Root); startedAt = [DateTime]::UtcNow.ToString('o') }
[IO.File]::WriteAllText($descriptorPath, ($descriptor | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))

try {
    :hostLoop while ($listener.IsListening) {
        $contextTask = $listener.GetContextAsync()
        while (-not $contextTask.Wait(1000)) {
            Remove-IdleSessions
            if ($script:Sessions.Count -eq 0 -and ([DateTime]::UtcNow - $script:LastHostActivityUtc).TotalSeconds -ge $HostShutdownSeconds) {
                $listener.Stop()
                break hostLoop
            }
        }
        if (-not $listener.IsListening) { break }
        $context = $contextTask.Result
        $script:LastHostActivityUtc = [DateTime]::UtcNow
        try {
            $request = $context.Request
            if ($request.Headers['X-Agent-Ssh-Session-Token'] -cne $apiToken) { Send-SessionJson $context @{ error = 'Unauthorized.' } 403; continue }
            $path = $request.Url.AbsolutePath
            switch ("$($request.HttpMethod) $path") {
                'GET /health' { Send-SessionJson $context @{ ok = $true; pid = $PID; idleTimeoutSeconds = $IdleTimeoutSeconds } }
                'GET /status' {
                    Remove-IdleSessions
                    $alias = [string]$request.QueryString['alias']
                    if ($alias) {
                        $settings = Get-SessionSettings $alias
                        $session = Get-PersistentSession $settings
                        Send-SessionJson $context @{ sessions = @((Get-PersistentSessionStatus $settings.Alias $session)) }
                    } else {
                        $statuses = foreach ($key in @($script:Sessions.Keys)) { Get-PersistentSessionStatus $key $script:Sessions[$key] }
                        Send-SessionJson $context @{ sessions = @($statuses) }
                    }
                }
                'POST /connect' {
                    $body = Read-SessionRequestJson $request
                    Send-SessionJson $context (Connect-PersistentSession ([string](Get-ObjectValue $body 'alias' '')))
                }
                'POST /execute' {
                    $body = Read-SessionRequestJson $request
                    $timeout = [int](Get-ObjectValue $body 'timeoutSeconds' 120)
                    if ($timeout -lt 1 -or $timeout -gt 120) { throw 'Command timeout must be between 1 and 120 seconds.' }
                    Send-SessionJson $context (Invoke-PersistentCommand ([string](Get-ObjectValue $body 'alias' '')) ([string](Get-ObjectValue $body 'command' '')) $timeout)
                }
                'POST /disconnect' {
                    $body = Read-SessionRequestJson $request
                    $alias = [string](Get-ObjectValue $body 'alias' '')
                    if (-not (Test-ServerAlias $alias)) { throw 'Enter a valid server alias.' }
                    Remove-PersistentSession $alias
                    Send-SessionJson $context (Get-PersistentSessionStatus $alias $null)
                }
                'POST /disconnect-all' {
                    foreach ($key in @($script:Sessions.Keys)) { Remove-PersistentSession $key }
                    Send-SessionJson $context @{ ok = $true; sessions = @() }
                }
                'POST /shutdown' {
                    if ($script:Sessions.Count -gt 0) { throw 'Cannot stop the session host while SSH sessions are active.' }
                    Send-SessionJson $context @{ ok = $true; shuttingDown = $true }
                    $script:ShutdownRequested = $true
                }
                default { Send-SessionJson $context @{ error = 'Session route not found.' } 404 }
            }
        } catch {
            try { Send-SessionJson $context @{ error = $_.Exception.Message } 400 } catch { try { $context.Response.Abort() } catch {} }
        }
        if ($script:ShutdownRequested) { $listener.Stop(); break }
    }
} finally {
    foreach ($alias in @($script:Sessions.Keys)) { Remove-PersistentSession $alias }
    try { $listener.Stop() } catch {}
    try { $listener.Close() } catch {}
    try {
        if (Test-Path -LiteralPath $descriptorPath -PathType Leaf) {
            $current = [IO.File]::ReadAllText($descriptorPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ([int](Get-ObjectValue $current 'pid' 0) -eq $PID) { [IO.File]::Delete($descriptorPath) }
        }
    } catch {}
    try { $hostMutex.ReleaseMutex() } catch {}
    $hostMutex.Dispose()
}
