//! TypeScript-syntax -> Zig -> native compiler seed.
//!
//! NOT part of the ECMAScript engine or the Test262 path. A SEPARATE,
//! self-contained front-end that takes a small statically-typed TypeScript
//! syntax subset and lowers it to Zig source, which `zig build-exe` then turns
//! into a native binary. Using Zig as the backend means we write the front-end
//! and lowering first; optimization, native codegen, and cross-compilation come
//! from Zig/LLVM.
//!
//! Current seed: inferred and typed `const`/`let`(immutable) and `var`(mutable) declarations
//! (`int`/`i32`/`i64`, `number`/`f64`, `bool`), arithmetic (`+ - * / %`, precedence + parens + unary `-`),
//! comparisons (`< > <= >= == !=`), `while` loops + assignment, typed objects (`type T = {…}` →
//! struct, object literals, field access), and `console.log`.
const std = @import("std");
const ast = @import("lumen_ast.zig");
const diag_mod = @import("lumen_diag.zig");
const lexer = @import("lumen_lexer.zig");
const types = @import("lumen_types.zig");

pub const CompileError = diag_mod.CompileError;
pub const Diag = diag_mod.Diag;

const Expr = ast.Expr;
const FieldInit = ast.FieldInit;
const Lexer = lexer.Lexer;
const Tok = lexer.Tok;

/// Builtins that lower to a Zig std wrapper (need __io/__alloc threaded in).
fn isBuiltin(name: []const u8) bool {
    return std.mem.eql(u8, name, "httpGet") or std.mem.eql(u8, name, "serve");
}

fn setDiag(diag: *Diag, line: u32, col: u32, msg: []const u8) CompileError {
    diag.* = .{ .line = line, .col = col, .msg = msg };
    return error.ParseError;
}

fn rejectUnsupportedDynamic(source: []const u8, diag: *Diag) CompileError!void {
    const eq = std.mem.eql;
    var lex = Lexer{ .src = source };
    var prev_was_dot = false;
    var prev_was_ident = false;
    var pending_dynamic_write_line: u32 = 0;
    var pending_dynamic_write_col: u32 = 0;
    var bracket_depth: u32 = 0;
    var bracket_candidate_line: u32 = 0;
    var bracket_candidate_col: u32 = 0;

    while (true) {
        const tok = lex.next() catch {
            return setDiag(diag, lex.tok_line, lex.tok_col, "syntax error");
        };
        switch (tok) {
            .eof => return,
            .ident => |name| {
                if (pending_dynamic_write_line != 0) {
                    pending_dynamic_write_line = 0;
                    pending_dynamic_write_col = 0;
                }
                if (eq(u8, name, "eval")) {
                    return setDiag(diag, lex.tok_line, lex.tok_col, "E_UNSUPPORTED_EVAL");
                }
                if (eq(u8, name, "require")) {
                    return setDiag(diag, lex.tok_line, lex.tok_col, "E_UNSUPPORTED_COMMONJS");
                }
                if (prev_was_dot and eq(u8, name, "prototype")) {
                    return setDiag(diag, lex.tok_line, lex.tok_col, "E_UNSUPPORTED_PROTOTYPE");
                }
                if (prev_was_dot) {
                    pending_dynamic_write_line = lex.tok_line;
                    pending_dynamic_write_col = lex.tok_col;
                }
                prev_was_dot = false;
                prev_was_ident = true;
            },
            .op => |ch| {
                if (ch == '=' and pending_dynamic_write_line != 0) {
                    return setDiag(diag, pending_dynamic_write_line, pending_dynamic_write_col, "E_DYNAMIC_PROPERTY_WRITE");
                }
                if (ch == '[' and prev_was_ident and bracket_depth == 0) {
                    bracket_candidate_line = lex.tok_line;
                    bracket_candidate_col = lex.tok_col;
                    bracket_depth = 1;
                } else if (ch == '[' and bracket_depth > 0) {
                    bracket_depth += 1;
                } else if (ch == ']' and bracket_depth > 0) {
                    bracket_depth -= 1;
                    if (bracket_depth == 0) {
                        pending_dynamic_write_line = bracket_candidate_line;
                        pending_dynamic_write_col = bracket_candidate_col;
                    }
                } else if (pending_dynamic_write_line != 0 and ch != '=') {
                    pending_dynamic_write_line = 0;
                    pending_dynamic_write_col = 0;
                }
                prev_was_dot = ch == '.';
                prev_was_ident = false;
            },
            else => {
                if (pending_dynamic_write_line != 0) {
                    pending_dynamic_write_line = 0;
                    pending_dynamic_write_col = 0;
                }
                prev_was_dot = false;
                prev_was_ident = false;
            },
        }
    }
}

