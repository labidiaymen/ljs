//! HOST runtime (Node axis, spec 102/113 — NOT ECMA-262): the `fs` (sync subset) and `os` core
//! modules, extracted from `host_require.zig` to keep that file focused on the module system. Installed
//! host-only for `ljs run`; never on the Test262 engine surface. Dispatched from
//! `host_require.coreModuleFn` (which routes `fs`/`os`/`fs_stats` here); method objects are registered
//! by `host_require.defineCoreMethod`.
const std = @import("std");
const builtin = @import("builtin");
const Value = @import("value.zig").Value;
const Object = @import("object.zig").Object;
const Completion = @import("completion.zig").Completion;
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;
const host_require = @import("host_require.zig");
const host_buffer = @import("host_buffer.zig");

const is_windows = builtin.os.tag == .windows;

/// ToString an argument via the engine (so a non-string arg coerces like Node's, e.g. a number).
pub fn argString(self: *Interpreter, v: Value) EvalError!Completion {
    return self.toStringValuePub(v);
}

// ── fs methods (sync subset) ────────────────────────────────────────────────────

pub fn fsMethod(self: *Interpreter, method: []const u8, args: []const Value) EvalError!Completion {
    const arena = self.arena;
    const eq = std.mem.eql;

    if (eq(u8, method, "readFileSync")) {
        const pc = try argString(self, if (args.len > 0) args[0] else .undefined);
        if (pc.isAbrupt()) return pc;
        const content = std.Io.Dir.cwd().readFileAlloc(self.io, pc.normal.string, arena, .limited(64 << 20)) catch
            return fsError(self, "ENOENT", method, pc.normal.string);
        // An encoding (string arg / { encoding } option) → return a string; else a Buffer.
        var enc: ?[]const u8 = null;
        if (args.len > 1 and args[1] == .string) enc = args[1].string;
        if (args.len > 1 and args[1] == .object) {
            if (args[1].object.get("encoding")) |ev| if (ev == .string) {
                enc = ev.string;
            };
        }
        if (enc != null and !std.mem.eql(u8, enc.?, "buffer")) {
            return .{ .normal = .{ .string = content } };
        }
        // No encoding → a Buffer of the bytes.
        const buf = host_buffer.makeBufferFromBytes(self, content) catch return error.OutOfMemory;
        return .{ .normal = .{ .object = buf } };
    }
    if (eq(u8, method, "existsSync")) {
        const pc = try argString(self, if (args.len > 0) args[0] else .undefined);
        if (pc.isAbrupt()) return pc;
        const ok = blk: {
            std.Io.Dir.cwd().access(self.io, pc.normal.string, .{}) catch break :blk false;
            break :blk true;
        };
        return .{ .normal = .{ .boolean = ok } };
    }
    if (eq(u8, method, "writeFileSync")) {
        const pc = try argString(self, if (args.len > 0) args[0] else .undefined);
        if (pc.isAbrupt()) return pc;
        var bytes: []const u8 = "";
        const dc = try dataBytes(self, if (args.len > 1) args[1] else .undefined, &bytes);
        if (dc.isAbrupt()) return dc;
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = pc.normal.string, .data = bytes }) catch
            return fsError(self, "EACCES", method, pc.normal.string);
        return .{ .normal = .undefined };
    }
    if (eq(u8, method, "statSync")) {
        const pc = try argString(self, if (args.len > 0) args[0] else .undefined);
        if (pc.isAbrupt()) return pc;
        const st = std.Io.Dir.cwd().statFile(self.io, pc.normal.string, .{}) catch
            return fsError(self, "ENOENT", method, pc.normal.string);
        return .{ .normal = .{ .object = try makeStats(self, st) } };
    }
    if (eq(u8, method, "readdirSync")) {
        const pc = try argString(self, if (args.len > 0) args[0] else .undefined);
        if (pc.isAbrupt()) return pc;
        return readdir(self, pc.normal.string, method);
    }
    if (eq(u8, method, "mkdirSync")) {
        const pc = try argString(self, if (args.len > 0) args[0] else .undefined);
        if (pc.isAbrupt()) return pc;
        // { recursive: true } → makePath; else a single makeDir.
        var recursive = false;
        if (args.len > 1 and args[1] == .object) {
            if (args[1].object.get("recursive")) |rv| recursive = (rv == .boolean and rv.boolean);
        }
        if (recursive) {
            std.Io.Dir.cwd().createDirPath(self.io, pc.normal.string) catch
                return fsError(self, "EACCES", method, pc.normal.string);
        } else {
            std.Io.Dir.cwd().createDir(self.io, pc.normal.string, .default_dir) catch
                return fsError(self, "EEXIST", method, pc.normal.string);
        }
        return .{ .normal = .undefined };
    }
    if (eq(u8, method, "appendFileSync")) {
        const pc = try argString(self, if (args.len > 0) args[0] else .undefined);
        if (pc.isAbrupt()) return pc;
        var bytes: []const u8 = "";
        const dc = try dataBytes(self, if (args.len > 1) args[1] else .undefined, &bytes);
        if (dc.isAbrupt()) return dc;
        // Append = (existing ++ new); a missing file starts empty (Node creates it).
        const existing = std.Io.Dir.cwd().readFileAlloc(self.io, pc.normal.string, arena, .limited(64 << 20)) catch "";
        const combined = std.mem.concat(arena, u8, &.{ existing, bytes }) catch return error.OutOfMemory;
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = pc.normal.string, .data = combined }) catch
            return fsError(self, "EACCES", method, pc.normal.string);
        return .{ .normal = .undefined };
    }
    if (eq(u8, method, "unlinkSync")) {
        const pc = try argString(self, if (args.len > 0) args[0] else .undefined);
        if (pc.isAbrupt()) return pc;
        std.Io.Dir.cwd().deleteFile(self.io, pc.normal.string) catch
            return fsError(self, "ENOENT", method, pc.normal.string);
        return .{ .normal = .undefined };
    }
    if (eq(u8, method, "rmSync")) {
        const pc = try argString(self, if (args.len > 0) args[0] else .undefined);
        if (pc.isAbrupt()) return pc;
        var recursive = false;
        var force = false;
        if (args.len > 1 and args[1] == .object) {
            if (args[1].object.get("recursive")) |rv| recursive = (rv == .boolean and rv.boolean);
            if (args[1].object.get("force")) |fv| force = (fv == .boolean and fv.boolean);
        }
        if (recursive) {
            std.Io.Dir.cwd().deleteTree(self.io, pc.normal.string) catch
                if (!force) return fsError(self, "ENOENT", method, pc.normal.string);
        } else {
            std.Io.Dir.cwd().deleteFile(self.io, pc.normal.string) catch
                if (!force) return fsError(self, "ENOENT", method, pc.normal.string);
        }
        return .{ .normal = .undefined };
    }
    if (eq(u8, method, "rmdirSync")) {
        const pc = try argString(self, if (args.len > 0) args[0] else .undefined);
        if (pc.isAbrupt()) return pc;
        std.Io.Dir.cwd().deleteDir(self.io, pc.normal.string) catch
            return fsError(self, "ENOENT", method, pc.normal.string);
        return .{ .normal = .undefined };
    }
    if (eq(u8, method, "renameSync")) {
        const oc = try argString(self, if (args.len > 0) args[0] else .undefined);
        if (oc.isAbrupt()) return oc;
        const nc = try argString(self, if (args.len > 1) args[1] else .undefined);
        if (nc.isAbrupt()) return nc;
        const cwd = std.Io.Dir.cwd();
        cwd.rename(oc.normal.string, cwd, nc.normal.string, self.io) catch
            return fsError(self, "ENOENT", method, oc.normal.string);
        return .{ .normal = .undefined };
    }
    if (eq(u8, method, "copyFileSync")) {
        const sc = try argString(self, if (args.len > 0) args[0] else .undefined);
        if (sc.isAbrupt()) return sc;
        const dc2 = try argString(self, if (args.len > 1) args[1] else .undefined);
        if (dc2.isAbrupt()) return dc2;
        const cwd = std.Io.Dir.cwd();
        cwd.copyFile(sc.normal.string, cwd, dc2.normal.string, self.io, .{}) catch
            return fsError(self, "ENOENT", method, sc.normal.string);
        return .{ .normal = .undefined };
    }
    if (eq(u8, method, "accessSync")) {
        const pc = try argString(self, if (args.len > 0) args[0] else .undefined);
        if (pc.isAbrupt()) return pc;
        std.Io.Dir.cwd().access(self.io, pc.normal.string, .{}) catch
            return fsError(self, "ENOENT", method, pc.normal.string);
        return .{ .normal = .undefined };
    }
    return .{ .normal = .undefined };
}

