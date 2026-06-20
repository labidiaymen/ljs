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
pub const runHost = engine.runHost;
pub const evalHost = engine.evalHost;
pub const HostCtx = engine.HostCtx;
pub const evaluateWithLimit = engine.evaluateWithLimit;
pub const evaluateWithLimitL = engine.evaluateWithLimitL;
pub const evaluateAsyncTest = engine.evaluateAsyncTest;
pub const evaluateAsyncTestL = engine.evaluateAsyncTestL;
pub const AsyncTestResult = engine.AsyncTestResult;
pub const default_step_limit = engine.default_step_limit;
pub const evaluateModule = engine.evaluateModule;
pub const evaluateAsyncModule = engine.evaluateAsyncModule;
pub const ModuleLoader = engine.ModuleLoader;
pub const ResolvedSource = engine.ResolvedSource;

test {
    // Pull in every module so `zig build test` runs their unit tests.
    _ = @import("value.zig");
    _ = @import("completion.zig");
    _ = @import("environment.zig");
    _ = @import("object.zig");
    _ = @import("typed_array.zig");
    _ = @import("abstract_ops.zig");
    _ = @import("builtins.zig");
    _ = @import("builtin_array.zig");
    _ = @import("builtin_string.zig");
    _ = @import("ast.zig");
    _ = @import("unicode_id.zig");
    _ = @import("lexer.zig");
    _ = @import("parser.zig");
    _ = @import("interpreter.zig");
    _ = @import("module.zig");
    _ = @import("engine.zig");
    _ = @import("engine_tests.zig");
    _ = @import("engine_tests2.zig");
    _ = @import("engine_tests3.zig");
    _ = @import("engine_tests4.zig");
}
