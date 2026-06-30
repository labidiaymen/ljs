//! Declaration parsing: `type`/`interface`/`enum`/`extern`/`function`/`class`,
//! plus the shared parameter-list and type-parameter/type-argument helpers
//! they all use.
//!
//! `parseClassDecl` is the largest piece (fields, constructor, methods,
//! `extends`/`implements`, generics) but follows the same shape as the rest:
//! consume keywords/punctuation, delegate to `lumen_parser_expr.zig` for any
//! expression (default values, decorators-as-values), and to
//! `lumen_parser.zig`'s `parseBlock`/`parseStmt` for bodies.
//!
//! Pulled out of `lumen_parser.zig` as the "parsing a top-level/class-member
//! declaration" concern.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const lexer = @import("lumen_lexer.zig");
const diag_mod = @import("lumen_diag.zig");
const parser_mod = @import("lumen_parser.zig");

const CompileError = diag_mod.CompileError;
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const Parser = parser_mod.Parser;

pub fn parseTypeDecl(self: *Parser, line: u32, col: u32) CompileError!Stmt {
    try self.advance();
    if (self.cur != .ident) return error.ParseError;
    const tname = self.cur.ident;
    try self.advance();
    try self.expectOp('=');
    if (self.cur == .str) {
        var literals: std.ArrayListUnmanaged([]const u8) = .empty;
        while (true) {
            if (self.cur != .str) return error.ParseError;
            try literals.append(self.arena, self.cur.str);
            try self.advance();
            if (self.isOp(';')) break;
            if (self.cur != .cmp or !std.mem.eql(u8, self.cur.cmp, "|")) return error.ParseError;
            try self.advance();
        }
        try self.expectOp(';');
        return .{ .type_decl = .{ .name = tname, .string_literals = try literals.toOwnedSlice(self.arena), .line = line, .col = col } };
    }
    if (self.cur == .num) {
        var int_literals: std.ArrayListUnmanaged(i64) = .empty;
        while (true) {
            if (self.cur != .num) return error.ParseError;
            try int_literals.append(self.arena, self.cur.num);
            try self.advance();
            if (self.isOp(';')) break;
            if (self.cur != .cmp or !std.mem.eql(u8, self.cur.cmp, "|")) return error.ParseError;
            try self.advance();
        }
        try self.expectOp(';');
        return .{ .type_decl = .{ .name = tname, .int_literals = try int_literals.toOwnedSlice(self.arena), .line = line, .col = col } };
    }
    // Object record body: `type T = { ... }`.
    if (self.isOp('{')) {
        try self.advance();
        var fields: std.ArrayListUnmanaged(ast.TypeField) = .empty;
        while (!self.isOp('}')) {
            if (self.cur != .ident) return error.ParseError;
            const fname = self.cur.ident;
            try self.advance();
            const annotation = try self.parseOptionalMember();
            try fields.append(self.arena, .{ .name = fname, .annotation = annotation });
            if (self.isOp(',')) try self.advance() else break;
        }
        try self.expectOp('}');
        if (self.isOp(';')) try self.advance();
        return .{ .type_decl = .{ .name = tname, .fields = try fields.toOwnedSlice(self.arena), .line = line, .col = col } };
    }
    // A function-type alias `type F = (a: T) => R;`.
    if (self.isOp('(')) {
        const fn_ann = try self.parseFunctionType();
        try self.expectOp(';');
        return .{ .type_decl = .{ .name = tname, .alias = fn_ann, .line = line, .col = col } };
    }
    // Otherwise an alias `type X = <member>;`, an optional alias
    // `type X = T | null;`, or a discriminated union `type U = A | B | C;`
    // over named record variants. Collect `|`-separated members first.
    var members: std.ArrayListUnmanaged([]const u8) = .empty;
    try members.append(self.arena, try self.parseTypeMember());
    while (self.isCmp("|")) {
        try self.advance();
        try members.append(self.arena, try self.parseTypeMember());
    }
    try self.expectOp(';');
    const items = try members.toOwnedSlice(self.arena);
    if (items.len == 1) {
        return .{ .type_decl = .{ .name = tname, .alias = items[0], .line = line, .col = col } };
    }
    // `T | null` / `T | undefined` -> optional alias.
    var nulls: usize = 0;
    var non_null: ?[]const u8 = null;
    for (items) |m| {
        if (std.mem.eql(u8, m, "null") or std.mem.eql(u8, m, "undefined")) {
            nulls += 1;
        } else {
            non_null = m;
        }
    }
    if (items.len == 2 and nulls == 1) {
        const opt = std.fmt.allocPrint(self.arena, "{s}?", .{non_null.?}) catch return error.OutOfMemory;
        return .{ .type_decl = .{ .name = tname, .alias = opt, .line = line, .col = col } };
    }
    return .{ .type_decl = .{ .name = tname, .union_variants = items, .line = line, .col = col } };
}

