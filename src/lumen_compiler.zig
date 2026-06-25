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
const check = @import("lumen_check.zig");
const diag_mod = @import("lumen_diag.zig");
const lexer = @import("lumen_lexer.zig");
const types = @import("lumen_types.zig");

pub const CompileError = diag_mod.CompileError;
pub const Diag = diag_mod.Diag;

const Expr = ast.Expr;
const FieldInit = ast.FieldInit;
const Lexer = lexer.Lexer;
const Program = ast.Program;
const Stmt = ast.Stmt;
const Tok = lexer.Tok;

const SourceLoc = struct { line: u32, col: u32 };

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
    last_err: []const u8 = "syntax error", // message for the next diagnostic

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
                return self.node(.{ .call = .{ .name = name, .args = try args.toOwnedSlice(self.arena) } });
            }
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

    fn parseTypeDecl(self: *Parser, line: u32, col: u32) CompileError!Stmt {
        try self.advance();
        if (self.cur != .ident) return error.ParseError;
        const tname = self.cur.ident;
        try self.advance();
        try self.expectOp('=');
        try self.expectOp('{');
        var fields: std.ArrayListUnmanaged(ast.TypeField) = .empty;
        while (!self.isOp('}')) {
            if (self.cur != .ident) return error.ParseError;
            const fname = self.cur.ident;
            try self.advance();
            try self.expectOp(':');
            if (self.cur != .ident) return error.ParseError;
            const annotation = self.cur.ident;
            try self.advance();
            try fields.append(self.arena, .{ .name = fname, .annotation = annotation });
            if (self.isOp(',')) try self.advance() else break;
        }
        try self.expectOp('}');
        if (self.isOp(';')) try self.advance();
        return .{ .type_decl = .{ .name = tname, .fields = try fields.toOwnedSlice(self.arena), .line = line, .col = col } };
    }

    fn parseStmt(self: *Parser) CompileError!Stmt {
        const eq = std.mem.eql;
        if (self.cur != .ident) return error.ParseError;
        const kw = self.cur.ident;
        const line = self.cur_line;
        const col = self.cur_col;

        if (eq(u8, kw, "type")) return self.parseTypeDecl(line, col);

        if (eq(u8, kw, "let") or eq(u8, kw, "const") or eq(u8, kw, "var")) {
            const mutable = eq(u8, kw, "var");
            try self.advance();
            if (self.cur != .ident) return error.ParseError;
            const name = self.cur.ident;
            try self.advance();
            var annotation: ?[]const u8 = null;
            if (self.isOp(':')) {
                try self.advance();
                if (self.cur != .ident) return error.ParseError;
                annotation = self.cur.ident;
                try self.advance();
            }
            try self.expectOp('=');
            const initial_value = try self.parseExpr();
            try self.expectOp(';');
            return .{ .var_decl = .{ .mutable = mutable, .name = name, .annotation = annotation, .init = initial_value, .line = line, .col = col } };
        }

        if (eq(u8, kw, "console")) {
            try self.advance();
            try self.expectOp('.');
            if (!self.isKw("log")) return error.ParseError;
            try self.advance();
            try self.expectOp('(');
            const value = try self.parseExpr();
            try self.expectOp(')');
            try self.expectOp(';');
            return .{ .console_log = .{ .value = value, .line = line, .col = col } };
        }

        if (eq(u8, kw, "while")) {
            try self.advance();
            try self.expectOp('(');
            const cond = try self.parseExpr();
            try self.expectOp(')');
            try self.expectOp('{');
            var body: std.ArrayListUnmanaged(Stmt) = .empty;
            while (!self.isOp('}')) try body.append(self.arena, try self.parseStmt());
            try self.expectOp('}');
            return .{ .while_stmt = .{ .cond = cond, .body = try body.toOwnedSlice(self.arena), .line = line, .col = col } };
        }

        if (isBuiltin(kw)) {
            const value = try self.parseExpr();
            try self.expectOp(';');
            return .{ .expr_stmt = .{ .value = value, .line = line, .col = col } };
        }

        const name = kw;
        try self.advance();
        try self.expectOp('=');
        const value = try self.parseExpr();
        try self.expectOp(';');
        return .{ .assign = .{ .name = name, .value = value, .line = line, .col = col } };
    }

    fn parseProgram(self: *Parser) CompileError!Program {
        var stmts: std.ArrayListUnmanaged(Stmt) = .empty;
        while (self.cur != .eof) try stmts.append(self.arena, try self.parseStmt());
        return .{ .stmts = try stmts.toOwnedSlice(self.arena) };
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

fn emitStmt(stmt: *const Stmt, decls: *std.ArrayListUnmanaged(u8), body: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    const line_col: SourceLoc = switch (stmt.*) {
        .type_decl => |decl| .{ .line = decl.line, .col = decl.col },
        .var_decl => |decl| .{ .line = decl.line, .col = decl.col },
        .assign => |assignment| .{ .line = assignment.line, .col = assignment.col },
        .console_log => |log| .{ .line = log.line, .col = log.col },
        .while_stmt => |loop| .{ .line = loop.line, .col = loop.col },
        .expr_stmt => |expr_stmt| .{ .line = expr_stmt.line, .col = expr_stmt.col },
    };
    try body.print(arena, "    __lumen_line = {d}; __lumen_col = {d};\n", .{ line_col.line, line_col.col });

    switch (stmt.*) {
        .type_decl => |decl| {
            try decls.print(arena, "const {s} = struct {{\n", .{decl.name});
            for (decl.fields) |field| {
                const field_type = field.checked_type orelse return error.ParseError;
                try decls.print(arena, "    {s}: {s},\n", .{ field.name, types.zigName(field_type) });
            }
            try decls.appendSlice(arena, "};\n");
        },
        .var_decl => |decl| {
            const final_zty = decl.checked_type orelse return error.ParseError;
            try body.print(arena, "    {s} {s}: {s} = ", .{ if (decl.mutable) "var" else "const", decl.name, types.zigName(final_zty) });
            try emitExpr(decl.init, body, arena);
            try body.appendSlice(arena, ";\n");
        },
        .assign => |assignment| {
            try body.print(arena, "    {s} = ", .{assignment.name});
            try emitExpr(assignment.value, body, arena);
            try body.appendSlice(arena, ";\n");
        },
        .console_log => |log| {
            try body.appendSlice(arena, "    std.debug.print(\"{d}\\n\", .{");
            try emitExpr(log.value, body, arena);
            try body.appendSlice(arena, "});\n");
        },
        .while_stmt => |loop| {
            try body.appendSlice(arena, "    while (");
            try emitExpr(loop.cond, body, arena);
            try body.appendSlice(arena, ") {\n");
            for (loop.body) |*body_stmt| try emitStmt(body_stmt, decls, body, arena);
            try body.appendSlice(arena, "    }\n");
        },
        .expr_stmt => |expr_stmt| {
            const is_serve = expr_stmt.value.* == .call and std.mem.eql(u8, expr_stmt.value.call.name, "serve");
            try body.appendSlice(arena, if (is_serve) "    " else "    _ = ");
            try emitExpr(expr_stmt.value, body, arena);
            try body.appendSlice(arena, ";\n");
        },
    }
}

fn emitProgram(program: *const Program, decls: *std.ArrayListUnmanaged(u8), body: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    for (program.stmts) |*stmt| try emitStmt(stmt, decls, body, arena);
}

/// Compile TypeScript-syntax `source` (from `filename`) to Zig source text. On a compile-time error,
/// `diag` is filled (located in the .ts source) and `error.ParseError` returned. `filename` is also
/// embedded so a runtime panic reports the .ts location.
pub fn compileToZig(arena: std.mem.Allocator, source: []const u8, filename: []const u8, diag: *Diag) CompileError![]const u8 {
    try rejectUnsupportedDynamic(source, diag);

    var p = try Parser.init(arena, source);
    var program = p.parseProgram() catch |e| {
        diag.* = .{ .line = p.cur_line, .col = p.cur_col, .msg = p.last_err };
        return e;
    };

    try check.checkProgram(arena, &program, diag);

    var decls: std.ArrayListUnmanaged(u8) = .empty; // top-level struct type definitions
    var body: std.ArrayListUnmanaged(u8) = .empty;

    try emitProgram(&program, &decls, &body, arena);

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

    if (program.needs_httpget) {
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
    if (program.needs_serve) {
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
    if (program.uses_io) {
        try out.appendSlice(arena, "pub fn main(__init: std.process.Init) !void {\n");
        try out.appendSlice(arena, "    const __io = __init.io;\n    const __alloc = __init.arena.allocator();\n");
    } else {
        try out.appendSlice(arena, "pub fn main() void {\n");
    }
    try out.appendSlice(arena, body.items);
    try out.appendSlice(arena, "}\n");
    return out.items;
}
