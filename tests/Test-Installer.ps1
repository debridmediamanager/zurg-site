# Regression tests for public/install.ps1.
#
# A user reported the one-line installer dying immediately on 2026-09-11:
#
#   iex : The property 'OSArchitecture' cannot be found on this object.
#
# Get-PlatformArchitecture read [System.Runtime.InteropServices.RuntimeInformation]
# and nothing else. PSReadLine carries its own copy of that class with no
# OSArchitecture property, and once PSReadLine is loaded any script parsed
# afterwards resolves the bare type name to PSReadLine's copy. Every
# interactive console has PSReadLine loaded, so the installer died on the
# second statement it ran, while the same file run with -File from a
# non-interactive shell on the same machine was fine.
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

function Test-Command([string]$Name, [string]$Command, [string]$Expected) {
    $output = Invoke-Host "-NoProfile -Command `"$Command`"" @{ ZURG_INSTALL_DRY_RUN = '1' }
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

# The reported command was a pipeline into iex, not a file invocation, and the
# two differ: iex runs in the caller's scope, where $args and $PSScriptRoot
# belong to the console rather than to the script.
Test-Command 'the irm | iex pipeline runs' `
    "Get-Content -Raw '$installer' | Invoke-Expression" `
    'Platform: windows-'

# This is the reported failure itself. An interactive console always has
# PSReadLine loaded before anything is typed into it, so the installer is
# always parsed after it. Drop the Import-Module and the same command passes,
# which is why a -File run reproduces nothing.
Test-Command 'runs with PSReadLine already loaded' `
    "Import-Module PSReadLine; Get-Content -Raw '$installer' | Invoke-Expression" `
    'Platform: windows-'

Test-Command 'runs with PSReadLine loaded and invoked as a file' `
    "Import-Module PSReadLine; & '$installer'" `
    'Platform: windows-' 

# Card 170, reproduced on Windows 2026-10-03: the installer downloaded gh.exe
# into its temporary directory to sign the user in, and its finally block
# deleted that directory. zurg update signs in through the same gh, so straight
# after a normal install it stopped with "no GitHub credential found" while the
# sign-in itself was still saved.
#
# These load the installer's functions without running it, answer its GitHub
# calls with the GitHub CLI release recorded on 2026-10-03, and check where the
# gh.exe it returns lives once the temporary directory is gone.
$definitions = Get-Content -Raw $installer
$definitions = $definitions.Substring(0, $definitions.IndexOf("`ntry {"))
$ghRelease = Join-Path $PSScriptRoot 'fixtures/installer/gh-latest-release.json'

function Test-GitHubCli([string]$Name, [scriptblock]$Arrange, [scriptblock]$Assert) {
    $work = Join-Path ([IO.Path]::GetTempPath()) ("zurg-installer-test-" + [guid]::NewGuid().ToString("N"))
    $savedPath = $env:PATH
    try {
        $outcome = & {
            . ([scriptblock]::Create($definitions))
            $InstallDir = Join-Path $work 'zurg'
            $TempDir = Join-Path $work 'tmp'
            New-Item -ItemType Directory -Force -Path $TempDir | Out-Null
            $downloads = New-Object System.Collections.ArrayList
            function Invoke-RestMethod { param($Headers, $Uri) Get-Content -Raw $ghRelease | ConvertFrom-Json }
            function Invoke-WebRequest {
                param($Headers, $Uri, $OutFile)
                [void]$downloads.Add($Uri)
                $source = Join-Path $work 'gh-archive'
                New-Item -ItemType Directory -Force -Path (Join-Path $source 'bin') | Out-Null
                Set-Content -Path (Join-Path $source 'bin/gh.exe') -Value 'stand-in'
                Compress-Archive -Path (Join-Path $source '*') -DestinationPath $OutFile -Force
            }
            # No gh on PATH, the way a machine without the GitHub CLI looks.
            $env:PATH = ($env:PATH -split ';' | Where-Object { $_ -and -not (Test-Path (Join-Path $_ 'gh.exe')) }) -join ';'
            & $Arrange
            $gh = Get-GitHubCli
            # What the installer's finally block does on the way out.
            Remove-Item -Path $TempDir -Recurse -Force
            @{ Gh = $gh; InstallDir = $InstallDir; Downloads = @($downloads) }
        }
        $problem = & $Assert $outcome
    }
    catch { $problem = "threw: $_" }
    finally {
        $env:PATH = $savedPath
        Remove-Item -Path $work -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($problem) {
        Write-Host "FAIL  $Name"
        Write-Host "      $problem"
        $script:failures++
    }
    else { Write-Host "PASS  $Name" }
}

Test-GitHubCli 'the GitHub CLI it downloads is kept beside zurg' {} {
    param($o)
    $kept = Join-Path $o.InstallDir 'bin\gh.exe'
    if ($o.Gh -ne $kept) { return "returned $($o.Gh), expected $kept" }
    if (-not (Test-Path $o.Gh)) { return "$($o.Gh) is gone once the installer exits" }
    $want = 'https://github.com/cli/cli/releases/download/v2.102.0/gh_2.102.0_windows_amd64.zip'
    if ($o.Downloads -notcontains $want) { return "downloaded $($o.Downloads -join ', '), expected $want" }
}

Test-GitHubCli 'a GitHub CLI kept by an earlier run is used, not downloaded again' {
    New-Item -ItemType Directory -Force -Path (Join-Path $InstallDir 'bin') | Out-Null
    Set-Content -Path (Join-Path $InstallDir 'bin\gh.exe') -Value 'kept'
} {
    param($o)
    $kept = Join-Path $o.InstallDir 'bin\gh.exe'
    if ($o.Gh -ne $kept) { return "returned $($o.Gh), expected $kept" }
    if ($o.Downloads.Count -gt 0) { return "downloaded $($o.Downloads -join ', ') again" }
}

Test-GitHubCli 'a GitHub CLI already installed is used and no copy is kept' {
    $onPath = Join-Path $work 'installed-gh'
    New-Item -ItemType Directory -Force -Path $onPath | Out-Null
    Copy-Item -Path (Join-Path $env:SystemRoot 'System32\whoami.exe') -Destination (Join-Path $onPath 'gh.exe')
    $env:PATH = "$onPath;$env:PATH"
} {
    param($o)
    if ($o.Gh -notlike '*installed-gh*') { return "returned $($o.Gh), expected the gh.exe on PATH" }
    if (Test-Path (Join-Path $o.InstallDir 'bin\gh.exe')) { return "kept a copy of a GitHub CLI that was already installed" }
    if ($o.Downloads.Count -gt 0) { return "downloaded $($o.Downloads -join ', ')" }
}

Write-Host ""
if ($failures -gt 0) { Write-Host "$failures failed"; exit 1 }
Write-Host "all passed"
