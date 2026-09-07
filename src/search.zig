//! Builds the `--search` feature's index: one entry per documented decl, giving the
//! client-side script a name, breadcrumb path, resolved href, and plain-text doc comment
//! without re-parsing rendered HTML.
const std = @import("std");
const model = @import("model.zig");
const options = @import("main.zig").options;
const render = @import("render.zig");

/// One search result's worth of data. `href` is root-relative, resolved by the client
/// script against its own `<script>` tag's URL at runtime.
pub const Entry = struct {
    name: []const u8,
    path: []const u8,
    href: []const u8,
    text: []const u8,

    fn deinit(self: *Entry, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.path);
        gpa.free(self.href);
        gpa.free(self.text);
    }
};

pub fn freeEntries(gpa: std.mem.Allocator, entries: []Entry) void {
    for (entries) |*e| e.deinit(gpa);
    gpa.free(entries);
}

/// Builds the full-site index for `tree` under `opts`. Assumes `--format html`.
/// Caller owns the result (`freeEntries`).
pub fn buildIndex(gpa: std.mem.Allocator, tree: model.DocTree, opts: options.Options) ![]Entry {
    var list: std.ArrayList(Entry) = .empty;
    errdefer {
        for (list.items) |*e| e.deinit(gpa);
        list.deinit(gpa);
    }

    if (opts.split == .none) {
        const sections = try model.disambiguateSectionPaths(gpa, tree.sections);
        defer model.freeDisambiguatedSections(gpa, sections, tree.sections);
        for (sections) |s| try collectInline(gpa, &list, s, opts.filename, opts.index, opts.prettyUrls);
        return list.toOwnedSlice(gpa);
    }

    var registry = try render.buildRegistry(gpa, tree.sections, .html, opts);
    defer registry.deinit(gpa);
    var pages = try render.buildPageIndex(gpa, .html, tree.sections, opts, registry, "", tree.moduleName, tree.sourceFile);
    defer pages.deinit(gpa);
    for (tree.sections) |section| try collectSection(gpa, &list, section, opts, &pages);
    return list.toOwnedSlice(gpa);
}

/// `--split file`/`--split item` case: reads each section's real page straight
/// from `pages`, the same lookup `sectionHref` uses for on-page codelinks, so a
/// search result always points at a page `writeNode` actually wrote.
fn collectSection(gpa: std.mem.Allocator, list: *std.ArrayList(Entry), section: model.Section, opts: options.Options, pages: *const render.PageIndex) !void {
    if (pages.get(section.path)) |loc| try appendEntry(gpa, list, section, loc.page, loc.anchor, opts.prettyUrls);
    for (section.children) |child| try collectSection(gpa, list, child, opts, pages);
}

/// Indexes `section` and every descendant as living on `pagePath`, per `linked` (whether
/// they actually get an anchor `id`).
fn collectInline(gpa: std.mem.Allocator, list: *std.ArrayList(Entry), section: model.Section, pagePath: []const u8, linked: bool, prettyUrls: bool) !void {
    var anchor: []const u8 = "";
    defer if (anchor.len > 0) gpa.free(anchor);
    if (linked) anchor = try section.anchorSlug(gpa);
    try appendEntry(gpa, list, section, pagePath, anchor, prettyUrls);
    for (section.children) |child| try collectInline(gpa, list, child, pagePath, linked, prettyUrls);
}

fn appendEntry(gpa: std.mem.Allocator, list: *std.ArrayList(Entry), section: model.Section, pagePath: []const u8, anchor: []const u8, prettyUrls: bool) !void {
    const rootRelativePage = try model.relativeHref(gpa, "", pagePath, prettyUrls);
    defer gpa.free(rootRelativePage);

    const href = if (anchor.len > 0)
        try std.fmt.allocPrint(gpa, "{s}#{s}", .{ rootRelativePage, anchor })
    else
        try gpa.dupe(u8, rootRelativePage);
    errdefer gpa.free(href);

    const text = try normalizeWhitespace(gpa, section.docComment);
    errdefer gpa.free(text);

    try list.append(gpa, .{
        .name = try gpa.dupe(u8, section.name),
        .path = try gpa.dupe(u8, section.path),
        .href = href,
        .text = text,
    });
}

/// Collapses doc-comment whitespace to single spaces and trims the ends, leaving
/// markdown syntax untouched.
pub fn normalizeWhitespace(gpa: std.mem.Allocator, md: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var lastWasSpace = true;
    for (md) |c| {
        switch (c) {
            '\n', '\r', '\t', ' ' => {
                if (!lastWasSpace) try out.append(gpa, ' ');
                lastWasSpace = true;
            },
            else => {
                try out.append(gpa, c);
                lastWasSpace = false;
            },
        }
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') _ = out.pop();
    return out.toOwnedSlice(gpa);
}

/// `--search on`'s client-side widget script, written unmodified to `search.js`.
pub const clientJs = @embedFile("assets/search.js");

/// Serializes `entries` as `window.ZDI = [...];`, the content of `search-index.js`.
/// Each entry is a positional 4-element array to keep the file small.
pub fn toJs(gpa: std.mem.Allocator, entries: []const Entry) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("window.ZDI = [\n");
    for (entries) |e| {
        try w.writeByte('[');
        try writeJsonString(w, e.name);
        try w.writeByte(',');
        try writeJsonString(w, e.path);
        try w.writeByte(',');
        try writeJsonString(w, e.href);
        try w.writeByte(',');
        try writeJsonString(w, e.text);
        try w.writeAll("],\n");
    }
    try w.writeAll("];\n");
    return aw.toOwnedSlice();
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            '<' => try w.writeAll("\\u003C"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}
