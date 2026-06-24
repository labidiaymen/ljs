// Thin C shim over quickjs.h: wraps the value-construction MACROS (JS_UNDEFINED, JS_MKVAL, …) and a
// couple of inline helpers as real exported functions, so Zig's translate-c (@cImport) can call them.
// translate-c can't reproduce quickjs's compound-literal macros; these give a clean Zig-callable ABI.
#ifndef QJS_SHIM_H
#define QJS_SHIM_H
#include "quickjs.h"

JSValue qjs_undefined(void);
int qjs_is_exception(JSValue v);
int qjs_is_function(JSContext *ctx, JSValue v);
JSValue qjs_dup(JSContext *ctx, JSValue v);
void qjs_free(JSContext *ctx, JSValue v);
// Call `func` with `this = undefined`.
JSValue qjs_call(JSContext *ctx, JSValue func, int argc, JSValue *argv);

#endif