/// Coerce a write/append data arg to bytes into `out`: a Buffer/Uint8Array → its bytes; else ToString.
fn dataBytes(self: *Interpreter, v: Value, out: *[]const u8) EvalError!Completion {
    if (v == .object) {
        if (v.object.typed_array) |ta| {
            if (ta.buffer.array_buffer) |ab| {
                const start = ta.byte_offset;
                const end = start + ta.array_length;
                if (end <= ab.bytes.len) {
                    out.* = ab.bytes[start..end];
                    return .{ .normal = .undefined };
                }
            }
        }
    }
    const sc = try argString(self, v);
    if (sc.isAbrupt()) return sc;
    out.* = sc.normal.string;
    return .{ .normal = .undefined };
}

/// A minimal `fs.Stats` object: `{ size, isFile(), isDirectory() }` (predicates read a baked-in flag).
fn makeStats(self: *Interpreter, st: std.Io.File.Stat) EvalError!*Object {
    const arena = self.arena;
    const obj = try Object.create(arena, self.objectProto());
    try obj.defineData("size", .{ .number = @floatFromInt(st.size) }, true, true, true);
    const is_file = st.kind == .file;
    const is_dir = st.kind == .directory;
    try obj.defineData("%isFile%", .{ .boolean = is_file }, false, false, true);
    try obj.defineData("%isDirectory%", .{ .boolean = is_dir }, false, false, true);
    try host_require.defineCoreMethod(self, obj, "fs_stats", "isFile");
    try host_require.defineCoreMethod(self, obj, "fs_stats", "isDirectory");
    return obj;
}

