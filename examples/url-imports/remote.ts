// Import a module directly from a URL. The .ts is fetched over HTTPS at compile
// time and inlined into the build -- no package manager, no install step.
import greet from "https://raw.githubusercontent.com/lumen-lang-org/std-contrib/main/packages/hello/hello.ts";

console.log(greet("world"));
