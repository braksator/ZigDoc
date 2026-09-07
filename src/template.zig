//! A deliberately minimal templating engine: `{variable}` substitution
//! and nothing else — no conditionals, no loops, no escaping syntax
//! inside the template itself. Values are supplied pre-rendered
//! (already HTML/Markdown, already escaped where the caller wants
//! escaping) and substituted verbatim; the engine does no escaping of
//! its own. A literal `{` not immediately followed by a known
//! variable name and `}` is passed through unchanged (so templates
//! can contain, say, a `{}`  Zig snippet in a comment without the
//! engine tripping over it — anything not exactly matching a
//! provided key is left as-is rather than treated as an error).
//!
//! A variable may also carry an inline `format="..."` attribute:
//! `{name format="<div>{name}</div>"}`. When present and the
//! variable's value is non-empty, the format string is rendered as a
//! sub-template — `name` rebound to the raw value, every other
//! variable still available — instead of substituting the raw value
//! directly. An empty value renders the whole `{name format="..."}`
//! span as nothing, same as an empty plain `{name}` would. Within the
//! format string, `\"` and `\n` are unescaped before rendering, so a
//! wrapper can embed quoted HTML attributes or a literal newline
//! without breaking out of the tag's own quotes.
//!
//! When `render` is given a `padBlock` (Markdown mode), literal
//! newlines in the template source are stripped before parsing — so a
//! `.tpl` file can wrap across lines for readability — and a bare
//! `\n` outside any tag becomes a real newline in the output. A
//! `format="..."` attribute's own `\n`/`\"` escapes are unaffected by
//! this, since they're decoded separately once that attribute renders.
const std = @import("std");

/// One `{name}` → value substitution.
pub const Var = struct {
    name: []const u8,
    value: []const u8,
};

const Tag = struct {
    name: []const u8,
    format: ?[]const u8,
    end: usize, // index just past the closing '}'
};

/// Parses a `{name}` or `{name format="..."}` tag starting at `template[start]`
/// (must be `{`). Returns null if there's no well-formed tag there.
fn parseTag(template: []const u8, start: usize) ?Tag {
    var i = start + 1;
    const nameStart = i;
    while (i < template.len and template[i] != '}' and template[i] != ' ') : (i += 1) {}
    const name = template[nameStart..i];
    if (name.len == 0) return null;

    if (i < template.len and template[i] == '}') {
        return .{ .name = name, .format = null, .end = i + 1 };
    }

    while (i < template.len and template[i] == ' ') : (i += 1) {}
    const attr = "format=\"";
    if (!std.mem.startsWith(u8, template[i..], attr)) return null;
    i += attr.len;
    const formatStart = i;
    while (i < template.len and template[i] != '"') {
        if (template[i] == '\\' and i + 1 < template.len) i += 1;
        i += 1;
    }
    if (i >= template.len) return null;
    const format = template[formatStart..i];
    i += 1; // closing quote
    if (i >= template.len or template[i] != '}') return null;
    return .{ .name = name, .format = format, .end = i + 1 };
}

/// A `render`'s `padBlock` callback: pads a bare substitution's value for a particular
/// output format's block conventions.
pub const PadBlockFn = *const fn (std.mem.Allocator, []const u8) std.mem.Allocator.Error![]u8;

/// Pads `value` with a trailing newline if non-empty and not already terminated.
/// Pass as `render`'s `padBlock` for Markdown; `null` for HTML.
pub fn padMdBlock(gpa: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]u8 {
    if (value.len == 0) return gpa.dupe(u8, "");
    if (value[value.len - 1] == '\n') return gpa.dupe(u8, value);
    return std.fmt.allocPrint(gpa, "{s}\n", .{value});
}

/// Unescapes `\"` and `\n` within a `format="..."` attribute's captured text.
fn unescapeFormat(gpa: std.mem.Allocator, format: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < format.len) : (i += 1) {
        if (format[i] == '\\' and i + 1 < format.len and format[i + 1] == '"') {
            try out.append(gpa, '"');
            i += 1;
        } else if (format[i] == '\\' and i + 1 < format.len and format[i + 1] == 'n') {
            try out.append(gpa, '\n');
            i += 1;
        } else {
            try out.append(gpa, format[i]);
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Strips literal newlines from `template` (so `.tpl` source can wrap
/// lines for readability without those breaks reaching the rendered
/// output) and turns bare `\n` escapes into real newlines. Only applied
/// to Markdown templates. A `format="..."` attribute's own `\"`/`\n`
/// escapes are left as-is here — `unescapeFormat` decodes those once
/// the attribute is rendered — so this scans tag-aware rather than
/// toggling on every quote character.
fn stripTemplateNewlines(gpa: std.mem.Allocator, template: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < template.len) {
        const c = template[i];
        if (c == '{') {
            if (parseTag(template, i)) |tag| {
                try out.appendSlice(gpa, template[i..tag.end]);
                i = tag.end;
                continue;
            }
        }
        if (c == '\r') {
            i += 1;
            continue;
        }
        if (c == '\n') {
            i += 1;
            continue;
        }
        if (c == '\\' and i + 1 < template.len and template[i + 1] == 'n') {
            try out.append(gpa, '\n');
            i += 2;
            continue;
        }
        try out.append(gpa, c);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

/// Renders `template`, replacing every matched `{name}`/`{name format="..."}` with its
/// value. Unmatched spans are copied through unchanged. `padBlock`, when non-null, applies
/// only to a bare `{name}` substitution, never one inside a `format="..."` string.
pub fn render(gpa: std.mem.Allocator, template: []const u8, vars: []const Var, padBlock: ?PadBlockFn) ![]u8 {
    const source = if (padBlock != null) try stripTemplateNewlines(gpa, template) else template;
    defer if (padBlock != null) gpa.free(source);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var i: usize = 0;
    while (i < source.len) {
        if (source[i] != '{') {
            try out.append(gpa, source[i]);
            i += 1;
            continue;
        }
        const tag = parseTag(source, i) orelse {
            try out.append(gpa, source[i]);
            i += 1;
            continue;
        };
        const matched = for (vars) |v| {
            if (std.mem.eql(u8, v.name, tag.name)) break v.value;
        } else null;
        if (matched) |value| {
            if (tag.format) |format| {
                if (value.len > 0) {
                    const unescaped = try unescapeFormat(gpa, format);
                    defer gpa.free(unescaped);
                    const scoped = try gpa.alloc(Var, vars.len + 1);
                    defer gpa.free(scoped);
                    scoped[0] = .{ .name = tag.name, .value = value };
                    @memcpy(scoped[1..], vars);
                    const wrapped = try render(gpa, unescaped, scoped, null);
                    defer gpa.free(wrapped);
                    try out.appendSlice(gpa, wrapped);
                }
            } else if (padBlock) |pad| {
                const padded = try pad(gpa, value);
                defer gpa.free(padded);
                try out.appendSlice(gpa, padded);
            } else {
                try out.appendSlice(gpa, value);
            }
            i = tag.end;
        } else {
            try out.append(gpa, source[i]);
            i += 1;
        }
    }

    return out.toOwnedSlice(gpa);
}

pub const htmlDoc = @embedFile("templates/htmldoc.tpl");

pub const htmlSec = @embedFile("templates/htmlsec.tpl");

pub const mdDoc = @embedFile("templates/mddoc.tpl");

pub const mdSec = @embedFile("templates/mdsec.tpl");
