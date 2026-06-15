//! Completion Records (ECMA-262 §6.2.4) — the spine of evaluation. M0 needs `normal` and
//! `throw`; `return`/`break`/`continue` arrive with functions and control flow.
const Value = @import("value.zig").Value;

pub const Completion = union(enum) {
    normal: Value,
    throw: Value,

    pub fn isAbrupt(self: Completion) bool {
        return self == .throw;
    }
};
