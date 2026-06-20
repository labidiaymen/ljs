//! §10.1/§13.3 property access subsystem for the tree-walking interpreter — extracted from
//! interpreter.zig as free functions taking `self: *Interpreter` (Zig 0.16 removed `usingnamespace`,
//! so cross-file method sets are split into free functions reached via thin delegating wrappers).
//! Covers [[Get]]/[[Set]] (string + symbol + computed keys), private members, `super.x`, `[[Delete]]`,
//! the ordinary internal-method overloads used by the Proxy forwarding path, CopyDataProperties, and
//! HasProperty. Behavior-identical to the original methods; calls to OTHER interpreter methods stay
//! `self.foo(...)` (resolved via interpreter.zig's wrappers / remaining methods).
const std = @import("std");
const interpreter = @import("interpreter.zig");
const Interpreter = interpreter.Interpreter;
const EvalError = interpreter.EvalError;
const Completion = @import("completion.zig").Completion;
const Value = @import("value.zig").Value;
const Symbol = @import("value.zig").Symbol;
const object_mod = @import("object.zig");
const Object = object_mod.Object;
const ops = @import("abstract_ops.zig");
const sutf16 = @import("string_utf16.zig");
const builtin_proxy = @import("builtin_proxy.zig");
const builtin_object = @import("builtin_object.zig");
const tarray = @import("typed_array.zig");
const builtin_bigint = @import("builtin_bigint.zig");

const toNumber = ops.toNumber;
const toBoolean = ops.toBoolean;
const parseIndex = ops.parseIndex;
const numberToString = ops.numberToString;

const BoolOrAbrupt = Interpreter.BoolOrAbrupt;
const PVOrAbrupt = Interpreter.PVOrAbrupt;
const protoProxy = interpreter.Interpreter.protoProxy;

/// §15.7 PrivateGet — read PrivateName `key` on `base`. A private member access by `key` whose brand
/// name on a non-object, or on an object lacking the brand, is a TypeError (§15.7 — the brand
/// check). A private accessor invokes its getter with `this` = `base`; a getter-less accessor
/// (set-only) is a TypeError on read.
pub fn getPrivate(self: *Interpreter, base: Value, key: []const u8) EvalError!Completion {
    if (base != .object) return self.throwError("TypeError", "Cannot read private member from an object whose class did not declare it");
    const o = base.object;
    const pv = o.getPrivate(key) orelse
        return self.throwError("TypeError", "Cannot read private member from an object whose class did not declare it");
    switch (pv.payload) {
        .data => |v| return .{ .normal = v },
        .accessor => |a| {
            const getter = a.get orelse return self.throwError("TypeError", "'#x' was defined without a getter");
            return self.callFunction(getter, &.{}, base);
        },
    }
}

/// §15.7 PrivateSet — write PrivateName `key` on `base`'s own private slot. The brand must exist
/// (TypeError otherwise). A private field is writable; a private method is read-only (TypeError on
/// assignment); a private accessor invokes its setter with `this` = `base` (set-less → TypeError).
pub fn setPrivate(self: *Interpreter, base: Value, key: []const u8, value: Value) EvalError!Completion {
    if (base != .object) return self.throwError("TypeError", "Cannot write private member to an object whose class did not declare it");
    const o = base.object;
    const pv = o.getPrivate(key) orelse
        return self.throwError("TypeError", "Cannot write private member to an object whose class did not declare it");
    switch (pv.payload) {
        .data => |v| {
            // A private METHOD slot holds a function and is not assignable; a private FIELD is.
            if (v == .object and v.object.kind == .function and v.object.call != null and v.object.call.?.is_private_method) {
                return self.throwError("TypeError", "Cannot write to private method");
            }
            try o.setPrivate(key, value);
            return .{ .normal = value };
        },
        .accessor => |a| {
            const setter = a.set orelse return self.throwError("TypeError", "'#x' was defined without a setter");
            const sc = try self.callFunction(setter, &.{value}, base);
            if (sc.isAbrupt()) return sc;
            return .{ .normal = value };
        },
    }
}

/// §13.3.5 GetSuperBase + Get — resolve `super.<key>` against the active method's
/// [[HomeObject]].[[Prototype]], invoking accessors with `this` = the current `this` (the
/// receiver), NOT against `this`'s own properties. A missing home/proto yields `undefined`.
pub fn getSuperProperty(self: *Interpreter, key: []const u8) EvalError!Completion {
    const home = self.home_object orelse return .{ .normal = .undefined };
    const base = home.prototype orelse return .{ .normal = .undefined };
    const loc = base.getProp(key) orelse return .{ .normal = .undefined };
    switch (loc.pv.payload) {
        .data => |v| return .{ .normal = v },
        // §10.2.x: a getter found on the super chain runs with `this` = the current receiver.
        .accessor => |a| {
            const getter = a.get orelse return .{ .normal = .undefined };
            return self.callFunction(getter, &.{}, self.this_val);
        },
    }
}

/// §13.3.5/§6.2.5.6 SuperProperty write — `super.x = v`. The reference's base is the home
/// object's [[Prototype]] but the receiver is the current `this` (§10.1.9.2): an accessor found
/// on the super chain has its SETTER invoked with `this` = the receiver; otherwise the value is
/// written on the RECEIVER (the instance), not the prototype. (A non-writable data property on
/// the super chain rejecting the write is an M-subset-deferred edge — see spec 060.)
pub fn setSuperProperty(self: *Interpreter, key: []const u8, value: Value) EvalError!Completion {
    if (self.home_object) |home| if (home.prototype) |base| {
        if (base.getProp(key)) |loc| switch (loc.pv.payload) {
            .accessor => |a| {
                const setter = a.set orelse {
                    if (self.strict) return self.throwError("TypeError", "Cannot set property with only a getter");
                    return .{ .normal = value };
                };
                const c = try self.callFunction(setter, &.{value}, self.this_val);
                if (c.isAbrupt()) return c;
                return .{ .normal = value };
            },
            .data => {},
        };
    };
    // No accessor on the super chain → Set on the receiver (this), per OrdinarySet.
    return self.setProperty(self.this_val, key, value);
}

