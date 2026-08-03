[CmdletBinding()]
param(
    [string]$OutputPath,
    [string]$Version
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# CodeDOM desktop compilation targets .NET Framework and is unavailable from
# PowerShell 7's .NET runtime. Windows runners still include Windows PowerShell,
# so transparently hand off only the compiler script when invoked from pwsh.
if ($PSVersionTable.PSEdition -eq 'Core') {
    $windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
        throw 'Windows PowerShell 5.1 is required to build the desktop application.'
    }
    $childArguments = @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-File', $PSCommandPath
    )
    if ($PSBoundParameters.ContainsKey('OutputPath')) {
        $childArguments += @('-OutputPath', $OutputPath)
    }
    if ($PSBoundParameters.ContainsKey('Version')) {
        $childArguments += @('-Version', $Version)
    }
    & $windowsPowerShell @childArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Windows PowerShell desktop build failed with exit code $LASTEXITCODE."
    }
    return
}

$packageVersion = '1.0.2592.51'
$root = Split-Path -Parent $PSScriptRoot
$versionPath = Join-Path $root 'VERSION'
if ([string]::IsNullOrWhiteSpace($Version)) {
    if (-not (Test-Path -LiteralPath $versionPath -PathType Leaf)) { throw "Version file is missing: $versionPath" }
    $Version = [IO.File]::ReadAllText($versionPath, [Text.Encoding]::UTF8).Trim()
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Invalid desktop version: $Version" }
$source = Join-Path $root 'src\desktop\AgentSsh.Desktop.cs'
$manifest = Join-Path $root 'src\desktop\app.manifest'
$icon = Join-Path $root 'src\desktop\agent-ssh.ico'
$buildRoot = Join-Path $root 'build'
$cache = Join-Path $buildRoot 'cache\webview2'
$output = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    Join-Path $root 'agent-ssh.exe'
} else {
    [IO.Path]::GetFullPath((Join-Path $root $OutputPath))
}
$temporaryDirectory = Join-Path $buildRoot 'desktop-compile'
$temporary = Join-Path $temporaryDirectory 'agent-ssh.exe'
$temporarySource = Join-Path $temporaryDirectory 'AgentSsh.Desktop.build.cs'
$core = Join-Path $cache 'Microsoft.Web.WebView2.Core.dll'
$winForms = Join-Path $cache 'Microsoft.Web.WebView2.WinForms.dll'
$loaderX64 = Join-Path $cache 'WebView2Loader.x64.dll'
$loaderX86 = Join-Path $cache 'WebView2Loader.x86.dll'

foreach ($requiredSource in @($source, $manifest, $icon)) {
    if (-not (Test-Path -LiteralPath $requiredSource -PathType Leaf)) {
        throw "Desktop build input was not found: $requiredSource"
    }
}

if (-not (Test-Path -LiteralPath $core -PathType Leaf)) {
    New-Item -ItemType Directory -Path $cache -Force | Out-Null
    $package = Join-Path $cache "Microsoft.Web.WebView2.$packageVersion.nupkg"
    $download = "$package.download"
    & curl.exe -L --fail --retry 3 --connect-timeout 15 `
        -o $download "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/$packageVersion"
    if ($LASTEXITCODE -ne 0) { throw 'Could not download the WebView2 build package.' }
    Move-Item -LiteralPath $download -Destination $package -Force
    $zip = Join-Path $cache "Microsoft.Web.WebView2.$packageVersion.zip"
    $expanded = Join-Path $cache 'package'
    Copy-Item -LiteralPath $package -Destination $zip -Force
    Expand-Archive -LiteralPath $zip -DestinationPath $expanded -Force
    Copy-Item -LiteralPath (Join-Path $expanded 'lib\net462\Microsoft.Web.WebView2.Core.dll') -Destination $core
    Copy-Item -LiteralPath (Join-Path $expanded 'lib\net462\Microsoft.Web.WebView2.WinForms.dll') -Destination $winForms
    Copy-Item -LiteralPath (Join-Path $expanded 'build\native\x64\WebView2Loader.dll') -Destination $loaderX64
    Copy-Item -LiteralPath (Join-Path $expanded 'build\native\x86\WebView2Loader.dll') -Destination $loaderX86
}

$dependencies = @($core, $winForms, $loaderX64, $loaderX86)
foreach ($dependency in $dependencies) {
    if (-not (Test-Path -LiteralPath $dependency -PathType Leaf)) {
        throw "WebView2 build dependency is missing: $dependency"
    }
}

New-Item -ItemType Directory -Path $buildRoot, $temporaryDirectory -Force | Out-Null
try {
    if (Test-Path -LiteralPath $temporary) {
        Remove-Item -LiteralPath $temporary -Force
    }
    $sourceText = [IO.File]::ReadAllText($source, [Text.Encoding]::UTF8)
    $assemblyVersion = "$Version.0"
    $sourceText = [regex]::Replace($sourceText, '\[assembly: AssemblyVersion\("[^"]+"\)\]', "[assembly: AssemblyVersion(`"$assemblyVersion`")]")
    $sourceText = [regex]::Replace($sourceText, '\[assembly: AssemblyFileVersion\("[^"]+"\)\]', "[assembly: AssemblyFileVersion(`"$assemblyVersion`")]")
    [IO.File]::WriteAllText($temporarySource, $sourceText, (New-Object Text.UTF8Encoding($false)))
    $resourceOptions = @(
        "/resource:`"$core`",AgentSsh.Resources.WebView2.Core",
        "/resource:`"$winForms`",AgentSsh.Resources.WebView2.WinForms",
        "/resource:`"$loaderX64`",AgentSsh.Resources.WebView2.Loader.x64",
        "/resource:`"$loaderX86`",AgentSsh.Resources.WebView2.Loader.x86"
    )
    $provider = New-Object Microsoft.CSharp.CSharpCodeProvider
    $parameters = New-Object CodeDom.Compiler.CompilerParameters
    $parameters.GenerateExecutable = $true
    $parameters.GenerateInMemory = $false
    $parameters.OutputAssembly = $temporary
    $parameters.CompilerOptions = "/target:winexe /optimize+ /win32icon:`"$icon`" /win32manifest:`"$manifest`" " + ($resourceOptions -join ' ')
    @('System.dll', 'System.Core.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll', $core, $winForms) |
        ForEach-Object { [void]$parameters.ReferencedAssemblies.Add($_) }
    $result = $provider.CompileAssemblyFromFile($parameters, $temporarySource)
    $provider.Dispose()
    if ($result.Errors.HasErrors) {
        $messages = @($result.Errors | ForEach-Object { "$($_.FileName):$($_.Line): $($_.ErrorText)" })
        throw "Desktop application compilation failed:`n$($messages -join "`n")"
    }
    Move-Item -LiteralPath $temporary -Destination $output -Force
    Write-Host "Built desktop app: $output" -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $temporary) {
        Remove-Item -LiteralPath $temporary -Force
    }
    if (Test-Path -LiteralPath $temporarySource) {
        Remove-Item -LiteralPath $temporarySource -Force
    }
}
