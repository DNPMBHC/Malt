param([ValidatePattern('^source-[a-z0-9-]+$')][string]$SourceStage = 'source-native', [ValidatePattern('^source-[a-z0-9-]+\.zip$')][string]$SourceArchive = 'source-revised.zip')
$ErrorActionPreference = 'Stop'
$lab = Join-Path $env:SystemDrive 'lab-b2'
$source = Join-Path $lab $SourceStage
$packages = Join-Path $lab 'toolchain'
$version = '10.0.26100.6584'
$expected = @{
    'Microsoft.Windows.SDK.cpp'='5d31b38205bdd9ac761b4cb39fbbc6b7209b01c11194324afc674d7d119483a0'
    'Microsoft.Windows.SDK.cpp.ARM64'='ac06922186fdd75e4ff1033a304ea629d7917bd0ca85e483762f8109584ccfc4'
    'Microsoft.Windows.WDK.ARM64'='e705b2a63eab891def8f98087666f93e8f21da8e3b5def81a624b83fef5bdae9'
}
foreach ($name in $expected.Keys) {
    $actual = (Get-FileHash (Join-Path $packages ($name+'.'+$version+'.nupkg')) -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected[$name]) { throw 'An official package changed between verified download and build.' }
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
if (Test-Path $source) { throw 'The fresh source staging directory already exists.' }
[IO.Compression.ZipFile]::ExtractToDirectory((Join-Path $lab $SourceArchive), $source)
$props = @'
<Project xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup>
    <B2Packages>$(MSBuildThisFileDirectory)..\toolchain\</B2Packages>
    <B2Version>10.0.26100.6584</B2Version>
  </PropertyGroup>
  <Import Project="$(B2Packages)Microsoft.Windows.SDK.cpp.$(B2Version)\build\native\Microsoft.Windows.SDK.cpp.props" />
  <Import Project="$(B2Packages)Microsoft.Windows.SDK.cpp.ARM64.$(B2Version)\build\native\Microsoft.Windows.SDK.cpp.arm64.props" />
  <Import Project="$(B2Packages)Microsoft.Windows.WDK.ARM64.$(B2Version)\build\native\Microsoft.Windows.WDK.arm64.props" />
  <PropertyGroup>
    <WindowsSdkDir>$(B2Packages)Microsoft.Windows.SDK.cpp.$(B2Version)\c\</WindowsSdkDir>
    <WindowsSdkDir_10>$(WindowsSdkDir)</WindowsSdkDir_10>
    <UCRTContentRoot>$(WindowsSdkDir)</UCRTContentRoot>
  </PropertyGroup>
</Project>
'@
Set-Content -LiteralPath (Join-Path $source 'Directory.Build.props') -Value $props -Encoding UTF8
$roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
$vswhere = $roots | ForEach-Object { Join-Path $_ 'Microsoft Visual Studio/Installer/vswhere.exe' } | Where-Object { Test-Path $_ } | Select-Object -First 1
$installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.ARM64 -property installationPath
$msbuild = @('MSBuild/Current/Bin/arm64/MSBuild.exe','MSBuild/Current/Bin/MSBuild.exe') | ForEach-Object { Join-Path $installation $_ } | Where-Object { Test-Path $_ } | Select-Object -First 1
$project = Get-ChildItem (Join-Path $source 'driver') -Filter '*.vcxproj' | Select-Object -First 1
$buildOutput = & $msbuild $project.FullName /p:Configuration=Release /p:Platform=ARM64 /p:TargetName=module-x-probe /p:WindowsTargetPlatformVersion=10.0.26100.0 /v:minimal /nologo 2>&1
$driverExit = $LASTEXITCODE
if ($driverExit -ne 0) {
    [pscustomobject]@{stage='driver_build';native_exit_code=$driverExit;output=($buildOutput -join [Environment]::NewLine)} | ConvertTo-Json -Compress
    exit $driverExit
}
$output = Join-Path $lab 'out'
$null = New-Item -ItemType Directory -Path $output -Force
$environmentScript = Join-Path $installation 'VC/Auxiliary/Build/vcvarsall.bat'
$client = Join-Path $source 'client/probe.c'
$command = 'call "'+$environmentScript+'" arm64 && cl.exe /nologo /std:c11 /W4 /DWIN32_LEAN_AND_MEAN /D_WIN32_WINNT=0x0A00 /I"'+(Join-Path $source 'shared')+'" "'+$client+'" /Fo"'+(Join-Path $output 'module-x-probe.obj')+'" /Fe"'+(Join-Path $output 'module-x-probe.exe')+'" /link wintrust.lib'
$clientOutput = & $env:ComSpec /d /c $command 2>&1
$clientExit = $LASTEXITCODE
if ($clientExit -ne 0) {
    [pscustomobject]@{stage='collector_build';native_exit_code=$clientExit;output=($clientOutput -join [Environment]::NewLine)} | ConvertTo-Json -Compress
    exit $clientExit
}
$driver = Get-ChildItem (Join-Path $source 'driver/out/ARM64/Release') -Filter '*.sys' | Select-Object -First 1
Copy-Item $driver.FullName (Join-Path $output 'module-x-probe.sys')
$records = @()
foreach ($name in @('module-x-probe.sys','module-x-probe.exe')) {
    $image = Join-Path $output $name
    $bytes = [IO.File]::ReadAllBytes($image)
    $offset = [BitConverter]::ToInt32($bytes,0x3c)
    if ($bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a -or [BitConverter]::ToUInt32($bytes,$offset) -ne 0x00004550) { throw 'A generated binary has invalid PE headers.' }
    $machine = [BitConverter]::ToUInt16($bytes,$offset+4)
    if ($machine -ne 0xaa64) { throw 'A generated binary is not native ARM64.' }
    $records += [pscustomobject]@{artifact_alias=$name;pe_machine=('0x{0:x4}' -f $machine);architecture='ARM64';size_bytes=$bytes.Length;sha256=(Get-FileHash $image -Algorithm SHA256).Hash.ToLowerInvariant()}
}
[pscustomobject]@{captured_at_utc=[DateTime]::UtcNow.ToString('o');native_exit_code=0;driver_build='passed';collector_build='passed';binaries=$records} | ConvertTo-Json -Depth 5 -Compress
