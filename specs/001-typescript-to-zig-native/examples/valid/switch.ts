let command = "build";
let code = 0;

switch (command) {
  case "test":
    code = 1;
    break;
  case "build":
    code = 2;
    break;
  default:
    code = 3;
}

console.log(code);
