// qjs bootstrap — a minimal Node-compat standard library in JS, over the native primitives
// (__serve / __respond / __readFile / __print). Loaded once at startup. This is the "JS stdlib on
// native bindings" split Node itself uses. Scope: enough to load and serve with http / express GET.
(function () {
  'use strict';
  var G = globalThis;
  if (!Error.captureStackTrace) Error.captureStackTrace = function () { };

  // TextEncoder/TextDecoder (quickjs core lacks them) — minimal UTF-8.
  if (typeof G.TextEncoder === 'undefined') {
    G.TextEncoder = function () { this.encoding = 'utf-8'; };
    G.TextEncoder.prototype.encode = function (str) {
      str = String(str); var b = [];
      for (var i = 0; i < str.length; i++) {
        var c = str.charCodeAt(i);
        if (c < 0x80) b.push(c);
        else if (c < 0x800) b.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
        else if (c >= 0xd800 && c < 0xdc00 && i + 1 < str.length) { var c2 = str.charCodeAt(++i); var cp = 0x10000 + ((c & 0x3ff) << 10) + (c2 & 0x3ff); b.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f)); }
        else b.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
      }
      return Uint8Array.from(b);
    };
  }
  if (typeof G.TextDecoder === 'undefined') {
    G.TextDecoder = function () { this.encoding = 'utf-8'; };
    G.TextDecoder.prototype.decode = function (buf) {
      if (!buf) return ''; var u = buf instanceof Uint8Array ? buf : new Uint8Array(buf.buffer || buf); var out = '', i = 0;
      while (i < u.length) {
        var c = u[i++];
        if (c < 0x80) out += String.fromCharCode(c);
        else if (c < 0xe0) out += String.fromCharCode(((c & 0x1f) << 6) | (u[i++] & 0x3f));
        else if (c < 0xf0) out += String.fromCharCode(((c & 0xf) << 12) | ((u[i++] & 0x3f) << 6) | (u[i++] & 0x3f));
        else { var cp = ((c & 0x7) << 18) | ((u[i++] & 0x3f) << 12) | ((u[i++] & 0x3f) << 6) | (u[i++] & 0x3f); cp -= 0x10000; out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff)); }
      }
      return out;
    };
  }

  // ── tiny utils ──────────────────────────────────────────────────────────────
  function _dirname(p) {
    p = p.replace(/\\/g, '/').replace(/\/+$/, '');
    var i = p.lastIndexOf('/');
    return i <= 0 ? (p[0] === '/' ? '/' : '.') : p.slice(0, i);
  }
  function _normalize(p) {
    p = p.replace(/\\/g, '/');
    var abs = p[0] === '/';
    var parts = p.split('/'), out = [];
    for (var i = 0; i < parts.length; i++) {
      var s = parts[i];
      if (s === '' || s === '.') continue;
      if (s === '..') { if (out.length && out[out.length - 1] !== '..') out.pop(); else if (!abs) out.push('..'); }
      else out.push(s);
    }
    return (abs ? '/' : '') + out.join('/');
  }

  // ── console / process ───────────────────────────────────────────────────────
  function _fmt(args) { return Array.prototype.map.call(args, function (a) { return typeof a === 'string' ? a : _inspect(a); }).join(' '); }
  G.console = {
    log: function () { __print(_fmt(arguments)); },
    error: function () { __print(_fmt(arguments)); },
    warn: function () { __print(_fmt(arguments)); },
    info: function () { __print(_fmt(arguments)); },
    debug: function () { __print(_fmt(arguments)); },
    trace: function () { },
  };
  var process = {
    env: { NODE_ENV: '' },
    argv: ['qjs', G.__entryPath || ''],
    platform: 'linux',
    arch: 'x64',
    version: 'v22.0.0',
    versions: { node: '22.0.0', qjs: '1' },
    pid: 1,
    cwd: function () { return '.'; },
    nextTick: function (fn) { var a = Array.prototype.slice.call(arguments, 1); queueMicrotask(function () { fn.apply(null, a); }); },
    on: function () { return this; },
    once: function () { return this; },
    off: function () { return this; },
    emit: function () { return false; },
    exit: function () { },
    hrtime: function (p) { var t = Date.now() * 1e6; if (p) return [0, 0]; return [Math.floor(t / 1e9), 0]; },
    stdout: { write: function (s) { __print(s); return true; } },
    stderr: { write: function (s) { __print(s); return true; } },
  };
  process.hrtime.bigint = function () { return BigInt(Date.now()) * 1000000n; };
  G.process = process;
  G.global = G;

  // ── inspect (very small) ─────────────────────────────────────────────────────
  function _inspect(v, seen) {
    seen = seen || [];
    if (v === null) return 'null';
    if (typeof v === 'string') return seen.length ? "'" + v + "'" : v;
    if (typeof v === 'function') return '[Function' + (v.name ? ': ' + v.name : ' (anonymous)') + ']';
    if (typeof v !== 'object') return String(v);
    if (seen.indexOf(v) >= 0) return '[Circular]';
    if (v instanceof Error) return v.stack || (v.name + ': ' + v.message);
    seen.push(v);
    var out;
    if (Array.isArray(v)) out = '[ ' + v.map(function (x) { return _inspect(x, seen); }).join(', ') + ' ]';
    else out = '{ ' + Object.keys(v).map(function (k) { return k + ': ' + _inspect(v[k], seen); }).join(', ') + ' }';
    seen.pop();
    return out;
  }

  // ── EventEmitter ─────────────────────────────────────────────────────────────
  // _ev is lazily created so mixin(app, EventEmitter.prototype) without `new` still works (express).
  function _evs(o) { return o._ev || (o._ev = Object.create(null)); }
  function EventEmitter() { this._ev = Object.create(null); }
  EventEmitter.prototype.on = function (t, f) { var e = _evs(this); (e[t] || (e[t] = [])).push(f); return this; };
  EventEmitter.prototype.addListener = EventEmitter.prototype.on;
  EventEmitter.prototype.once = function (t, f) { var self = this; function g() { self.off(t, g); return f.apply(this, arguments); } g.listener = f; return this.on(t, g); };
  EventEmitter.prototype.off = function (t, f) { var a = _evs(this)[t]; if (a) { for (var i = 0; i < a.length; i++) if (a[i] === f || a[i].listener === f) { a.splice(i, 1); break; } } return this; };
  EventEmitter.prototype.removeListener = EventEmitter.prototype.off;
  EventEmitter.prototype.removeAllListeners = function (t) { if (t) delete _evs(this)[t]; else this._ev = Object.create(null); return this; };
  EventEmitter.prototype.emit = function (t) { var a = _evs(this)[t]; if (!a) { if (t === 'error') throw arguments[1]; return false; } var args = Array.prototype.slice.call(arguments, 1); a.slice().forEach(function (f) { f.apply(this, args); }); return true; };
  EventEmitter.prototype.listeners = function (t) { return (_evs(this)[t] || []).slice(); };
  EventEmitter.prototype.listenerCount = function (t) { return (_evs(this)[t] || []).length; };
  EventEmitter.prototype.setMaxListeners = function () { return this; };
  EventEmitter.prototype.prependListener = EventEmitter.prototype.on;
  EventEmitter.defaultMaxListeners = 10;

  // ── util ─────────────────────────────────────────────────────────────────────
  function _inherits(ctor, superCtor) {
    ctor.super_ = superCtor;
    ctor.prototype = Object.create(superCtor.prototype, { constructor: { value: ctor, enumerable: false, writable: true, configurable: true } });
  }
  var util = {
    inherits: _inherits,
    inspect: function (v) { return _inspect(v); },
    format: function (f) {
      var args = Array.prototype.slice.call(arguments, 1), i = 0;
      if (typeof f !== 'string') return _fmt(arguments);
      var s = f.replace(/%[sdjifoO%]/g, function (m) { if (m === '%%') return '%'; if (i >= args.length) return m; var a = args[i++]; if (m === '%d' || m === '%i') return String(parseInt(a)); if (m === '%f') return String(parseFloat(a)); if (m === '%j') return JSON.stringify(a); if (m === '%s') return String(a); return _inspect(a); });
      for (; i < args.length; i++) s += ' ' + (typeof args[i] === 'string' ? args[i] : _inspect(args[i]));
      return s;
    },
    deprecate: function (fn) { return fn; },
    debuglog: function () { return function () { }; },
    promisify: function (fn) { return function () { var args = Array.prototype.slice.call(arguments), self = this; return new Promise(function (res, rej) { args.push(function (e, v) { e ? rej(e) : res(v); }); fn.apply(self, args); }); }; },
    isBuffer: function (x) { return x instanceof Buffer; },
    isArray: Array.isArray,
    isFunction: function (x) { return typeof x === 'function'; },
    isString: function (x) { return typeof x === 'string'; },
    isObject: function (x) { return x !== null && typeof x === 'object'; },
    isNullOrUndefined: function (x) { return x == null; },
    types: { isDate: function (x) { return x instanceof Date; } },
    inspect_custom: Symbol.for('nodejs.util.inspect.custom'),
  };

  // ── Buffer (over Uint8Array) ─────────────────────────────────────────────────
  var _enc = typeof TextEncoder !== 'undefined' ? new TextEncoder() : null;
  var _dec = typeof TextDecoder !== 'undefined' ? new TextDecoder() : null;
  function _u8(s) { return _enc ? _enc.encode(s) : Uint8Array.from(unescape(encodeURIComponent(s)), function (c) { return c.charCodeAt(0); }); }
  function _us(u) { return _dec ? _dec.decode(u) : decodeURIComponent(escape(String.fromCharCode.apply(null, u))); }
  function Buffer() { }
  Buffer.from = function (v, enc) {
    if (typeof v === 'string') { var u = _u8(v); var b = new Uint8Array(u.length); b.set(u); Object.setPrototypeOf(b, BufProto); return b; }
    if (v instanceof Uint8Array || Array.isArray(v)) { var b2 = new Uint8Array(v.length); b2.set(v); Object.setPrototypeOf(b2, BufProto); return b2; }
    if (typeof v === 'number') { var b3 = new Uint8Array(v); Object.setPrototypeOf(b3, BufProto); return b3; }
    return Buffer.alloc(0);
  };
  Buffer.alloc = function (n, fill) { var b = new Uint8Array(n); Object.setPrototypeOf(b, BufProto); if (fill != null) b.fill(typeof fill === 'string' ? fill.charCodeAt(0) : fill); return b; };
  Buffer.allocUnsafe = function (n) { return Buffer.alloc(n); };
  Buffer.isBuffer = function (x) { return x instanceof Uint8Array && Object.getPrototypeOf(x) === BufProto; };
  Buffer.byteLength = function (s) { return typeof s === 'string' ? _u8(s).length : s.length; };
  Buffer.concat = function (list, len) { if (len == null) { len = 0; for (var i = 0; i < list.length; i++) len += list[i].length; } var out = Buffer.alloc(len), o = 0; for (var j = 0; j < list.length; j++) { var b = list[j]; out.set(b.subarray(0, Math.min(b.length, len - o)), o); o += b.length; if (o >= len) break; } return out; };
  var BufProto = Object.create(Uint8Array.prototype);
  BufProto.toString = function (enc, s, e) { var sub = this.subarray(s || 0, e == null ? this.length : e); if (enc === 'hex') { var h = ''; for (var i = 0; i < sub.length; i++) h += sub[i].toString(16).padStart(2, '0'); return h; } return _us(sub); };
  BufProto.slice = function (a, b) { var r = this.subarray(a, b); Object.setPrototypeOf(r, BufProto); return r; };
  BufProto.constructor = Buffer;
  Buffer.prototype = BufProto;
  G.Buffer = Buffer;

  // ── string_decoder ───────────────────────────────────────────────────────────
  function StringDecoder() { } StringDecoder.prototype.write = function (b) { return _us(b); }; StringDecoder.prototype.end = function () { return ''; };

  // ── stream (minimal, EventEmitter-based) ─────────────────────────────────────
  function Stream() { EventEmitter.call(this); } _inherits(Stream, EventEmitter);
  Stream.prototype.pipe = function (dest) { var self = this; this.on('data', function (c) { dest.write(c); }); this.on('end', function () { dest.end(); }); return dest; };
  function Readable(opts) { Stream.call(this); this.readable = true; } _inherits(Readable, Stream);
  Readable.prototype.read = function () { return null; };
  Readable.prototype.setEncoding = function () { return this; };
  Readable.prototype.resume = function () { return this; };
  Readable.prototype.pause = function () { return this; };
  Readable.prototype.push = function (c) { if (c === null) this.emit('end'); else this.emit('data', c); return true; };
  function Writable(opts) { Stream.call(this); this.writable = true; } _inherits(Writable, Stream);
  Writable.prototype.write = function (c, e, cb) { this.emit('data', c); if (typeof e === 'function') e(); else if (typeof cb === 'function') cb(); return true; };
  Writable.prototype.end = function (c, e, cb) { if (c) this.write(c); this.emit('finish'); if (typeof c === 'function') c(); else if (typeof e === 'function') e(); else if (typeof cb === 'function') cb(); return this; };
  function Duplex(o) { Readable.call(this, o); this.writable = true; } _inherits(Duplex, Readable);
  Duplex.prototype.write = Writable.prototype.write; Duplex.prototype.end = Writable.prototype.end;
  function Transform(o) { Duplex.call(this, o); } _inherits(Transform, Duplex);
  function PassThrough(o) { Transform.call(this, o); } _inherits(PassThrough, Transform);
  Stream.Readable = Readable; Stream.Writable = Writable; Stream.Duplex = Duplex; Stream.Transform = Transform; Stream.PassThrough = PassThrough; Stream.Stream = Stream;

  // ── querystring / url ────────────────────────────────────────────────────────
  var querystring = {
    parse: function (s) { var o = {}; if (!s) return o; s.split('&').forEach(function (p) { var i = p.indexOf('='); var k = decodeURIComponent((i < 0 ? p : p.slice(0, i)).replace(/\+/g, ' ')); var v = i < 0 ? '' : decodeURIComponent(p.slice(i + 1).replace(/\+/g, ' ')); if (k in o) { if (!Array.isArray(o[k])) o[k] = [o[k]]; o[k].push(v); } else o[k] = v; }); return o; },
    stringify: function (o) { return Object.keys(o || {}).map(function (k) { return encodeURIComponent(k) + '=' + encodeURIComponent(o[k]); }).join('&'); },
    escape: encodeURIComponent, unescape: decodeURIComponent,
    decode: function (s) { return querystring.parse(s); }, encode: function (o) { return querystring.stringify(o); },
  };
  function parseUrl(u) {
    var m = /^([a-zA-Z][a-zA-Z0-9+.-]*:)?(?:\/\/([^\/?#]*))?([^?#]*)(\?[^#]*)?(#.*)?$/.exec(u || '');
    var pathname = m[3] || '', search = m[4] || '', host = m[2] || '';
    return { href: u, protocol: m[1] || null, host: host || null, hostname: host.split(':')[0] || null, port: host.split(':')[1] || null, pathname: pathname, path: pathname + search, search: search || null, query: search ? search.slice(1) : null, hash: m[5] || null };
  }
  var url = { parse: function (u, pq) { var r = parseUrl(u); if (pq) r.query = querystring.parse(r.query || ''); return r; }, format: function (o) { return o.href || ((o.protocol || '') + (o.host ? '//' + o.host : '') + (o.pathname || '') + (o.search || '')); }, resolve: function (a, b) { return b; }, URL: G.URL, URLSearchParams: G.URLSearchParams };

  // ── path ─────────────────────────────────────────────────────────────────────
  var path = {
    sep: '/', delimiter: ':',
    join: function () { var p = Array.prototype.filter.call(arguments, function (x) { return x; }).join('/'); return _normalize(p) || '.'; },
    resolve: function () { var r = ''; for (var i = arguments.length - 1; i >= 0; i--) { if (!arguments[i]) continue; r = arguments[i] + '/' + r; if (arguments[i][0] === '/') break; } r = _normalize(r); return r[0] === '/' ? r : '/' + r; },
    normalize: function (p) { return _normalize(p) || '.'; },
    dirname: _dirname,
    basename: function (p, ext) { var b = p.replace(/\/+$/, '').split('/').pop() || ''; if (ext && b.slice(-ext.length) === ext) b = b.slice(0, -ext.length); return b; },
    extname: function (p) { var b = p.split('/').pop() || ''; var i = b.lastIndexOf('.'); return i > 0 ? b.slice(i) : ''; },
    isAbsolute: function (p) { return !!p && p[0] === '/'; },
    parse: function (p) { return { root: p[0] === '/' ? '/' : '', dir: _dirname(p), base: path.basename(p), ext: path.extname(p), name: path.basename(p, path.extname(p)) }; },
  };

  // ── http (req/res over native dispatch) ──────────────────────────────────────
  var _server = null;
  function ServerResponse(id) { EventEmitter.call(this); this._id = id; this.statusCode = 200; this.statusMessage = ''; this._headers = {}; this.headersSent = false; this.finished = false; }
  _inherits(ServerResponse, EventEmitter);
  ServerResponse.prototype.setHeader = function (k, v) { this._headers[String(k).toLowerCase()] = v; return this; };
  ServerResponse.prototype.getHeader = function (k) { return this._headers[String(k).toLowerCase()]; };
  ServerResponse.prototype.removeHeader = function (k) { delete this._headers[String(k).toLowerCase()]; };
  ServerResponse.prototype.hasHeader = function (k) { return String(k).toLowerCase() in this._headers; };
  ServerResponse.prototype.getHeaderNames = function () { return Object.keys(this._headers); };
  ServerResponse.prototype.writeHead = function (code, msg, headers) { this.statusCode = code; var h = headers || (typeof msg === 'object' ? msg : null); if (h) for (var k in h) this._headers[k.toLowerCase()] = h[k]; this.headersSent = true; return this; };
  ServerResponse.prototype.write = function (chunk) { this._body = (this._body || '') + (chunk == null ? '' : (typeof chunk === 'string' ? chunk : Buffer.isBuffer(chunk) ? chunk.toString() : String(chunk))); return true; };
  ServerResponse.prototype.end = function (chunk, enc, cb) {
    if (this.finished) return this;
    if (typeof chunk === 'function') { cb = chunk; chunk = null; }
    if (chunk != null) this.write(chunk);
    this.finished = true;
    var hs = '';
    for (var k in this._headers) { var v = this._headers[k]; if (k === 'content-length') continue; if (Array.isArray(v)) { for (var i = 0; i < v.length; i++) hs += k + ': ' + v[i] + '\r\n'; } else hs += k + ': ' + v + '\r\n'; }
    __respond(this._id, this.statusCode | 0, hs, this._body || '');
    this.emit('finish'); this.emit('close');
    if (typeof cb === 'function') cb();
    return this;
  };

  function makeReq(method, url_, headersStr) {
    var req = new Readable();
    req.method = method; req.url = url_; req.originalUrl = url_; req.httpVersion = '1.1'; req.httpVersionMajor = 1; req.httpVersionMinor = 1;
    var headers = {};
    if (headersStr) headersStr.split('\r\n').forEach(function (line) { var i = line.indexOf(':'); if (i > 0) headers[line.slice(0, i).trim().toLowerCase()] = line.slice(i + 1).trim(); });
    req.headers = headers; req.rawHeaders = [];
    req.connection = req.socket = { remoteAddress: '127.0.0.1', remotePort: 0, encrypted: false };
    req.complete = true;
    queueMicrotask(function () { req.emit('end'); });
    return req;
  }
  G.__dispatch = function (id, method, url_, headersStr) {
    var req = makeReq(method, url_, headersStr);
    var res = new ServerResponse(id);
    if (_server) _server.emit('request', req, res); else res.end('');
  };

  function Server(handler) { EventEmitter.call(this); if (handler) this.on('request', handler); _server = this; }
  _inherits(Server, EventEmitter);
  Server.prototype.listen = function () { var args = arguments, port = 0, cb = null; for (var i = 0; i < args.length; i++) { if (typeof args[i] === 'number') port = args[i]; else if (typeof args[i] === 'function') cb = args[i]; else if (typeof args[i] === 'string' && /^\d+$/.test(args[i])) port = parseInt(args[i]); } __serve(port | 0); var self = this; queueMicrotask(function () { self.emit('listening'); if (cb) cb(); }); return this; };
  Server.prototype.close = function (cb) { if (cb) queueMicrotask(cb); return this; };
  Server.prototype.address = function () { return { port: 0, address: '127.0.0.1', family: 'IPv4' }; };
  Server.prototype.on = function (t, f) { return EventEmitter.prototype.on.call(this, t, f); };

  var http = {
    createServer: function (opts, handler) { if (typeof opts === 'function') { handler = opts; } return new Server(handler); },
    Server: Server, ServerResponse: ServerResponse, IncomingMessage: Readable,
    METHODS: ['ACL', 'BIND', 'CHECKOUT', 'CONNECT', 'COPY', 'DELETE', 'GET', 'HEAD', 'LOCK', 'MERGE', 'MKACTIVITY', 'MKCOL', 'MOVE', 'NOTIFY', 'OPTIONS', 'PATCH', 'POST', 'PURGE', 'PUT', 'REPORT', 'SEARCH', 'SUBSCRIBE', 'TRACE', 'UNBIND', 'UNLOCK', 'UNSUBSCRIBE'],
    STATUS_CODES: { 200: 'OK', 201: 'Created', 204: 'No Content', 301: 'Moved Permanently', 302: 'Found', 304: 'Not Modified', 400: 'Bad Request', 401: 'Unauthorized', 403: 'Forbidden', 404: 'Not Found', 500: 'Internal Server Error' },
    globalAgent: {},
  };

  // ── stubs (loadable; functions throw only if actually used off the hot path) ──
  function _throwUnimpl(name) { return function () { throw new Error('qjs: ' + name + ' not implemented'); }; }
  var fs = {
    readFileSync: function (p, enc) { var s = __readFile(typeof p === 'string' ? p : String(p)); if (s === null) throw new Error('ENOENT: ' + p); return enc ? s : Buffer.from(s); },
    existsSync: function (p) { return __readFile(String(p)) !== null; },
    readFile: function (p, enc, cb) { if (typeof enc === 'function') { cb = enc; enc = null; } try { cb(null, fs.readFileSync(p, enc)); } catch (e) { cb(e); } },
    statSync: _throwUnimpl('fs.statSync'), stat: function (p, cb) { cb(new Error('ENOENT')); },
    writeFileSync: function () { }, writeFile: function (p, d, cb) { if (typeof cb === 'function') cb(null); },
    createReadStream: function () { return new Readable(); }, createWriteStream: function () { return new Writable(); },
    promises: {},
  };
  var crypto = {
    createHash: _throwUnimpl('crypto.createHash'), createHmac: _throwUnimpl('crypto.createHmac'),
    randomBytes: function (n) { return Buffer.alloc(n); }, randomUUID: function () { return '00000000-0000-0000-0000-000000000000'; },
  };
  var os = { platform: function () { return 'linux'; }, type: function () { return 'Linux'; }, hostname: function () { return 'qjs'; }, cpus: function () { return [{}]; }, networkInterfaces: function () { return {}; }, tmpdir: function () { return '/tmp'; }, EOL: '\n', release: function () { return '1'; }, totalmem: function () { return 0; }, freemem: function () { return 0; } };
  var net = { Socket: function () { return new Duplex(); }, createConnection: function () { return new Duplex(); }, connect: function () { return new Duplex(); }, isIP: function () { return 0; }, Server: Server };
  var events = EventEmitter; events.EventEmitter = EventEmitter; events.once = function (ee, name) { return new Promise(function (res) { ee.once(name, function () { res(Array.prototype.slice.call(arguments)); }); }); };

  // ── require ──────────────────────────────────────────────────────────────────
  var _coreFactories = {
    events: function () { return events; },
    util: function () { return util; },
    stream: function () { return Stream; },
    string_decoder: function () { return { StringDecoder: StringDecoder }; },
    buffer: function () { return { Buffer: Buffer, INSPECT_MAX_BYTES: 50, kMaxLength: 0x7fffffff }; },
    path: function () { return path; },
    querystring: function () { return querystring; },
    url: function () { return url; },
    http: function () { return http; },
    https: function () { return http; },
    net: function () { return net; },
    fs: function () { return fs; },
    crypto: function () { return crypto; },
    os: function () { return os; },
    process: function () { return process; },
    assert: function () { var a = function (v, m) { if (!v) throw new Error(m || 'assert'); }; a.ok = a; a.equal = function (x, y, m) { if (x != y) throw new Error(m || 'equal'); }; a.strictEqual = function (x, y, m) { if (x !== y) throw new Error(m || 'strictEqual'); }; a.deepEqual = a.ok; return a; },
    tty: function () { return { isatty: function () { return false; } }; },
    zlib: function () { return { createGzip: function () { return new Transform(); }, createDeflate: function () { return new Transform(); }, gzip: function (b, cb) { cb(null, b); } }; },
    timers: function () { return { setTimeout: G.setTimeout, clearTimeout: G.clearTimeout, setImmediate: G.setImmediate, setInterval: G.setInterval, clearInterval: G.clearInterval }; },
    async_hooks: function () { return { AsyncLocalStorage: function () { this.getStore = function () { }; this.run = function (s, cb) { return cb(); }; }, createHook: function () { return { enable: function () { }, disable: function () { } }; } }; },
    child_process: function () { return {}; },
    dns: function () { return { lookup: function (h, cb) { cb(null, '127.0.0.1', 4); } }; },
    // depd uses V8 CallSite stack internals quickjs lacks → shadow with a no-op deprecate.
    depd: function () { return function (ns) { function dep() { } dep.function = function (fn) { return fn; }; dep.property = function () { }; return dep; }; },
  };
  var _coreCache = {};
  var _fileCache = {};

  function _loadAsFile(p) {
    var s = __readFile(p); if (s !== null) return { path: p, src: s, json: /\.json$/.test(p) };
    s = __readFile(p + '.js'); if (s !== null) return { path: p + '.js', src: s };
    s = __readFile(p + '.json'); if (s !== null) return { path: p + '.json', src: s, json: true };
    return null;
  }
  function _loadAsDir(p) {
    var pj = __readFile(p + '/package.json');
    if (pj !== null) { try { var main = JSON.parse(pj).main; if (main) { var r = _loadAsFile(_normalize(p + '/' + main)) || _loadAsFile(_normalize(p + '/' + main + '/index')); if (r) return r; } } catch (e) { } }
    return _loadAsFile(p + '/index');
  }
  function _resolve(req, fromDir) {
    if (req[0] === '.' || req[0] === '/') { var p = _normalize(fromDir + '/' + req); return _loadAsFile(p) || _loadAsDir(p); }
    var dir = fromDir;
    while (true) { var cand = _normalize(dir + '/node_modules/' + req); var r = _loadAsFile(cand) || _loadAsDir(cand); if (r) return r; var parent = _dirname(dir); if (parent === dir || parent === '.') { var top = _loadAsFile(_normalize('node_modules/' + req)) || _loadAsDir(_normalize('node_modules/' + req)); return top; } dir = parent; }
  }
  function _makeRequire(fromDir) {
    function require(name) {
      if (name.slice(0, 5) === 'node:') name = name.slice(5);
      if (_coreFactories[name]) return _coreCache[name] || (_coreCache[name] = _coreFactories[name]());
      var r = _resolve(name, fromDir);
      if (!r) throw new Error("Cannot find module '" + name + "' from '" + fromDir + "'");
      if (_fileCache[r.path]) return _fileCache[r.path].exports;
      var module = { exports: {}, id: r.path, filename: r.path, loaded: false, paths: [] };
      _fileCache[r.path] = module;
      if (r.json) { module.exports = JSON.parse(r.src); module.loaded = true; return module.exports; }
      var dir = _dirname(r.path);
      var fn;
      try { fn = new Function('module', 'exports', 'require', '__dirname', '__filename', r.src); }
      catch (e) { throw new Error('compile ' + r.path + ': ' + e.message); }
      fn(module, module.exports, _makeRequire(dir), dir, r.path);
      module.loaded = true;
      return module.exports;
    }
    require.cache = _fileCache;
    require.resolve = function (n) { var r = _resolve(n, fromDir); return r ? r.path : n; };
    return require;
  }
  G.require = function (name) { return _makeRequire(_dirname(G.__entryPath || '.'))(name); };
})();
