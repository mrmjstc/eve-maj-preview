const std = @import("std");

pub const BOOL = c_int;
pub const BYTE = u8;
pub const WORD = u16;
pub const DWORD = u32;
pub const UINT = c_uint;
pub const INT = c_int;
pub const LONG = c_long;
pub const LPARAM = isize;
pub const WPARAM = usize;
pub const LRESULT = isize;
pub const HANDLE = *anyopaque;
pub const HWND = HANDLE;
pub const HDC = HANDLE;
pub const HINSTANCE = HANDLE;
pub const HICON = HANDLE;
pub const HCURSOR = HANDLE;
pub const HBRUSH = HANDLE;
pub const HMENU = HANDLE;
pub const HFONT = HANDLE;
pub const HPEN = HANDLE;
pub const HBITMAP = HANDLE;
pub const HTHUMBNAIL = HANDLE;
pub const HMODULE = HANDLE;
pub const HKEY = HANDLE;
pub const LPVOID = ?*anyopaque;
pub const LPCSTR = [*:0]const u8;
pub const LPSTR = [*:0]u8;

pub const WS_OVERLAPPEDWINDOW = 0x00CF0000;
pub const WS_VISIBLE = 0x10000000;
pub const WS_CHILD = 0x40000000;
pub const WS_POPUP = 0x80000000;
pub const WS_CAPTION = 0x00C00000;
pub const WS_SYSMENU = 0x00080000;
pub const WS_THICKFRAME = 0x00040000;
pub const WS_MINIMIZEBOX = 0x00020000;
pub const WS_MAXIMIZEBOX = 0x00010000;

pub const WS_EX_TOPMOST = 0x00000008;
pub const WS_EX_TRANSPARENT = 0x00000020;
pub const WS_EX_TOOLWINDOW = 0x00000080;
pub const WS_EX_LAYERED = 0x00080000;
pub const WS_EX_NOACTIVATE = 0x08000000;

pub const WM_DESTROY = 0x0002;
pub const WM_MOVE = 0x0003;
pub const WM_MOVING = 0x0216;
pub const WM_ACTIVATE = 0x0006;
pub const WM_SETFOCUS = 0x0007;
pub const WM_KILLFOCUS = 0x0008;
pub const WM_PAINT = 0x000F;
pub const WM_CLOSE = 0x0010;
pub const WM_QUIT = 0x0012;
pub const WM_ERASEBKGND = 0x0014;
pub const WM_NCHITTEST = 0x0084;
pub const WM_TIMER = 0x0113;
pub const WM_KEYDOWN = 0x0100;
pub const WM_KEYUP = 0x0101;
pub const WM_SYSKEYDOWN = 0x0104;
pub const WM_SYSKEYUP = 0x0105;
pub const WM_LBUTTONDOWN = 0x0201;
pub const WM_LBUTTONUP = 0x0202;
pub const WM_LBUTTONDBLCLK = 0x0203;
pub const WM_MOUSEMOVE = 0x0200;
pub const WM_RBUTTONDOWN = 0x0204;
pub const WM_RBUTTONUP = 0x0205;
pub const WM_MOUSEWHEEL = 0x020A;
pub const WM_XBUTTONDOWN = 0x020B;
pub const WM_XBUTTONUP = 0x020C;
pub const WM_ENTERSIZEMOVE = 0x0231;
pub const WM_EXITSIZEMOVE = 0x0232;
pub const WM_HOTKEY = 0x0312;
pub const WM_DPICHANGED = 0x02E0;
pub const WM_DWMSENDICONICTHUMBNAIL = 0x0323;
pub const WM_DWMSENDICONICLIVEPREVIEWBITMAP = 0x0326;
pub const WM_COPYDATA = 0x004A;
pub const WM_USER = 0x0400;
pub const WM_APP = 0x8000;
pub const WM_TRAYICON = WM_USER + 1;
pub const WM_SWITCH_PROFILE = WM_APP + 4;
pub const WM_PROTOCOL_HOTKEY = WM_APP + 7;
pub const WM_HOTKEYS_STATE_CHANGED = WM_APP + 12;
pub const WM_TOGGLE_VISIBILITY = WM_APP + 13;
pub const WM_COMMAND = 0x0111;

pub const PROTOCOL_SWITCH_CHARACTER: usize = 1;
pub const PROTOCOL_SWITCH_PROFILE: usize = 2;
pub const PROTOCOL_PREVIEW_THUMBNAIL: usize = 3;
pub const PROTOCOL_REVERT_PREVIEW: usize = 4;
pub const PROTOCOL_DIALOG_SUSPEND_HOTKEYS: usize = 5;
pub const PROTOCOL_DIALOG_RESUME_HOTKEYS: usize = 6;

pub const SPI_GETANIMATION = 0x0048;
pub const SPI_SETANIMATION = 0x0049;
pub const SPIF_SENDCHANGE = 0x0002;

pub const CW_USEDEFAULT = @as(c_int, @bitCast(@as(c_uint, 0x80000000)));
pub const COLOR_WINDOW = 5;
pub const SW_HIDE = 0;
pub const SW_SHOWNOACTIVATE = 4;
pub const SW_SHOW = 5;
pub const SW_MINIMIZE = 6;
pub const SW_SHOWMINIMIZED = 2;
pub const SW_SHOWMAXIMIZED = 3;
pub const SW_RESTORE = 9;
pub const SW_FORCEMINIMIZE = 11;
pub const TRUE = 1;
pub const FALSE = 0;
pub const DWM_TNP_VISIBLE = 0x8;
pub const DWM_TNP_RECTDESTINATION = 0x1;
pub const DWM_TNP_RECTSOURCE = 0x2;
pub const DWM_TNP_OPACITY = 0x4;
pub const DWM_TNP_SOURCECLIENTAREAONLY = 0x10;

pub const INVALID_HANDLE_VALUE = @as(HANDLE, @ptrFromInt(@as(usize, @bitCast(@as(isize, -1)))));
pub const FILE_NOTIFY_CHANGE_FILE_NAME = 0x00000001;
pub const FILE_NOTIFY_CHANGE_LAST_WRITE = 0x00000010;
pub const WAIT_OBJECT_0 = 0x00000000;
pub const WAIT_TIMEOUT = 0x00000102;

pub const HWND_TOP: HWND = @ptrFromInt(0);
pub const HWND_BOTTOM: HWND = @ptrFromInt(1);
pub const HWND_TOPMOST: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
pub const HWND_NOTOPMOST: HWND = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));
pub const SWP_NOSIZE = 0x0001;
pub const SWP_NOMOVE = 0x0002;
pub const SWP_NOZORDER = 0x0004;
pub const SWP_NOREDRAW = 0x0008;
pub const SWP_NOACTIVATE = 0x0010;
pub const SWP_SHOWWINDOW = 0x0040;

pub const GWLP_USERDATA = -21;
pub const GWL_EXSTYLE = -20;

pub const IDC_ARROW: LPCSTR = @ptrFromInt(32512);

pub const PROCESS_QUERY_INFORMATION = 0x0400;
pub const PROCESS_VM_READ = 0x0010;
pub const PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
pub const PROCESS_TERMINATE = 0x0001;

pub const ERROR_ALREADY_EXISTS = 183;

pub const INFINITE = 0xFFFFFFFF;

pub const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
pub const KEY_WRITE: DWORD = 0x20006;
pub const KEY_READ: DWORD = 0x20019;
pub const REG_SZ: DWORD = 1;
pub const REG_OPTION_NON_VOLATILE: DWORD = 0;
pub const ERROR_SUCCESS: LONG = 0;

pub const POINT = extern struct {
    x: LONG,
    y: LONG,
};
pub const WINDOWPLACEMENT = extern struct {
    length: UINT,
    flags: UINT,
    showCmd: UINT,
    ptMinPosition: POINT,
    ptMaxPosition: POINT,
    rcNormalPosition: RECT,
};

