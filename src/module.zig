//! §16.2.1.6 Source Text Module Records. A `ModuleRecord` is the in-engine representation of one
//! parsed module in a module graph: its resolved key (specifier path), parsed `Program`, the
//! per-module Module Environment Record, and link/evaluation status. The graph (the disk reads that
//! resolve a specifier to source) is built by the Test262 runner — the permitted minimal harness
//! loader — and handed to the interpreter, which links (CreateImportBinding + namespace objects) and
//! evaluates the modules in dependency order (§16.2.1.6.x InnerModuleLinking / InnerModuleEvaluation).
const std = @import("std");
const ast = @import("ast.zig");
const Environment = @import("environment.zig").Environment;
const Object = @import("object.zig").Object;

pub const Status = enum { unlinked, linking, linked, evaluating, evaluated };

pub const ModuleRecord = struct {
    /// The resolved module key (absolute/normalized specifier path). Identity in the graph cache.
    key: []const u8,
    /// The parsed module body (`is_module = true`, with Import/Export entries + RequestedModules).
    program: ast.Program,
    /// §16.2.1.6 the Module Environment Record (a strict var scope; `this` = undefined). Created at
    /// link time; the module body evaluates in it.
    env: ?*Environment = null,
    /// §10.4.6 the module namespace exotic object, lazily built for `import * as ns` / re-export.
    namespace: ?*Object = null,
    status: Status = .unlinked,
    /// Resolved dependencies, parallel to `program.requested_modules` (same order). Filled by the
    /// loader before linking so the interpreter walks the graph without re-resolving specifiers.
    deps: []const *ModuleRecord = &.{},

    /// Find the dependency module record for a given specifier string (linear scan over the small
    /// requested-modules list).
    pub fn depFor(self: *const ModuleRecord, spec: []const u8) ?*ModuleRecord {
        for (self.program.requested_modules, 0..) |m, i| {
            if (i < self.deps.len and std.mem.eql(u8, m, spec)) return self.deps[i];
        }
        return null;
    }
};
