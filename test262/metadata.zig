//! Parser for Test262's `/*--- ... ---*/` YAML frontmatter (see INTERPRETING.md). M0 extracts
//! only the keys the harness needs: `negative` (type + phase), `includes`, `flags`, `features`,
//! and `description`. It is a minimal line-based parser, not a full YAML implementation.
const std = @import("std");

pub const Phase = enum { parse, resolution, runtime };

pub const Negative = struct {
    phase: Phase,
    type_name: []const u8,
};

pub const Flags = struct {
    only_strict: bool = false,
    no_strict: bool = false,
    module: bool = false,
    raw: bool = false,
    is_async: bool = false,
    can_block_is_false: bool = false,
};

pub const Metadata = struct {
    negative: ?Negative = null,
    includes: []const []const u8 = &.{},
    flags: Flags = .{},
    features: []const []const u8 = &.{},
    description: []const u8 = "",
};

pub const Error = error{ NoFrontmatter, OutOfMemory };

/// Extract and parse the YAML frontmatter from a Test262 source file.
pub fn parse(arena: std.mem.Allocator, source: []const u8) Error!Metadata {
    const open = std.mem.indexOf(u8, source, "/*---") orelse return Error.NoFrontmatter;
    const rest = source[open + 5 ..];
    const close = std.mem.indexOf(u8, rest, "---*/") orelse return Error.NoFrontmatter;
    const yaml = rest[0..close];

    var md: Metadata = .{};
    var includes: std.ArrayList([]const u8) = .empty;
    var features: std.ArrayList([]const u8) = .empty;

    var lines = std.mem.splitScalar(u8, yaml, '\n');
    var in_negative = false;
    var pending_list: enum { none, includes, features } = .none;

    while (lines.next()) |raw_line| {
        const line = stripCr(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        var indent: usize = 0;
        while (indent < line.len and (line[indent] == ' ' or line[indent] == '\t')) : (indent += 1) {}

        // Continue a block-style list ("  - item") started on a previous line.
        if (pending_list != .none and std.mem.startsWith(u8, trimmed, "- ")) {
            const item = std.mem.trim(u8, trimmed[2..], " \t");
            switch (pending_list) {
                .includes => try includes.append(arena, item),
                .features => try features.append(arena, item),
                .none => {},
            }
            continue;
        }
        pending_list = .none;

        // Inside a `negative:` block (indented phase:/type:).
        if (in_negative and indent > 0) {
            if (kv(trimmed, "phase")) |v| {
                md.negative.?.phase = parsePhase(v);
            } else if (kv(trimmed, "type")) |v| {
                md.negative.?.type_name = try arena.dupe(u8, v);
            }
            continue;
        }
        in_negative = false;

        if (std.mem.startsWith(u8, trimmed, "negative:")) {
            md.negative = .{ .phase = .runtime, .type_name = "" };
            in_negative = true;
        } else if (kv(trimmed, "includes")) |v| {
            if (isFlow(v)) {
                try parseFlow(arena, v, &includes);
            } else if (v.len == 0) {
                pending_list = .includes;
            }
        } else if (kv(trimmed, "features")) |v| {
            if (isFlow(v)) {
                try parseFlow(arena, v, &features);
            } else if (v.len == 0) {
                pending_list = .features;
            }
        } else if (kv(trimmed, "flags")) |v| {
            try parseFlags(v, &md.flags);
        } else if (kv(trimmed, "description")) |v| {
            md.description = try arena.dupe(u8, std.mem.trim(u8, v, "'\""));
        }
    }

    md.includes = try includes.toOwnedSlice(arena);
    md.features = try features.toOwnedSlice(arena);
    return md;
}

fn stripCr(line: []const u8) []const u8 {
    return if (line.len > 0 and line[line.len - 1] == '\r') line[0 .. line.len - 1] else line;
}

/// If `line` is "key: value", return the trimmed value; else null.
fn kv(line: []const u8, key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, key)) return null;
    const after = line[key.len..];
    if (after.len == 0 or after[0] != ':') return null;
    return std.mem.trim(u8, after[1..], " \t");
}

fn isFlow(v: []const u8) bool {
    return v.len >= 2 and v[0] == '[';
}

fn parseFlow(arena: std.mem.Allocator, v: []const u8, out: *std.ArrayList([]const u8)) Error!void {
    const inner = std.mem.trim(u8, v, "[]");
    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |item| {
        const t = std.mem.trim(u8, item, " \t'\"");
        if (t.len > 0) try out.append(arena, try arena.dupe(u8, t));
    }
}

fn parseFlags(v: []const u8, flags: *Flags) Error!void {
    const inner = std.mem.trim(u8, v, "[]");
    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |item| {
        const t = std.mem.trim(u8, item, " \t'\"");
        if (std.mem.eql(u8, t, "onlyStrict")) flags.only_strict = true;
        if (std.mem.eql(u8, t, "noStrict")) flags.no_strict = true;
        if (std.mem.eql(u8, t, "module")) flags.module = true;
        if (std.mem.eql(u8, t, "raw")) flags.raw = true;
        if (std.mem.eql(u8, t, "async")) flags.is_async = true;
        if (std.mem.eql(u8, t, "CanBlockIsFalse")) flags.can_block_is_false = true;
    }
}

fn parsePhase(v: []const u8) Phase {
    if (std.mem.eql(u8, v, "parse")) return .parse;
    if (std.mem.eql(u8, v, "resolution")) return .resolution;
    return .runtime;
}

// ── tests (T015 / FR-002) ───────────────────────────────────────────────────
const testing = std.testing;

test "parses negative + flags + includes (flow)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const src =
        \\// comment
        \\/*---
        \\description: a negative parse test
        \\negative:
        \\  phase: parse
        \\  type: SyntaxError
        \\flags: [onlyStrict]
        \\includes: [propertyHelper.js, assert.js]
        \\features: [generators]
        \\---*/
        \\var x =
    ;
    const md = try parse(arena_state.allocator(), src);
    try testing.expect(md.negative != null);
    try testing.expectEqual(Phase.parse, md.negative.?.phase);
    try testing.expectEqualStrings("SyntaxError", md.negative.?.type_name);
    try testing.expect(md.flags.only_strict);
    try testing.expectEqual(@as(usize, 2), md.includes.len);
    try testing.expectEqualStrings("propertyHelper.js", md.includes[0]);
    try testing.expectEqual(@as(usize, 1), md.features.len);
    try testing.expectEqualStrings("a negative parse test", md.description);
}

test "parses raw + module flags; no negative" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const src =
        \\/*---
        \\flags: [raw, module]
        \\---*/
        \\1 + 1;
    ;
    const md = try parse(arena_state.allocator(), src);
    try testing.expect(md.negative == null);
    try testing.expect(md.flags.raw);
    try testing.expect(md.flags.module);
}

test "missing frontmatter errors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(Error.NoFrontmatter, parse(arena_state.allocator(), "1 + 1;"));
}