pub const ANIMATIONINFO = extern struct {
    cbSize: UINT,
    iMinAnimate: INT,
};

/// Payload for a WH_MOUSE_LL hook callback (see SetWindowsHookExA below)
pub const MSLLHOOKSTRUCT = extern struct {
    pt: POINT,
    mouseData: DWORD,
    flags: DWORD,
    time: DWORD,
    dwExtraInfo: usize,
};

/// Payload for a WH_KEYBOARD_LL hook callback (see SetWindowsHookExA below)
pub const KBDLLHOOKSTRUCT = extern struct {
    vkCode: DWORD,
    scanCode: DWORD,
    flags: DWORD,
    time: DWORD,
    dwExtraInfo: usize,
};
/// KBDLLHOOKSTRUCT.flags bit set when the event was synthesized (e.g. SendInput)
/// rather than coming from a physical keypress.
pub const LLKHF_INJECTED: DWORD = 0x00000010;
/// nCode value meaning a WH_KEYBOARD_LL/WH_MOUSE_LL hook must process the event
pub const HC_ACTION: c_int = 0;
pub const RECT = extern struct {
    left: LONG,
    top: LONG,
    right: LONG,
    bottom: LONG,
};

pub fn rectWidth(rect: RECT) LONG {
    return rect.right - rect.left;
}

pub fn rectHeight(rect: RECT) LONG {
    return rect.bottom - rect.top;
}

pub const MSG = extern struct {
    hwnd: ?HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
};

pub const COPYDATASTRUCT = extern struct {
    dwData: usize,
    cbData: DWORD,
    lpData: ?*const anyopaque,
};

pub const WNDCLASSEXA = extern struct {
    cbSize: UINT,
    style: UINT,
    lpfnWndProc: *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.c) LRESULT,
    cbClsExtra: c_int,
    cbWndExtra: c_int,
    hInstance: HINSTANCE,
    hIcon: ?HICON,
    hCursor: ?HCURSOR,
    hbrBackground: ?HBRUSH,
    lpszMenuName: ?LPCSTR,
    lpszClassName: LPCSTR,
    hIconSm: ?HICON,
};

pub const PAINTSTRUCT = extern struct {
    hdc: HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]BYTE,
};

pub const DWM_THUMBNAIL_PROPERTIES = extern struct {
    dwFlags: DWORD,
    rcDestination: RECT,
    rcSource: RECT,
    opacity: BYTE,
    fVisible: BOOL,
    fSourceClientAreaOnly: BOOL,
};

pub const WNDENUMPROC = *const fn (HWND, LPARAM) callconv(.c) BOOL;

pub extern "user32" fn GetMessageA(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT) callconv(.c) BOOL;
pub extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.c) BOOL;
pub extern "user32" fn DispatchMessageA(lpMsg: *const MSG) callconv(.c) LRESULT;
pub extern "user32" fn PostQuitMessage(nExitCode: c_int) callconv(.c) void;
pub extern "user32" fn PostMessageA(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.c) BOOL;
pub extern "user32" fn DefWindowProcA(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.c) LRESULT;
pub extern "user32" fn RegisterClassExA(lpWndClass: *const WNDCLASSEXA) callconv(.c) WORD;
pub extern "user32" fn CreateWindowExA(
    dwExStyle: DWORD,
    lpClassName: LPCSTR,
    lpWindowName: LPCSTR,
    dwStyle: DWORD,
    X: c_int,
    Y: c_int,
    nWidth: c_int,
    nHeight: c_int,
    hWndParent: ?HWND,
    hMenu: ?HMENU,
    hInstance: HINSTANCE,
    lpParam: LPVOID,
) callconv(.c) ?HWND;
pub extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: c_int) callconv(.c) BOOL;
pub extern "user32" fn ShowWindowAsync(hWnd: HWND, nCmdShow: c_int) callconv(.c) BOOL;
pub extern "user32" fn UpdateWindow(hWnd: HWND) callconv(.c) BOOL;
pub extern "user32" fn SystemParametersInfoA(uiAction: UINT, uiParam: UINT, pvParam: ?*anyopaque, fWinIni: UINT) callconv(.c) BOOL;
pub extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.c) BOOL;
pub extern "user32" fn SetForegroundWindow(hWnd: HWND) callconv(.c) BOOL;
pub extern "user32" fn GetForegroundWindow() callconv(.c) ?HWND;
pub extern "user32" fn FindWindowA(lpClassName: ?[*:0]const u8, lpWindowName: ?[*:0]const u8) callconv(.c) ?HWND;
pub extern "user32" fn SendMessageA(hWnd: HWND, Msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.c) LRESULT;

pub extern "kernel32" fn CreateMutexW(lpMutexAttributes: ?*anyopaque, bInitialOwner: BOOL, lpName: [*:0]const u16) callconv(.c) ?HANDLE;
pub extern "kernel32" fn ReleaseMutex(hMutex: HANDLE) callconv(.c) BOOL;
pub extern "kernel32" fn GetLastError() callconv(.c) DWORD;

// ContextRecord is left opaque - the arch-specific CONTEXT layout is never read here.
pub const EXCEPTION_MAXIMUM_PARAMETERS = 15;
pub const EXCEPTION_RECORD = extern struct {
    ExceptionCode: DWORD,
    ExceptionFlags: DWORD,
    ExceptionRecord: ?*EXCEPTION_RECORD,
    ExceptionAddress: ?*anyopaque,
    NumberParameters: DWORD,
    ExceptionInformation: [EXCEPTION_MAXIMUM_PARAMETERS]usize,
};
pub const EXCEPTION_POINTERS = extern struct {
    ExceptionRecord: ?*EXCEPTION_RECORD,
    ContextRecord: ?*anyopaque,
};
pub const EXCEPTION_CONTINUE_SEARCH: LONG = 0;
pub const TopLevelExceptionFilter = *const fn (*EXCEPTION_POINTERS) callconv(.c) LONG;
pub extern "kernel32" fn SetUnhandledExceptionFilter(lpTopLevelExceptionFilter: ?TopLevelExceptionFilter) callconv(.c) ?TopLevelExceptionFilter;

pub const ULONG = u32;
// AddVectoredExceptionHandler sees first-chance exceptions before Zig's own segfault handler
// swallows and rethrows them as a breakpoint, so it's the only way to log the real fault address.
pub extern "kernel32" fn AddVectoredExceptionHandler(First: ULONG, Handler: ?TopLevelExceptionFilter) callconv(.c) ?*anyopaque;

pub const EXCEPTION_DATATYPE_MISALIGNMENT: DWORD = 0x80000002;
pub const EXCEPTION_ACCESS_VIOLATION: DWORD = 0xc0000005;
pub const EXCEPTION_ILLEGAL_INSTRUCTION: DWORD = 0xc000001d;
pub const EXCEPTION_STACK_OVERFLOW: DWORD = 0xc00000fd;

pub extern "kernel32" fn GetCurrentProcess() callconv(.c) HANDLE;
pub extern "kernel32" fn GetCurrentProcessId() callconv(.c) DWORD;
pub extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?HANDLE,
) callconv(.c) HANDLE;
pub const GENERIC_WRITE: DWORD = 0x40000000;
pub const FILE_SHARE_READ: DWORD = 0x00000001;
pub const CREATE_ALWAYS: DWORD = 2;
pub const FILE_ATTRIBUTE_NORMAL: DWORD = 0x80;

