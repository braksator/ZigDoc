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

/// Parses a `{name}` or `{name format="..."}` tag starting at
/// `template[start]` (which must be `{`). Returns null if there's no
/// well-formed tag there (unterminated, or a `format=` not followed by
/// a properly quoted, closed string).
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

/// A `render`'s `padBlock` callback: pads a bare substitution's value
/// for a particular output format's block conventions. See
/// `padMdBlock`.
pub const PadBlockFn = *const fn (std.mem.Allocator, []const u8) std.mem.Allocator.Error![]u8;

/// Pads `value` with a trailing newline if it's non-empty and doesn't
/// already end with one — Markdown's usual one-block-per-line
/// convention for a top-level template slot. Pass as `render`'s
/// `padBlock` for a Markdown template; pass `null` for HTML, which
/// has no such convention.
pub fn padMdBlock(gpa: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]u8 {
    if (value.len == 0) return gpa.dupe(u8, "");
    if (value[value.len - 1] == '\n') return gpa.dupe(u8, value);
    return std.fmt.allocPrint(gpa, "{s}\n", .{value});
}

/// Unescapes `\"` and `\n` within a `format="..."` attribute's
/// captured text (the former so a template can wrap a value in HTML
/// double-quoted attributes; the latter so an MD template can put a
/// literal newline in its wrapper without breaking out of the
/// single-line `{name format="..."}` tag). Caller owns the returned
/// slice.
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

/// Renders `template`, replacing every `{name}` (or `{name
/// format="..."}`) that matches an entry in `vars` with its value (or
/// the value substituted into the format string). Unmatched `{...}`
/// spans are copied through unchanged. Caller owns the returned slice.
///
/// `padBlock`, when non-null, is applied only to a bare `{name}`
/// substitution (never one referenced inside another tag's
/// `format="..."` string, since that string is the template author
/// composing the value inline themselves) — it pads the substituted
/// value with a trailing newline if it doesn't already end with one.
/// This lets a caller ask for Markdown's usual one-block-per-line
/// convention on top-level slots, without that padding leaking into
/// values that get reused inside a `format` wrapper.
pub fn render(gpa: std.mem.Allocator, template: []const u8, vars: []const Var, padBlock: ?PadBlockFn) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var i: usize = 0;
    while (i < template.len) {
        if (template[i] != '{') {
            try out.append(gpa, template[i]);
            i += 1;
            continue;
        }
        const tag = parseTag(template, i) orelse {
            // No well-formed tag here: copy the '{' through literally
            // and keep scanning normally.
            try out.append(gpa, template[i]);
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
                    // Nested render: bare {name}s referenced inside this
                    // format string are being composed inline by the
                    // template author, so they're never block-padded.
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
            // Unknown {name}: not a substitution target, pass through
            // verbatim including the braces.
            try out.append(gpa, template[i]);
            i += 1;
        }
    }

    return out.toOwnedSlice(gpa);
}

test "render substitutes known variables and leaves unknown ones verbatim" {
    const gpa = std.testing.allocator;
    const out = try render(gpa, "<h1>{title}</h1>{unknown}", &.{
        .{ .name = "title", .value = "Hello" },
    }, null);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("<h1>Hello</h1>{unknown}", out);
}

test "render passes through a lone unmatched '{' without a closing brace" {
    const gpa = std.testing.allocator;
    const out = try render(gpa, "a { b", &.{}, null);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("a { b", out);
}

test "render handles a variable used multiple times" {
    const gpa = std.testing.allocator;
    const out = try render(gpa, "{x}-{x}", &.{
        .{ .name = "x", .value = "42" },
    }, null);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("42-42", out);
}

test "render leaves empty-brace and malformed spans untouched" {
    const gpa = std.testing.allocator;
    const out = try render(gpa, "{}{ }{{x}}", &.{
        .{ .name = "x", .value = "V" },
    }, null);
    defer gpa.free(out);
    // "{}" and "{ }" match no var name, left verbatim. "{{x}}" is
    // "{" + "{x}" + "}" — the inner "{x}" substitutes, the outer
    // braces are unmatched literal text.
    try std.testing.expectEqualStrings("{}{ }{V}", out);
}

test "render applies a format attribute, wrapping the raw value" {
    const gpa = std.testing.allocator;
    const out = try render(gpa, "{x format=\"<b>{x}</b>\"}", &.{
        .{ .name = "x", .value = "hi" },
    }, null);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("<b>hi</b>", out);
}

test "render with format attribute produces nothing for an empty value" {
    const gpa = std.testing.allocator;
    const out = try render(gpa, "before{x format=\"<b>{x}</b>\"}after", &.{
        .{ .name = "x", .value = "" },
    }, null);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("beforeafter", out);
}

test "render allows a format string with other variables inside" {
    const gpa = std.testing.allocator;
    const out = try render(gpa, "{crumb format=\"<nav>{crumb}{title}</nav>\"}", &.{
        .{ .name = "crumb", .value = "Home" },
        .{ .name = "title", .value = "Page" },
    }, null);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("<nav>HomePage</nav>", out);
}

test "render unescapes \\n in a format string to a literal newline" {
    const gpa = std.testing.allocator;
    const out = try render(gpa, "{x format=\"## {x}\\n\"}after", &.{
        .{ .name = "x", .value = "Heading" },
    }, null);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("## Heading\nafter", out);
}

test "render with padBlock pads a bare substitution but not a format-string one" {
    const gpa = std.testing.allocator;
    const out = try render(gpa, "**{crumb format=\"{crumb}{title}\"}**\n{title}", &.{
        .{ .name = "crumb", .value = "Home > " },
        .{ .name = "title", .value = "Page" },
    }, padMdBlock);
    defer gpa.free(out);
    // Inside the format string neither {crumb} nor {title} gets
    // padded, so the bold span stays intact. The bare {title} at the
    // end is a top-level slot and does get a trailing newline.
    try std.testing.expectEqualStrings("**Home > Page**\nPage\n", out);
}

test "render with padBlock leaves an already-newline-terminated value alone" {
    const gpa = std.testing.allocator;
    const out = try render(gpa, "{x}after", &.{
        .{ .name = "x", .value = "line\n" },
    }, padMdBlock);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("line\nafter", out);
}

test "render with padBlock produces nothing for an empty bare value" {
    const gpa = std.testing.allocator;
    const out = try render(gpa, "before{x}after", &.{
        .{ .name = "x", .value = "" },
    }, padMdBlock);
    defer gpa.free(out);
    try std.testing.expectEqualStrings("beforeafter", out);
}

// Default templates for the four `--tpl-*` slots. See README's
// "Templating" section for the variable names rendered against them.

/// `--htmldoctpl` default. One call per page.
pub const htmlDoc = @embedFile("templates/htmldoc.tpl");

/// `--htmlsectpl` default. One call per documented declaration.
pub const htmlSec = @embedFile("templates/htmlsec.tpl");

/// `--mddoctpl` default. Same shape as `htmlDoc`.
pub const mdDoc = @embedFile("templates/mddoc.tpl");

/// `--mdsectpl` default.
pub const mdSec = @embedFile("templates/mdsec.tpl");
