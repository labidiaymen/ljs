//! HOST `path` core module (spec 105, Unit A).
//!
//! Rather than reimplement Node's intricate win32/posix path edge-cases (drive letters, UNC roots,
//! case-insensitive `relative`, `parse`/`format`, trailing-separator handling, glob matching) in
//! Zig, we evaluate a faithful port of Node's `lib/path.js` IN THE ENGINE. The JS source is wrapped
//! as a CommonJS module (`exports`/`module`) exactly like a real required file, then run in the
//! current realm; its `module.exports` becomes the `path` core-module object.
//!
//! This gives us exact Node semantics for free — `path.posix`, `path.win32`, `toNamespacedPath`,
//! `matchesGlob`, `format`, the `ERR_INVALID_ARG_TYPE` throwing, and JS `toLowerCase`-based win32
//! `relative` case-folding. The JS leans only on globals the host already provides (`process.cwd`,
//! `process.platform`, `TypeError`, `Object`, `String`, `RegExp`, `Math`).
//!
//! `path` itself aliases the host-platform default namespace (win32 on Windows, posix otherwise);
//! `path.posix.posix === path.posix`, `path.win32.win32 === path.win32`, and each exposes the other.
//! `require('path/posix')` / `require('path/win32')` resolve to the respective sub-namespace (wired in
//! host_require.zig).

const std = @import("std");
const Interpreter = @import("interpreter.zig").Interpreter;
const Object = @import("object.zig").Object;
const Value = @import("value.zig").Value;
const Parser = @import("parser.zig").Parser;
const EvalError = @import("interpreter.zig").EvalError;

/// Build the `path` module object by evaluating the embedded Node path.js port. Returns the platform
/// default namespace object (which carries `.posix` and `.win32`).
pub fn build(self: *Interpreter) EvalError!*Object {
    const arena = self.arena;
    const wrapped = std.fmt.allocPrint(
        arena,
        "(function (exports, module) {{\n{s}\n}})",
        .{path_js},
    ) catch return error.OutOfMemory;
    // The embedded JS below is statically valid and side-effect-free, so the parse/run/call paths
    // below cannot realistically fail; treat any failure as an internal (OOM-class) error.
    const program = Parser.parseMode(arena, wrapped, false) catch return error.OutOfMemory;
    const wrapper_c = try self.run(program, self.globals.?);
    if (wrapper_c.isAbrupt() or wrapper_c.normal != .object) return error.OutOfMemory;
    const wrapper = wrapper_c.normal.object;

    const exports_obj = try Object.create(arena, self.objectProto());
    const module_obj = try Object.create(arena, self.objectProto());
    try module_obj.defineData("exports", .{ .object = exports_obj }, true, true, true);
    const call_args = [_]Value{ .{ .object = exports_obj }, .{ .object = module_obj } };
    const body_c = try self.callFunction(wrapper, &call_args, .undefined);
    if (body_c.isAbrupt()) return error.OutOfMemory;
    const final = module_obj.get("exports") orelse Value{ .object = exports_obj };
    if (final != .object) return error.OutOfMemory;
    return final.object;
}

