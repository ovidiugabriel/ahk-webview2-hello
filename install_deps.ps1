# Installs everything main.ahk needs. Safe to re-run: anything already present is detected and skipped.
#
#   1. AutoHotkey v2         official installer from autohotkey.com (pinned version, SHA-256 verified),
#                            then its v2 folder is added to the user PATH so `autohotkey main.ahk` works
#   2. WebView2 Runtime      checked; if missing, Microsoft's Evergreen bootstrapper is run
#                            (its Authenticode signature must be valid and from Microsoft)
#   3. lib\WebView2Loader.dll  x64 loader extracted from the Microsoft.Web.WebView2 NuGet package
#                            (pinned version, SHA-256 verified)
#
# Downloads are cached in %LOCALAPPDATA%\ahk-webview2-hello\cache (outside the repo, so deep repo
# locations cannot push paths past Windows PowerShell's 260-character limit), and the whole run is
# logged to logs\install.log.
param(
    [string]$AhkVersion   = '2.0.28',
    [string]$AhkZipSha256 = 'B63BE7548792B4AD0DFE424D91CC69376694ED2F758245B7A75A0C77D693B478',
    [string]$SdkVersion   = '1.0.4258.31',
    [string]$SdkPkgSha256 = '56F7F4B8BF9AEE4B8EFEFBBDD4F67D5F74EBD1B100ED0806DA71BF76AF481AA9'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # only hides the slow progress bar; errors still stop the script
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$root     = $PSScriptRoot
$toolsDir = Join-Path $env:LOCALAPPDATA 'ahk-webview2-hello\cache'
$libDir   = Join-Path $root 'lib'
$logDir   = Join-Path $root 'logs'
$logFile  = Join-Path $logDir 'install.log'
New-Item -ItemType Directory -Force $toolsDir, $libDir, $logDir | Out-Null

function Log([string]$level, [string]$msg) {
    $line = '{0} | {1,-6}| {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $level, $msg
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    Write-Host $line
}

function Get-VerifiedDownload([string]$url, [string]$file, [string]$sha256) {
    if (Test-Path $file) {
        if ((Get-FileHash $file -Algorithm SHA256).Hash -eq $sha256) { Log INFO "Using cached $file"; return }
        Log WARN "Cached $file has the wrong hash; downloading again"
        Remove-Item $file
    }
    Log INFO "Downloading $url"
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $file
    $actual = (Get-FileHash $file -Algorithm SHA256).Hash
    if ($actual -ne $sha256) {
        Remove-Item $file
        throw "SHA-256 mismatch for $url`n  expected $sha256`n  actual   $actual"
    }
    Log INFO "Verified SHA-256 $actual"
}

function Get-AhkInstallDir {
    foreach ($key in 'HKLM:\Software\AutoHotkey', 'HKCU:\Software\AutoHotkey') {
        if (Test-Path $key) {
            $dir = (Get-ItemProperty $key).InstallDir
            if ($dir -and (Test-Path (Join-Path $dir 'v2\AutoHotkey.exe'))) { return $dir }
        }
    }
    return $null
}

function Add-ToUserPath([string]$dir) {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath -and (($userPath -split ';') -contains $dir)) { Log INFO "Already on user PATH: $dir" }
    else {
        $new = if ($userPath) { $userPath.TrimEnd(';') + ';' + $dir } else { $dir }
        [Environment]::SetEnvironmentVariable('Path', $new, 'User')
        Log INFO "Added to user PATH: $dir (open a new terminal to pick it up)"
    }
    if (($env:Path -split ';') -notcontains $dir) { $env:Path = $env:Path.TrimEnd(';') + ';' + $dir }
}

