interface Box {
  label: string;
}

function nameOf(b: Box | null): string {
  if (b != null) {
    return b.label;
  }
  return "none";
}

let bx: Box = { label: "hi" };
console.log(nameOf(bx));

let empty: Box | null = null;
console.log(nameOf(empty));
console.log(empty?.label ?? "default");

let present: Box | null = { label: "here" };
console.log(present?.label ?? "default");
