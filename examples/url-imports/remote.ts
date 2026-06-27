// Import a module directly from a URL. The .ts is fetched over HTTPS at compile
// time and inlined into the build -- no package manager, no install step.
import greet from "https://lumen-lang.org/package/std-contrib/hello/hello.ts";

console.log(greet("world"));
