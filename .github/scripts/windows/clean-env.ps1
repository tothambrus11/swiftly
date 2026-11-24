# Dot-source: gives the current PowerShell process a "fresh machine" environment
# (no VS variables, minimal PATH without MinGW/Strawberry/LLVM/etc.).
$vars = 'INCLUDE','LIB','LIBPATH','EXTERNAL_INCLUDE','VCToolsInstallDir','VCToolsVersion','VCINSTALLDIR','VSINSTALLDIR',
        'WindowsSdkDir','WindowsSDKVersion','WindowsSDKLibVersion','UniversalCRTSdkDir','UCRTVersion','VCIDEInstallDir',
        'VS170COMNTOOLS','VS160COMNTOOLS','DevEnvDir','VisualStudioVersion','SDKROOT','CC','CXX'
foreach ($v in $vars) { Remove-Item "env:$v" -ErrorAction SilentlyContinue }
$env:Path = @(
  "$env:SystemRoot\System32", $env:SystemRoot, "$env:SystemRoot\System32\Wbem",
  "$env:SystemRoot\System32\WindowsPowerShell\v1.0", 'C:\Program Files\PowerShell\7', 'C:\Program Files\Git\cmd'
) -join ';'
