//! Decodes encoded images, e.g. a JPEG portrait, into RGBA pixels with the Windows Imaging Component.
const std = @import("std");
const win32 = @import("win32.zig");

const CLSID_WIC_IMAGING_FACTORY = win32.GUID{ .Data1 = 0xcacaf262, .Data2 = 0x9370, .Data3 = 0x4615, .Data4 = .{ 0xa1, 0x3b, 0x9f, 0x55, 0x39, 0xda, 0x4c, 0x0a } };
const IID_IWIC_IMAGING_FACTORY = win32.GUID{ .Data1 = 0xec5ec8a9, .Data2 = 0xc395, .Data3 = 0x4314, .Data4 = .{ 0x9c, 0x77, 0x54, 0xd7, 0xa9, 0x35, 0xff, 0x70 } };
const GUID_WIC_PIXEL_FORMAT_32BPP_RGBA = win32.GUID{ .Data1 = 0xf5c7ad2d, .Data2 = 0x6a8d, .Data3 = 0x43dd, .Data4 = .{ 0xa7, 0xa8, 0xa2, 0x99, 0x35, 0x26, 0x1a, 0xe9 } };

/// Larger images are refused rather than decoded.
const MAX_SIDE = 1024;

/// Vtable slots, counting IUnknown's three, of the few WIC methods used.
const RELEASE = 2;
const FACTORY_CREATE_DECODER_FROM_STREAM = 4;
const FACTORY_CREATE_FORMAT_CONVERTER = 10;
const FACTORY_CREATE_STREAM = 14;
const STREAM_INITIALIZE_FROM_MEMORY = 16;
const DECODER_GET_FRAME = 13;
const SOURCE_GET_SIZE = 3;
const SOURCE_COPY_PIXELS = 7;
const CONVERTER_INITIALIZE = 8;

const HRESULT = c_long;
const Object = anyopaque;

pub const Decoded = struct {
    /// RGBA, `width` * 4 bytes a row. Owned; freed by deinit.
    pixels: []u8,
    width: u32,
    height: u32,

    pub fn deinit(self: Decoded, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

/// Decodes the first frame of `encoded`, initialising COM on the calling thread for the call; doesn't log.
pub fn decodeRgba(allocator: std.mem.Allocator, encoded: []const u8) !Decoded {
    const init_hr = win32.CoInitializeEx(null, win32.COINIT_MULTITHREADED);
    if (init_hr < 0) return error.ComInitFailed;
    defer win32.CoUninitialize();

    var factory_ptr: ?*anyopaque = null;
    if (win32.CoCreateInstance(&CLSID_WIC_IMAGING_FACTORY, null, win32.CLSCTX_INPROC_SERVER, &IID_IWIC_IMAGING_FACTORY, &factory_ptr) < 0) return error.CreateFactoryFailed;
    const factory = factory_ptr orelse return error.CreateFactoryFailed;
    defer release(factory);

    var stream_ptr: ?*Object = null;
    if (method(fn (*Object, *?*Object) callconv(.c) HRESULT, factory, FACTORY_CREATE_STREAM)(factory, &stream_ptr) < 0) return error.CreateStreamFailed;
    const stream = stream_ptr orelse return error.CreateStreamFailed;
    defer release(stream);
    // WIC only reads the buffer, though its signature isn't const.
    if (method(fn (*Object, [*]u8, u32) callconv(.c) HRESULT, stream, STREAM_INITIALIZE_FROM_MEMORY)(stream, @constCast(encoded.ptr), @intCast(encoded.len)) < 0) return error.CreateStreamFailed;

    var decoder_ptr: ?*Object = null;
    if (method(fn (*Object, *Object, ?*const win32.GUID, u32, *?*Object) callconv(.c) HRESULT, factory, FACTORY_CREATE_DECODER_FROM_STREAM)(factory, stream, null, 0, &decoder_ptr) < 0) return error.DecodeFailed;
    const decoder = decoder_ptr orelse return error.DecodeFailed;
    defer release(decoder);

    var frame_ptr: ?*Object = null;
    if (method(fn (*Object, u32, *?*Object) callconv(.c) HRESULT, decoder, DECODER_GET_FRAME)(decoder, 0, &frame_ptr) < 0) return error.DecodeFailed;
    const frame = frame_ptr orelse return error.DecodeFailed;
    defer release(frame);

    var converter_ptr: ?*Object = null;
    if (method(fn (*Object, *?*Object) callconv(.c) HRESULT, factory, FACTORY_CREATE_FORMAT_CONVERTER)(factory, &converter_ptr) < 0) return error.ConvertFailed;
    const converter = converter_ptr orelse return error.ConvertFailed;
    defer release(converter);
    const initialize = method(fn (*Object, *Object, *const win32.GUID, u32, ?*Object, f64, u32) callconv(.c) HRESULT, converter, CONVERTER_INITIALIZE);
    if (initialize(converter, frame, &GUID_WIC_PIXEL_FORMAT_32BPP_RGBA, 0, null, 0, 0) < 0) return error.ConvertFailed;

    var width: u32 = 0;
    var height: u32 = 0;
    if (method(fn (*Object, *u32, *u32) callconv(.c) HRESULT, converter, SOURCE_GET_SIZE)(converter, &width, &height) < 0) return error.DecodeFailed;
    if (width == 0 or height == 0 or width > MAX_SIDE or height > MAX_SIDE) return error.InvalidImageSize;

    const pixels = try allocator.alloc(u8, width * height * 4);
    errdefer allocator.free(pixels);
    const copy_pixels = method(fn (*Object, ?*const anyopaque, u32, u32, [*]u8) callconv(.c) HRESULT, converter, SOURCE_COPY_PIXELS);
    if (copy_pixels(converter, null, width * 4, @intCast(pixels.len), pixels.ptr) < 0) return error.CopyPixelsFailed;
    return .{ .pixels = pixels, .width = width, .height = height };
}

/// A COM method by vtable slot: declaring WIC's whole vtables for these few calls would dwarf the module.
fn method(comptime Fn: type, object: *Object, comptime slot: usize) *const Fn {
    const vtable: *const [*]const *const anyopaque = @ptrCast(@alignCast(object));
    return @ptrCast(vtable.*[slot]);
}

fn release(object: *Object) void {
    _ = method(fn (*Object) callconv(.c) u32, object, RELEASE)(object);
}
