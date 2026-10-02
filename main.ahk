; Hello World WebView2 demo for AutoHotkey v2 (64-bit).
; Talks to WebView2 directly over COM via lib\WebView2Loader.dll - no third-party AHK libraries.
;
; Usage:  autohotkey main.ahk                      interactive window
;         set AHK_APP_SELFTEST=1 (or pass --selftest) to exit by itself after the bridge test
;         (exit code 0 = success). When stdout/stderr are redirected, every log line is mirrored
;         to stdout and errors to stderr, so the launcher can keep a full execution log.
#Requires AutoHotkey v2.0 64-bit
#SingleInstance Force
#Warn All, StdOut
#ErrorStdOut "UTF-8"   ; load-time/syntax errors go to stderr instead of a blocking dialog

global LOG_DIR := A_ScriptDir "\logs"
global LOG_FILE := LOG_DIR "\app.log"
global LOADER_DLL := A_ScriptDir "\lib\WebView2Loader.dll"
global INDEX_HTML := A_ScriptDir "\ui\index.html"
; Browser profile (caches, settings) in the per-user app-data folder, as Microsoft recommends for
; WebView2 apps: its deep paths would exceed 260 characters inside a deeply nested checkout.
global USER_DATA := EnvGet("LOCALAPPDATA") "\ahk-webview2-hello\WebView2"
global SELFTEST := false
global TIMEOUT_MS := 30000

global App := {gui: 0, env: 0, controller: 0, webview: 0, nonce: "", result: "", tokens: []}
global Handlers := Map()   ; COM handler ptr -> AHK callback (also keeps the handler memory alive)

SELFTEST := EnvGet("AHK_APP_SELFTEST") = "1"
for arg in A_Args
    if (arg = "--selftest")
        SELFTEST := true

; stdout/stderr exist only when the launcher redirected them (AutoHotkey is a GUI-subsystem exe).
global HAS_STDOUT := HasStdHandle(-11)
global HAS_STDERR := HasStdHandle(-12)

LogInit()
OnError(OnUnhandledError)
OnExit(OnAppExit)
Main()
return

; ---------------------------------------------------------------- logging

LogInit() {
    DirCreate(LOG_DIR)
    if FileExist(LOG_FILE)
        FileMove(LOG_FILE, LOG_DIR "\app.prev.log", true)
    ; Lets cleanup.ps1 find this instance even when it was started with a relative path.
    FileOpen(LOG_DIR "\app.pid", "w").Write(ProcessExist())
}

HasStdHandle(id) {
    h := DllCall("GetStdHandle", "int", id, "ptr")
    return h != 0 && h != -1
}

Log(level, msg) {
    WriteLogLine(FormatTime(, "yyyy-MM-dd HH:mm:ss") "." Format("{:03}", A_MSec) " | " Format("{:-6}", level) "| " msg)
}

; Another process (an editor, a tail, a test harness) may briefly hold app.log without write
; sharing, so retry for up to ~1 s. A write that still fails is reported on stderr with the
; actual error rather than being dropped.
WriteLogLine(line) {
    if HAS_STDOUT
        FileAppend(line "`n", "*", "UTF-8")
    lastErr := ""
    loop 20 {
        try {
            FileAppend(line "`n", LOG_FILE, "UTF-8")
            return true
        } catch as e {
            lastErr := e.Message
        }
        Sleep(50)
    }
    ReportStdErr("app.log write failed (" lastErr "): " line)
    return false
}

ReportStdErr(text) {
    if HAS_STDERR
        FileAppend(text "`n", "**", "UTF-8")
    else
        OutputDebug(text)
}

SetResult(ok, reason) {
    if (App.result != "")
        return
    App.result := ok ? "SUCCESS" : "FAILURE"
    SetTimer(OnTimeout, 0)
    Log(ok ? "INFO" : "ERROR", reason)
    ; Unambiguous marker line, exactly "RESULT|SUCCESS" or "RESULT|FAILURE".
    WriteLogLine("RESULT|" App.result)
    if SELFTEST
        SetTimer(() => ExitApp(ok ? 0 : 1), -2500)   ; leave the window up briefly so it can be observed
}

