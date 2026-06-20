//! §19.2.1 PerformEval and §20.2.1.1 CreateDynamicFunction (the `eval` / `Function(...)` machinery).
//! Extracted from interp_expr.zig (behavior-preserving split, Zig 0.16 has no `usingnamespace`) to
//! keep that core under the file-size budget. Free functions taking `self: *Interpreter`.
const std = @import("std");
const Value = @import("value.zig").Value;
const Completion = @import("completion.zig").Completion;
const Environment = @import("environment.zig").Environment;
const object_mod = @import("object.zig");
const Parser = @import("parser.zig").Parser;
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;
const interp_stmt = @import("interp_stmt.zig");

/// §20.2.1.1 / §20.2.1.1.1 CreateDynamicFunction — `Function(p1, …, pN, body)`: the last argument is
/// the function body, the rest are parameter texts (joined with `,`). Builds the source
/// `(function anonymous(<params>\n) {\n<body>\n})` and evaluates it in the GLOBAL scope (the dynamic
/// function closes over global bindings, not the caller's), returning the resulting function. A
/// malformed parameter/body → a catchable SyntaxError (via performEval). The `\n` after the params
/// and around the body match the spec text (prevent `//`-comment / `)` injection from hiding the
/// closing delimiters). The function's name is `anonymous`; its strictness comes from its own body.
pub fn functionConstructor(self: *Interpreter, args: []const Value) EvalError!Completion {
    const genv = self.globals orelse return self.throwError("EvalError", "Function: no realm");
    var params: std.ArrayListUnmanaged(u8) = .empty;
    var body: []const u8 = "";
    if (args.len > 0) {
        for (args[0 .. args.len - 1], 0..) |p, i| {
            const sc = try self.toStringValuePub(p);
            if (sc.isAbrupt()) return sc;
            if (i > 0) try params.appendSlice(self.arena, ",");
            try params.appendSlice(self.arena, sc.normal.string);
        }
        const bc = try self.toStringValuePub(args[args.len - 1]);
        if (bc.isAbrupt()) return bc;
        body = bc.normal.string;
    }
    const source = try std.fmt.allocPrint(self.arena, "(function anonymous({s}\n) {{\n{s}\n}})", .{ params.items, body });
    // Evaluate in the global context with the global `this` (the dynamic function is created there).
    const saved_this = self.this_val;
    const saved_home = self.home_object;
    defer {
        self.this_val = saved_this;
        self.home_object = saved_home;
    }
    self.this_val = if (genv.lookup("%GlobalThis%")) |b| b.value else .undefined;
    self.home_object = null;
    return performEval(self, source, genv, false, false);
}

/// §19.2.1.1 PerformEval — parse `source` as a Script and run it in `target_env` on THIS interpreter
/// (so the live step/depth counters carry through; runaway eval code still terminates). A parse error
/// → a real catchable `SyntaxError`. `target_env` is a fresh child of the caller's env for DIRECT
/// eval, or the GLOBAL env for INDIRECT eval. A DIRECT eval is a continuation of the caller's context,
/// so its body may use `super`/`new.target`/private references legal in the surrounding method/class —
/// those §13.x parse-context flags are seeded from the interpreter's current execution context.
pub fn performEval(self: *Interpreter, source: []const u8, target_env: *Environment, inherit_strict: bool, direct: bool) EvalError!Completion {
    // §19.2.1.1: the eval code is strict iff it carries its own `"use strict"` prologue OR (DIRECT
    // eval only) the calling context is strict (`inherit_strict`). Parsing with the inherited flag
    // folds both into `program.strict`, which `run` installs as the eval body's runtime strictness.
    const program = blk: {
        if (!direct) break :blk Parser.parseMode(self.arena, source, inherit_strict);
        // §15.7 the in-scope private spellings = every Private Name on the running [[PrivateEnvironment]]
        // chain (so `eval("this.#x")` inside a method parses; resolution at runtime uses `private_env`).
        var pn_list: std.ArrayListUnmanaged([]const u8) = .empty;
        var pe: ?*const object_mod.PrivateEnv = self.private_env;
        while (pe) |frame| : (pe = frame.parent) {
            for (frame.names) |pn| try pn_list.append(self.arena, pn.spelling);
        }
        break :blk Parser.parseEvalMode(self.arena, source, inherit_strict, .{
            // §13.3.5: `super.x` is legal iff the caller is in a method/constructor (has a HomeObject).
            .in_method = self.home_object != null,
            // §13.3.7.1: `super(...)` is legal iff the caller is directly in a derived constructor.
            .in_derived_ctor = self.this_init_cell != null,
            // §13.3.12: `new.target` is legal inside any function body (func_depth > 0).
            .in_function = self.func_depth > 0,
            // §15.7: a private reference is legal inside a class body (the chain is non-empty).
            .in_class_body = self.private_env != null,
            .in_generator = self.current_gen != null,
            .private_names = pn_list.items,
        });
    } catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        // §19.2.1 step 7: a parse failure throws a SyntaxError (a real, catchable error object).
        else => return self.throwError("SyntaxError", "eval: invalid source"),
    };
    // §19.2.1.3 step 3.d: a SLOPPY direct eval evaluated inside a function's formal-parameter list
    // (`f(p = eval("var arguments"))`) hoists its `var`/function declarations into the caller's var
    // scope, but the parameter env's `arguments` binding (§10.2.11 step 22) sits between the eval's
    // lexical env and that var scope. A var/function-declaration of `arguments` therefore collides
    // with it and is a SyntaxError. A STRICT eval (own var scope) / indirect eval do not trigger this.
    if (direct and self.in_param_init and !program.strict and
        interp_stmt.declaresVarOrFuncName(program.statements, "arguments"))
    {
        return self.throwError("SyntaxError", "eval cannot declare 'arguments' in a parameter-scope direct eval");
    }
    // §19.2.1.3: a STRICT eval gets its OWN VariableEnvironment (its `var`s are eval-local); a SLOPPY
    // direct eval's `var`s hoist to the caller's var scope (its fresh eval env is left a non-var-scope
    // so `varScope()` climbs past it). An indirect eval / Function-body eval already targets the
    // global var scope, which this preserves (`or`-ing keeps an existing var scope).
    target_env.is_var_scope = target_env.is_var_scope or program.strict;
    // §19.2.1.3 step 9.d.ii.2 / 12.b.ii.2: a (sloppy) direct eval whose `var`/function declarations
    // hoist into a NON-GLOBAL function VariableEnvironment creates them DELETABLE, so a later
    // `delete x` removes them (`var-env-*-local-new-delete`). A strict / indirect / global-scoped eval
    // do not get this flag. The flag is read by the var/function hoist in `run`.
    const saved_eval_deletable = self.eval_var_deletable;
    self.eval_var_deletable = direct and !program.strict and target_env.varScope() != self.globals;
    defer self.eval_var_deletable = saved_eval_deletable;
    // Reuse `run` (ReturnIfAbrupt over the statement list); the completion value is the last
    // statement's value. Counters are the interpreter's own — not reset, so limits still apply.
    return self.run(program, target_env);
}
