//! The one renderer. A page is written for the same reason
//! regardless of what it's for — the root, a `--tree` directory
//! group, or a documented file/decl — and regardless of `--split`
//! mode or `--format`: it's "the content for this node in the
//! project's structure." One recursive function (`writeNode`) builds
//! every page; the explicit branches below (on `NodeKind`, `Format`,
//! and `opts.split`) are the only places behavior actually differs —
//! not separate copies of this logic per page type or per format.
//!
//! Directories are the one thing here that aren't `model.Section`
//! nodes in the data model (only files and decls are), so discovering
//! them is a separate small walk (`writeDirGroups`) — but everything
//! a directory's page contains is still built by the same `writeNode`
//! a file or item page goes through.
//!
//! `--split none` (single-page mode) is the same engine with two
//! differences, both applied as plain `if`s below: only the root ever
//! becomes its own `Page` (everything else inlines onto it), and
//! there's nowhere else to link to, so directory groups and decls
//! link within the page (`#anchor`) instead of out to another page.
const std = @import("std");
const model = @import("model.zig");
const options = @import("options.zig");
const style = @import("style.zig");
const template = @import("template.zig");
const sources = @import("sources.zig");
const progress_mod = @import("progress.zig");
const markdown = struct {
    pub const Parser = @import("markdown/Parser.zig");
};

/// One rendered output page.
pub const Page = struct {
    /// Output-relative path, `/`-separated, mirroring the input
    /// project's directory structure. In single-page mode there's
    /// exactly one `Page`, named `opts.filename`.
    filename: []const u8,
    contents: []const u8,

    pub fn deinit(self: *Page, gpa: std.mem.Allocator) void {
        gpa.free(self.filename);
        gpa.free(self.contents);
    }
};

pub fn freePages(gpa: std.mem.Allocator, pages: *std.ArrayList(Page)) void {
    for (pages.items) |*p| p.deinit(gpa);
    pages.deinit(gpa);
}

/// The only thing that distinguishes an HTML page from a Markdown
/// one: a filename extension and a handful of small rendering
/// choices, switched on below wherever they differ.
pub const Format = enum {
    html,
    md,

    fn ext(self: Format) []const u8 {
        return switch (self) {
            .html => ".html",
            .md => ".md",
        };
    }

    fn indexFilename(self: Format) []const u8 {
        return switch (self) {
            .html => "index.html",
            .md => "index.md",
        };
    }
};

/// What a page is for. A directory and the root are the same shape
/// (`container`) — the root is just the container whose `dirPath` is
/// `""` — so front/directory pages are never distinguished. A file
/// and a documented decl are the same shape too (`decl`); whether a
/// decl's children get their own pages or render inline on this one
/// page is a single global choice (`opts.split`), not a per-kind one.
const NodeKind = union(enum) {
    container: struct {
        /// Page heading: the project title at root, `"name/"` for a directory.
        heading: []const u8,
        /// `""` at root, the directory's path otherwise.
        dirPath: []const u8,
        /// This container's immediate members (files and/or nested
        /// directory groups, per `fileLabel` prefix grouping).
        sections: []const model.Section,
        /// Root's own doc comment; directories never have one.
        comment: []const u8,
        isRoot: bool,
    },
    decl: model.Section,
};

/// One entry in a breadcrumb trail: a display name and its page's
/// real, already-computed output path (root-relative). Carrying the
/// actual computed path — rather than each breadcrumb re-deriving it
/// from a `Section` with a `dirPageFilename`/`pageFilename` guess —
/// is what makes an item-mode decl ancestor resolve correctly: a
/// decl's own page path depends on which file it belongs to, which
/// isn't recoverable from the `Section` alone.
const Ancestor = struct { name: []const u8, target: []const u8 };

const Ctx = struct {
    gpa: std.mem.Allocator,
    fmt: Format,
    title: []const u8,
    opts: options.Options,
    tplDoc: []const u8,
    tplSec: []const u8,
    /// The index page's own displayed heading/breadcrumb label —
    /// `opts.rootname` if set, else `rootDirName`.
    indexTitle: []const u8,
    /// The documented root's real name (e.g. `lib/`), always as
    /// derived from the input path — never overridden by
    /// `opts.rootname`, which only renames the index page's own
    /// heading/breadcrumb label, not what other pages call it when
    /// linking back (`resolveLocLink`'s `--locfull` case).
    rootDirName: []const u8,
    registry: Registry,
    reporter: *progress_mod.Progress,
};

/// Renders `tree` into a set of `Page`s for `opts.split`/`opts.format`.
/// `tplDoc`/`tplSec` are the resolved doc/section template text for
/// `fmt`. Caller owns the returned slice and each page's contents
/// (`freePages`).
pub fn write(
    gpa: std.mem.Allocator,
    fmt: Format,
    tree: model.DocTree,
    title: []const u8,
    opts: options.Options,
    tplDoc: []const u8,
    tplSec: []const u8,
    reporter: *progress_mod.Progress,
) ![]Page {
    var pages: std.ArrayList(Page) = .empty;
    errdefer freePages(gpa, &pages);

    const indexTitle = opts.rootname orelse tree.moduleName;

    if (opts.split == .none) {
        // Single-page mode never writes a separate page per file, so
        // there's nothing for a registry to resolve.
        var registry = Registry{ .slugs = std.StringHashMap([]const u8).init(gpa), .declSegments = std.StringHashMap([]const u8).init(gpa) };
        defer registry.deinit(gpa);
        const ctx = Ctx{ .gpa = gpa, .fmt = fmt, .title = title, .opts = opts, .tplDoc = tplDoc, .tplSec = tplSec, .indexTitle = indexTitle, .rootDirName = tree.moduleName, .registry = registry, .reporter = reporter };
        try writeSinglePage(ctx, &pages, tree);
        return pages.toOwnedSlice(gpa);
    }

    var registry = try buildRegistry(gpa, tree.sections, fmt, opts);
    defer registry.deinit(gpa);
    const ctx = Ctx{ .gpa = gpa, .fmt = fmt, .title = title, .opts = opts, .tplDoc = tplDoc, .tplSec = tplSec, .indexTitle = indexTitle, .rootDirName = tree.moduleName, .registry = registry, .reporter = reporter };

    try writeNode(ctx, &pages, .{ .container = .{
        .heading = ctx.indexTitle,
        .dirPath = "",
        .sections = tree.sections,
        .comment = tree.rootDocComment orelse "",
        .isRoot = true,
    } }, &.{}, "", "");

    if (model.hasFileLabels(tree.sections)) {
        try writeDirGroups(ctx, &pages, tree.sections, "");
    }

    for (tree.sections) |section| {
        const dirAncestors = if (opts.tree) try ancestorsFromDirPath(gpa, fmt, dirPortion(section.fileLabel)) else &.{};
        defer freeDirAncestors(gpa, dirAncestors);
        // Seeds the base --split item's own recursion appends decl
        // names onto (see writeNode's ownDeclPath doc comment) — the
        // file section's own page ignores this (pageFilename's
        // file-kind branch uses the registry directly instead).
        try writeNode(ctx, &pages, .{ .decl = section }, dirAncestors, section.fileLabel, ctx.registry.slugFor(section.fileLabel));
    }

    if (!opts.dirUrls) try writeOrphanRedirects(ctx, &pages, tree.sections);

    return pages.toOwnedSlice(gpa);
}

/// Discovers every `--tree` directory group under `sections` (which
/// must already be the portion at `dirPath`) and writes each one's
/// own page via `writeNode`, then recurses into subdirectories.
fn writeDirGroups(ctx: Ctx, pages: *std.ArrayList(Page), sections: []const model.Section, dirPath: []const u8) !void {
    const gpa = ctx.gpa;
    const sorted = try gpa.dupe(model.Section, sections);
    defer gpa.free(sorted);
    model.sortByFileLabelOrder(sorted, toDirOrder(ctx.opts.dirOrder));
    const prefixLen = if (dirPath.len == 0) 0 else dirPath.len + 1;

    const DirWalkCtx = struct { ctx: Ctx, pages: *std.ArrayList(Page), dirPath: []const u8 };
    var dctx = DirWalkCtx{ .ctx = ctx, .pages = pages, .dirPath = dirPath };
    const Cbs = struct {
        fn onDir(c: *DirWalkCtx, name: []const u8, children: []const model.Section) !void {
            const gpa2 = c.ctx.gpa;
            const childDirPath = if (c.dirPath.len == 0)
                try gpa2.dupe(u8, name)
            else
                try std.fmt.allocPrint(gpa2, "{s}/{s}", .{ c.dirPath, name });
            defer gpa2.free(childDirPath);
            const heading = try std.fmt.allocPrint(gpa2, "{s}/", .{name});
            defer gpa2.free(heading);
            const dirAncestors = if (c.ctx.opts.breadcrumb) try ancestorsFromDirPath(gpa2, c.ctx.fmt, c.dirPath) else &.{};
            defer freeDirAncestors(gpa2, dirAncestors);

            try writeNode(c.ctx, c.pages, .{ .container = .{
                .heading = heading,
                .dirPath = childDirPath,
                .sections = children,
                .comment = "",
                .isRoot = false,
            } }, dirAncestors, "", "");
            try writeDirGroups(c.ctx, c.pages, children, childDirPath);
        }
        fn onLeaf(_: *DirWalkCtx, _: model.Section) !void {}
    };
    try model.forEachDirGroup(sorted, prefixLen, &dctx, Cbs.onDir, Cbs.onLeaf);
}

/// A decl page's link back to its containing directory's page, plus
/// the display text for that link — see `resolveLocLink`.
const LocLink = struct {
    href: []const u8,
    prefix: []const u8,

    fn deinit(self: LocLink, gpa: std.mem.Allocator) void {
        if (self.href.len > 0) gpa.free(self.href);
        if (self.prefix.len > 0) gpa.free(self.prefix);
    }
};

/// Resolves the directory-page link shown before a decl's bare
/// filename in `{location}`: always targets the file's own containing
/// directory page (the root/index page itself, for a file with no
/// subdirectory of its own). `prefix` is the display text for that
/// link — the file's real directory path (e.g. `build-web/`, or `""`
/// for a root-level file) — with `rootDirName` prepended when
/// `opts.locFull` is on (e.g. `lib/build-web/`, or just `lib/` for a
/// root-level file), so the full path down to the file's directory is
/// always one clickable link to that same directory page.
/// `rootDirName` is the root's real name, deliberately not
/// `opts.rootname`/`ctx.indexTitle`, which only rename the index
/// page's own on-page heading, not what other pages call it when
/// linking back to it. Independent of `opts.tree`: that only controls
/// whether the *index page's own listing* groups entries by directory
/// (`writeSectionIndex`) — every directory page still exists on disk
/// either way (`writeDirGroups` has no `opts.tree` gate of its own),
/// so a decl's location line can always link to one. Both fields
/// empty when nothing should link at all (single-file input with no
/// `fileLabel`, or a root-level file with `opts.locFull` off). Caller
/// owns both fields via `LocLink.deinit`.
fn resolveLocLink(gpa: std.mem.Allocator, fmt: Format, opts: options.Options, fileLabel: []const u8, ownPath: []const u8, rootDirName: []const u8) !LocLink {
    const prettyUrls = fmt == .html and opts.prettyUrls;
    const dirPath = dirPortion(fileLabel);
    if (dirPath.len == 0 and !(opts.locFull and fileLabel.len > 0)) return .{ .href = "", .prefix = "" };

    const target = try dirPageFilename(gpa, fmt, dirPath);
    defer gpa.free(target);
    const href = try model.relativeHref(gpa, ownPath, target, prettyUrls);
    errdefer gpa.free(href);

    const prefix = if (opts.locFull and fileLabel.len > 0)
        try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ rootDirName, dirPath, if (dirPath.len > 0) "/" else "" })
    else
        try std.fmt.allocPrint(gpa, "{s}/", .{dirPath});
    return .{ .href = href, .prefix = prefix };
}

