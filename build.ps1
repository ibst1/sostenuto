# build.ps1 - builds the portable Sostenuto release zip into dist\.
# Downloads the AutoHotkey v2 base into build\ on first run and caches it there.
# Works in Windows PowerShell 5.1 and PowerShell 7 (used by the GitHub Actions
# release workflow).
#
# The zip ships the UNMODIFIED official AutoHotkey64.exe renamed to Sostenuto.exe,
# next to the plain-text scripts: run with no arguments, the interpreter loads the
# script matching its own name (Sostenuto.ahk). A stock interpreter keeps its
# reputation with Defender, an Ahk2Exe build does not.
#
# The zip holds the tracked files only, so Sostenuto.ini and the *.local.ahk files
# are never in it: unzipping a new version over an old one keeps your settings.
#
# Version: -Version, else the pushed tag (v2026.10.12 -> 2026.10.12), else today.
param([string]$Version)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$root = $PSScriptRoot
$tools = Join-Path $root 'build'
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force $tools | Out-Null

if (-not $Version) {
    $Version = if ($env:GITHUB_REF_NAME -match '^v(.+)$') { $Matches[1] } else { Get-Date -Format 'yyyy.M.d' }
}
Write-Host "Building Sostenuto $Version"

$base = Join-Path $tools 'base\AutoHotkey64.exe'
if (-not (Test-Path $base)) {
    Write-Host 'Downloading AutoHotkey v2 base...'
    $rels = Invoke-RestMethod 'https://api.github.com/repos/AutoHotkey/AutoHotkey/releases'
    $v2 = $rels | Where-Object { $_.tag_name -like 'v2.0*' } | Select-Object -First 1
    $asset = $v2.assets | Where-Object { $_.name -like 'AutoHotkey_2*.zip' } | Select-Object -First 1
    Invoke-WebRequest $asset.browser_download_url -OutFile (Join-Path $tools 'ahk2.zip')
    Expand-Archive (Join-Path $tools 'ahk2.zip') (Join-Path $tools 'base') -Force
}

# everything tracked except repo plumbing
$files = @(git -C $root ls-files) | Where-Object { $_ -notmatch '^(\.git|build\.ps1$)' }
if ($files.Count -eq 0) { throw 'git ls-files returned nothing - run from a git checkout' }

# clear dist with retries - OneDrive/AV can hold freshly written files briefly
if (Test-Path $dist) {
    $done = $false
    foreach ($i in 1..5) {
        try {
            Remove-Item $dist -Recurse -Force -ErrorAction Stop
            $done = $true
            break
        } catch {
            Start-Sleep -Seconds 2
        }
    }
    if (-not $done) { throw "Could not clear $dist - is the folder open?" }
}
$stage = Join-Path $dist 'Sostenuto'
foreach ($f in $files) {
    $to = Join-Path $stage $f
    New-Item -ItemType Directory -Force (Split-Path $to) | Out-Null
    Copy-Item (Join-Path $root $f) $to
}
# the renamed stock interpreter auto-loads Sostenuto.ahk beside it
Copy-Item $base (Join-Path $stage 'Sostenuto.exe')

$zip = Join-Path $dist "Sostenuto-$Version.zip"
Compress-Archive -Path $stage -DestinationPath $zip -Force
Write-Host "Done: $zip"
