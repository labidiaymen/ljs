const std = @import("std");

const Summary = struct {
    checksum: i32,
    iterations: i32,
};

inline fn score(value: i32, salt: i32) i32 {
    var mixed = value * 31 + salt * 17;
    mixed = @rem(mixed, 100000);

    if (mixed < 0) {
        return @intCast(@abs(mixed));
    }

    return mixed;
}

fn runBenchmark(rounds: i32) i32 {
    const data = [_]i32{ 3, 11, 23, 31, 47, 59, 61, 73, 89, 97, 101, 113, 127, 131, 149, 157 };
    const empty: []const i32 = &.{};
    var checksum: i32 = 0;
    var cursor: i32 = 0;
    var i: i32 = 0;

    if (empty.len == 0) {
        const err = "empty-input";
        if (std.mem.startsWith(u8, err, "empty") and std.mem.indexOf(u8, err, "input") != null) {
            checksum = checksum + 13;
        }
        checksum = checksum + 1;
    }

    while (i < rounds) {
        const value = data[@intCast(cursor)];
        const mixed = score(value, @rem(i, 97));
        const bounded = @min(@max(mixed, 0), 90000);
        checksum = checksum + bounded;
        checksum = @rem(checksum, 1000000);

        if (value > 80) {
            checksum = checksum + @min(value, 100);
        } else {
            checksum = checksum + @max(value, 7);
        }

        cursor = cursor + 1;
        if (cursor == data.len) {
            cursor = 0;
        }

        i = i + 1;
    }

    return checksum;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const rounds = if (args.len > 1) try std.fmt.parseInt(i32, args[1], 10) else 1000000;
    const checksum = runBenchmark(rounds);
    const result = Summary{
        .checksum = checksum,
        .iterations = rounds,
    };

    std.debug.print("{d}\n", .{result.checksum});
}
