# dextr installer (Windows x64).
#
# Usage:
#   irm https://raw.githubusercontent.com/JayashBhandary/dextr/main/install.ps1 | iex
#
# Downloads the latest GitHub release zip and installs to:
#   %LOCALAPPDATA%\Programs\dextr
# Also creates a Start Menu shortcut.

$ErrorActionPreference = 'Stop'

$Repo    = 'JayashBhandary/dextr'
$AppName = 'dextr'

# GitHub API needs TLS 1.2 on older Windows / PowerShell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host "==> Fetching latest release info from $Repo"

$headers = @{}
if ($env:GITHUB_TOKEN) {
    $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN"
}
$headers['User-Agent'] = 'dextr-installer'

$release = Invoke-RestMethod `
    -Uri "https://api.github.com/repos/$Repo/releases/latest" `
    -Headers $headers `
    -UseBasicParsing

# Only assets served from this project's own release path are candidates: the
# release lists every attached asset, and a name match alone would accept one
# uploaded by somebody else.
#
# Compared case-insensitively: the API returns URLs with the repository's
# canonical casing (".../JayashBhandary/Dextr/..."), which need not match the
# spelling in $Repo. GitHub owner and repository names are unique without
# regard to case, so this still cannot resolve to anybody else's repository.
$releasePrefix = "https://github.com/$Repo/releases/download/"
$ordinalNoCase = [System.StringComparison]::OrdinalIgnoreCase

$asset = $release.assets |
    Where-Object {
        $_.browser_download_url.StartsWith($releasePrefix, $ordinalNoCase) -and
        $_.name -match '^dextr-.*windows-x64\.zip$'
    } |
    Select-Object -First 1

if (-not $asset) {
    Write-Error "No windows-x64.zip asset found in the latest release. See https://github.com/$Repo/releases"
    exit 1
}

$sums = $release.assets |
    Where-Object {
        $_.browser_download_url.StartsWith($releasePrefix, $ordinalNoCase) -and $_.name -eq 'SHA256SUMS'
    } |
    Select-Object -First 1

if (-not $sums) {
    Write-Error @"
This release publishes no SHA256SUMS file, so the download cannot be verified.
Refusing to install.

Releases from v0.1.3 onward publish one. To install an earlier build, download
it from https://github.com/$Repo/releases and check it by hand.
"@
    exit 1
}

$tmpFile = [System.IO.Path]::GetTempFileName()
$zipPath = "$tmpFile.zip"
Move-Item -Force $tmpFile $zipPath
$sumsPath = "$tmpFile.sums"

try {
    Write-Host "==> Downloading $($asset.browser_download_url)"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -UseBasicParsing

    # Before the archive is expanded. An installer that skips this is a remote
    # code execution primitive for whoever can influence a release artifact.
    Write-Host '==> Verifying checksum'
    Invoke-WebRequest -Uri $sums.browser_download_url -OutFile $sumsPath -UseBasicParsing

    $expected = $null
    foreach ($line in Get-Content $sumsPath) {
        # `sha256sum` writes "<digest>  <name>", and prefixes the name with '*'
        # for a binary-mode entry. Matched on the exact name, not a substring.
        $fields = $line -split '\s+', 2
        if ($fields.Count -lt 2) { continue }
        $name = $fields[1].Trim().TrimStart('*')
        if ($name -eq $asset.name) {
            $expected = $fields[0].Trim().ToLowerInvariant()
            break
        }
    }

    if (-not $expected) {
        Write-Error "SHA256SUMS does not list $($asset.name). Refusing to install."
        exit 1
    }

    $actual = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()

    if ($expected -ne $actual) {
        Write-Error @"
Checksum mismatch for $($asset.name) - refusing to install.
  expected: $expected
  actual:   $actual

The download does not match what the release says it published. This is either
a corrupted transfer or a tampered artifact; do not install it either way.
"@
        exit 1
    }

    Write-Host "    OK  $actual"

    $installDir = Join-Path $env:LOCALAPPDATA "Programs\$AppName"

    if (Test-Path $installDir) {
        Write-Host "==> Removing previous installation at $installDir"
        Remove-Item -Recurse -Force $installDir
    }

    Write-Host "==> Extracting to $installDir"
    New-Item -ItemType Directory -Force -Path $installDir | Out-Null
    Expand-Archive -Path $zipPath -DestinationPath $installDir -Force

    # Locate the executable (Flutter builds <project-name>.exe, lowercased)
    $exe = Get-ChildItem -Path $installDir -Filter '*.exe' -File |
           Where-Object { $_.Name -match '^(?i)dextr\.exe$' } |
           Select-Object -First 1

    if (-not $exe) {
        # Fallback: first .exe in the bundle
        $exe = Get-ChildItem -Path $installDir -Filter '*.exe' -File | Select-Object -First 1
    }

    if (-not $exe) {
        Write-Error "Could not find a .exe inside the extracted bundle at $installDir."
        exit 1
    }

    # Start Menu shortcut
    $startMenuDir = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'
    if (-not (Test-Path $startMenuDir)) {
        New-Item -ItemType Directory -Force -Path $startMenuDir | Out-Null
    }
    $shortcutPath = Join-Path $startMenuDir "$AppName.lnk"

    $shell    = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath       = $exe.FullName
    $shortcut.WorkingDirectory = $exe.DirectoryName
    $shortcut.Save()

    Write-Host ''
    Write-Host "Installed:  $installDir"
    Write-Host "Executable: $($exe.FullName)"
    Write-Host "Shortcut:   $shortcutPath"
    Write-Host 'Done.'
}
finally {
    foreach ($path in @($zipPath, $sumsPath)) {
        if ($path -and (Test-Path $path)) {
            Remove-Item -Force $path
        }
    }
}
