// Round-trips a string through a C library using the `declare function` FFI
// form: text goes in as a C string and an uppercased C string comes back,
// copied into an owned Lumen string.
// Build the library first, then: lumen compile demo.ts
// @link ./shim.o
declare function shout(s: string): string;   // C: const char* shout(const char*)

console.log(shout("hi there"));   // HI THERE
