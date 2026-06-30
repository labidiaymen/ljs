//! The parser -- stage 2 of the compiler.
//!
//! Consumes the lexer's token stream and produces the AST (`lumen_ast.zig`). It is
//! a hand-written recursive-descent parser: `Parser.init(arena, source)` wraps a
//! `Lexer`, and `Parser.parseProgram()` returns a `Program`. The parser only knows
//! about tokens and AST nodes -- it does no type checking and no code generation
//! (those are `lumen_check.zig` and the codegen in `lumen_compiler.zig`).
//!
//! Errors are reported as `error.ParseError`; the caller turns the lexer's current
//! position into a user-facing diagnostic. Type annotations are kept as raw source
//! strings on the AST and resolved later by the checker.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const lexer = @import("lumen_lexer.zig");
const diag_mod = @import("lumen_diag.zig");
const parser_expr = @import("lumen_parser_expr.zig");
const parser_decl = @import("lumen_parser_decl.zig");

const CompileError = diag_mod.CompileError;
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const Program = ast.Program;
const FieldInit = ast.FieldInit;
const Lexer = lexer.Lexer;
const Tok = lexer.Tok;

/// Names the parser treats as built-in calls rather than user identifiers.
fn isBuiltin(name: []const u8) bool {
    return std.mem.eql(u8, name, "httpGet") or std.mem.eql(u8, name, "serve");
}