/// Builds and appends the page for one node — root, directory, file,
/// or item alike. `ancestors` is the breadcrumb chain. `fileLabel` is
/// only meaningful for a `.decl` node (its owning file's label, for
/// `resolveLocLink`'s `{location}` link — the same for every decl in
/// a file, however deeply nested, unlike `ownDeclPath` below).
/// `ownDeclPath` is also only meaningful for a `.decl` node: this
/// decl's own full page path, built by the caller (see the recursive
/// call site below, and its own top-level call site) as its owning
/// file's folder plus one case-preserved segment per level of decl
/// nesting (e.g. `fuzzer.zig/Input/deinit`) — a top-level *file*
/// section ignores it entirely (`pageFilename`'s file-kind branch).
fn writeNode(ctx: Ctx, pages: *std.ArrayList(Page), kind: NodeKind, ancestors: []const Ancestor, fileLabel: []const u8, ownDeclPath: []const u8) !void {
    const gpa = ctx.gpa;
    const fmt = ctx.fmt;

    const ownPath = switch (kind) {
        .container => |c| try dirPageFilename(gpa, fmt, c.dirPath),
        .decl => |s| try pageFilename(gpa, fmt, s, ownDeclPath, ctx.opts, ctx.registry),
    };
    defer gpa.free(ownPath);
    ctx.reporter.update("rendering {s}", .{ownPath});

    const styles = switch (fmt) {
        .html => try stylesValue(gpa, ctx.opts),
        .md => try gpa.dupe(u8, ""),
    };
    defer gpa.free(styles);

    // Breadcrumb: every page except the root has one (when `opts.breadcrumb`).
    var breadcrumb: []const u8 = "";
    defer if (breadcrumb.len > 0) gpa.free(breadcrumb);
    const isRoot = kind == .container and kind.container.isRoot;
    if (ctx.opts.breadcrumb and !isRoot) {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        const prettyUrls = fmt == .html and ctx.opts.prettyUrls;
        const indexHref = try model.relativeHref(gpa, ownPath, fmt.indexFilename(), prettyUrls);
        defer gpa.free(indexHref);
        switch (fmt) {
            .html => try writeBreadcrumbHtml(gpa, &aw.writer, indexHref, ctx.indexTitle, ancestors, ownPath, prettyUrls),
            .md => try writeBreadcrumbMd(gpa, &aw.writer, indexHref, ctx.indexTitle, ancestors, ownPath),
        }
        breadcrumb = try gpa.dupe(u8, aw.written());
    }

    // Resolves the directory-page link this decl's {location} shows
    // before its bare filename (see resolveLocLink's doc comment).
    var loc = LocLink{ .href = "", .prefix = "" };
    defer loc.deinit(gpa);
    if (kind == .decl) {
        loc = try resolveLocLink(gpa, fmt, ctx.opts, fileLabel, ownPath, ctx.rootDirName);
    }
    const dirHref = loc.href;
    const locPrefix = loc.prefix;

    // page-title / id / comment / index / docs: the one place kind
    // and opts.split actually change what a page contains.
    var idVal: []const u8 = "";
    defer if (idVal.len > 0) gpa.free(idVal);
    var comment: []const u8 = "";
    defer if (comment.len > 0) gpa.free(comment);
    var indexContent: []const u8 = "";
    defer if (indexContent.len > 0) gpa.free(indexContent);
    var docs: []const u8 = "";
    defer if (docs.len > 0) gpa.free(docs);
    var pageTitle: []const u8 = "";

    switch (kind) {
        .container => |c| {
            pageTitle = c.heading;
            if (ctx.opts.index and c.isRoot) idVal = try gpa.dupe(u8, "index");
            if (c.isRoot and ctx.opts.rootComment.len > 0) {
                comment = try renderComment(gpa, fmt, ctx.opts.rootComment);
            } else if (c.comment.len > 0) {
                comment = try renderComment(gpa, fmt, c.comment);
            }

            var aw: std.Io.Writer.Allocating = .init(gpa);
            defer aw.deinit();
            try writeSectionIndex(gpa, fmt, &aw.writer, c.sections, c.dirPath, ownPath, ctx.opts, ctx.registry, true);
            indexContent = try gpa.dupe(u8, aw.written());
            // docs / a directory or the root never inline any body content.
        },
        .decl => |section| {
            pageTitle = section.name;

            if (ctx.opts.split == .file) {
                // `--split file`: this page holds the whole file —
                // every descendant decl inlined with in-page anchors.
                if (ctx.opts.index) {
                    const slug = switch (fmt) {
                        .html => try section.anchorSlug(gpa),
                        .md => try section.anchorSlugMd(gpa),
                    };
                    defer gpa.free(slug);
                    idVal = try gpa.dupe(u8, slug);
                }
                if (section.docComment.len > 0) comment = try renderComment(gpa, fmt, section.docComment);

                if (ctx.opts.index and section.children.len > 0) {
                    var aw: std.Io.Writer.Allocating = .init(gpa);
                    defer aw.deinit();
                    try writeInPageIndex(gpa, fmt, &aw.writer, section.children, 0, ctx.opts.collapse == .all);
                    indexContent = try gpa.dupe(u8, aw.written());
                }

                var docsBuf: std.ArrayList(u8) = .empty;
                defer docsBuf.deinit(gpa);
                for (section.children) |child| {
                    try renderSection(gpa, fmt, &docsBuf, ctx.tplSec, child, ctx.opts, 2, ctx.opts.index, dirHref, locPrefix);
                }
                docs = try docsBuf.toOwnedSlice(gpa);
            } else {
                // `--split item`: this page holds only this one decl;
                // every child gets its own page too, so the index here
                // links out to them instead of inlining anything.
                var vars = try buildSectionVars(gpa, fmt, section, ctx.opts, 1, false, dirHref, locPrefix);
                defer vars.deinit(gpa);

                if (section.children.len > 0) {
                    var aw: std.Io.Writer.Allocating = .init(gpa);
                    defer aw.deinit();
                    try writePageLinkList(gpa, fmt, &aw.writer, section.children, ownPath, ownDeclPath, ctx.opts, ctx.registry);
                    indexContent = try gpa.dupe(u8, aw.written());
                }

                // The doc template's own {page-title}/{comment} slots
                // carry the heading and comment, so the section body
                // renders with those two blanked, leaving just {docs}.
                var bodyVars = vars;
                bodyVars.name = "";
                bodyVars.comment = "";
                docs = try renderOneSection(gpa, fmt, ctx.tplSec, bodyVars);
                comment = try gpa.dupe(u8, vars.comment);
            }
        },
    }

    try finishPage(gpa, fmt, pages, ownPath, ctx.tplDoc, &.{
        .{ .name = "page-title", .value = pageTitle },
        .{ .name = "site-title", .value = ctx.title },
        .{ .name = "styles", .value = styles },
        .{ .name = "head", .value = ctx.opts.head },
        .{ .name = "prepend", .value = ctx.opts.prepend },
        .{ .name = "breadcrumb", .value = breadcrumb },
        .{ .name = "desc", .value = ctx.opts.desc },
        .{ .name = "comment", .value = comment },
        .{ .name = "index", .value = indexContent },
        .{ .name = "id", .value = idVal },
        .{ .name = "docs", .value = docs },
        .{ .name = "append", .value = ctx.opts.append },
    });

    // `--split item` recurses into each child, giving it its own page too.
    if (kind == .decl and ctx.opts.split == .item) {
        const section = kind.decl;
        var nextAncestors = try gpa.alloc(Ancestor, ancestors.len + 1);
        defer gpa.free(nextAncestors);
        @memcpy(nextAncestors[0..ancestors.len], ancestors);
        // `ownPath` is this page's real, already-computed path — used
        // as-is, not re-derived — and stays alive for this whole call
        // (freed by this function's own `defer` only after every
        // recursive child call below has returned).
        nextAncestors[ancestors.len] = .{ .name = section.name, .target = ownPath };
        for (section.children) |child| {
            const childDeclPath = try appendDeclPathSegment(gpa, ownDeclPath, child.name, ctx.registry);
            defer gpa.free(childDeclPath);
            try writeNode(ctx, pages, .{ .decl = child }, nextAncestors, fileLabel, childDeclPath);
        }
    }
}

/// `--split none`: everything lives on one page (`opts.filename`, not
/// `fmt.indexFilename()` — this is the one page whose name is
/// user-configurable). There's nowhere else to link to, so the
/// breadcrumb is always empty, directory groups are unlinked labels
/// rather than links, and every decl (not just top-level files) links
/// within the page via `#anchor` instead of out to another page —
/// `writeSectionIndex`/`writeInPageIndex`'s `linkOut = false` path.
/// Every top-level section shares this one page's anchor namespace, so
/// colliding paths are disambiguated first.
fn writeSinglePage(ctx: Ctx, pages: *std.ArrayList(Page), tree: model.DocTree) !void {
    const gpa = ctx.gpa;
    const fmt = ctx.fmt;

    const sections = try model.disambiguateSectionPaths(gpa, tree.sections);
    defer model.freeDisambiguatedSections(gpa, sections, tree.sections);

    const styles = switch (fmt) {
        .html => try stylesValue(gpa, ctx.opts),
        .md => try gpa.dupe(u8, ""),
    };
    defer gpa.free(styles);

    var idVal: []const u8 = "";
    defer if (idVal.len > 0) gpa.free(idVal);
    if (ctx.opts.index) {
        const slug = try model.slugify(gpa, tree.moduleName);
        defer gpa.free(slug);
        idVal = try gpa.dupe(u8, slug);
    }

    var comment: []const u8 = "";
    defer if (comment.len > 0) gpa.free(comment);
    if (ctx.opts.rootComment.len > 0) {
        comment = try renderComment(gpa, fmt, ctx.opts.rootComment);
    } else if (tree.rootDocComment) |doc| {
        comment = try renderComment(gpa, fmt, doc);
    }

    var indexContent: []const u8 = "";
    defer if (indexContent.len > 0) gpa.free(indexContent);
    if (ctx.opts.index) {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try writeSectionIndex(gpa, fmt, &aw.writer, sections, "", "", ctx.opts, ctx.registry, false);
        indexContent = try gpa.dupe(u8, aw.written());
    }

    var docsBuf: std.ArrayList(u8) = .empty;
    defer docsBuf.deinit(gpa);
    for (sections) |section| {
        try renderSection(gpa, fmt, &docsBuf, ctx.tplSec, section, ctx.opts, 2, ctx.opts.index, "", "");
    }

    try finishPage(gpa, fmt, pages, ctx.opts.filename, ctx.tplDoc, &.{
        .{ .name = "page-title", .value = ctx.indexTitle },
        .{ .name = "site-title", .value = ctx.title },
        .{ .name = "styles", .value = styles },
        .{ .name = "head", .value = ctx.opts.head },
        .{ .name = "prepend", .value = ctx.opts.prepend },
        .{ .name = "breadcrumb", .value = "" }, // single-page mode: nowhere else to link to
        .{ .name = "desc", .value = ctx.opts.desc },
        .{ .name = "comment", .value = comment },
        .{ .name = "index", .value = indexContent },
        .{ .name = "id", .value = idVal },
        .{ .name = "docs", .value = docsBuf.items },
        .{ .name = "append", .value = ctx.opts.append },
    });
}

const VarSpec = struct { name: []const u8, value: []const u8 };

/// Renders `tplDoc` against `specs` and appends the resulting page.
/// For Markdown, `template.render`'s `padBlock` normalizes a trailing
/// newline onto every bare (non-`format`) substitution; HTML passes
/// values through unpadded. Everything past that point — building the
/// `Var` list, calling `template.render`, appending the `Page` — is
/// identical either way.
fn finishPage(gpa: std.mem.Allocator, fmt: Format, pages: *std.ArrayList(Page), ownPath: []const u8, tplDoc: []const u8, specs: []const VarSpec) !void {
    const owned = try gpa.alloc([]const u8, specs.len);
    defer gpa.free(owned);
    var filled: usize = 0;
    defer for (owned[0..filled]) |o| gpa.free(o);

    const vars = try gpa.alloc(template.Var, specs.len);
    defer gpa.free(vars);

    for (specs, 0..) |s, i| {
        owned[i] = try gpa.dupe(u8, s.value);
        filled += 1;
        vars[i] = .{ .name = s.name, .value = owned[i] };
    }

    const padBlock: ?template.PadBlockFn = if (fmt == .md) template.padMdBlock else null;
    const rendered = try template.render(gpa, tplDoc, vars, padBlock);
    try pages.append(gpa, .{ .filename = try gpa.dupe(u8, ownPath), .contents = rendered });
}

