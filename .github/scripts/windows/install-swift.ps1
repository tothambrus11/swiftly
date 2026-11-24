# Installs a swift.org toolchain with its own installer (per user) and exports its
# environment to the following steps. Used to build swiftly, not to test it.
param([Parameter(Mandatory = $true)][string]$Version)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$suffix = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { '-arm64' } else { '' }
$url = "https://download.swift.org/swift-$Version-release/windows10$suffix/swift-$Version-RELEASE/swift-$Version-RELEASE-windows10$suffix.exe"
$installer = Join-Path $env:RUNNER_TEMP 'swift-installer.exe'
& curl.exe -sSfL --retry 3 -o $installer $url
if ($LASTEXITCODE) { throw "download failed: $url" }
$p = Start-Process -FilePath $installer -ArgumentList '/quiet', '/norestart' -Wait -PassThru
if ($p.ExitCode -ne 0) { throw "installer failed: $($p.ExitCode)" }
Remove-Item $installer
# The installer writes Path and SDKROOT to HKCU\Environment; later steps only see GITHUB_PATH/GITHUB_ENV.
$key = Get-Item 'HKCU:\Environment'
foreach ($dir in ($key.GetValue('Path', '') -split ';')) {
  if ($dir -match '\\Swift\\') { Add-Content $env:GITHUB_PATH $dir; Write-Host "PATH += $dir" }
}
$sdkroot = $key.GetValue('SDKROOT', '')
if ($sdkroot) { Add-Content $env:GITHUB_ENV "SDKROOT=$sdkroot"; Write-Host "SDKROOT=$sdkroot" }