/// Parses `[?] : Type` after a field/param name, returning the annotation with
/// an optional `?` suffix when the member is marked optional.
pub fn parseOptionalMember(self: *Parser) CompileError![]const u8 {
    var opt = false;
    if (self.isOp('?')) {
        try self.advance();
        opt = true;
    }
    try self.expectOp(':');
    const annotation = try self.parseTypeAnnotation();
    if (opt and !std.mem.endsWith(u8, annotation, "?")) {
        return std.fmt.allocPrint(self.arena, "{s}?", .{annotation}) catch error.OutOfMemory;
    }
    return annotation;
}

/// An external C-ABI function declaration. Two spellings are accepted and
/// lower identically: the TypeScript-valid `declare function name(...): R;`
/// (the preferred form, since it parses under `tsc` as an ambient
/// declaration) and the legacy `extern function name(...): R;` alias.
pub fn parseExternDecl(self: *Parser, line: u32, col: u32) CompileError!Stmt {
    try self.advance(); // 'extern' or 'declare'
    if (!self.isKw("function")) return error.ParseError;
    try self.advance(); // 'function'
    if (self.cur != .ident) return error.ParseError;
    const name = self.cur.ident;
    try self.advance();
    try self.expectOp('(');
    var params: std.ArrayListUnmanaged(ast.FunctionParam) = .empty;
    while (!self.isOp(')')) {
        if (self.cur != .ident) return error.ParseError;
        const pname = self.cur.ident;
        try self.advance();
        try self.expectOp(':');
        const annotation = try self.parseTypeAnnotation();
        try params.append(self.arena, .{ .name = pname, .annotation = annotation });
        if (self.isOp(',')) try self.advance() else break;
    }
    try self.expectOp(')');
    try self.expectOp(':');
    const return_annotation = try self.parseTypeAnnotation();
    try self.expectOp(';');
    return .{ .extern_decl = .{ .name = name, .params = try params.toOwnedSlice(self.arena), .return_annotation = return_annotation, .line = line, .col = col } };
}

/// `interface Name { field: T; field2: U }` — a synonym for an object `type`.
/// Accepts `;` or `,` (or newline) between members.
pub fn parseInterfaceDecl(self: *Parser, line: u32, col: u32) CompileError!Stmt {
    try self.advance(); // 'interface'
    if (self.cur != .ident) return error.ParseError;
    const tname = self.cur.ident;
    try self.advance();
    const type_params = try self.parseTypeParams();
    try self.expectOp('{');
    var fields: std.ArrayListUnmanaged(ast.TypeField) = .empty;
    while (!self.isOp('}')) {
        if (self.cur != .ident) return error.ParseError;
        const fname = self.cur.ident;
        try self.advance();
        const annotation = try self.parseOptionalMember();
        try fields.append(self.arena, .{ .name = fname, .annotation = annotation });
        if (self.isOp(',') or self.isOp(';')) try self.advance();
    }
    try self.expectOp('}');
    if (self.isOp(';')) try self.advance();
    return .{ .type_decl = .{ .name = tname, .fields = try fields.toOwnedSlice(self.arena), .type_params = type_params, .line = line, .col = col } };
}

/// `enum Name { A, B = 2, C }` (numeric) or `enum Name { Up = "up" }` (string).
pub fn parseEnumDecl(self: *Parser, line: u32, col: u32) CompileError!Stmt {
    try self.advance(); // 'enum'
    if (self.cur != .ident) return error.ParseError;
    const ename = self.cur.ident;
    try self.advance();
    try self.expectOp('{');
    var members: std.ArrayListUnmanaged(ast.EnumMember) = .empty;
    var is_string = false;
    var auto: i64 = 0;
    while (!self.isOp('}')) {
        if (self.cur != .ident) return error.ParseError;
        const mname = self.cur.ident;
        try self.advance();
        var member: ast.EnumMember = .{ .name = mname };
        if (self.isOp('=')) {
            try self.advance();
            if (self.cur == .num) {
                member.int_value = self.cur.num;
                auto = self.cur.num + 1;
                try self.advance();
            } else if (self.cur == .str) {
                member.str_value = self.cur.str;
                is_string = true;
                try self.advance();
            } else return error.ParseError;
        } else {
            member.int_value = auto;
            auto += 1;
        }
        try members.append(self.arena, member);
        if (self.isOp(',')) try self.advance() else break;
    }
    try self.expectOp('}');
    if (self.isOp(';')) try self.advance();
    return .{ .enum_decl = .{ .name = ename, .is_string = is_string, .members = try members.toOwnedSlice(self.arena), .line = line, .col = col } };
}

