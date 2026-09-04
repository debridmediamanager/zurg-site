$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
Set-StrictMode -Version Latest

$ZurgRepo = if ($env:ZURG_REPO) { $env:ZURG_REPO } else { "debridmediamanager/zurg" }
$InstallDir = if ($env:ZURG_INSTALL_DIR) { $env:ZURG_INSTALL_DIR } else { Join-Path $HOME "zurg" }
$DryRun = $env:ZURG_INSTALL_DRY_RUN -eq "1"
$TempDir = $null
$Gh = $null
$RebootRequired = $false

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Get-PlatformArchitecture {
    $machine = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    switch ($machine) {
        "X86" { return "386" }
        "X64" { return "amd64" }
        "Arm64" {
            Write-Host "Windows on ARM will use zurg's x64 binary through Windows emulation."
            return "amd64"
        }
        default { throw "No zurg Windows binary is published for $machine." }
    }
}

function Install-WinFsp {
    $candidatePaths = @()
    if ($env:ProgramFiles) { $candidatePaths += Join-Path $env:ProgramFiles "WinFsp\bin\winfsp-x64.dll" }
    $programFilesX86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
    if ($programFilesX86) { $candidatePaths += Join-Path $programFilesX86 "WinFsp\bin\winfsp-x86.dll" }
    $installed = @($candidatePaths | Where-Object { Test-Path $_ })
    if ($installed.Count -gt 0) { return }

    Write-Step "Installing WinFsp"
    $release = Invoke-RestMethod -Headers @{ "User-Agent" = "zurg-installer" } -Uri "https://api.github.com/repos/winfsp/winfsp/releases/latest"
    $asset = $release.assets | Where-Object { $_.name -match '^winfsp-[0-9.]+\.msi$' } | Select-Object -First 1
    if (-not $asset) { throw "The latest WinFsp release has no MSI installer." }
    $msi = Join-Path $TempDir "winfsp.msi"
    Invoke-WebRequest -Headers @{ "User-Agent" = "zurg-installer" } -Uri $asset.browser_download_url -OutFile $msi
    $process = Start-Process msiexec.exe -Verb RunAs -Wait -PassThru -ArgumentList @("/i", $msi, "/qn", "/norestart")
    if ($process.ExitCode -notin @(0, 3010)) { throw "WinFsp installation failed with exit code $($process.ExitCode)." }
    if ($process.ExitCode -eq 3010) { $script:RebootRequired = $true }
}

function Get-GitHubCli {
    $command = Get-Command gh -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    Write-Step "Downloading a temporary GitHub CLI"
    $release = Invoke-RestMethod -Headers @{ "User-Agent" = "zurg-installer" } -Uri "https://api.github.com/repos/cli/cli/releases/latest"
    $asset = $release.assets | Where-Object { $_.name -match '_windows_amd64\.zip$' } | Select-Object -First 1
    if (-not $asset) { throw "The latest GitHub CLI release has no Windows x64 archive." }
    $archive = Join-Path $TempDir "gh.zip"
    $destination = Join-Path $TempDir "gh"
    Invoke-WebRequest -Headers @{ "User-Agent" = "zurg-installer" } -Uri $asset.browser_download_url -OutFile $archive
    Expand-Archive -Path $archive -DestinationPath $destination -Force
    $binary = Get-ChildItem -Path $destination -Filter gh.exe -Recurse | Select-Object -First 1
    if (-not $binary) { throw "The downloaded GitHub CLI archive did not contain gh.exe." }
    return $binary.FullName
}

