type Mode = "dev" | "prod";

function label(mode: Mode): string {
  return mode == "dev" ? "debug" : "release";
}

let mode: Mode = "dev";

switch (mode) {
  case "dev":
    console.log(label(mode));
    break;
  case "prod":
    console.log("release");
    break;
}

mode = "prod";
console.log(label(mode));
