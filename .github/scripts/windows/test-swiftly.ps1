# End-to-end test of swiftly on Windows (with Visual Studio, as on the GitHub runners): init, two
# toolchains side by side, use, run, building and testing through the proxies in fresh terminals,
# upgrading swiftly while a proxy runs, uninstall.
#
#   test-swiftly.ps1 -Swiftly <swiftly.exe> [-Older 6.2.4] [-OlderInstallOnly]
#
# -OlderInstallOnly installs, uses and uninstalls the older toolchain without building with it: Swift
# 6.2's driver can't read its own files under a path with non-ASCII characters (6.4 can).
#
# SWIFTLY_HOME_DIR, SWIFTLY_BIN_DIR and SWIFTLY_TOOLCHAINS_DIR are honored. CI only: this changes the
# user's Path in the registry.
param(
  [Parameter(Mandatory = $true)][string]$Swiftly,
  [string]$Older = '6.2.4',
  [switch]$OlderInstallOnly,
  # The first toolchain, instead of the latest release that init installs, such as main-snapshot.
  [string]$First,
  # Options for every `swiftly install`, such as --no-verify.
  [string[]]$InstallOptions = @()
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

$swiftlyHome = if ($env:SWIFTLY_HOME_DIR) { $env:SWIFTLY_HOME_DIR } else { Join-Path $env:LOCALAPPDATA 'swiftly' }
$bin = if ($env:SWIFTLY_BIN_DIR) { $env:SWIFTLY_BIN_DIR } else { Join-Path $swiftlyHome 'bin' }
$toolchains = if ($env:SWIFTLY_TOOLCHAINS_DIR) { $env:SWIFTLY_TOOLCHAINS_DIR } else { Join-Path $swiftlyHome 'toolchains' }
Write-Host "home: $swiftlyHome"
# Outside of any git checkout, so that `swiftly use` changes the global default.
$work = Join-Path $env:RUNNER_TEMP 'swiftly-e2e'
New-Item -ItemType Directory -Force $work | Out-Null
Set-Location $work
$customDirs = @{ SWIFTLY_HOME_DIR = $env:SWIFTLY_HOME_DIR; SWIFTLY_BIN_DIR = $env:SWIFTLY_BIN_DIR; SWIFTLY_TOOLCHAINS_DIR = $env:SWIFTLY_TOOLCHAINS_DIR }
. (Join-Path $here 'clean-env.ps1')
foreach ($k in $customDirs.Keys) { if ($customDirs[$k]) { Set-Item "env:$k" $customDirs[$k] } }

$installFirst = $First -or $InstallOptions.Count -gt 0
Case 'swiftly init (latest toolchain)' {
  if ($installFirst) {
    X $Swiftly init --skip-install --assume-yes --verbose
    $selector = if ($First) { $First } else { 'latest' }
    X (Join-Path $bin 'swiftly.exe') install $selector --use --assume-yes --verbose @InstallOptions
  } else {
    X $Swiftly init --assume-yes --verbose
  }
  Assert (Test-Path (Join-Path $bin 'swiftly.exe')) 'swiftly.exe was not installed into the bin directory'
  Assert (-not (Get-ChildItem $toolchains -Recurse -Filter clang.cfg -ErrorAction SilentlyContinue)) 'a clang.cfg was written'
  $userPath = (Get-Item 'HKCU:\Environment').GetValue('Path', '', 'DoNotExpandEnvironmentNames')
  Assert ($userPath -like "*$bin*") "the user Path doesn't contain $bin"
  foreach ($k in $customDirs.Keys) {
    if ($customDirs[$k]) { Assert ((Get-Item 'HKCU:\Environment').GetValue($k) -eq $customDirs[$k]) "$k wasn't recorded for new terminals" }
  }
}

# A new terminal: the machine Path plus what init wrote to the user's environment.
. (Join-Path $here 'fresh-env.ps1')
$latest = ''
Case 'swiftly list / swift --version through the proxy' {
  X swiftly --version
  X swiftly list
  $out = (& swift --version 2>&1 | Out-String); Write-Host $out
  # A snapshot says "Swift version 6.5-dev"; it's used by its selector.
  $script:latest = if ($First) { $First } else { SwiftVersionOf $out }
  Assert ($out -match 'Swift version') 'no Swift version from the swift proxy'
  Assert ((Get-Command swift).Source -like "$bin\*") "swift resolves to $((Get-Command swift).Source)"
}

Case "swiftly install $Older (side by side)" {
  X swiftly install $Older --assume-yes @InstallOptions
  X swiftly list
  Assert (@(Get-ChildItem $toolchains -Directory | Where-Object Name -NotLike '_*').Count -eq 2) 'expected two toolchain directories'
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
    Case "[$version] swiftly run swift --version" {
      $out = (& swiftly run swift --version 2>&1 | Out-String); Write-Host $out
      Assert (IsVersion $out $version) "swiftly run used $(SwiftVersionOf $out)"
    }
    . (Join-Path $here 'fresh-env.ps1')
    Case "[$version] swift --version (proxy, fresh terminal)" {
      $out = (& swift --version 2>&1 | Out-String); Write-Host $out
      Assert (IsVersion $out $version) "the proxy used $(SwiftVersionOf $out)"
    }
    # What the installer installs by default too: the IDE support and the debugger.
    Case "[$version] sourcekit-lsp, clangd and lldb (proxies)" {
      X sourcekit-lsp --help | Out-Null
      X clangd --version
      X lldb --version
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
if (-not $OlderInstallOnly) { Test-Toolchain $Older }
Case "swiftly use $latest" { X swiftly use $latest --global-default --assume-yes }
Test-Toolchain $latest

Case 'upgrade swiftly while a proxy is running' {
  # Away from the checkout, whose .swift-version names a toolchain that isn't installed.
  Push-Location $env:RUNNER_TEMP
  # swiftc reading a program from stdin keeps running until stdin closes.
  $psi = [Diagnostics.ProcessStartInfo]::new((Join-Path $bin 'swiftc.exe'), '-parse -')
  $psi.WorkingDirectory = $env:RUNNER_TEMP
  $psi.RedirectStandardInput = $true
  $psi.UseShellExecute = $false
  $running = [Diagnostics.Process]::Start($psi)
  try {
    Start-Sleep -Seconds 3
    Assert (-not $running.HasExited) 'the proxy process did not keep running'
    X $Swiftly init --skip-install --assume-yes
    $links = (& fsutil.exe hardlink list (Join-Path $bin 'swift.exe') | Out-String)
    Write-Host $links
    Assert ($links -match 'swiftly\.exe') 'swift.exe is no longer a hard link to swiftly.exe'
    $out = (& swift --version 2>&1 | Out-String)
    Assert (IsVersion $out $latest) "after upgrading, the proxy used $(SwiftVersionOf $out)"
    Assert (@(Get-ChildItem $bin -Filter '*.old').Count -gt 0) 'the running proxy was not kept aside'
  } finally {
    $running.StandardInput.Close()
    $running.WaitForExit(60000) | Out-Null
    Pop-Location
  }
  X $Swiftly init --skip-install --assume-yes
  $left = @(Get-ChildItem $bin | Where-Object Name -Match '\.[0-9a-f]{8}\.(old|new)$')
  Assert ($left.Count -eq 0) "left over: $($left.Name -join ', ')"
}

Case "swiftly uninstall $Older" {
  X swiftly uninstall $Older --assume-yes
  $out = (& swiftly list 2>&1 | Out-String); Write-Host $out
  Assert ($out -notmatch [regex]::Escape($Older)) "$Older is still listed"
  Assert (-not (Test-Path (Join-Path $toolchains $Older))) "toolchains\$Older still exists"
  $out = (& swift --version 2>&1 | Out-String)
  Assert (IsVersion $out $latest) "after uninstalling, swift is $(SwiftVersionOf $out)"
}

Case 'swiftly self-uninstall' {
  X swiftly self-uninstall --assume-yes
  $userPath = (Get-Item 'HKCU:\Environment').GetValue('Path', '', 'DoNotExpandEnvironmentNames')
  Assert ($userPath -notlike "*$bin*") "the user Path still contains $bin"
  $proxies = @(Get-ChildItem $bin -Filter *.exe -ErrorAction SilentlyContinue)
  Assert ($proxies.Count -eq 0) "left in the bin directory: $($proxies.Name -join ', ')"
}

$results | Format-Table -AutoSize | Out-String -Width 300 | Write-Host
$md = "| case | result |`n|---|---|`n" + (($results.Keys | ForEach-Object { "| $_ | $($results[$_]) |" }) -join "`n")
if ($env:GITHUB_STEP_SUMMARY) { "### $env:JOB_LABEL`n$md`n" | Out-File -Append -Encoding utf8 $env:GITHUB_STEP_SUMMARY }
if (@($results.Values | Where-Object { $_ -like 'FAIL*' }).Count -gt 0) { exit 1 }