pub const Parser = struct {
    // Type-annotation and expression parsing lives in lumen_parser_expr.zig.
    pub const parseTypeMember = parser_expr.parseTypeMember;
    pub const consumeTypeArgClose = parser_expr.consumeTypeArgClose;
    pub const parseFunctionType = parser_expr.parseFunctionType;
    pub const parseTupleType = parser_expr.parseTupleType;
    pub const parseTypeAnnotation = parser_expr.parseTypeAnnotation;
    pub const parseExpr = parser_expr.parseExpr;
    pub const parseSpreadOrExpr = parser_expr.parseSpreadOrExpr;
    pub const parseTemplateParts = parser_expr.parseTemplateParts;
    pub const isCmp = parser_expr.isCmp;
    pub const isComparison = parser_expr.isComparison;
    pub const parseTernary = parser_expr.parseTernary;
    pub const parseCoalesce = parser_expr.parseCoalesce;
    pub const parseOr = parser_expr.parseOr;
    pub const parseAnd = parser_expr.parseAnd;
    pub const parseBitOr = parser_expr.parseBitOr;
    pub const parseBitXor = parser_expr.parseBitXor;
    pub const parseBitAnd = parser_expr.parseBitAnd;
    pub const parseCmp = parser_expr.parseCmp;
    pub const parseShift = parser_expr.parseShift;
    pub const parseAdd = parser_expr.parseAdd;
    pub const parseMul = parser_expr.parseMul;
    pub const parseExp = parser_expr.parseExp;
    pub const parseUnary = parser_expr.parseUnary;
    pub const parsePostfix = parser_expr.parsePostfix;
    pub const parsePostfixFrom = parser_expr.parsePostfixFrom;
    pub const looksLikeArrow = parser_expr.looksLikeArrow;
    pub const parseArrow = parser_expr.parseArrow;
    pub const parseDeferHelperBodyStmt = parser_expr.parseDeferHelperBodyStmt;
    pub const parsePrimary = parser_expr.parsePrimary;
    pub const parseAssignmentTail = parser_expr.parseAssignmentTail;
    pub const parsePrefixUpdate = parser_expr.parsePrefixUpdate;

    // Declaration parsing lives in lumen_parser_decl.zig.
    pub const parseTypeDecl = parser_decl.parseTypeDecl;
    pub const parseOptionalMember = parser_decl.parseOptionalMember;
    pub const parseExternDecl = parser_decl.parseExternDecl;
    pub const parseInterfaceDecl = parser_decl.parseInterfaceDecl;
    pub const parseEnumDecl = parser_decl.parseEnumDecl;
    pub const parseFunctionDecl = parser_decl.parseFunctionDecl;
    pub const parseParamList = parser_decl.parseParamList;
    pub const parseTypeParams = parser_decl.parseTypeParams;
    pub const parseTypeArgs = parser_decl.parseTypeArgs;
    pub const looksLikeTypeArgs = parser_decl.looksLikeTypeArgs;
    pub const parseClassDecl = parser_decl.parseClassDecl;

    arena: std.mem.Allocator,
    lex: Lexer,
    cur: Tok,
    cur_line: u32 = 1, // source line of `cur`
    cur_col: u32 = 1, // source column of `cur`
    last_err: []const u8 = "syntax error", // message for the next diagnostic

    pub fn init(arena: std.mem.Allocator, src: []const u8) CompileError!Parser {
        var lex = Lexer{ .src = src };
        const first = try lex.next();
        return .{ .arena = arena, .lex = lex, .cur = first, .cur_line = lex.tok_line, .cur_col = lex.tok_col };
    }
    pub fn advance(self: *Parser) CompileError!void {
        self.cur = try self.lex.next();
        self.cur_line = self.lex.tok_line;
        self.cur_col = self.lex.tok_col;
    }
    pub fn isOp(self: *Parser, ch: u8) bool {
        return self.cur == .op and self.cur.op == ch;
    }
    pub fn isOp2(self: *Parser, op: []const u8) bool {
        return self.cur == .op2 and std.mem.eql(u8, self.cur.op2, op);
    }
    pub fn isSpread(self: *Parser) bool {
        return self.cur == .op3 and std.mem.eql(u8, self.cur.op3, "...");
    }
    pub fn oneExpr(self: *Parser, value: i64) CompileError!*Expr {
        return self.node(.{ .num = value });
    }
    pub fn expectOp(self: *Parser, ch: u8) CompileError!void {
        if (!self.isOp(ch)) return error.ParseError;
        try self.advance();
    }
    pub fn isKw(self: *Parser, kw: []const u8) bool {
        return self.cur == .ident and std.mem.eql(u8, self.cur.ident, kw);
    }
    /// True when the token after `cur` is `(`. Restores parser state afterwards.
    fn peekIsOpenParen(self: *Parser) bool {
        const save_lex = self.lex;
        const save_cur = self.cur;
        const save_line = self.cur_line;
        const save_col = self.cur_col;
        self.advance() catch {};
        const result = self.isOp('(');
        self.lex = save_lex;
        self.cur = save_cur;
        self.cur_line = save_line;
        self.cur_col = save_col;
        return result;
    }
    pub fn node(self: *Parser, e: Expr) CompileError!*Expr {
        const p = try self.arena.create(Expr);
        p.* = e;
        return p;
    }
    pub fn isStdNamespace(name: []const u8) bool {
        return std.mem.eql(u8, name, "Math") or std.mem.eql(u8, name, "String") or std.mem.eql(u8, name, "Array") or std.mem.eql(u8, name, "fs") or std.mem.eql(u8, name, "Promise");
    }
    pub fn parseBlock(self: *Parser) CompileError![]Stmt {
        try self.expectOp('{');
        var body: std.ArrayListUnmanaged(Stmt) = .empty;
        while (!self.isOp('}')) try body.append(self.arena, try self.parseStmt());
        try self.expectOp('}');
        return body.toOwnedSlice(self.arena);
    }

    fn parseSwitchBody(self: *Parser) CompileError![]Stmt {
        var body: std.ArrayListUnmanaged(Stmt) = .empty;
        while (!self.isOp('}') and !self.isKw("case") and !self.isKw("default")) {
            try body.append(self.arena, try self.parseStmt());
        }
        return body.toOwnedSlice(self.arena);
    }

    fn parseSwitch(self: *Parser, line: u32, col: u32) CompileError!Stmt {
        try self.advance();
        try self.expectOp('(');
        const value = try self.parseExpr();
        try self.expectOp(')');
        try self.expectOp('{');
        var cases: std.ArrayListUnmanaged(ast.SwitchCase) = .empty;
        var default_body: ?[]Stmt = null;
        while (!self.isOp('}')) {
            if (self.isKw("case")) {
                const case_line = self.cur_line;
                const case_col = self.cur_col;
                try self.advance();
                const case_value = try self.parseExpr();
                try self.expectOp(':');
                try cases.append(self.arena, .{ .value = case_value, .body = try self.parseSwitchBody(), .line = case_line, .col = case_col });
            } else if (self.isKw("default")) {
                if (default_body != null) return error.ParseError;
                try self.advance();
                try self.expectOp(':');
                default_body = try self.parseSwitchBody();
            } else {
                return error.ParseError;
            }
        }
        try self.expectOp('}');
        return .{ .switch_stmt = .{ .value = value, .cases = try cases.toOwnedSlice(self.arena), .default_body = default_body, .line = line, .col = col } };
    }

    fn parseStmt(self: *Parser) CompileError!Stmt {
        const eq = std.mem.eql;
        const line = self.cur_line;
        const col = self.cur_col;
        if (self.cur == .op2 and (std.mem.eql(u8, self.cur.op2, "++") or std.mem.eql(u8, self.cur.op2, "--"))) {
            const op = self.cur.op2;
            return .{ .assign = try self.parsePrefixUpdate(op, line, col, true) };
        }
        if (self.cur != .ident) return error.ParseError;
        const kw = self.cur.ident;

        // `await <expr>;` as a statement (the resolved value is discarded).
        if (eq(u8, kw, "await")) {
            const value = try self.parseExpr();
            try self.expectOp(';');
            return .{ .expr_stmt = .{ .value = value, .line = line, .col = col } };
        }

        if (eq(u8, kw, "type")) return self.parseTypeDecl(line, col);
        if (eq(u8, kw, "interface")) return self.parseInterfaceDecl(line, col);
        if (eq(u8, kw, "enum")) return self.parseEnumDecl(line, col);
        if (eq(u8, kw, "extern")) return self.parseExternDecl(line, col);
        // `declare function NAME(...): R;` — the TypeScript-valid spelling for an
        // FFI declaration; identical lowering to `extern function`.
        if (eq(u8, kw, "declare")) return self.parseExternDecl(line, col);
        if (eq(u8, kw, "function")) return self.parseFunctionDecl(line, col, false);
        // `async function ...` — an asynchronous function returning a Promise<T>.
        if (eq(u8, kw, "async")) {
            try self.advance(); // 'async'
            if (!self.isKw("function")) return error.ParseError;
            return self.parseFunctionDecl(line, col, true);
        }
        if (eq(u8, kw, "switch")) return self.parseSwitch(line, col);
        if (eq(u8, kw, "class")) return self.parseClassDecl(line, col);

        // `this.field = value;` (member assignment) or `this.method(args);`
        if (eq(u8, kw, "this")) {
            try self.advance(); // 'this'
            try self.expectOp('.');
            if (self.cur != .ident) return error.ParseError;
            const member = self.cur.ident;
            try self.advance();
            if (self.isOp('(')) {
                try self.expectOp('(');
                var args: std.ArrayListUnmanaged(*Expr) = .empty;
                while (!self.isOp(')')) {
                    try args.append(self.arena, try self.parseExpr());
                    if (self.isOp(',')) try self.advance() else break;
                }
                try self.expectOp(')');
                try self.expectOp(';');
                const this_e = try self.node(.this_expr);
                const mc = try self.node(.{ .method_call = .{ .obj = this_e, .name = member, .args = try args.toOwnedSlice(self.arena) } });
                return .{ .expr_stmt = .{ .value = mc, .line = line, .col = col } };
            }
            var op: []const u8 = "=";
            if (self.isOp('=')) {
                try self.advance();
            } else if (self.cur == .op2 and (eq(u8, self.cur.op2, "+=") or eq(u8, self.cur.op2, "-=") or eq(u8, self.cur.op2, "*=") or eq(u8, self.cur.op2, "/=") or eq(u8, self.cur.op2, "%="))) {
                op = self.cur.op2;
                try self.advance();
            } else return error.ParseError;
            const value = try self.parseExpr();
            try self.expectOp(';');
            return .{ .member_assign = .{ .field = member, .op = op, .value = value, .line = line, .col = col } };
        }

        // `super(args);` (parent constructor) or `super.method(args);`.
        if (eq(u8, kw, "super")) {
            try self.advance(); // 'super'
            if (self.isOp('(')) {
                try self.expectOp('(');
                var args: std.ArrayListUnmanaged(*Expr) = .empty;
                while (!self.isOp(')')) {
                    try args.append(self.arena, try self.parseExpr());
                    if (self.isOp(',')) try self.advance() else break;
                }
                try self.expectOp(')');
                try self.expectOp(';');
                return .{ .super_ctor = .{ .args = try args.toOwnedSlice(self.arena), .line = line, .col = col } };
            }
            try self.expectOp('.');
            if (self.cur != .ident) return error.ParseError;
            const member = self.cur.ident;
            try self.advance();
            try self.expectOp('(');
            var args: std.ArrayListUnmanaged(*Expr) = .empty;
            while (!self.isOp(')')) {
                try args.append(self.arena, try self.parseExpr());
                if (self.isOp(',')) try self.advance() else break;
            }
            try self.expectOp(')');
            try self.expectOp(';');
            const sc = try self.node(.{ .super_call = .{ .name = member, .args = try args.toOwnedSlice(self.arena) } });
            return .{ .expr_stmt = .{ .value = sc, .line = line, .col = col } };
        }

        if (eq(u8, kw, "let") or eq(u8, kw, "const") or eq(u8, kw, "var")) {
            const mutable = eq(u8, kw, "let") or eq(u8, kw, "var");
            try self.advance();
            // Destructuring: `let [a, b] = e;` or `let { x, y } = e;`
            if (self.isOp('[') or self.isOp('{')) {
                const is_object = self.isOp('{');
                try self.advance();
                const close: u8 = if (is_object) '}' else ']';
                var bindings: std.ArrayListUnmanaged(ast.DestructBinding) = .empty;
                while (!self.isOp(close)) {
                    if (self.cur != .ident) return error.ParseError;
                    try bindings.append(self.arena, .{ .name = self.cur.ident });
                    try self.advance();
                    if (self.isOp(',')) try self.advance() else break;
                }
                try self.expectOp(close);
                try self.expectOp('=');
                const source = try self.parseExpr();
                try self.expectOp(';');
                return .{ .destructure_decl = .{ .mutable = mutable, .is_object = is_object, .bindings = try bindings.toOwnedSlice(self.arena), .source = source, .line = line, .col = col } };
            }
            if (self.cur != .ident) return error.ParseError;
            const name = self.cur.ident;
            try self.advance();
            var annotation: ?[]const u8 = null;
            if (self.isOp(':')) {
                try self.advance();
                annotation = try self.parseTypeAnnotation();
            }
            try self.expectOp('=');
            const initial_value = try self.parseExpr();
            try self.expectOp(';');
            return .{ .var_decl = .{ .mutable = mutable, .name = name, .annotation = annotation, .init = initial_value, .line = line, .col = col } };
        }

        // `using NAME = EXPR;` — TypeScript 5.2 scope-exit disposal. Reuses the
        // same scope-exit (LIFO) lowering as `defer`. Disposes the bound value at
        // block/function exit; see ast.UsingDecl.
        if (eq(u8, kw, "using")) {
            try self.advance();
            if (self.cur != .ident) return error.ParseError;
            const name = self.cur.ident;
            try self.advance();
            var annotation: ?[]const u8 = null;
            if (self.isOp(':')) {
                try self.advance();
                annotation = try self.parseTypeAnnotation();
            }
            try self.expectOp('=');
            // `using x = defer(() => BODY);` — the built-in scope-exit helper. The
            // body is parsed as statements (so `console.log(...)` works) and run
            // at scope exit, exactly like the `defer` statement. We still build an
            // `init` call node for the checker to validate the helper shape.
            if (self.isKw("defer") and self.peekIsOpenParen()) {
                try self.advance(); // 'defer'
                try self.expectOp('(');
                if (!self.isOp('(')) return error.ParseError; // require `() =>`
                try self.advance();
                try self.expectOp(')');
                if (!self.isOp2("=>")) return error.ParseError;
                try self.advance();
                var defer_body: []Stmt = undefined;
                if (self.isOp('{')) {
                    // Block-bodied arrow: `defer(() => { ...; ... })`.
                    defer_body = try self.parseBlock();
                } else {
                    // Single-expression arrow body, followed by the `)` that closes
                    // the `defer(` call (so no trailing `;` to consume here).
                    const single = try self.arena.alloc(Stmt, 1);
                    single[0] = try self.parseDeferHelperBodyStmt();
                    defer_body = single;
                }
                try self.expectOp(')');
                try self.expectOp(';');
                const init_call = try self.node(.{ .call = .{ .name = "defer", .args = &.{} } });
                return .{ .using_decl = .{ .name = name, .annotation = annotation, .init = init_call, .defer_body = defer_body, .line = line, .col = col } };
            }
            const initial_value = try self.parseExpr();
            try self.expectOp(';');
            return .{ .using_decl = .{ .name = name, .annotation = annotation, .init = initial_value, .line = line, .col = col } };
        }

        if (eq(u8, kw, "console")) {
            try self.advance();
            try self.expectOp('.');
            if (self.cur != .ident) return error.ParseError;
            const method = self.cur.ident;
            if (!eq(u8, method, "log") and !eq(u8, method, "error")) {
                self.last_err = "E_UNSUPPORTED_STD";
                return error.ParseError;
            }
            try self.advance();
            try self.expectOp('(');
            const value = try self.parseExpr();
            try self.expectOp(')');
            try self.expectOp(';');
            return .{ .console_log = .{ .method = method, .value = value, .line = line, .col = col } };
        }

        if (eq(u8, kw, "while")) {
            try self.advance();
            try self.expectOp('(');
            const cond = try self.parseExpr();
            try self.expectOp(')');
            const body = try self.parseBlock();
            return .{ .while_stmt = .{ .cond = cond, .body = body, .line = line, .col = col } };
        }

        if (eq(u8, kw, "do")) {
            try self.advance();
            const body = try self.parseBlock();
            if (!self.isKw("while")) return error.ParseError;
            try self.advance();
            try self.expectOp('(');
            const cond = try self.parseExpr();
            try self.expectOp(')');
            try self.expectOp(';');
            return .{ .do_while_stmt = .{ .body = body, .cond = cond, .line = line, .col = col } };
        }

        if (eq(u8, kw, "for")) {
            try self.advance();
            try self.expectOp('(');
            if (self.cur != .ident) return error.ParseError;
            const init_kw = self.cur.ident;
            const is_const = eq(u8, init_kw, "const");
            if (!eq(u8, init_kw, "let") and !eq(u8, init_kw, "var") and !is_const) return error.ParseError;
            try self.advance();
            if (self.cur != .ident) return error.ParseError;
            const init_name = self.cur.ident;
            const init_line = self.cur_line;
            const init_col = self.cur_col;
            try self.advance();
            // for...of: `for (const|let name of iterable) { ... }`
            if (self.isKw("of")) {
                try self.advance();
                const iterable = try self.parseExpr();
                try self.expectOp(')');
                const body = try self.parseBlock();
                return .{ .for_of_stmt = .{ .mutable = !is_const, .binding = init_name, .iterable = iterable, .body = body, .line = line, .col = col } };
            }
            // C-style for loops require a reassignable binding for the update step.
            if (is_const) return error.ParseError;
            var annotation: ?[]const u8 = null;
            if (self.isOp(':')) {
                try self.advance();
                annotation = try self.parseTypeAnnotation();
            }
            try self.expectOp('=');
            const init_value = try self.parseExpr();
            try self.expectOp(';');
            const cond = try self.parseExpr();
            try self.expectOp(';');
            const update_line = self.cur_line;
            const update_col = self.cur_col;
            const update = if (self.cur == .op2 and (std.mem.eql(u8, self.cur.op2, "++") or std.mem.eql(u8, self.cur.op2, "--"))) blk: {
                const op = self.cur.op2;
                break :blk try self.parsePrefixUpdate(op, update_line, update_col, false);
            } else blk: {
                if (self.cur != .ident) return error.ParseError;
                const update_name = self.cur.ident;
                try self.advance();
                break :blk try self.parseAssignmentTail(update_name, update_line, update_col, false);
            };
            try self.expectOp(')');
            const body = try self.parseBlock();
            return .{ .for_stmt = .{
                .init = .{ .mutable = true, .name = init_name, .annotation = annotation, .init = init_value, .line = init_line, .col = init_col },
                .cond = cond,
                .update = update,
                .body = body,
                .line = line,
                .col = col,
            } };
        }

        if (eq(u8, kw, "if")) {
            try self.advance();
            try self.expectOp('(');
            const cond = try self.parseExpr();
            try self.expectOp(')');
            const then_body = try self.parseBlock();
            var else_body: ?[]Stmt = null;
            if (self.isKw("else")) {
                try self.advance();
                if (self.isKw("if")) {
                    const nested_if = try self.parseStmt();
                    const nested_body = try self.arena.alloc(Stmt, 1);
                    nested_body[0] = nested_if;
                    else_body = nested_body;
                } else {
                    else_body = try self.parseBlock();
                }
            }
            return .{ .if_stmt = .{ .cond = cond, .then_body = then_body, .else_body = else_body, .line = line, .col = col } };
        }

        if (eq(u8, kw, "return")) {
            try self.advance();
            const value = if (self.isOp(';')) null else try self.parseExpr();
            try self.expectOp(';');
            return .{ .return_stmt = .{ .value = value, .line = line, .col = col } };
        }

        if (eq(u8, kw, "break")) {
            try self.advance();
            try self.expectOp(';');
            return .{ .break_stmt = .{ .line = line, .col = col } };
        }

        if (eq(u8, kw, "continue")) {
            try self.advance();
            try self.expectOp(';');
            return .{ .continue_stmt = .{ .line = line, .col = col } };
        }

        if (eq(u8, kw, "throw")) {
            try self.advance();
            const value = try self.parseExpr();
            try self.expectOp(';');
            return .{ .throw_stmt = .{ .value = value, .line = line, .col = col } };
        }

        if (eq(u8, kw, "defer")) {
            try self.advance();
            if (self.isOp('{')) {
                const body = try self.parseBlock();
                return .{ .defer_stmt = .{ .body = body, .line = line, .col = col } };
            }
            const single = try self.arena.alloc(Stmt, 1);
            single[0] = try self.parseStmt();
            return .{ .defer_stmt = .{ .body = single, .line = line, .col = col } };
        }

        if (eq(u8, kw, "try")) {
            try self.advance();
            const try_body = try self.parseBlock();
            if (!self.isKw("catch")) return error.ParseError;
            try self.advance();
            try self.expectOp('(');
            if (self.cur != .ident) return error.ParseError;
            const catch_name = self.cur.ident;
            try self.advance();
            try self.expectOp(')');
            const catch_body = try self.parseBlock();
            var finally_body: ?[]Stmt = null;
            if (self.isKw("finally")) {
                try self.advance();
                finally_body = try self.parseBlock();
            }
            return .{ .try_stmt = .{ .try_body = try_body, .catch_name = catch_name, .catch_body = catch_body, .finally_body = finally_body, .line = line, .col = col } };
        }

        // Test declarations. Two surfaces lower to the same `test_decl`:
        //   * `test "name" { ... }`              — the original block form.
        //   * `test("name", () => { ... });`     — the conventional function form
        //                                          (Jest/Vitest/node:test style),
        //                                          which is valid TypeScript.
        // Both are recognised only by lookahead, so `test` stays usable as an
        // ordinary identifier everywhere else.
        if (eq(u8, kw, "test")) {
            const save_lex = self.lex;
            const save_cur = self.cur;
            const save_line = self.cur_line;
            const save_col = self.cur_col;
            self.advance() catch {};
            const after_test = self.cur;
            self.lex = save_lex;
            self.cur = save_cur;
            self.cur_line = save_line;
            self.cur_col = save_col;
            if (after_test == .str) {
                // `test "name" { ... }`
                try self.advance(); // 'test'
                const name = self.cur.str;
                try self.advance(); // name string
                const tbody = try self.parseBlock();
                return .{ .test_decl = .{ .name = name, .body = tbody, .line = line, .col = col } };
            }
            if (after_test == .op and after_test.op == '(') {
                // `test("name", () => { ... });`
                try self.advance(); // 'test'
                try self.expectOp('(');
                if (self.cur != .str) return error.ParseError;
                const name = self.cur.str;
                try self.advance(); // name string
                try self.expectOp(',');
                // Callback `() => { ... }`: no params, block body.
                try self.expectOp('(');
                try self.expectOp(')');
                if (!self.isOp2("=>")) return error.ParseError;
                try self.advance(); // '=>'
                const tbody = try self.parseBlock();
                try self.expectOp(')');
                try self.expectOp(';');
                return .{ .test_decl = .{ .name = name, .body = tbody, .line = line, .col = col } };
            }
        }

        // `expect(...)` assertions. The boolean form `expect(cond);` and the
        // matcher form `expect(actual).toBe(expected);` (and `.toEqual`) both
        // lower to a single `expect` call node; the matcher carries the expected
        // value as a second argument and a marker name. Recognised only when an
        // open paren follows, so `expect` stays usable as an identifier.
        if (eq(u8, kw, "expect") and self.peekIsOpenParen()) {
            try self.advance(); // 'expect'
            try self.expectOp('(');
            const actual = try self.parseExpr();
            try self.expectOp(')');
            if (self.isOp('.')) {
                try self.advance(); // '.'
                if (self.cur != .ident) return error.ParseError;
                const matcher = self.cur.ident;
                const matcher_name: ?[]const u8 = if (eq(u8, matcher, "toBe"))
                    "__expectToBe"
                else if (eq(u8, matcher, "toEqual"))
                    "__expectToEqual"
                else
                    null;
                if (matcher_name == null) {
                    self.last_err = "E_UNKNOWN_MATCHER";
                    return error.ParseError;
                }
                try self.advance(); // matcher name
                try self.expectOp('(');
                const expected = try self.parseExpr();
                try self.expectOp(')');
                try self.expectOp(';');
                const args = try self.arena.alloc(*Expr, 2);
                args[0] = actual;
                args[1] = expected;
                const value = try self.node(.{ .call = .{ .name = matcher_name.?, .args = args } });
                return .{ .expr_stmt = .{ .value = value, .line = line, .col = col } };
            }
            // Boolean form: `expect(cond);`.
            try self.expectOp(';');
            const args = try self.arena.alloc(*Expr, 1);
            args[0] = actual;
            const value = try self.node(.{ .call = .{ .name = "expect", .args = args } });
            return .{ .expr_stmt = .{ .value = value, .line = line, .col = col } };
        }

        if (isBuiltin(kw)) {
            const value = try self.parseExpr();
            try self.expectOp(';');
            return .{ .expr_stmt = .{ .value = value, .line = line, .col = col } };
        }

        const name = kw;
        try self.advance();
        if (self.isOp('(')) {
            try self.expectOp('(');
            var args: std.ArrayListUnmanaged(*Expr) = .empty;
            while (!self.isOp(')')) {
                try args.append(self.arena, try self.parseSpreadOrExpr());
                if (self.isOp(',')) try self.advance() else break;
            }
            try self.expectOp(')');
            // A method call on a returned object, e.g. `make().go();`, continues
            // as a postfix expression statement.
            if (self.isOp('.') or self.isOp('[') or self.isOp2("?.")) {
                const call_e = try self.node(.{ .call = .{ .name = name, .args = try args.toOwnedSlice(self.arena) } });
                const e = try self.parsePostfixFrom(call_e);
                try self.expectOp(';');
                return .{ .expr_stmt = .{ .value = e, .line = line, .col = col } };
            }
            try self.expectOp(';');
            const value = try self.node(.{ .call = .{ .name = name, .args = try args.toOwnedSlice(self.arena) } });
            return .{ .expr_stmt = .{ .value = value, .line = line, .col = col } };
        }
        // Single-level member assignment: `obj.field = value;`,
        // `Class.staticField += value;`, or a setter property write.
        if (self.isOp('.')) {
            const save_lex = self.lex;
            const save_cur = self.cur;
            try self.advance(); // '.'
            if (self.cur == .ident) {
                const field = self.cur.ident;
                try self.advance();
                var op: []const u8 = "=";
                var is_assign = false;
                if (self.isOp('=')) {
                    is_assign = true;
                    try self.advance();
                } else if (self.cur == .op2 and (eq(u8, self.cur.op2, "+=") or eq(u8, self.cur.op2, "-=") or eq(u8, self.cur.op2, "*=") or eq(u8, self.cur.op2, "/=") or eq(u8, self.cur.op2, "%="))) {
                    is_assign = true;
                    op = self.cur.op2;
                    try self.advance();
                }
                if (is_assign) {
                    const obj = try self.node(.{ .var_ref = .{ .name = name } });
                    const value = try self.parseExpr();
                    try self.expectOp(';');
                    return .{ .member_assign = .{ .field = field, .op = op, .value = value, .obj = obj, .line = line, .col = col } };
                }
            }
            // Not a simple assignment: restore and fall through to postfix.
            self.lex = save_lex;
            self.cur = save_cur;
        }
        // Member-expression statement: `obj.method(args);`, `obj.field...`.
        if (self.isOp('.') or self.isOp('[') or self.isOp2("?.")) {
            const base = try self.node(.{ .var_ref = .{ .name = name } });
            const e = try self.parsePostfixFrom(base);
            try self.expectOp(';');
            return .{ .expr_stmt = .{ .value = e, .line = line, .col = col } };
        }
        return .{ .assign = try self.parseAssignmentTail(name, line, col, true) };
    }

    pub fn parseProgram(self: *Parser) CompileError!Program {
        var stmts: std.ArrayListUnmanaged(Stmt) = .empty;
        while (self.cur != .eof) try stmts.append(self.arena, try self.parseStmt());
        return .{ .stmts = try stmts.toOwnedSlice(self.arena) };
    }
};
