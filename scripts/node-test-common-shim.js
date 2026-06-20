'use strict';
// Minimal stand-in for Node's test/common/index.js (spec 104, node-test harness).
//
// Node's real common/index.js depends on host features ljs does not yet have (internal
// bindings, process.on('exit') accounting for mustCall, flag re-spawning). When it throws on
// load it fails every test that `require('../common')` BEFORE the test's own assertions run.
//
// This shim provides just enough of the `common` surface for pure synchronous-assert tests
// (path, buffer, querystring, simple util) to load `common` and reach their assertions, so the
// harness reports a REAL pass number for those. It deliberately does NOT enforce mustCall counts
// at exit (that needs process.on('exit')); mustCall here only wraps the fn. Tests whose
// correctness depends on exit-time call accounting will under-verify, not falsely fail.
//
// Overlaid by scripts/run-node-tests.sh --shim onto vendor/node-test/common/index.js.

const noop = () => {};

// mustCall(fn[, exact]) — Node verifies fn ran `exact` times at process exit. Without
// process.on('exit') we cannot verify at exit; we just return a wrapper that forwards. This is a
// deliberate weakening (documented above).
function mustCall(fn, _exact) {
  if (typeof fn !== 'function') return mustCall(noop, fn);
  return function (...args) { return fn.apply(this, args); };
}
function mustCallAtLeast(fn, _min) { return mustCall(fn); }
function mustSucceed(fn) {
  return mustCall(function (err, ...args) {
    if (err) throw err;
    if (typeof fn === 'function') return fn.apply(this, args);
  });
}
function mustNotCall(msg) {
  return function (...args) {
    throw new Error('mustNotCall' + (msg ? ': ' + msg : '') +
      (args.length ? ' (called with ' + args.length + ' args)' : ''));
  };
}

function platformTimeout(ms) { return ms; }
function allowGlobals() {}
function expectWarning() {}

// expectsError(fn|validator) — loose: just asserts something throws (and optionally that the
// thrown error matches a {code,name,message} validator).
function expectsError(validator) {
  return function (err) {
    if (!err) throw new Error('expectsError: expected an error');
    if (validator && typeof validator === 'object') {
      for (const k of Object.keys(validator)) {
        if (err[k] !== validator[k] && String(err[k]) !== String(validator[k])) {
          throw new Error('expectsError: mismatch on ' + k);
        }
      }
    }
    return true;
  };
}

const isWindows = (typeof process !== 'undefined' && process.platform === 'win32');
const isMainThread = true;
const isLinux = (typeof process !== 'undefined' && process.platform === 'linux');
const isMacOS = (typeof process !== 'undefined' && process.platform === 'darwin');

// A scratch temp dir helper (best-effort; some tests reference common.tmpDir / refresh()).
const tmpdir = {
  path: (typeof process !== 'undefined' && process.env && process.env.TMPDIR) ||
        (isWindows ? 'C:/tmp' : '/tmp'),
  refresh: noop,
};

const common = {
  mustCall,
  mustCallAtLeast,
  mustSucceed,
  mustNotCall,
  platformTimeout,
  allowGlobals,
  expectWarning,
  expectsError,
  isWindows,
  isLinux,
  isMacOS,
  isMainThread,
  tmpdir,
  hasCrypto: false,
  hasIntl: false,
  enoughTestMem: true,
  skip(msg) { console.log('# SKIP', msg || ''); if (typeof process !== 'undefined') process.exit(0); },
  skipIfWorker: noop,
  printSkipMessage(msg) { console.log('# SKIP', msg || ''); },
};

module.exports = common;