pub const MINIDUMP_EXCEPTION_INFORMATION = extern struct {
    ThreadId: DWORD,
    ExceptionPointers: ?*EXCEPTION_POINTERS,
    ClientPointers: BOOL,
};
// MiniDumpNormal: stack traces for all threads, no full memory contents.
pub const MiniDumpNormal: DWORD = 0x00000000;
pub extern "dbghelp" fn MiniDumpWriteDump(
    hProcess: HANDLE,
    ProcessId: DWORD,
    hFile: HANDLE,
    DumpType: DWORD,
    ExceptionParam: ?*MINIDUMP_EXCEPTION_INFORMATION,
    UserStreamParam: ?*anyopaque,
    CallbackParam: ?*anyopaque,
) callconv(.c) BOOL;

pub extern "kernel32" fn SetCurrentDirectoryA(lpPathName: LPCSTR) callconv(.c) BOOL;
pub extern "advapi32" fn RegCreateKeyExA(
    hKey: HKEY,
    lpSubKey: LPCSTR,
    Reserved: DWORD,
    lpClass: ?LPCSTR,
    dwOptions: DWORD,
    samDesired: DWORD,
    lpSecurityAttributes: ?*anyopaque,
    phkResult: *HKEY,
    lpdwDisposition: ?*DWORD,
) callconv(.c) LONG;
pub extern "advapi32" fn RegSetValueExA(
    hKey: HKEY,
    lpValueName: ?LPCSTR,
    Reserved: DWORD,
    dwType: DWORD,
    lpData: [*]const u8,
    cbData: DWORD,
) callconv(.c) LONG;
pub extern "advapi32" fn RegOpenKeyExA(
    hKey: HKEY,
    lpSubKey: LPCSTR,
    ulOptions: DWORD,
    samDesired: DWORD,
    phkResult: *HKEY,
) callconv(.c) LONG;
pub extern "advapi32" fn RegCloseKey(hKey: HKEY) callconv(.c) LONG;
pub extern "advapi32" fn RegDeleteTreeA(hKey: HKEY, lpSubKey: ?LPCSTR) callconv(.c) LONG;
pub extern "advapi32" fn RegDeleteValueA(hKey: HKEY, lpValueName: ?LPCSTR) callconv(.c) LONG;
pub extern "user32" fn BringWindowToTop(hWnd: HWND) callconv(.c) BOOL;
pub extern "user32" fn SetFocus(hWnd: HWND) callconv(.c) ?HWND;
pub extern "user32" fn GetWindowPlacement(hWnd: HWND, lpwndpl: *WINDOWPLACEMENT) callconv(.c) BOOL;
pub extern "user32" fn AttachThreadInput(idAttach: DWORD, idAttachTo: DWORD, fAttach: BOOL) callconv(.c) BOOL;
pub extern "user32" fn GetCurrentThreadId() callconv(.c) DWORD;
pub extern "user32" fn IsWindow(hWnd: HWND) callconv(.c) BOOL;
pub extern "user32" fn IsIconic(hWnd: HWND) callconv(.c) BOOL;
pub extern "user32" fn GetWindowTextA(hWnd: HWND, lpString: LPSTR, nMaxCount: c_int) callconv(.c) c_int;
pub extern "user32" fn GetWindowTextLengthA(hWnd: HWND) callconv(.c) c_int;
pub extern "user32" fn GetWindowThreadProcessId(hWnd: HWND, lpdwProcessId: ?*DWORD) callconv(.c) DWORD;
pub extern "user32" fn IsWindowVisible(hWnd: HWND) callconv(.c) BOOL;
pub extern "user32" fn GetClassNameA(hWnd: HWND, lpClassName: LPSTR, nMaxCount: c_int) callconv(.c) c_int;
pub extern "user32" fn EnumWindows(lpEnumFunc: WNDENUMPROC, lParam: LPARAM) callconv(.c) BOOL;
pub extern "user32" fn BeginPaint(hWnd: HWND, lpPaint: *PAINTSTRUCT) callconv(.c) ?HDC;
pub extern "user32" fn EndPaint(hWnd: HWND, lpPaint: *const PAINTSTRUCT) callconv(.c) BOOL;
pub extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.c) BOOL;
pub extern "user32" fn GetWindowRect(hWnd: HWND, lpRect: *RECT) callconv(.c) BOOL;
pub extern "user32" fn InvalidateRect(hWnd: HWND, lpRect: ?*const RECT, bErase: BOOL) callconv(.c) BOOL;
pub extern "user32" fn GetDC(hWnd: ?HWND) callconv(.c) ?HDC;
pub extern "user32" fn ReleaseDC(hWnd: ?HWND, hDC: HDC) callconv(.c) c_int;
pub extern "user32" fn LoadCursorA(hInstance: ?HINSTANCE, lpCursorName: LPCSTR) callconv(.c) ?HCURSOR;
pub extern "user32" fn SetLayeredWindowAttributes(hwnd: HWND, crKey: DWORD, bAlpha: BYTE, dwFlags: DWORD) callconv(.c) BOOL;
pub extern "user32" fn UpdateLayeredWindow(
    hWnd: HWND,
    hdcDst: ?HDC,
    pptDst: ?*POINT,
    psize: ?*SIZE,
    hdcSrc: ?HDC,
    pptSrc: ?*POINT,
    crKey: DWORD,
    pblend: ?*const BLENDFUNCTION,
    dwFlags: DWORD,
) callconv(.c) BOOL;
pub extern "user32" fn SetWindowPos(
    hWnd: HWND,
    hWndInsertAfter: HWND,
    X: c_int,
    Y: c_int,
    cx: c_int,
    cy: c_int,
    uFlags: UINT,
) callconv(.c) BOOL;

// EndDeferWindowPos applies the whole batch atomically, so DWM never composites a frame
// with only some windows in the batch reordered.
pub const HDWP = *anyopaque;
pub extern "user32" fn BeginDeferWindowPos(nNumWindows: c_int) callconv(.c) ?HDWP;
pub extern "user32" fn DeferWindowPos(
    hWinPosInfo: HDWP,
    hWnd: HWND,
    hWndInsertAfter: HWND,
    x: c_int,
    y: c_int,
    cx: c_int,
    cy: c_int,
    uFlags: UINT,
) callconv(.c) ?HDWP;
pub extern "user32" fn EndDeferWindowPos(hWinPosInfo: HDWP) callconv(.c) BOOL;
pub extern "user32" fn SetWinEventHook(
    eventMin: DWORD,
    eventMax: DWORD,
    hmodWinEventProc: ?HMODULE,
    pfnWinEventProc: WINEVENTPROC,
    idProcess: DWORD,
    idThread: DWORD,
    dwFlags: DWORD,
) callconv(.c) ?HANDLE;
pub extern "user32" fn UnhookWinEvent(hWinEventHook: HANDLE) callconv(.c) BOOL;
pub extern "user32" fn SetWindowLongPtrA(hWnd: HWND, nIndex: c_int, dwNewLong: isize) callconv(.c) isize;
pub extern "user32" fn GetWindowLongPtrA(hWnd: HWND, nIndex: c_int) callconv(.c) isize;
pub extern "user32" fn SetPropA(hWnd: HWND, lpString: LPCSTR, hData: HANDLE) callconv(.c) BOOL;
pub extern "user32" fn GetPropA(hWnd: HWND, lpString: LPCSTR) callconv(.c) ?HANDLE;
pub extern "user32" fn SetTimer(hWnd: ?HWND, nIDEvent: usize, uElapse: UINT, lpTimerFunc: ?*const anyopaque) callconv(.c) usize;
pub extern "user32" fn KillTimer(hWnd: ?HWND, uIDEvent: usize) callconv(.c) BOOL;
pub extern "user32" fn SetCapture(hWnd: HWND) callconv(.c) ?HWND;
pub extern "user32" fn ReleaseCapture() callconv(.c) BOOL;
pub extern "user32" fn GetParent(hWnd: HWND) callconv(.c) ?HWND;
pub extern "user32" fn GetSystemMetrics(nIndex: c_int) callconv(.c) c_int;
pub extern "user32" fn GetAsyncKeyState(vKey: c_int) callconv(.c) c_short;
pub extern "user32" fn RegisterHotKey(
    hWnd: ?HWND,
    id: c_int,
    fsModifiers: UINT,
    vk: UINT,
) callconv(.c) BOOL;
pub extern "user32" fn UnregisterHotKey(
    hWnd: ?HWND,
    id: c_int,
) callconv(.c) BOOL;