/// §7.3.25 CopyDataProperties(target, source, excluded) — copy own ENUMERABLE properties of `source`
/// (string + symbol keys) to `target`, skipping any string key in `excluded` (symbol-keyed properties
/// are never excluded by a string rest). A throwing getter / abrupt [[OwnPropertyKeys]] (a
/// Proxy) propagates. The single primitive behind object spread `{...src}` and the two
/// destructuring rest forms (§14.3.3 BindingRestProperty / §13.15.5.4 AssignmentRestProperty).
/// Returns null on success, or the abrupt Completion (a throwing getter / Proxy trap) to propagate.
pub fn copyDataPropertiesExcluding(self: *Interpreter, target: *Object, source: Value, excluded: []const []const u8) EvalError!?Completion {
    switch (source) {
        .undefined, .null => return null,
        .object => |o| {
            // §7.3.25 step 4: From = ToObject(source); keys = From.[[OwnPropertyKeys]]().
            const keys = switch (try self.ordinaryOwnKeys(o)) {
                .keys => |k| k,
                .abrupt => |c| return c,
            };
            for (keys) |key| {
                switch (key) {
                    .string => |ks| {
                        // §7.3.25 step 5.a: skip keys in the exclusion set (string rest only).
                        for (excluded) |ek| {
                            if (std.mem.eql(u8, ek, ks)) break;
                        } else {
                            // Own + Enumerable check, then [[Get]] + CreateDataPropertyOrThrow.
                            const desc = switch (try self.ordinaryGetOwnProperty(o, ks)) {
                                .pv => |pv| pv orelse continue,
                                .abrupt => |c| return c,
                            };
                            if (!desc.enumerable) continue;
                            const gc = try self.getProperty(source, ks);
                            if (gc.isAbrupt()) return gc;
                            try target.set(ks, gc.normal);
                        }
                    },
                    .symbol => |sym| {
                        const desc = switch (try self.ordinaryGetOwnPropertySymbol(o, sym)) {
                            .pv => |pv| pv orelse continue,
                            .abrupt => |c| return c,
                        };
                        if (!desc.enumerable) continue;
                        const gc = try self.getSymbolProperty(source, sym);
                        if (gc.isAbrupt()) return gc;
                        try target.setSymbol(sym, gc.normal);
                    },
                    else => {},
                }
            }
            return null;
        },
        .string => |s| {
            // §7.3.25: a primitive String boxes to enumerable character-index own properties.
            for (0..sutf16.utf16Length(s)) |i| {
                const k = try numberToString(self.arena, @floatFromInt(i));
                for (excluded) |ek| {
                    if (std.mem.eql(u8, ek, k)) break;
                } else try target.set(k, .{ .string = try sutf16.charAtAlloc(self.arena, s, i) });
            }
            return null;
        },
        else => return null,
    }
}

/// Object spread `{...source}` — §7.3.25 CopyDataProperties with no exclusions. Returns the abrupt
/// Completion (throwing getter / revoked Proxy) to propagate, else null.
pub fn copyDataProperties(self: *Interpreter, target: *Object, source: Value) EvalError!?Completion {
    return copyDataPropertiesExcluding(self, target, source, &.{});
}

pub fn getProperty(self: *Interpreter, base: Value, key: []const u8) EvalError!Completion {
    switch (base) {
        .object => |o| {
            if (o.proxy) |pd| return builtin_proxy.get(self, pd, .{ .string = key }, base); // §28.2.5.4 [[Get]]
            if (o.kind == .array) {
                if (std.mem.eql(u8, key, "length")) return .{ .normal = .{ .number = @floatFromInt(o.arrayLen()) } };
                if (parseIndex(key)) |i| {
                    // §10.4.2.4: a present own dense index returns its value. Otherwise fall through to
                    // the ordinary [[Get]] below, which (a) reads a non-default-attribute index demoted
                    // into the property map by `Object.defineProperty` (honoring its descriptor), or
                    // (b) for a true hole, walks the PROTOTYPE CHAIN so an inherited `Array.prototype[i]`
                    // is observed. A truly absent-everywhere index ends up undefined via that chain.
                    if (o.arrayHas(i)) return .{ .normal = o.arrayGet(i) };
                }
                // a non-index key falls through to the prototype chain (Array.prototype methods)
            }
            // §10.4.5.4: a TypedArray integer-indexed [[Get]] — a CanonicalNumericIndexString key is
            // handled entirely here (in-bounds → element, OOB/invalid/detached → undefined) and NEVER
            // resolves as an ordinary string property; a non-numeric key falls through to the chain.
            if (o.kind == .typed_array) {
                if (canonicalNumericIndex(self, key)) |n| return .{ .normal = try typedArrayGet(self, o, n) };
            }
            // §22.1.4.1/§10.4.3: a `new String(s)` wrapper is a String exotic — `.length` and the
            // canonical integer indices [0, len) read the boxed [[StringData]] (own, ahead of the
            // ordinary chain) so wrapper.length / wrapper[i] mirror the primitive (M-subset: byte
            // model). A defined own data property still wins (none clobbers these read-only slots).
            if (o.primitive != null and o.primitive.? == .string and o.getProp(key) == null) {
                const sv = o.primitive.?.string;
                if (std.mem.eql(u8, key, "length")) return .{ .normal = .{ .number = @floatFromInt(sutf16.utf16Length(sv)) } };
                if (parseIndex(key)) |i| {
                    if (sutf16.isAscii(sv)) {
                        if (i < sv.len) return .{ .normal = .{ .string = sv[i .. i + 1] } };
                    } else if (sutf16.codeUnitAt(sv, i) != null) {
                        return .{ .normal = .{ .string = try sutf16.charAtAlloc(self.arena, sv, i) } };
                    }
                }
            }
            // §10.4.4.3: a MAPPED arguments index reads the LIVE parameter binding (the map takes
            // precedence over the stored value, which may be stale after the parameter was reassigned).
            if (o.mapped_params) |mp| {
                if (parseIndex(key)) |i| {
                    if (i < mp.names.len and mp.names[i].len > 0) {
                        if (mp.env.lookupLocal(mp.names[i])) |b| return .{ .normal = b.value };
                    }
                }
            }
            // §10.1.8.1 OrdinaryGet — locate the property (data or accessor) on the chain.
            // Data-property fast path: a single descriptor read, no accessor branch.
            const loc = o.getProp(key) orelse {
                // §10.1.8.1 step 3: the property is absent on the ordinary string-keyed chain. An
                // INHERITED Array exotic's `length` / canonical index, or a boxed-String wrapper's
                // index/`length`, are internal slots invisible to `getProp` — resolve them by walking
                // the prototype chain (only reached on a miss, so the ordinary hot path is untouched).
                if (std.mem.eql(u8, key, "length") or parseIndex(key) != null) {
                    var p: ?*Object = o.prototype;
                    while (p) |holder| {
                        if (holder.kind == .array) {
                            if (std.mem.eql(u8, key, "length")) return .{ .normal = .{ .number = @floatFromInt(holder.arrayLen()) } };
                            if (parseIndex(key)) |i| if (holder.arrayHas(i)) return .{ .normal = holder.arrayGet(i) };
                        } else if (holder.primitive) |prim| {
                            if (prim == .string and holder.getProp(key) == null) {
                                if (std.mem.eql(u8, key, "length")) return .{ .normal = .{ .number = @floatFromInt(sutf16.utf16Length(prim.string)) } };
                                if (parseIndex(key)) |i| if (sutf16.codeUnitAt(prim.string, i) != null) {
                                    return .{ .normal = .{ .string = try sutf16.charAtAlloc(self.arena, prim.string, i) } };
                                };
                            }
                        }
                        // Stop at the first holder that owns the string key (an ordinary shadow).
                        if (holder.properties.getPtr(key) != null) break;
                        p = holder.prototype;
                    }
                }
                // If a Proxy sits on the prototype chain, its [[Get]] trap must fire (with `this`=base).
                if (protoProxy(o)) |pp| return builtin_proxy.get(self, pp, .{ .string = key }, base);
                return .{ .normal = .undefined };
            };
            switch (loc.pv.payload) {
                .data => |v| return .{ .normal = v },
                .accessor => |a| {
                    // §10.2.x: invoke the getter with `this` = the original receiver (`base`).
                    const getter = a.get orelse return .{ .normal = .undefined };
                    return self.callFunction(getter, &.{}, base);
                },
            }
        },
        .string => |s| {
            // §22.1: transparent boxing — `.length`, integer index, or a String.prototype method.
            // §6.1.4: `.length` and integer indices are UTF-16 code-unit quantities (ASCII fast path).
            if (std.mem.eql(u8, key, "length")) return .{ .normal = .{ .number = @floatFromInt(sutf16.utf16Length(s)) } };
            if (parseIndex(key)) |i| {
                if (sutf16.isAscii(s)) {
                    return .{ .normal = if (i < s.len) .{ .string = s[i .. i + 1] } else .undefined };
                }
                return .{ .normal = if (sutf16.codeUnitAt(s, i) != null) .{ .string = try sutf16.charAtAlloc(self.arena, s, i) } else .undefined };
            }
            if (self.stringProto()) |proto| {
                if (proto.get(key)) |m| return .{ .normal = m };
            }
            return .{ .normal = .undefined };
        },
        .symbol => |sym| {
            // §20.4: transparent boxing — `sym.toString`/`valueOf` resolve on Symbol.prototype, and
            // `sym.description` (§20.4.3.2) reads the [[Description]] directly.
            if (std.mem.eql(u8, key, "description")) {
                return .{ .normal = if (sym.description) |d| .{ .string = d } else .undefined };
            }
            if (self.globalProto("Symbol")) |proto| {
                if (proto.get(key)) |m| return .{ .normal = m };
            }
            return .{ .normal = .undefined };
        },
        .bigint => {
            // §6.1.6.2: transparent boxing — `(1n).toString` / `valueOf` / `constructor` resolve on
            // BigInt.prototype. (Accessors on the proto get `this` = the original primitive base.)
            if (self.globalProto("BigInt")) |proto| {
                const loc = proto.getProp(key) orelse return .{ .normal = .undefined };
                switch (loc.pv.payload) {
                    .data => |dv| return .{ .normal = dv },
                    .accessor => |a| {
                        const getter = a.get orelse return .{ .normal = .undefined };
                        return self.callFunction(getter, &.{}, base);
                    },
                }
            }
            return .{ .normal = .undefined };
        },
        .number => {
            // §21.1.3: transparent boxing — `(255).toString` / `valueOf` / `toFixed` / `constructor`
            // resolve on Number.prototype (accessors get `this` = the original primitive base).
            if (self.globalProto("Number")) |proto| {
                const loc = proto.getProp(key) orelse return .{ .normal = .undefined };
                switch (loc.pv.payload) {
                    .data => |dv| return .{ .normal = dv },
                    .accessor => |a| {
                        const getter = a.get orelse return .{ .normal = .undefined };
                        return self.callFunction(getter, &.{}, base);
                    },
                }
            }
            return .{ .normal = .undefined };
        },
        .boolean => {
            // §20.3.3: transparent boxing — `(true).toString` / `valueOf` resolve on Boolean.prototype.
            if (self.globalProto("Boolean")) |proto| {
                const loc = proto.getProp(key) orelse return .{ .normal = .undefined };
                switch (loc.pv.payload) {
                    .data => |dv| return .{ .normal = dv },
                    .accessor => |a| {
                        const getter = a.get orelse return .{ .normal = .undefined };
                        return self.callFunction(getter, &.{}, base);
                    },
                }
            }
            return .{ .normal = .undefined };
        },
        .undefined, .null => return self.throwError("TypeError", "Cannot read properties of null or undefined"),
    }
}

