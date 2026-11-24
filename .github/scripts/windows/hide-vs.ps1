# Hides Visual Studio / Build Tools / Windows SDK on a GitHub Actions Windows runner
# so that the portable-toolchain test is honest. CI only - do NOT run on your machine.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

Write-Host '==> Stopping VS-related services/processes'
Get-Service | Where-Object { $_.Name -match 'VSStandardCollector|VSInstaller|vshub|Visual Studio' } | ForEach-Object {
  Write-Host "    stop service $($_.Name)"; Stop-Service $_.Name -Force -ErrorAction SilentlyContinue
}
Get-Process | Where-Object { $_.Path -and $_.Path -match 'Visual Studio|Windows Kits' } | ForEach-Object {
  Write-Host "    stop $($_.Path)"; Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}

$dirs = @(
  'C:\Program Files\Microsoft Visual Studio',
  'C:\Program Files (x86)\Microsoft Visual Studio',
  'C:\Program Files (x86)\Windows Kits',
  'C:\Program Files\Windows Kits',
  'C:\ProgramData\Microsoft\VisualStudio',
  'C:\Program Files (x86)\Microsoft SDKs\Windows Kits',
  'C:\Program Files\LLVM'   # preinstalled LLVM: not VS, but hide it so only Swift's clang is used
)
foreach ($d in $dirs) {
  if (-not (Test-Path $d)) { Write-Host "    (absent) $d"; continue }
  $leaf = Split-Path $d -Leaf
  $new = "$leaf.hidden"
  $t = Measure-Command { Rename-Item -LiteralPath $d -NewName $new -ErrorAction SilentlyContinue }
  if (Test-Path $d) {
    Write-Host "    rename failed for $d, deleting instead"
    $t = Measure-Command { cmd /c "rd /s /q `"$d`"" 2>$null }
  }
  Write-Host ("    hid {0} ({1:n1}s) -> exists now: {2}" -f $d, $t.TotalSeconds, (Test-Path $d))
}

Write-Host '==> Hiding registry keys'
$keys = @(
  'HKLM:\SOFTWARE\Microsoft\Windows Kits',
  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows Kits',
  'HKLM:\SOFTWARE\Microsoft\Microsoft SDKs\Windows',
  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft SDKs\Windows',
  'HKLM:\SOFTWARE\Microsoft\VisualStudio',
  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio',
  'HKLM:\SOFTWARE\Microsoft\VisualStudio\SxS',
  # Visual Studio Setup Configuration COM server (used by clang/swift to locate VS instances)
  'HKLM:\SOFTWARE\Classes\CLSID\{177F0C4A-1CD3-4DE7-A32C-71DBBB9FA36D}',
  'HKLM:\SOFTWARE\Classes\WOW6432Node\CLSID\{177F0C4A-1CD3-4DE7-A32C-71DBBB9FA36D}',
  'HKLM:\SOFTWARE\WOW6432Node\Classes\CLSID\{177F0C4A-1CD3-4DE7-A32C-71DBBB9FA36D}'
)
foreach ($k in $keys) {
  if (Test-Path $k) {
    $leaf = Split-Path $k -Leaf
    Rename-Item -Path $k -NewName "$leaf.hidden" -ErrorAction SilentlyContinue
    if (Test-Path $k) { Remove-Item -Path $k -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Host ("    {0} -> exists now: {1}" -f $k, (Test-Path $k))
  }
}

Write-Host '==> Removing VS-related machine/user environment variables'
$vars = 'INCLUDE','LIB','LIBPATH','EXTERNAL_INCLUDE','VCToolsInstallDir','VCToolsVersion','VCINSTALLDIR','VSINSTALLDIR',
        'WindowsSdkDir','WindowsSDKVersion','WindowsSDKLibVersion','UniversalCRTSdkDir','UCRTVersion','VCIDEInstallDir',
        'VS170COMNTOOLS','VS160COMNTOOLS','DevEnvDir','VisualStudioVersion'
foreach ($v in $vars) {
  foreach ($scope in 'Machine','User') { [Environment]::SetEnvironmentVariable($v, $null, $scope) }
}