OnUnhandledError(err, mode) {
    summary := "Unhandled " Type(err) ": " err.Message " | what=" err.What " | file=" err.File ":" err.Line
    ReportStdErr(summary "`n" err.Stack)
    Log("ERROR", summary)
    Log("ERROR", "Stack: " StrReplace(Trim(StrReplace(err.Stack, "`r"), "`n"), "`n", " <- "))
    SetResult(false, "Unhandled exception")
    if !SELFTEST   ; interactive run: say what went wrong instead of disappearing silently
        MsgBox(err.Message "`n`nSee " LOG_FILE " for details."
            . (InStr(err.Message, "WebView2Loader.dll") ? "`n`nRun install_deps.cmd first." : "")
            , "AHK WebView2 Hello World - error", "Iconx")
    ExitApp(1)
}

OnAppExit(reason, code) {
    if (App.result = "")
        SetResult(false, "Exited before the bridge test completed (reason=" reason ")")
    Log("INFO", "Application shutdown (reason=" reason ", exitCode=" code ")")
    if FileExist(LOG_DIR "\app.pid")
        FileDelete(LOG_DIR "\app.pid")
    if App.controller {
        try {
            ComCall(24, App.controller)   ; ICoreWebView2Controller::Close
            Log("INFO", "WebView2 controller closed")
        } catch as e {
            Log("ERROR", "WebView2 controller Close failed: " e.Message)
        }
    }
}

OnTimeout() {
    Log("ERROR", "Timed out after " TIMEOUT_MS " ms; state: env=" (App.env ? "ok" : "none") " controller=" (App.controller ? "ok" : "none") " webview=" (App.webview ? "ok" : "none"))
    SetResult(false, "Timeout waiting for the bridge round trip")
}

; ---------------------------------------------------------------- startup

Main() {
    Log("INFO", "Application starting (selftest=" (SELFTEST ? "yes" : "no") ")")
    Log("INFO", "AutoHotkey " A_AhkVersion " | " (A_PtrSize * 8) "-bit | exe=" A_AhkPath)
    Log("INFO", "OS " A_OSVersion " | user=" A_UserName " | admin=" (A_IsAdmin ? "yes" : "no"))
    Log("INFO", "Script dir=" A_ScriptDir " | working dir=" A_WorkingDir)

    for label, path in Map("WebView2Loader.dll", LOADER_DLL, "index.html", INDEX_HTML)
        if !FileExist(path)
            throw Error("Required file missing: " label " (" path ")")
    Log("INFO", "Found " LOADER_DLL " (version " FileGetVersion(LOADER_DLL) ")")
    Log("INFO", "Found " INDEX_HTML)

    hLoader := DllCall("LoadLibrary", "str", LOADER_DLL, "ptr")
    if !hLoader
        throw OSError(A_LastError, , "LoadLibrary " LOADER_DLL)
    Log("INFO", "WebView2Loader.dll loaded")

    pVer := 0
    hr := DllCall("WebView2Loader\GetAvailableCoreWebView2BrowserVersionString", "ptr", 0, "ptr*", &pVer, "int")
    if (hr != 0 || !pVer)
        throw Error(Format("WebView2 Runtime not found (hr=0x{:08X})", hr & 0xFFFFFFFF))
    Log("INFO", "WebView2 Runtime version " StrGet(pVer, "UTF-16"))
    DllCall("ole32\CoTaskMemFree", "ptr", pVer)

    g := Gui("+Resize +MinSize400x300", "AHK WebView2 Hello World")
    g.OnEvent("Close", (*) => ExitApp(App.result = "SUCCESS" ? 0 : 1))
    g.OnEvent("Size", OnGuiSize)
    g.Show("w900 h600")
    App.gui := g
    Log("INFO", Format("Window created hwnd=0x{:X}", g.Hwnd))

    SetTimer(OnTimeout, -TIMEOUT_MS)
    DirCreate(USER_DATA)
    Log("INFO", "WebView2 initialization started (userDataFolder=" USER_DATA ")")
    hr := DllCall("WebView2Loader\CreateCoreWebView2EnvironmentWithOptions"
        , "ptr", 0, "wstr", USER_DATA, "ptr", 0, "ptr", NewHandler(OnEnvironmentCreated), "int")
    if (hr != 0)
        throw Error(Format("CreateCoreWebView2EnvironmentWithOptions failed hr=0x{:08X}", hr & 0xFFFFFFFF))
}