/// §10.1.9 [[Set]]. Setting on null/undefined throws; on other primitives is a no-op in M1.
/// Public wrapper over `setProperty` for the built-in method files (e.g. Array.from/of setting
/// `length` on a non-Array constructor result via §7.3.4 Set).
pub fn setPropertyPub(self: *Interpreter, base: Value, key: []const u8, value: Value) EvalError!Completion {
    return self.setProperty(base, key, value);
}

pub fn setProperty(self: *Interpreter, base: Value, key: []const u8, value: Value) EvalError!Completion {
    switch (base) {
        .object => |o| {
            if (o.proxy) |pd| { // §10.5.9 [[Set]] (P, V, Receiver = base)
                const c = try builtin_proxy.set(self, pd, .{ .string = key }, value, base);
                if (c.isAbrupt()) return c;
                if (!c.normal.boolean and self.strict) return self.throwError("TypeError", "proxy [[Set]] returned false");
                return .{ .normal = value };
            }
            if (o.kind == .array) {
                if (std.mem.eql(u8, key, "length")) {
                    // §23.1.4.1 ArraySetLength — ToNumber(value) (observable; ToPrimitive may run
                    // valueOf/toString), then ToUint32; a non-integral / >2^32-1 value is a RangeError.
                    // No eager fill on a length increase (sparse): just record it.
                    const nc = try self.toNumberV(value);
                    if (nc.isAbrupt()) return nc;
                    const n = toNumber(nc.normal);
                    if (std.math.isNan(n) or n < 0 or n > 4294967295.0 or n != @floor(n)) {
                        return self.throwError("RangeError", "Invalid array length");
                    }
                    const new_len: usize = @intFromFloat(n);
                    // §10.4.2.4: a non-writable `length` (frozen array, or an explicit
                    // defineProperty making it non-writable) rejects a CHANGE — TypeError in strict,
                    // silent no-op in sloppy. A no-op assignment to the same value is allowed.
                    if (!o.array_length_writable and new_len != o.arrayLen()) {
                        if (self.strict) return self.throwError("TypeError", "Cannot assign to read only property 'length'");
                        return .{ .normal = value };
                    }
                    try o.arraySetLen(new_len);
                    return .{ .normal = value };
                }
                if (parseIndex(key)) |i| {
                    // A non-default-attribute index that was demoted to the ordinary property map is
                    // NOT in the dense store — its writability/accessor semantics live in the map, so
                    // fall through to OrdinarySetWithOwnDescriptor below rather than the dense fast path.
                    if (!o.arrayHas(i) and o.properties.get(key) != null) {
                        // fall through to the §10.1.9.2 ordinary set path
                    } else if (o.extensible and !o.array_frozen) {
                        // Hot path: an extensible, non-frozen array takes the raw dense/sparse set.
                        try o.arraySet(o.arena, i, value);
                        return .{ .normal = value };
                    } else {
                        // §10.1.9.2: a frozen array rejects any element write; a non-extensible array
                        // rejects a NEW index (an existing index of a sealed array stays writable).
                        const reject = o.array_frozen or !o.arrayHas(i);
                        if (reject) {
                            if (self.strict) return self.throwError("TypeError", "Cannot add/modify property on a non-extensible array");
                            return .{ .normal = value };
                        }
                        try o.arraySet(o.arena, i, value);
                        return .{ .normal = value };
                    }
                }
            }
            // §10.4.5.5: a TypedArray integer-indexed [[Set]] — a CanonicalNumericIndexString key is
            // handled entirely here. The value is coerced (observably, even out-of-bounds); the byte
            // write lands only for a valid in-bounds index, else a silent no-op. The key is NEVER stored
            // as an ordinary string property. A non-numeric key falls through to the ordinary path.
            if (o.kind == .typed_array) {
                if (canonicalNumericIndex(self, key)) |n| {
                    if (try typedArraySet(self, o, n, value)) |abrupt| return abrupt;
                    return .{ .normal = value };
                }
            }
            // §10.1.9.2 OrdinarySetWithOwnDescriptor — if `key` resolves to an accessor on the
            // chain, invoke its setter with `this` = receiver; a getter-only accessor is a silent
            // no-op (sloppy). A data property (own or inherited) → define/overwrite an own data
            // property. The common case (absent or own data) stays a single `set`.
            if (o.getProp(key)) |loc| {
                if (loc.pv.payload == .accessor) {
                    const setter = loc.pv.payload.accessor.set orelse {
                        // §10.1.9.2: a getter-only accessor (own or inherited) → [[Set]] returns false;
                        // §6.2.5.6 PutValue throws in strict, silent no-op in sloppy.
                        if (self.strict) return self.throwError("TypeError", "Cannot set property that has only a getter");
                        return .{ .normal = value };
                    };
                    const sc = try self.callFunction(setter, &.{value}, base);
                    if (sc.isAbrupt()) return sc;
                    return .{ .normal = value };
                }
                // §10.1.9.2: a non-writable data property (own or inherited — an inherited non-writable
                // data property blocks creating a shadowing own property) → [[Set]] returns false.
                if (!loc.pv.writable) {
                    if (self.strict) return self.throwError("TypeError", "Cannot assign to read only property");
                    return .{ .normal = value };
                }
            }
            // §10.1.9.2 step 2: no own descriptor and `key` absent from the ordinary chain — if a
            // Proxy sits on the prototype chain, its [[Set]] trap runs with Receiver = base. (Only
            // when `o` has no own property for `key`: an own write stays on `o` below.)
            if (o.properties.get(key) == null and !(o.kind == .array and parseIndex(key) != null and o.arrayHas(parseIndex(key).?))) {
                if (protoProxy(o)) |pp| {
                    const c = try builtin_proxy.set(self, pp, .{ .string = key }, value, base);
                    if (c.isAbrupt()) return c;
                    if (!c.normal.boolean and self.strict) return self.throwError("TypeError", "proxy [[Set]] returned false");
                    return .{ .normal = value };
                }
            }
            // §10.1.9.2 → §10.1.6.3: creating a NEW own property on a non-extensible object is
            // rejected ([[Set]] returns false → throw in strict). An EXISTING own (writable) property
            // is still overwritten. Array `length`/indices are handled by the dense path above, so any
            // array key reaching here is a NEW non-index string property (e.g. `frozenTemplate.x = 1`)
            // — also rejected on a non-extensible array.
            if (!o.extensible and o.properties.get(key) == null) {
                if (self.strict) return self.throwError("TypeError", "Cannot add property, object is not extensible");
                return .{ .normal = value };
            }
            // §10.4.4.4: writing a MAPPED arguments index also writes the live parameter binding
            // (and vice-versa — keeping `arguments[i]` and the parameter in sync).
            if (o.mapped_params) |mp| {
                if (parseIndex(key)) |i| {
                    if (i < mp.names.len and mp.names[i].len > 0) {
                        if (mp.env.lookupLocal(mp.names[i])) |b| b.value = value;
                    }
                }
            }
            try o.set(key, value);
            return .{ .normal = value };
        },
        .undefined, .null => return self.throwError("TypeError", "Cannot set properties of null or undefined"),
        // §6.2.5.6 PutValue on a primitive base: ToObject(base) yields a fresh wrapper, then
        // OrdinarySetWithOwnDescriptor runs with Receiver = the primitive. An inherited accessor's
        // setter is invoked with `this` = base. Otherwise the write targets the (primitive) receiver
        // and fails — a TypeError in strict mode, a silent no-op in sloppy.
        else => return try setOnPrimitive(self, base, key, value),
    }
}