fn renderComment(gpa: std.mem.Allocator, fmt: Format, docComment: []const u8) ![]u8 {
    return switch (fmt) {
        .html => markdownToHtml(gpa, docComment),
        .md => gpa.dupe(u8, docComment),
    };
}

fn stylesValue(gpa: std.mem.Allocator, opts: options.Options) ![]u8 {
    return switch (opts.css) {
        .embed => std.fmt.allocPrint(gpa, "<style>\n{s}\n</style>", .{style.css(opts.theme)}),
        .external => gpa.dupe(u8, "<link rel=\"stylesheet\" href=\"style.css\">"),
    };
}

/// Maps a file's `fileLabel` (e.g. `"render/html_single.zig"`) to the
/// slug its own page and (in `--split item` mode) its decls' folder
/// are built from — usually just `fileLabel` itself or its `.zig`-
/// stripped form (per `opts.extUrls`), except where that would
/// collide with a sibling in the same directory (another file's slug,
/// or a real subdirectory's name), in which case it's whatever the
/// collision resolution in `buildRegistry` settled on instead —
/// regardless of what `opts.extUrls`/`opts.dirUrls` say. Built once
/// per `write()` call; every page's filename is looked up here rather
/// than each recomputing its own guess, so a decl page's breadcrumb
/// back to its file (and everything else that needs a file's path)
/// agrees with where that file's page actually is.
const Registry = struct {
    slugs: std.StringHashMap([]const u8),
    declSegments: std.StringHashMap([]const u8),

    fn deinit(self: *Registry, gpa: std.mem.Allocator) void {
        var it = self.slugs.iterator();
        while (it.next()) |e| {
            gpa.free(@constCast(e.key_ptr.*));
            gpa.free(e.value_ptr.*);
        }
        self.slugs.deinit();
        var it2 = self.declSegments.iterator();
        while (it2.next()) |e| {
            gpa.free(@constCast(e.key_ptr.*));
            gpa.free(e.value_ptr.*);
        }
        self.declSegments.deinit();
    }

    /// The registered slug for `fileLabel`, or its plain `.zig`-
    /// stripped form if `fileLabel` isn't registered (single-file
    /// input, where there's no directory structure to collide in, so
    /// `buildRegistry` is never called).
    fn slugFor(self: Registry, fileLabel: []const u8) []const u8 {
        return self.slugs.get(fileLabel) orelse model.stripZigExt(fileLabel);
    }

    /// The registered, sibling-collision-resolved path segment for a
    /// decl named `name` under `parentDeclPath`, or `null` if this
    /// registry never saw that pair (single-page mode, which builds no
    /// registry at all).
    fn declSegmentFor(self: Registry, gpa: std.mem.Allocator, parentDeclPath: []const u8, name: []const u8) !?[]const u8 {
        const key = try declSegmentKey(gpa, parentDeclPath, name);
        defer gpa.free(key);
        return self.declSegments.get(key);
    }
};

/// Joins `parentDeclPath` and `name` with a NUL byte, which can never
/// appear in either, so the pair maps to one unambiguous map key.
fn declSegmentKey(gpa: std.mem.Allocator, parentDeclPath: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}\x00{s}", .{ parentDeclPath, name });
}

/// Builds `sections`' `Registry`. Also walks into every decl's own
/// children (whatever `--split item`'s recursion will later append
/// segments onto) so two sibling decls whose names only differ by
/// case — a real collision on a case-insensitive filesystem — are
/// resolved once, up front, the same way two files already are.
fn buildRegistry(gpa: std.mem.Allocator, sections: []const model.Section, fmt: Format, opts: options.Options) !Registry {
    var reg = Registry{ .slugs = std.StringHashMap([]const u8).init(gpa), .declSegments = std.StringHashMap([]const u8).init(gpa) };
    errdefer reg.deinit(gpa);
    if (model.hasFileLabels(sections)) {
        try buildRegistryLevel(gpa, sections, "", opts, &reg);
        for (sections) |section| {
            try buildDeclSegments(gpa, section.children, reg.slugFor(section.fileLabel), fmt, &reg);
        }
    } else {
        try buildDeclSegments(gpa, sections, "", fmt, &reg);
    }
    return reg;
}

/// Resolves sibling decls under `parentDeclPath` into unique,
/// case-insensitively-safe path segments (matching how `--split item`
/// pairs a folder's `index.html` alongside sibling pages, and how most
/// filesystems — Windows always, macOS by default — collapse names
/// differing only by case), then recurses into each decl's own
/// children with its resolved path as the new parent.
fn buildDeclSegments(gpa: std.mem.Allocator, siblings: []const model.Section, parentDeclPath: []const u8, fmt: Format, reg: *Registry) !void {
    if (siblings.len == 0) return;

    var claimedLower = std.StringHashMap(void).init(gpa);
    defer {
        var it = claimedLower.iterator();
        while (it.next()) |e| gpa.free(@constCast(e.key_ptr.*));
        claimedLower.deinit();
    }

    for (siblings) |s| {
        const base = try model.filenameSegment(gpa, s.name);
        defer gpa.free(base);

        var candidate: []const u8 = base;
        var owned: ?[]u8 = null;
        defer if (owned) |o| gpa.free(o);

        var outputLower = try outputNameLower(gpa, candidate, s.hasChildren, fmt);
        defer gpa.free(outputLower);

        var n: usize = 2;
        while (claimedLower.contains(outputLower)) : (n += 1) {
            if (owned) |o| gpa.free(o);
            owned = try std.fmt.allocPrint(gpa, "{s}-{d}", .{ base, n });
            candidate = owned.?;
            gpa.free(outputLower);
            outputLower = try outputNameLower(gpa, candidate, s.hasChildren, fmt);
        }

        try claimedLower.put(outputLower, {});
        outputLower = &.{};

        const key = try declSegmentKey(gpa, parentDeclPath, s.name);
        errdefer gpa.free(key);
        try reg.declSegments.put(key, try gpa.dupe(u8, candidate));

        const childParentPath = if (parentDeclPath.len == 0)
            try gpa.dupe(u8, candidate)
        else
            try std.fmt.allocPrint(gpa, "{s}/{s}", .{ parentDeclPath, candidate });
        defer gpa.free(childParentPath);
        try buildDeclSegments(gpa, s.children, childParentPath, fmt, reg);
    }
}

/// Lowercased form of what `segment` actually becomes on disk — a
/// folder (`segment/`) if `hasChildren`, otherwise a flat file
/// (`segment<ext>`) — so two siblings only collide when their real
/// output names would, not merely when their bare names match.
fn outputNameLower(gpa: std.mem.Allocator, segment: []const u8, hasChildren: bool, fmt: Format) ![]u8 {
    const named = if (hasChildren)
        try std.fmt.allocPrint(gpa, "{s}/", .{segment})
    else
        try std.fmt.allocPrint(gpa, "{s}{s}", .{ segment, fmt.ext() });
    defer gpa.free(named);
    return std.ascii.allocLowerString(gpa, named);
}

/// Resolves every file's slug at one directory level, then recurses.
/// Two passes over this level's `--tree` grouping: first every real
/// subdirectory claims its own name (so a file's slug can never
/// silently steal one), then every file's candidate slug is checked
/// against what's claimed — falling back to the `.zig`-suffixed form,
/// then a numbered suffix, until it's unique — and claimed in turn.
fn buildRegistryLevel(gpa: std.mem.Allocator, sections: []const model.Section, dirPath: []const u8, opts: options.Options, reg: *Registry) !void {
    const sorted = try gpa.dupe(model.Section, sections);
    defer gpa.free(sorted);
    model.sortByFileLabelOrder(sorted, toDirOrder(opts.dirOrder));
    const prefixLen = if (dirPath.len == 0) 0 else dirPath.len + 1;

    var claimed = std.StringHashMap(void).init(gpa);
    defer {
        var it = claimed.iterator();
        while (it.next()) |e| gpa.free(@constCast(e.key_ptr.*));
        claimed.deinit();
    }

    const LevelCtx = struct {
        gpa: std.mem.Allocator,
        opts: options.Options,
        reg: *Registry,
        dirPath: []const u8,
        claimed: *std.StringHashMap(void),
    };
    var lctx = LevelCtx{ .gpa = gpa, .opts = opts, .reg = reg, .dirPath = dirPath, .claimed = &claimed };

    const ClaimCbs = struct {
        fn onDir(c: *LevelCtx, name: []const u8, _: []const model.Section) !void {
            try c.claimed.put(try c.gpa.dupe(u8, name), {});
        }
        fn onLeaf(_: *LevelCtx, _: model.Section) !void {}
    };
    try model.forEachDirGroup(sorted, prefixLen, &lctx, ClaimCbs.onDir, ClaimCbs.onLeaf);

    const ResolveCbs = struct {
        fn onDir(c: *LevelCtx, name: []const u8, children: []const model.Section) !void {
            const safeName = try model.avoidWindowsReservedName(c.gpa, try c.gpa.dupe(u8, name));
            defer c.gpa.free(safeName);
            const childDirPath = if (c.dirPath.len == 0)
                try c.gpa.dupe(u8, safeName)
            else
                try std.fmt.allocPrint(c.gpa, "{s}/{s}", .{ c.dirPath, safeName });
            defer c.gpa.free(childDirPath);
            try buildRegistryLevel(c.gpa, children, childDirPath, c.opts, c.reg);
        }
        fn onLeaf(c: *LevelCtx, s: model.Section) !void {
            const base = labelBasename(s.fileLabel);
            var candidate: []const u8 = if (c.opts.extUrls) base else model.stripZigExt(base);
            var owned: ?[]u8 = try model.avoidWindowsReservedName(c.gpa, try c.gpa.dupe(u8, candidate));
            if (!std.mem.eql(u8, owned.?, candidate)) candidate = owned.?;
            defer if (owned) |o| c.gpa.free(o);

            if (c.claimed.contains(candidate) and !std.mem.eql(u8, candidate, base)) {
                candidate = base; // fall back to keeping the extension
            }
            var n: usize = 2;
            while (c.claimed.contains(candidate)) : (n += 1) {
                if (owned) |o| c.gpa.free(o);
                owned = try std.fmt.allocPrint(c.gpa, "{s}-{d}", .{ base, n });
                candidate = owned.?;
            }

            try c.claimed.put(try c.gpa.dupe(u8, candidate), {});

            const fullSlug = if (c.dirPath.len == 0)
                try c.gpa.dupe(u8, candidate)
            else
                try std.fmt.allocPrint(c.gpa, "{s}/{s}", .{ c.dirPath, candidate });
            try c.reg.slugs.put(try c.gpa.dupe(u8, s.fileLabel), fullSlug);
        }
    };
    try model.forEachDirGroup(sorted, prefixLen, &lctx, ResolveCbs.onDir, ResolveCbs.onLeaf);
}

/// `--dirurls off`, `--split item`, HTML only: a file's own page is a
/// flat sibling file, but its decls (if it has any) still live in a
/// same-named folder with no `index.html` of its own — visiting that
/// bare folder directly would show a raw directory listing on most
/// static hosts. Drops a tiny meta-refresh stub there pointing at the
/// file's real page instead. Markdown has no browser-rendering
/// concept to redirect with (and the stub only helps when a real
/// webserver is serving the output), so this is HTML-only, best
/// effort. `sections` is the flat list of every file in the tree
/// (`tree.sections` — already flat regardless of nesting depth;
/// directory structure lives in each entry's own `fileLabel`).
fn writeOrphanRedirects(ctx: Ctx, pages: *std.ArrayList(Page), sections: []const model.Section) !void {
    if (ctx.fmt != .html or ctx.opts.split != .item) return;
    const gpa = ctx.gpa;
    for (sections) |section| {
        if (section.kind != .file or section.children.len == 0) continue;

        const flatPath = try pageFilename(gpa, ctx.fmt, section, "", ctx.opts, ctx.registry);
        defer gpa.free(flatPath);
        const folder = ctx.registry.slugFor(section.fileLabel);
        const stubPath = try std.fmt.allocPrint(gpa, "{s}/index.html", .{folder});
        defer gpa.free(stubPath);
        const target = try model.relativeHref(gpa, stubPath, flatPath, false);
        defer gpa.free(target);

        const contents = try std.fmt.allocPrint(gpa,
            \\<!DOCTYPE html>
            \\<html><head><meta charset="utf-8"><meta http-equiv="refresh" content="0; url={s}"></head>
            \\<body>Redirecting to <a href="{s}">{s}</a>.</body></html>
            \\
        , .{ target, target, section.name });
        try pages.append(gpa, .{ .filename = try gpa.dupe(u8, stubPath), .contents = contents });
    }
}

