interface Config {
  host: string;
  port?: int;
}

function portOf(c: Config): int {
  return c.port ?? 8080;
}

let dev: Config = { host: "localhost" };
console.log(dev.host);
console.log(portOf(dev));

let prod: Config = { host: "api", port: 443 };
console.log(portOf(prod));