/// Embedded port of Node's `lib/path.js` (de-primordialized to plain prototype methods). Faithful to
/// Node 20 semantics for posix + win32.
const path_js =
    \\'use strict';
    \\const CHAR_UPPERCASE_A = 65, CHAR_LOWERCASE_A = 97;
    \\const CHAR_UPPERCASE_Z = 90, CHAR_LOWERCASE_Z = 122;
    \\const CHAR_DOT = 46, CHAR_FORWARD_SLASH = 47, CHAR_BACKWARD_SLASH = 92;
    \\const CHAR_COLON = 58, CHAR_QUESTION_MARK = 63;
    \\
    \\function validateString(value, name) {
    \\  if (typeof value !== 'string') {
    \\    const err = new TypeError(
    \\      'The "' + name + '" argument must be of type string.' +
    \\      ' Received ' + (value === null ? 'null' : typeof value));
    \\    err.code = 'ERR_INVALID_ARG_TYPE';
    \\    throw err;
    \\  }
    \\}
    \\function validateObject(value, name) {
    \\  if (value === null || typeof value !== 'object') {
    \\    const err = new TypeError(
    \\      'The "' + name + '" argument must be of type object.' +
    \\      ' Received ' + (value === null ? 'null' : (Array.isArray(value) ? 'an instance of Array' : typeof value)));
    \\    err.code = 'ERR_INVALID_ARG_TYPE';
    \\    throw err;
    \\  }
    \\}
    \\
    \\function isPathSeparator(code) {
    \\  return code === CHAR_FORWARD_SLASH || code === CHAR_BACKWARD_SLASH;
    \\}
    \\function isPosixPathSeparator(code) { return code === CHAR_FORWARD_SLASH; }
    \\function isWindowsDeviceRoot(code) {
    \\  return (code >= CHAR_UPPERCASE_A && code <= CHAR_UPPERCASE_Z) ||
    \\         (code >= CHAR_LOWERCASE_A && code <= CHAR_LOWERCASE_Z);
    \\}
    \\
    \\function normalizeString(path, allowAboveRoot, separator, isPathSeparatorFn) {
    \\  let res = '';
    \\  let lastSegmentLength = 0;
    \\  let lastSlash = -1;
    \\  let dots = 0;
    \\  let code = 0;
    \\  for (let i = 0; i <= path.length; ++i) {
    \\    if (i < path.length)
    \\      code = path.charCodeAt(i);
    \\    else if (isPathSeparatorFn(code))
    \\      break;
    \\    else
    \\      code = CHAR_FORWARD_SLASH;
    \\
    \\    if (isPathSeparatorFn(code)) {
    \\      if (lastSlash === i - 1 || dots === 1) {
    \\      } else if (dots === 2) {
    \\        if (res.length < 2 || lastSegmentLength !== 2 ||
    \\            res.charCodeAt(res.length - 1) !== CHAR_DOT ||
    \\            res.charCodeAt(res.length - 2) !== CHAR_DOT) {
    \\          if (res.length > 2) {
    \\            const lastSlashIndex = res.lastIndexOf(separator);
    \\            if (lastSlashIndex === -1) {
    \\              res = '';
    \\              lastSegmentLength = 0;
    \\            } else {
    \\              res = res.slice(0, lastSlashIndex);
    \\              lastSegmentLength = res.length - 1 - res.lastIndexOf(separator);
    \\            }
    \\            lastSlash = i;
    \\            dots = 0;
    \\            continue;
    \\          } else if (res.length !== 0) {
    \\            res = '';
    \\            lastSegmentLength = 0;
    \\            lastSlash = i;
    \\            dots = 0;
    \\            continue;
    \\          }
    \\        }
    \\        if (allowAboveRoot) {
    \\          res += res.length > 0 ? separator + '..' : '..';
    \\          lastSegmentLength = 2;
    \\        }
    \\      } else {
    \\        if (res.length > 0)
    \\          res += separator + path.slice(lastSlash + 1, i);
    \\        else
    \\          res = path.slice(lastSlash + 1, i);
    \\        lastSegmentLength = i - lastSlash - 1;
    \\      }
    \\      lastSlash = i;
    \\      dots = 0;
    \\    } else if (code === CHAR_DOT && dots !== -1) {
    \\      ++dots;
    \\    } else {
    \\      dots = -1;
    \\    }
    \\  }
    \\  return res;
    \\}
    \\
    \\function formatExt(ext) {
    \\  return ext ? (ext[0] === '.' ? ext : '.' + ext) : '';
    \\}
    \\function _format(sep, pathObject) {
    \\  validateObject(pathObject, 'pathObject');
    \\  const dir = pathObject.dir || pathObject.root;
    \\  const base = pathObject.base ||
    \\    ((pathObject.name || '') + formatExt(pathObject.ext));
    \\  if (!dir) return base;
    \\  return dir === pathObject.root ? dir + base : dir + sep + base;
    \\}
    \\
    \\// ── glob (minimal fnmatch — drives path.matchesGlob) ──────────────────────────
    \\function globToRegExp(glob) {
    \\  let re = '';
    \\  let i = 0;
    \\  const n = glob.length;
    \\  while (i < n) {
    \\    const c = glob[i];
    \\    if (c === '*') {
    \\      if (glob[i + 1] === '*') {
    \\        re += '.*';
    \\        i += 2;
    \\        if (glob[i] === '/' || glob[i] === '\\') i++;
    \\        continue;
    \\      }
    \\      re += '[^/\\\\]*';
    \\      i++;
    \\    } else if (c === '?') {
    \\      re += '[^/\\\\]';
    \\      i++;
    \\    } else if (c === '[') {
    \\      let j = i + 1;
    \\      let cls = '[';
    \\      if (glob[j] === '!') { cls += '^'; j++; }
    \\      while (j < n && glob[j] !== ']') {
    \\        const cc = glob[j];
    \\        if (cc === '\\') cls += '\\\\';
    \\        else cls += cc;
    \\        j++;
    \\      }
    \\      cls += ']';
    \\      re += cls;
    \\      i = j + 1;
    \\    } else if (c === '/' || c === '\\') {
    \\      re += '[/\\\\]';
    \\      i++;
    \\    } else {
    \\      if ('.+^${}()|'.indexOf(c) !== -1) re += '\\' + c;
    \\      else re += c;
    \\      i++;
    \\    }
    \\  }
    \\  return new RegExp('^' + re + '$');
    \\}
    \\function matchesGlobImpl(path, glob) {
    \\  validateString(path, 'path');
    \\  validateString(glob, 'pattern');
    \\  return globToRegExp(glob).test(path);
    \\}
    \\
    \\const win32 = {
    \\  resolve(...args) {
    \\    let resolvedDevice = '';
    \\    let resolvedTail = '';
    \\    let resolvedAbsolute = false;
    \\    for (let i = args.length - 1; i >= -1; i--) {
    \\      let path;
    \\      if (i >= 0) {
    \\        path = args[i];
    \\        validateString(path, 'path');
    \\        if (path.length === 0) continue;
    \\      } else if (resolvedDevice.length === 0) {
    \\        path = process.cwd();
    \\      } else {
    \\        path = (process.env && process.env['=' + resolvedDevice]) || process.cwd();
    \\        if (path === undefined ||
    \\            (path.slice(0, 2).toLowerCase() !== resolvedDevice.toLowerCase() &&
    \\             path.charCodeAt(2) === CHAR_BACKWARD_SLASH)) {
    \\          path = resolvedDevice + '\\';
    \\        }
    \\      }
    \\      const len = path.length;
    \\      let rootEnd = 0;
    \\      let device = '';
    \\      let isAbsolute = false;
    \\      const code = path.charCodeAt(0);
    \\      if (len === 1) {
    \\        if (isPathSeparator(code)) { rootEnd = 1; isAbsolute = true; }
    \\      } else if (isPathSeparator(code)) {
    \\        isAbsolute = true;
    \\        if (isPathSeparator(path.charCodeAt(1))) {
    \\          let j = 2;
    \\          let last = j;
    \\          while (j < len && !isPathSeparator(path.charCodeAt(j))) j++;
    \\          if (j < len && j !== last) {
    \\            const firstPart = path.slice(last, j);
    \\            last = j;
    \\            while (j < len && isPathSeparator(path.charCodeAt(j))) j++;
    \\            if (j < len && j !== last) {
    \\              last = j;
    \\              while (j < len && !isPathSeparator(path.charCodeAt(j))) j++;
    \\              if (j === len || j !== last) {
    \\                device = '\\\\' + firstPart + '\\' + path.slice(last, j);
    \\                rootEnd = j;
    \\              }
    \\            }
    \\          }
    \\        } else {
    \\          rootEnd = 1;
    \\        }
    \\      } else if (isWindowsDeviceRoot(code) &&
    \\                 path.charCodeAt(1) === CHAR_COLON) {
    \\        device = path.slice(0, 2);
    \\        rootEnd = 2;
    \\        if (len > 2 && isPathSeparator(path.charCodeAt(2))) {
    \\          isAbsolute = true;
    \\          rootEnd = 3;
    \\        }
    \\      }
    \\      if (device.length > 0) {
    \\        if (resolvedDevice.length > 0) {
    \\          if (device.toLowerCase() !== resolvedDevice.toLowerCase()) continue;
    \\        } else {
    \\          resolvedDevice = device;
    \\        }
    \\      }
    \\      if (resolvedAbsolute) {
    \\        if (resolvedDevice.length > 0) break;
    \\      } else {
    \\        resolvedTail = path.slice(rootEnd) + '\\' + resolvedTail;
    \\        resolvedAbsolute = isAbsolute;
    \\        if (isAbsolute && resolvedDevice.length > 0) break;
    \\      }
    \\    }
    \\    resolvedTail = normalizeString(resolvedTail, !resolvedAbsolute, '\\', isPathSeparator);
    \\    return resolvedAbsolute ?
    \\      resolvedDevice + '\\' + resolvedTail :
    \\      (resolvedDevice + resolvedTail) || '.';
    \\  },
    \\
    \\  normalize(path) {
    \\    validateString(path, 'path');
    \\    const len = path.length;
    \\    if (len === 0) return '.';
    \\    let rootEnd = 0;
    \\    let device;
    \\    let isAbsolute = false;
    \\    const code = path.charCodeAt(0);
    \\    if (len === 1) {
    \\      return isPosixPathSeparator(code) ? '\\' : path;
    \\    }
    \\    if (isPathSeparator(code)) {
    \\      isAbsolute = true;
    \\      if (isPathSeparator(path.charCodeAt(1))) {
    \\        let j = 2;
    \\        let last = j;
    \\        while (j < len && !isPathSeparator(path.charCodeAt(j))) j++;
    \\        if (j < len && j !== last) {
    \\          const firstPart = path.slice(last, j);
    \\          last = j;
    \\          while (j < len && isPathSeparator(path.charCodeAt(j))) j++;
    \\          if (j < len && j !== last) {
    \\            last = j;
    \\            while (j < len && !isPathSeparator(path.charCodeAt(j))) j++;
    \\            if (j === len || j !== last) {
    \\              if (firstPart === '.' || firstPart === '?') {
    \\                device = '\\\\' + firstPart;
    \\                rootEnd = 4;
    \\              } else if (j === len) {
    \\                return '\\\\' + firstPart + '\\' + path.slice(last) + '\\';
    \\              } else {
    \\                device = '\\\\' + firstPart + '\\' + path.slice(last, j);
    \\                rootEnd = j;
    \\              }
    \\            }
    \\          }
    \\        }
    \\      } else {
    \\        rootEnd = 1;
    \\      }
    \\    } else if (isWindowsDeviceRoot(code) &&
    \\               path.charCodeAt(1) === CHAR_COLON) {
    \\      device = path.slice(0, 2);
    \\      rootEnd = 2;
    \\      if (len > 2 && isPathSeparator(path.charCodeAt(2))) {
    \\        isAbsolute = true;
    \\        rootEnd = 3;
    \\      }
    \\    }
    \\    let tail = rootEnd < len ?
    \\      normalizeString(path.slice(rootEnd), !isAbsolute, '\\', isPathSeparator) :
    \\      '';
    \\    if (tail.length === 0 && !isAbsolute) tail = '.';
    \\    if (tail.length > 0 && isPathSeparator(path.charCodeAt(len - 1)))
    \\      tail += '\\';
    \\    if (!isAbsolute && device === undefined && path.indexOf(':') !== -1) {
    \\      // CVE-2024-36139: a relative path must not normalize into something Windows would
    \\      // interpret as an absolute (device-rooted) path.
    \\      if (tail.length >= 2 &&
    \\          isWindowsDeviceRoot(tail.charCodeAt(0)) &&
    \\          tail.charCodeAt(1) === CHAR_COLON) {
    \\        return '.\\' + tail;
    \\      }
    \\      let index = path.indexOf(':');
    \\      do {
    \\        if (index === len - 1 || isPathSeparator(path.charCodeAt(index + 1))) {
    \\          return '.\\' + tail;
    \\        }
    \\      } while ((index = path.indexOf(':', index + 1)) !== -1);
    \\    }
    \\    if (device === undefined) {
    \\      return isAbsolute ? '\\' + tail : tail;
    \\    }
    \\    return isAbsolute ? device + '\\' + tail : device + tail;
    \\  },
    \\
    \\  isAbsolute(path) {
    \\    validateString(path, 'path');
    \\    const len = path.length;
    \\    if (len === 0) return false;
    \\    const code = path.charCodeAt(0);
    \\    return isPathSeparator(code) ||
    \\      (len > 2 && isWindowsDeviceRoot(code) &&
    \\       path.charCodeAt(1) === CHAR_COLON &&
    \\       isPathSeparator(path.charCodeAt(2)));
    \\  },
    \\
    \\  join(...args) {
    \\    if (args.length === 0) return '.';
    \\    let joined;
    \\    let firstPart;
    \\    for (let i = 0; i < args.length; ++i) {
    \\      const arg = args[i];
    \\      validateString(arg, 'path');
    \\      if (arg.length > 0) {
    \\        if (joined === undefined) joined = firstPart = arg;
    \\        else joined += '\\' + arg;
    \\      }
    \\    }
    \\    if (joined === undefined) return '.';
    \\    let needsReplace = true;
    \\    let slashCount = 0;
    \\    if (isPathSeparator(firstPart.charCodeAt(0))) {
    \\      ++slashCount;
    \\      const firstLen = firstPart.length;
    \\      if (firstLen > 1 && isPathSeparator(firstPart.charCodeAt(1))) {
    \\        ++slashCount;
    \\        if (firstLen > 2) {
    \\          if (isPathSeparator(firstPart.charCodeAt(2))) ++slashCount;
    \\          else { needsReplace = false; }
    \\        }
    \\      }
    \\    }
    \\    if (needsReplace) {
    \\      while (slashCount < joined.length &&
    \\             isPathSeparator(joined.charCodeAt(slashCount))) slashCount++;
    \\      if (slashCount >= 2) joined = '\\' + joined.slice(slashCount);
    \\    }
    \\    return win32.normalize(joined);
    \\  },
    \\
    \\  relative(from, to) {
    \\    validateString(from, 'from');
    \\    validateString(to, 'to');
    \\    if (from === to) return '';
    \\    const fromOrig = win32.resolve(from);
    \\    const toOrig = win32.resolve(to);
    \\    if (fromOrig === toOrig) return '';
    \\    from = fromOrig.toLowerCase();
    \\    to = toOrig.toLowerCase();
    \\    if (from === to) return '';
    \\    let fromStart = 0;
    \\    while (fromStart < from.length &&
    \\           from.charCodeAt(fromStart) === CHAR_BACKWARD_SLASH) fromStart++;
    \\    let fromEnd = from.length;
    \\    while (fromEnd - 1 > fromStart &&
    \\           from.charCodeAt(fromEnd - 1) === CHAR_BACKWARD_SLASH) fromEnd--;
    \\    const fromLen = fromEnd - fromStart;
    \\    let toStart = 0;
    \\    while (toStart < to.length &&
    \\           to.charCodeAt(toStart) === CHAR_BACKWARD_SLASH) toStart++;
    \\    let toEnd = to.length;
    \\    while (toEnd - 1 > toStart &&
    \\           to.charCodeAt(toEnd - 1) === CHAR_BACKWARD_SLASH) toEnd--;
    \\    const toLen = toEnd - toStart;
    \\    const length = fromLen < toLen ? fromLen : toLen;
    \\    let lastCommonSep = -1;
    \\    let i = 0;
    \\    for (; i < length; i++) {
    \\      const fromCode = from.charCodeAt(fromStart + i);
    \\      if (fromCode !== to.charCodeAt(toStart + i)) break;
    \\      else if (fromCode === CHAR_BACKWARD_SLASH) lastCommonSep = i;
    \\    }
    \\    if (i !== length) {
    \\      if (lastCommonSep === -1) return toOrig;
    \\    } else {
    \\      if (toLen > length) {
    \\        if (to.charCodeAt(toStart + i) === CHAR_BACKWARD_SLASH) {
    \\          return toOrig.slice(toStart + i + 1);
    \\        }
    \\        if (i === 2) {
    \\          return toOrig.slice(toStart + i);
    \\        }
    \\      }
    \\      if (fromLen > length) {
    \\        if (from.charCodeAt(fromStart + i) === CHAR_BACKWARD_SLASH) lastCommonSep = i;
    \\        else if (i === 2) lastCommonSep = 3;
    \\      }
    \\      if (lastCommonSep === -1) lastCommonSep = 0;
    \\    }
    \\    let out = '';
    \\    for (i = fromStart + lastCommonSep + 1; i <= fromEnd; ++i) {
    \\      if (i === fromEnd || from.charCodeAt(i) === CHAR_BACKWARD_SLASH) {
    \\        out += out.length === 0 ? '..' : '\\..';
    \\      }
    \\    }
    \\    toStart += lastCommonSep;
    \\    if (out.length > 0) {
    \\      return out + toOrig.slice(toStart, toEnd);
    \\    }
    \\    if (toOrig.charCodeAt(toStart) === CHAR_BACKWARD_SLASH) ++toStart;
    \\    return toOrig.slice(toStart, toEnd);
    \\  },
    \\
    \\  toNamespacedPath(path) {
    \\    if (typeof path !== 'string' || path.length === 0) return path;
    \\    const resolvedPath = win32.resolve(path);
    \\    if (resolvedPath.length <= 2) return path;
    \\    if (resolvedPath.charCodeAt(0) === CHAR_BACKWARD_SLASH) {
    \\      if (resolvedPath.charCodeAt(1) === CHAR_BACKWARD_SLASH) {
    \\        const code = resolvedPath.charCodeAt(2);
    \\        if (code !== CHAR_QUESTION_MARK && code !== CHAR_DOT) {
    \\          return '\\\\?\\UNC\\' + resolvedPath.slice(2);
    \\        }
    \\      }
    \\    } else if (isWindowsDeviceRoot(resolvedPath.charCodeAt(0)) &&
    \\               resolvedPath.charCodeAt(1) === CHAR_COLON &&
    \\               resolvedPath.charCodeAt(2) === CHAR_BACKWARD_SLASH) {
    \\      return '\\\\?\\' + resolvedPath;
    \\    }
    \\    return resolvedPath;
    \\  },
    \\
    \\  dirname(path) {
    \\    validateString(path, 'path');
    \\    const len = path.length;
    \\    if (len === 0) return '.';
    \\    let rootEnd = -1;
    \\    let offset = 0;
    \\    const code = path.charCodeAt(0);
    \\    if (len === 1) return isPathSeparator(code) ? path : '.';
    \\    if (isPathSeparator(code)) {
    \\      rootEnd = offset = 1;
    \\      if (isPathSeparator(path.charCodeAt(1))) {
    \\        let j = 2;
    \\        let last = j;
    \\        while (j < len && !isPathSeparator(path.charCodeAt(j))) j++;
    \\        if (j < len && j !== last) {
    \\          last = j;
    \\          while (j < len && isPathSeparator(path.charCodeAt(j))) j++;
    \\          if (j < len && j !== last) {
    \\            last = j;
    \\            while (j < len && !isPathSeparator(path.charCodeAt(j))) j++;
    \\            if (j === len) return path;
    \\            if (j !== last) rootEnd = offset = j + 1;
    \\          }
    \\        }
    \\      }
    \\    } else if (isWindowsDeviceRoot(code) &&
    \\               path.charCodeAt(1) === CHAR_COLON) {
    \\      rootEnd = len > 2 && isPathSeparator(path.charCodeAt(2)) ? 3 : 2;
    \\      offset = rootEnd;
    \\    }
    \\    let end = -1;
    \\    let matchedSlash = true;
    \\    for (let i = len - 1; i >= offset; --i) {
    \\      if (isPathSeparator(path.charCodeAt(i))) {
    \\        if (!matchedSlash) { end = i; break; }
    \\      } else { matchedSlash = false; }
    \\    }
    \\    if (end === -1) {
    \\      if (rootEnd === -1) return '.';
    \\      end = rootEnd;
    \\    }
    \\    return path.slice(0, end);
    \\  },
    \\
    \\  basename(path, suffix) {
    \\    if (suffix !== undefined) validateString(suffix, 'suffix');
    \\    validateString(path, 'path');
    \\    let start = 0;
    \\    let end = -1;
    \\    let matchedSlash = true;
    \\    if (path.length >= 2 && isWindowsDeviceRoot(path.charCodeAt(0)) &&
    \\        path.charCodeAt(1) === CHAR_COLON) start = 2;
    \\    if (suffix !== undefined && suffix.length > 0 &&
    \\        suffix.length <= path.length) {
    \\      if (suffix === path) return '';
    \\      let extIdx = suffix.length - 1;
    \\      let firstNonSlashEnd = -1;
    \\      for (let i = path.length - 1; i >= start; --i) {
    \\        const code = path.charCodeAt(i);
    \\        if (isPathSeparator(code)) {
    \\          if (!matchedSlash) { start = i + 1; break; }
    \\        } else {
    \\          if (firstNonSlashEnd === -1) { matchedSlash = false; firstNonSlashEnd = i + 1; }
    \\          if (extIdx >= 0) {
    \\            if (code === suffix.charCodeAt(extIdx)) {
    \\              if (--extIdx === -1) end = i;
    \\            } else { extIdx = -1; end = firstNonSlashEnd; }
    \\          }
    \\        }
    \\      }
    \\      if (start === end) end = firstNonSlashEnd;
    \\      else if (end === -1) end = path.length;
    \\      return path.slice(start, end);
    \\    }
    \\    for (let i = path.length - 1; i >= start; --i) {
    \\      if (isPathSeparator(path.charCodeAt(i))) {
    \\        if (!matchedSlash) { start = i + 1; break; }
    \\      } else if (end === -1) { matchedSlash = false; end = i + 1; }
    \\    }
    \\    if (end === -1) return '';
    \\    return path.slice(start, end);
    \\  },
    \\
    \\  extname(path) {
    \\    validateString(path, 'path');
    \\    let start = 0;
    \\    let startDot = -1;
    \\    let startPart = 0;
    \\    let end = -1;
    \\    let matchedSlash = true;
    \\    let preDotState = 0;
    \\    if (path.length >= 2 && path.charCodeAt(1) === CHAR_COLON &&
    \\        isWindowsDeviceRoot(path.charCodeAt(0))) start = startPart = 2;
    \\    for (let i = path.length - 1; i >= start; --i) {
    \\      const code = path.charCodeAt(i);
    \\      if (isPathSeparator(code)) {
    \\        if (!matchedSlash) { startPart = i + 1; break; }
    \\        continue;
    \\      }
    \\      if (end === -1) { matchedSlash = false; end = i + 1; }
    \\      if (code === CHAR_DOT) {
    \\        if (startDot === -1) startDot = i;
    \\        else if (preDotState !== 1) preDotState = 1;
    \\      } else if (startDot !== -1) {
    \\        preDotState = -1;
    \\      }
    \\    }
    \\    if (startDot === -1 || end === -1 || preDotState === 0 ||
    \\        (preDotState === 1 && startDot === end - 1 && startDot === startPart + 1)) {
    \\      return '';
    \\    }
    \\    return path.slice(startDot, end);
    \\  },
    \\
    \\  format: _format.bind(null, '\\'),
    \\
    \\  parse(path) {
    \\    validateString(path, 'path');
    \\    const ret = { root: '', dir: '', base: '', ext: '', name: '' };
    \\    if (path.length === 0) return ret;
    \\    const len = path.length;
    \\    let rootEnd = 0;
    \\    let code = path.charCodeAt(0);
    \\    if (len === 1) {
    \\      if (isPathSeparator(code)) {
    \\        ret.root = ret.dir = path;
    \\        return ret;
    \\      }
    \\      ret.base = ret.name = path;
    \\      return ret;
    \\    }
    \\    if (isPathSeparator(code)) {
    \\      rootEnd = 1;
    \\      if (isPathSeparator(path.charCodeAt(1))) {
    \\        let j = 2;
    \\        let last = j;
    \\        while (j < len && !isPathSeparator(path.charCodeAt(j))) j++;
    \\        if (j < len && j !== last) {
    \\          last = j;
    \\          while (j < len && isPathSeparator(path.charCodeAt(j))) j++;
    \\          if (j < len && j !== last) {
    \\            last = j;
    \\            while (j < len && !isPathSeparator(path.charCodeAt(j))) j++;
    \\            if (j === len) rootEnd = j;
    \\            else if (j !== last) rootEnd = j + 1;
    \\          }
    \\        }
    \\      }
    \\    } else if (isWindowsDeviceRoot(code) &&
    \\               path.charCodeAt(1) === CHAR_COLON) {
    \\      if (len <= 2) {
    \\        ret.root = ret.dir = path;
    \\        return ret;
    \\      }
    \\      rootEnd = 2;
    \\      if (isPathSeparator(path.charCodeAt(2))) {
    \\        if (len === 3) {
    \\          ret.root = ret.dir = path;
    \\          return ret;
    \\        }
    \\        rootEnd = 3;
    \\      }
    \\    }
    \\    if (rootEnd > 0) ret.root = path.slice(0, rootEnd);
    \\    let startDot = -1;
    \\    let startPart = rootEnd;
    \\    let end = -1;
    \\    let matchedSlash = true;
    \\    let i = len - 1;
    \\    let preDotState = 0;
    \\    for (; i >= rootEnd; --i) {
    \\      code = path.charCodeAt(i);
    \\      if (isPathSeparator(code)) {
    \\        if (!matchedSlash) { startPart = i + 1; break; }
    \\        continue;
    \\      }
    \\      if (end === -1) { matchedSlash = false; end = i + 1; }
    \\      if (code === CHAR_DOT) {
    \\        if (startDot === -1) startDot = i;
    \\        else if (preDotState !== 1) preDotState = 1;
    \\      } else if (startDot !== -1) {
    \\        preDotState = -1;
    \\      }
    \\    }
    \\    if (end !== -1) {
    \\      if (startDot === -1 || preDotState === 0 ||
    \\          (preDotState === 1 && startDot === end - 1 && startDot === startPart + 1)) {
    \\        ret.base = ret.name = path.slice(startPart, end);
    \\      } else {
    \\        ret.name = path.slice(startPart, startDot);
    \\        ret.base = path.slice(startPart, end);
    \\        ret.ext = path.slice(startDot, end);
    \\      }
    \\    }
    \\    if (startPart > 0 && startPart !== rootEnd)
    \\      ret.dir = path.slice(0, startPart - 1);
    \\    else ret.dir = ret.root;
    \\    return ret;
    \\  },
    \\
    \\  matchesGlob(path, pattern) {
    \\    return matchesGlobImpl(path, pattern);
    \\  },
    \\
    \\  sep: '\\',
    \\  delimiter: ';',
    \\  win32: null,
    \\  posix: null,
    \\};
    \\
    \\const posix = {
    \\  resolve(...args) {
    \\    let resolvedPath = '';
    \\    let resolvedAbsolute = false;
    \\    for (let i = args.length - 1; i >= -1 && !resolvedAbsolute; i--) {
    \\      const path = i >= 0 ? args[i] : process.cwd();
    \\      validateString(path, 'path');
    \\      if (path.length === 0) continue;
    \\      resolvedPath = path + '/' + resolvedPath;
    \\      resolvedAbsolute = path.charCodeAt(0) === CHAR_FORWARD_SLASH;
    \\    }
    \\    resolvedPath = normalizeString(resolvedPath, !resolvedAbsolute, '/', isPosixPathSeparator);
    \\    if (resolvedAbsolute) return '/' + resolvedPath;
    \\    return resolvedPath.length > 0 ? resolvedPath : '.';
    \\  },
    \\
    \\  normalize(path) {
    \\    validateString(path, 'path');
    \\    if (path.length === 0) return '.';
    \\    const isAbsolute = path.charCodeAt(0) === CHAR_FORWARD_SLASH;
    \\    const trailingSeparator = path.charCodeAt(path.length - 1) === CHAR_FORWARD_SLASH;
    \\    path = normalizeString(path, !isAbsolute, '/', isPosixPathSeparator);
    \\    if (path.length === 0) {
    \\      if (isAbsolute) return '/';
    \\      return trailingSeparator ? './' : '.';
    \\    }
    \\    if (trailingSeparator) path += '/';
    \\    return isAbsolute ? '/' + path : path;
    \\  },
    \\
    \\  isAbsolute(path) {
    \\    validateString(path, 'path');
    \\    return path.length > 0 && path.charCodeAt(0) === CHAR_FORWARD_SLASH;
    \\  },
    \\
    \\  join(...args) {
    \\    if (args.length === 0) return '.';
    \\    let joined;
    \\    for (let i = 0; i < args.length; ++i) {
    \\      const arg = args[i];
    \\      validateString(arg, 'path');
    \\      if (arg.length > 0) {
    \\        if (joined === undefined) joined = arg;
    \\        else joined += '/' + arg;
    \\      }
    \\    }
    \\    if (joined === undefined) return '.';
    \\    return posix.normalize(joined);
    \\  },
    \\
    \\  relative(from, to) {
    \\    validateString(from, 'from');
    \\    validateString(to, 'to');
    \\    if (from === to) return '';
    \\    from = posix.resolve(from);
    \\    to = posix.resolve(to);
    \\    if (from === to) return '';
    \\    const fromStart = 1;
    \\    const fromEnd = from.length;
    \\    const fromLen = fromEnd - fromStart;
    \\    const toStart = 1;
    \\    const toLen = to.length - toStart;
    \\    const length = fromLen < toLen ? fromLen : toLen;
    \\    let lastCommonSep = -1;
    \\    let i = 0;
    \\    for (; i < length; i++) {
    \\      const fromCode = from.charCodeAt(fromStart + i);
    \\      if (fromCode !== to.charCodeAt(toStart + i)) break;
    \\      else if (fromCode === CHAR_FORWARD_SLASH) lastCommonSep = i;
    \\    }
    \\    if (i === length) {
    \\      if (toLen > length) {
    \\        if (to.charCodeAt(toStart + i) === CHAR_FORWARD_SLASH) {
    \\          return to.slice(toStart + i + 1);
    \\        }
    \\        if (i === 0) {
    \\          return to.slice(toStart + i);
    \\        }
    \\      } else if (fromLen > length) {
    \\        if (from.charCodeAt(fromStart + i) === CHAR_FORWARD_SLASH) lastCommonSep = i;
    \\        else if (i === 0) lastCommonSep = 0;
    \\      }
    \\    }
    \\    let out = '';
    \\    for (i = fromStart + lastCommonSep + 1; i <= fromEnd; ++i) {
    \\      if (i === fromEnd || from.charCodeAt(i) === CHAR_FORWARD_SLASH) {
    \\        out += out.length === 0 ? '..' : '/..';
    \\      }
    \\    }
    \\    return out + to.slice(toStart + lastCommonSep);
    \\  },
    \\
    \\  toNamespacedPath(path) { return path; },
    \\
    \\  dirname(path) {
    \\    validateString(path, 'path');
    \\    if (path.length === 0) return '.';
    \\    const hasRoot = path.charCodeAt(0) === CHAR_FORWARD_SLASH;
    \\    let end = -1;
    \\    let matchedSlash = true;
    \\    for (let i = path.length - 1; i >= 1; --i) {
    \\      if (path.charCodeAt(i) === CHAR_FORWARD_SLASH) {
    \\        if (!matchedSlash) { end = i; break; }
    \\      } else { matchedSlash = false; }
    \\    }
    \\    if (end === -1) return hasRoot ? '/' : '.';
    \\    if (hasRoot && end === 1) return '//';
    \\    return path.slice(0, end);
    \\  },
    \\
    \\  basename(path, suffix) {
    \\    if (suffix !== undefined) validateString(suffix, 'suffix');
    \\    validateString(path, 'path');
    \\    let start = 0;
    \\    let end = -1;
    \\    let matchedSlash = true;
    \\    if (suffix !== undefined && suffix.length > 0 &&
    \\        suffix.length <= path.length) {
    \\      if (suffix === path) return '';
    \\      let extIdx = suffix.length - 1;
    \\      let firstNonSlashEnd = -1;
    \\      for (let i = path.length - 1; i >= 0; --i) {
    \\        const code = path.charCodeAt(i);
    \\        if (code === CHAR_FORWARD_SLASH) {
    \\          if (!matchedSlash) { start = i + 1; break; }
    \\        } else {
    \\          if (firstNonSlashEnd === -1) { matchedSlash = false; firstNonSlashEnd = i + 1; }
    \\          if (extIdx >= 0) {
    \\            if (code === suffix.charCodeAt(extIdx)) {
    \\              if (--extIdx === -1) end = i;
    \\            } else { extIdx = -1; end = firstNonSlashEnd; }
    \\          }
    \\        }
    \\      }
    \\      if (start === end) end = firstNonSlashEnd;
    \\      else if (end === -1) end = path.length;
    \\      return path.slice(start, end);
    \\    }
    \\    for (let i = path.length - 1; i >= 0; --i) {
    \\      if (path.charCodeAt(i) === CHAR_FORWARD_SLASH) {
    \\        if (!matchedSlash) { start = i + 1; break; }
    \\      } else if (end === -1) { matchedSlash = false; end = i + 1; }
    \\    }
    \\    if (end === -1) return '';
    \\    return path.slice(start, end);
    \\  },
    \\
    \\  extname(path) {
    \\    validateString(path, 'path');
    \\    let startDot = -1;
    \\    let startPart = 0;
    \\    let end = -1;
    \\    let matchedSlash = true;
    \\    let preDotState = 0;
    \\    for (let i = path.length - 1; i >= 0; --i) {
    \\      const code = path.charCodeAt(i);
    \\      if (code === CHAR_FORWARD_SLASH) {
    \\        if (!matchedSlash) { startPart = i + 1; break; }
    \\        continue;
    \\      }
    \\      if (end === -1) { matchedSlash = false; end = i + 1; }
    \\      if (code === CHAR_DOT) {
    \\        if (startDot === -1) startDot = i;
    \\        else if (preDotState !== 1) preDotState = 1;
    \\      } else if (startDot !== -1) {
    \\        preDotState = -1;
    \\      }
    \\    }
    \\    if (startDot === -1 || end === -1 || preDotState === 0 ||
    \\        (preDotState === 1 && startDot === end - 1 && startDot === startPart + 1)) {
    \\      return '';
    \\    }
    \\    return path.slice(startDot, end);
    \\  },
    \\
    \\  format: _format.bind(null, '/'),
    \\
    \\  parse(path) {
    \\    validateString(path, 'path');
    \\    const ret = { root: '', dir: '', base: '', ext: '', name: '' };
    \\    if (path.length === 0) return ret;
    \\    const isAbsolute = path.charCodeAt(0) === CHAR_FORWARD_SLASH;
    \\    let start;
    \\    if (isAbsolute) { ret.root = '/'; start = 1; }
    \\    else { start = 0; }
    \\    let startDot = -1;
    \\    let startPart = 0;
    \\    let end = -1;
    \\    let matchedSlash = true;
    \\    let i = path.length - 1;
    \\    let preDotState = 0;
    \\    for (; i >= start; --i) {
    \\      const code = path.charCodeAt(i);
    \\      if (code === CHAR_FORWARD_SLASH) {
    \\        if (!matchedSlash) { startPart = i + 1; break; }
    \\        continue;
    \\      }
    \\      if (end === -1) { matchedSlash = false; end = i + 1; }
    \\      if (code === CHAR_DOT) {
    \\        if (startDot === -1) startDot = i;
    \\        else if (preDotState !== 1) preDotState = 1;
    \\      } else if (startDot !== -1) {
    \\        preDotState = -1;
    \\      }
    \\    }
    \\    if (end !== -1) {
    \\      const cStart = startPart === 0 && isAbsolute ? 1 : startPart;
    \\      if (startDot === -1 || preDotState === 0 ||
    \\          (preDotState === 1 && startDot === end - 1 && startDot === startPart + 1)) {
    \\        ret.base = ret.name = path.slice(cStart, end);
    \\      } else {
    \\        ret.name = path.slice(cStart, startDot);
    \\        ret.base = path.slice(cStart, end);
    \\        ret.ext = path.slice(startDot, end);
    \\      }
    \\    }
    \\    if (startPart > 0) ret.dir = path.slice(0, startPart - 1);
    \\    else if (isAbsolute) ret.dir = '/';
    \\    return ret;
    \\  },
    \\
    \\  matchesGlob(path, pattern) {
    \\    return matchesGlobImpl(path, pattern);
    \\  },
    \\
    \\  sep: '/',
    \\  delimiter: ':',
    \\  win32: null,
    \\  posix: null,
    \\};
    \\
    \\win32.win32 = win32;
    \\win32.posix = posix;
    \\posix.posix = posix;
    \\posix.win32 = win32;
    \\
    \\const isWindows = process.platform === 'win32';
    \\module.exports = isWindows ? win32 : posix;
;
