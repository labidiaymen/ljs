# Tasks — Spec 113 (fs sync completeness)

- [x] `appendFileSync` — read existing (ENOENT→empty) + concat + writeFile
- [x] `unlinkSync` → `deleteFile`
- [x] `rmSync` → `deleteTree` if `{recursive:true}` else `deleteFile` (+ `{force}` suppresses ENOENT)
- [x] `rmdirSync` → `deleteDir`
- [x] `renameSync` → `rename`
- [x] `copyFileSync` → `copyFile`
- [x] `accessSync` → `access` (throw `ENOENT` on failure)
- [x] In-engine round-trip script (write→append→copy→rename→read→rm→assert-gone) — **byte-identical to Node**
- [x] Gates: `zig build test` / `lint` / `bench` green

## Refactor (same cycle — file-size best practice)
- [x] Extract the `fs` + `os` subsystem (~290 lines) out of `host_require.zig` into a new focused
      `host_fs.zig` (delegation pattern: `host_require.coreModuleFn` routes `fs`/`os` → `host_fs`;
      `defineCoreMethod` made `pub`). host_require.zig 1046→756 lines; host_fs.zig 301 lines.
