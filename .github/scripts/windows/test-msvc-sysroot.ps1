# End-to-end test of the opt-in MSVC sysroot (--msvc=portable) on a runner with Visual Studio, the
# Windows Kits and LLVM hidden (hide-vs.ps1): declining installs the toolchain without downloading
# anything from Microsoft; accepting sets up the sysroot, which a second toolchain reuses; then
# building and testing through the proxies in fresh terminals.
#
#   test-msvc-sysroot.ps1 -Swiftly <swiftly.exe> [-Older 6.2.4]
param(
  [Parameter(Mandatory = $true)][string]$Swiftly,
  [string]$Older = '6.2.4',
  # The first toolchain instead of the latest release, such as main-snapshot.
  [string]$First
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$here = $PSScriptRoot
$results = [ordered]@{}

function X {
  $cmd = @($args)
  Write-Host "> $($cmd -join ' ')" -ForegroundColor Cyan
  & $cmd[0] @($cmd | Select-Object -Skip 1)
  if ($LASTEXITCODE) { throw "exit code $LASTEXITCODE from: $($cmd -join ' ')" }
}
function Case([string]$name, [scriptblock]$body) {
  Write-Host "::group::$name"
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try { & $body; $results[$name] = "PASS ($([math]::Round($sw.Elapsed.TotalSeconds))s)" }
  catch { $results[$name] = "FAIL: $_"; Write-Host "::error::$name failed: $_" }
  Write-Host '::endgroup::'
}
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }
function SwiftVersionOf([string]$text) { [regex]::Match($text, 'Swift version (\d+\.\d+(\.\d+)?)').Groups[1].Value }

$swiftlyHome = Join-Path $env:LOCALAPPDATA 'swiftly'
$toolchains = Join-Path $swiftlyHome 'toolchains'
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
$triple = if ($arch -eq 'arm64') { 'aarch64-unknown-windows-msvc' } else { 'x86_64-unknown-windows-msvc' }
$sysroot = Join-Path $swiftlyHome "msvc-sysroot-$arch"
$work = Join-Path $env:RUNNER_TEMP 'swiftly-e2e'
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work
. (Join-Path $here 'clean-env.ps1')
Remove-Item env:SWIFTLY_ACCEPT_MSVC_LICENSE -ErrorAction SilentlyContinue

Case 'swiftly init --skip-install' { X $Swiftly init --assume-yes --skip-install }
. (Join-Path $here 'fresh-env.ps1')

$latest = ''
Case 'declined: the toolchain installs, nothing comes from Microsoft' {
  $releases = Invoke-RestMethod 'https://www.swift.org/api/v1/install/releases.json'
  $script:latest = if ($First) { $First } else { $releases[-1].name }
  $post = Join-Path $work 'post-install.txt'
  # Enter at the question takes the default, no; --assume-yes must not answer it.
  $out = '' | & swiftly install $script:latest --assume-yes --msvc=portable --post-install-file $post 2>&1 | Out-String
  Write-Host $out
  Assert ($LASTEXITCODE -eq 0) "install failed: $LASTEXITCODE"
  Assert ($out -match 'Accept the Microsoft license terms\?') 'no license question'
  # The terms the packages point to (the output wraps lines).
  Assert ($out -match 'LinkId=2179911' -and $out -match 'WinSDKLicenseURL') 'license links missing'
  Assert (-not (Test-Path $sysroot)) "$sysroot exists although the license wasn't accepted"
  Assert ((Get-Content -Raw $post) -match 'winget install') 'no Visual Studio instructions'
  Assert (@(Get-ChildItem $toolchains -Directory | Where-Object Name -NotLike '_*').Count -eq 1) 'the toolchain was not installed'
  X swiftly uninstall $script:latest --assume-yes
}

Case 'accepted with --accept-msvc-license: the sysroot is set up' {
  X swiftly install $latest --assume-yes --msvc=portable --accept-msvc-license --use
  Assert (Test-Path (Join-Path $sysroot 'sysroot.json')) 'no sysroot'
  Get-Content (Join-Path $sysroot 'sysroot.json') | Write-Host
  $cfg = @(Get-ChildItem $toolchains -Recurse -Filter "$triple.cfg")
  Assert ($cfg.Count -eq 1) "expected one $triple.cfg, found $($cfg.Count)"
  Get-Content $cfg[0].FullName | Write-Host
  Assert (-not (Get-ChildItem $toolchains -Recurse -Filter clang.cfg)) 'a clang.cfg was written'
  Assert (@(Get-ChildItem $toolchains -Recurse -Filter "*-windows-msvc-clang-cl.cfg").Count -eq 2) 'no clang-cl configurations'
}