// RegisterHotKey is keyboard-only, so mouse-button hotkeys (e.g. XButton1/XButton2) instead
// go through a WH_MOUSE_LL low-level hook, with its own handle/callback/(un)install functions.
pub const HHOOK = HANDLE;
pub const WH_KEYBOARD_LL: c_int = 13;
pub const WH_MOUSE_LL: c_int = 14;
pub const HOOKPROC = *const fn (c_int, WPARAM, LPARAM) callconv(.c) LRESULT;

pub extern "user32" fn SetWindowsHookExA(idHook: c_int, lpfn: HOOKPROC, hmod: ?HINSTANCE, dwThreadId: DWORD) callconv(.c) ?HHOOK;
pub extern "user32" fn UnhookWindowsHookEx(hhk: HHOOK) callconv(.c) BOOL;
pub extern "user32" fn CallNextHookEx(hhk: ?HHOOK, nCode: c_int, wParam: WPARAM, lParam: LPARAM) callconv(.c) LRESULT;

pub extern "kernel32" fn FindFirstChangeNotificationW(
    lpPathName: [*:0]const u16,
    bWatchSubtree: BOOL,
    dwNotifyFilter: DWORD,
) callconv(.c) HANDLE;
pub extern "kernel32" fn FindNextChangeNotification(hChangeHandle: HANDLE) callconv(.c) BOOL;
pub extern "kernel32" fn FindCloseChangeNotification(hChangeHandle: HANDLE) callconv(.c) BOOL;
pub extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.c) DWORD;

// Directory enumeration, filtered by name pattern (e.g. "Local_*.txt") at the OS level
pub const MAX_PATH = 260;
pub const FILE_ATTRIBUTE_DIRECTORY = 0x00000010;

pub const WIN32_FIND_DATAW = extern struct {
    dwFileAttributes: DWORD,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    nFileSizeHigh: DWORD,
    nFileSizeLow: DWORD,
    dwReserved0: DWORD,
    dwReserved1: DWORD,
    cFileName: [MAX_PATH]u16,
    cAlternateFileName: [14]u16,
};

pub extern "kernel32" fn FindFirstFileW(lpFileName: [*:0]const u16, lpFindFileData: *WIN32_FIND_DATAW) callconv(.c) HANDLE;
pub extern "kernel32" fn FindNextFileW(hFindFile: HANDLE, lpFindFileData: *WIN32_FIND_DATAW) callconv(.c) BOOL;
pub extern "kernel32" fn FindClose(hFindFile: HANDLE) callconv(.c) BOOL;

pub extern "user32" fn CreatePopupMenu() callconv(.c) ?HMENU;
pub extern "user32" fn AppendMenuA(
    hMenu: HMENU,
    uFlags: UINT,
    uIDNewItem: usize,
    lpNewItem: ?LPCSTR,
) callconv(.c) BOOL;
pub extern "user32" fn TrackPopupMenu(
    hMenu: HMENU,
    uFlags: UINT,
    x: c_int,
    y: c_int,
    nReserved: c_int,
    hWnd: HWND,
    prcRect: ?*const RECT,
) callconv(.c) BOOL;
pub extern "user32" fn DestroyMenu(hMenu: HMENU) callconv(.c) BOOL;
pub extern "user32" fn GetCursorPos(lpPoint: *POINT) callconv(.c) BOOL;
pub extern "user32" fn WindowFromPoint(point: POINT) callconv(.c) ?HWND;
pub extern "user32" fn LoadIconA(hInstance: ?HINSTANCE, lpIconName: LPCSTR) callconv(.c) ?HICON;
pub extern "user32" fn DestroyIcon(hIcon: HICON) callconv(.c) BOOL;
pub extern "user32" fn LoadImageA(
    hInst: ?HINSTANCE,
    name: LPCSTR,
    type_: UINT,
    cx: c_int,
    cy: c_int,
    fuLoad: UINT,
) callconv(.c) ?HANDLE;
pub extern "shell32" fn Shell_NotifyIconA(
    dwMessage: DWORD,
    lpData: *NOTIFYICONDATAA,
) callconv(.c) BOOL;
pub extern "shell32" fn ShellExecuteA(
    hwnd: ?HWND,
    lpOperation: LPCSTR,
    lpFile: LPCSTR,
    lpParameters: ?LPCSTR,
    lpDirectory: ?LPCSTR,
    nShowCmd: c_int,
) callconv(.c) ?HANDLE;

pub const SM_CXSCREEN = 0;
pub const SM_CYSCREEN = 1;
pub const SM_XVIRTUALSCREEN = 76;
pub const SM_YVIRTUALSCREEN = 77;
pub const SM_CXVIRTUALSCREEN = 78;
pub const SM_CYVIRTUALSCREEN = 79;

pub const MOD_ALT = 0x0001;
pub const MOD_CONTROL = 0x0002;
pub const MOD_SHIFT = 0x0004;
pub const MOD_WIN = 0x0008;
pub const MOD_NOREPEAT = 0x4000;

pub const NIM_ADD = 0x00000000;
pub const NIM_MODIFY = 0x00000001;
pub const NIM_DELETE = 0x00000002;
pub const NIF_MESSAGE = 0x00000001;
pub const NIF_ICON = 0x00000002;
pub const NIF_TIP = 0x00000004;
pub const NIF_INFO = 0x00000010;

pub const NIIF_INFO = 0x00000001;
pub const NIIF_WARNING = 0x00000002;

pub const TPM_RIGHTBUTTON = 0x0002;
pub const TPM_BOTTOMALIGN = 0x0020;
pub const MF_STRING = 0x00000000;
pub const MF_SEPARATOR = 0x00000800;
pub const MF_POPUP = 0x00000010;
pub const MF_CHECKED = 0x00000008;
pub const MF_GRAYED = 0x00000001;
pub const IDM_EXIT = 1001;
pub const IDM_UPDATE = 1002;
pub const IDM_TOGGLE_DRAGGING = 1003;
pub const IDM_SUSPEND_HOTKEYS = 1004;
pub const IDM_TOGGLE_AUTO_MINIMIZE = 1005;
pub const IDM_TOGGLE_VISIBILITY = 1006;
pub const IDM_OPEN_CONFIG = 1007;
pub const IDM_CLOSE_ALL_CLIENTS = 1008;
pub const IDM_TOGGLE_NOTIF_HISTORY = 1009;
pub const IDM_CLEAR_NOTIF_HISTORY = 1010;
pub const IDM_TOGGLE_TRAVEL_MODE = 1011;
pub const IDM_PROFILE_BASE = 2000;

pub const IDI_APPLICATION: LPCSTR = @ptrFromInt(32512);
pub const IMAGE_ICON = 1;
pub const LR_LOADFROMFILE = 0x00000010;

pub const VK_SHIFT = 0x10;
pub const VK_CONTROL = 0x11;
// Alt
pub const VK_MENU = 0x12;
pub const VK_LWIN = 0x5B;
pub const VK_RWIN = 0x5C;

// Identifies which side button triggered a WM_XBUTTONDOWN/UP message or MSLLHOOKSTRUCT event (packed into the high word of wParam/mouseData respectively).
pub const XBUTTON1: WORD = 0x0001;
pub const XBUTTON2: WORD = 0x0002;

