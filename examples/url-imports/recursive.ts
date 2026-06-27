// A remote module can import its own sibling files with a relative path. Here
// greeter.ts pulls in ./shout.ts, fetched relative to greeter's URL.
import greeter from "https://lumen-lang.org/package/std-contrib/greeter/greeter.ts";

console.log(greeter("Lumen"));
