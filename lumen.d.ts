// Ambient declarations for editor / tsc compatibility.
//
// Lumen's source is TypeScript *syntax*, but it has a few names plain TypeScript
// does not know. Referencing this file lets standard tsc/eslint/editor tooling
// type-check and lint `.ts` sources without "cannot find name" errors. The Lumen
// compiler itself ignores this file and applies its own, stricter rules.

// Numeric and boolean type spellings. To Lumen these are DISTINCT types (e.g.
// `i32` vs `i64`, integer vs float), checked as such by the compiler; to plain
// TypeScript they collapse to `number`/`boolean` — enough to keep tooling quiet
// without claiming tsc enforces Lumen's numeric rules.
type int = number;
type i32 = number;
type i64 = number;
type float = number;
type f64 = number;
type bool = boolean;

// `Ref<T>` is a by-reference parameter in Lumen; to TypeScript it is just an
// identity alias.
type Ref<T> = T;

// Runtime globals Lumen provides. Declared here (rather than relying on the DOM
// lib) so tooling type-checks `console.log(...)` without pulling in browser
// globals — the generated tsconfig keeps `lib` to `ESNext` only, so there is no
// duplicate-`console` clash.
declare const console: {
  log(...args: any[]): void;
  error(...args: any[]): void;
};

// `using` resource management (TypeScript 5.2). A `using x = value;` declaration
// disposes `value` at the end of the enclosing scope; multiple declarations
// dispose in reverse (LIFO) order. The ESNext lib already defines `Disposable`
// with `[Symbol.dispose]`; this interface-merge documents the `dispose()` method
// Lumen calls on a class instance bound by `using`.
interface Disposable {
  dispose(): void;
}

// `defer(fn)` is Lumen's built-in scope-exit helper: the tsc-clean spelling of a
// deferred cleanup is `using _ = defer(() => /* cleanup */);`, which runs `fn`
// when the enclosing scope exits.
declare function defer(fn: () => void): Disposable;

// Testing. `test("name", () => { ... })` declares a test run by `lumen test`
// (Jest/Vitest/node:test-style). Inside a test body, `expect` asserts either a
// boolean condition or a matcher on a value:
//   expect(cond);                       // boolean assertion
//   expect(actual).toBe(expected);      // strict equality
//   expect(actual).toEqual(expected);   // strict equality (V1 alias of toBe)
declare function test(name: string, fn: () => void): void;
interface Matchers<T> {
  toBe(expected: T): void;
  toEqual(expected: T): void;
}
declare function expect(condition: boolean): void;
declare function expect<T>(actual: T): Matchers<T>;
