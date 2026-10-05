//! The webview/webview C API (deps/webview) and webview_shim.cpp, which host the configuration window's WebView2 control.
const win32 = @import("win32.zig");

pub const Webview = *opaque {};

/// webview_error_t: 0 is success, negative a failure.
pub const Error = c_int;

pub const NATIVE_HANDLE_KIND_UI_WIDGET: c_int = 1;

pub const DispatchFn = *const fn (w: Webview, arg: ?*anyopaque) callconv(.c) void;
pub const BindFn = *const fn (id: [*:0]const u8, req: [*:0]const u8, arg: ?*anyopaque) callconv(.c) void;
/// Fills body and content_type with memory that outlives the window and returns 1, or returns 0 for a 404.
pub const ServeFn = *const fn (path: [*:0]const u8, body: *[*]const u8, body_len: *usize, content_type: *[*:0]const u8) callconv(.c) c_int;

/// window is an HWND the control embeds into; the caller owns the window and has initialized COM on this thread.
pub extern fn webview_create(debug: c_int, window: ?*anyopaque) callconv(.c) ?Webview;
pub extern fn webview_destroy(w: Webview) callconv(.c) Error;
/// Pumps this thread's messages until WM_QUIT.
pub extern fn webview_run(w: Webview) callconv(.c) Error;
/// Thread-safe: runs f on the webview's thread.
pub extern fn webview_dispatch(w: Webview, f: DispatchFn, arg: ?*anyopaque) callconv(.c) Error;
pub extern fn webview_get_native_handle(w: Webview, kind: c_int) callconv(.c) ?*anyopaque;
pub extern fn webview_navigate(w: Webview, url: [*:0]const u8) callconv(.c) Error;
/// Webview thread only.
pub extern fn webview_eval(w: Webview, js: [*:0]const u8) callconv(.c) Error;
/// f runs on the webview's thread with req as the JSON array of the JS call's arguments.
pub extern fn webview_bind(w: Webview, name: [*:0]const u8, f: BindFn, arg: ?*anyopaque) callconv(.c) Error;
/// Thread-safe; result must be JSON, which resolves the JS call's promise.
pub extern fn webview_return(w: Webview, id: [*:0]const u8, status: c_int, result: [*:0]const u8) callconv(.c) Error;

/// Serves every request under prefix through serve; returns an HRESULT.
pub extern fn eve_webview_serve(w: Webview, prefix: [*:0]const u8, serve: ServeFn) callconv(.c) c_long;
pub extern fn eve_webview_focus(w: Webview) callconv(.c) void;

/// The child window the control fills, which the caller sizes to its own client area.
pub fn widget(w: Webview) ?win32.HWND {
    return webview_get_native_handle(w, NATIVE_HANDLE_KIND_UI_WIDGET);
}
