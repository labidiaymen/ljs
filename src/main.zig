//! ljs command-line interface. See specs/001-test262-harness/contracts/cli.md.
//!   ljs eval "<source>"   evaluate a source string
//!   ljs run <file>        evaluate a source file
const std = @import("std");
const Io = std.Io;
const ljs = @import("ljs");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    var out_buf: [4096]u8 = undefined;
    var out_fw: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_fw.interface;

    var err_buf: [4096]u8 = undefined;
    var err_fw: Io.File.Writer = .init(.stderr(), io, &err_buf);
    const err = &err_fw.interface;

    if (args.len < 3) {
        try err.writeAll("usage: ljs <eval|run> <source|file>\n");
        try err.flush();
        std.process.exit(2);
    }

    const cmd = args[1];
    const arg = args[2];

    const source: []const u8 = if (std.mem.eql(u8, cmd, "eval"))
        arg
    else if (std.mem.eql(u8, cmd, "run"))
        std.Io.Dir.cwd().readFileAlloc(io, arg, arena, .limited(16 * 1024 * 1024)) catch {
            try err.print("error: cannot read file {s}\n", .{arg});
            try err.flush();
            std.process.exit(2);
        }
    else {
        try err.print("unknown command: {s}\n", .{cmd});
        try err.flush();
        std.process.exit(2);
    };

    const result = try ljs.evaluate(arena, source, .sloppy);
    switch (result) {
        .normal => |v| {
            try v.writeDisplay(out);
            try out.writeAll("\n");
            try out.flush();
        },
        .thrown => |v| {
            try err.writeAll("Uncaught ");
            try v.writeDisplay(err);
            try err.writeAll("\n");
            try err.flush();
            std.process.exit(1);
        },
        .syntax_error => |m| {
            try err.print("SyntaxError: {s}\n", .{m});
            try err.flush();
            std.process.exit(1);
        },
        .step_limit => {
            try err.writeAll("RangeError: step limit exceeded\n");
            try err.flush();
            std.process.exit(1);
        },
    }
}
