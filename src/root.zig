//! Root of the `ljs` module — the engine's public surface, imported by the CLI (`main.zig`),
//! the Test262 harness, and the benchmark runner.

pub const Value = @import("value.zig").Value;
pub const Completion = @import("completion.zig").Completion;
pub const Environment = @import("environment.zig").Environment;
pub const Object = @import("object.zig").Object;
const engine = @import("engine.zig");
pub const RunMode = engine.RunMode;
pub const EvaluationResult = engine.EvaluationResult;
pub const evaluate = engine.evaluate;
pub const evaluateWithLimit = engine.evaluateWithLimit;
pub const default_step_limit = engine.default_step_limit;

test {
    // Pull in every module so `zig build test` runs their unit tests.
    _ = @import("value.zig");
    _ = @import("completion.zig");
    _ = @import("environment.zig");
    _ = @import("object.zig");
    _ = @import("ast.zig");
    _ = @import("lexer.zig");
    _ = @import("parser.zig");
    _ = @import("interpreter.zig");
    _ = @import("engine.zig");
}
