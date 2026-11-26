//! The Win32 declarations only the simulator uses, kept here so it adds nothing to platform/win32.zig.
const win32 = @import("../platform/win32.zig");

const BOOL = win32.BOOL;
const BYTE = win32.BYTE;
const DWORD = win32.DWORD;
const HANDLE = win32.HANDLE;
const LPCSTR = win32.LPCSTR;
const LPSTR = win32.LPSTR;
const UINT = win32.UINT;
const WORD = win32.WORD;

pub const WS_VISIBLE = 0x10000000;
pub const CW_USEDEFAULT: c_int = @bitCast(@as(u32, 0x80000000));
pub const CS_VREDRAW = 0x0001;
pub const CS_HREDRAW = 0x0002;

pub const STARTUPINFOA = extern struct {
    cb: DWORD = @sizeOf(STARTUPINFOA),
    lpReserved: ?LPSTR = null,
    lpDesktop: ?LPSTR = null,
    lpTitle: ?LPSTR = null,
    dwX: DWORD = 0,
    dwY: DWORD = 0,
    dwXSize: DWORD = 0,
    dwYSize: DWORD = 0,
    dwXCountChars: DWORD = 0,
    dwYCountChars: DWORD = 0,
    dwFillAttribute: DWORD = 0,
    dwFlags: DWORD = 0,
    wShowWindow: WORD = 0,
    cbReserved2: WORD = 0,
    lpReserved2: ?*BYTE = null,
    hStdInput: ?HANDLE = null,
    hStdOutput: ?HANDLE = null,
    hStdError: ?HANDLE = null,
};

pub const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};

pub extern "kernel32" fn CreateProcessA(
    lpApplicationName: ?LPCSTR,
    lpCommandLine: ?LPSTR,
    lpProcessAttributes: ?*anyopaque,
    lpThreadAttributes: ?*anyopaque,
    bInheritHandles: BOOL,
    dwCreationFlags: DWORD,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?LPCSTR,
    lpStartupInfo: *const STARTUPINFOA,
    lpProcessInformation: *PROCESS_INFORMATION,
) callconv(.c) BOOL;
pub extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: UINT) callconv(.c) BOOL;
pub extern "kernel32" fn CopyFileA(lpExistingFileName: LPCSTR, lpNewFileName: LPCSTR, bFailIfExists: BOOL) callconv(.c) BOOL;
pub extern "user32" fn FillRect(hDC: win32.HDC, lprc: *const win32.RECT, hbr: win32.HBRUSH) callconv(.c) c_int;
