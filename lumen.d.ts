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