/// Output-relative path for a section's own page:
/// - file-kind: its registered slug (`Registry.slugFor`), as
///   `<slug>/index<ext>` (`opts.dirUrls`) or `<slug><ext>` (flat).
/// - item-kind: `ownDeclPath` *is* this decl's full path already —
///   built by the caller (`writeNode`'s `--split item` recursion) as
///   its owning file's folder plus one case-preserved segment per
///   level of decl nesting, e.g. `fuzzer.zig/Input/deinit`. Based on
///   `section.hasChildren`, not `children.len` — the source item may
///   have nested members even under `--recursive off`, where
///   `children` stays empty but the page still needs a folder for
///   consistency. A leaf becomes `ownDeclPath<ext>`; one with
///   children of its own becomes a folder, `ownDeclPath/index<ext>`, always —
///   regardless of `opts.dirUrls`, which only decides where the
///   *file's own* page goes — since its children need somewhere under
///   it to live either way.
fn pageFilename(gpa: std.mem.Allocator, fmt: Format, section: model.Section, ownDeclPath: []const u8, opts: options.Options, registry: Registry) ![]u8 {
    if (section.kind == .file) {
        const slug = registry.slugFor(section.fileLabel);
        if (opts.dirUrls) return std.fmt.allocPrint(gpa, "{s}/{s}", .{ slug, fmt.indexFilename() });
        return std.fmt.allocPrint(gpa, "{s}{s}", .{ slug, fmt.ext() });
    }
    if (section.hasChildren) return std.fmt.allocPrint(gpa, "{s}/{s}", .{ ownDeclPath, fmt.indexFilename() });
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ ownDeclPath, fmt.ext() });
}

/// Builds `parentDeclPath`'s child path for `name`. Prefers the
/// already-resolved, sibling-collision-safe segment `registry` worked
/// out up front; falls back to computing one directly only when the
/// registry has none (single-page mode, which builds no registry at
/// all). Used both for a top-level decl (`parentDeclPath` = its owning
/// file's folder, or `""` for single-file input) and for each level of
/// nesting under a decl with its own children.
fn appendDeclPathSegment(gpa: std.mem.Allocator, parentDeclPath: []const u8, name: []const u8, registry: Registry) ![]u8 {
    if (try registry.declSegmentFor(gpa, parentDeclPath, name)) |segment| {
        if (parentDeclPath.len == 0) return gpa.dupe(u8, segment);
        return std.fmt.allocPrint(gpa, "{s}/{s}", .{ parentDeclPath, segment });
    }
    const segment = try model.filenameSegment(gpa, name);
    defer gpa.free(segment);
    if (parentDeclPath.len == 0) return gpa.dupe(u8, segment);
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ parentDeclPath, segment });
}

/// Output-relative path for a directory's own page: `<dirPath>/index<ext>`.
fn dirPageFilename(gpa: std.mem.Allocator, fmt: Format, dirPath: []const u8) ![]u8 {
    if (dirPath.len == 0) return gpa.dupe(u8, fmt.indexFilename());
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ dirPath, fmt.indexFilename() });
}

/// Builds the chain of directory-level breadcrumb ancestors for `dirPath`.
fn ancestorsFromDirPath(gpa: std.mem.Allocator, fmt: Format, dirPath: []const u8) ![]Ancestor {
    if (dirPath.len == 0) return &.{};

    var out: std.ArrayList(Ancestor) = .empty;
    errdefer {
        for (out.items) |a| {
            gpa.free(a.name);
            gpa.free(a.target);
        }
        out.deinit(gpa);
    }

    var start: usize = 0;
    var i: usize = 0;
    while (i <= dirPath.len) : (i += 1) {
        if (i == dirPath.len or dirPath[i] == '/') {
            const segment = dirPath[start..i];
            const name = try std.fmt.allocPrint(gpa, "{s}/", .{segment});
            const target = try dirPageFilename(gpa, fmt, dirPath[0..i]);
            try out.append(gpa, Ancestor{ .name = name, .target = target });
            start = i + 1;
        }
    }

    return out.toOwnedSlice(gpa);
}

/// Frees a slice returned by `ancestorsFromDirPath`.
fn freeDirAncestors(gpa: std.mem.Allocator, ancestors: []const Ancestor) void {
    if (ancestors.len == 0) return;
    for (ancestors) |a| {
        gpa.free(a.name);
        gpa.free(a.target);
    }
    gpa.free(@constCast(ancestors));
}

/// Last `/`-separated segment of a `fileLabel` (always `/`-joined by
/// construction, unlike a real OS path — so this splits on a literal
/// `/`, not `std.fs.path.basename`, which would use the host's native
/// separator and misbehave on Windows).
fn labelBasename(fileLabel: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, fileLabel, '/')) |slash| fileLabel[slash + 1 ..] else fileLabel;
}

/// Directory portion of a file's `fileLabel`.
fn dirPortion(fileLabel: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, fileLabel, '/')) |slash| fileLabel[0..slash] else "";
}

/// The `{index}` content for any page with a section index — a
/// split-mode root/directory page, or the one single-page-mode page.
/// `linkOut` is the one thing that changes: `true` (split mode) links
/// a directory group and each decl out to its own page; `false`
/// (single-page mode, nothing else to link to) labels a directory
/// group without a link and links each decl to its own in-page anchor,
/// recursing into its children as nested anchors right there.
fn writeSectionIndex(gpa: std.mem.Allocator, fmt: Format, writer: *std.Io.Writer, sections: []const model.Section, dirPath: []const u8, ownPath: []const u8, opts: options.Options, registry: Registry, linkOut: bool) !void {
    if (opts.tree and model.hasFileLabels(sections)) {
        const sorted = try gpa.dupe(model.Section, sections);
        defer gpa.free(sorted);
        model.sortByFileLabelOrder(sorted, toDirOrder(opts.dirOrder));
        const prefixLen = if (dirPath.len == 0) 0 else dirPath.len + 1;
        switch (fmt) {
            .html => {
                var ctx = HtmlTreeCtx{ .gpa = gpa, .writer = writer, .dirPath = std.ArrayList(u8).empty, .ownPath = ownPath, .opts = opts, .registry = registry, .linkOut = linkOut };
                defer ctx.dirPath.deinit(gpa);
                if (dirPath.len > 0) try ctx.dirPath.appendSlice(gpa, dirPath);
                try writer.writeAll("<ul>\n");
                try model.writeIndexTree(sorted, prefixLen, &ctx, htmlTreeOnDir, htmlTreeOnLeaf, htmlTreeOnDirEnd);
                try writer.writeAll("</ul>\n");
            },
            .md => {
                var ctx = MdTreeCtx{ .gpa = gpa, .writer = writer, .depth = 0, .dirPath = std.ArrayList(u8).empty, .ownPath = ownPath, .opts = opts, .registry = registry, .linkOut = linkOut };
                defer ctx.dirPath.deinit(gpa);
                if (dirPath.len > 0) try ctx.dirPath.appendSlice(gpa, dirPath);
                try model.writeIndexTree(sorted, prefixLen, &ctx, mdTreeOnDir, mdTreeOnLeaf, mdTreeOnDirEnd);
            },
        }
    } else if (linkOut) {
        try writePageLinkList(gpa, fmt, writer, sections, ownPath, "", opts, registry);
    } else {
        try writeInPageIndex(gpa, fmt, writer, sections, 0, opts.collapse == .all);
    }
}

const HtmlTreeCtx = struct {
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    dirPath: std.ArrayList(u8),
    ownPath: []const u8,
    opts: options.Options,
    registry: Registry,
    linkOut: bool,
};

fn htmlTreeOnDir(ctx: *HtmlTreeCtx, name: []const u8) !void {
    if (ctx.dirPath.items.len > 0) try ctx.dirPath.append(ctx.gpa, '/');
    try ctx.dirPath.appendSlice(ctx.gpa, name);

    if (!ctx.linkOut) {
        // Single-page mode: nowhere to link a directory group to.
        if (ctx.opts.collapse == .none) {
            try ctx.writer.print("<li><span class=\"index-dir\">{s}/</span>\n<ul>\n", .{name});
        } else {
            try ctx.writer.print("<li><details><summary class=\"index-dir\">{s}/</summary>\n<ul>\n", .{name});
        }
        return;
    }

    const filename = try dirPageFilename(ctx.gpa, .html, ctx.dirPath.items);
    defer ctx.gpa.free(filename);
    const href = try model.relativeHref(ctx.gpa, ctx.ownPath, filename, ctx.opts.prettyUrls);
    defer ctx.gpa.free(href);
    if (ctx.opts.collapse == .none) {
        try ctx.writer.print("<li><a class=\"index-dir\" href=\"{s}\">{s}/</a>\n<ul>\n", .{ href, name });
    } else {
        try ctx.writer.print("<li><details><summary><span>{s}/</span></summary>\n<a class=\"index-dir\" href=\"{s}\">{s}/</a>\n<ul>\n", .{ name, href, name });
    }
}

fn htmlTreeOnDirEnd(ctx: *HtmlTreeCtx) !void {
    if (ctx.opts.collapse == .none) {
        try ctx.writer.writeAll("</ul></li>\n");
    } else {
        try ctx.writer.writeAll("</ul></details></li>\n");
    }
    if (std.mem.lastIndexOfScalar(u8, ctx.dirPath.items, '/')) |i| {
        ctx.dirPath.items.len = i;
    } else {
        ctx.dirPath.items.len = 0;
    }
}

fn htmlTreeOnLeaf(ctx: *HtmlTreeCtx, s: model.Section) !void {
    if (!ctx.linkOut) {
        // Single-page mode: this decl lives on this same page — link
        // to its own anchor and inline its children the same way
        // `writeInPageIndex` would.
        const slug = try s.anchorSlug(ctx.gpa);
        defer ctx.gpa.free(slug);
        try writeIndexItemOpen(ctx.gpa, ctx.writer, s);
        try ctx.writer.print("<a href=\"#{s}\">{s}</a>", .{ slug, s.name });
        try writeInPageIndex(ctx.gpa, .html, ctx.writer, s.children, 1, ctx.opts.collapse == .all);
        try ctx.writer.writeAll("</li>\n");
        return;
    }

    const filename = try pageFilename(ctx.gpa, .html, s, "", ctx.opts, ctx.registry);
    defer ctx.gpa.free(filename);
    const href = try model.relativeHref(ctx.gpa, ctx.ownPath, filename, ctx.opts.prettyUrls);
    defer ctx.gpa.free(href);
    try writeIndexItemOpen(ctx.gpa, ctx.writer, s);
    try ctx.writer.print("<a href=\"{s}\">{s}</a></li>\n", .{ href, s.name });
}

const MdTreeCtx = struct {
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    depth: usize,
    dirPath: std.ArrayList(u8),
    ownPath: []const u8,
    opts: options.Options,
    registry: Registry,
    linkOut: bool,
};

fn mdTreeOnDir(ctx: *MdTreeCtx, name: []const u8) !void {
    if (ctx.dirPath.items.len > 0) try ctx.dirPath.append(ctx.gpa, '/');
    try ctx.dirPath.appendSlice(ctx.gpa, name);

    try writeRepeated(ctx.writer, ' ', ctx.depth * 2);
    if (!ctx.linkOut) {
        // Single-page mode: nowhere to link a directory group to.
        try ctx.writer.print("- **{s}/**\n", .{name});
    } else {
        const filename = try dirPageFilename(ctx.gpa, .md, ctx.dirPath.items);
        defer ctx.gpa.free(filename);
        const href = try model.relativeHref(ctx.gpa, ctx.ownPath, filename, false);
        defer ctx.gpa.free(href);
        try ctx.writer.print("- [{s}/]({s})\n", .{ name, href });
    }
    ctx.depth += 1;
}

