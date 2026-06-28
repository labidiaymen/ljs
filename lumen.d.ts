// Ambient declarations for editor/tsc compatibility. The Lumen compiler treats
// `Ref<T>` specially (a by-reference parameter); to plain TypeScript tooling it
// is just an identity alias so `.ts` sources still type-check and lint cleanly.
type Ref<T> = T;
