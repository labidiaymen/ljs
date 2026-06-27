const std = @import("std");
const __lumen_file = "specs/001-typescript-to-zig-native/examples/valid/function-hoist.ts";
var __lumen_line: u32 = 0;
var __lumen_col: u32 = 0;
const __lumen_src =
    \\console.log(add(4, 6));
    \\
    \\function add(a: int, b: int): int {
    \\  return a + b;
    \\}
    \\
    \\
;
fn __lumenPanic(msg: []const u8, _: ?usize) noreturn {
    std.debug.print("\n{s}:{d}:{d}: runtime error: {s}\n", .{ __lumen_file, __lumen_line, __lumen_col, msg });
    var __it = std.mem.splitScalar(u8, __lumen_src, '\n');
    var __n: u32 = 1;
    while (__it.next()) |__l| : (__n += 1) {
        if (__n == __lumen_line) {
            std.debug.print("  {d} | {s}\n    | ", .{ __lumen_line, __l });
            var __k: u32 = 1;
            while (__k < __lumen_col) : (__k += 1) std.debug.print(" ", .{});
            std.debug.print("^\n", .{});
            break;
        }
    }
    std.process.exit(1);
}
pub const panic = std.debug.FullPanic(__lumenPanic);
fn add(a: i32, b: i32) i32 {
    __lumen_line = 4; __lumen_col = 3;
    return (a + b);
}
pub fn main() void {
    __lumen_line = 1; __lumen_col = 1;
    std.debug.print("{d}\n", .{add(4, 6)});
    __lumen_line = 3; __lumen_col = 1;
}
