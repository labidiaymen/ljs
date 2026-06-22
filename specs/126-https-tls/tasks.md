# Tasks — Spec 126 HTTPS/TLS
- [x] host_https.fetchBlocking via std.http.Client (TLS+HTTP+certs+redirects)
- [x] CA bundle rescan (system roots) + allocating body writer
- [x] Route fetch('https://…') to it; build a Response
- [x] Verify against a real https URL; gate (test/lint/bench)
- [ ] (next) `https` module: https.get/request delivered via http-client events → axios/ws/node-fetch
- [ ] custom request headers + response headers; async (libxev) TLS path
