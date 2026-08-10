//! Renders a decl's source as HTML, per `options.SourceMode`, syntax-
//! highlighted via `std.zig.Tokenizer`. No JS: highlighting is pure
//! CSS via `style.zig`.
const std = @import("std");
const options = @import("options.zig");

const maxPreRows = 25;

/// Writes `source` as an HTML fragment matching `mode`. Always escapes.
/// `resizable` and `inline` modes syntax-highlight via `writeTokens`
/// below unless `raw` is set (`--filetypes`, non-`.zig` content), in
/// which case `source` is only escaped, never tokenized.
pub fn write(gpa: std.mem.Allocator, writer: *std.Io.Writer, source: []const u8, mode: options.SourceMode, raw: bool) !void {
    switch (mode) {
        .none => {},
        .collapsed => {
            try writer.writeAll("<details class=\"src\"><summary>Source</summary><pre><code>");
            try writeSource(gpa, writer, source, raw);
            try writer.writeAll("</code></pre></details>\n");
        },
        .resizable => {
            // 1.5rem = 2x style.zig's `pre { padding: 0.75rem }`, so the
            // box's content area is exactly `rows` lines tall. +1 leaves
            // a bit of whitespace below the last line.
            const rows = @min(maxPreRows, countLines(source) + 1);
            try writer.print("<pre class=\"src resizable\" style=\"height: calc({d}lh + 1.5rem)\"><code>", .{rows});
            try writeSource(gpa, writer, source, raw);
            try writer.writeAll("</code></pre>\n");
        },
        .inline_ => {
            try writer.writeAll("<pre class=\"src\"><code>");
            try writeSource(gpa, writer, source, raw);
            try writer.writeAll("</code></pre>\n");
        },
    }
}

fn writeSource(gpa: std.mem.Allocator, writer: *std.Io.Writer, source: []const u8, raw: bool) !void {
    if (raw) {
        try writeEscaped(writer, source);
    } else {
        try writeHighlighted(gpa, writer, source);
    }
}

/// Copies `source` to a sentinel-terminated buffer (as `std.zig.Tokenizer`
/// requires) and highlights it; falls back to plain escaped text on
/// allocation failure so a highlighting error never drops the source.
/// (`Allocator.dupeZ` was removed in this Zig version — see
/// ZIG_API_CHANGES.md — so this builds the sentinel copy manually.)
fn writeHighlighted(gpa: std.mem.Allocator, writer: *std.Io.Writer, source: []const u8) !void {
    const sentinelSource = allocSentinelCopy(gpa, source) catch {
        try writeEscaped(writer, source);
        return;
    };
    defer gpa.free(sentinelSource);
    try writeTokens(writer, sentinelSource);
}

/// Copies `source` into a new null-terminated buffer.
fn allocSentinelCopy(gpa: std.mem.Allocator, source: []const u8) ![:0]u8 {
    const buf = try gpa.allocSentinel(u8, source.len, 0);
    @memcpy(buf, source);
    return buf;
}

/// Counts newline-delimited lines, treating a trailing partial line as one.
fn countLines(source: []const u8) usize {
    var n: usize = 1;
    for (source) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

/// Writes `source` as highlighted, HTML-escaped Zig source to `writer`,
/// using `std.zig.Tokenizer`. Exposed directly (not just via `write`
/// above) for callers highlighting a fragment — e.g. a signature —
/// that isn't wrapped in one of `options.SourceMode`'s containers.
pub fn writeTokens(writer: *std.Io.Writer, source: [:0]const u8) !void {
    var tokenizer = std.zig.Tokenizer.init(source);
    var index: usize = 0;

    while (true) {
        const token = tokenizer.next();

        if (std.mem.indexOf(u8, source[index..token.loc.start], "//")) |off| {
            const commentStart = index + off;
            const newlineOff = std.mem.indexOfScalar(u8, source[commentStart..token.loc.start], '\n');
            const commentEnd = if (newlineOff) |o| commentStart + o else token.loc.start;

            try writeEscaped(writer, source[index..commentStart]);
            try writer.writeAll("<span class=\"tok-comment\">");
            try writeEscaped(writer, source[commentStart..commentEnd]);
            try writer.writeAll("</span>");
            index = commentEnd;
        }

        try writeEscaped(writer, source[index..token.loc.start]);

        if (token.tag == .eof) break;

        const class = classFor(token.tag);
        if (class) |c| {
            try writer.print("<span class=\"{s}\">", .{c});
            try writeEscaped(writer, source[token.loc.start..token.loc.end]);
            try writer.writeAll("</span>");
        } else {
            try writeEscaped(writer, source[token.loc.start..token.loc.end]);
        }

        index = token.loc.end;
    }
}

/// Maps a token tag to a CSS class, or null for tokens left unstyled
/// (operators, punctuation, and anything not covered below).
fn classFor(tag: std.zig.Token.Tag) ?[]const u8 {
    if (tag == .identifier) return "tok-identifier";
    if (tag == .doc_comment or tag == .container_doc_comment) return "tok-comment";
    if (tag == .builtin) return "tok-builtin";
    if (tag == .number_literal) return "tok-number";
    if (tag == .string_literal or tag == .multiline_string_literal_line or tag == .char_literal) return "tok-string";
    if (std.mem.startsWith(u8, @tagName(tag), "keyword_")) return "tok-keyword";
    return null;
}

/// HTML-escapes `<`, `>`, and `&`.
fn writeEscaped(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '&' => try writer.writeAll("&amp;"),
            else => try writer.writeByte(c),
        }
    }
}

test "none mode emits nothing" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try write(gpa, &aw.writer, "pub fn f() void {}", .none, false);
    try std.testing.expectEqualStrings("", aw.written());
}

test "resizable mode escapes, highlights, and is resizable" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try write(gpa, &aw.writer, "if (a < b) {}", .resizable, false);
    const written = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "class=\"src resizable\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "&lt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "<span class=\"tok-identifier\">a</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "<span class=\"tok-keyword\">if</span>") != null);
}

test "resizable mode rows capped at max" {
    const gpa = std.testing.allocator;
    var lines: std.ArrayList(u8) = .empty;
    defer lines.deinit(gpa);
    var i: usize = 0;
    while (i < 100) : (i += 1) try lines.appendSlice(gpa, "x;\n");

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try write(gpa, &aw.writer, lines.items, .resizable, false);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "height: calc(25lh + 1.5rem)") != null);
}

test "raw mode escapes but does not highlight" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try write(gpa, &aw.writer, "if (a < b) {}", .resizable, true);
    const written = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "&lt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "tok-") == null);
}

test "collapsed mode wraps in details/summary" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try write(gpa, &aw.writer, "x", .collapsed, false);
    const written = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "<details") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "<summary>") != null);
}

test "highlights a keyword, identifier, and comment" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try writeTokens(&aw.writer, "pub fn add() void {} // sums\n");
    const out = aw.written();

    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-keyword\">pub</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-identifier\">add</span>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-comment\">// sums</span>") != null);
}

test "highlights a string literal and escapes angle brackets" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try writeTokens(&aw.writer, "const s = \"a < b\";");
    const out = aw.written();

    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-string\">\"a &lt; b\"</span>") != null);
}

test "highlights a doc comment" {
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    try writeTokens(&aw.writer, "/// docs\npub fn f() void {}");
    const out = aw.written();

    try std.testing.expect(std.mem.indexOf(u8, out, "<span class=\"tok-comment\">/// docs</span>") != null);
}