pub extern "kernel32" fn GetModuleHandleA(lpModuleName: ?LPCSTR) callconv(.c) ?HINSTANCE;
pub extern "kernel32" fn OpenProcess(dwDesiredAccess: DWORD, bInheritHandle: BOOL, dwProcessId: DWORD) callconv(.c) ?HANDLE;
pub extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.c) BOOL;
pub extern "kernel32" fn GetModuleFileNameExA(hProcess: HANDLE, hModule: ?HMODULE, lpFilename: LPSTR, nSize: DWORD) callconv(.c) DWORD;
pub extern "kernel32" fn GetModuleFileNameA(hModule: ?HMODULE, lpFilename: LPSTR, nSize: DWORD) callconv(.c) DWORD;

pub const ALL_PROCESSOR_GROUPS: WORD = 0xFFFF;
pub extern "kernel32" fn GetActiveProcessorCount(GroupNumber: WORD) callconv(.c) DWORD;

/// resource_tracker.zig only reads WorkingSetSize; the rest exists so the extern struct matches the real Win32 layout.
pub const PROCESS_MEMORY_COUNTERS = extern struct {
    cb: DWORD,
    PageFaultCount: DWORD,
    PeakWorkingSetSize: usize,
    WorkingSetSize: usize,
    QuotaPeakPagedPoolUsage: usize,
    QuotaPagedPoolUsage: usize,
    QuotaPeakNonPagedPoolUsage: usize,
    QuotaNonPagedPoolUsage: usize,
    PagefileUsage: usize,
    PeakPagefileUsage: usize,
};
pub extern "psapi" fn GetProcessMemoryInfo(hProcess: HANDLE, ppsmemCounters: *PROCESS_MEMORY_COUNTERS, cb: DWORD) callconv(.c) BOOL;

// PDH (Performance Data Helper) - per-process VRAM has no simpler API than its "GPU Process Memory" counter.
pub const PDH_HQUERY = ?*anyopaque;
pub const PDH_HCOUNTER = ?*anyopaque;
pub const PDH_STATUS = LONG;
pub const PDH_MORE_DATA: PDH_STATUS = @bitCast(@as(u32, 0x800007D2));
pub const PDH_FMT_LARGE: DWORD = 0x00000400;

pub const PDH_FMT_COUNTERVALUE = extern struct {
    CStatus: DWORD,
    value: extern union {
        longValue: LONG,
        doubleValue: f64,
        largeValue: i64,
    },
};
pub const PDH_FMT_COUNTERVALUE_ITEM_A = extern struct {
    szName: LPSTR,
    FmtValue: PDH_FMT_COUNTERVALUE,
};

pub extern "pdh" fn PdhOpenQueryA(szDataSource: ?LPCSTR, dwUserData: usize, phQuery: *PDH_HQUERY) callconv(.c) PDH_STATUS;
// English variant deliberately: PdhAddCounterA expects OS-localized counter names, which would break VRAM_COUNTER_PATH on non-English Windows.
pub extern "pdh" fn PdhAddEnglishCounterA(hQuery: PDH_HQUERY, szFullCounterPath: LPCSTR, dwUserData: usize, phCounter: *PDH_HCOUNTER) callconv(.c) PDH_STATUS;
pub extern "pdh" fn PdhCollectQueryData(hQuery: PDH_HQUERY) callconv(.c) PDH_STATUS;
pub extern "pdh" fn PdhGetFormattedCounterArrayA(hCounter: PDH_HCOUNTER, dwFormat: DWORD, lpdwBufferSize: *DWORD, lpdwItemCount: *DWORD, ItemBuffer: ?[*]u8) callconv(.c) PDH_STATUS;
pub extern "pdh" fn PdhCloseQuery(hQuery: PDH_HQUERY) callconv(.c) PDH_STATUS;

pub const FILETIME = extern struct {
    dwLowDateTime: DWORD,
    dwHighDateTime: DWORD,

    /// Convert to a u64 (100-nanosecond intervals since Jan 1, 1601)
    pub fn toU64(self: FILETIME) u64 {
        return (@as(u64, self.dwHighDateTime) << 32) | @as(u64, self.dwLowDateTime);
    }
};
pub extern "kernel32" fn GetProcessTimes(hProcess: HANDLE, lpCreationTime: *FILETIME, lpExitTime: *FILETIME, lpKernelTime: *FILETIME, lpUserTime: *FILETIME) callconv(.c) BOOL;

pub const SYSTEMTIME = extern struct {
    wYear: WORD,
    wMonth: WORD,
    wDayOfWeek: WORD,
    wDay: WORD,
    wHour: WORD,
    wMinute: WORD,
    wSecond: WORD,
    wMilliseconds: WORD,
};
pub extern "kernel32" fn GetLocalTime(lpSystemTime: *SYSTEMTIME) callconv(.c) void;
pub extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.c) void;
pub extern "kernel32" fn GetTickCount64() callconv(.c) u64;

pub extern "gdi32" fn TextOutA(hdc: HDC, x: c_int, y: c_int, lpString: LPCSTR, c: c_int) callconv(.c) BOOL;
pub extern "gdi32" fn GetTextExtentPoint32A(hdc: HDC, lpString: LPCSTR, c: c_int, psizl: *SIZE) callconv(.c) BOOL;
pub extern "gdi32" fn TextOutW(hdc: HDC, x: c_int, y: c_int, lpString: [*]const u16, c: c_int) callconv(.c) BOOL;
pub extern "gdi32" fn GetTextExtentPoint32W(hdc: HDC, lpString: [*]const u16, c: c_int, psizl: *SIZE) callconv(.c) BOOL;
pub extern "gdi32" fn SetBkMode(hdc: HDC, mode: c_int) callconv(.c) c_int;
pub extern "gdi32" fn SetTextColor(hdc: HDC, color: DWORD) callconv(.c) DWORD;
pub extern "gdi32" fn CreateFontA(
    cHeight: c_int,
    cWidth: c_int,
    cEscapement: c_int,
    cOrientation: c_int,
    cWeight: c_int,
    bItalic: DWORD,
    bUnderline: DWORD,
    bStrikeOut: DWORD,
    iCharSet: DWORD,
    iOutPrecision: DWORD,
    iClipPrecision: DWORD,
    iQuality: DWORD,
    iPitchAndFamily: DWORD,
    pszFaceName: ?LPCSTR,
) callconv(.c) ?HFONT;
pub extern "gdi32" fn SelectObject(hdc: HDC, h: HANDLE) callconv(.c) ?HANDLE;
pub extern "gdi32" fn DeleteObject(ho: HANDLE) callconv(.c) BOOL;
pub extern "gdi32" fn Rectangle(hdc: HDC, left: c_int, top: c_int, right: c_int, bottom: c_int) callconv(.c) BOOL;
pub extern "gdi32" fn CreatePen(iStyle: c_int, cWidth: c_int, color: DWORD) callconv(.c) ?HPEN;
pub extern "gdi32" fn FrameRect(hDC: HDC, lprc: *const RECT, hbr: HBRUSH) callconv(.c) c_int;
pub extern "gdi32" fn CreateCompatibleDC(hdc: ?HDC) callconv(.c) ?HDC;
pub extern "gdi32" fn CreateDIBSection(
    hdc: ?HDC,
    pbmi: *const BITMAPINFO,
    usage: UINT,
    ppvBits: *?*anyopaque,
    hSection: ?HANDLE,
    offset: DWORD,
) callconv(.c) ?HANDLE;
pub extern "gdi32" fn DeleteDC(hdc: HDC) callconv(.c) BOOL;
pub extern "gdi32" fn CreateSolidBrush(color: DWORD) callconv(.c) ?HBRUSH;
pub extern "gdi32" fn FillRect(hDC: HDC, lprc: *const RECT, hbr: HBRUSH) callconv(.c) c_int;

