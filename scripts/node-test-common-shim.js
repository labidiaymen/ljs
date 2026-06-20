'use strict';
// Stand-in for Node's test/common/index.js (spec 104/106, node-test harness).
//
// Node's real common/index.js depends on host features ljs does not fully have (internal
// bindings, flag re-spawning). When it throws on load it fails every test that
// `require('../common')` BEFORE the test's own assertions run.
//
// This shim provides enough of the `common` surface for the pure / no-I/O tests to load
// `common` and reach their assertions. Spec 106 Unit D extends it with REAL mustCall accounting
// (verified at `process.on('exit')` now that `process` is an EventEmitter) plus the helper
// surface tests across modules reference (`invalidArgTypeHelper`, `getArrayBufferViews`, flags…).
//
// Overlaid by scripts/run-node-tests.sh --shim onto vendor/node-test/common/index.js.

const noop = () => {};
const hasProcess = (typeof process !== 'undefined');

// ── platform flags ───────────────────────────────────────────────────────────
const platform = hasProcess ? process.platform : '';
const isWindows = platform === 'win32';
const isLinux = platform === 'linux';
const isMacOS = platform === 'darwin';
const isOSX = isMacOS;
const isFreeBSD = platform === 'freebsd';
const isAIX = platform === 'aix';
const isSunOS = platform === 'sunos';
const isMainThread = true;
const isDumbTerminal = hasProcess && process.env && process.env.TERM === 'dumb';
const hasCrypto = false;
const hasIntl = false;
const hasOpenSSL3 = false;
const enoughTestMem = true;

// ── mustCall accounting (real verification at process exit) ───────────────────
// Each registered expectation records a {minimum, maximum, actual, name}. At 'exit' we check every
// expectation; an unmet one prints a diagnostic and forces exit code 1 so the harness classifies
// the test as FAILED (matching Node's mustCall semantics).
const mustCallChecks = [];

function runExitChecks() {
  const failed = mustCallChecks.filter((ctx) =>
    !(ctx.actual >= ctx.minimum && ctx.actual <= ctx.maximum));
  for (const ctx of failed) {
    const expected = ctx.maximum === Infinity ? 'at least ' + ctx.minimum :
      (ctx.minimum === ctx.maximum ? 'exactly ' + ctx.minimum :
        ctx.minimum + '..' + ctx.maximum);
    console.error('Mismatched ' + ctx.name + ' function calls. Expected ' +
                  expected + ', actual ' + ctx.actual + '.');
  }
  if (failed.length > 0 && hasProcess) process.exit(1);
}

let exitHandlerRegistered = false;
function registerExitHandler() {
  if (exitHandlerRegistered) return;
  exitHandlerRegistered = true;
  if (hasProcess && typeof process.on === 'function') {
    process.on('exit', runExitChecks);
  }
}

// _mustCallInner(fn, criteria, field) — criteria is a number. field 'exact' or 'min'.
function _mustCallInner(fn, criteria, field) {
  if (typeof fn === 'number') { criteria = fn; fn = noop; }
  else if (fn === undefined) fn = noop;
  if (criteria === undefined) criteria = 1;
  if (typeof criteria !== 'number') {
    throw new TypeError('Invalid ' + field + ' value: ' + criteria);
  }
  registerExitHandler();
  const ctx = {
    minimum: criteria,
    maximum: field === 'min' ? Infinity : criteria,
    actual: 0,
    name: fn.name || '<anonymous>',
  };
  mustCallChecks.push(ctx);
  return function(...args) {
    ctx.actual++;
    return fn.apply(this, args);
  };
}

function mustCall(fn, exact) { return _mustCallInner(fn, exact, 'exact'); }
function mustCallAtLeast(fn, minimum) { return _mustCallInner(fn, minimum, 'min'); }

function mustSucceed(fn, exact) {
  return mustCall(function(err, ...args) {
    if (err) throw err;
    if (typeof fn === 'function') return fn.apply(this, args);
  }, exact);
}

// mustNotCall(msg?) — a function that fails (and forces exit 1) if ever invoked.
function mustNotCall(msg) {
  const stack = new Error().stack;
  return function(...args) {
    const argsInfo = args.length > 0 ?
      '\ncalled with arguments: ' + args.map(String).join(', ') : '';
    const message = (msg || 'function should not have been called') +
      ' at unexpected location' + argsInfo + '\n' + stack;
    console.error(message);
    if (hasProcess) process.exit(1);
    throw new Error(message);
  };
}

