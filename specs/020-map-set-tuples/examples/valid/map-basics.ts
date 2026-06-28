function showKV(v: int, k: string): void {
  console.log(k);
  console.log(v);
}

let m: Map<string, int> = new Map<string, int>();
m.set("a", 1);
m.set("b", 2);
m.set("a", 10);
console.log(m.size);
console.log(m.get("a"));
console.log(m.get("missing"));
console.log(m.has("b"));
console.log(m.has("z"));
console.log(m.delete("b"));
console.log(m.delete("b"));
console.log(m.size);

let ks: string[] = m.keys();
console.log(ks[0]);
let vs: int[] = m.values();
console.log(vs[0]);

m.set("c", 30);
m.forEach((v: int, k: string) => showKV(v, k));