pub extern "dwmapi" fn DwmRegisterThumbnail(
    hwndDestination: HWND,
    hwndSource: HWND,
    phThumbnailId: *HTHUMBNAIL,
) callconv(.c) LONG;
pub extern "dwmapi" fn DwmUnregisterThumbnail(hThumbnailId: HTHUMBNAIL) callconv(.c) LONG;
pub extern "dwmapi" fn DwmUpdateThumbnailProperties(
    hThumbnailId: HTHUMBNAIL,
    ptnProperties: *const DWM_THUMBNAIL_PROPERTIES,
) callconv(.c) LONG;

pub const TRANSPARENT = 1;
pub const OPAQUE = 2;
pub const PS_SOLID = 0;
pub const PS_DASH = 1;
pub const PS_NULL = 5;
pub const PS_INSIDEFRAME = 6;
pub const FW_NORMAL = 400;
pub const FW_BOLD = 700;
pub const DEFAULT_CHARSET = 1;
pub const OUT_DEFAULT_PRECIS = 0;
pub const CLIP_DEFAULT_PRECIS = 0;
pub const DEFAULT_QUALITY = 0;
pub const ANTIALIASED_QUALITY = 4;
pub const CLEARTYPE_QUALITY = 5;
pub const DEFAULT_PITCH = 0;

pub const LWA_COLORKEY = 0x00000001;
pub const LWA_ALPHA = 0x00000002;
pub const ULW_ALPHA = 0x00000002;
pub const AC_SRC_OVER = 0x00;
pub const AC_SRC_ALPHA = 0x01;

pub const WINEVENTPROC = *const fn (
    hWinEventHook: HANDLE,
    event: DWORD,
    hwnd: HWND,
    idObject: LONG,
    idChild: LONG,
    idEventThread: DWORD,
    dwmsEventTime: DWORD,
) callconv(.c) void;

pub const EVENT_SYSTEM_FOREGROUND = 0x0003;
pub const EVENT_OBJECT_CREATE = 0x8000;
pub const EVENT_OBJECT_DESTROY = 0x8001;
pub const EVENT_OBJECT_NAMECHANGE = 0x800C;
pub const WINEVENT_OUTOFCONTEXT = 0x0000;

pub const BI_RGB = 0;
pub const DIB_RGB_COLORS = 0;

pub const BLENDFUNCTION = extern struct {
    BlendOp: BYTE,
    BlendFlags: BYTE,
    SourceConstantAlpha: BYTE,
    AlphaFormat: BYTE,
};

pub const SIZE = extern struct {
    cx: LONG,
    cy: LONG,
};

pub const BITMAPINFOHEADER = extern struct {
    biSize: DWORD,
    biWidth: LONG,
    biHeight: LONG,
    biPlanes: WORD,
    biBitCount: WORD,
    biCompression: DWORD,
    biSizeImage: DWORD,
    biXPelsPerMeter: LONG,
    biYPelsPerMeter: LONG,
    biClrUsed: DWORD,
    biClrImportant: DWORD,
};

pub const RGBQUAD = extern struct {
    rgbBlue: BYTE,
    rgbGreen: BYTE,
    rgbRed: BYTE,
    rgbReserved: BYTE,
};

pub const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER,
    bmiColors: [1]RGBQUAD,
};

pub const NOTIFYICONDATAA = extern struct {
    cbSize: DWORD,
    hWnd: HWND,
    uID: UINT,
    uFlags: UINT,
    uCallbackMessage: UINT,
    hIcon: HICON,
    szTip: [128]u8,
    dwState: DWORD,
    dwStateMask: DWORD,
    szInfo: [256]u8,
    uTimeout: UINT,
    szInfoTitle: [64]u8,
    dwInfoFlags: DWORD,
    guidItem: [16]u8,
    hBalloonIcon: HICON,
};

pub const HMONITOR = *opaque {};
pub const MONITORINFO = extern struct {
    cbSize: DWORD,
    rcMonitor: RECT,
    rcWork: RECT,
    dwFlags: DWORD,
};

pub const MONITORENUMPROC = *const fn (
    hMonitor: HMONITOR,
    hdcMonitor: ?HDC,
    lprcMonitor: ?*RECT,
    dwData: LPARAM,
) callconv(.c) BOOL;

pub extern "user32" fn EnumDisplayMonitors(
    hdc: ?HDC,
    lprcClip: ?*RECT,
    lpfnEnum: MONITORENUMPROC,
    dwData: LPARAM,
) callconv(.c) BOOL;

pub extern "user32" fn GetMonitorInfoA(
    hMonitor: HMONITOR,
    lpmi: *MONITORINFO,
) callconv(.c) BOOL;

pub const MONITOR_DEFAULTTONEAREST: DWORD = 0x00000002;
pub const MONITOR_DEFAULTTONULL: DWORD = 0x00000000;
pub const MONITOR_DEFAULTTOPRIMARY: DWORD = 0x00000001;

pub extern "user32" fn MonitorFromPoint(
    pt: POINT,
    dwFlags: DWORD,
) callconv(.c) ?HMONITOR;

pub extern "user32" fn MonitorFromWindow(
    hwnd: HWND,
    dwFlags: DWORD,
) callconv(.c) ?HMONITOR;

pub const HRESULT = i32;
pub const MDT_EFFECTIVE_DPI: c_int = 0;
pub extern "shcore" fn GetDpiForMonitor(hMonitor: HMONITOR, dpiType: c_int, dpiX: *UINT, dpiY: *UINT) callconv(.c) HRESULT;

pub extern "user32" fn GetDpiForWindow(hWnd: HWND) callconv(.c) UINT;
pub extern "user32" fn GetDpiForSystem() callconv(.c) UINT;

// Sentinel pointer value, not a real pointer, matching HWND_TOPMOST/HWND_NOTOPMOST below.
pub const DPI_AWARENESS_CONTEXT = *opaque {};
pub const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: DPI_AWARENESS_CONTEXT = @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));
pub extern "user32" fn SetProcessDpiAwarenessContext(value: DPI_AWARENESS_CONTEXT) callconv(.c) BOOL;

pub extern "kernel32" fn GetConsoleWindow() callconv(.c) ?HWND;
pub extern "kernel32" fn AllocConsole() callconv(.c) BOOL;

pub const CTRL_C_EVENT: DWORD = 0;
pub const CTRL_BREAK_EVENT: DWORD = 1;
pub const CTRL_CLOSE_EVENT: DWORD = 2;
pub const CTRL_LOGOFF_EVENT: DWORD = 5;
pub const CTRL_SHUTDOWN_EVENT: DWORD = 6;
pub const PHANDLER_ROUTINE = *const fn (DWORD) callconv(.c) BOOL;
pub extern "kernel32" fn SetConsoleCtrlHandler(HandlerRoutine: PHANDLER_ROUTINE, Add: BOOL) callconv(.c) BOOL;

pub fn getWindowTitle(hwnd: HWND, allocator: std.mem.Allocator) ![]const u8 {
    var title_buffer: [64:0]u8 = undefined;
    const title_len = GetWindowTextA(hwnd, &title_buffer, title_buffer.len);
    if (title_len == 0) return error.NoWindowTitle;
    return allocator.dupe(u8, title_buffer[0..@intCast(title_len)]);
}

pub fn getWindowTitleBuf(hwnd: HWND, buffer: []u8) ![]const u8 {
    if (buffer.len == 0) return error.BufferTooSmall;
    const buf_ptr: [*:0]u8 = @ptrCast(buffer.ptr);
    const title_len = GetWindowTextA(hwnd, buf_ptr, @intCast(buffer.len));
    if (title_len == 0) return error.NoWindowTitle;
    return buffer[0..@intCast(title_len)];
}

