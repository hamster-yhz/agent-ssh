[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Target,

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$RemoteCommand
)

# Compatibility entry point for scripts created before the agent-ssh rename.
$arguments = @()
if ($PSBoundParameters.ContainsKey('Target')) { $arguments += $Target }
if ($null -ne $RemoteCommand) { $arguments += $RemoteCommand }
& (Join-Path $PSScriptRoot 'agent-ssh.ps1') @arguments
exit $LASTEXITCODE
