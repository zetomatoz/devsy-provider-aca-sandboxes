<#
.SYNOPSIS
Run the Devsy ACA quickstart in x64 Ubuntu on WSL 2.

.DESCRIPTION
The Linux quickstart launches a terminal workspace and uses Azure device-code
sign-in when authentication is needed. Keep this checkout in a durable location.

.PARAMETER Distribution
The WSL distribution name shown by wsl --list --verbose. Defaults to Ubuntu.

.PARAMETER Subscription
The Azure subscription ID or name. When omitted, the Azure CLI selects its
active subscription inside WSL.

.PARAMETER InstallWsl
Run Microsoft's WSL installation command if the distribution is missing. This
can require administrator access, a Windows restart, and Ubuntu's first-run setup.
After installing the distribution, rerun this launcher from a regular terminal.

.PARAMETER WithCopilot
Install the optional standalone Copilot CLI inside WSL.

.PARAMETER BrowserLogin
Use Azure CLI's normal login instead of requesting device-code login.

.PARAMETER Help
Show the launcher's parameters without starting WSL.
#>

[CmdletBinding()]
param(
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9._-]*$')]
    [string]$Distribution = 'Ubuntu',

    [ValidateScript({ -not [string]::IsNullOrWhiteSpace($_) -and $_ -notmatch '["\x00-\x1f]' -and $_ -notmatch '^--' })]
    [string]$Subscription,

    [switch]$InstallWsl,
    [switch]$WithCopilot,
    [switch]$BrowserLogin,
    [Alias('h')]
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

if ($Help) {
    Get-Help $PSCommandPath -Detailed
    exit 0
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Run this launcher from PowerShell on Windows. On Linux, run bash scripts/quickstart.sh --headless.'
}
try {
    $windowsArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
} catch {
    $windowsArchitecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
}
if ($windowsArchitecture -notin @('X64', 'AMD64')) {
    throw "This quickstart requires Windows x64. Detected $windowsArchitecture."
}

$checkout = Split-Path -Parent $PSScriptRoot
$shellDirectories = @('scripts', 'devsy_aca', 'examples/dotnet') | ForEach-Object { Join-Path $checkout $_ }
$shellFilesWithCrLf = @(Get-ChildItem -LiteralPath $shellDirectories -Filter '*.sh' -File -Recurse | Where-Object {
    [IO.File]::ReadAllText($_.FullName).Contains("`r`n")
})
if ($shellFilesWithCrLf.Count -gt 0) {
    $files = ($shellFilesWithCrLf.Name -join ', ')
    throw "Bash requires LF line endings. Clone a fresh checkout with git -c core.autocrlf=false clone and retry. Files with CRLF: $files"
}
if (Test-Path -LiteralPath (Join-Path $checkout '.venv/Scripts/python.exe')) {
    throw 'This checkout has a Windows Python virtual environment. Use a separate checkout for the WSL provider.'
}

$systemFolder = if ([Environment]::Is64BitProcess) { 'System32' } else { 'Sysnative' }
$windowsFolder = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
$wsl = Join-Path (Join-Path $windowsFolder $systemFolder) 'wsl.exe'
if (-not (Test-Path -LiteralPath $wsl -PathType Leaf)) {
    throw 'wsl.exe is unavailable. Enable WSL on a supported Windows release. See https://learn.microsoft.com/windows/wsl/install.'
}

function Read-Wsl {
    param([string[]]$WslArguments)

    $ErrorActionPreference = 'Continue'
    $output = & $wsl @WslArguments 2>$null
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Text = (($output -join "`n") -replace "`0", '' -replace [char]0xfeff, '').Trim()
    }
}

function Get-DistributionVersion {
    $listing = Read-Wsl -WslArguments @('--list', '--verbose')
    if ($listing.ExitCode -ne 0) { return $null }

    # Only the name and version matter. The WSL state column can be localized.
    $row = '(?m)^\s*\*?\s*{0}[ \t]+[^\r\n]+?[ \t]+([12])[ \t]*\r?$' -f [regex]::Escape($Distribution)
    if ($listing.Text -match $row) { return [int]$Matches[1] }
    return $null
}

$version = Get-DistributionVersion
if ($null -eq $version) {
    if (-not $InstallWsl) {
        throw "Cannot find the $Distribution WSL distribution. Check wsl --list --verbose or rerun with -InstallWsl. To install manually, run wsl --install -d $Distribution in an administrator PowerShell."
    }

    & $wsl --install -d $Distribution
    if ($LASTEXITCODE -ne 0) {
        throw "WSL installation exited with $LASTEXITCODE. Follow the Windows message above, then rerun the quickstart."
    }

    Write-Host "Restart Windows if prompted. Open $Distribution and finish creating your Linux user. Rerun this script from a regular PowerShell terminal."
    exit 0
}
if ($version -ne 2) {
    throw "This quickstart needs WSL 2. Convert the selected distribution with wsl --set-version $Distribution 2, then rerun."
}

$wslArchitecture = Read-Wsl -WslArguments @('--distribution', $Distribution, '--exec', '/bin/uname', '-m')
if ($wslArchitecture.ExitCode -ne 0) {
    throw "Cannot start $Distribution. Open it with wsl -d $Distribution, finish its first-run setup, and retry."
}
if ($wslArchitecture.Text -notin @('x86_64', 'amd64')) {
    throw "This quickstart requires x64 Ubuntu. WSL reports $($wslArchitecture.Text)."
}
$osRelease = Read-Wsl -WslArguments @('--distribution', $Distribution, '--exec', '/bin/cat', '/etc/os-release')
if ($osRelease.ExitCode -ne 0 -or $osRelease.Text -notmatch '(?m)^ID="?ubuntu"?\r?$') {
    throw "Select an Ubuntu WSL 2 distribution with -Distribution. The current selection is $Distribution."
}

if ($checkout -match '^\\\\(?:wsl\.localhost|wsl\$)\\([^\\]+)\\(.+)$') {
    if ($Matches[1] -ine $Distribution) {
        throw "This checkout belongs to WSL distribution $($Matches[1]). Select it with -Distribution."
    }
    $linuxCheckout = '/' + $Matches[2].Replace('\', '/')
} else {
    $translated = Read-Wsl -WslArguments @('--distribution', $Distribution, '--exec', 'wslpath', '-a', '-u', $checkout)
    if ($translated.ExitCode -ne 0 -or $translated.Text -notmatch '^/[^\r\n]+$') {
        throw 'WSL cannot access this checkout path. Clone the repository inside Ubuntu and run bash scripts/quickstart.sh --headless --device-code.'
    }
    $linuxCheckout = $translated.Text
}

$launch = @('--distribution', $Distribution, '--exec', '/bin/bash', "$linuxCheckout/scripts/quickstart.sh", '--headless')
if (-not $BrowserLogin) { $launch += '--device-code' }
if ($WithCopilot) { $launch += '--with-copilot' }
if ($PSBoundParameters.ContainsKey('Subscription')) { $launch += @('--subscription', $Subscription) }

Write-Host "Starting the terminal workspace in $Distribution on WSL 2."
& $wsl @launch
exit $LASTEXITCODE
