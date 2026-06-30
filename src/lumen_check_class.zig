//! Class member resolution: field/method/accessor lookup across the
//! inheritance chain, and visibility (`private`/`protected`) enforcement.
//!
//! `resolveField`/`resolveMethod`/`resolveStaticField`/`resolveStaticMethod`/
//! `resolveAccessor` walk a class's `extends` chain (via `Checker.classes`)
//! looking for the first matching member, returning both the member and its
//! *owner* class name (needed by the codegen to call the right
//! `ClassName.method` / cast to the declaring struct). `checkVisibility`/
//! `visibilityOk` then gate access based on where the access happens relative
//! to that owner.
//!
//! Pulled out of `lumen_check.zig` as a self-contained "class member lookup"
//! concern, separate from statement/expression checking that *uses* these
//! lookups.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const types = @import("lumen_types.zig");
const diag_mod = @import("lumen_diag.zig");
const check_mod = @import("lumen_check.zig");

const Checker = check_mod.Checker;
const CompileError = diag_mod.CompileError;
const ResolvedField = Checker.ResolvedField;
const ResolvedMethod = Checker.ResolvedMethod;

pub fn classField(self: *Checker, class_name: []const u8, field: []const u8) ?types.Type {
    if (self.resolveField(class_name, field)) |r| return r.field.checked_type;
    return null;
}

/// Find an instance field by name, walking the inheritance chain. Static
/// fields are excluded (looked up separately via `resolveStaticField`).
pub fn resolveField(self: *Checker, class_name: []const u8, field: []const u8) ?ResolvedField {
    var cur: ?[]const u8 = class_name;
    while (cur) |name| {
        const info = self.classes.get(name) orelse return null;
        for (info.fields) |f| {
            if (!f.is_static and std.mem.eql(u8, f.name, field)) return .{ .field = f, .owner = name };
        }
        cur = info.parent;
    }
    return null;
}

pub fn resolveStaticField(self: *Checker, class_name: []const u8, field: []const u8) ?ResolvedField {
    var cur: ?[]const u8 = class_name;
    while (cur) |name| {
        const info = self.classes.get(name) orelse return null;
        for (info.fields) |f| {
            if (f.is_static and std.mem.eql(u8, f.name, field)) return .{ .field = f, .owner = name };
        }
        cur = info.parent;
    }
    return null;
}

/// Find an instance method/accessor by name, walking the chain. The most
/// derived definition wins (override).
pub fn resolveMethod(self: *Checker, class_name: []const u8, name: []const u8) ?ResolvedMethod {
    var cur: ?[]const u8 = class_name;
    while (cur) |cname| {
        const info = self.classes.get(cname) orelse return null;
        for (info.methods) |m| {
            if (!m.is_static and m.accessor == .none and std.mem.eql(u8, m.name, name)) return .{ .method = m, .owner = cname };
        }
        cur = info.parent;
    }
    return null;
}

pub fn resolveStaticMethod(self: *Checker, class_name: []const u8, name: []const u8) ?ResolvedMethod {
    var cur: ?[]const u8 = class_name;
    while (cur) |cname| {
        const info = self.classes.get(cname) orelse return null;
        for (info.methods) |m| {
            if (m.is_static and m.accessor == .none and std.mem.eql(u8, m.name, name)) return .{ .method = m, .owner = cname };
        }
        cur = info.parent;
    }
    return null;
}

pub fn resolveAccessor(self: *Checker, class_name: []const u8, name: []const u8, kind: ast.Accessor) ?ResolvedMethod {
    var cur: ?[]const u8 = class_name;
    while (cur) |cname| {
        const info = self.classes.get(cname) orelse return null;
        for (info.methods) |m| {
            if (m.accessor == kind and std.mem.eql(u8, m.name, name)) return .{ .method = m, .owner = cname };
        }
        cur = info.parent;
    }
    return null;
}

/// True if `sub` is `ancestor` or a (transitive) subclass of it.
pub fn isSubclassOf(self: *Checker, sub: []const u8, ancestor: []const u8) bool {
    var cur: ?[]const u8 = sub;
    while (cur) |name| {
        if (std.mem.eql(u8, name, ancestor)) return true;
        const info = self.classes.get(name) orelse return false;
        cur = info.parent;
    }
    return false;
}

/// Enforce member visibility for an access whose member is declared in
/// `owner` with `vis`, from the currently-checked class context.
pub fn checkVisibility(self: *Checker, vis: ast.Visibility, owner: []const u8, line: u32, col: u32) CompileError!void {
    switch (vis) {
        .public => {},
        .private => {
            const here = self.current_class orelse return self.fail(line, col, "E_PRIVATE_ACCESS");
            if (!std.mem.eql(u8, here, owner)) return self.fail(line, col, "E_PRIVATE_ACCESS");
        },
        .protected => {
            const here = self.current_class orelse return self.fail(line, col, "E_PROTECTED_ACCESS");
            if (!self.isSubclassOf(here, owner)) return self.fail(line, col, "E_PROTECTED_ACCESS");
        },
    }
}

/// Non-erroring visibility check for use inside `exprType` (which returns
/// `?Type`). Records the diagnostic and returns false on violation.
pub fn visibilityOk(self: *Checker, vis: ast.Visibility, owner: []const u8, line: u32, col: u32) bool {
    self.checkVisibility(vis, owner, line, col) catch return false;
    return true;
}