fn mdTreeOnDirEnd(ctx: *MdTreeCtx) !void {
    ctx.depth -= 1;
    if (std.mem.lastIndexOfScalar(u8, ctx.dirPath.items, '/')) |i| {
        ctx.dirPath.items.len = i;
    } else {
        ctx.dirPath.items.len = 0;
    }
}

fn mdTreeOnLeaf(ctx: *MdTreeCtx, s: model.Section) !void {
    if (!ctx.linkOut) {
        // Single-page mode: this decl lives on this same page —
        // anchor via `anchorSlugMd` (the same slug the MD renderer
        // auto-generates from its `## {path}` heading) and inline its
        // children the same way `writeInPageIndex` would.
        const slug = try s.anchorSlugMd(ctx.gpa);
        defer ctx.gpa.free(slug);
        try writeRepeated(ctx.writer, ' ', ctx.depth * 2);
        const target = try std.fmt.allocPrint(ctx.gpa, "#{s}", .{slug});
        defer ctx.gpa.free(target);
        try writeMdIndexLine(ctx.gpa, ctx.writer, s, s.name, target);
        try writeInPageIndex(ctx.gpa, .md, ctx.writer, s.children, ctx.depth + 1, false);
        return;
    }

    const filename = try pageFilename(ctx.gpa, .md, s, "", ctx.opts, ctx.registry);
    defer ctx.gpa.free(filename);
    const href = try model.relativeHref(ctx.gpa, ctx.ownPath, filename, false);
    defer ctx.gpa.free(href);
    try writeRepeated(ctx.writer, ' ', ctx.depth * 2);
    try writeMdIndexLine(ctx.gpa, ctx.writer, s, s.name, href);
}

/// Flat list of links to each section's own page (non-tree split-mode
/// index content, and `--split item`'s children-link list).
/// `fromPath` is this page's output path (hrefs are relative to it);
/// `parentDeclPath` is the *current* page's own decl path (`""` for a
/// file-kind list) — each listed section's own page path is built
/// from it via `appendDeclPathSegment`, one level deeper.
fn writePageLinkList(gpa: std.mem.Allocator, fmt: Format, writer: *std.Io.Writer, sections: []const model.Section, fromPath: []const u8, parentDeclPath: []const u8, opts: options.Options, registry: Registry) !void {
    if (sections.len == 0) return;
    if (fmt == .html) try writer.writeAll("<ul>\n");
    for (sections) |s| {
        const ownDeclPath = try appendDeclPathSegment(gpa, parentDeclPath, s.name, registry);
        defer gpa.free(ownDeclPath);
        const target = try pageFilename(gpa, fmt, s, ownDeclPath, opts, registry);
        defer gpa.free(target);
        const href = try model.relativeHref(gpa, fromPath, target, fmt == .html and opts.prettyUrls);
        defer gpa.free(href);
        switch (fmt) {
            .html => {
                try writeIndexItemOpen(gpa, writer, s);
                try writer.print("<a href=\"{s}\">{s}</a></li>\n", .{ href, s.name });
            },
            .md => try writeMdIndexLine(gpa, writer, s, s.name, href),
        }
    }
    if (fmt == .html) try writer.writeAll("</ul>\n");
}

/// In-page nested index for a `--split file` page's own decl tree, or
/// (via `writeSectionIndex`'s `linkOut = false` path) single-page
/// mode's whole index — every decl, at every nesting depth, as a jump
/// link to its own anchor. `collapsed` (HTML only, `--collapse all`)
/// wraps each non-empty child list in `<details>`.
fn writeInPageIndex(gpa: std.mem.Allocator, fmt: Format, writer: *std.Io.Writer, sections: []const model.Section, depth: usize, collapsed: bool) !void {
    switch (fmt) {
        .html => {
            if (depth == 0 and sections.len == 0) return;
            try writer.writeAll("<ul>\n");
            for (sections) |s| {
                const slug = try s.anchorSlug(gpa);
                defer gpa.free(slug);
                try writeIndexItemOpen(gpa, writer, s);
                try writer.print("<a href=\"#{s}\">{s}</a>", .{ slug, s.name });
                if (s.children.len > 0) {
                    if (collapsed) {
                        try writer.print("\n<details><summary>{s}</summary>\n", .{s.name});
                        try writeInPageIndex(gpa, fmt, writer, s.children, depth + 1, collapsed);
                        try writer.writeAll("</details>");
                    } else {
                        try writeInPageIndex(gpa, fmt, writer, s.children, depth + 1, collapsed);
                    }
                }
                try writer.writeAll("</li>\n");
            }
            try writer.writeAll("</ul>\n");
        },
        .md => {
            for (sections) |s| {
                const slug = try s.anchorSlugMd(gpa);
                defer gpa.free(slug);
                try writeRepeated(writer, ' ', depth * 2);
                const target = try std.fmt.allocPrint(gpa, "#{s}", .{slug});
                defer gpa.free(target);
                try writeMdIndexLine(gpa, writer, s, s.path, target);
                try writeInPageIndex(gpa, fmt, writer, s.children, depth + 1, collapsed);
            }
        },
    }
}

// ---------------------------------------------------------------
// Below: the leaf variable-to-string mapping for one `htmldoc`/`mddoc`
// page or one `htmlsec`/`mdsec` section, per `template.zig`'s default-
// template variable reference. Everything above owns structure (what pages
// exist, how sections nest, filenames); this part only turns a
// `Section` into template values.
// ---------------------------------------------------------------

/// Explicit, exhaustive mapping from `options.DirOrder` to
/// `model.DirOrder` — no reliance on the two enums sharing tag order,
/// since `model.zig` deliberately doesn't import `options.zig`.
fn toDirOrder(order: options.DirOrder) model.DirOrder {
    return switch (order) {
        .first => .first,
        .last => .last,
        .alpha => .alpha,
    };
}

/// Stable, lowercase, CSS-class-safe label for a section, exposed to
/// templates as `{kind}`. A `--filetypes` raw file (`section.raw`) gets
/// `other-<ext>` (e.g. `other-md`) instead of plain `file`, so it's
/// visually and CSS-distinguishable from a `.zig` file's own wrapper
/// section — both share `Kind.file`, only `raw` tells them apart.
/// `ext` comes from `sourceFile` (always set for a raw section), not a
/// separate field, so it can't drift out of sync with the file. Falls
/// back to plain `other` if `sourceFile` has no `.ext` — should not
/// happen in practice (`--filetypes` only matches files with a matched
/// extension), but keeps this total. Allocates only for the raw case;
/// non-raw sections get a `'static` literal, same as before.
fn kindLabel(gpa: std.mem.Allocator, section: model.Section) ![]const u8 {
    if (section.raw) {
        const base = std.fs.path.basename(section.sourceFile);
        if (std.mem.lastIndexOfScalar(u8, base, '.')) |i| {
            return std.fmt.allocPrint(gpa, "other-{s}", .{base[i + 1 ..]});
        }
        return gpa.dupe(u8, "other");
    }
    return switch (section.kind) {
        .file => "file",
        .fn_decl => "fn",
        .var_decl => "var",
        .const_decl => "const",
        .struct_decl => "struct",
        .enum_decl => "enum",
        .union_decl => "union",
        .opaque_decl => "opaque",
        .directory => "directory",
    };
}

fn isPlainFileOrDir(section: model.Section) bool {
    return !section.raw and (section.kind == .file or section.kind == .directory);
}

/// Writes an index `<li>`'s opening tag: `item-<kind>` class always,
/// plus a `<span class="prefix">` label for anything but a plain file/directory.
fn writeIndexItemOpen(gpa: std.mem.Allocator, writer: *std.Io.Writer, section: model.Section) !void {
    const label = try kindLabel(gpa, section);
    defer if (section.raw) gpa.free(label);
    if (isPlainFileOrDir(section)) {
        try writer.print("<li class=\"item-{s}\">", .{label});
        return;
    }
    try writer.print("<li class=\"item-{s}\"><span class=\"prefix\">{s}</span> ", .{ label, label });
}

/// Markdown index-item kind prefix, e.g. `fn `. Empty for a plain
/// file/directory. Always returns caller-owned memory (freed by the
/// caller), even though the empty-string and non-empty cases go
/// through different allocations internally.
fn mdIndexPrefix(gpa: std.mem.Allocator, section: model.Section) ![]const u8 {
    if (isPlainFileOrDir(section)) return gpa.dupe(u8, "");
    const label = try kindLabel(gpa, section);
    if (section.raw) return label;
    return gpa.dupe(u8, label);
}

/// Writes one Markdown index/link-list entry: `- <prefix> [label](target)`,
/// omitting the prefix when the section has none.
fn writeMdIndexLine(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    section: model.Section,
    label: []const u8,
    target: []const u8,
) !void {
    const prefix = try mdIndexPrefix(gpa, section);
    defer gpa.free(prefix);
    if (prefix.len > 0) {
        try writer.print("- {s} [{s}]({s})\n", .{ prefix, label, target });
    } else {
        try writer.print("- [{s}]({s})\n", .{ label, target });
    }
}

fn writeRepeated(writer: *std.Io.Writer, byte: u8, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) try writer.writeByte(byte);
}

/// HTML-escapes `<`, `>`, and `&`.
fn writeEscapedHtml(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '&' => try writer.writeAll("&amp;"),
            else => try writer.writeByte(c),
        }
    }
}

/// Renders a doc comment's markdown body to HTML via the vendored
/// parser. Caller owns the returned slice.
fn markdownToHtml(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var parser = try markdown.Parser.init(gpa);
    defer parser.deinit();

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| try parser.feedLine(line);

    var doc = try parser.endInput();
    defer doc.deinit(gpa);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try doc.render(&aw.writer);
    return aw.toOwnedSlice();
}

/// Everything needed to render one `htmlsec`/`mdsec` section.
const SectionVars = struct {
    id: []const u8, // `id="..."` value (HTML) or anchor slug text (MD), no surrounding quotes/attr, or ""
    name: []const u8, // `section.name` (HTML) or `path` + trailing `\n` (MD) — the MD form doubles as heading text so renderers auto-generate matching anchors
    kind: []const u8, // e.g. "file", "fn", "struct", "other-md" — see model.Kind / kindLabel
    kindOwned: bool, // true only for a raw (`--filetypes`) section's allocated "other-<ext>" label
    path: []const u8, // per-segment links (HTML `<a>`, MD `[text](#anchor)`, MD trailing `\n` if non-empty), or plain text if !opts.index
    sig: []const u8, // syntax-highlighted markup (HTML) or `` `sig`\n\n `` (MD), wrapped by the template's format attr, or ""
    fileHeading: []const u8, // "File" (subheading text, wrapped by the template's format attr) or ""
    location: []const u8, // location markup (HTML) or "path:line" text (MD), wrapped by the template's format attr, or ""
    comment: []const u8, // rendered markdown doc comment (HTML) or raw text with trailing `\n` (MD), or ""
    codeHeading: []const u8, // "Code" (subheading text, wrapped by the template's format attr) or ""
    source: []const u8, // full <details>/<pre> block (HTML) or fenced code block (MD), or ""

    pub fn deinit(self: *SectionVars, gpa: std.mem.Allocator) void {
        if (self.id.len > 0) gpa.free(self.id);
        if (self.kindOwned) gpa.free(self.kind);
        gpa.free(self.name);
        gpa.free(self.path);
        if (self.sig.len > 0) gpa.free(self.sig);
        if (self.location.len > 0) gpa.free(self.location);
        if (self.comment.len > 0) gpa.free(self.comment);
        if (self.source.len > 0) gpa.free(self.source);
    }
};

/// Owned copy of `value` for an MD template var, with a trailing `\n`
/// appended unless `value` is empty or already ends in one. MD
/// templates put nothing after a var but its own newline, so an empty
/// value contributes no stray blank line. Caller frees.
fn locationDirPortion(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| return path[0 .. slash + 1];
    return "";
}