/// Read a directory's entries into a JS array of name strings.
fn readdir(self: *Interpreter, dir_path: []const u8, method: []const u8) EvalError!Completion {
    const arena = self.arena;
    var dir = std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch
        return fsError(self, "ENOENT", method, dir_path);
    defer dir.close(self.io);
    const arr = try Object.createArray(arena, self.arrayProto());
    var it = dir.iterate();
    var i: usize = 0;
    while (it.next(self.io) catch null) |entry| {
        const name = arena.dupe(u8, entry.name) catch return error.OutOfMemory;
        try arr.arraySet(arena, i, .{ .string = name });
        i += 1;
    }
    return .{ .normal = .{ .object = arr } };
}

/// Build + throw a Node-style fs error with a `code` property.
fn fsError(self: *Interpreter, code: []const u8, syscall: []const u8, p: []const u8) EvalError!Completion {
    const arena = self.arena;
    const msg = std.fmt.allocPrint(arena, "{s}: {s} '{s}'", .{ code, syscall, p }) catch return error.OutOfMemory;
    const err = try Object.create(arena, self.errorProto("Error"));
    err.error_data = true;
    try err.set("name", .{ .string = "Error" });
    try err.set("message", .{ .string = msg });
    try err.defineData("code", .{ .string = code }, true, false, true);
    try err.defineData("syscall", .{ .string = syscall }, true, false, true);
    try err.defineData("path", .{ .string = p }, true, false, true);
    return .{ .throw = .{ .object = err } };
}

// ── os methods (minimal) ────────────────────────────────────────────────────────

pub fn osMethod(self: *Interpreter, method: []const u8, args: []const Value) EvalError!Completion {
    _ = args;
    const arena = self.arena;
    const eq = std.mem.eql;
    if (eq(u8, method, "platform")) return .{ .normal = .{ .string = osPlatform() } };
    if (eq(u8, method, "arch")) return .{ .normal = .{ .string = osArch() } };
    if (eq(u8, method, "type")) return .{ .normal = .{ .string = osType() } };
    if (eq(u8, method, "release")) return .{ .normal = .{ .string = "0.0.0" } };
    if (eq(u8, method, "endianness")) return .{ .normal = .{ .string = if (builtin.cpu.arch.endian() == .little) "LE" else "BE" } };
    if (eq(u8, method, "hostname")) return .{ .normal = .{ .string = "localhost" } };
    if (eq(u8, method, "totalmem")) return .{ .normal = .{ .number = 0 } };
    if (eq(u8, method, "freemem")) return .{ .normal = .{ .number = 0 } };
    if (eq(u8, method, "cpus")) return .{ .normal = .{ .object = try Object.createArray(arena, self.arrayProto()) } };
    if (eq(u8, method, "homedir")) {
        const home = osEnv(self, if (is_windows) "USERPROFILE" else "HOME") orelse (if (is_windows) "C:\\" else "/");
        return .{ .normal = .{ .string = home } };
    }
    if (eq(u8, method, "tmpdir")) {
        const tmp = osEnv(self, if (is_windows) "TEMP" else "TMPDIR") orelse (if (is_windows) "C:\\Windows\\Temp" else "/tmp");
        return .{ .normal = .{ .string = tmp } };
    }
    return .{ .normal = .undefined };
}

/// Read an env var off the installed `process.env` (so os.homedir/tmpdir reflect the run's environment).
fn osEnv(self: *Interpreter, key: []const u8) ?[]const u8 {
    const g = self.globals orelse return null;
    const proc = g.lookup("process") orelse return null;
    if (proc.value != .object) return null;
    const env_v = proc.value.object.get("env") orelse return null;
    if (env_v != .object) return null;
    const v = env_v.object.get(key) orelse return null;
    return if (v == .string and v.string.len > 0) v.string else null;
}

fn osPlatform() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "win32",
        .linux => "linux",
        .macos => "darwin",
        .freebsd => "freebsd",
        .openbsd => "openbsd",
        else => @tagName(builtin.os.tag),
    };
}
fn osArch() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64 => "x64",
        .x86 => "ia32",
        .aarch64 => "arm64",
        .arm => "arm",
        else => @tagName(builtin.cpu.arch),
    };
}
fn osType() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "Windows_NT",
        .linux => "Linux",
        .macos => "Darwin",
        else => @tagName(builtin.os.tag),
    };
}
