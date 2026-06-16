//! Completion Records (ECMA-262 §6.2.4) — the spine of evaluation. M1 adds the abrupt control
//! completions (`ret`/`brk`/`cont`) needed by functions and loops; `throw` already existed.
const Value = @import("value.zig").Value;

pub const Completion = union(enum) {
    normal: Value,
    throw: Value,
    ret: Value, // §14.10 return
    /// §14.9 break — `null` for an unlabeled break (caught by the innermost iteration/switch), or the
    /// target label name (caught only by the matching labelled statement/loop).
    brk: ?[]const u8,
    /// §14.8 continue — `null` for an unlabeled continue (caught by the innermost iteration), or the
    /// target loop's label name (caught only by the matching labelled iteration statement).
    cont: ?[]const u8,

    /// Any non-normal completion propagates (ReturnIfAbrupt, §5.2.3.4).
    pub fn isAbrupt(self: Completion) bool {
        return self != .normal;
    }
};
