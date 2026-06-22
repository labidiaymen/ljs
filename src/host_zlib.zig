//! HOST runtime (Node axis — NOT ECMA-262): a focused `zlib` module. Express's dependency tree
//! (`body-parser`, `destroy`) requires `zlib` at load time: `body-parser` calls
//! `createGunzip()`/`createInflate()` ONLY when decompressing a `Content-Encoding: gzip/deflate`
//! request body, and `destroy` does `stream instanceof zlib.Gunzip` for cleanup. So loading + serving
//! a plain request needs the module present with the factory functions + the stream classes; the
//! actual (de)compression is lazy. The transform streams are `stream.PassThrough` for now (a real
//! flate codec is a follow-up); the sync helpers throw a clear "not implemented" until then.
//! CLI/host-only; never on the Test262 path.
const std = @import("std");
const Value = @import("value.zig").Value;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const Completion = @import("completion.zig").Completion;
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;
const host_require = @import("host_require.zig");

const factories = [_][]const u8{
    "createGzip",             "createGunzip",     "createDeflate", "createInflate",
    "createDeflateRaw",       "createInflateRaw", "createUnzip",   "createBrotliCompress",
    "createBrotliDecompress",
};
const classes = [_][]const u8{
    "Gzip",             "Gunzip",     "Deflate", "Inflate",
    "DeflateRaw",       "InflateRaw", "Unzip",   "BrotliCompress",
    "BrotliDecompress", "Zlib",
};
const sync_fns = [_][]const u8{
    "gzipSync",             "gunzipSync",     "deflateSync", "inflateSync",
    "deflateRawSync",       "inflateRawSync", "unzipSync",   "brotliCompressSync",
    "brotliDecompressSync",
};
const async_fns = [_][]const u8{
    "gzip",             "gunzip",     "deflate", "inflate",
    "deflateRaw",       "inflateRaw", "unzip",   "brotliCompress",
    "brotliDecompress",
};

fn fnObj(self: *Interpreter, name: []const u8) EvalError!*Object {
    const f = try Object.createNative(self.arena, .zlib_method, name);
    f.prototype = self.functionProto();
    try f.defineData("name", .{ .string = name }, false, false, true);
    return f;
}

pub fn build(self: *Interpreter) EvalError!*Object {
    const mod = try Object.create(self.arena, self.objectProto());
    inline for (.{ factories, classes, sync_fns, async_fns }) |group| {
        for (group) |n| try mod.defineData(n, .{ .object = try fnObj(self, n) }, true, false, true);
    }
    // zlib.constants — the flush/strategy/return-code enum (the values packages branch on).
    const constants = try Object.create(self.arena, self.objectProto());
    const C = [_]struct { k: []const u8, v: f64 }{
        .{ .k = "Z_NO_FLUSH", .v = 0 },            .{ .k = "Z_PARTIAL_FLUSH", .v = 1 },        .{ .k = "Z_SYNC_FLUSH", .v = 2 },
        .{ .k = "Z_FULL_FLUSH", .v = 3 },          .{ .k = "Z_FINISH", .v = 4 },               .{ .k = "Z_BLOCK", .v = 5 },
        .{ .k = "Z_OK", .v = 0 },                  .{ .k = "Z_STREAM_END", .v = 1 },           .{ .k = "Z_NEED_DICT", .v = 2 },
        .{ .k = "Z_BUF_ERROR", .v = -5 },          .{ .k = "Z_NO_COMPRESSION", .v = 0 },       .{ .k = "Z_BEST_SPEED", .v = 1 },
        .{ .k = "Z_BEST_COMPRESSION", .v = 9 },    .{ .k = "Z_DEFAULT_COMPRESSION", .v = -1 }, .{ .k = "Z_DEFAULT_STRATEGY", .v = 0 },
        .{ .k = "Z_DEFAULT_WINDOWBITS", .v = 15 },
    };
    for (C) |c| try constants.defineData(c.k, .{ .number = c.v }, true, true, true);
    try mod.defineData("constants", .{ .object = constants }, true, false, true);
    // Node also mirrors the constants directly on the module.
    for (C) |c| try mod.defineData(c.k, .{ .number = c.v }, true, false, true);
    return mod;
}

/// A `stream.PassThrough` instance — the placeholder transform for a (de)compression stream.
fn makePassThrough(self: *Interpreter) EvalError!Completion {
    const sc = try host_require.loadCoreModulePub(self, "stream");
    if (sc.isAbrupt()) return sc;
    if (sc.normal != .object) return self.throwError("Error", "zlib: stream module unavailable");
    const pt = sc.normal.object.get("PassThrough") orelse return self.throwError("Error", "zlib: PassThrough unavailable");
    if (pt != .object) return self.throwError("Error", "zlib: PassThrough unavailable");
    return self.construct(pt.object, &.{});
}

pub fn method(self: *Interpreter, func: *Object, this_val: Value, args: []const Value) EvalError!Completion {
    _ = args;
    const name = func.native_name;
    const eq = std.mem.eql;
    // Factory functions + the class constructors (`new zlib.Gunzip()`) → a PassThrough transform.
    inline for (factories) |f| if (eq(u8, name, f)) return makePassThrough(self);
    inline for (classes) |c| if (eq(u8, name, c)) {
        // As a constructor (`new`) → a transform instance; as a plain call, also return one.
        return makePassThrough(self);
    };
    _ = this_val;
    // Sync / async (de)compression — a real flate codec is a follow-up. Clear error until then.
    inline for (sync_fns ++ async_fns) |s| if (eq(u8, name, s)) {
        return self.throwError("Error", "zlib: compression not yet implemented (load + transform-passthrough only)");
    };
    return .{ .normal = .undefined };
}
