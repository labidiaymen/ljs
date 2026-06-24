#include "qjs_shim.h"

JSValue qjs_undefined(void) { return JS_UNDEFINED; }
int qjs_is_exception(JSValue v) { return JS_IsException(v); }
int qjs_is_function(JSContext *ctx, JSValue v) { return JS_IsFunction(ctx, v); }
JSValue qjs_dup(JSContext *ctx, JSValue v) { return JS_DupValue(ctx, v); }
void qjs_free(JSContext *ctx, JSValue v) { JS_FreeValue(ctx, v); }
JSValue qjs_call(JSContext *ctx, JSValue func, int argc, JSValue *argv) {
    return JS_Call(ctx, func, JS_UNDEFINED, argc, argv);
}
