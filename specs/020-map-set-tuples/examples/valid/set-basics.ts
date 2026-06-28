function showV(v: string): void {
  console.log(v);
}

let s: Set<string> = new Set<string>();
s.add("red");
s.add("green");
s.add("red");
s.add("blue");
console.log(s.size);
console.log(s.has("green"));
console.log(s.has("yellow"));
console.log(s.delete("green"));
console.log(s.delete("green"));
console.log(s.size);

let vs: string[] = s.values();
console.log(vs.length);
console.log(vs[0]);

s.forEach((v: string) => showV(v));
