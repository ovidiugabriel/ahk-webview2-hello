# AHK WebView2 Hello World

A minimal AutoHotkey v2 app that hosts an HTML UI in Microsoft Edge WebView2 and passes
messages both ways between JavaScript and AutoHotkey. It talks to WebView2 directly over COM
through `WebView2Loader.dll`: no third-party AutoHotkey libraries.

## Requirements

- Windows 10 or 11 (or Windows Server 2019+), 64-bit
- AutoHotkey v2.0 (64-bit)
- Microsoft Edge WebView2 Runtime (preinstalled on current Windows)
- `lib\WebView2Loader.dll` (x64) from the `Microsoft.Web.WebView2` NuGet package

The repository contains no binaries. `install_deps` downloads them.

## Quick start

```bat
install_deps.cmd
autohotkey main.ahk
```

`install_deps` is safe to re-run. It:

1. installs AutoHotkey v2 with its official installer (pinned version, SHA-256 verified) unless
   it is already installed, and adds its `v2` folder to the user `PATH` so `autohotkey` works
   (open a new terminal afterwards);
2. checks for the WebView2 Runtime and, only if it is missing, runs Microsoft's Evergreen
   bootstrapper after checking its Microsoft signature;
3. extracts the x64 `WebView2Loader.dll` from the pinned NuGet package into `lib\`
   (SHA-256 verified).

Downloads are cached in `%LOCALAPPDATA%\ahk-webview2-hello\cache` and the run is logged to
`logs\install.log`.

Keep the repository at a reasonably short path (for example `C:\src\ahk-webview2-hello`): Windows
PowerShell cannot write paths longer than 260 characters, and `install_deps` stops with a clear
message if `lib\WebView2Loader.dll` would exceed that.

## Testing

```bat
run_test.cmd
```

This runs exactly `autohotkey main.ahk` with `AHK_APP_SELFTEST=1`. In that mode the app checks
that WebView2 starts, `ui\index.html` loads, a message makes a full round trip
(AHK → JS → AHK → JS → AHK), and the rendered page can be captured. It then exits on its own.
The test passes only if the exit code is 0, `logs\app.log` contains `RESULT|SUCCESS`, and there
are no errors.

## Files

| File | Purpose |
|---|---|
| `main.ahk` | Entry point: window, WebView2 setup over COM, JS ↔ AHK bridge, logging, self-test |
| `ui/index.html` | The UI and the page side of the bridge |
| `install_deps.ps1` / `.cmd` | Installs and verifies all dependencies |
| `run_test.ps1` / `.cmd` | Automated self-test of `autohotkey main.ahk` |
| `cleanup.ps1` / `.cmd` | Double-click to close the app and remove generated files (`lib\`, `logs\`, `%LOCALAPPDATA%\ahk-webview2-hello`); source files and installed software are left alone |

## Logs (created at runtime, git-ignored)

| File | Contents |
|---|---|
| `logs/app.log` | App diagnostics: versions, paths, WebView2 init steps, bridge messages, errors, `RESULT\|SUCCESS` or `RESULT\|FAILURE` |
| `logs/ahk_run.log` | Written by `run_test`: command, resolved `AutoHotkey.exe`, AutoHotkey stdout + stderr, exit code, verdict |
| `logs/install.log` | Written by `install_deps` |
| `logs/ui_capture.png` | Image of the rendered page taken during the self-test |

The WebView2 browser profile (caches, settings) lives in
`%LOCALAPPDATA%\ahk-webview2-hello\WebView2`, outside the repository. It is regenerated
automatically and safe to delete, along with the download cache next to it.