const mustCallAsync = mustCall;

// ── invalidArgTypeHelper — mirrors lib/internal/errors.js ─────────────────────
// Returns the ` Received ...` suffix Node appends to ERR_INVALID_ARG_TYPE messages.
function invalidArgTypeHelper(input) {
  if (input == null) {
    return ' Received ' + input;
  }
  if (typeof input === 'function' && input.name) {
    return ' Received function ' + input.name;
  }
  if (typeof input === 'object') {
    if (input.constructor && input.constructor.name) {
      return ' Received an instance of ' + input.constructor.name;
    }
    return ' Received ' + inspectForHelper(input);
  }
  let inspected = inspectForHelper(input);
  if (inspected.length > 28) { inspected = inspected.slice(0, 25) + '...'; }
  return ' Received type ' + (typeof input) + ' (' + inspected + ')';
}

// Best-effort inspect for the helper above (util.inspect may be unavailable under the shim).
function inspectForHelper(value) {
  try {
    const util = require('util');
    if (util && typeof util.inspect === 'function') return util.inspect(value);
  } catch {
    // fall through to a manual rendering
  }
  if (typeof value === 'string') return "'" + value + "'";
  if (typeof value === 'bigint') return value + 'n';
  return String(value);
}

// ── expectsError / expectWarning ──────────────────────────────────────────────
function expectsError(validator, exact) {
  return mustCall((err) => {
    if (typeof validator === 'function') {
      if (validator.prototype !== undefined && err instanceof validator) return true;
      return validator(err);
    }
    if (validator && typeof validator === 'object') {
      for (const key of Object.keys(validator)) {
        const expected = validator[key];
        const actual = err[key];
        if (expected instanceof RegExp) {
          if (!expected.test(String(actual))) {
            throw new Error('expectsError: ' + key + ' ' + actual + ' does not match ' + expected);
          }
        } else if (actual !== expected && String(actual) !== String(expected)) {
          throw new Error('expectsError: mismatch on ' + key + ': ' + actual + ' !== ' + expected);
        }
      }
    }
    return true;
  }, exact);
}

function expectWarning() {}

// ── getArrayBufferViews — every TypedArray/DataView view over `buf` ───────────
function getArrayBufferViews(buf) {
  const { buffer, byteOffset, byteLength } = buf;
  const out = [];
  const ctors = [
    Uint8Array, Uint8ClampedArray, Int8Array,
    Uint16Array, Int16Array,
    Uint32Array, Int32Array,
    Float32Array, Float64Array,
    DataView,
  ];
  for (const Ctor of ctors) {
    if (typeof Ctor !== 'function') continue;
    const bpe = Ctor.BYTES_PER_ELEMENT || 1;
    if (byteLength % bpe === 0) {
      try { out.push(new Ctor(buffer, byteOffset, byteLength / bpe)); } catch {
        // Ctor may reject these args (e.g. an alignment constraint) — skip it.
      }
    }
  }
  return out;
}

function allowGlobals() {}
function platformTimeout(ms) { return ms; }
function skipIfWorker() {}

const tmpdir = {
  path: (hasProcess && process.env && process.env.TMPDIR) || (isWindows ? 'C:/tmp' : '/tmp'),
  refresh: noop,
  resolve(...args) { return [this.path].concat(args).join('/'); },
};

const common = {
  mustCall,
  mustCallAtLeast,
  mustCallAsync,
  mustSucceed,
  mustNotCall,
  invalidArgTypeHelper,
  expectsError,
  expectWarning,
  getArrayBufferViews,
  allowGlobals,
  platformTimeout,
  skipIfWorker,
  tmpdir,
  isWindows,
  isLinux,
  isMacOS,
  isOSX,
  isFreeBSD,
  isAIX,
  isSunOS,
  isMainThread,
  isDumbTerminal,
  hasCrypto,
  hasIntl,
  hasOpenSSL3,
  enoughTestMem,
  skip(msg) { console.log('# SKIP', msg || ''); if (hasProcess) process.exit(0); },
  printSkipMessage(msg) { console.log('# SKIP', msg || ''); },
};

module.exports = common;
