//! Renders a decl's source as HTML, per `options.SourceMode`, syntax-highlighted via
//! `std.zig.Tokenizer`. No JS: highlighting and the line-number gutter are pure CSS/HTML.
const std = @import("std");
const options = @import("main.zig").options;
const model = @import("model.zig");

const maxPreRows = 25;

/// Resolves the identifier token starting at byte offset `start` to its documenting href,
/// plus the byte offset one past the last token the resolved reference covers (a resolved
/// reference can span multiple tokens, e.g. `array_list.Aligned`). Position-based rather
/// than name-based, since the same identifier can resolve differently at different offsets
/// (shadowing). Used only for tokenized source; prose uses `ProseLinkResolver` instead.
pub const ResolvedSpan = struct { end: u32, href: []const u8 };

pub const LinkResolver = struct {
    context: *const anyopaque,
    resolveFn: *const fn (context: *const anyopaque, start: u32) ?ResolvedSpan,

    pub fn resolve(self: LinkResolver, start: u32) ?ResolvedSpan {
        return self.resolveFn(self.context, start);
    }
};

/// Resolves a bare identifier name (not a byte position) to an href, for doc-comment
/// prose and other non-tokenized text with no source position to key off.
pub const ProseLinkResolver = struct {
    context: *const anyopaque,
    resolveFn: *const fn (context: *const anyopaque, name: []const u8) ?[]const u8,

    pub fn resolve(self: ProseLinkResolver, name: []const u8) ?[]const u8 {
        return self.resolveFn(self.context, name);
    }
};

/// Writes `source` as an HTML fragment matching `mode`. Always escapes. `links`, when
/// given, wraps resolvable identifiers in a link (ignored when `raw`). `startLine` is the
/// 1-based line the gutter should begin counting from. Callers should skip this entirely
/// for binary content rather than pass it in.
pub fn write(gpa: std.mem.Allocator, writer: *std.Io.Writer, source: []const u8, mode: options.SourceMode, raw: bool, links: ?LinkResolver, startLine: u32) !void {
    switch (mode) {
        .none => {},
        .collapsed => {
            try writer.writeAll("<details class=\"src\"><summary>Source</summary>");
            try writeCodeGrid(gpa, writer, source, raw, links, null, startLine);
            try writer.writeAll("</details>\n");
        },
        .resizable => {
            const rows = @min(maxPreRows, countLines(source) + 1);
            try writeCodeGrid(gpa, writer, source, raw, links, rows, startLine);
        },
        .inline_, .tab => {
            try writeCodeGrid(gpa, writer, source, raw, links, null, startLine);
        },
    }
}

/// Renders the `.src-nums` gutter and `.src-txt` code pane side by side.
fn writeCodeGrid(gpa: std.mem.Allocator, writer: *std.Io.Writer, source: []const u8, raw: bool, links: ?LinkResolver, resizeRows: ?usize, startLine: u32) !void {
    if (resizeRows) |rows| {
        try writer.print("<div class=\"src-code resizable\" style=\"height: {d}lh\">", .{rows + 1});
    } else {
        try writer.writeAll("<div class=\"src-code\">");
    }

    try writer.writeAll("<div class=\"src-nums\"><pre><code>");
    try writeLineNumbers(writer, countLines(source), startLine);
    try writer.writeAll("</code></pre></div>");

    try writer.writeAll("<div class=\"src-txt\"><pre><code>");
    try writeSource(gpa, writer, source, raw, links);
    try writer.writeAll("</code></pre></div>");

    try writer.writeAll("</div>\n");
}

fn writeLineNumbers(writer: *std.Io.Writer, lineCount: usize, startLine: u32) !void {
    var n: usize = 0;
    while (n < lineCount) : (n += 1) {
        if (n > 0) try writer.writeByte('\n');
        try writer.print("<span>{d}</span>", .{startLine + n});
    }
}

fn writeSource(gpa: std.mem.Allocator, writer: *std.Io.Writer, source: []const u8, raw: bool, links: ?LinkResolver) !void {
    if (raw) {
        try writeEscaped(writer, source);
    } else {
        try writeHighlighted(gpa, writer, source, links);
    }
}