/// §10.1.9 [[Set]] over a primitive base (number/string/boolean/symbol/bigint). Resolves an inherited
/// setter on the wrapper prototype and calls it with `this` = the primitive; if no setter exists the
/// write would create/overwrite on the primitive receiver, which is rejected (strict → TypeError).
fn setOnPrimitive(self: *Interpreter, base: Value, key: []const u8, value: Value) EvalError!Completion {
    const proto: ?*Object = switch (base) {
        .string => self.stringProto(),
        .number => self.globalProto("Number"),
        .boolean => self.globalProto("Boolean"),
        .symbol => self.globalProto("Symbol"),
        .bigint => self.globalProto("BigInt"),
        else => null,
    };
    if (proto) |p| {
        if (p.getProp(key)) |loc| switch (loc.pv.payload) {
            .accessor => |a| {
                if (a.set) |setter| {
                    const c = try self.callFunction(setter, &.{value}, base);
                    if (c.isAbrupt()) return c;
                    return .{ .normal = value };
                }
                // A get-only inherited accessor: the write is rejected (strict → TypeError).
                if (self.strict) return self.throwError("TypeError", "Cannot set property which has only a getter");
                return .{ .normal = value };
            },
            .data => {}, // an inherited data property does not let the primitive receiver be written
        };
    }
    if (self.strict) return self.throwError("TypeError", "Cannot create property on a primitive value");
    return .{ .normal = value };
}

/// §13.3.3 / §7.1.19 ToPropertyKey-aware [[Get]] for a computed key (`a[k]`). A Symbol key routes
/// to the symbol-keyed store (no ToString); any other key ToString's and takes the ordinary string
/// path (the hot path, unchanged). Keeps the string get fast — the symbol branch is taken only when
/// the key actually IS a Symbol.
pub fn getPropertyV(self: *Interpreter, base: Value, key: Value) EvalError!Completion {
    if (key == .symbol) return self.getSymbolProperty(base, key.symbol);
    // §6.2.5.5 GetValue: RequireObjectCoercible(base) precedes ToPropertyKey — a null/undefined base
    // throws a TypeError *before* the key is coerced (so a throwing `key.toString` never runs).
    if (base == .undefined or base == .null) return self.throwError("TypeError", "Cannot read properties of null or undefined");
    // §7.1.19 ToPropertyKey: an object key is ToPrimitive(string)'d first (so `o[fn]` uses the
    // function's `toString`, matching `String(fn)`); the result may itself be a Symbol.
    if (key == .object) {
        const pc = try self.toPrimitive(key, .string);
        if (pc.isAbrupt()) return pc;
        if (pc.normal == .symbol) return self.getSymbolProperty(base, pc.normal.symbol);
        return self.getProperty(base, try self.toString(pc.normal));
    }
    return self.getProperty(base, try self.toString(key));
}