pub fn parseFunctionDecl(self: *Parser, line: u32, col: u32, is_async: bool) CompileError!Stmt {
    try self.advance();
    if (self.cur != .ident) return error.ParseError;
    const name = self.cur.ident;
    try self.advance();
    const type_params = try self.parseTypeParams();
    const params = try self.parseParamList();
    try self.expectOp(':');
    const return_annotation = try self.parseTypeAnnotation();
    const body = try self.parseBlock();
    return .{ .function_decl = .{
        .name = name,
        .params = params,
        .return_annotation = return_annotation,
        .body = body,
        .type_params = type_params,
        .is_async = is_async,
        .line = line,
        .col = col,
    } };
}

pub fn parseParamList(self: *Parser) CompileError![]ast.FunctionParam {
    try self.expectOp('(');
    var params: std.ArrayListUnmanaged(ast.FunctionParam) = .empty;
    var seen_rest = false;
    while (!self.isOp(')')) {
        // A rest parameter `...name: T[]` may only appear last.
        var is_rest = false;
        if (self.isSpread()) {
            if (seen_rest) return error.ParseError;
            try self.advance();
            is_rest = true;
            seen_rest = true;
        }
        if (self.cur != .ident) return error.ParseError;
        const param_name = self.cur.ident;
        try self.advance();
        const annotation = try self.parseOptionalMember();
        // Optional default value `= expr`. Not allowed on a rest parameter.
        var default_value: ?*Expr = null;
        if (self.isOp('=')) {
            if (is_rest) return error.ParseError;
            try self.advance();
            default_value = try self.parseExpr();
        }
        try params.append(self.arena, .{ .name = param_name, .annotation = annotation, .is_rest = is_rest, .default = default_value });
        if (self.isOp(',')) try self.advance() else break;
    }
    // A rest parameter must be the final parameter.
    if (seen_rest and !params.items[params.items.len - 1].is_rest) return error.ParseError;
    try self.expectOp(')');
    return params.toOwnedSlice(self.arena);
}

/// Optional generic type-parameter list `<T, U, ...>` after a declaration
/// name. Returns an empty slice when no `<` is present.
pub fn parseTypeParams(self: *Parser) CompileError![][]const u8 {
    if (!self.isCmp("<")) return &.{};
    try self.advance(); // '<'
    var params: std.ArrayListUnmanaged([]const u8) = .empty;
    while (!self.isCmp(">")) {
        if (self.cur != .ident) return error.ParseError;
        try params.append(self.arena, self.cur.ident);
        try self.advance();
        if (self.isOp(',')) try self.advance() else break;
    }
    if (!self.isCmp(">")) return error.ParseError;
    try self.advance(); // '>'
    return params.toOwnedSlice(self.arena);
}

/// Generic type-argument list `<T, U, ...>` (concrete type annotations). The
/// caller has confirmed (via lookahead) that `cur` is the opening `<`.
pub fn parseTypeArgs(self: *Parser) CompileError![][]const u8 {
    try self.advance(); // '<'
    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    while (!self.isCmp(">")) {
        const ann = try self.parseTypeAnnotation();
        try args.append(self.arena, ann);
        if (self.isOp(',')) try self.advance() else break;
    }
    if (!self.isCmp(">")) return error.ParseError;
    try self.advance(); // '>'
    return args.toOwnedSlice(self.arena);
}

/// Lookahead: starting at a `<` (cmp), is this an explicit type-argument list
/// immediately followed by a `(` call? Scans `< ... >` (allowing nested `<`
/// and `[]`) and checks for a following `(`. Restores parser state.
pub fn looksLikeTypeArgs(self: *Parser) bool {
    const save_lex = self.lex;
    const save_cur = self.cur;
    const save_line = self.cur_line;
    const save_col = self.cur_col;
    defer {
        self.lex = save_lex;
        self.cur = save_cur;
        self.cur_line = save_line;
        self.cur_col = save_col;
    }
    self.advance() catch return false; // consume '<'
    var depth: u32 = 1;
    while (depth > 0) {
        if (self.cur == .eof) return false;
        // Only type-annotation tokens may appear inside a type-argument list.
        switch (self.cur) {
            .ident => {},
            .op => |c| if (c != ',' and c != '[' and c != ']' and c != '.') return false,
            .cmp => |s| {
                if (std.mem.eql(u8, s, "<")) {
                    depth += 1;
                } else if (std.mem.eql(u8, s, ">")) {
                    depth -= 1;
                } else return false;
            },
            .op2 => |s| if (!std.mem.eql(u8, s, ">>")) return false else {
                // `>>` closes two nested type-argument levels at once.
                if (depth >= 2) depth -= 2 else return false;
            },
            else => return false,
        }
        self.advance() catch return false;
    }
    return self.isOp('(');
}