pub fn getClassNameBuf(hwnd: HWND, buffer: []u8) ?[]const u8 {
    if (buffer.len == 0) return null;
    const buf_ptr: [*:0]u8 = @ptrCast(buffer.ptr);
    const class_len = GetClassNameA(hwnd, buf_ptr, @intCast(buffer.len));
    if (class_len <= 0) return null;
    return buffer[0..@intCast(class_len)];
}

/// Full executable path of process_id's owning process, or null if it can't be opened or queried.
/// exe_path_buf must be MAX_PATH-sized; the returned slice borrows it.
pub fn queryProcessExePath(process_id: DWORD, exe_path_buf: *[260:0]u8) ?[]const u8 {
    const handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, process_id) orelse return null;
    defer _ = CloseHandle(handle);
    const path_len = GetModuleFileNameExA(handle, null, exe_path_buf, exe_path_buf.len);
    if (path_len == 0) return null;
    return exe_path_buf[0..@intCast(path_len)];
}

/// Full path of the current process's own executable. Replaces std.fs.selfExePath, removed in Zig 0.16.
pub fn selfExePath(buf: []u8) ![]const u8 {
    const len = GetModuleFileNameA(null, @ptrCast(buf.ptr), @intCast(buf.len));
    if (len == 0) return error.Unexpected;
    if (len == buf.len) return error.NameTooLong;
    return buf[0..@intCast(len)];
}

/// Directory containing the current process's own executable. Replaces std.fs.selfExeDirPath, removed in Zig 0.16.
pub fn selfExeDirPath(buf: []u8) ![]const u8 {
    const full_path = try selfExePath(buf);
    return std.fs.path.dirname(full_path) orelse return error.NoDirname;
}

/// Opens `target` (a file path or URL) with its default handler via ShellExecuteA. Returns false on failure.
pub fn shellOpen(target: [*:0]const u8, workdir: ?[*:0]const u8) bool {
    const result = ShellExecuteA(null, "open", target, null, workdir, SW_SHOW);
    return @intFromPtr(result) > 32;
}

pub extern "user32" fn OpenClipboard(hWndNewOwner: ?HWND) callconv(.c) BOOL;
pub extern "user32" fn CloseClipboard() callconv(.c) BOOL;
pub extern "user32" fn GetClipboardData(uFormat: UINT) callconv(.c) ?HANDLE;
pub extern "kernel32" fn GlobalLock(hMem: HANDLE) callconv(.c) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(hMem: HANDLE) callconv(.c) BOOL;

pub const CF_TEXT: UINT = 1;

/// Caller-owned copy of the clipboard's CF_TEXT (ANSI, matching this app's Win32 surface) content, or null if unavailable/non-text.
pub fn getClipboardText(allocator: std.mem.Allocator) ?[]u8 {
    if (!toBool(OpenClipboard(null))) return null;
    defer _ = CloseClipboard();

    const handle = GetClipboardData(CF_TEXT) orelse return null;
    const ptr = GlobalLock(handle) orelse return null;
    defer _ = GlobalUnlock(handle);

    const text: [*:0]const u8 = @ptrCast(ptr);
    return allocator.dupe(u8, std.mem.span(text)) catch null;
}

pub const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};

const CLSID_FileOpenDialog = GUID{
    .Data1 = 0xDC1C5A9C,
    .Data2 = 0xE88A,
    .Data3 = 0x4dde,
    .Data4 = [8]u8{ 0xA5, 0xA1, 0x60, 0xF8, 0x2A, 0x20, 0xAE, 0xF7 },
};

const IID_IFileOpenDialog = GUID{
    .Data1 = 0xD57C7288,
    .Data2 = 0xD4AD,
    .Data3 = 0x4768,
    .Data4 = [8]u8{ 0xBE, 0x02, 0x9D, 0x96, 0x95, 0x32, 0xD9, 0x60 },
};

const FOS_PICKFOLDERS: u32 = 0x00000020;
const SIGDN_FILESYSPATH: u32 = 0x80058000;

extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: u32) callconv(.c) c_long;
extern "ole32" fn CoUninitialize() callconv(.c) void;
extern "ole32" fn CoCreateInstance(
    rclsid: *const GUID,
    pUnkOuter: ?*anyopaque,
    dwClsContext: u32,
    riid: *const GUID,
    ppv: *?*anyopaque,
) callconv(.c) c_long;
extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(.c) void;

const IFileOpenDialog = extern struct {
    vtable: *const IFileOpenDialogVtbl,

    const IFileOpenDialogVtbl = extern struct {
        QueryInterface: *const fn (*IFileOpenDialog, *const GUID, *?*anyopaque) callconv(.c) c_long,
        AddRef: *const fn (*IFileOpenDialog) callconv(.c) u32,
        Release: *const fn (*IFileOpenDialog) callconv(.c) u32,
        Show: *const fn (*IFileOpenDialog, ?HWND) callconv(.c) c_long,
        SetFileTypes: *const fn (*IFileOpenDialog, u32, ?*const anyopaque) callconv(.c) c_long,
        SetFileTypeIndex: *const fn (*IFileOpenDialog, u32) callconv(.c) c_long,
        GetFileTypeIndex: *const fn (*IFileOpenDialog, *u32) callconv(.c) c_long,
        Advise: *const fn (*IFileOpenDialog, ?*anyopaque, *u32) callconv(.c) c_long,
        Unadvise: *const fn (*IFileOpenDialog, u32) callconv(.c) c_long,
        SetOptions: *const fn (*IFileOpenDialog, u32) callconv(.c) c_long,
        GetOptions: *const fn (*IFileOpenDialog, *u32) callconv(.c) c_long,
        SetDefaultFolder: *const fn (*IFileOpenDialog, ?*anyopaque) callconv(.c) c_long,
        SetFolder: *const fn (*IFileOpenDialog, ?*anyopaque) callconv(.c) c_long,
        GetFolder: *const fn (*IFileOpenDialog, *?*anyopaque) callconv(.c) c_long,
        GetCurrentSelection: *const fn (*IFileOpenDialog, *?*anyopaque) callconv(.c) c_long,
        SetFileName: *const fn (*IFileOpenDialog, [*:0]const u16) callconv(.c) c_long,
        GetFileName: *const fn (*IFileOpenDialog, *[*:0]u16) callconv(.c) c_long,
        SetTitle: *const fn (*IFileOpenDialog, [*:0]const u16) callconv(.c) c_long,
        SetOkButtonLabel: *const fn (*IFileOpenDialog, [*:0]const u16) callconv(.c) c_long,
        SetFileNameLabel: *const fn (*IFileOpenDialog, [*:0]const u16) callconv(.c) c_long,
        GetResult: *const fn (*IFileOpenDialog, *?*IShellItem) callconv(.c) c_long,
        AddPlace: *const fn (*IFileOpenDialog, ?*anyopaque, u32) callconv(.c) c_long,
        SetDefaultExtension: *const fn (*IFileOpenDialog, [*:0]const u16) callconv(.c) c_long,
        Close: *const fn (*IFileOpenDialog, c_long) callconv(.c) c_long,
        SetClientGuid: *const fn (*IFileOpenDialog, *const GUID) callconv(.c) c_long,
        ClearClientData: *const fn (*IFileOpenDialog) callconv(.c) c_long,
        SetFilter: *const fn (*IFileOpenDialog, ?*anyopaque) callconv(.c) c_long,
    };

    fn release(self: *IFileOpenDialog) void {
        _ = self.vtable.Release(self);
    }

    fn setOptions(self: *IFileOpenDialog, options: u32) c_long {
        return self.vtable.SetOptions(self, options);
    }

    fn setTitle(self: *IFileOpenDialog, title: [*:0]const u16) c_long {
        return self.vtable.SetTitle(self, title);
    }

    fn show(self: *IFileOpenDialog, hwnd: ?HWND) c_long {
        return self.vtable.Show(self, hwnd);
    }

    fn getResult(self: *IFileOpenDialog) ?*IShellItem {
        var result: ?*IShellItem = null;
        const hr = self.vtable.GetResult(self, &result);
        if (hr < 0) return null;
        return result;
    }
};