/// Copies `source` to a sentinel-terminated buffer for `std.zig.Tokenizer` and highlights
/// it; falls back to plain escaped text on allocation failure.
fn writeHighlighted(gpa: std.mem.Allocator, writer: *std.Io.Writer, source: []const u8, links: ?LinkResolver) !void {
    const sentinelSource = allocSentinelCopy(gpa, source) catch {
        try writeEscaped(writer, source);
        return;
    };
    defer gpa.free(sentinelSource);
    try writeTokensLinked(writer, sentinelSource, links);
}

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

/// Writes `source` as highlighted, HTML-escaped Zig source using `std.zig.Tokenizer`.
/// Never links identifiers — see `writeTokensLinked` for that.
pub fn writeTokens(writer: *std.Io.Writer, source: [:0]const u8) !void {
    try writeTokensLinked(writer, source, null);
}

/// Like `writeTokens`, but also links a resolvable identifier or string
/// literal (an `@import(...)` target) to its docs. A resolved reference
/// spanning multiple tokens (e.g. `array_list.Aligned`) is folded into a
/// single `<a>`, each token still individually syntax-highlighted inside it.
pub fn writeTokensLinked(writer: *std.Io.Writer, source: [:0]const u8, links: ?LinkResolver) !void {
    var tokenizer = std.zig.Tokenizer.init(source);
    var index: usize = 0;
    var prevTag: ?std.zig.Token.Tag = null;

    while (true) {
        const token = tokenizer.next();

        while (std.mem.indexOf(u8, source[index..token.loc.start], "//")) |off| {
            const commentStart = index + off;
            const newlineOff = std.mem.indexOfScalar(u8, source[commentStart..token.loc.start], '\n');
            const commentEnd = if (newlineOff) |o| commentStart + o else token.loc.start;

            // The gap before this comment (a newline plus indentation,
            // when this isn't the first of a consecutive run) — dropped
            // otherwise, since each iteration only ever wrote the comment
            // span itself before jumping `index` past it.
            try writeEscaped(writer, source[index..commentStart]);
            try writer.writeAll("<span class=\"tok-c\">");
            try writeLinkedRun(writer, source, commentStart, commentEnd, links);
            try writer.writeAll("</span>");
            index = commentEnd;
        }

        try writeEscaped(writer, source[index..token.loc.start]);

        if (token.tag == .eof) break;

        // A dotted identifier chain (`array_list.Aligned`) still resolves
        // as one multi-token span from its own start; a filename mention
        // inside a string literal is checked byte-by-byte below instead,
        // since it can start anywhere inside the token, not just at it.
        const span = if (token.tag == .identifier and links != null)
            links.?.resolve(@intCast(token.loc.start))
        else
            null;

        if (span) |s| {
            try writer.print("<a class=\"tok-l\" href=\"", .{});
            try writeEscapedAttr(writer, s.href);
            try writer.writeAll("\">");
            prevTag = try writeTokenSpan(writer, source, &tokenizer, token, s.end, prevTag);
            try writer.writeAll("</a>");
            index = s.end;
        } else if (token.tag == .string_literal) {
            try writer.writeAll("<span class=\"tok-str\">");
            try writeLinkedRun(writer, source, token.loc.start, token.loc.end, links);
            try writer.writeAll("</span>");
            prevTag = token.tag;
            index = token.loc.end;
        } else {
            var peek = tokenizer;
            const nextTag = peek.next().tag;
            try writeOneToken(writer, source, token, prevTag, nextTag);
            prevTag = token.tag;
            index = token.loc.end;
        }
    }
}

/// Writes `source[spanStart..spanEnd)` (a comment or the inside of a
/// string literal), HTML-escaped, checking every byte position for a
/// resolvable filename mention and wrapping any hit in its own `<a>` —
/// the rest of the span stays plain text around it.
fn writeLinkedRun(writer: *std.Io.Writer, source: [:0]const u8, spanStart: usize, spanEnd: usize, links: ?LinkResolver) !void {
    var i = spanStart;
    var plainStart = spanStart;
    while (i < spanEnd) {
        const span = if (links) |l| l.resolve(@intCast(i)) else null;
        if (span) |s| {
            // A target resolved against a different (longer) string than
            // what's actually being rendered here can report an end past
            // this span — clamp rather than let the slice below invert.
            const end = @min(s.end, spanEnd);
            if (end <= i) {
                i += 1;
                continue;
            }
            try writeEscaped(writer, source[plainStart..i]);
            try writer.print("<a class=\"tok-l\" href=\"", .{});
            try writeEscapedAttr(writer, s.href);
            try writer.writeAll("\">");
            try writeEscaped(writer, source[i..end]);
            try writer.writeAll("</a>");
            i = end;
            plainStart = i;
        } else {
            i += 1;
        }
    }
    try writeEscaped(writer, source[plainStart..spanEnd]);
}

