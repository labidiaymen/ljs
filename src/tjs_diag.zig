pub const CompileError = error{ ParseError, OutOfMemory };

/// A compile-time diagnostic, located in the .ts source.
pub const Diag = struct { line: u32 = 0, col: u32 = 0, msg: []const u8 = "syntax error" };