/// §13.3.3 ToPropertyKey-aware [[Set]] for a computed key (`a[k] = v`). Symbol → symbol store; else
/// ToString + the ordinary string path.
pub fn setPropertyV(self: *Interpreter, base: Value, key: Value, value: Value) EvalError!Completion {
    if (key == .symbol) return setSymbolProperty(self, base, key.symbol, value);
    // §6.2.5.6 PutValue: RequireObjectCoercible(base) precedes ToPropertyKey — a null/undefined base
    // throws a TypeError *before* the key is coerced (so a throwing `key.toString` never runs).
    if (base == .undefined or base == .null) return self.throwError("TypeError", "Cannot set properties of null or undefined");
    // §7.1.19 ToPropertyKey: ToPrimitive(string) an object key first (so `o[fn] = v` keys by the
    // function's `toString`, matching `String(fn)`); the primitive may be a Symbol.
    if (key == .object) {
        const pc = try self.toPrimitive(key, .string);
        if (pc.isAbrupt()) return pc;
        if (pc.normal == .symbol) return setSymbolProperty(self, base, pc.normal.symbol, value);
        return self.setProperty(base, try self.toString(pc.normal), value);
    }
    return self.setProperty(base, try self.toString(key), value);
}

/// §7.1.19 ToPropertyKey, returning the coerced key as a primitive Value (a String, or a Symbol
/// when the key is/ToPrimitive's to a Symbol). Used by read-then-write member operations (compound
/// assignment, `++`/`--`) so a side-effecting `key.toString` runs EXACTLY ONCE — the resulting
/// primitive is then passed to both `getPropertyV` and `setPropertyV` (which no-op on a primitive).
pub fn coercePropertyKey(self: *Interpreter, key: Value) EvalError!Completion {
    if (key != .object) return .{ .normal = key };
    const pc = try self.toPrimitive(key, .string);
    if (pc.isAbrupt()) return pc;
    if (pc.normal == .symbol) return .{ .normal = pc.normal };
    return .{ .normal = .{ .string = try self.toString(pc.normal) } };
}

/// §10.1.8 [[Get]] for a Symbol key — own/inherited symbol property (data or accessor). A primitive
/// base with no symbol slot yields undefined; null/undefined throws (matching the string path).
pub fn getSymbolProperty(self: *Interpreter, base: Value, key: *Symbol) EvalError!Completion {
    switch (base) {
        .object => |o| {
            if (o.proxy) |pd| return builtin_proxy.get(self, pd, .{ .symbol = key }, base); // §28.2.5.4 [[Get]]
            const loc = o.getSymbolProp(key) orelse {
                if (protoProxy(o)) |pp| return builtin_proxy.get(self, pp, .{ .symbol = key }, base);
                return .{ .normal = .undefined };
            };
            switch (loc.pv.payload) {
                .data => |v| return .{ .normal = v },
                .accessor => |a| {
                    const getter = a.get orelse return .{ .normal = .undefined };
                    return self.callFunction(getter, &.{}, base);
                },
            }
        },
        .undefined, .null => return self.throwError("TypeError", "Cannot read properties of null or undefined"),
        // §22.1/§20.4/etc.: a primitive boxes to its wrapper prototype for symbol keys too, so
        // `"ab"[Symbol.iterator]` and `Symbol.toPrimitive[Symbol.toPrimitive]` resolve the inherited
        // method/accessor (with `this` = the primitive base).
        else => {
            const proto: ?*Object = switch (base) {
                .string => self.stringProto(),
                .number => self.globalProto("Number"),
                .boolean => self.globalProto("Boolean"),
                .symbol => self.globalProto("Symbol"),
                .bigint => self.globalProto("BigInt"),
                else => null,
            };
            if (proto) |p| {
                if (p.getSymbolProp(key)) |loc| switch (loc.pv.payload) {
                    .data => |v| return .{ .normal = v },
                    .accessor => |a| {
                        const getter = a.get orelse return .{ .normal = .undefined };
                        return self.callFunction(getter, &.{}, base);
                    },
                };
            }
            return .{ .normal = .undefined };
        },
    }
}

/// §10.1.9 [[Set]] for a Symbol key — invoke an inherited setter if present, else define an own
/// symbol data property. Setting on null/undefined throws; on other primitives is a no-op.
pub fn setSymbolProperty(self: *Interpreter, base: Value, key: *Symbol, value: Value) EvalError!Completion {
    switch (base) {
        .object => |o| {
            if (o.proxy) |pd| { // §10.5.9 [[Set]] for a Symbol key
                const c = try builtin_proxy.set(self, pd, .{ .symbol = key }, value, base);
                if (c.isAbrupt()) return c;
                if (!c.normal.boolean and self.strict) return self.throwError("TypeError", "proxy [[Set]] returned false");
                return .{ .normal = value };
            }
            if (o.getSymbolProp(key)) |loc| {
                if (loc.pv.payload == .accessor) {
                    const setter = loc.pv.payload.accessor.set orelse {
                        // §10.1.9.2: a getter-only accessor → [[Set]] returns false (throw in strict).
                        if (self.strict) return self.throwError("TypeError", "Cannot set property that has only a getter");
                        return .{ .normal = value };
                    };
                    const sc = try self.callFunction(setter, &.{value}, base);
                    if (sc.isAbrupt()) return sc;
                    return .{ .normal = value };
                }
                // §10.1.9.2: a non-writable data property (own or inherited) → [[Set]] returns false.
                if (!loc.pv.writable) {
                    if (self.strict) return self.throwError("TypeError", "Cannot assign to read only property");
                    return .{ .normal = value };
                }
            }
            if (ownSymbol(o, key) == null) {
                if (protoProxy(o)) |pp| { // §10.1.9.2: Proxy on the proto chain handles the [[Set]]
                    const c = try builtin_proxy.set(self, pp, .{ .symbol = key }, value, base);
                    if (c.isAbrupt()) return c;
                    if (!c.normal.boolean and self.strict) return self.throwError("TypeError", "proxy [[Set]] returned false");
                    return .{ .normal = value };
                }
                // §10.1.9.2 → §10.1.6.3: creating a NEW own symbol property on a non-extensible
                // object is rejected ([[Set]] returns false → throw in strict).
                if (!o.extensible) {
                    if (self.strict) return self.throwError("TypeError", "Cannot add property, object is not extensible");
                    return .{ .normal = value };
                }
            }
            try o.setSymbol(key, value);
            return .{ .normal = value };
        },
        .undefined, .null => return self.throwError("TypeError", "Cannot set properties of null or undefined"),
        // §6.2.5.6 PutValue on a primitive base with a symbol key — same rejection as string keys
        // (no inherited symbol setter is resolved here; strict → TypeError, sloppy → no-op).
        else => {
            if (self.strict) return self.throwError("TypeError", "Cannot create property on a primitive value");
            return .{ .normal = value };
        },
    }
}

