type Status = 200 | 404 | 500;

function label(s: Status): string {
  if (s === 200) {
    return "ok";
  }
  if (s === 404) {
    return "missing";
  }
  return "error";
}

let code: Status = 404;
console.log(label(code));
console.log(label(200));

switch (code) {
  case 200:
    console.log("a");
    break;
  case 404:
    console.log("b");
    break;
  default:
    console.log("c");
}
