# End-to-end test of swiftly on Windows: init (with the license gate), two toolchains side by side,
# use, run, building and testing through the proxies in a fresh environment, uninstall.
#
#   test-swiftly.ps1 -Swiftly <swiftly.exe> -Msvc portable|visual-studio [-Older 6.2.4]
#
# CI only: it changes the user's Path in the registry.
param(
  [Parameter(Mandatory = $true)][string]$Swiftly,
  [Parameter(Mandatory = $true)][ValidateSet('portable', 'visual-studio')][string]$Msvc,
  [string]$Older = '6.2.4'
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

$home_ = Join-Path $env:LOCALAPPDATA 'swiftly'
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
$sysroot = Join-Path $home_ "msvc-sysroot-$arch"
# Outside of any git checkout, so that `swiftly use` changes the global default.
$work = Join-Path $env:RUNNER_TEMP 'swiftly-e2e'
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work
. (Join-Path $here 'clean-env.ps1')
Remove-Item env:SWIFTLY_ACCEPT_MSVC_LICENSE -ErrorAction SilentlyContinue

if ($Msvc -eq 'portable') {
  Case 'license gate: init --assume-yes refuses without SWIFTLY_ACCEPT_MSVC_LICENSE' {
    # Enter at the license question takes the default, no. (--assume-yes must not answer it.)
    $out = '' | & $Swiftly init --assume-yes 2>&1 | Out-String
    Write-Host $out
    Assert ($LASTEXITCODE -ne 0) 'init succeeded without accepting the license'
    Assert ($out -match 'license terms') 'no license terms were shown'
    Assert (-not (Test-Path $sysroot)) "$sysroot exists although the license wasn't accepted"
    Assert (-not (Test-Path (Join-Path $home_ 'toolchains\*'))) 'a toolchain was installed although the license was not accepted'
  }
}

Case 'swiftly init (latest toolchain)' {
  if ($Msvc -eq 'portable') { $env:SWIFTLY_ACCEPT_MSVC_LICENSE = '1' }
  try { X $Swiftly init --assume-yes --overwrite --verbose }
  finally { Remove-Item env:SWIFTLY_ACCEPT_MSVC_LICENSE -ErrorAction SilentlyContinue }
  Assert (Test-Path (Join-Path $home_ 'bin\swiftly.exe')) 'swiftly.exe was not installed into the bin directory'
  if ($Msvc -eq 'portable') {
    Assert (Test-Path (Join-Path $sysroot 'sysroot.json')) 'no MSVC sysroot'
    Get-Content (Join-Path $sysroot 'sysroot.json') | Write-Host
  } else {
    Assert (-not (Test-Path $sysroot)) "Visual Studio is installed, but swiftly downloaded $sysroot"
    $cfg = @(Get-ChildItem (Join-Path $home_ 'toolchains') -Recurse -Filter clang.cfg -ErrorAction SilentlyContinue)
    Assert ($cfg.Count -eq 0) "Visual Studio is installed, but swiftly wrote $($cfg.FullName -join ', ')"
  }
}

# A new terminal: the machine Path plus what init wrote to the user's Path.
. (Join-Path $here 'fresh-env.ps1')
$latest = ''
Case 'swiftly list / swift --version through the proxy' {
  X swiftly --version
  X swiftly list
  $out = (& swift --version 2>&1 | Out-String); Write-Host $out
  $script:latest = SwiftVersionOf $out
  Assert $script:latest 'no Swift version from the swift proxy'
  Assert ((Get-Command swift).Source -like "$home_\bin\*") "swift resolves to $((Get-Command swift).Source)"
}

Case "swiftly install $Older (side by side)" {
  if ($Msvc -eq 'portable') {
    # The sysroot is already there: no license question, nothing more from Microsoft.
    Assert (-not $env:SWIFTLY_ACCEPT_MSVC_LICENSE) 'license variable leaked'
  }
  X swiftly install $Older --assume-yes --verbose
  X swiftly list
  Assert (@(Get-ChildItem (Join-Path $home_ 'toolchains') -Directory).Count -eq 2) 'expected two toolchain directories'
}

function Test-Toolchain([string]$version) {
  $dir = Join-Path $work "t-$version"
  if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
  New-Item -ItemType Directory $dir | Out-Null
  Push-Location $dir
  try {
    Case "[$version] swiftly run swift --version" {
      $out = (& swiftly run swift --version 2>&1 | Out-String); Write-Host $out
      Assert ((SwiftVersionOf $out) -eq $version) "swiftly run used $(SwiftVersionOf $out)"
    }
    # A fresh terminal for every step, as a user would have.
    . (Join-Path $here 'fresh-env.ps1')
    Case "[$version] swift --version (proxy, fresh shell)" {
      $out = (& swift --version 2>&1 | Out-String); Write-Host $out
      Assert ((SwiftVersionOf $out) -eq $version) "the proxy used $(SwiftVersionOf $out)"
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
    Copy-Item -Recurse (Join-Path $here 'fixtures\swiftpkg') pkg
    Push-Location pkg
    try {
      Case "[$version] swift build" { X swift build }
      Case "[$version] swift run" { X swift run FoundationDemo }
      Case "[$version] swift test (XCTest + swift-testing)" { X swift test }
    } finally { Pop-Location }
  } finally { Pop-Location }
}

Case "swiftly use $Older" { X swiftly use $Older --global-default --assume-yes }
Test-Toolchain $Older
Case "swiftly use $latest" { X swiftly use $latest --global-default --assume-yes }
Test-Toolchain $latest

Case 'init again keeps the proxies linked to the new swiftly.exe' {
  X $Swiftly init --assume-yes
  $links = (& fsutil.exe hardlink list (Join-Path $home_ 'bin\swift.exe') | Out-String)
  Write-Host $links
  Assert ($links -match 'swiftly\.exe') 'swift.exe is no longer a hard link to swiftly.exe'
  $out = (& swift --version 2>&1 | Out-String)
  Assert ((SwiftVersionOf $out) -eq $latest) "the proxy used $(SwiftVersionOf $out)"
}

Case "swiftly uninstall $Older" {
  X swiftly uninstall $Older --assume-yes
  $out = (& swiftly list 2>&1 | Out-String); Write-Host $out
  Assert ($out -notmatch [regex]::Escape($Older)) "$Older is still listed"
  Assert (-not (Test-Path (Join-Path $home_ "toolchains\$Older"))) "toolchains\$Older still exists"
  $out = (& swift --version 2>&1 | Out-String)
  Assert ((SwiftVersionOf $out) -eq $latest) "after uninstalling, swift is $(SwiftVersionOf $out)"
}

$results | Format-Table -AutoSize | Out-String -Width 300 | Write-Host
$md = "| case | result |`n|---|---|`n" + (($results.Keys | ForEach-Object { "| $_ | $($results[$_]) |" }) -join "`n")
if ($env:GITHUB_STEP_SUMMARY) { "### $env:JOB_LABEL`n$md`n" | Out-File -Append -Encoding utf8 $env:GITHUB_STEP_SUMMARY }
if (@($results.Values | Where-Object { $_ -like 'FAIL*' }).Count -gt 0) { exit 1 }
