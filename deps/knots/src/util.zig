pub fn ReturnType(func: anytype) type {
    return @typeInfo(@TypeOf(func)).@"fn".return_type.?;
}