const IShellItem = extern struct {
    vtable: *const IShellItemVtbl,

    const IShellItemVtbl = extern struct {
        QueryInterface: *const fn (*IShellItem, *const GUID, *?*anyopaque) callconv(.c) c_long,
        AddRef: *const fn (*IShellItem) callconv(.c) u32,
        Release: *const fn (*IShellItem) callconv(.c) u32,
        BindToHandler: *const fn (*IShellItem, ?*anyopaque, *const GUID, *const GUID, *?*anyopaque) callconv(.c) c_long,
        GetParent: *const fn (*IShellItem, *?*IShellItem) callconv(.c) c_long,
        GetDisplayName: *const fn (*IShellItem, u32, *[*:0]u16) callconv(.c) c_long,
        GetAttributes: *const fn (*IShellItem, u32, *u32) callconv(.c) c_long,
        Compare: *const fn (*IShellItem, *IShellItem, u32, *i32) callconv(.c) c_long,
    };

    fn release(self: *IShellItem) void {
        _ = self.vtable.Release(self);
    }

    fn getDisplayName(self: *IShellItem, sigdnName: u32) ?[*:0]u16 {
        var name: [*:0]u16 = undefined;
        const hr = self.vtable.GetDisplayName(self, sigdnName, &name);
        if (hr < 0) return null;
        return name;
    }
};

/// Shows the Win32 "Select Folder" dialog with `title`, returning the chosen path (caller frees) or null if cancelled.
/// `owner`, when given, keeps the picker above a topmost owner window (an owned window always draws above its owner, even a HWND_TOPMOST one).
pub fn showFolderPicker(allocator: std.mem.Allocator, title: []const u8, owner: ?HWND) !?[]const u8 {
    const COINIT_APARTMENTTHREADED: u32 = 0x2;
    const COINIT_DISABLE_OLE1DDE: u32 = 0x4;
    const hr = CoInitializeEx(null, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    // 0x00000001 is S_FALSE (already initialized), which is OK.
    if (hr < 0 and hr != 0x00000001) {
        return error.ComInitFailed;
    }
    defer CoUninitialize();

    const CLSCTX_INPROC_SERVER: u32 = 0x1;
    var dialog_ptr: ?*anyopaque = null;
    const create_hr = CoCreateInstance(
        &CLSID_FileOpenDialog,
        null,
        CLSCTX_INPROC_SERVER,
        &IID_IFileOpenDialog,
        &dialog_ptr,
    );

    if (create_hr < 0 or dialog_ptr == null) {
        return error.CreateDialogFailed;
    }

    const dialog: *IFileOpenDialog = @ptrCast(@alignCast(dialog_ptr.?));
    defer dialog.release();

    _ = dialog.setOptions(FOS_PICKFOLDERS);

    const title_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, title);
    defer allocator.free(title_w);
    _ = dialog.setTitle(title_w.ptr);

    const show_hr = dialog.show(owner);
    if (show_hr < 0) {
        return null;
    }

    const result_item = dialog.getResult() orelse return null;
    defer result_item.release();

    const path_w = result_item.getDisplayName(SIGDN_FILESYSPATH) orelse return null;
    defer CoTaskMemFree(path_w);

    const path_len = std.mem.indexOfSentinel(u16, 0, path_w);
    const path_slice = path_w[0..path_len :0];
    const path = try std.unicode.utf16LeToUtf8Alloc(allocator, path_slice);

    return path;
}

extern "shell32" fn SHGetKnownFolderPath(
    rfid: *const GUID,
    dwFlags: u32,
    hToken: ?HANDLE,
    ppszPath: *?[*:0]u16,
) callconv(.c) c_long;

/// Resolves a shell known-folder (e.g. Documents) to its current real path, backslash-separated as returned by Windows.
pub fn getKnownFolderPath(allocator: std.mem.Allocator, folder_id: GUID) ![]u8 {
    var path_ptr: ?[*:0]u16 = null;
    const hr = SHGetKnownFolderPath(&folder_id, 0, null, &path_ptr);
    if (hr < 0 or path_ptr == null) return error.KnownFolderUnavailable;
    defer CoTaskMemFree(path_ptr);

    return std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.span(path_ptr.?));
}

/// Monotonic milliseconds since boot (GetTickCount64) — for elapsed-time/duration comparisons only, never wall-clock/calendar time.
/// A distinct type (not a bare u64/i64) so a timestamp from a different clock source can't be silently compared against one of these.
pub const Ticks = struct {
    ms: u64 = 0,

    pub fn now() Ticks {
        return .{ .ms = GetTickCount64() };
    }

    /// Elapsed ms from `earlier` to `self`; saturates at 0 rather than underflowing if `earlier` is somehow later.
    pub fn elapsedSince(self: Ticks, earlier: Ticks) u64 {
        return self.ms -| earlier.ms;
    }

    pub fn isZero(self: Ticks) bool {
        return self.ms == 0;
    }
};

pub inline fn toBool(value: BOOL) bool {
    return value != 0;
}

pub inline fn isWindowVisible(hwnd: HWND) bool {
    return toBool(IsWindowVisible(hwnd));
}

pub inline fn isWindowIconic(hwnd: HWND) bool {
    return toBool(IsIconic(hwnd));
}

pub inline fn isWindow(hwnd: HWND) bool {
    return toBool(IsWindow(hwnd));
}

pub inline fn hwndToUserData(hwnd: HWND) isize {
    return @as(isize, @bitCast(@intFromPtr(hwnd)));
}

pub inline fn userDataToHwnd(user_data: isize) ?HWND {
    if (user_data == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(user_data)));
}

pub inline fn ptrToLparam(ptr: anytype) LPARAM {
    return @as(LPARAM, @bitCast(@intFromPtr(ptr)));
}

pub inline fn lparamToPtr(comptime T: type, lparam: LPARAM) *T {
    return @ptrFromInt(@as(usize, @bitCast(lparam)));
}

/// Extract the triggering virtual-key code from a WM_HOTKEY message's lParam.
/// Per MSDN: LOWORD(lParam) holds the modifier flags, HIWORD(lParam) the vk code.
pub inline fn hotkeyVkFromLparam(lparam: LPARAM) u32 {
    const bits: u32 = @truncate(@as(usize, @bitCast(lparam)));
    return bits >> 16;
}

const VK_DOWN_FLAG: c_short = @bitCast(@as(c_ushort, 0x8000));

pub inline fn isCtrlPressed() bool {
    return (GetAsyncKeyState(VK_CONTROL) & VK_DOWN_FLAG) != 0;
}

pub inline fn isAltPressed() bool {
    return (GetAsyncKeyState(VK_MENU) & VK_DOWN_FLAG) != 0;
}

pub inline fn isShiftPressed() bool {
    return (GetAsyncKeyState(VK_SHIFT) & VK_DOWN_FLAG) != 0;
}

// Two physical Win keys, no single VK code covers both.
pub inline fn isWinPressed() bool {
    return (GetAsyncKeyState(VK_LWIN) & VK_DOWN_FLAG) != 0 or
        (GetAsyncKeyState(VK_RWIN) & VK_DOWN_FLAG) != 0;
}

pub inline fn getXButton(mouse_data: DWORD) WORD {
    return @truncate(mouse_data >> 16);
}

/// Extract the signed wheel delta (multiples of 120 = WHEEL_DELTA; positive = scrolled up,
/// negative = scrolled down) from the high word of a WM_MOUSEWHEEL MSLLHOOKSTRUCT's mouseData
pub inline fn getWheelDelta(mouse_data: DWORD) i16 {
    return @bitCast(@as(u16, @truncate(mouse_data >> 16)));
}