// ── parser ───────────────────────────────────────────────────────────────────
const Parser = struct {
    arena: std.mem.Allocator,
    lex: Lexer,
    cur: Tok,
    cur_line: u32 = 1, // source line of `cur`
    cur_col: u32 = 1, // source column of `cur`
    vars: std.StringHashMapUnmanaged([]const u8) = .empty, // declared variable names and normalized types
    last_err: []const u8 = "syntax error", // message for the next diagnostic
    uses_io: bool = false, // any io builtin used → emit the std.process.Init main (io + allocator)
    needs_httpget: bool = false, // emit the __httpGet wrapper
    needs_serve: bool = false, // emit the __serve wrapper

    fn declare(self: *Parser, name: []const u8, zty: []const u8) CompileError!void {
        self.vars.put(self.arena, name, zty) catch return error.OutOfMemory;
    }
    fn undefined_(self: *Parser, name: []const u8) CompileError {
        self.last_err = std.fmt.allocPrint(self.arena, "undefined variable '{s}'", .{name}) catch "undefined variable";
        return error.ParseError;
    }
    fn exprType(self: *Parser, e: *const Expr) ?[]const u8 {
        return switch (e.*) {
            .var_ref => |name| self.vars.get(name),
            .neg => |inner| self.exprType(inner),
            else => types.inferExprType(e),
        };
    }

    fn init(arena: std.mem.Allocator, src: []const u8) CompileError!Parser {
        var lex = Lexer{ .src = src };
        const first = try lex.next();
        return .{ .arena = arena, .lex = lex, .cur = first, .cur_line = lex.tok_line, .cur_col = lex.tok_col };
    }
    fn advance(self: *Parser) CompileError!void {
        self.cur = try self.lex.next();
        self.cur_line = self.lex.tok_line;
        self.cur_col = self.lex.tok_col;
    }
    fn isOp(self: *Parser, ch: u8) bool {
        return self.cur == .op and self.cur.op == ch;
    }
    fn expectOp(self: *Parser, ch: u8) CompileError!void {
        if (!self.isOp(ch)) return error.ParseError;
        try self.advance();
    }
    fn isKw(self: *Parser, kw: []const u8) bool {
        return self.cur == .ident and std.mem.eql(u8, self.cur.ident, kw);
    }
    fn node(self: *Parser, e: Expr) CompileError!*Expr {
        const p = try self.arena.create(Expr);
        p.* = e;
        return p;
    }

    fn parseExpr(self: *Parser) CompileError!*Expr {
        return self.parseCmp();
    }
    fn parseCmp(self: *Parser) CompileError!*Expr {
        var left = try self.parseAdd();
        if (self.cur == .cmp) {
            const op = self.cur.cmp;
            try self.advance();
            const right = try self.parseAdd();
            left = try self.node(.{ .cmp = .{ .op = op, .l = left, .r = right } });
        }
        return left;
    }
    fn parseAdd(self: *Parser) CompileError!*Expr {
        var left = try self.parseMul();
        while (self.isOp('+') or self.isOp('-')) {
            const op = self.cur.op;
            try self.advance();
            const right = try self.parseMul();
            left = try self.node(.{ .bin = .{ .op = op, .l = left, .r = right } });
        }
        return left;
    }
    fn parseMul(self: *Parser) CompileError!*Expr {
        var left = try self.parseUnary();
        while (self.isOp('*') or self.isOp('/') or self.isOp('%')) {
            const op = self.cur.op;
            try self.advance();
            const right = try self.parseUnary();
            left = try self.node(.{ .bin = .{ .op = op, .l = left, .r = right } });
        }
        return left;
    }
    fn parseUnary(self: *Parser) CompileError!*Expr {
        if (self.isOp('-')) {
            try self.advance();
            return self.node(.{ .neg = try self.parseUnary() });
        }
        return self.parsePostfix();
    }
    fn parsePostfix(self: *Parser) CompileError!*Expr {
        var e = try self.parsePrimary();
        while (self.isOp('.')) {
            try self.advance();
            if (self.cur != .ident) return error.ParseError;
            const name = self.cur.ident;
            try self.advance();
            e = try self.node(.{ .field = .{ .obj = e, .name = name } });
        }
        return e;
    }
    fn parsePrimary(self: *Parser) CompileError!*Expr {
        if (self.cur == .num) {
            const v = self.cur.num;
            try self.advance();
            return self.node(.{ .num = v });
        }
        if (self.cur == .str) {
            const s = self.cur.str;
            try self.advance();
            return self.node(.{ .str = s });
        }
        if (self.cur == .ident) {
            const name = self.cur.ident;
            if (isBuiltin(name)) {
                try self.advance();
                try self.expectOp('(');
                var args: std.ArrayListUnmanaged(*Expr) = .empty;
                while (!self.isOp(')')) {
                    try args.append(self.arena, try self.parseExpr());
                    if (self.isOp(',')) try self.advance() else break;
                }
                try self.expectOp(')');
                self.uses_io = true;
                if (std.mem.eql(u8, name, "httpGet")) self.needs_httpget = true;
                if (std.mem.eql(u8, name, "serve")) self.needs_serve = true;
                return self.node(.{ .call = .{ .name = name, .args = try args.toOwnedSlice(self.arena) } });
            }
            if (!self.vars.contains(name)) return self.undefined_(name);
            try self.advance();
            return self.node(.{ .var_ref = name });
        }
        if (self.isOp('(')) {
            try self.advance();
            const e = try self.parseExpr();
            try self.expectOp(')');
            return e;
        }
        if (self.isOp('{')) {
            try self.advance();
            var fields: std.ArrayListUnmanaged(FieldInit) = .empty;
            while (!self.isOp('}')) {
                if (self.cur != .ident) return error.ParseError;
                const fname = self.cur.ident;
                try self.advance();
                try self.expectOp(':');
                const v = try self.parseExpr();
                try fields.append(self.arena, .{ .name = fname, .value = v });
                if (self.isOp(',')) try self.advance() else break;
            }
            try self.expectOp('}');
            return self.node(.{ .obj = try fields.toOwnedSlice(self.arena) });
        }
        return error.ParseError;
    }
};

