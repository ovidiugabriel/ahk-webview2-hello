# Removes everything install_deps and main.ahk generate, returning the repo to source files only:
#   lib\                                 WebView2Loader.dll fetched by install_deps
#   logs\                                app, test and install logs, UI capture
#   %LOCALAPPDATA%\ahk-webview2-hello    download cache and WebView2 browser profile
# A running instance of this repo's main.ahk is closed first so no file is locked.
# Installed software (AutoHotkey, WebView2 Runtime) and the PATH entry are left alone.
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$mainAhk = Join-Path $root 'main.ahk'

# 1. Close this repo's app: the AutoHotkey process recorded in logs\app.pid (written by main.ahk),
#    plus any AutoHotkey process whose command line has this main.ahk's full path (double-click).
$pidFile = Join-Path $root 'logs\app.pid'
$appPid = if (Test-Path -LiteralPath $pidFile) { [int](Get-Content -LiteralPath $pidFile -Raw).Trim() } else { 0 }
$running = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%'" |
    Where-Object { $_.ProcessId -eq $appPid -or ($_.CommandLine -and $_.CommandLine.Contains($mainAhk)) })
foreach ($proc in $running) {
    Stop-Process -Id $proc.ProcessId -Force
    Write-Host "Closed running app (AutoHotkey pid $($proc.ProcessId))"
}
if ($running.Count) {
    # WebView2 child processes exit with their host; wait for them to release the profile.
    $deadline = (Get-Date).AddSeconds(10)
    do {
        $children = @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" |
            Where-Object { $_.CommandLine -and $_.CommandLine.Contains('ahk-webview2-hello') })
        if ($children.Count) { Start-Sleep -Milliseconds 300 }
    } while ($children.Count -and (Get-Date) -lt $deadline)
    if ($children.Count) { throw "$($children.Count) WebView2 process(es) still hold the profile; close them and run cleanup again" }
}

# 2. Remove generated folders. The \\?\ prefix handles paths over 260 characters.
$targets = @(
    (Join-Path $root 'lib'),
    (Join-Path $root 'logs'),
    (Join-Path $env:LOCALAPPDATA 'ahk-webview2-hello')
)
$removed = 0
foreach ($t in $targets) {
    if (Test-Path -LiteralPath $t) {
        Remove-Item -LiteralPath "\\?\$t" -Recurse -Force
        Write-Host "Removed  $t"
        $removed++
    } else {
        Write-Host "Not found (already clean)  $t"
    }
}
Write-Host ''
Write-Host "Cleanup finished: $removed folder(s) removed."
