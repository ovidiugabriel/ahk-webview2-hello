# Self-test: runs exactly `autohotkey main.ahk` and records the whole AutoHotkey execution
# (stdout, stderr, exit code, duration, verdict) in logs\ahk_run.log.
# The app's own diagnostics go to logs\app.log; this script checks both.
param([int]$TimeoutSec = 60)
$ErrorActionPreference = 'Stop'
$root    = $PSScriptRoot
$logDir  = Join-Path $root 'logs'
$runLog  = Join-Path $logDir 'ahk_run.log'
$appLog  = Join-Path $logDir 'app.log'
$command = 'autohotkey main.ahk'

function Write-RunLog([string]$text) {
    Add-Content -Path $runLog -Value $text -Encoding UTF8
    Write-Output $text
}

New-Item -ItemType Directory -Force $logDir | Out-Null
if (Test-Path $runLog) { Move-Item -Force $runLog (Join-Path $logDir 'ahk_run.prev.log') }

# Use PATH as a freshly opened shell would see it (picks up a just-installed AutoHotkey).
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
$ahk = Get-Command autohotkey   # throws if `autohotkey` is not resolvable
$ver = (Get-Item $ahk.Source).VersionInfo.FileVersion

# Stop leftover instances of this app only (not unrelated AutoHotkey scripts).
$mainPath = Join-Path $root 'main.ahk'
$stale = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%'" |
    Where-Object { $_.CommandLine -and $_.CommandLine.Contains('main.ahk') -and $_.CommandLine.Contains($root) })
foreach ($s in $stale) { Stop-Process -Id $s.ProcessId -Force }

$start = Get-Date
Write-RunLog "==== AutoHotkey execution $($start.ToString('yyyy-MM-dd HH:mm:ss.fff')) ===="
Write-RunLog "command     : $command"
Write-RunLog "resolved to : $($ahk.Source) (version $ver)"
Write-RunLog "working dir : $root"
Write-RunLog "environment : AHK_APP_SELFTEST=1"
Write-RunLog "stale instances stopped: $($stale.Count)"
Write-RunLog "---- AutoHotkey stdout + stderr ----"

# cmd /c waits for the GUI-subsystem AutoHotkey.exe and appends both streams to the run log.
$env:AHK_APP_SELFTEST = '1'
$p = Start-Process -FilePath $env:ComSpec -ArgumentList '/d', '/c', "`"$command >> `"$runLog`" 2>&1`"" `
        -WorkingDirectory $root -WindowStyle Hidden -PassThru
$null = $p.Handle   # cache the handle so ExitCode is available after exit

$timedOut = -not $p.WaitForExit($TimeoutSec * 1000)
if ($timedOut) {
    $hung = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains('main.ahk') -and $_.ParentProcessId -eq $p.Id })
    foreach ($h in $hung) { Stop-Process -Id $h.ProcessId -Force }
    $p.Kill()
}
$exitCode = if ($timedOut) { 'none (killed)' } else { $p.ExitCode }
$duration = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)

# Verdict from runtime evidence only.
$problems = @()
if ($timedOut)                  { $problems += "timed out after $TimeoutSec s" }
elseif ($exitCode -ne 0)        { $problems += "exit code $exitCode" }
if (-not (Test-Path $appLog))   { $problems += 'logs\app.log was not created' }
else {
    $appLines = Get-Content $appLog -Encoding UTF8
    if ($appLines -notcontains 'RESULT|SUCCESS') { $problems += 'RESULT|SUCCESS not found in logs\app.log' }
    if ($appLines -contains 'RESULT|FAILURE')    { $problems += 'RESULT|FAILURE found in logs\app.log' }
    $errs = @($appLines | Where-Object { $_ -match '\| ERROR \|' })
    if ($errs.Count) { $problems += "$($errs.Count) ERROR line(s) in logs\app.log" }
}
# Any AutoHotkey output that is not a structured app log line (e.g. a load-time error on stderr).
$runLines = Get-Content $runLog -Encoding UTF8
$sepIdx   = [array]::IndexOf($runLines, '---- AutoHotkey stdout + stderr ----')
$foreign  = @($runLines | Select-Object -Skip ($sepIdx + 1) |
    Where-Object { $_ -ne '' -and $_ -notmatch '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3} \| ' -and $_ -notmatch '^RESULT\|' })
if ($foreign.Count) { $problems += "$($foreign.Count) unexpected stdout/stderr line(s) (see above)" }

Write-RunLog "---- end of AutoHotkey output ----"
Write-RunLog "exit code   : $exitCode"
Write-RunLog "duration    : $duration s"
if ($problems.Count) {
    foreach ($pr in $problems) { Write-RunLog "problem     : $pr" }
    Write-RunLog 'TEST RESULT : FAILURE'
    exit 1
}
Write-RunLog 'TEST RESULT : SUCCESS'
exit 0
