// A remote module can import its own sibling files with a relative path. Here
// greeter.ts pulls in ./shout.ts, fetched relative to greeter's URL.
import greeter from "https://raw.githubusercontent.com/lumen-lang-org/std-contrib/main/packages/greeter/greeter.ts";

console.log(greeter("Lumen"));
