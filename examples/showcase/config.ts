// Nullability (optional fields, ??, narrowing) and defer.

interface Settings {
  host: string;
  port?: int;
}

function connect(s: Settings): void {
  using _ = defer(() => console.log("connection closed"));
  let port = s.port ?? 8080;
  console.log(`connecting to ${s.host}:${port}`);
}

function label(name: string | null): string {
  if (name != null) {
    return name;
  }
  return "anonymous";
}

connect({ host: "localhost" });
connect({ host: "api.example.com", port: 443 });

console.log(label("ada"));
console.log(label(null));