function Install-AutoHotkey {
    $dir = Get-AhkInstallDir
    if ($dir) {
        $ver = (Get-Item (Join-Path $dir 'v2\AutoHotkey.exe')).VersionInfo.FileVersion
        Log INFO "AutoHotkey $ver already installed in $dir"
    } else {
        $zip = Join-Path $toolsDir "AutoHotkey_$AhkVersion.zip"
        Get-VerifiedDownload "https://www.autohotkey.com/download/2.0/AutoHotkey_$AhkVersion.zip" $zip $AhkZipSha256
        $src = Join-Path $toolsDir "AutoHotkey_$AhkVersion"
        if (Test-Path $src) { Remove-Item -Recurse -Force $src }
        Expand-Archive $zip $src
        # The bundled installer: all users when elevated, otherwise the current user only.
        Log INFO "Running the AutoHotkey installer (silent, admin=$(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators')))"
        $p = Start-Process -FilePath (Join-Path $src 'AutoHotkey64.exe') `
                -ArgumentList "`"$(Join-Path $src 'UX\install.ahk')`"", '/silent' -PassThru -Wait
        if ($p.ExitCode -ne 0) { throw "AutoHotkey installer exited with code $($p.ExitCode)" }
        $dir = Get-AhkInstallDir
        if (-not $dir) { throw 'AutoHotkey installer finished but no installation was registered' }
        Log INFO "AutoHotkey installed in $dir"
    }
    Add-ToUserPath (Join-Path $dir 'v2')
    $cmd = Get-Command autohotkey
    Log INFO "autohotkey resolves to $($cmd.Source) (version $((Get-Item $cmd.Source).VersionInfo.FileVersion))"
}

function Get-WebView2Version {
    # Per-machine and per-user registrations of the Evergreen WebView2 Runtime.
    $guid = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
    foreach ($key in "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\$guid",
                     "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\$guid",
                     "HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\$guid") {
        if (Test-Path $key) {
            $pv = (Get-ItemProperty $key).pv
            if ($pv -and $pv -ne '0.0.0.0') { return $pv }
        }
    }
    return $null
}

function Install-WebView2Runtime {
    $ver = Get-WebView2Version
    if ($ver) { Log INFO "WebView2 Runtime $ver already installed"; return }
    $exe = Join-Path $toolsDir 'MicrosoftEdgeWebview2Setup.exe'
    Log INFO 'WebView2 Runtime not found; downloading the Evergreen bootstrapper'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' -OutFile $exe
    $sig = Get-AuthenticodeSignature $exe
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        throw "WebView2 bootstrapper signature check failed: $($sig.Status) $($sig.SignerCertificate.Subject)"
    }
    Log INFO "Bootstrapper signature valid ($($sig.SignerCertificate.Subject))"
    $p = Start-Process -FilePath $exe -ArgumentList '/silent', '/install' -PassThru -Wait
    if ($p.ExitCode -ne 0) { throw "WebView2 bootstrapper exited with code $($p.ExitCode)" }
    $ver = Get-WebView2Version
    if (-not $ver) { throw 'WebView2 bootstrapper finished but the runtime is still not registered' }
    Log INFO "WebView2 Runtime $ver installed"
}

function Install-WebView2Loader {
    $dll = Join-Path $libDir 'WebView2Loader.dll'
    if ((Test-Path $dll) -and (Get-Item $dll).VersionInfo.FileVersion -eq $SdkVersion) {
        Log INFO "lib\WebView2Loader.dll $SdkVersion already present"; return
    }
    $pkg = Join-Path $toolsDir "microsoft.web.webview2.$SdkVersion.nupkg"
    Get-VerifiedDownload "https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$SdkVersion/microsoft.web.webview2.$SdkVersion.nupkg" $pkg $SdkPkgSha256
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($pkg)
    try {
        $entry = $zip.GetEntry('build/native/x64/WebView2Loader.dll')
        if (-not $entry) { throw "build/native/x64/WebView2Loader.dll not found in $pkg" }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dll, $true)
    } finally { $zip.Dispose() }
    Log INFO "Extracted lib\WebView2Loader.dll (version $((Get-Item $dll).VersionInfo.FileVersion))"
}

try {
    Log INFO "Dependency installation started (repo=$root, download cache=$toolsDir)"
    # Fail early with a clear message instead of a confusing "Could not find a part of the path".
    $dllTarget = Join-Path $libDir 'WebView2Loader.dll'
    if ($dllTarget.Length -ge 260) {
        throw "The repository path is too long for Windows PowerShell ($($dllTarget.Length) characters for $dllTarget, limit 259). Move the folder somewhere shorter, e.g. C:\src\ahk-webview2-hello."
    }
    Install-AutoHotkey
    Install-WebView2Runtime
    Install-WebView2Loader
    Log INFO 'All dependencies are installed. Run:  autohotkey main.ahk'
    Add-Content -Path $logFile -Value 'RESULT|SUCCESS' -Encoding UTF8
    exit 0
} catch {
    Log ERROR $_.Exception.Message
    Log ERROR "at $($_.InvocationInfo.PositionMessage -replace '\r?\n', ' ')"
    Add-Content -Path $logFile -Value 'RESULT|FAILURE' -Encoding UTF8
    exit 1
}