// ── emit ─────────────────────────────────────────────────────────────────────
fn emitExpr(e: *const Expr, w: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    switch (e.*) {
        .num => |v| try w.print(arena, "{d}", .{v}),
        .str => |s| {
            try w.append(arena, '"');
            for (s) |ch| {
                if (ch == '"' or ch == '\\') try w.append(arena, '\\');
                try w.append(arena, ch);
            }
            try w.append(arena, '"');
        },
        .call => |cl| {
            // builtins lower to a Zig std wrapper taking (__io, __alloc, args...).
            if (std.mem.eql(u8, cl.name, "httpGet")) {
                try w.appendSlice(arena, "__httpGet(__io, __alloc, ");
                if (cl.args.len > 0) try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.name, "serve")) {
                try w.appendSlice(arena, "__serve(__io, __alloc, ");
                if (cl.args.len > 0) try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                if (cl.args.len > 1) try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            }
        },
        .var_ref => |name| try w.appendSlice(arena, name),
        .neg => |inner| {
            try w.appendSlice(arena, "-(");
            try emitExpr(inner, w, arena);
            try w.append(arena, ')');
        },
        .bin => |b| {
            if (b.op == '%') {
                // Zig's `%` rejects signed operands → use @rem (operands are non-negative here).
                try w.appendSlice(arena, "@rem(");
                try emitExpr(b.l, w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(b.r, w, arena);
                try w.append(arena, ')');
            } else {
                try w.append(arena, '(');
                try emitExpr(b.l, w, arena);
                try w.print(arena, " {c} ", .{b.op});
                try emitExpr(b.r, w, arena);
                try w.append(arena, ')');
            }
        },
        .cmp => |b| {
            try w.append(arena, '(');
            try emitExpr(b.l, w, arena);
            try w.print(arena, " {s} ", .{b.op});
            try emitExpr(b.r, w, arena);
            try w.append(arena, ')');
        },
        .obj => |fields| {
            try w.appendSlice(arena, ".{ ");
            for (fields, 0..) |f, i| {
                if (i > 0) try w.appendSlice(arena, ", ");
                try w.print(arena, ".{s} = ", .{f.name});
                try emitExpr(f.value, w, arena);
            }
            try w.appendSlice(arena, " }");
        },
        .field => |fa| {
            try emitExpr(fa.obj, w, arena);
            try w.print(arena, ".{s}", .{fa.name});
        },
    }
}