/// Writes one already-tokenized token's text, syntax-highlighted, with no link wrapping.
/// `prevTag`/`nextTag` are the tokens immediately before/after `token` (see `isFnNameToken`).
fn writeOneToken(writer: *std.Io.Writer, source: [:0]const u8, token: std.zig.Token, prevTag: ?std.zig.Token.Tag, nextTag: std.zig.Token.Tag) !void {
    const text = source[token.loc.start..token.loc.end];
    const isFnName = token.tag == .identifier and isFnNameToken(prevTag, nextTag);
    if (classFor(token.tag, text, isFnName)) |c| {
        try writer.print("<span class=\"{s}\">", .{c});
        try writeEscaped(writer, text);
        try writer.writeAll("</span>");
    } else {
        try writeEscaped(writer, text);
    }
}

/// Writes `firstToken` plus every further token up through byte offset `end`, each
/// individually syntax-highlighted — the inside of a multi-token linked span.
/// `prevTag` is the token immediately before `firstToken`, for `firstToken`'s own
/// `isFnNameToken` check; returns the last token's tag, for the caller's own.
fn writeTokenSpan(writer: *std.Io.Writer, source: [:0]const u8, tokenizer: *std.zig.Tokenizer, firstToken: std.zig.Token, end: u32, prevTag: ?std.zig.Token.Tag) !std.zig.Token.Tag {
    var token = firstToken;
    var index: usize = firstToken.loc.start;
    var prev = prevTag;
    while (true) {
        try writeEscaped(writer, source[index..token.loc.start]);
        var peek = tokenizer.*;
        const nextTag = peek.next().tag;
        try writeOneToken(writer, source, token, prev, nextTag);
        prev = token.tag;
        index = token.loc.end;
        if (token.loc.end >= end or token.tag == .eof) break;
        token = tokenizer.next();
    }
    return prev.?;
}

/// Reports whether an identifier token is a function name: immediately preceded
/// by the `fn` keyword (a declaration's own name) or immediately followed by `(`
/// (a call expression). `nextTag` is the very next token after the identifier —
/// callers get it via a cloned tokenizer peek, since `std.zig.Tokenizer.next()`
/// has no lookahead of its own. There's always a next token (`.eof` at worst),
/// but `prevTag` is genuinely absent for the very first token in a source.
pub fn isFnNameToken(prevTag: ?std.zig.Token.Tag, nextTag: std.zig.Token.Tag) bool {
    if (prevTag == .keyword_fn) return true;
    if (nextTag == .l_paren) return true;
    return false;
}

/// Maps a token's tag and text to a CSS class, or null for tokens left unstyled.
/// `isFnName` marks an identifier as a function name (declaration or call site) —
/// callers with token-sequence context (see `writeOneToken`'s caller) decide that
/// and it overrides the default `tok-id` an identifier would otherwise get.
pub fn classFor(tag: std.zig.Token.Tag, text: []const u8, isFnName: bool) ?[]const u8 {
    if (tag == .identifier) {
        if (isFnName) return "tok-f";
        return if (model.isPrimitiveTypeName(text)) "tok-type" else "tok-id";
    }
    if (tag == .doc_comment or tag == .container_doc_comment) return "tok-c";
    if (tag == .builtin) return "tok-bi";
    if (tag == .number_literal) return "tok-num";
    if (tag == .string_literal or tag == .multiline_string_literal_line or tag == .char_literal) return "tok-str";
    if (std.mem.startsWith(u8, @tagName(tag), "keyword_")) return "tok-kw";
    return null;
}

/// HTML-escapes `<`, `>`, and `&`.
pub fn writeEscaped(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '&' => try writer.writeAll("&amp;"),
            else => try writer.writeByte(c),
        }
    }
}

/// HTML-escapes an attribute value: as `writeEscaped`, plus `"`.
pub fn writeEscapedAttr(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '&' => try writer.writeAll("&amp;"),
            '"' => try writer.writeAll("&quot;"),
            else => try writer.writeByte(c),
        }
    }
}