/// §13.5.1.2 / §10.1.10 [[Delete]] — remove the own property `key` from `base`. A non-configurable
/// own property is NOT deleted and yields `false` (so `delete` on a sealed/frozen property reports
/// correctly); an absent property yields `true`. On a primitive base, deletion is a no-op → true.
pub fn deleteProperty(self: *Interpreter, base: Value, key: []const u8) EvalError!Completion {
    switch (base) {
        .object => |o| {
            if (o.proxy) |pd| return builtin_proxy.deleteProperty(self, pd, .{ .string = key }); // §10.5.10 [[Delete]]
            if (o.kind == .array) {
                // §10.4.2/§22.1.4.1: an Array's `length` is a non-configurable own property — a
                // [[Delete]] of it always returns false (it is synthetic, never in `properties`).
                if (std.mem.eql(u8, key, "length")) return .{ .normal = .{ .boolean = false } };
                if (parseIndex(key)) |i| {
                    // A non-default-attribute index lives in the property map; honor its
                    // [[Configurable]] (a frozen/sealed or explicit non-configurable index can't be
                    // deleted → false, no removal). §10.1.10.1.
                    if (o.properties.get(key)) |pv| {
                        if (!pv.configurable) return .{ .normal = .{ .boolean = false } };
                        _ = o.properties.orderedRemove(key);
                        try o.arrayDelete(i);
                        return .{ .normal = .{ .boolean = true } };
                    }
                    // §10.4.2.1: a frozen array's dense indices are non-configurable → undeletable.
                    if (o.array_frozen and o.arrayHas(i)) return .{ .normal = .{ .boolean = false } };
                    // delete a dense/sparse index → a true hole (dense slot recorded in `holes`,
                    // sparse entry removed). The slot reads `undefined` and is absent thereafter.
                    try o.arrayDelete(i);
                    return .{ .normal = .{ .boolean = true } };
                }
            }
            if (o.properties.get(key)) |pv| {
                if (!pv.configurable) return .{ .normal = .{ .boolean = false } }; // §10.1.10.1 step 4
                _ = o.properties.orderedRemove(key); // ordered delete preserves the remaining keys' order
                // §10.4.4.4: deleting a MAPPED arguments index also removes it from the [[ParameterMap]],
                // so a later read no longer aliases the (still-live) parameter binding.
                if (o.mapped_params) |mp| {
                    if (parseIndex(key)) |i| if (i < mp.names.len) {
                        mp.names[i] = "";
                    };
                }
            }
            return .{ .normal = .{ .boolean = true } };
        },
        .undefined, .null => return self.throwError("TypeError", "Cannot convert undefined or null to object"),
        else => return .{ .normal = .{ .boolean = true } },
    }
}

/// §10.1.5 / §10.4.2.1 [[GetOwnProperty]] for a string key → the stored attributes (data/accessor),
/// or null when absent. Array indices / `length` and String-exotic indices yield synthetic
/// descriptors. Routes through the proxy trap when `o` is a Proxy.
pub fn ordinaryGetOwnProperty(self: *Interpreter, o: *Object, key: []const u8) EvalError!PVOrAbrupt {
    if (o.proxy) |pd| {
        const c = try builtin_proxy.getOwnProperty(self, pd, .{ .string = key });
        if (c.isAbrupt()) return .{ .abrupt = c };
        // The trap path returns a descriptor object (or undefined); convert back to a PropertyValue.
        return .{ .pv = try descriptorObjectToPV(self, c.normal) };
    }
    if (o.kind == .array) {
        if (std.mem.eql(u8, key, "length")) return .{ .pv = .{ .payload = .{ .data = .{ .number = @floatFromInt(o.arrayLen()) } }, .writable = o.array_length_writable, .enumerable = false, .configurable = false } };
        if (parseIndex(key)) |i| {
            if (o.properties.getPtr(key)) |pv| return .{ .pv = pv.* };
            if (o.arrayHas(i)) return .{ .pv = .{ .payload = .{ .data = o.arrayGet(i) }, .writable = !o.array_frozen, .enumerable = true, .configurable = !o.array_frozen } };
            return .{ .pv = null };
        }
    }
    if (o.primitive != null and o.primitive.? == .string and o.properties.getPtr(key) == null) {
        const sv = o.primitive.?.string;
        if (std.mem.eql(u8, key, "length")) return .{ .pv = .{ .payload = .{ .data = .{ .number = @floatFromInt(sutf16.utf16Length(sv)) } }, .writable = false, .enumerable = false, .configurable = false } };
        if (parseIndex(key)) |i| {
            if (sutf16.isAscii(sv)) {
                if (i < sv.len) return .{ .pv = .{ .payload = .{ .data = .{ .string = sv[i .. i + 1] } }, .writable = false, .enumerable = true, .configurable = false } };
            } else if (sutf16.codeUnitAt(sv, i) != null) {
                return .{ .pv = .{ .payload = .{ .data = .{ .string = try sutf16.charAtAlloc(self.arena, sv, i) } }, .writable = false, .enumerable = true, .configurable = false } };
            }
        }
    }
    if (o.properties.getPtr(key)) |pv| return .{ .pv = pv.* };
    return .{ .pv = null };
}

/// §10.1.5 [[GetOwnProperty]] for a Symbol key → stored attributes or null. Proxy-aware.
pub fn ordinaryGetOwnPropertySymbol(self: *Interpreter, o: *Object, key: *Symbol) EvalError!PVOrAbrupt {
    if (o.proxy) |pd| {
        const c = try builtin_proxy.getOwnProperty(self, pd, .{ .symbol = key });
        if (c.isAbrupt()) return .{ .abrupt = c };
        return .{ .pv = try descriptorObjectToPV(self, c.normal) };
    }
    for (o.symbol_props.items) |sp| {
        if (sp.key == key) return .{ .pv = sp.pv };
    }
    return .{ .pv = null };
}

/// Convert a descriptor OBJECT (as returned by a proxy `getOwnPropertyDescriptor` trap, already
/// ToPropertyDescriptor-completed by the trap path) back into a stored PropertyValue. `undefined`
/// → null (property absent). Used so descriptor-level callers see a uniform shape.
pub fn descriptorObjectToPV(self: *Interpreter, v: Value) EvalError!?object_mod.PropertyValue {
    _ = self;
    if (v != .object) return null;
    const d = v.object;
    const has_get = d.properties.get("get") != null;
    const has_set = d.properties.get("set") != null;
    const enumerable = if (d.get("enumerable")) |e| toBoolean(e) else false;
    const configurable = if (d.get("configurable")) |c| toBoolean(c) else false;
    if (has_get or has_set) {
        const g = if (d.get("get")) |gv| (if (gv == .object) gv.object else null) else null;
        const s = if (d.get("set")) |sv| (if (sv == .object) sv.object else null) else null;
        return .{ .payload = .{ .accessor = .{ .get = g, .set = s } }, .enumerable = enumerable, .configurable = configurable };
    }
    const val = if (d.get("value")) |vv| vv else Value.undefined;
    const writable = if (d.get("writable")) |w| toBoolean(w) else false;
    return .{ .payload = .{ .data = val }, .writable = writable, .enumerable = enumerable, .configurable = configurable };
}