/// Emit one executable statement (recurses for `while` bodies).
fn emitStmt(p: *Parser, out: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    const eq = std.mem.eql;
    if (p.cur != .ident) return error.ParseError;
    const kw = p.cur.ident;
    const stmt_line = p.cur_line;
    const stmt_col = p.cur_col;
    // Track the source line+col so a runtime panic can report the .ts location (Zig has no #line).
    try out.print(arena, "    __lumen_line = {d}; __lumen_col = {d};\n", .{ p.cur_line, p.cur_col });

    if (eq(u8, kw, "let") or eq(u8, kw, "const") or eq(u8, kw, "var")) {
        const mutable = eq(u8, kw, "var");
        try p.advance();
        if (p.cur != .ident) return error.ParseError;
        const name = p.cur.ident;
        try p.advance();
        var zty: ?[]const u8 = null;
        if (p.isOp(':')) {
            try p.advance();
            if (p.cur != .ident) return error.ParseError;
            zty = types.mapType(p.cur.ident) orelse p.cur.ident;
            try p.advance();
        }
        try p.expectOp('=');
        const e = try p.parseExpr();
        try p.expectOp(';');
        const final_zty = zty orelse p.exprType(e) orelse {
            p.last_err = "cannot infer variable type";
            return error.ParseError;
        };
        try p.declare(name, final_zty); // in scope after its initializer (so `let x = x` is undefined)
        try out.print(arena, "    {s} {s}: {s} = ", .{ if (mutable) "var" else "const", name, final_zty });
        try emitExpr(e, out, arena);
        try out.appendSlice(arena, ";\n");
    } else if (eq(u8, kw, "console")) {
        try p.advance();
        try p.expectOp('.');
        if (!p.isKw("log")) return error.ParseError;
        try p.advance();
        try p.expectOp('(');
        const e = try p.parseExpr();
        try p.expectOp(')');
        try p.expectOp(';');
        try out.appendSlice(arena, "    std.debug.print(\"{d}\\n\", .{");
        try emitExpr(e, out, arena);
        try out.appendSlice(arena, "});\n");
    } else if (eq(u8, kw, "while")) {
        try p.advance();
        try p.expectOp('(');
        const cond = try p.parseExpr();
        try p.expectOp(')');
        try p.expectOp('{');
        try out.appendSlice(arena, "    while (");
        try emitExpr(cond, out, arena);
        try out.appendSlice(arena, ") {\n");
        while (!p.isOp('}')) try emitStmt(p, out, arena);
        try p.expectOp('}');
        try out.appendSlice(arena, "    }\n");
    } else if (isBuiltin(kw)) {
        // expression statement: a builtin call, e.g. serve(8080, "hi");
        const e = try p.parseExpr();
        try p.expectOp(';');
        // `serve` is noreturn; other builtins return a value that must be discarded.
        try out.appendSlice(arena, if (std.mem.eql(u8, kw, "serve")) "    " else "    _ = ");
        try emitExpr(e, out, arena);
        try out.appendSlice(arena, ";\n");
    } else {
        // assignment: <name> = <expr> ;
        const name = kw;
        const expected_zty = p.vars.get(name) orelse return p.undefined_(name);
        try p.advance();
        try p.expectOp('=');
        const e = try p.parseExpr();
        try p.expectOp(';');
        const actual_zty = p.exprType(e) orelse {
            p.last_err = "cannot infer assignment type";
            p.cur_line = stmt_line;
            p.cur_col = stmt_col;
            return error.ParseError;
        };
        if (!types.sameType(expected_zty, actual_zty)) {
            p.last_err = "E_TYPE_MISMATCH";
            p.cur_line = stmt_line;
            p.cur_col = stmt_col;
            return error.ParseError;
        }
        try out.print(arena, "    {s} = ", .{name});
        try emitExpr(e, out, arena);
        try out.appendSlice(arena, ";\n");
    }
}

