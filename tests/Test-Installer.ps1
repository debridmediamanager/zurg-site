# Regression tests for public/install.ps1 platform detection.
#
# A user reported the one-line installer dying immediately on 2026-09-11:
#
#   iex : The property 'OSArchitecture' cannot be found on this object.
#
# Get-PlatformArchitecture read [System.Runtime.InteropServices.RuntimeInformation]
# and nothing else. PSReadLine and other modules ship their own copy of that
# class, and on a Windows whose mscorlib carries no copy of its own the bare
# type name resolves to theirs, which has no OSArchitecture property. One
# missing property took the whole installer down on its second statement.
#
# These drive the real script through its dry run, which prints the platform and
# stops before it touches WinFsp, GitHub or a release. Run under both hosts:
#
#   powershell -NoProfile -File tests\Test-Installer.ps1
#   pwsh       -NoProfile -File tests\Test-Installer.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$installer = Join-Path (Split-Path -Parent $PSScriptRoot) 'public/install.ps1'
$host_exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$failures = 0

function Invoke-Host([string]$Arguments, [hashtable]$Environment) {
    # The child's environment is built here rather than inherited from this
    # process. PowerShell 7 does not pass an architecture written with
    # [Environment]::SetEnvironmentVariable on to a native child, so inheriting
    # would quietly test the runner's own architecture six times over.
    #
    # Arguments is one string, not a list: .NET Framework has no ArgumentList
    # and Windows PowerShell would fail on it.
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $host_exe
    $start.Arguments = $Arguments
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($name in $Environment.Keys) {
        [void]$start.Environment.Remove($name)
        if ($null -ne $Environment[$name]) { $start.Environment[$name] = $Environment[$name] }
    }
    $process = [Diagnostics.Process]::Start($start)
    $output = $process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return $output.Trim()
}

function Test-Case([string]$Name, [hashtable]$Environment, [string]$Expected) {
    $Environment['ZURG_INSTALL_DRY_RUN'] = '1'
    # -File, so $args is empty exactly as it is under `irm ... | iex`.
    $output = Invoke-Host "-NoProfile -File `"$installer`"" $Environment
    if ($output -match [regex]::Escape($Expected)) {
        Write-Host "PASS  $Name"
    }
    else {
        Write-Host "FAIL  $Name"
        Write-Host "      expected to find: $Expected"
        foreach ($line in ($output -split "`r?`n")) { Write-Host "      | $line" }
        $script:failures++
    }
}

Write-Host "host      : $host_exe"
Write-Host "installer : $installer"
Write-Host ""

# The machine under test is x64, so this is the answer a working installer
# gives, and it is the case that failed outright for the reporter.
Test-Case 'reports a platform at all' @{} 'Platform: windows-'

Test-Case 'x64 Windows' @{
    PROCESSOR_ARCHITECTURE = 'AMD64'; PROCESSOR_ARCHITEW6432 = $null
} 'Platform: windows-amd64'

Test-Case '32-bit Windows' @{
    PROCESSOR_ARCHITECTURE = 'x86'; PROCESSOR_ARCHITEW6432 = $null
} 'Platform: windows-386'

# 32-bit PowerShell on 64-bit Windows: the process says x86 and only
# PROCESSOR_ARCHITEW6432 carries the real architecture of the OS.
Test-Case 'WOW64 reports the OS, not the process' @{
    PROCESSOR_ARCHITECTURE = 'x86'; PROCESSOR_ARCHITEW6432 = 'AMD64'
} 'Platform: windows-amd64'

Test-Case 'Windows on ARM takes the x64 binary' @{
    PROCESSOR_ARCHITECTURE = 'ARM64'; PROCESSOR_ARCHITEW6432 = $null
} 'Platform: windows-amd64'

Test-Case 'Windows on ARM says it is emulated' @{
    PROCESSOR_ARCHITECTURE = 'ARM64'; PROCESSOR_ARCHITEW6432 = $null
} 'Windows on ARM will use'

Test-Case 'an architecture with no build is named' @{
    PROCESSOR_ARCHITECTURE = 'IA64'; PROCESSOR_ARCHITEW6432 = $null
} 'No zurg Windows binary is published for IA64'

# With no architecture in the environment at all the .NET class still answers,
# which is the path a shadowed RuntimeInformation used to break.
Test-Case 'falls back to .NET when the environment says nothing' @{
    PROCESSOR_ARCHITECTURE = $null; PROCESSOR_ARCHITEW6432 = $null
} 'Platform: windows-amd64'

# The reported command was a pipeline into iex, not a file invocation, and the
# two differ: iex runs in the caller's scope, where $args and $PSScriptRoot
# belong to the console rather than to the script.
$piped = Invoke-Host "-NoProfile -Command `"Get-Content -Raw '$installer' | Invoke-Expression`"" @{ ZURG_INSTALL_DRY_RUN = '1' }
if ($piped -match 'Platform: windows-') {
    Write-Host "PASS  the irm | iex pipeline runs"
}
else {
    Write-Host "FAIL  the irm | iex pipeline runs"
    foreach ($line in ($piped -split "`r?`n")) { Write-Host "      | $line" }
    $failures++
}

Write-Host ""
if ($failures -gt 0) { Write-Host "$failures failed"; exit 1 }
Write-Host "all passed"