/// §10.1.6 / §10.4.2.1 [[DefineOwnProperty]] → boolean. Proxy-aware; Array-index aware. For an
/// ordinary object, delegates to `Object.defineProperty`. (Array `length` keeps the store path.)
pub fn ordinaryDefineOwnProperty(self: *Interpreter, o: *Object, key: []const u8, d: object_mod.Descriptor) EvalError!BoolOrAbrupt {
    if (o.proxy) |pd| {
        const c = try builtin_proxy.defineProperty(self, pd, .{ .string = key }, d);
        if (c.isAbrupt()) return .{ .abrupt = c };
        return .{ .ok = c.normal.boolean };
    }
    if (o.kind == .array and !std.mem.eql(u8, key, "length")) {
        if (builtin_object.arrayIndex(key)) |idx| {
            const adc = try builtin_object.arrayDefineIndex(self, o, idx, key, d);
            return .{ .ok = !adc.isAbrupt() };
        }
    }
    const ok = try o.defineProperty(key, d);
    return .{ .ok = ok };
}

pub fn ordinaryDefineOwnPropertySymbol(self: *Interpreter, o: *Object, key: *Symbol, d: object_mod.Descriptor) EvalError!BoolOrAbrupt {
    if (o.proxy) |pd| {
        const c = try builtin_proxy.defineProperty(self, pd, .{ .symbol = key }, d);
        if (c.isAbrupt()) return .{ .abrupt = c };
        return .{ .ok = c.normal.boolean };
    }
    const ok = try o.defineSymbol(key, d);
    return .{ .ok = ok };
}

/// §10.1.1 [[GetPrototypeOf]] → the prototype (object or null). Proxy-aware.
pub fn ordinaryGetPrototypeOf(self: *Interpreter, o: *Object) EvalError!Interpreter.ProtoOrAbrupt {
    if (o.proxy) |pd| {
        const c = try builtin_proxy.getPrototypeOf(self, pd);
        if (c.isAbrupt()) return .{ .abrupt = c };
        return .{ .proto = if (c.normal == .object) c.normal.object else null };
    }
    return .{ .proto = o.prototype };
}

/// §10.1.2 [[SetPrototypeOf]] → boolean. Proxy-aware.
pub fn ordinarySetPrototypeOf(self: *Interpreter, o: *Object, proto: ?*Object) EvalError!BoolOrAbrupt {
    if (o.proxy) |pd| {
        const c = try builtin_proxy.setPrototypeOf(self, pd, proto);
        if (c.isAbrupt()) return .{ .abrupt = c };
        return .{ .ok = c.normal.boolean };
    }
    if (o.prototype == proto) return .{ .ok = true };
    if (!o.extensible) return .{ .ok = false };
    // §10.1.2 step 8: walk the proposed prototype chain; reject if it would create a cycle
    // back to `o`. Stop walking at a proxy (its [[GetPrototypeOf]] is not statically known).
    var p = proto;
    while (p) |pp| {
        if (pp == o) return .{ .ok = false };
        if (pp.proxy != null) break;
        p = pp.prototype;
    }
    o.prototype = proto;
    return .{ .ok = true };
}

/// §10.1.3 [[IsExtensible]] → boolean. Proxy-aware.
pub fn ordinaryIsExtensible(self: *Interpreter, o: *Object) EvalError!Interpreter.ExtOrAbrupt {
    if (o.proxy) |pd| {
        const c = try builtin_proxy.isExtensible(self, pd);
        if (c.isAbrupt()) return .{ .abrupt = c };
        return .{ .ext = c.normal.boolean };
    }
    return .{ .ext = o.extensible };
}

/// §10.1.4 [[PreventExtensions]] → boolean. Proxy-aware.
pub fn ordinaryPreventExtensions(self: *Interpreter, o: *Object) EvalError!BoolOrAbrupt {
    if (o.proxy) |pd| {
        const c = try builtin_proxy.preventExtensions(self, pd);
        if (c.isAbrupt()) return .{ .abrupt = c };
        return .{ .ok = c.normal.boolean };
    }
    o.extensible = false;
    return .{ .ok = true };
}

/// §10.1.11 [[OwnPropertyKeys]] → the own keys as an allocated `[]Value` (strings then symbols for
/// an ordinary object; for an Array: indices, `length`, string keys, symbols). Proxy-aware.
pub fn ordinaryOwnKeys(self: *Interpreter, o: *Object) EvalError!Interpreter.KeysOrAbrupt {
    if (o.proxy) |pd| {
        const c = try builtin_proxy.ownKeys(self, pd);
        if (c.isAbrupt()) return .{ .abrupt = c };
        // The trap path returns an Array of keys; flatten to a slice.
        const arr = c.normal.object;
        return .{ .keys = try self.arena.dupe(Value, arr.elements.items[0..arr.arrayLen()]) };
    }
    var list: std.ArrayListUnmanaged(Value) = .empty;
    if (o.kind == .array) {
        for (try o.arrayIndices(self.arena)) |i| try list.append(self.arena, .{ .string = try numberToString(self.arena, @floatFromInt(i)) });
        try list.append(self.arena, .{ .string = "length" });
    }
    // §10.1.11.1: integer-index string keys ascending, then the rest in insertion order, then
    // Symbol keys last. `orderedStringKeys` handles the index/insertion partition for the store.
    for (try o.orderedStringKeys(self.arena)) |key| try list.append(self.arena, .{ .string = key });
    for (o.symbol_props.items) |sp| try list.append(self.arena, .{ .symbol = sp.key });
    return .{ .keys = try list.toOwnedSlice(self.arena) };
}

/// §7.3.12 HasProperty as a Completion (so a Proxy `has` trap that throws/revokes can propagate).
/// Use this wherever the result feeds a JS-observable operation (`in`, `Reflect.has`).
pub fn hasPropertyVC(self: *Interpreter, base: Value, key: Value) EvalError!Completion {
    if (base == .object) {
        const o = base.object;
        if (o.proxy) |pd| return builtin_proxy.has(self, pd, key);
        // §10.1.7 OrdinaryHasProperty: own check, then delegate to a Proxy on the proto chain.
        // A non-symbol key is normally a string, but a numeric index (e.g. from a typed-array `in`)
        // can arrive un-coerced — ToPropertyKey it (§7.1.19: ToString for a number) rather than read
        // the wrong union field.
        const own = if (key == .symbol)
            o.getSymbolProp(key.symbol) != null
        else
            ownHasString(o, if (key == .string) key.string else try self.toPropertyKeyString(key));
        if (own) return .{ .normal = .{ .boolean = true } };
        if (protoProxy(o)) |pp| return builtin_proxy.has(self, pp, key);
    }
    const b = try self.hasPropertyV(base, key);
    return .{ .normal = .{ .boolean = b } };
}

