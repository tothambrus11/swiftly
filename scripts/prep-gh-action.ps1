# The Windows counterpart of prep-gh-action.sh: installs a swift.org toolchain with its own installer
# (per user) and exports its environment to the following steps of the job. It builds swiftly; it
# doesn't test swiftly's own installation of toolchains.
#
#   prep-gh-action.ps1 [-Version <version>]    (default: the version in .swift-version)
param([string]$Version)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (-not $Version) { $Version = (Get-Content (Join-Path $PSScriptRoot '..\.swift-version') -Raw).Trim() }

# The newest patch release of that version's major.minor (6.4.0 means 6.4.x) with a Windows toolchain
# for this architecture, from swift.org's list: patch releases fix Windows issues (6.4.0's static
# runtime misses the Blocks runtime that swiftly links).
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x86_64' }
$minor = ($Version -split '\.')[0..1] -join '.'
# Invoke-RestMethod passes a JSON array on as one object; assigning it enumerates the releases.
$releases = Invoke-RestMethod 'https://www.swift.org/api/v1/install/releases.json'
$release = $releases |
  Where-Object { $_.name -eq $minor -or $_.name.StartsWith("$minor.") } |
  Where-Object { $_.platforms | Where-Object { $_.platform -eq 'Windows' -and $_.archs -contains $arch } } |
  Select-Object -Last 1
if (-not $release) { throw "swift.org lists no Windows release of Swift $Version for $arch" }
$tag = $release.tag
$platform = if ($arch -eq 'arm64') { 'windows10-arm64' } else { 'windows10' }
$url = "https://download.swift.org/$($tag.ToLowerInvariant())/$platform/$tag/$tag-$platform.exe"
Write-Host "Installing $tag from $url"
$installer = Join-Path $env:RUNNER_TEMP 'swift-installer.exe'
& curl.exe -sSfL --retry 3 -o $installer $url
if ($LASTEXITCODE) { throw "download failed: $url" }

# Only run an installer that swift.org signed: a valid signature, and Apple Inc. (US) as the
# certificate's organization and country, compared as parsed fields rather than as a substring.
$signature = Get-AuthenticodeSignature $installer
$fields = @{}
if ($signature.SignerCertificate) {
  foreach ($line in ($signature.SignerCertificate.SubjectName.Format($true) -split "`r?`n")) {
    if ($line -match '^\s*([A-Z]+)=(.*)$') { $fields[$Matches[1]] = $Matches[2].Trim().Trim('"') }
  }
}
if ($signature.Status -ne 'Valid' -or $fields['O'] -ne 'Apple Inc.' -or $fields['C'] -ne 'US') {
  throw "the installer isn't validly signed by Apple Inc.: $($signature.Status) $($signature.SignerCertificate.Subject)"
}

$key = 'HKCU:\Environment'
$before = @((Get-Item $key).GetValue('Path', '', 'DoNotExpandEnvironmentNames') -split ';')
$p = Start-Process -FilePath $installer -ArgumentList '/quiet', '/norestart' -Wait -PassThru
if ($p.ExitCode -ne 0) { throw "installer failed: $($p.ExitCode)" }
Remove-Item $installer

# The installer adds to Path and sets SDKROOT in HKCU\Environment, which this job's later steps don't
# see; they see GITHUB_PATH and GITHUB_ENV.
$environment = Get-Item $key
foreach ($dir in ($environment.GetValue('Path', '', 'DoNotExpandEnvironmentNames') -split ';')) {
  if ($dir -and $before -notcontains $dir) {
    $dir = [Environment]::ExpandEnvironmentVariables($dir)
    Add-Content $env:GITHUB_PATH $dir
    Write-Host "PATH += $dir"
  }
}
$sdkroot = $environment.GetValue('SDKROOT', '')
if ($sdkroot) { Add-Content $env:GITHUB_ENV "SDKROOT=$sdkroot"; Write-Host "SDKROOT=$sdkroot" }
