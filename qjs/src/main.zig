//! QuickJS-embedded runtime — proof of life. Embeds the quickjs-ng C engine (real, conformant JS:
//! full bytecode VM, UTF-16 strings, templates/`\p{}`/everything) and evaluates JS from Zig. This is
//! the seed of the "Zig host layer over a proven engine" track (the txiki.js / Bun pattern).
//!
//! Next: wire a host API surface (fs/http/timers) against `JSContext`, reusing the design from the
//! from-scratch ljs runtime. For now it just proves the engine compiles, links, and runs JS that the
//! hand-written engine struggled with (nested templates, `\p{L}` regex).
const std = @import("std");
const c = @cImport({
    @cInclude("quickjs.h");
});

pub fn main() !void {
    const rt = c.JS_NewRuntime() orelse return error.RuntimeInit;
    defer c.JS_FreeRuntime(rt);
    const ctx = c.JS_NewContext(rt) orelse return error.ContextInit;
    defer c.JS_FreeContext(ctx);

    // Exactly the kinds of JS the hand-written ljs engine had to be patched for, one after another:
    // nested template literals, regex-in-interpolation, and `\p{…}` Unicode property escapes.
    const code =
        \\const wrap = (x) => `[${`<${x}>`}]`;          // nested template
        \\const ident = /^[_\p{L}][_0-9\p{L}]*$/u;       // \p{} property escape
        \\const esc = `${"a".replace(/"/g, '\\"')}`;     // regex w/ quote in interpolation
        \\JSON.stringify({ wrap: wrap("ok"), ident: ident.test("fooBar9"), esc });
    ;
    const val = c.JS_Eval(ctx, code.ptr, code.len, "<embed>", c.JS_EVAL_TYPE_GLOBAL);
    defer c.JS_FreeValue(ctx, val);

    if (c.JS_IsException(val)) {
        const exc = c.JS_GetException(ctx);
        defer c.JS_FreeValue(ctx, exc);
        const es = c.JS_ToCStringLen2(ctx, null, exc, false);
        defer if (es != null) c.JS_FreeCString(ctx, es);
        std.debug.print("Exception: {s}\n", .{es});
        return error.JsException;
    }
    const s = c.JS_ToCStringLen2(ctx, null, val, false);
    defer if (s != null) c.JS_FreeCString(ctx, s);
    std.debug.print("quickjs result: {s}\n", .{s});
}