/// Builds every variable for one section, in `fmt`'s form only — the
/// two formats are never rendered from the same call, so there's no
/// need to build both. `headingLevel` is currently unused in the
/// default templates (heading depth is hardcoded at `##` for
/// sections, `###` for children, etc.) but is kept as a parameter so
/// the renderers' recursive calls can track depth for potential
/// future use. `linked` controls whether `{id}`/`{path}` produce real
/// anchors and links (true) or bare text (false) — pass `opts.index`.
/// `dirHref` is an href (relative to this page) to `locPrefix`'s
/// target page, or `""` if nothing links there (single-page mode,
/// `--tree off`, or a root-level file with `--locfull off`).
/// `locPrefix` is the linked text shown before the bare filename in
/// `{location}` — a subdirectory's own path with a trailing `/`, or
/// (root-level file, `--locfull` on) the documented root's display
/// name. Always paired with `dirHref`: one non-empty iff the other is.
fn buildSectionVars(
    gpa: std.mem.Allocator,
    fmt: Format,
    section: model.Section,
    opts: options.Options,
    headingLevel: u8,
    linked: bool,
    dirHref: []const u8,
    locPrefix: []const u8,
) !SectionVars {
    _ = headingLevel; // depth tracking; not used by default templates

    var id: []const u8 = "";
    if (linked) {
        const slug = try section.anchorSlug(gpa);
        defer gpa.free(slug);
        id = try gpa.dupe(u8, slug);
    }

    var pathAw: std.Io.Writer.Allocating = .init(gpa);
    defer pathAw.deinit();
    if (section.kind != .file) {
        switch (fmt) {
            .html => {
                if (linked) {
                    try model.writePathLinks(gpa, &pathAw.writer, section.path);
                } else {
                    try writeEscapedHtml(&pathAw.writer, section.path);
                }
            },
            .md => {
                if (linked) {
                    try model.writePathLinksMd(gpa, &pathAw.writer, section.path);
                } else {
                    try pathAw.writer.writeAll(section.path);
                }
            },
        }
    }
    const path = try gpa.dupe(u8, pathAw.written());

    var sig: []const u8 = "";
    if (section.signature.len > 0) {
        switch (fmt) {
            .html => {
                var aw: std.Io.Writer.Allocating = .init(gpa);
                defer aw.deinit();
                const sentinelSig = try gpa.allocSentinel(u8, section.signature.len, 0);
                defer gpa.free(sentinelSig);
                @memcpy(sentinelSig, section.signature);
                try sources.writeTokens(&aw.writer, sentinelSig);
                sig = try gpa.dupe(u8, aw.written());
            },
            .md => sig = try std.fmt.allocPrint(gpa, "`{s}`\n\n", .{section.signature}),
        }
    }

    const showLine = opts.showLine and section.kind != .file;
    var fileHeading: []const u8 = "";
    var location: []const u8 = "";
    if (section.sourceFile.len > 0 and (opts.showFile or showLine)) {
        if (opts.subheadings) fileHeading = "File";
        // `dirHref`/`locPrefix` are paired: when set, locPrefix is the
        // linked text and sourceFileDirLen is how much of sourceFile
        // it already covers (0 for the root-locfull case, where
        // locPrefix is the root's name rather than a sourceFile
        // prefix — the whole leaf is still sourceFile's basename).
        const sourceFileDirLen = if (dirHref.len > 0) locationDirPortion(section.sourceFile).len else 0;
        const dirPart = if (dirHref.len > 0) locPrefix else "";
        const leafPart = section.sourceFile[sourceFileDirLen..];

        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        switch (fmt) {
            .html => {
                if (opts.showFile) {
                    if (dirPart.len > 0) {
                        try aw.writer.writeAll("<a href=\"");
                        try writeEscapedHtml(&aw.writer, dirHref);
                        try aw.writer.writeAll("\">");
                        try writeEscapedHtml(&aw.writer, dirPart);
                        try aw.writer.writeAll("</a>");
                    }
                    try writeEscapedHtml(&aw.writer, leafPart);
                }
                if (showLine) try aw.writer.print("<span class=\"src-ln\"><span>:</span><span>{d}</span></span>", .{section.sourceLine});
                if (section.raw) try aw.writer.print(" <span class=\"src-size\">({d} bytes)</span>", .{section.sizeBytes});
            },
            .md => {
                if (opts.showFile) {
                    if (dirPart.len > 0) try aw.writer.print("[{s}]({s})", .{ dirPart, dirHref });
                    try aw.writer.writeAll(leafPart);
                }
                if (opts.showFile and showLine) try aw.writer.writeAll(":");
                if (showLine) try aw.writer.print("{d}", .{section.sourceLine});
                if (section.raw) try aw.writer.print(" ({d} bytes)", .{section.sizeBytes});
            },
        }
        location = try gpa.dupe(u8, aw.written());
    }

    var comment: []const u8 = "";
    if (section.docComment.len > 0) {
        comment = switch (fmt) {
            .html => try markdownToHtml(gpa, section.docComment),
            .md => try gpa.dupe(u8, section.docComment),
        };
    }

    var codeHeading: []const u8 = "";
    var source: []const u8 = "";
    // A `.zig` file's own wrapper section (`kind == .file`, not `raw` —
    // that's `--filetypes`' non-`.zig` content, always governed by
    // `opts.source`) uses the independent `--filesource` mode instead
    // of the per-decl `--source` mode.
    const mode = if (section.kind == .file and !section.raw) opts.fileSource else opts.source;
    if (section.source.len > 0 and mode != .none) {
        if (opts.subheadings) codeHeading = "Code";
        switch (fmt) {
            .html => {
                var aw: std.Io.Writer.Allocating = .init(gpa);
                defer aw.deinit();
                try sources.write(gpa, &aw.writer, section.source, mode, section.raw);
                source = try gpa.dupe(u8, aw.written());
            },
            .md => {
                const fence = if (section.raw) "" else "zig";
                source = try std.fmt.allocPrint(gpa, "```{s}\n{s}\n```\n\n", .{ fence, section.source });
            },
        }
    }

    const kind = try kindLabel(gpa, section);
    const name = switch (fmt) {
        .html => try gpa.dupe(u8, section.name),
        // Doubles as the MD heading text, so it's `path` (not `name`)
        // — that's what makes renderers generate an anchor matching
        // `id` above. Used only inside `mdsec.tpl`'s own
        // `format="## {name}\n"}`, so it's left unpadded here.
        .md => try gpa.dupe(u8, section.path),
    };
    return .{
        .id = id,
        .name = name,
        .kind = kind,
        .kindOwned = section.raw,
        .path = path,
        .sig = sig,
        .fileHeading = fileHeading,
        .location = location,
        .comment = comment,
        .codeHeading = codeHeading,
        .source = source,
    };
}

/// Renders a single section against `tpl`'s variable slots, with no
/// recursion into children. Shared by `renderSection` (which adds
/// recursion) and item-page rendering (which puts each child on its
/// own page instead). `id` is offered to both formats' templates —
/// the default `mdsec` template just doesn't reference it.
fn renderOneSection(gpa: std.mem.Allocator, fmt: Format, tpl: []const u8, vars: SectionVars) ![]u8 {
    const padBlock: ?template.PadBlockFn = if (fmt == .md) template.padMdBlock else null;
    return template.render(gpa, tpl, &.{
        .{ .name = "id", .value = vars.id },
        .{ .name = "name", .value = vars.name },
        .{ .name = "kind", .value = vars.kind },
        .{ .name = "path", .value = vars.path },
        .{ .name = "sig", .value = vars.sig },
        .{ .name = "file-heading", .value = vars.fileHeading },
        .{ .name = "location", .value = vars.location },
        .{ .name = "comment", .value = vars.comment },
        .{ .name = "code-heading", .value = vars.codeHeading },
        .{ .name = "source", .value = vars.source },
    }, padBlock);
}

/// Renders one section (via `tpl` — `template.htmlSec`/`mdSec`
/// or a custom `--htmlsectpl`/`--mdsectpl` file's contents) and appends
/// the result, followed by all its children rendered the same way at
/// `headingLevel + 1`, to `out`. This is the "no `{children}` slot"
/// concatenation the section template relies on.
fn renderSection(
    gpa: std.mem.Allocator,
    fmt: Format,
    out: *std.ArrayList(u8),
    tpl: []const u8,
    section: model.Section,
    opts: options.Options,
    headingLevel: u8,
    linked: bool,
    dirHref: []const u8,
    locPrefix: []const u8,
) !void {
    var vars = try buildSectionVars(gpa, fmt, section, opts, headingLevel, linked, dirHref, locPrefix);
    defer vars.deinit(gpa);

    const rendered = try renderOneSection(gpa, fmt, tpl, vars);
    defer gpa.free(rendered);
    try out.appendSlice(gpa, rendered);

    for (section.children) |child| {
        try renderSection(gpa, fmt, out, tpl, child, opts, headingLevel + 1, linked, dirHref, locPrefix);
    }
}

/// Writes a breadcrumb trail up to (not including) the current page:
/// `<page-title-of-index-target> › <ancestor, if any> ›`. The
/// template's `{breadcrumb format="..."}` appends `{page-title}` (and
/// any trailing separator/whitespace) to complete the trail — see
/// `htmldoc.tpl`/`mddoc.tpl`. `indexLabel` is the *target page's own
/// title* — e.g. `"src/"` for a link to that directory's page, never
/// the project's `--title`/site name, since the link's text should
/// describe what it points to, not repeat the site name shown one
/// line above on every page already. `ancestors` is the chain from
/// outermost to innermost, each already carrying its own page's real
/// path (see `Ancestor`) — resolved to an href relative to `fromPath`
/// here, not re-derived from a `Section` guess.
fn writeBreadcrumbHtml(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    indexHref: []const u8,
    indexLabel: []const u8,
    ancestors: []const Ancestor,
    fromPath: []const u8,
    prettyUrls: bool,
) !void {
    try writer.print("<a href=\"{s}\">{s}</a>", .{ indexHref, indexLabel });
    for (ancestors) |a| {
        try writer.writeAll("<span class=\"breadcrumb-sep\">&rsaquo;</span>");
        const href = try model.relativeHref(gpa, fromPath, a.target, prettyUrls);
        defer gpa.free(href);
        try writer.print("<a href=\"{s}\">{s}</a>", .{ href, a.name });
    }
    try writer.writeAll("<span class=\"breadcrumb-sep\">&rsaquo;</span>");
}

/// Markdown twin of `writeBreadcrumbHtml`.
fn writeBreadcrumbMd(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    indexHref: []const u8,
    indexLabel: []const u8,
    ancestors: []const Ancestor,
    fromPath: []const u8,
) !void {
    try writer.print("[{s}]({s})", .{ indexLabel, indexHref });
    for (ancestors) |a| {
        const href = try model.relativeHref(gpa, fromPath, a.target, false);
        defer gpa.free(href);
        try writer.print(" &rsaquo; [{s}]({s})", .{ a.name, href });
    }
    try writer.writeAll(" &rsaquo; ");
}

fn testWrite(gpa: std.mem.Allocator, fmt: Format, tree: model.DocTree, title: []const u8, opts: options.Options) ![]Page {
    var progress: progress_mod.Progress = .{};
    return switch (fmt) {
        .html => write(gpa, .html, tree, title, opts, template.htmlDoc, template.htmlSec, &progress),
        .md => write(gpa, .md, tree, title, opts, template.mdDoc, template.mdSec, &progress),
    };
}

test "split item: single-file input's root index links match the decl's real page path" {
    const gpa = std.testing.allocator;

    const structSection = model.Section{
        .name = "Fuzzer",
        .path = "Fuzzer",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "fuzzer.zig",
        .sourceLine = 0,
        .kind = .struct_decl,
        .children = &.{},
        .fileLabel = "",
    };
    var sections = [_]model.Section{structSection};
    const tree = model.DocTree{ .moduleName = "fuzzer", .rootDocComment = null, .sections = &sections };

    const pages = try testWrite(gpa, .html, tree, "fuzzer", options.Options{ .split = .item, .tree = true, .extUrls = false, .dirUrls = true, .index = true });
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    var rootIndex: ?[]const u8 = null;
    var pathSet = std.StringHashMap(void).init(gpa);
    defer pathSet.deinit();
    for (pages) |p| {
        try pathSet.put(p.filename, {});
        if (std.mem.eql(u8, p.filename, "index.html")) rootIndex = p.contents;
    }
    try std.testing.expect(rootIndex != null);
    // The root index must link to a page that was actually written.
    try std.testing.expect(std.mem.indexOf(u8, rootIndex.?, "href=\"Fuzzer/index.html\"") != null or std.mem.indexOf(u8, rootIndex.?, "href=\"Fuzzer.html\"") != null);
}

