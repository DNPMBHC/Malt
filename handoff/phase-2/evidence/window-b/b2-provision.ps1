$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$lab = Join-Path $env:SystemDrive 'lab-b2'
$packages = Join-Path $lab 'toolchain'
$null = New-Item -ItemType Directory -Path $packages -Force
$roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
$vswhere = $roots | ForEach-Object { Join-Path $_ 'Microsoft Visual Studio/Installer/vswhere.exe' } | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $vswhere) { throw 'The Visual Studio installation locator is missing.' }
$installation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.ARM64 -property installationPath
if (-not $installation) { throw 'ARM64 C++ Build Tools are not installed.' }
$component = 'Component.Microsoft.Windows.DriverKit.BuildTools'
$present = [bool](& $vswhere -latest -products '*' -requires $component -property installationVersion)
$extensionExit = 0
if (-not $present) {
    $setup = Join-Path (Split-Path $vswhere) 'setup.exe'
    $process = Start-Process -FilePath $setup -ArgumentList @('modify','--installPath',('"'+$installation+'"'),'--add',$component,'--quiet','--norestart') -PassThru -Wait
    $extensionExit = $process.ExitCode
    if ($extensionExit -notin @(0,3010)) { throw "The official build extension installer returned $extensionExit." }
}
$version = '10.0.26100.6584'
$records = @()
Add-Type -AssemblyName System.IO.Compression.FileSystem
foreach ($name in @('Microsoft.Windows.SDK.cpp','Microsoft.Windows.SDK.cpp.ARM64','Microsoft.Windows.WDK.ARM64')) {
    $archive = Join-Path $packages ($name + '.' + $version + '.nupkg')
    $destination = Join-Path $packages ($name + '.' + $version)
    if (-not (Test-Path $archive)) {
        $url = 'https://api.nuget.org/v3-flatcontainer/' + $name.ToLowerInvariant() + '/' + $version + '/' + $name.ToLowerInvariant() + '.' + $version + '.nupkg'
        Invoke-WebRequest -Uri $url -OutFile $archive -UseBasicParsing
    }
    if (-not (Test-Path $destination)) {
        [IO.Compression.ZipFile]::ExtractToDirectory($archive, $destination)
    }
    $records += [pscustomobject]@{package=$name;version=$version;archive_bytes=(Get-Item $archive).Length;sha256=(Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant();expanded=$true}
}
[pscustomobject]@{
    captured_at_utc=[DateTime]::UtcNow.ToString('o')
    extension_native_exit_code=$extensionExit
    extension_installed=[bool](& $vswhere -latest -products '*' -requires $component -property installationVersion)
    arm64_compiler_present=(Test-Path (Join-Path $installation 'VC/Tools/MSVC'))
    packages=$records
    system_free_bytes=(Get-CimInstance Win32_LogicalDisk | Where-Object DeviceID -eq $env:SystemDrive).FreeSpace
} | ConvertTo-Json -Depth 6 -Compress