OnEnvironmentCreated(hr, pEnv) {
    if (hr != 0 || !pEnv)
        throw Error(Format("WebView2 environment creation failed hr=0x{:08X}", hr & 0xFFFFFFFF))
    ComCall(1, pEnv, "uint")   ; AddRef: keep it beyond this callback
    App.env := pEnv
    Log("INFO", "WebView2 environment created")
    ; ICoreWebView2Environment::CreateCoreWebView2Controller(parentHwnd, handler)
    ComCall(3, pEnv, "ptr", App.gui.Hwnd, "ptr", NewHandler(OnControllerCreated))
}

OnControllerCreated(hr, pController) {
    if (hr != 0 || !pController)
        throw Error(Format("Failed to create WebView2 controller hr=0x{:08X}", hr & 0xFFFFFFFF))
    ComCall(1, pController, "uint")
    App.controller := pController
    Log("INFO", "WebView2 controller created")

    ComCall(25, pController, "ptr*", &pWebView := 0)   ; get_CoreWebView2 (already AddRef'd for us)
    App.webview := pWebView
    ResizeWebView()

    ComCall(3, pWebView, "ptr*", &pSettings := 0)      ; get_Settings
    ComCall(6, pSettings, "int", 1)                    ; put_IsWebMessageEnabled(TRUE)
    ComCall(2, pSettings, "uint")                      ; Release

    App.tokens.Push(AddEvent(pWebView, 15, OnNavigationCompleted))   ; add_NavigationCompleted
    App.tokens.Push(AddEvent(pWebView, 34, OnWebMessageReceived))    ; add_WebMessageReceived
    Log("INFO", "WebView2 initialization complete; event handlers registered")

    uri := "file:///" StrReplace(INDEX_HTML, "\", "/")
    Log("INFO", "Navigating to " uri)
    ComCall(5, pWebView, "wstr", uri)                  ; Navigate
}

OnNavigationCompleted(pSender, pArgs) {
    ComCall(3, pArgs, "int*", &ok := 0)                ; get_IsSuccess
    ComCall(4, pArgs, "int*", &status := 0)            ; get_WebErrorStatus
    if !ok {
        Log("ERROR", "Navigation failed, WebErrorStatus=" status)
        SetResult(false, "index.html failed to load")
        return
    }
    Log("INFO", "Navigation completed: index.html loaded")
    App.nonce := Format("{:08X}", Random(0, 0x7FFFFFFF))
    Log("INFO", "Bridge test: AHK -> JS hello nonce=" App.nonce)
    PostToJs("hello|" App.nonce)
}

OnWebMessageReceived(pSender, pArgs) {
    pStr := 0
    ComCall(5, pArgs, "ptr*", &pStr)                   ; TryGetWebMessageAsString
    msg := StrGet(pStr, "UTF-16")
    DllCall("ole32\CoTaskMemFree", "ptr", pStr)
    Log("EVENT", "JS -> AHK: " msg)

    parts := StrSplit(msg, "|")
    switch parts[1] {
        case "ready":
            Log("INFO", "Page script initialized; JS bridge present")
        case "ping":
            if (parts.Length < 3 || parts[2] != App.nonce) {
                SetResult(false, "Bridge ping carried wrong nonce: " msg)
                return
            }
            Log("INFO", "UI report from page: visibility,size=" parts[3] " protocol=" (parts.Length >= 4 ? parts[4] : "?"))
            PostToJs("pong|" App.nonce)
        case "ack":
            if (parts.Length >= 2 && parts[2] = App.nonce) {
                Log("INFO", "Bridge round trip verified (AHK -> JS -> AHK -> JS -> AHK), nonce=" App.nonce)
                CaptureUi()
            } else
                SetResult(false, "Bridge ack carried wrong nonce: " msg)
        case "click":
            MsgBox "AHK running"
            PostToJs("reply|Hello from AutoHotkey " A_AhkVersion " (click #" parts[2] " at " FormatTime(, "HH:mm:ss") ")")
        default:
            Log("WARN", "Unknown message from JS: " msg)
    }
}

; Final check: have WebView2 render the visible page to logs\ui_capture.png, proving the UI is drawn.
CaptureUi() {
    static path := LOG_DIR "\ui_capture.png"
    if FileExist(path)
        FileDelete(path)
    hr := DllCall("shlwapi\SHCreateStreamOnFileEx", "wstr", path, "uint", 0x1001   ; STGM_CREATE|STGM_WRITE
        , "uint", 0x80, "int", 1, "ptr", 0, "ptr*", &pStream := 0, "int")
    if (hr != 0)
        throw Error(Format("SHCreateStreamOnFileEx failed hr=0x{:08X}", hr & 0xFFFFFFFF))
    Log("INFO", "Capturing rendered UI to " path)
    ; ICoreWebView2::CapturePreview(COREWEBVIEW2_CAPTURE_PREVIEW_IMAGE_FORMAT_PNG, stream, handler)
    ComCall(30, App.webview, "int", 0, "ptr", pStream, "ptr", NewHandler(OnCaptured.Bind(pStream, path)))
}

OnCaptured(pStream, path, hr, *) {
    ObjRelease(pStream)   ; flushes and closes the file
    size := FileExist(path) ? FileGetSize(path) : 0
    if (hr != 0 || size = 0) {
        SetResult(false, Format("UI capture failed hr=0x{:08X} size={}", hr & 0xFFFFFFFF, size))
        return
    }
    Log("INFO", "UI capture written (" size " bytes so far; WebView2 finishes flushing after releasing the stream)")
    SetResult(true, "WebView2 UI rendered and JS <-> AHK bridge verified, nonce=" App.nonce)
}

PostToJs(text) {
    ComCall(33, App.webview, "wstr", text)             ; PostWebMessageAsString
}

OnGuiSize(*) {
    if App.controller
        ResizeWebView()
}

ResizeWebView() {
    rc := Buffer(16, 0)
    DllCall("GetClientRect", "ptr", App.gui.Hwnd, "ptr", rc)
    ComCall(6, App.controller, "ptr", rc)              ; put_Bounds (RECT by value = pointer on x64)
}

; ---------------------------------------------------------------- minimal COM handler objects
; Every WebView2 completion/event handler is an IUnknown with a single Invoke(this, a, b) method,
; so one shared vtable serves all of them; Invoke dispatches on the object pointer.

NewHandler(callback) {
    static vtbl := 0
    if !vtbl {
        vtbl := Buffer(4 * A_PtrSize)
        NumPut("ptr", CallbackCreate(Handler_QueryInterface, , 3)
             , "ptr", CallbackCreate(Handler_AddRef, , 1)
             , "ptr", CallbackCreate(Handler_Release, , 1)
             , "ptr", CallbackCreate(Handler_Invoke, , 3), vtbl)
    }
    obj := Buffer(A_PtrSize * 2, 0)
    NumPut("ptr", vtbl.Ptr, obj)
    Handlers[obj.Ptr] := {buf: obj, fn: callback}
    return obj.Ptr
}

AddEvent(pTarget, vtIndex, callback) {
    ComCall(vtIndex, pTarget, "ptr", NewHandler(callback), "int64*", &token := 0)
    return token
}

Handler_QueryInterface(pThis, riid, ppv) {
    NumPut("ptr", pThis, ppv)   ; the caller only asks for IUnknown or the handler's own interface
    return 0
}
Handler_AddRef(pThis) => 1      ; lifetime is owned by the Handlers map
Handler_Release(pThis) => 1

Handler_Invoke(pThis, a, b) {
    try {
        Handlers[pThis].fn.Call(a, b)
    } catch as err {
        OnUnhandledError(err, "Handler")
    }
    return 0
}