test "split item: a file's root index link matches its decl's real (case-preserved) page path" {
    const gpa = std.testing.allocator;

    const structDecl = model.Section{
        .name = "Fuzzer",
        .path = "Fuzzer",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "fuzzer.zig",
        .sourceLine = 0,
        .kind = .struct_decl,
        .children = &.{},
        .fileLabel = "",
    };
    var declChildren = [_]model.Section{structDecl};
    const fileSection = model.Section{
        .name = "fuzzer.zig",
        .path = "fuzzer",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "fuzzer.zig",
        .sourceLine = 0,
        .kind = .file,
        .children = &declChildren,
        .fileLabel = "fuzzer.zig",
    };
    var sections = [_]model.Section{fileSection};
    const tree = model.DocTree{ .moduleName = "myproject", .rootDocComment = null, .sections = &sections };

    const pages = try testWrite(gpa, .html, tree, "myproject", options.Options{ .split = .item, .tree = true, .extUrls = false, .dirUrls = true, .index = true, .breadcrumb = false });
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    var writtenPaths = std.StringHashMap(void).init(gpa);
    defer writtenPaths.deinit();
    for (pages) |p| try writtenPaths.put(p.filename, {});
    // The struct's own page must have been written with case preserved.
    try std.testing.expect(writtenPaths.contains("fuzzer/Fuzzer.html"));

    var fileIndex: ?[]const u8 = null;
    for (pages) |p| {
        if (std.mem.eql(u8, p.filename, "fuzzer/index.html")) fileIndex = p.contents;
    }
    try std.testing.expect(fileIndex != null);
    // Whatever href the file's own index page emits for "Fuzzer" must
    // point at a page that was actually written.
    const hrefNeedle = "<a href=\"";
    const hrefStart = std.mem.indexOf(u8, fileIndex.?, hrefNeedle).? + hrefNeedle.len;
    const hrefEnd = std.mem.indexOfScalarPos(u8, fileIndex.?, hrefStart, '"').?;
    const href = fileIndex.?[hrefStart..hrefEnd];
    const resolved = try resolveTestHref(gpa, "fuzzer/index.html", href);
    defer gpa.free(resolved);
    try std.testing.expect(writtenPaths.contains(resolved) or std.mem.eql(u8, resolved, "Fuzzer/index.html"));
}

test "split item: sibling decls whose names differ only by case get distinct pages, resolved consistently between the file page and the actual write" {
    const gpa = std.testing.allocator;

    const fnDecl = model.Section{
        .name = "fuzzer",
        .path = "fuzzer",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "fuzzer.zig",
        .sourceLine = 0,
        .kind = .fn_decl,
        .children = &.{},
        .fileLabel = "",
    };
    const structDecl = model.Section{
        .name = "Fuzzer",
        .path = "Fuzzer",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "fuzzer.zig",
        .sourceLine = 0,
        .kind = .struct_decl,
        .children = &.{},
        .fileLabel = "",
    };
    var declChildren = [_]model.Section{ fnDecl, structDecl };
    const fileSection = model.Section{
        .name = "fuzzer.zig",
        .path = "fuzzer",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "fuzzer.zig",
        .sourceLine = 0,
        .kind = .file,
        .children = &declChildren,
        .fileLabel = "fuzzer.zig",
    };
    var sections = [_]model.Section{fileSection};
    const tree = model.DocTree{ .moduleName = "myproject", .rootDocComment = null, .sections = &sections };

    const pages = try testWrite(gpa, .html, tree, "myproject", options.Options{ .split = .item, .tree = true, .extUrls = false, .dirUrls = true, .index = true, .breadcrumb = false });
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    var lowerWritten = std.StringHashMap(void).init(gpa);
    defer {
        var it = lowerWritten.iterator();
        while (it.next()) |e| gpa.free(@constCast(e.key_ptr.*));
        lowerWritten.deinit();
    }
    var writtenPaths = std.StringHashMap(void).init(gpa);
    defer writtenPaths.deinit();
    for (pages) |p| {
        try writtenPaths.put(p.filename, {});
        const lower = try std.ascii.allocLowerString(gpa, p.filename);
        // Two written pages must never collapse to the same path on a
        // case-insensitive filesystem.
        try std.testing.expect(!lowerWritten.contains(lower));
        try lowerWritten.put(lower, {});
    }

    var fileIndex: ?[]const u8 = null;
    for (pages) |p| {
        if (std.mem.eql(u8, p.filename, "fuzzer/index.html")) fileIndex = p.contents;
    }
    try std.testing.expect(fileIndex != null);
    // Every href on the file's own index page must point at a page
    // that was actually written.
    var searchFrom: usize = 0;
    const needle = "<a href=\"";
    while (std.mem.indexOfPos(u8, fileIndex.?, searchFrom, needle)) |start| {
        const hrefStart = start + needle.len;
        const hrefEnd = std.mem.indexOfScalarPos(u8, fileIndex.?, hrefStart, '"').?;
        const href = fileIndex.?[hrefStart..hrefEnd];
        const resolved = try resolveTestHref(gpa, "fuzzer/index.html", href);
        defer gpa.free(resolved);
        try std.testing.expect(writtenPaths.contains(resolved));
        searchFrom = hrefEnd;
    }
}

test "split file: a nested file's page lives at its real directory path" {
    const gpa = std.testing.allocator;

    const fileSection = model.Section{
        .name = "html_single.zig",
        .path = "html_single",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "src/render/html_single.zig",
        .sourceLine = 0,
        .kind = .file,
        .children = &.{},
        .fileLabel = "render/html_single.zig",
    };
    var sections = [_]model.Section{fileSection};
    const tree = model.DocTree{ .moduleName = "combined", .rootDocComment = null, .sections = &sections };

    const pages = try testWrite(gpa, .html, tree, "myproject", options.Options{ .split = .file, .tree = true });
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    var foundFilePage = false;
    var foundDirPage = false;
    for (pages) |p| {
        if (std.mem.eql(u8, p.filename, "render/html_single.zig/index.html")) foundFilePage = true;
        if (std.mem.eql(u8, p.filename, "render/index.html")) foundDirPage = true;
    }
    try std.testing.expect(foundFilePage);
    try std.testing.expect(foundDirPage);
}

test "split item: a file's slug that collides with a real directory falls back to keeping its extension" {
    const gpa = std.testing.allocator;

    // "src/utils.zig" (a file) and "src/utils/x.zig" (inside a real
    // directory named "utils") would both want the folder
    // "src/utils/" if the file's extension were stripped.
    const utilsFile = model.Section{
        .name = "utils.zig",
        .path = "utils",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "src/utils.zig",
        .sourceLine = 0,
        .kind = .file,
        .children = &.{},
        .fileLabel = "src/utils.zig",
    };
    const xFile = model.Section{
        .name = "x.zig",
        .path = "x",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "src/utils/x.zig",
        .sourceLine = 0,
        .kind = .file,
        .children = &.{},
        .fileLabel = "src/utils/x.zig",
    };
    var sections = [_]model.Section{ utilsFile, xFile };
    const tree = model.DocTree{ .moduleName = "combined", .rootDocComment = null, .sections = &sections };

    const pages = try testWrite(gpa, .html, tree, "myproject", options.Options{ .split = .file, .tree = true, .extUrls = false, .dirUrls = true });
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    var foundUtilsFilePage = false;
    var foundUtilsDirPage = false;
    var foundXFilePage = false;
    var pathCounts = std.StringHashMap(usize).init(gpa);
    defer pathCounts.deinit();
    for (pages) |p| {
        const gop = try pathCounts.getOrPut(p.filename);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
        if (std.mem.eql(u8, p.filename, "src/utils.zig/index.html")) foundUtilsFilePage = true;
        if (std.mem.eql(u8, p.filename, "src/utils/index.html")) foundUtilsDirPage = true;
        if (std.mem.eql(u8, p.filename, "src/utils/x/index.html")) foundXFilePage = true;
    }
    // The file kept its extension in its folder name specifically
    // because "utils" was already claimed by the real directory —
    // resolving the collision, not just avoiding it by coincidence.
    try std.testing.expect(foundUtilsFilePage);
    try std.testing.expect(foundUtilsDirPage);
    try std.testing.expect(foundXFilePage);
    // No two pages ever landed on the same output path.
    var it = pathCounts.valueIterator();
    while (it.next()) |count| try std.testing.expectEqual(@as(usize, 1), count.*);
}

test "split file: a file named after a Windows-reserved device name gets a tilde suffix" {
    const gpa = std.testing.allocator;

    const nulFile = model.Section{
        .name = "nul.zig",
        .path = "nul",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "nul.zig",
        .sourceLine = 0,
        .kind = .file,
        .children = &.{},
        .fileLabel = "nul.zig",
    };
    var sections = [_]model.Section{nulFile};
    const tree = model.DocTree{ .moduleName = "combined", .rootDocComment = null, .sections = &sections };

    const pages = try testWrite(gpa, .html, tree, "myproject", options.Options{ .split = .file, .tree = true, .extUrls = false, .dirUrls = true });
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    var foundSafePage = false;
    for (pages) |p| {
        try std.testing.expect(!std.mem.eql(u8, p.filename, "nul/index.html"));
        if (std.mem.eql(u8, p.filename, "nul~/index.html")) foundSafePage = true;
    }
    try std.testing.expect(foundSafePage);
}

test "split file: --tree off still writes each directory's own page" {
    const gpa = std.testing.allocator;

    const fileSection = model.Section{
        .name = "html_single.zig",
        .path = "html_single",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "src/render/html_single.zig",
        .sourceLine = 0,
        .kind = .file,
        .children = &.{},
        .fileLabel = "render/html_single.zig",
    };
    var sections = [_]model.Section{fileSection};
    const tree = model.DocTree{ .moduleName = "combined", .rootDocComment = null, .sections = &sections };

    const pages = try testWrite(gpa, .html, tree, "myproject", options.Options{ .split = .file, .tree = false });
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    var foundDirPage = false;
    for (pages) |p| {
        if (std.mem.eql(u8, p.filename, "render/index.html")) foundDirPage = true;
    }
    try std.testing.expect(foundDirPage);
}

test "relativeHref: prettyurls on a directory-group link matches the shape htmlTreeOnDir builds" {
    // htmlTreeOnDir (a directory group's own link, inside --tree's
    // index) passes ctx.opts.prettyUrls straight through to
    // relativeHref with no logic of its own, so relativeHref's own
    // tests already cover its behavior — this just pins the specific
    // page-path shapes that code actually calls it with, root to a
    // subdirectory group and back.
    const gpa = std.testing.allocator;
    const toDir = try model.relativeHref(gpa, "index.html", "render/index.html", true);
    defer gpa.free(toDir);
    try std.testing.expectEqualStrings("render/", toDir);

    const toFile = try model.relativeHref(gpa, "index.html", "render/html_single.zig/index.html", true);
    defer gpa.free(toFile);
    try std.testing.expectEqualStrings("render/html_single.zig/", toFile);

    const backToRoot = try model.relativeHref(gpa, "render/html_single.zig/index.html", "index.html", true);
    defer gpa.free(backToRoot);
    try std.testing.expectEqualStrings("../../", backToRoot);
}



test "resolveLocLink: a root-level file with locfull on links to the root page, labelled with the root's name" {
    const gpa = std.testing.allocator;
    const opts = options.Options{ .tree = true, .locFull = true };
    const loc = try resolveLocLink(gpa, .html, opts, "ubsan_rt.zig", "ubsan_rt.zig/index.html", "lib/");
    defer loc.deinit(gpa);
    try std.testing.expectEqualStrings("../index.html", loc.href);
    try std.testing.expectEqualStrings("lib/", loc.prefix);
}

test "resolveLocLink: a root-level file with locfull off resolves to no link at all" {
    const gpa = std.testing.allocator;
    const opts = options.Options{ .tree = true, .locFull = false };
    const loc = try resolveLocLink(gpa, .html, opts, "ubsan_rt.zig", "ubsan_rt.zig/index.html", "lib/");
    defer loc.deinit(gpa);
    try std.testing.expectEqualStrings("", loc.href);
    try std.testing.expectEqualStrings("", loc.prefix);
}

