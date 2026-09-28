//! Root of `zig build test`: the modules with unit tests, which can run without the app or Windows UI.
test {
    _ = @import("chatlog/lines.zig");
    _ = @import("chatlog/utf16.zig");
}