Case "swiftly install $Older reuses the sysroot" {
  X swiftly install $Older --assume-yes
  Assert (@(Get-ChildItem $toolchains -Recurse -Filter "$triple.cfg").Count -eq 2) "$Older has no $triple.cfg"
}

# Whether `swift --version` output is that of the toolchain `selector`: a snapshot's is "-dev".
function IsVersion([string]$out, [string]$selector) {
  if ($selector -like '*snapshot*') { return $out -match 'Swift version \S+-dev' }
  return (SwiftVersionOf $out) -eq $selector
}

function Test-Toolchain([string]$version) {
  $dir = Join-Path $work "t-$version"
  if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
  New-Item -ItemType Directory $dir | Out-Null
  Push-Location $dir
  try {
    . (Join-Path $here 'fresh-env.ps1')
    Case "[$version] swift --version (proxy, fresh terminal)" {
      $out = (& swift --version 2>&1 | Out-String); Write-Host $out
      Assert (IsVersion $out $version) "the proxy used $(SwiftVersionOf $out)"
    }
    Copy-Item (Join-Path $here 'fixtures\foundation.swift') . -Force
    Case "[$version] swiftc Foundation program (debug) + run" {
      X swiftc foundation.swift -o fdemo.exe
      X swiftly run .\fdemo.exe
    }
    Case "[$version] swiftc -O Foundation program + run" {
      X swiftc -O foundation.swift -o fdemo-o.exe
      X swiftly run .\fdemo-o.exe
    }
    Case "[$version] clang-cl C program + run" {
      Set-Content probe.c "#include <stdio.h>`n#include <windows.h>`nint main(void) { printf(`"pid %lu\n`", GetCurrentProcessId()); return 0; }"
      X clang-cl /nologo probe.c /Fe:probe.exe
      X .\probe.exe
    }
    Copy-Item -Recurse (Join-Path $here 'fixtures\swiftpkg') pkg
    Push-Location pkg
    try {
      Case "[$version] swift build" { X swift build }
      Case "[$version] swift run" { X swift run FoundationDemo }
      Case "[$version] swift run (C target)" { X swift run CDemo }
      Case "[$version] swift test (XCTest + swift-testing)" { X swift test }
    } finally { Pop-Location }
  } finally { Pop-Location }
}

Case "swiftly use $Older" { X swiftly use $Older --global-default --assume-yes }
Test-Toolchain $Older
Case "swiftly use $latest" { X swiftly use $latest --global-default --assume-yes }
Test-Toolchain $latest

# An experiment, which doesn't fail the job: does the Swift compiler find the sysroot's SDK, and
# map its own modulemaps in, from -Xmicrosoft-windows-sys-root in the clang configuration alone,
# without swiftly's VFS overlay?
Write-Host '::group::experiment: the sysroot without the overlay'
try {
$cfg = @(Get-ChildItem $toolchains -Recurse -Filter "$triple.cfg")
foreach ($file in $cfg) {
  $text = Get-Content -Raw $file.FullName
  [IO.File]::WriteAllText($file.FullName, (($text -split "`n" | Where-Object { $_ -notlike '-ivfsoverlay*' }) -join "`n"))
  Push-Location $work
  try {
    $version = ($file.FullName.Substring($toolchains.Length + 1) -split '[\\/]')[0]
    Set-Content winsdk.swift "import WinSDK`nimport Foundation`nprint(GetCurrentProcessId(), Date())"
    $out = (& swiftly run swiftc winsdk.swift -o winsdk.exe "+$version" 2>&1 | Out-String)
    $results["experiment: $version without the overlay"] = if ($LASTEXITCODE -eq 0) { 'WORKS' } else { 'needs the overlay' }
    Write-Host $out
  } finally { Pop-Location }
  [IO.File]::WriteAllText($file.FullName, $text)
}
} catch { Write-Host "experiment failed to run: $_" }
Write-Host '::endgroup::'

$results | Format-Table -AutoSize | Out-String -Width 300 | Write-Host
$md = "| case | result |`n|---|---|`n" + (($results.Keys | ForEach-Object { "| $_ | $($results[$_]) |" }) -join "`n")
if ($env:GITHUB_STEP_SUMMARY) { "### $env:JOB_LABEL`n$md`n" | Out-File -Append -Encoding utf8 $env:GITHUB_STEP_SUMMARY }
if (@($results.Values | Where-Object { $_ -like 'FAIL*' }).Count -gt 0) { exit 1 }
exit 0
