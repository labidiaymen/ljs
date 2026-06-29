# Lumen playground compile service

A small HTTP service that powers the in-browser Lumen playground. It takes Lumen
source over HTTP, compiles it to WebAssembly, and returns the `.wasm` bytes for
the browser to run. The service only **compiles** code — it never executes user
programs, so the browser stays in control of running anything.

## API

### `POST /compile`

Send the Lumen source as the raw request body.

- **Success** → `200 OK`, `Content-Type: application/wasm`, body is the compiled
  `.wasm` module.
- **Compile error** → `400 Bad Request`, `Content-Type: application/json`, body
  is `{"error": "<diagnostic text>"}`.

```sh
# Compile and save the wasm module.
curl -s -X POST --data 'const n: int = 41; console.log(n + 1);' \
  https://<your-app>.fly.dev/compile -o out.wasm

# A program the wasm target can't build returns a 400 with the diagnostic.
curl -s -X POST --data 'console.log(undefinedName);' \
  https://<your-app>.fly.dev/compile
# -> {"error":"play.ts:1:13: error: ..."}
```

### `GET /health`

Returns `200 OK` with the body `ok`. Used for readiness checks.

### CORS

Every response (including errors and the `OPTIONS` preflight, which returns
`204`) carries permissive CORS headers so a browser playground served from any
origin can call the service:

```
Access-Control-Allow-Origin: *
Access-Control-Allow-Methods: POST, OPTIONS
Access-Control-Allow-Headers: Content-Type
```

## Guards

Because the service only compiles (it never runs user code), it needs just two
guards:

- **Body size**: requests larger than 512 KiB are rejected with `413`.
- **Compile timeout**: each compile is capped at 20 seconds.

The listen port comes from the `PORT` environment variable (default `8080`), and
the service binds `0.0.0.0`.

## Deploy to Fly.io

All commands are run **from the repository root** so the Docker build context
includes `src/` and `build.zig`. Edit the `app` name in `playground/fly.toml`
first (or let `fly launch` set one).

```sh
# From the repo root.

# One-time: create the Fly app without deploying yet.
fly launch --no-deploy \
  --config playground/fly.toml \
  --dockerfile playground/Dockerfile

# Build and deploy (also used for every subsequent update).
fly deploy \
  --config playground/fly.toml \
  --dockerfile playground/Dockerfile
```

### Scale to zero

`playground/fly.toml` configures the service to scale to zero: with
`auto_stop_machines = "stop"`, `auto_start_machines = true`, and
`min_machines_running = 0`, Fly stops the machine when traffic is idle and
starts it again on the next request. The first request after an idle period pays
a short cold-start; subsequent requests are served from the running machine.

## Local development

```sh
# From the repo root: build the compiler, then the service.
zig build
zig build-exe playground/server.zig -O ReleaseSafe -femit-bin=./server

# Run with the compiler on PATH (it is invoked by name at runtime).
PATH="$PWD/zig-out/bin:$PATH" PORT=8080 ./server
```

Then `curl` it as shown above using `localhost:8080`.
