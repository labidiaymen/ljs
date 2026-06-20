//! Completion Records (ECMA-262 §6.2.4) — the spine of evaluation. M1 adds the abrupt control
//! completions (`ret`/`brk`/`cont`) needed by functions and loops; `throw` already existed.
//! Statement-completion-value cycle adds the `empty` normal completion ([[Value]] = empty, §6.2.4)
//! and a carried [[Value]] on `brk`/`cont`, so §6.2.4.6 UpdateEmpty and the per-statement Evaluation
//! rules compute the right `eval(...)` completion value (the `cptn-*` Test262 cases).
const Value = @import("value.zig").Value;

/// §14.8/§14.9 break/continue completion: the (optional) target label plus the [[Value]] accumulated
/// by the enclosing StatementList at the point of the abrupt exit (§6.2.4.6 UpdateEmpty). `value` is
/// `null` when the [[Value]] is still ~empty~ (a bare `break;`/`continue;`); UpdateEmpty fills it with
/// the prior non-empty value. Surfacing an empty break/continue yields `undefined`.
pub const Abrupt = struct {
    label: ?[]const u8,
    value: ?Value = null,
};

pub const Completion = union(enum) {
    normal: Value,
    /// §6.2.4 a normal completion whose [[Value]] is ~empty~ — produced by declarations, the empty
    /// statement, `if(false)` with no else, a zero-iteration loop, an empty block. §6.2.4.6
    /// UpdateEmpty(C, V) replaces this with V (the prior non-empty value) when accumulating a list.
    empty,
    throw: Value,
    ret: Value, // §14.10 return
    /// §14.9 break — `label` is `null` for an unlabeled break (caught by the innermost
    /// iteration/switch), or the target label name (caught only by the matching labelled
    /// statement/loop). `value` carries the §6.2.4.6 UpdateEmpty-accumulated [[Value]].
    brk: Abrupt,
    /// §14.8 continue — `label` is `null` for an unlabeled continue (caught by the innermost
    /// iteration), or the target loop's label name (caught only by the matching labelled iteration
    /// statement). `value` carries the §6.2.4.6 UpdateEmpty-accumulated [[Value]].
    cont: Abrupt,

    /// Any non-normal completion propagates (ReturnIfAbrupt, §5.2.3.4). `.empty` is a NORMAL
    /// completion (empty [[Value]]) so it is NOT abrupt.
    pub fn isAbrupt(self: Completion) bool {
        return switch (self) {
            .normal, .empty => false,
            else => true,
        };
    }

    /// §6.2.4.6 UpdateEmpty(completionRecord, value): if this completion's [[Value]] is empty, set it
    /// to `v`; otherwise leave it unchanged. Used by StatementList / CaseBlock / loop / try evaluation
    /// to carry the last non-empty value forward across statements whose own value is empty.
    pub fn updateEmpty(self: Completion, v: Value) Completion {
        return switch (self) {
            .empty => .{ .normal = v },
            .normal => self,
            .brk => |a| .{ .brk = .{ .label = a.label, .value = a.value orelse v } },
            .cont => |a| .{ .cont = .{ .label = a.label, .value = a.value orelse v } },
            // §6.2.4.6 asserts the completion's [[Value]] is empty for throw/return — they never reach
            // UpdateEmpty in the statement evaluators (an abrupt throw/return propagates immediately).
            .throw, .ret => self,
        };
    }
};