fn ownSymbol(o: *Object, key: *Symbol) ?Value {
    for (o.symbol_props.items) |sp| if (sp.key == key) return .undefined;
    return null;
}

fn ownHasString(o: *Object, ks: []const u8) bool {
    if (o.kind == .array) {
        if (std.mem.eql(u8, ks, "length")) return true;
        if (parseIndex(ks)) |i| if (o.arrayHas(i)) return true;
    }
    return o.properties.get(ks) != null;
}

pub fn hasPropertyV(self: *Interpreter, base: Value, key: Value) EvalError!bool {
    const o = base.object;
    if (o.proxy) |pd| { // §10.5.7 [[HasProperty]] — non-throwing callers only (forwarding chains).
        const c = try builtin_proxy.has(self, pd, key);
        return if (c == .normal) c.normal.boolean else false;
    }
    if (key == .symbol) return o.getSymbolProp(key.symbol) != null;
    const ks = try self.toPropertyKeyString(key);
    if (o.kind == .array) {
        if (std.mem.eql(u8, ks, "length")) return true;
        if (parseIndex(ks)) |i| if (o.arrayHas(i)) return true;
    }
    if (o.get(ks) != null) return true;
    if (protoProxy(o)) |pp| {
        const c = try builtin_proxy.has(self, pp, key);
        return if (c == .normal) c.normal.boolean else false;
    }
    return false;
}

// ── §10.4.5 Integer-Indexed (TypedArray) exotic element access ───────────────
// A TypedArray's [[Get]]/[[Set]] for a CanonicalNumericIndexString key (§6.1.7) is fully handled by
// the integer-indexed logic (§10.4.5.4/.5) and NEVER falls through to ordinary string-keyed storage:
// such a key is never an own string property. These helpers gate behind `kind == .typed_array` so the
// ordinary property hot path is byte-for-byte unchanged (the bench guard).

/// §6.1.7 CanonicalNumericIndexString — if `key` is the canonical String form of a Number `n`
/// (`ToString(ToNumber(key)) === key`, plus the special case `"-0"`), return that Number; else null.
/// A canonical numeric index need NOT be an integer index (`"1.5"`, `"Infinity"`, `"-1"` qualify) —
/// IsValidIntegerIndex applies the further integrality/bounds test.
fn canonicalNumericIndex(self: *Interpreter, key: []const u8) ?f64 {
    if (std.mem.eql(u8, key, "-0")) return -0.0;
    // ToNumber(key): a non-numeric string yields NaN. NaN's canonical string is "NaN" — so a key of
    // "NaN" round-trips and IS a canonical numeric index (an out-of-range one). Any other non-canonical
    // spelling (leading zeros, whitespace, "+1") fails the round-trip below and is an ordinary key.
    const n = ops.stringToNumber(key);
    const canon = numberToString(self.arena, n) catch return null;
    return if (std.mem.eql(u8, canon, key)) n else null;
}

/// §10.4.5.4 [[Get]] for a TypedArray integer-indexed key. `n` is the CanonicalNumericIndexString value.
/// IsValidIntegerIndex (§10.4.5.1): not detached, integral, not -0, and `0 <= n < array_length`. A valid
/// index reads the element via the codec; any out-of-bounds / invalid / detached read yields `undefined`.
pub fn typedArrayGet(self: *Interpreter, o: *Object, n: f64) EvalError!Value {
    const ta = o.typed_array.?;
    const buf = ta.buffer.array_buffer orelse return .undefined;
    if (buf.detached) return .undefined; // §10.4.5.1 step 1: a detached buffer → invalid index
    if (n != @floor(n) or std.math.signbit(n) and n == 0) return .undefined; // not integral, or -0
    // §10.4.5.1: bound against the LIVE length (tracking views follow the resized buffer; fixed views
    // are clamped to what the live bytes hold), not the stored `array_length`.
    const live_len = tarray.liveLength(ta.tracks_length, ta.array_length, ta.byte_offset, buf.bytes.len, ta.elem.bytesPerElement());
    if (n < 0 or n >= @as(f64, @floatFromInt(live_len))) return .undefined; // out of bounds
    const i: usize = @intFromFloat(n);
    // Clamp byteOffset: a resizable buffer may have shrunk below it, so `bytes[byte_offset..]` itself
    // would be out of range; an empty live slice makes getElement's bounds guard return undefined.
    const v = try tarray.getElement(ta.elem, buf.bytes[@min(ta.byte_offset, buf.bytes.len)..], i, self.arena);
    return v;
}

/// §10.4.5.5 [[Set]] for a TypedArray integer-indexed key. The value is ALWAYS coerced (ToNumber, or
/// ToBigInt for a bigint-content array) — observably, even for an out-of-bounds index (§10.4.5.16
/// IntegerIndexedElementSet) — but the byte write happens only for a valid in-bounds index; an invalid
/// or detached write is a silent no-op. Returns the abrupt completion if coercion throws, else null.
pub fn typedArraySet(self: *Interpreter, o: *Object, n: f64, value: Value) EvalError!?Completion {
    const ta = o.typed_array.?;
    // §10.4.5.16 step 1-2: coerce the value per the array's content type FIRST (always observable).
    var num: f64 = 0;
    var big: ?*const std.math.big.int.Const = null;
    if (ta.elem.contentType() == .bigint) {
        const bc = try builtin_bigint.toBigIntPub(self, value);
        if (bc.isAbrupt()) return bc;
        big = bc.normal.bigint;
    } else {
        const nc = try self.toNumberThrowing(value);
        if (nc.isAbrupt()) return nc;
        num = nc.normal.number;
    }
    // §10.4.5.1 IsValidIntegerIndex — write only when the index is valid; else a silent no-op.
    const buf = ta.buffer.array_buffer orelse return null;
    if (buf.detached) return null;
    if (n != @floor(n) or (std.math.signbit(n) and n == 0)) return null;
    // §10.4.5.1: bound against the LIVE length (see typedArrayGet).
    const live_len = tarray.liveLength(ta.tracks_length, ta.array_length, ta.byte_offset, buf.bytes.len, ta.elem.bytesPerElement());
    if (n < 0 or n >= @as(f64, @floatFromInt(live_len))) return null;
    const i: usize = @intFromFloat(n);
    // Clamp byteOffset (see typedArrayGet): a shrunk resizable buffer may sit below it; the empty live
    // slice makes setElement's bounds guard a no-op.
    try tarray.setElement(ta.elem, buf.bytes[@min(ta.byte_offset, buf.bytes.len)..], i, num, big);
    return null;
}