/// Parse every top-level construct, emitting struct defs into `decls` and statements into `body`.
fn lower(p: *Parser, decls: *std.ArrayListUnmanaged(u8), body: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    while (p.cur != .eof) {
        if (p.isKw("type")) {
            // type <Name> = { field: type, ... } ;   →   const Name = struct { field: ztype, ... };
            try p.advance();
            if (p.cur != .ident) return error.ParseError;
            const tname = p.cur.ident;
            try p.advance();
            try p.expectOp('=');
            try p.expectOp('{');
            try decls.print(arena, "const {s} = struct {{\n", .{tname});
            while (!p.isOp('}')) {
                if (p.cur != .ident) return error.ParseError;
                const fname = p.cur.ident;
                try p.advance();
                try p.expectOp(':');
                if (p.cur != .ident) return error.ParseError;
                const fty = types.mapType(p.cur.ident) orelse p.cur.ident;
                try p.advance();
                try decls.print(arena, "    {s}: {s},\n", .{ fname, fty });
                if (p.isOp(',')) try p.advance() else break;
            }
            try p.expectOp('}');
            if (p.isOp(';')) try p.advance();
            try decls.appendSlice(arena, "};\n");
        } else {
            try emitStmt(p, body, arena);
        }
    }
}

/// Compile TypeScript-syntax `source` (from `filename`) to Zig source text. On a compile-time error,
/// `diag` is filled (located in the .ts source) and `error.ParseError` returned. `filename` is also
/// embedded so a runtime panic reports the .ts location.
pub fn compileToZig(arena: std.mem.Allocator, source: []const u8, filename: []const u8, diag: *Diag) CompileError![]const u8 {
    try rejectUnsupportedDynamic(source, diag);

    var p = try Parser.init(arena, source);
    var decls: std.ArrayListUnmanaged(u8) = .empty; // top-level struct type definitions
    var body: std.ArrayListUnmanaged(u8) = .empty;

    lower(&p, &decls, &body, arena) catch |e| {
        diag.* = .{ .line = p.cur_line, .col = p.cur_col, .msg = p.last_err };
        return e;
    };

    // Sanitize the filename for a Zig string literal (backslashes/quotes break it).
    const safe_name = try arena.dupe(u8, filename);
    for (safe_name) |*ch| if (ch.* == '\\' or ch.* == '"') {
        ch.* = '/';
    };

    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(arena, "const std = @import(\"std\");\n");
    try out.print(arena, "const __lumen_file = \"{s}\";\n", .{safe_name});
    try out.appendSlice(arena, "var __lumen_line: u32 = 0;\nvar __lumen_col: u32 = 0;\n");
    // Embed the .ts source as a multiline string (no escaping needed) so the handler can show the line.
    try out.appendSlice(arena, "const __lumen_src =\n");
    {
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |l| {
            const t = std.mem.trimEnd(u8, l, "\r");
            try out.print(arena, "    \\\\{s}\n", .{t});
        }
    }
    try out.appendSlice(arena, ";\n");
    // Custom panic handler -> map the native runtime error back to the .ts source: file:line:col +
    // the offending source line + a caret.
    try out.appendSlice(arena,
        \\fn __lumenPanic(msg: []const u8, _: ?usize) noreturn {
        \\    std.debug.print("\n{s}:{d}:{d}: runtime error: {s}\n", .{ __lumen_file, __lumen_line, __lumen_col, msg });
        \\    var __it = std.mem.splitScalar(u8, __lumen_src, '\n');
        \\    var __n: u32 = 1;
        \\    while (__it.next()) |__l| : (__n += 1) {
        \\        if (__n == __lumen_line) {
        \\            std.debug.print("  {d} | {s}\n    | ", .{ __lumen_line, __l });
        \\            var __k: u32 = 1;
        \\            while (__k < __lumen_col) : (__k += 1) std.debug.print(" ", .{});
        \\            std.debug.print("^\n", .{});
        \\            break;
        \\        }
        \\    }
        \\    std.process.exit(1);
        \\}
        \\pub const panic = std.debug.FullPanic(__lumenPanic);
        \\
    );
    try out.appendSlice(arena, decls.items);

    if (p.needs_httpget) {
        // A real std.http one-shot GET, wrapped to a Lumen-friendly `i64` (status code, or -1 on error).
        try out.appendSlice(arena,
            \\fn __httpGet(io: std.Io, alloc: std.mem.Allocator, url: []const u8) i64 {
            \\    var client: std.http.Client = .{ .allocator = alloc, .io = io };
            \\    defer client.deinit();
            \\    client.ca_bundle.rescan(alloc, io, std.Io.Clock.now(.real, io)) catch return -1;
            \\    const res = client.fetch(.{ .location = .{ .url = url } }) catch return -1;
            \\    return @intFromEnum(res.status);
            \\}
            \\
        );
    }
    if (p.needs_serve) {
        // A real (blocking) HTTP server on std.Io.net — returns the same body to every request.
        try out.appendSlice(arena,
            \\fn __serve(io: std.Io, alloc: std.mem.Allocator, port: i64, body: []const u8) noreturn {
            \\    _ = alloc;
            \\    const addr = std.Io.net.IpAddress.parse("0.0.0.0", @intCast(port)) catch std.process.exit(1);
            \\    var server = addr.listen(io, .{ .reuse_address = true }) catch std.process.exit(1);
            \\    var hbuf: [256]u8 = undefined;
            \\    const head = std.fmt.bufPrint(&hbuf, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len}) catch std.process.exit(1);
            \\    while (true) {
            \\        const stream = server.accept(io) catch continue;
            \\        var wbuf: [2048]u8 = undefined;
            \\        var w = stream.writer(io, &wbuf);
            \\        w.interface.writeAll(head) catch {};
            \\        w.interface.writeAll(body) catch {};
            \\        w.interface.flush() catch {};
            \\        stream.close(io);
            \\    }
            \\}
            \\
        );
    }
    if (p.uses_io) {
        try out.appendSlice(arena, "pub fn main(__init: std.process.Init) !void {\n");
        try out.appendSlice(arena, "    const __io = __init.io;\n    const __alloc = __init.arena.allocator();\n");
    } else {
        try out.appendSlice(arena, "pub fn main() void {\n");
    }
    try out.appendSlice(arena, body.items);
    try out.appendSlice(arena, "}\n");
    return out.items;
}
