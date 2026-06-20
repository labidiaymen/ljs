//! Environment Records (ECMA-262 §9.1) — a chain of declarative scopes. M1 subset: a parent
//! pointer + a name→binding map. Bindings carry `mutable` (for `const`) and `initialized`
//! (for the `let`/`const` temporal dead zone). Allocated in the realm arena.
const std = @import("std");
const Value = @import("value.zig").Value;

pub const Binding = struct {
    value: Value,
    mutable: bool,
    initialized: bool,
    /// §16.2.1.6 CreateImportBinding — an immutable INDIRECT binding. When non-null this binding is an
    /// import alias: reads/writes resolve through to `(alias.env, alias.name)` — the exporting module's
    /// binding cell — so the import reflects the live state of the export (TDZ before init, current
    /// value after). Resolved by name+env (not a raw `*Binding`) so a rehash of the source map can't
    /// dangle the alias. Null for every ordinary binding (the hot declarative path is unchanged).
    alias: ?ImportAlias = null,
    /// §19.2.1.3 / §9.1.1.1.2 CreateMutableBinding(N, D): the `deletable` (D) flag. A var/function
    /// binding introduced into a function VariableEnvironment by a (sloppy) direct eval is created
    /// DELETABLE (`true`), so a subsequent `delete x` removes it and a later read throws
    /// ReferenceError. Ordinary `var`/`let`/`const`/function/parameter bindings are non-deletable
    /// (`false`, the default). Only the slow `delete <identifier>` and eval-hoist paths read/set it.
    deletable: bool = false,
};

pub const ImportAlias = struct { env: *Environment, name: []const u8 };

pub const Environment = struct {
    arena: std.mem.Allocator,
    parent: ?*Environment,
    vars: std.StringHashMapUnmanaged(Binding),
    /// §9.1.1.2 Object Environment Record — for a `with` scope, the binding object (as an opaque
    /// `*Object`; stored opaque to avoid the Object↔Environment import cycle). null for ordinary
    /// declarative scopes. The interpreter consults it (only when a `with` is active) during
    /// identifier resolution, casting it back to `*Object`.
    with_object: ?*anyopaque = null,
    /// §10.2.11/§16.1.7: true for a VariableEnvironment — a Function/Script/Global/(strict-)eval
    /// scope that is the hoisting target for `var` and top-level FunctionDeclarations. Block, loop,
    /// catch, switch and `with` scopes are NOT var scopes; a `var` declared inside one hoists up to
    /// the nearest enclosing var scope (`varScope`).
    is_var_scope: bool = false,

    pub fn create(arena: std.mem.Allocator, parent: ?*Environment) std.mem.Allocator.Error!*Environment {
        const env = try arena.create(Environment);
        env.* = .{ .arena = arena, .parent = parent, .vars = .{} };
        return env;
    }

    /// The nearest enclosing VariableEnvironment (§10.2.11): walk up until `is_var_scope`, falling
    /// back to the topmost scope (the global env is always a var scope, so this normally finds one).
    pub fn varScope(self: *Environment) *Environment {
        var env: *Environment = self;
        while (!env.is_var_scope) {
            env = env.parent orelse return env;
        }
        return env;
    }

    pub fn declare(self: *Environment, name: []const u8, value: Value, mutable: bool, initialized: bool) std.mem.Allocator.Error!void {
        try self.vars.put(self.arena, name, .{ .value = value, .mutable = mutable, .initialized = initialized });
    }

    /// §16.2.1.6 CreateImportBinding — declare `local` as an immutable indirect binding aliasing
    /// `(source_env, source_name)` (the exporting module's binding). Reads/writes of `local` resolve
    /// through to the source cell, so the import is live.
    pub fn declareImport(self: *Environment, local: []const u8, source_env: *Environment, source_name: []const u8) std.mem.Allocator.Error!void {
        try self.vars.put(self.arena, local, .{ .value = .undefined, .mutable = false, .initialized = true, .alias = .{ .env = source_env, .name = source_name } });
    }

    /// Follow an import alias chain to the underlying binding cell (the exporting module's binding).
    /// A plain (non-alias) binding is returned as-is. Bounded chain walk (re-exports may alias once).
    pub fn resolveAlias(b: *Binding) ?*Binding {
        var cur = b;
        var guard: u32 = 0;
        while (cur.alias) |a| {
            guard += 1;
            if (guard > 64) return null; // cyclic / runaway alias chain
            cur = a.env.vars.getPtr(a.name) orelse return null;
        }
        return cur;
    }

    /// Resolve `name` in THIS scope only (no parent walk) — used to detect whether a binding is
    /// already declared in the current environment (e.g. a parameter named `arguments` shadowing the
    /// implicit `arguments` exotic object, §10.4.4).
    pub fn lookupLocal(self: *Environment, name: []const u8) ?*Binding {
        return self.vars.getPtr(name);
    }

    /// Resolve `name` by walking up the scope chain; returns a mutable pointer to the binding.
    /// INVARIANT: do not hold the returned `*Binding` across a `declare`/`put` — the unmanaged
    /// map may rehash and invalidate the pointer; re-`lookup` after any mutation.
    pub fn lookup(self: *Environment, name: []const u8) ?*Binding {
        var env: ?*Environment = self;
        while (env) |e| {
            if (e.vars.getPtr(name)) |b| return b;
            env = e.parent;
        }
        return null;
    }
};
