//! Completion Records (ECMA-262 §6.2.4) — the spine of evaluation. M1 adds the abrupt control
//! completions (`ret`/`brk`/`cont`) needed by functions and loops; `throw` already existed.
const Value = @import("value.zig").Value;

pub const Completion = union(enum) {
    normal: Value,
    throw: Value,
    ret: Value, // §14.10 return
    brk, // §14.9 break
    cont, // §14.8 continue

    /// Any non-normal completion propagates (ReturnIfAbrupt, §5.2.3.4).
    pub fn isAbrupt(self: Completion) bool {
        return self != .normal;
    }
};
