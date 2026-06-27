interface Box { label: string; }
function bad(b: Box | null): string {
  return b.label;
}
console.log(bad(null));