test "resolveLocLink: a file inside a subdirectory always links there; locfull prepends the root name onto that link's text" {
    const gpa = std.testing.allocator;

    const withLocFull = try resolveLocLink(gpa, .html, options.Options{ .tree = true, .locFull = true }, "render/html_single.zig", "render/html_single.zig/index.html", "lib/");
    defer withLocFull.deinit(gpa);
    try std.testing.expectEqualStrings("../../render/index.html", withLocFull.href);
    try std.testing.expectEqualStrings("lib/render/", withLocFull.prefix);

    const withoutLocFull = try resolveLocLink(gpa, .html, options.Options{ .tree = true, .locFull = false }, "render/html_single.zig", "render/html_single.zig/index.html", "lib/");
    defer withoutLocFull.deinit(gpa);
    try std.testing.expectEqualStrings("../../render/index.html", withoutLocFull.href);
    try std.testing.expectEqualStrings("render/", withoutLocFull.prefix);
}

test "resolveLocLink: locfull never applies to single-file input (empty fileLabel)" {
    const gpa = std.testing.allocator;
    const opts = options.Options{ .tree = true, .locFull = true };
    const loc = try resolveLocLink(gpa, .html, opts, "", "index.html", "lib/");
    defer loc.deinit(gpa);
    try std.testing.expectEqualStrings("", loc.href);
    try std.testing.expectEqualStrings("", loc.prefix);
}

test "resolveLocLink: --tree off still links, since directory pages exist either way" {
    const gpa = std.testing.allocator;
    const opts = options.Options{ .tree = false, .locFull = true };

    const rootLoc = try resolveLocLink(gpa, .html, opts, "ubsan_rt.zig", "ubsan_rt.zig/index.html", "lib/");
    defer rootLoc.deinit(gpa);
    try std.testing.expectEqualStrings("../index.html", rootLoc.href);
    try std.testing.expectEqualStrings("lib/", rootLoc.prefix);

    const nestedLoc = try resolveLocLink(gpa, .html, opts, "render/html_single.zig", "render/html_single.zig/index.html", "lib/");
    defer nestedLoc.deinit(gpa);
    try std.testing.expectEqualStrings("../../render/index.html", nestedLoc.href);
    try std.testing.expectEqualStrings("lib/render/", nestedLoc.prefix);
}

test "resolveLocLink: prettyurls strips index.html from the resolved href" {
    const gpa = std.testing.allocator;
    const opts = options.Options{ .tree = true, .locFull = true, .prettyUrls = true };
    const loc = try resolveLocLink(gpa, .html, opts, "ubsan_rt.zig", "ubsan_rt.zig/index.html", "lib/");
    defer loc.deinit(gpa);
    try std.testing.expectEqualStrings("../", loc.href);
    try std.testing.expectEqualStrings("lib/", loc.prefix);
}

test "resolveLocLink: a file in a real Zig-stdlib-shaped tree (lib/build-web/fuzz.zig) reads as one full path down to its own directory" {
    const gpa = std.testing.allocator;
    const opts = options.Options{ .tree = true, .locFull = true };
    const loc = try resolveLocLink(gpa, .html, opts, "build-web/fuzz.zig", "build-web/fuzz.zig/index.html", "lib/");
    defer loc.deinit(gpa);
    try std.testing.expectEqualStrings("../../build-web/index.html", loc.href);
    try std.testing.expectEqualStrings("lib/build-web/", loc.prefix);
}

test "appendDeclPathSegment: builds one path segment at a time, case preserved" {
    const gpa = std.testing.allocator;
    var reg = Registry{ .slugs = std.StringHashMap([]const u8).init(gpa), .declSegments = std.StringHashMap([]const u8).init(gpa) };
    defer reg.deinit(gpa);

    const own = try appendDeclPathSegment(gpa, "fuzzer.zig", "Input", reg);
    defer gpa.free(own);
    try std.testing.expectEqualStrings("fuzzer.zig/Input", own);

    const nested = try appendDeclPathSegment(gpa, own, "deinit", reg);
    defer gpa.free(nested);
    try std.testing.expectEqualStrings("fuzzer.zig/Input/deinit", nested);
}

/// Resolves an `href` emitted on the page at `fromPath` (relative to
/// that page's own directory, `../` included) back to an
/// output-root-relative path, so it can be checked against a set of
/// written page paths. Test-only.
fn resolveTestHref(gpa: std.mem.Allocator, fromPath: []const u8, href: []const u8) ![]u8 {
    var dirs: std.ArrayList([]const u8) = .empty;
    defer dirs.deinit(gpa);
    var fromIt = std.mem.splitScalar(u8, fromPath, '/');
    var fromParts: std.ArrayList([]const u8) = .empty;
    defer fromParts.deinit(gpa);
    while (fromIt.next()) |seg| try fromParts.append(gpa, seg);
    if (fromParts.items.len > 0) fromParts.items.len -= 1; // drop the filename itself
    try dirs.appendSlice(gpa, fromParts.items);

    var hrefIt = std.mem.splitScalar(u8, href, '/');
    while (hrefIt.next()) |seg| {
        if (std.mem.eql(u8, seg, "..")) {
            if (dirs.items.len > 0) dirs.items.len -= 1;
        } else if (seg.len == 0 or std.mem.eql(u8, seg, ".")) {
            continue;
        } else {
            try dirs.append(gpa, seg);
        }
    }
    return std.mem.join(gpa, "/", dirs.items);
}

test "appendDeclPathSegment: an empty parent (single-file input) starts with just the segment" {
    const gpa = std.testing.allocator;
    var reg = Registry{ .slugs = std.StringHashMap([]const u8).init(gpa), .declSegments = std.StringHashMap([]const u8).init(gpa) };
    defer reg.deinit(gpa);
    const own = try appendDeclPathSegment(gpa, "", "Input", reg);
    defer gpa.free(own);
    try std.testing.expectEqualStrings("Input", own);
}

fn testSection(kind: model.Kind, children: []model.Section) model.Section {
    return .{
        .name = "",
        .path = "",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "",
        .sourceLine = 0,
        .kind = kind,
        .children = children,
        .hasChildren = children.len > 0,
    };
}

test "pageFilename: a decl with children becomes a folder page; a leaf decl stays flat" {
    const gpa = std.testing.allocator;
    var reg = Registry{ .slugs = std.StringHashMap([]const u8).init(gpa), .declSegments = std.StringHashMap([]const u8).init(gpa) };
    defer reg.deinit(gpa);

    var oneChild = [_]model.Section{testSection(.fn_decl, &.{})};
    const withChildren = testSection(.struct_decl, &oneChild);
    const leaf = testSection(.fn_decl, &.{});

    const withChildrenPath = try pageFilename(gpa, .html, withChildren, "fuzzer.zig/Input", options.Options{}, reg);
    defer gpa.free(withChildrenPath);
    try std.testing.expectEqualStrings("fuzzer.zig/Input/index.html", withChildrenPath);

    const leafPath = try pageFilename(gpa, .html, leaf, "fuzzer.zig/Input/deinit", options.Options{}, reg);
    defer gpa.free(leafPath);
    try std.testing.expectEqualStrings("fuzzer.zig/Input/deinit.html", leafPath);
}

test "pageFilename: --recursive off still folders a decl that has unextracted children" {
    const gpa = std.testing.allocator;
    var reg = Registry{ .slugs = std.StringHashMap([]const u8).init(gpa), .declSegments = std.StringHashMap([]const u8).init(gpa) };
    defer reg.deinit(gpa);

    var unrecursed = testSection(.struct_decl, &.{});
    unrecursed.hasChildren = true;

    const path = try pageFilename(gpa, .html, unrecursed, "fuzzer.zig/Input", options.Options{}, reg);
    defer gpa.free(path);
    try std.testing.expectEqualStrings("fuzzer.zig/Input/index.html", path);
}

test "pageFilename: a decl with children ignores --dirurls off — its own leaf page does not" {
    // --dirurls only controls whether a *file's own* page sits inside
    // its folder as index.html or flat beside it; a decl with
    // children always needs a folder for those children to live in
    // regardless, same as it always has (see writeOrphanRedirects).
    const gpa = std.testing.allocator;
    var reg = Registry{ .slugs = std.StringHashMap([]const u8).init(gpa), .declSegments = std.StringHashMap([]const u8).init(gpa) };
    defer reg.deinit(gpa);
    const opts = options.Options{ .dirUrls = false };

    var oneChild = [_]model.Section{testSection(.fn_decl, &.{})};
    const withChildren = testSection(.struct_decl, &oneChild);
    const declPath = try pageFilename(gpa, .html, withChildren, "fuzzer.zig/Input", opts, reg);
    defer gpa.free(declPath);
    try std.testing.expectEqualStrings("fuzzer.zig/Input/index.html", declPath);

    const leaf = testSection(.fn_decl, &.{});
    const leafPath = try pageFilename(gpa, .html, leaf, "fuzzer.zig/Input/deinit", opts, reg);
    defer gpa.free(leafPath);
    try std.testing.expectEqualStrings("fuzzer.zig/Input/deinit.html", leafPath);
}

test "pageFilename: file-kind still respects --dirurls, unaffected by the decl-nesting change" {
    const gpa = std.testing.allocator;
    var reg = Registry{ .slugs = std.StringHashMap([]const u8).init(gpa), .declSegments = std.StringHashMap([]const u8).init(gpa) };
    defer reg.deinit(gpa);
    try reg.slugs.put(try gpa.dupe(u8, "fuzzer.zig"), try gpa.dupe(u8, "fuzzer.zig"));

    var fileSection = testSection(.file, &.{});
    fileSection.fileLabel = "fuzzer.zig";

    const dirUrlsOn = try pageFilename(gpa, .html, fileSection, "", options.Options{ .dirUrls = true }, reg);
    defer gpa.free(dirUrlsOn);
    try std.testing.expectEqualStrings("fuzzer.zig/index.html", dirUrlsOn);

    const dirUrlsOff = try pageFilename(gpa, .html, fileSection, "", options.Options{ .dirUrls = false }, reg);
    defer gpa.free(dirUrlsOff);
    try std.testing.expectEqualStrings("fuzzer.zig.html", dirUrlsOff);
}

test "split item end-to-end: a decl with children nests its own children under it, and this composes with --exturls off" {
    const child = model.Section{
        .name = "deinit",
        .path = "fuzzer.Input.deinit",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "fuzzer.zig",
        .sourceLine = 0,
        .kind = .fn_decl,
        .children = &.{},
    };
    var children = [_]model.Section{child};
    const topLevelDecl = model.Section{
        .name = "Input",
        .path = "fuzzer.Input",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "fuzzer.zig",
        .sourceLine = 0,
        .kind = .struct_decl,
        .children = &children,
        .hasChildren = true,
    };
    var fileChildren = [_]model.Section{topLevelDecl};
    const fileSection = model.Section{
        .name = "fuzzer.zig",
        .path = "fuzzer",
        .signature = "",
        .docComment = "",
        .source = "",
        .sourceFile = "fuzzer.zig",
        .sourceLine = 0,
        .kind = .file,
        .children = &fileChildren,
        .fileLabel = "fuzzer.zig",
    };
    const gpa = std.testing.allocator;
    var sections = [_]model.Section{fileSection};
    const tree = model.DocTree{ .moduleName = "combined", .rootDocComment = null, .sections = &sections };

    const pages = try testWrite(gpa, .html, tree, "myproject", options.Options{ .split = .item, .tree = true, .extUrls = false });
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }

    var foundInputPage = false;
    var foundDeinitPage = false;
    for (pages) |p| {
        // extUrls off strips .zig from the *file's* folder name
        // ("fuzzer", not "fuzzer.zig") — Input's own casing is kept,
        // and deinit nests under Input rather than sitting flat
        // beside it.
        if (std.mem.eql(u8, p.filename, "fuzzer/Input/index.html")) foundInputPage = true;
        if (std.mem.eql(u8, p.filename, "fuzzer/Input/deinit.html")) foundDeinitPage = true;
    }
    try std.testing.expect(foundInputPage);
    try std.testing.expect(foundDeinitPage);
}