/// `class Name { field: T; constructor(p: T) { ... } method(p: T): R { ... } }`
pub fn parseClassDecl(self: *Parser, line: u32, col: u32) CompileError!Stmt {
    try self.advance(); // 'class'
    if (self.cur != .ident) return error.ParseError;
    const name = self.cur.ident;
    try self.advance();
    const type_params = try self.parseTypeParams();
    var parent: ?[]const u8 = null;
    if (self.isKw("extends")) {
        try self.advance();
        if (self.cur != .ident) return error.ParseError;
        parent = self.cur.ident;
        try self.advance();
        // ignore any type args on the parent, e.g. `extends Base<T>`
        if (self.isCmp("<")) {
            try self.advance();
            while (!self.isCmp(">")) {
                _ = try self.parseTypeAnnotation();
                if (self.isOp(',')) try self.advance() else break;
            }
            try self.consumeTypeArgClose();
        }
    }
    var implements: std.ArrayListUnmanaged([]const u8) = .empty;
    if (self.isKw("implements")) {
        try self.advance();
        while (true) {
            if (self.cur != .ident) return error.ParseError;
            try implements.append(self.arena, self.cur.ident);
            try self.advance();
            if (self.isOp(',')) try self.advance() else break;
        }
    }
    try self.expectOp('{');
    var fields: std.ArrayListUnmanaged(ast.TypeField) = .empty;
    var methods: std.ArrayListUnmanaged(ast.FunctionDecl) = .empty;
    var has_ctor = false;
    var ctor_params: []ast.FunctionParam = &.{};
    var ctor_body: []Stmt = &.{};
    while (!self.isOp('}')) {
        // Optional member modifiers, in any order.
        var visibility: ast.Visibility = .public;
        var is_static = false;
        var is_readonly = false;
        var accessor: ast.Accessor = .none;
        while (self.cur == .ident) {
            const kw = self.cur.ident;
            if (std.mem.eql(u8, kw, "public")) {
                visibility = .public;
            } else if (std.mem.eql(u8, kw, "private")) {
                visibility = .private;
            } else if (std.mem.eql(u8, kw, "protected")) {
                visibility = .protected;
            } else if (std.mem.eql(u8, kw, "static")) {
                is_static = true;
            } else if (std.mem.eql(u8, kw, "readonly")) {
                is_readonly = true;
            } else if (std.mem.eql(u8, kw, "get") or std.mem.eql(u8, kw, "set")) {
                // `get`/`set` is an accessor prefix only when followed by an
                // identifier name (not e.g. a method literally named `get`).
                const save = self.lex;
                const save_cur = self.cur;
                try self.advance();
                if (self.cur == .ident) {
                    accessor = if (std.mem.eql(u8, kw, "get")) .getter else .setter;
                    break;
                }
                // not an accessor: restore and treat `get`/`set` as the name
                self.lex = save;
                self.cur = save_cur;
                break;
            } else break;
            try self.advance();
        }
        if (self.cur != .ident) return error.ParseError;
        const member = self.cur.ident;
        const m_line = self.cur_line;
        const m_col = self.cur_col;
        try self.advance();
        if (accessor == .none and std.mem.eql(u8, member, "constructor")) {
            ctor_params = try self.parseParamList();
            ctor_body = try self.parseBlock();
            has_ctor = true;
        } else if (self.isOp('(')) {
            // method (or accessor)
            const params = try self.parseParamList();
            var return_annotation: []const u8 = "void";
            if (self.isOp(':')) {
                try self.advance();
                return_annotation = try self.parseTypeAnnotation();
            }
            const body = try self.parseBlock();
            try methods.append(self.arena, .{
                .name = member,
                .params = params,
                .return_annotation = return_annotation,
                .body = body,
                .visibility = visibility,
                .is_static = is_static,
                .accessor = accessor,
                .line = m_line,
                .col = m_col,
            });
        } else {
            // field: name: T ;
            const annotation = try self.parseOptionalMember();
            try fields.append(self.arena, .{
                .name = member,
                .annotation = annotation,
                .visibility = visibility,
                .is_static = is_static,
                .is_readonly = is_readonly,
            });
            if (self.isOp(';') or self.isOp(',')) try self.advance();
        }
    }
    try self.expectOp('}');
    if (self.isOp(';')) try self.advance();
    return .{ .class_decl = .{
        .name = name,
        .fields = try fields.toOwnedSlice(self.arena),
        .has_ctor = has_ctor,
        .ctor_params = ctor_params,
        .ctor_body = ctor_body,
        .methods = try methods.toOwnedSlice(self.arena),
        .parent = parent,
        .implements = try implements.toOwnedSlice(self.arena),
        .type_params = type_params,
        .line = line,
        .col = col,
    } };
}