function Connect-GitHub {
    $savedErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "SilentlyContinue"
        & $Gh auth status --hostname github.com *> $null
        $authStatus = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    if ($authStatus -ne 0) {
        Write-Step "Sign in to GitHub with the account that has zurg access"
        & $Gh auth login --hostname github.com --git-protocol https --web
        if ($LASTEXITCODE -ne 0) { throw "GitHub sign-in failed." }
    }
    try {
        $ErrorActionPreference = "SilentlyContinue"
        & $Gh api "repos/$ZurgRepo" *> $null
        $repoStatus = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    if ($repoStatus -ne 0) { throw "This GitHub account cannot access $ZurgRepo. Check your sponsorship access and try again." }
}

function Get-ZurgRelease([string]$Architecture) {
    $releases = & $Gh api "repos/$ZurgRepo/releases?per_page=30" | ConvertFrom-Json
    $release = $releases | Where-Object { $_.prerelease -and -not $_.draft } | Select-Object -First 1
    if (-not $release) { throw "No sponsor nightly release was found." }
    $details = & $Gh api "repos/$ZurgRepo/releases/tags/$($release.tag_name)" | ConvertFrom-Json
    $suffix = "-windows-$Architecture.zip"
    $asset = $details.assets | Where-Object { $_.name.EndsWith($suffix) } | Select-Object -First 1
    if (-not $asset) { throw "Release $($release.tag_name) has no windows-$Architecture binary." }
    # The release tag is stamped minutes after the build starts, so it never equals
    # the version compiled into the binary. The asset name does, so compare on that.
    $version = $asset.name -replace '^zurg-', '' -replace "-windows-$Architecture\.zip$", ''
    return @{ Tag = $release.tag_name; Asset = $asset.name; Version = $version }
}

function Get-InstalledZurgVersion([string]$Binary) {
    try {
        $output = & $Binary version 2>&1 | Out-String
    }
    catch { return $null }
    if ($LASTEXITCODE -ne 0) { return $null }
    $match = [regex]::Match($output, '(?m)^Version:\s*(\S+)')
    if ($match.Success) { return $match.Groups[1].Value }
    return $null
}

function Install-Zurg([string]$Architecture) {
    $binary = Join-Path $InstallDir "zurg.exe"
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $release = Get-ZurgRelease $Architecture

    if (Test-Path $binary) {
        $installed = Get-InstalledZurgVersion $binary
        if (-not $installed) {
            Write-Step "Keeping the zurg binary in ${InstallDir}: its version could not be read"
            return $binary
        }
        if ($installed -notlike "*-nightly") {
            Write-Step "Keeping zurg $installed in ${InstallDir}: not a nightly build"
            return $binary
        }
        if ($installed -eq $release.Version) {
            Write-Step "zurg $installed is already the newest nightly"
            return $binary
        }
        # nightly versions are YYYY.MM.DD.HHMM stamps, so they order ordinally
        if ([string]::Compare($installed, $release.Version, [StringComparison]::Ordinal) -gt 0) {
            Write-Step "Keeping zurg $installed in ${InstallDir}: newer than the published $($release.Version)"
            return $binary
        }
        Write-Step "Updating zurg $installed to $($release.Version)"
    }

    Write-Step "Downloading zurg $($release.Version) for windows-$Architecture"
    $download = Join-Path $TempDir "zurg"
    $extracted = Join-Path $TempDir "zurg-extracted"
    New-Item -ItemType Directory -Force -Path $download | Out-Null
    # No --clobber: $download is freshly made each run, and the flag needs a gh
    # newer than the one Debian and Ubuntu package (2.4.0 has no such flag).
    & $Gh release download $release.Tag --repo $ZurgRepo --pattern $release.Asset --dir $download
    if ($LASTEXITCODE -ne 0) { throw "The zurg release download failed." }
    Expand-Archive -Path (Join-Path $download $release.Asset) -DestinationPath $extracted -Force
    $downloadedBinary = Join-Path $extracted "zurg.exe"
    if (-not (Test-Path $downloadedBinary)) { throw "The zurg archive did not contain zurg.exe." }
    $help = & $downloadedBinary setup --help 2>&1 | Out-String
    if ($help -notmatch '--provider') { throw "The newest nightly predates provider selection. Try again after the next nightly release." }
    if (Test-Path $binary) {
        # a running zurg.exe is locked; renaming it aside lets the new one land
        $retired = "$binary.old"
        Remove-Item -Path $retired -Force -ErrorAction SilentlyContinue
        Rename-Item -Path $binary -NewName ([IO.Path]::GetFileName($retired)) -Force
    }
    Copy-Item -Path $downloadedBinary -Destination $binary
    Remove-Item -Path "$binary.old" -Force -ErrorAction SilentlyContinue
    return $binary
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $architecture = Get-PlatformArchitecture
    Write-Step "zurg Windows convenience installer"
    Write-Host "Platform: windows-$architecture"
    Write-Host "Install:  $InstallDir"

    if ($DryRun) {
        Write-Host "Dry run: WinFsp, private release download and zurg setup would run."
        return
    }

    $TempDir = Join-Path ([IO.Path]::GetTempPath()) ("zurg-install-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $TempDir | Out-Null
    Install-WinFsp
    $Gh = Get-GitHubCli
    Connect-GitHub
    $zurg = Install-Zurg $architecture

    $help = & $zurg setup --help 2>&1 | Out-String
    if ($help -notmatch '--provider') { throw "This zurg build predates provider selection. Install the newest nightly and rerun this command." }

    Write-Step "Running zurg setup"
    Push-Location $InstallDir
    try {
        & $zurg setup
        if ($LASTEXITCODE -ne 0) { throw "zurg setup failed." }
        & $zurg doctor
        if ($LASTEXITCODE -ne 0) { throw "zurg doctor found a failed check." }
    }
    finally {
        Pop-Location
    }
    Write-Step "zurg is installed in $InstallDir"
    if ($RebootRequired) { Write-Warning "WinFsp requested a reboot. Reboot before using the Z: mount." }
}
finally {
    if ($TempDir -and (Test-Path $TempDir)) {
        Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
