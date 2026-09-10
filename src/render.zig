//! Renders a `DocTree` into output `Page`s for a given `--split`
//! mode and `--format`.
const std = @import("std");
const model = @import("model.zig");
const main = @import("main.zig");
const options = main.options;
const style = @import("style.zig");
const template = @import("template.zig");
const sources = @import("sources.zig");
const imports = @import("imports.zig");
const progress_mod = main.progress_mod;
const markdown = struct {
    pub const Parser = @import("markdown/Parser.zig");
};

/// One rendered output page.
pub const Page = struct {
    /// Output-relative path, `/`-separated.
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

/// What a page is for: a synthetic `--tree` directory group, or an
/// ordinary file/decl section.
const NodeKind = union(enum) {
    container: struct {
        /// Page heading: `"name/"` for this directory.
        heading: []const u8,
        dirPath: []const u8,
        sections: []const model.Section,
    },
    decl: model.Section,
};

/// One breadcrumb entry: a display name and its page's output path.
const Ancestor = struct { name: []const u8, target: []const u8 };

const Ctx = struct {
    gpa: std.mem.Allocator,
    fmt: Format,
    title: []const u8,
    opts: options.Options,
    tplDoc: []const u8,
    tplSec: []const u8,
    /// Index page's heading/breadcrumb label: `opts.rootname` or `rootDirName`.
    indexTitle: []const u8,
    /// Root's real name, independent of `opts.rootname`.
    rootDirName: []const u8,
    registry: Registry,
    /// `null` when `opts.codelinks` is off.
    symbols: ?*SymbolIndex,
    /// `null` in single-page mode.
    pages: ?*const PageIndex,
    /// `null` when `opts.codelinks` is off. Used to chase a `funcsigs`
    /// alias entry to its real content — see `resolveFuncSigContent`.
    fileRoots: ?*const FileRootIndex,
    reporter: *progress_mod.Progress,
};

/// Renders `tree` into a set of `Page`s. Caller owns the result
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

    var virtualRoot: model.Section = undefined;
    var fileRoots: ?FileRootIndex = null;
    defer if (fileRoots) |*fr| fr.deinit();
    if (opts.codelinks) {
        reporter.update("resolving codelinks", .{});
        fileRoots = try buildFileRootIndex(gpa, tree, &virtualRoot);
        try resolvePendingCodelinks(gpa, tree.sections, &fileRoots.?);
    }

    if (opts.split == .none) {
        var registry = Registry{ .slugs = std.StringHashMap([]const u8).init(gpa), .declSegments = std.StringHashMap([]const u8).init(gpa), .declPathsByPath = std.StringHashMap([]const u8).init(gpa) };
        defer registry.deinit(gpa);
        // Anchors must match writeSinglePage's actual render, not tree.sections.
        const disambiguated = try model.disambiguateSectionPaths(gpa, tree.sections);
        defer model.freeDisambiguatedSections(gpa, disambiguated, tree.sections);
        if (opts.codelinks) reporter.update("indexing symbols", .{});
        var symbols: ?SymbolIndex = if (opts.codelinks)
            try buildSymbolIndex(gpa, fmt, disambiguated, opts, null, opts.filename, tree.moduleName, null)
        else
            null;
        defer if (symbols) |*s| s.deinit(gpa);
        const ctx = Ctx{ .gpa = gpa, .fmt = fmt, .title = title, .opts = opts, .tplDoc = tplDoc, .tplSec = tplSec, .indexTitle = indexTitle, .rootDirName = tree.moduleName, .registry = registry, .symbols = if (symbols) |*s| s else null, .pages = null, .fileRoots = if (fileRoots) |*fr| fr else null, .reporter = reporter };
        try writeSinglePage(ctx, &pages, tree);
        return pages.toOwnedSlice(gpa);
    }

    reporter.update("building page registry", .{});
    var registry = try buildRegistry(gpa, tree.sections, fmt, opts);
    defer registry.deinit(gpa);

    reporter.update("locating pages", .{});
    var pageIndex = try buildPageIndex(gpa, fmt, tree.sections, opts, registry, "", tree.moduleName, tree.sourceFile);
    defer pageIndex.deinit(gpa);
    try populateAliasTable(gpa, &registry, &pageIndex);

    if (opts.codelinks) reporter.update("indexing symbols", .{});
    var symbols: ?SymbolIndex = if (opts.codelinks)
        try buildSymbolIndex(gpa, fmt, tree.sections, opts, registry, "", tree.moduleName, &pageIndex)
    else
        null;
    defer if (symbols) |*s| s.deinit(gpa);
    const ctx = Ctx{ .gpa = gpa, .fmt = fmt, .title = title, .opts = opts, .tplDoc = tplDoc, .tplSec = tplSec, .indexTitle = indexTitle, .rootDirName = tree.moduleName, .registry = registry, .symbols = if (symbols) |*s| s else null, .pages = &pageIndex, .fileRoots = if (fileRoots) |*fr| fr else null, .reporter = reporter };

    const rootIsDir = tree.rootIsDir;

    if (rootIsDir) {
        try writeNode(ctx, &pages, .{ .container = .{
            .heading = ctx.indexTitle,
            .dirPath = "",
            .sections = tree.sections,
        } }, &.{}, "", "", true);
        try writeDirGroups(ctx, &pages, tree.sections, "");

        for (tree.sections) |section| {
            const dirAncestors = if (opts.tree) try ancestorsFromDirPath(gpa, fmt, dirPortion(section.fileLabel)) else &.{};
            defer freeDirAncestors(gpa, dirAncestors);
            const ownDeclPath = try ctx.registry.slugForFileSection(gpa, section);
            defer gpa.free(ownDeclPath);
            try writeNode(ctx, &pages, .{ .decl = section }, dirAncestors, section.fileLabel, ownDeclPath, false);
        }
    } else {
        // children are borrowed from tree.sections; not freed here.
        const rootKind: model.Kind = if (opts.discover == .ns) .namespace else .file;
        var rootSection = try model.fileWrapperSection(gpa, tree, rootKind, ctx.indexTitle, "", tree.sourceFile);
        if (fileRoots) |*fr| {
            try resolveSectionPendingCodelinks(gpa, &rootSection, fr);
            try scanFilenameMentions(gpa, &rootSection, fr);
        }
        defer {
            gpa.free(rootSection.name);
            gpa.free(rootSection.path);
            gpa.free(rootSection.signature);
            gpa.free(rootSection.docComment);
            gpa.free(rootSection.source);
            gpa.free(rootSection.sourceFile);
            if (rootSection.fileLabel.len > 0) gpa.free(rootSection.fileLabel);
            gpa.free(rootSection.testSource);
            for (rootSection.codelinkTargets) |t| gpa.free(t.targetPath);
            if (rootSection.codelinkTargets.len > 0) gpa.free(rootSection.codelinkTargets);
            for (rootSection.mentionTargets) |t| gpa.free(t.targetPath);
            if (rootSection.mentionTargets.len > 0) gpa.free(rootSection.mentionTargets);
            for (rootSection.pendingCodelinkTargets) |t| {
                gpa.free(t.importTarget);
                if (t.remainingPath.len > 0) gpa.free(t.remainingPath);
            }
            if (rootSection.pendingCodelinkTargets.len > 0) gpa.free(rootSection.pendingCodelinkTargets);
        }
        try writeNode(ctx, &pages, .{ .decl = rootSection }, &.{}, "", "", true);
    }

    if (!opts.dirUrls) try writeOrphanRedirects(ctx, &pages, tree.sections);

    return pages.toOwnedSlice(gpa);
}

/// Writes a page for each `--tree` directory group under `sections`
/// (already the portion at `dirPath`), recursing into subdirectories.
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
            } }, dirAncestors, "", "", false);
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

    pub fn deinit(self: LocLink, gpa: std.mem.Allocator) void {
        if (self.href.len > 0) gpa.free(self.href);
        if (self.prefix.len > 0) gpa.free(self.prefix);
    }
};

/// Resolves the directory-page link shown before a decl's bare
/// filename in `{file}`. Both fields empty when nothing should
/// link (single-file input with no `fileLabel`, or a root-level file
/// with `opts.fileDir` off). Caller owns both fields via `LocLink.deinit`.
pub fn resolveLocLink(gpa: std.mem.Allocator, fmt: Format, opts: options.Options, fileLabel: []const u8, ownPath: []const u8, rootDirName: []const u8) !LocLink {
    const prettyUrls = fmt == .html and opts.prettyUrls;
    const dirPath = dirPortion(fileLabel);
    if (dirPath.len == 0 and !(opts.fileDir and fileLabel.len > 0)) return .{ .href = "", .prefix = "" };

    const target = try dirPageFilename(gpa, fmt, dirPath);
    defer gpa.free(target);
    const href = try model.relativeHref(gpa, ownPath, target, prettyUrls);
    errdefer gpa.free(href);

    const prefix = if (opts.fileDir and fileLabel.len > 0)
        try std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ rootDirName, dirPath, if (dirPath.len > 0) "/" else "" })
    else
        try std.fmt.allocPrint(gpa, "{s}/", .{dirPath});
    return .{ .href = href, .prefix = prefix };
}

/// Builds and appends the page for one node — root, directory, file, or
/// item alike. `ancestors` is the breadcrumb chain. `fileLabel` and
/// `ownDeclPath` only apply to `.decl` nodes: the owning file's label, and
/// this decl's full page path. `isRoot` is true only for the front page.
fn writeNode(ctx: Ctx, pages: *std.ArrayList(Page), kind: NodeKind, ancestors: []const Ancestor, fileLabel: []const u8, ownDeclPath: []const u8, isRoot: bool) !void {
    const gpa = ctx.gpa;
    const fmt = ctx.fmt;

    // Cross-file aliases resolve straight to their real page already;
    // `--omitdoc` decls get no page anywhere (see `Section.docOnly`).
    if (kind == .decl and (kind.decl.aliasTargetPath != null or kind.decl.docOnly)) return;

    const ownPath = if (isRoot)
        try gpa.dupe(u8, fmt.indexFilename())
    else switch (kind) {
        .container => |c| try dirPageFilename(gpa, fmt, c.dirPath),
        .decl => |s| try pageFilename(gpa, fmt, s, ownDeclPath, ctx.opts, ctx.registry),
    };
    defer gpa.free(ownPath);
    ctx.reporter.update("rendering {s}", .{ownPath});

    const styles = switch (fmt) {
        .html => try stylesValue(gpa, ctx.opts, ownPath),
        .md => try gpa.dupe(u8, ""),
    };
    defer gpa.free(styles);

    // Which source mode governs *this* page's own source block, for
    // the tips-box `[u]` line (searchBoxValue) — `null` for a
    // container page (no single source block to jump to). A whole
    // file/namespace's own page always uses `pageSource`; so does any
    // other section here, since `writeNode` only ever renders a page's
    // own main item, and under `--split item` that's true even for a
    // single decl with no whole-file wrapper of its own.
    const pageSourceMode: ?options.SourceMode = switch (kind) {
        .container => null,
        .decl => |s| if ((s.isWholeFileWrapper() and !s.raw) or ctx.opts.split == .item) ctx.opts.pageSource else ctx.opts.source,
    };
    const searchBox = try searchBoxValue(gpa, fmt, ctx.opts, ownPath, pageSourceMode);
    defer gpa.free(searchBox);

    var breadcrumb: []const u8 = "";
    defer if (breadcrumb.len > 0) gpa.free(breadcrumb);
    if (ctx.opts.breadcrumb) {
        if (isRoot) {
            breadcrumb = switch (fmt) {
                .html => try gpa.dupe(u8, ""),
                .md => "",
            };
        } else {
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
    }

    var loc = LocLink{ .href = "", .prefix = "" };
    defer loc.deinit(gpa);
    if (kind == .decl) {
        loc = try resolveLocLink(gpa, fmt, ctx.opts, fileLabel, ownPath, ctx.rootDirName);
    }
    const dirHref = loc.href;
    const locPrefix = loc.prefix;

    var idVal: []const u8 = "";
    defer if (idVal.len > 0) gpa.free(idVal);
    var comment: []const u8 = "";
    defer if (comment.len > 0) gpa.free(comment);
    var indexContent: []const u8 = "";
    defer if (indexContent.len > 0) gpa.free(indexContent);
    var docs: []const u8 = "";
    defer if (docs.len > 0) gpa.free(docs);
    var pageTitle: []const u8 = "";

    var pageType: []const u8 = "";
    var pageVis: []const u8 = "";
    var pageClasses: []const u8 = "";
    defer if (pageClasses.len > 0) gpa.free(pageClasses);
    var pageKind: []const u8 = "";
    var pageKindOwned = false;
    defer if (pageKindOwned) gpa.free(pageKind);

    switch (kind) {
        .container => |c| {
            pageTitle = c.heading;
            pageType = "Directory";
            pageVis = "";
            pageClasses = try std.fmt.allocPrint(gpa, "page-dir{s}", .{if (isRoot) " zd-root" else ""});

            var aw: std.Io.Writer.Allocating = .init(gpa);
            defer aw.deinit();
            try writeSectionIndex(gpa, fmt, &aw.writer, c.sections, c.dirPath, ownPath, ctx.opts, ctx.registry, true, ctx.pages, "");
            indexContent = try gpa.dupe(u8, aw.written());

            if (ctx.opts.shows(.directories) or ctx.opts.shows(.files)) {
                const result = try renderDirGroupLists(gpa, fmt, c.sections, c.dirPath, ownPath, ctx.opts, ctx.registry, ctx.pages);
                var dirs: []const u8 = "";
                var dirsHeading: []const u8 = "";
                defer if (dirs.len > 0) gpa.free(dirs);
                if (ctx.opts.shows(.directories)) {
                    dirs = result.directories;
                    if (ctx.opts.subheadings and dirs.len > 0) dirsHeading = "Directories";
                } else gpa.free(result.directories);
                var fileList: []const u8 = "";
                var filesListHeading: []const u8 = "";
                defer if (fileList.len > 0) gpa.free(fileList);
                if (ctx.opts.shows(.files)) {
                    fileList = result.files;
                    if (ctx.opts.subheadings and fileList.len > 0) filesListHeading = "Files";
                } else gpa.free(result.files);

                if (dirs.len > 0 or fileList.len > 0) {
                    var dirVars: SectionVars = std.mem.zeroes(SectionVars);
                    dirVars.directoriesHeading = dirsHeading;
                    dirVars.directories = dirs;
                    dirVars.filesHeading = filesListHeading;
                    dirVars.files = fileList;
                    docs = try renderOneSection(gpa, fmt, ctx.tplSec, dirVars);
                }
            }
        },
        .decl => |section| {
            pageTitle = if (isRoot) ctx.indexTitle else section.name;
            pageType = pageTypeLabel(section);
            pageVis = if (!section.raw and (section.kind == .file or section.kind == .namespace)) "" else if (section.isPub) "Public" else "Private";
            pageClasses = try pageClassesValue(gpa, section, isRoot);
            pageKind = try genericKindLabel(gpa, section);
            pageKindOwned = section.raw;

            if (ctx.opts.split == .file) {
                if (ctx.opts.index) {
                    const slug = switch (fmt) {
                        .html => try section.anchorSlug(gpa),
                        .md => try section.anchorSlugMd(gpa),
                    };
                    defer gpa.free(slug);
                    idVal = try gpa.dupe(u8, slug);
                }
                const prettyUrlsForComment = fmt == .html and ctx.opts.prettyUrls;
                if (isRoot and ctx.opts.rootComment.len > 0) {
                    var lookupStorage = rootLinkResolver(ctx.symbols, gpa, ownPath, prettyUrlsForComment);
                    const lookup: ?sources.ProseLinkResolver = if (lookupStorage) |*l| l.resolver() else null;
                    comment = try renderComment(gpa, fmt, ctx.opts.rootComment, lookup);
                } else if (section.docComment.len > 0) {
                    var lookupStorage: SymbolLookup = undefined;
                    const lookup: ?sources.ProseLinkResolver = if (fmt == .html and ctx.symbols != null) blk: {
                        lookupStorage = .{ .index = ctx.symbols.?, .gpa = gpa, .fromPage = ownPath, .prettyUrls = prettyUrlsForComment, .selfName = section.name };
                        break :blk lookupStorage.resolver();
                    } else null;
                    comment = try renderComment(gpa, fmt, section.docComment, lookup);
                    if (fmt == .html and section.docCommentIsFallback) {
                        const wrapped = try std.fmt.allocPrint(gpa, "<div class=\"doc-fallback\">{s}</div>", .{comment});
                        gpa.free(comment);
                        comment = wrapped;
                    }
                }

                if (ctx.opts.index and section.children.len > 0) {
                    var aw: std.Io.Writer.Allocating = .init(gpa);
                    defer aw.deinit();
                    // Children crossing an @import boundary get their own
                    // page and must link out, not to an in-page anchor.
                    try writeInPageIndexNsAware(gpa, fmt, &aw.writer, section.children, 0, ctx.opts, ctx.registry, ownPath, ownDeclPath, section.sourceFile, ctx.pages);
                    indexContent = try gpa.dupe(u8, aw.written());
                }

                var docsBuf: std.ArrayList(u8) = .empty;
                defer docsBuf.deinit(gpa);

                // Blank name/comment so only fields/params/errors/child-kind lists print.
                if (section.fields.len > 0 or section.params.len > 0 or section.errors.len > 0 or section.children.len > 0) {
                    var ownVars = try buildSectionVars(gpa, fmt, section, ctx.opts, 2, false, dirHref, locPrefix, ctx.symbols, ownPath, true, ctx.rootDirName.len, ctx.registry, ctx.pages, ctx.fileRoots);
                    defer ownVars.deinit(gpa);
                    if (ownVars.name.len > 0) gpa.free(ownVars.name);
                    ownVars.name = try gpa.dupe(u8, "");
                    if (ownVars.comment.len > 0) gpa.free(ownVars.comment);
                    ownVars.comment = try gpa.dupe(u8, "");
                    const ownExtras = try renderOneSection(gpa, fmt, ctx.tplSec, ownVars);
                    defer gpa.free(ownExtras);
                    try docsBuf.appendSlice(gpa, ownExtras);
                }

                for (section.children) |child| {
                    if (isFileBoundary(child, section.sourceFile)) continue;
                    try renderSection(gpa, fmt, &docsBuf, ctx.tplSec, child, ctx.opts, 2, ctx.opts.index, dirHref, locPrefix, ctx.symbols, ownPath, ctx.rootDirName.len, ctx.registry, ctx.pages, ctx.fileRoots);
                }
                docs = try docsBuf.toOwnedSlice(gpa);

                // `--pagesource tab`: the page-level Doc/Source toggle
                if (fmt == .html and ctx.opts.pageSource == .tab and section.source.len > 0) {
                    var wrapperVars = try buildSectionVars(gpa, fmt, section, ctx.opts, 1, false, dirHref, locPrefix, ctx.symbols, ownPath, false, ctx.rootDirName.len, ctx.registry, ctx.pages, ctx.fileRoots);
                    defer wrapperVars.deinit(gpa);
                    if (wrapperVars.tabSourceHtml.len > 0) {
                        const shelled = try writeTabShell(gpa, docs, wrapperVars.tabSourceHtml);
                        gpa.free(docs);
                        docs = shelled;
                    }
                }
            } else {
                var vars = try buildSectionVars(gpa, fmt, section, ctx.opts, 1, false, dirHref, locPrefix, ctx.symbols, ownPath, true, ctx.rootDirName.len, ctx.registry, ctx.pages, ctx.fileRoots);
                defer vars.deinit(gpa);
                if (isRoot) {
                    if (ctx.opts.index) {
                        if (vars.id.len > 0) gpa.free(vars.id);
                        vars.id = switch (fmt) {
                            .html => try section.anchorSlug(gpa),
                            .md => try section.anchorSlugMd(gpa),
                        };
                    }
                    if (ctx.opts.rootComment.len > 0) {
                        if (vars.comment.len > 0) gpa.free(vars.comment);
                        var lookupStorage = rootLinkResolver(ctx.symbols, gpa, ownPath, fmt == .html and ctx.opts.prettyUrls);
                        const lookup: ?sources.ProseLinkResolver = if (lookupStorage) |*l| l.resolver() else null;
                        vars.comment = try renderComment(gpa, fmt, ctx.opts.rootComment, lookup);
                    }
                }

                if (ctx.opts.index and section.children.len > 0) {
                    var aw: std.Io.Writer.Allocating = .init(gpa);
                    defer aw.deinit();
                    if (isRoot and model.hasFileLabels(section.children)) {
                        try writeSectionIndex(gpa, fmt, &aw.writer, section.children, "", ownPath, ctx.opts, ctx.registry, true, ctx.pages, "");
                    } else {
                        try writePageLinkList(gpa, fmt, &aw.writer, section.children, ownPath, ownDeclPath, ownPath, section.sourceFile, ctx.opts, ctx.registry, ctx.pages);
                    }
                    indexContent = try gpa.dupe(u8, aw.written());
                }

                if (isRoot and ctx.opts.index) idVal = try gpa.dupe(u8, vars.id);

                // {page-title} already carries the heading, so blank name.
                var bodyVars = vars;
                bodyVars.name = "";
                const renderedSection = try renderOneSection(gpa, fmt, ctx.tplSec, bodyVars);
                if (vars.tabSourceHtml.len > 0) {
                    defer gpa.free(renderedSection);
                    docs = try writeTabShell(gpa, renderedSection, vars.tabSourceHtml);
                } else {
                    docs = renderedSection;
                }
            }
        },
    }

    try finishPage(gpa, fmt, pages, ownPath, ctx.tplDoc, &.{
        .{ .name = "page-title", .value = pageTitle },
        .{ .name = "page-type", .value = pageType },
        .{ .name = "page-vis", .value = pageVis },
        .{ .name = "page-classes", .value = pageClasses },
        .{ .name = "kind", .value = pageKind },
        .{ .name = "nav-classes", .value = navClassesValue(ctx.opts) },
        .{ .name = "site-title", .value = ctx.title },
        .{ .name = "styles", .value = styles },
        .{ .name = "head", .value = ctx.opts.head },
        .{ .name = "prepend", .value = ctx.opts.prepend },
        .{ .name = "breadcrumb", .value = breadcrumb },
        .{ .name = "desc", .value = ctx.opts.desc },
        .{ .name = "search", .value = searchBox },
        .{ .name = "comment", .value = comment },
        .{ .name = "index", .value = indexContent },
        .{ .name = "id", .value = idVal },
        .{ .name = "docs", .value = docs },
        .{ .name = "append", .value = ctx.opts.append },
    });

    // Recurse into children: `--split item` recurses into all of them;
    // `--split file` only into real @import file boundaries. Skips the
    // root-with-fileLabel-children case, already written by `write`'s
    // dedicated loop with the correct registry-resolved slug.
    if (kind == .decl and ctx.opts.split != .none and !(isRoot and model.hasFileLabels(kind.decl.children))) {
        const section = kind.decl;
        var nextAncestors = try gpa.alloc(Ancestor, ancestors.len + @intFromBool(!isRoot));
        defer gpa.free(nextAncestors);
        @memcpy(nextAncestors[0..ancestors.len], ancestors);
        // Root is already the leading breadcrumb, not an ancestor entry.
        if (!isRoot) nextAncestors[ancestors.len] = .{ .name = section.name, .target = ownPath };
        for (section.children) |child| {
            if (ctx.opts.split == .file and !isFileBoundary(child, section.sourceFile)) continue;
            const childDeclPath = try appendDeclPathSegment(gpa, ownDeclPath, child.name, ctx.registry);
            defer gpa.free(childDeclPath);
            try writeNode(ctx, pages, .{ .decl = child }, nextAncestors, fileLabel, childDeclPath, false);
        }
    }
}

/// `--split none`: renders everything onto one page (`opts.filename`).
/// Top-level section paths are disambiguated first since they all
/// share this page's anchor namespace.
fn writeSinglePage(ctx: Ctx, pages: *std.ArrayList(Page), tree: model.DocTree) !void {
    const gpa = ctx.gpa;
    const fmt = ctx.fmt;

    const sections = try model.disambiguateSectionPaths(gpa, tree.sections);
    defer model.freeDisambiguatedSections(gpa, sections, tree.sections);

    const styles = switch (fmt) {
        .html => try stylesValue(gpa, ctx.opts, ctx.opts.filename),
        .md => try gpa.dupe(u8, ""),
    };
    defer gpa.free(styles);

    const searchBox = try searchBoxValue(gpa, fmt, ctx.opts, ctx.opts.filename, null);
    defer gpa.free(searchBox);

    var idVal: []const u8 = "";
    defer if (idVal.len > 0) gpa.free(idVal);
    if (ctx.opts.index) {
        const slug = try model.slugify(gpa, tree.moduleName);
        defer gpa.free(slug);
        idVal = try gpa.dupe(u8, slug);
    }

    var comment: []const u8 = "";
    defer if (comment.len > 0) gpa.free(comment);
    var lookupStorage = rootLinkResolver(ctx.symbols, gpa, ctx.opts.filename, fmt == .html and ctx.opts.prettyUrls);
    const rootLookup: ?sources.ProseLinkResolver = if (lookupStorage) |*l| l.resolver() else null;
    if (ctx.opts.rootComment.len > 0) {
        comment = try renderComment(gpa, fmt, ctx.opts.rootComment, rootLookup);
    } else if (tree.rootDocComment) |doc| {
        comment = try renderComment(gpa, fmt, doc, rootLookup);
    }

    var indexContent: []const u8 = "";
    defer if (indexContent.len > 0) gpa.free(indexContent);
    if (ctx.opts.index) {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try writeSectionIndex(gpa, fmt, &aw.writer, sections, "", "", ctx.opts, ctx.registry, false, ctx.pages, tree.sourceFile);
        indexContent = try gpa.dupe(u8, aw.written());
    }

    var docsBuf: std.ArrayList(u8) = .empty;
    defer docsBuf.deinit(gpa);
    for (sections) |section| {
        try renderSection(gpa, fmt, &docsBuf, ctx.tplSec, section, ctx.opts, 2, ctx.opts.index, "", "", ctx.symbols, ctx.opts.filename, ctx.rootDirName.len, ctx.registry, ctx.pages, ctx.fileRoots);
    }

    try finishPage(gpa, fmt, pages, ctx.opts.filename, ctx.tplDoc, &.{
        .{ .name = "page-title", .value = ctx.indexTitle },
        .{ .name = "page-type", .value = "Index" },
        .{ .name = "page-vis", .value = "Public" },
        .{ .name = "page-classes", .value = "page-index page-pub zd-root" },
        .{ .name = "kind", .value = "" },
        .{ .name = "nav-classes", .value = navClassesValue(ctx.opts) },
        .{ .name = "site-title", .value = ctx.title },
        .{ .name = "styles", .value = styles },
        .{ .name = "head", .value = ctx.opts.head },
        .{ .name = "prepend", .value = ctx.opts.prepend },
        .{ .name = "breadcrumb", .value = "" },
        .{ .name = "desc", .value = ctx.opts.desc },
        .{ .name = "search", .value = searchBox },
        .{ .name = "comment", .value = comment },
        .{ .name = "index", .value = indexContent },
        .{ .name = "id", .value = idVal },
        .{ .name = "docs", .value = docsBuf.items },
        .{ .name = "append", .value = ctx.opts.append },
    });
}

const VarSpec = struct { name: []const u8, value: []const u8 };

/// Renders `tplDoc` against `specs` and appends the resulting page.
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

fn renderComment(gpa: std.mem.Allocator, fmt: Format, docComment: []const u8, links: ?sources.ProseLinkResolver) ![]u8 {
    return switch (fmt) {
        .html => markdownToHtml(gpa, docComment, links),
        .md => gpa.dupe(u8, docComment),
    };
}

/// Codelink resolver for a root/whole-page comment with no `selfName`.
fn rootLinkResolver(symbols: ?*SymbolIndex, gpa: std.mem.Allocator, fromPage: []const u8, prettyUrls: bool) ?SymbolLookup {
    const idx = symbols orelse return null;
    return .{ .index = idx, .gpa = gpa, .fromPage = fromPage, .prettyUrls = prettyUrls, .selfName = "" };
}

fn stylesValue(gpa: std.mem.Allocator, opts: options.Options, ownPath: []const u8) ![]u8 {
    return switch (opts.css) {
        .embed => {
            const cssData = try style.css(gpa, opts, opts.theme);
            defer gpa.free(cssData);
            return std.fmt.allocPrint(gpa, "<style>\n{s}\n</style>", .{cssData});
        },
        .external => {
            const href = try model.relativeHref(gpa, ownPath, "style.css", false);
            defer gpa.free(href);
            return std.fmt.allocPrint(gpa, "<link rel=\"stylesheet\" href=\"{s}\">", .{href});
        },
    };
}

/// `{search}` template var: search box, shortcut-tips widget, and
/// `search.js` script tags. Empty for `--search off` or `--format md`.
fn searchBoxValue(gpa: std.mem.Allocator, fmt: Format, opts: options.Options, ownPath: []const u8, pageSourceMode: ?options.SourceMode) ![]u8 {
    if (!opts.search or fmt != .html) return gpa.dupe(u8, "");

    const indexHref = try model.relativeHref(gpa, ownPath, "search-index.js", false);
    defer gpa.free(indexHref);
    const scriptHref = try model.relativeHref(gpa, ownPath, "search.js", false);
    defer gpa.free(scriptHref);

    const showJumpTip = pageSourceMode != null and pageSourceMode.? == .tab;
    const jumpTipLine = if (showJumpTip) "<dl><dt><kbd class=Ku><span>U</span></kbd></dt><dd>Jump to source code</dd></dl>\n" else "";

    return std.fmt.allocPrint(gpa,
        \\<div class="fnd">
        \\<input type="text" id="fnd-i" class="fnd-i" placeholder="Search…" autocomplete="off" spellcheck="false">
        \\<input type="checkbox" id="tips-tog" class="tips-tog">
        \\<label for="tips-tog" class="tip" tabindex="0"><kbd class="tip"><span>?</span></kbd></label>
        \\<div class="tips-box">
        \\<label for="tips-tog" class="tips-x" aria-label="Close tips">&times;</label>
        \\<strong>Shortcut keys</strong>
        \\<dl><dt><kbd class="KQ"><span>?</span></kbd></dt><dd>Show these tips</dd></dl>
        \\<dl><dt><kbd class="Ks"><span>S</span></kbd></dt><dd>Focus search field</dd></dl>
        \\<dl><dt><kbd class="KE"><span>Esc</span></kbd></dt><dd>Clear focus &amp; close tips</dd></dl>
        \\{s}<dl><dt><kbd class="KU"><span>&uarr;</span></kbd></dt><dd>Move up in search results</dd></dl>
        \\<dl><dt><kbd class="KD"><span>&darr;</span></kbd></dt><dd>Move down in search results</dd></dl>
        \\<dl><dt><kbd class="KR"><span>&crarr;</span></kbd></dt><dd>Go to active search result</dd></dl>
        \\</div>
        \\<div id="fnd-res" class="fnd-res" hidden></div>
        \\</div>
        \\<script src="{s}" defer></script>
        \\<script src="{s}" defer></script>
    , .{ jumpTipLine, indexHref, scriptHref });
}

/// Maps a file's `fileLabel` to the slug its page (and, under
/// `--split item`, its decls' folder) is built from, resolving
/// collisions with sibling files/directories. Built once per `write()`
/// call so every page's filename agrees on where a file's page lives.
pub const Registry = struct {
    slugs: std.StringHashMap([]const u8),
    declSegments: std.StringHashMap([]const u8),
    /// Maps a section's `path` (e.g. `"root.hash_map.AutoHashMap"`) to
    /// its resolved decl path (e.g. `"hash_map/AutoHashMap"`), so
    /// `pageFilename` can resolve an `aliasTargetPath` directly.
    declPathsByPath: std.StringHashMap([]const u8),

    pub fn deinit(self: *Registry, gpa: std.mem.Allocator) void {
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
        var it3 = self.declPathsByPath.iterator();
        while (it3.next()) |e| {
            gpa.free(@constCast(e.key_ptr.*));
            gpa.free(e.value_ptr.*);
        }
        self.declPathsByPath.deinit();
    }

    /// Registered slug for `fileLabel`, or its `.zig`-stripped form if unregistered.
    pub fn slugFor(self: Registry, fileLabel: []const u8) []const u8 {
        return self.slugs.get(fileLabel) orelse model.stripZigExt(fileLabel);
    }

    /// Registered path segment for `name` under `parentDeclPath`, or
    /// `null` if unseen (single-page mode).
    pub fn declSegmentFor(self: Registry, gpa: std.mem.Allocator, parentDeclPath: []const u8, name: []const u8) !?[]const u8 {
        const key = try declSegmentKey(gpa, parentDeclPath, name);
        defer gpa.free(key);
        return self.declSegments.get(key);
    }

    /// Registered slug for a top-level whole-file-wrapper section.
    /// Always freshly allocated, unlike `slugFor`.
    pub fn slugForFileSection(self: Registry, gpa: std.mem.Allocator, section: model.Section) ![]u8 {
        if (section.fileLabel.len > 0) return gpa.dupe(u8, self.slugFor(section.fileLabel));
        if (try self.declSegmentFor(gpa, "", section.name)) |segment| return gpa.dupe(u8, segment);
        return model.filenameSegment(gpa, section.name);
    }
};

/// Joins `parentDeclPath` and `name` into one unambiguous map key.
fn declSegmentKey(gpa: std.mem.Allocator, parentDeclPath: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}\x00{s}", .{ parentDeclPath, name });
}

/// Builds `sections`' `Registry`. Also walks into every decl's own
/// children (whatever `--split item`'s recursion will later append
/// segments onto) so two sibling decls whose names only differ by
/// case — a real collision on a case-insensitive filesystem — are
/// resolved once, up front, the same way two files already are.
pub fn buildRegistry(gpa: std.mem.Allocator, sections: []const model.Section, fmt: Format, opts: options.Options) !Registry {
    var reg = Registry{ .slugs = std.StringHashMap([]const u8).init(gpa), .declSegments = std.StringHashMap([]const u8).init(gpa), .declPathsByPath = std.StringHashMap([]const u8).init(gpa) };
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

/// Populates `reg.declPathsByPath` (`pageFilename`'s alias lookup)
/// from `pages`. Must run after `buildRegistry` and `buildPageIndex`.
fn populateAliasTable(gpa: std.mem.Allocator, reg: *Registry, pages: *const PageIndex) !void {
    // Only aliases whose target owns its own page (no anchor) get an
    // entry — an inlined target must resolve via sectionHref instead.
    var it = pages.byPath.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.anchor.len != 0) continue;
        const key = try gpa.dupe(u8, e.key_ptr.*);
        errdefer gpa.free(key);
        const value = try gpa.dupe(u8, e.value_ptr.page);
        errdefer gpa.free(value);
        try reg.declPathsByPath.put(key, value);
    }
}

/// Resolves sibling decls under `parentDeclPath` into unique,
/// case-insensitive-safe path segments, then recurses into each decl's
/// own children.
fn buildDeclSegments(gpa: std.mem.Allocator, siblings: []const model.Section, parentDeclPath: []const u8, fmt: Format, reg: *Registry) !void {
    if (siblings.len == 0) return;

    var claimedLower = std.StringHashMap(void).init(gpa);
    defer {
        var it = claimedLower.iterator();
        while (it.next()) |e| gpa.free(@constCast(e.key_ptr.*));
        claimedLower.deinit();
    }

    for (siblings) |s| {
        if (s.docOnly) continue;
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
        const value = try gpa.dupe(u8, candidate);
        errdefer gpa.free(value);
        const existing = try reg.declSegments.fetchPut(key, value);
        if (existing) |kv| {
            // fetchPut keeps the original key; free the passed-in one.
            gpa.free(kv.value);
            gpa.free(key);
        }

        const childParentPath = if (parentDeclPath.len == 0)
            try gpa.dupe(u8, candidate)
        else
            try std.fmt.allocPrint(gpa, "{s}/{s}", .{ parentDeclPath, candidate });
        defer gpa.free(childParentPath);

        try buildDeclSegments(gpa, s.children, childParentPath, fmt, reg);
    }
}

/// Lowercased form of what `segment` becomes on disk — a folder or a
/// flat file — so siblings only collide on their real output names.
fn outputNameLower(gpa: std.mem.Allocator, segment: []const u8, hasChildren: bool, fmt: Format) ![]u8 {
    const named = if (hasChildren)
        try std.fmt.allocPrint(gpa, "{s}/", .{segment})
    else
        try std.fmt.allocPrint(gpa, "{s}{s}", .{ segment, fmt.ext() });
    defer gpa.free(named);
    return std.ascii.allocLowerString(gpa, named);
}

/// Resolves every file's slug at one directory level, then recurses.
/// Subdirectories claim their names first, then files resolve
/// candidate slugs against what's claimed, falling back to a numbered
/// suffix until unique.
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

/// `--dirurls off`, `--split item`, HTML only: a file's decls live in
/// a same-named folder with no `index.html` of its own, so visiting it
/// directly would show a raw directory listing. Writes a meta-refresh
/// stub there pointing at the file's real page.
fn writeOrphanRedirects(ctx: Ctx, pages: *std.ArrayList(Page), sections: []const model.Section) !void {
    if (ctx.fmt != .html or ctx.opts.split != .item) return;
    const gpa = ctx.gpa;
    for (sections) |section| {
        if (!section.isWholeFileWrapper() or section.children.len == 0) continue;

        const flatPath = try pageFilename(gpa, ctx.fmt, section, "", ctx.opts, ctx.registry);
        defer gpa.free(flatPath);
        const folder = try ctx.registry.slugForFileSection(gpa, section);
        defer gpa.free(folder);
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

/// Single source of truth for what page (and in-page anchor, if any) a
/// section lives on. `Registry`, `SymbolIndex`, and nav-rendering read from
/// this instead of each re-deriving it independently.
pub const PageIndex = struct {
    /// Keyed by full dotted `Section.path`.
    byPath: std.StringHashMap(PageLocation),

    pub const PageLocation = struct {
        page: []const u8,
        /// `""` when this section owns its page outright.
        anchor: []const u8,
    };

    fn init(gpa: std.mem.Allocator) PageIndex {
        return .{ .byPath = std.StringHashMap(PageLocation).init(gpa) };
    }

    pub fn deinit(self: *PageIndex, gpa: std.mem.Allocator) void {
        var it = self.byPath.iterator();
        while (it.next()) |e| {
            gpa.free(@constCast(e.key_ptr.*));
            gpa.free(@constCast(e.value_ptr.page));
            if (e.value_ptr.anchor.len > 0) gpa.free(@constCast(e.value_ptr.anchor));
        }
        self.byPath.deinit();
    }

    pub fn get(self: *const PageIndex, path: []const u8) ?PageLocation {
        return self.byPath.get(path);
    }

    fn put(self: *PageIndex, gpa: std.mem.Allocator, path: []const u8, page: []const u8, anchor: []const u8) !void {
        if (self.byPath.contains(path)) return;
        const dupedKey = try gpa.dupe(u8, path);
        errdefer gpa.free(dupedKey);
        try self.byPath.put(dupedKey, .{ .page = try gpa.dupe(u8, page), .anchor = if (anchor.len == 0) "" else try gpa.dupe(u8, anchor) });
    }
};

/// Builds `PageIndex` for a whole tree. Runs once, before `Registry`'s
/// alias table and `SymbolIndex`, so both can depend on it.
pub fn buildPageIndex(gpa: std.mem.Allocator, fmt: Format, sections: []const model.Section, opts: options.Options, registry: ?Registry, singlePagePath: []const u8, rootModuleName: []const u8, rootSourceFile: []const u8) !PageIndex {
    var index = PageIndex.init(gpa);
    errdefer index.deinit(gpa);

    if (registry == null) {
        try indexSinglePageLocations(gpa, fmt, sections, singlePagePath, &index);
        try resolveAliasPageEntries(gpa, sections, &index);
        return index;
    }

    const rootPage = fmt.indexFilename();
    try index.put(gpa, rootModuleName, rootPage, "");

    if (opts.split == .file) {
        // Only a genuine @import boundary crossing gets its own page;
        // same-file nesting inlines onto the root's page.
        try indexInlinedLocations(gpa, fmt, sections, rootPage, rootSourceFile, opts, registry.?, "", &index, true);
        try resolveAliasPageEntries(gpa, sections, &index);
        return index;
    }

    for (sections) |file| {
        const fileDeclPath = try registry.?.slugForFileSection(gpa, file);
        defer gpa.free(fileDeclPath);
        const filePage = try pageFilenameForIndex(gpa, fmt, file, fileDeclPath, opts, registry.?);
        defer gpa.free(filePage);
        try index.put(gpa, file.path, filePage, "");
        try indexItemLocations(gpa, fmt, file.children, fileDeclPath, opts, registry.?, &index);
    }
    try resolveAliasPageEntries(gpa, sections, &index);
    return index;
}

/// Registers each alias section under a redirect to its real target's page,
/// so `hrefFor` doesn't send a codelink to a page `writeNode` never writes.
/// Must run after every non-alias section is already indexed.
fn resolveAliasPageEntries(gpa: std.mem.Allocator, sections: []const model.Section, index: *PageIndex) !void {
    for (sections) |s| {
        if (s.aliasTargetPath) |target| {
            if (index.get(target)) |loc| try index.put(gpa, s.path, loc.page, loc.anchor);
        }
        try resolveAliasPageEntries(gpa, s.children, index);
    }
}

fn indexSinglePageLocations(gpa: std.mem.Allocator, fmt: Format, sections: []const model.Section, page: []const u8, index: *PageIndex) !void {
    for (sections) |s| {
        if (s.docOnly) continue;
        if (s.aliasTargetPath != null) {
            try indexSinglePageLocations(gpa, fmt, s.children, page, index);
            continue;
        }
        const anchor = switch (fmt) {
            .html => try s.anchorSlug(gpa),
            .md => try s.anchorSlugMd(gpa),
        };
        defer gpa.free(anchor);
        try index.put(gpa, s.path, page, anchor);
        try indexSinglePageLocations(gpa, fmt, s.children, page, index);
    }
}

/// Mirrors the `isFileBoundary`-aware recursion `writeNode` uses to
/// split pages, so nav rendering and codelinks agree on where a
/// section actually lives. `atPageTop` resets true each time a
/// boundary is crossed onto a new page.
fn indexInlinedLocations(
    gpa: std.mem.Allocator,
    fmt: Format,
    sections: []const model.Section,
    page: []const u8,
    parentSourceFile: []const u8,
    opts: options.Options,
    registry: Registry,
    parentDeclPath: []const u8,
    index: *PageIndex,
    atPageTop: bool,
) !void {
    for (sections) |s| {
        if (s.docOnly) continue;
        if (s.aliasTargetPath != null) {
            try indexInlinedLocations(gpa, fmt, s.children, page, parentSourceFile, opts, registry, parentDeclPath, index, false);
            continue;
        }
        if (atPageTop and isFileBoundary(s, parentSourceFile)) {
            const declPath = if (s.isWholeFileWrapper())
                try registry.slugForFileSection(gpa, s)
            else
                try appendDeclPathSegment(gpa, parentDeclPath, s.name, registry);
            defer gpa.free(declPath);
            const childPage = try pageFilenameForIndex(gpa, fmt, s, declPath, opts, registry);
            defer gpa.free(childPage);
            try index.put(gpa, s.path, childPage, "");
            try indexInlinedLocations(gpa, fmt, s.children, childPage, s.sourceFile, opts, registry, declPath, index, true);
            continue;
        }
        const anchor = switch (fmt) {
            .html => try s.anchorSlug(gpa),
            .md => try s.anchorSlugMd(gpa),
        };
        defer gpa.free(anchor);
        try index.put(gpa, s.path, page, anchor);
        try indexInlinedLocations(gpa, fmt, s.children, page, parentSourceFile, opts, registry, parentDeclPath, index, false);
    }
}

fn indexItemLocations(gpa: std.mem.Allocator, fmt: Format, sections: []const model.Section, parentDeclPath: []const u8, opts: options.Options, registry: Registry, index: *PageIndex) !void {
    for (sections) |s| {
        if (s.docOnly) continue;
        const declPath = try appendDeclPathSegment(gpa, parentDeclPath, s.name, registry);
        defer gpa.free(declPath);
        if (s.aliasTargetPath != null) {
            try indexItemLocations(gpa, fmt, s.children, declPath, opts, registry, index);
            continue;
        }
        const page = try pageFilenameForIndex(gpa, fmt, s, declPath, opts, registry);
        defer gpa.free(page);
        try index.put(gpa, s.path, page, "");
        try indexItemLocations(gpa, fmt, s.children, declPath, opts, registry, index);
    }
}

/// `pageFilename`, minus alias resolution — used only while building
/// `PageIndex` itself, where consulting `PageIndex` would be
/// self-referential.
fn pageFilenameForIndex(gpa: std.mem.Allocator, fmt: Format, section: model.Section, ownDeclPath: []const u8, opts: options.Options, registry: Registry) ![]u8 {
    if (section.isWholeFileWrapper()) {
        const slug = if (ownDeclPath.len > 0) try gpa.dupe(u8, ownDeclPath) else try registry.slugForFileSection(gpa, section);
        defer gpa.free(slug);
        if (opts.dirUrls) return std.fmt.allocPrint(gpa, "{s}/{s}", .{ slug, fmt.indexFilename() });
        return std.fmt.allocPrint(gpa, "{s}{s}", .{ slug, fmt.ext() });
    }
    if (section.hasChildren or opts.dirUrls) return std.fmt.allocPrint(gpa, "{s}/{s}", .{ ownDeclPath, fmt.indexFilename() });
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ ownDeclPath, fmt.ext() });
}

/// Resolves `section`'s real href from `fromPage`. Delegates to
/// `pages` when available; the `null` fallback recomputes without
/// boundary-awareness (only used with `--codelinks off`). An alias
/// section is looked up by its target's path, not its own.
fn sectionHref(gpa: std.mem.Allocator, fmt: Format, section: model.Section, ownDeclPath: []const u8, fromPage: []const u8, opts: options.Options, registry: Registry, pages: ?*const PageIndex) ![]u8 {
    const lookupPath = section.aliasTargetPath orelse section.path;
    if (pages) |p| {
        if (p.get(lookupPath)) |loc| {
            if (loc.anchor.len == 0) {
                return model.relativeHref(gpa, fromPage, loc.page, fmt == .html and opts.prettyUrls);
            }
            if (std.mem.eql(u8, loc.page, fromPage)) {
                return std.fmt.allocPrint(gpa, "#{s}", .{loc.anchor});
            }
            const base = try model.relativeHref(gpa, fromPage, loc.page, fmt == .html and opts.prettyUrls);
            defer gpa.free(base);
            return std.fmt.allocPrint(gpa, "{s}#{s}", .{ base, loc.anchor });
        }
    }
    const target = try pageFilenameForIndex(gpa, fmt, section, ownDeclPath, opts, registry);
    defer gpa.free(target);
    return model.relativeHref(gpa, fromPage, target, fmt == .html and opts.prettyUrls);
}

/// Output-relative path for a section's own page. A whole-file wrapper uses
/// its registered slug as `<slug>/index<ext>` or `<slug><ext>` depending on
/// `opts.dirUrls`. An item-kind section uses `ownDeclPath` directly,
/// becoming a folder if it has children, else following `opts.dirUrls`
/// like the file case.
pub fn pageFilename(gpa: std.mem.Allocator, fmt: Format, section: model.Section, ownDeclPath: []const u8, opts: options.Options, registry: Registry) ![]u8 {
    if (section.aliasTargetPath) |targetPath| {
        if (registry.declPathsByPath.get(targetPath)) |realFilename| return gpa.dupe(u8, realFilename);
    }
    if (section.isWholeFileWrapper()) {
        const slug = if (ownDeclPath.len > 0) try gpa.dupe(u8, ownDeclPath) else try registry.slugForFileSection(gpa, section);
        defer gpa.free(slug);
        if (opts.dirUrls) return std.fmt.allocPrint(gpa, "{s}/{s}", .{ slug, fmt.indexFilename() });
        return std.fmt.allocPrint(gpa, "{s}{s}", .{ slug, fmt.ext() });
    }
    if (section.hasChildren or opts.dirUrls) return std.fmt.allocPrint(gpa, "{s}/{s}", .{ ownDeclPath, fmt.indexFilename() });
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ ownDeclPath, fmt.ext() });
}

/// Builds `parentDeclPath`'s child path for `name`, preferring the
/// registry's collision-resolved segment; falls back to computing one
/// directly when unregistered (single-page mode).
pub fn appendDeclPathSegment(gpa: std.mem.Allocator, parentDeclPath: []const u8, name: []const u8, registry: Registry) ![]u8 {
    if (try registry.declSegmentFor(gpa, parentDeclPath, name)) |segment| {
        if (parentDeclPath.len == 0) return gpa.dupe(u8, segment);
        return std.fmt.allocPrint(gpa, "{s}/{s}", .{ parentDeclPath, segment });
    }
    const segment = try model.filenameSegment(gpa, name);
    defer gpa.free(segment);
    if (parentDeclPath.len == 0) return gpa.dupe(u8, segment);
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ parentDeclPath, segment });
}

/// Maps a decl's full dotted path to the page (+ anchor) that
/// documents it, for `--codelinks`. Built once per `write()` call.
const SymbolIndex = struct {
    /// Authoritative: keyed by full dotted path, collision-free.
    pathTargets: std.StringHashMap(Target),
    /// Best-effort fallback keyed by bare unqualified name, for
    /// tokenizer-based source codelinks with no scope info to resolve a
    /// full path.
    bareNameTargets: std.StringHashMap(Target),
    /// Keyed on "<fromPage>\x00<path>". Owns both key and href;
    /// `hrefFor` hands out borrowed slices so a repeated name only
    /// pays for one relativeHref/allocPrint.
    hrefCache: std.StringHashMap([]const u8),

    const Target = struct { page: []const u8, anchor: []const u8 };

    fn init(gpa: std.mem.Allocator) SymbolIndex {
        return .{
            .pathTargets = std.StringHashMap(Target).init(gpa),
            .bareNameTargets = std.StringHashMap(Target).init(gpa),
            .hrefCache = std.StringHashMap([]const u8).init(gpa),
        };
    }

    fn deinit(self: *SymbolIndex, gpa: std.mem.Allocator) void {
        var it = self.pathTargets.iterator();
        while (it.next()) |e| {
            gpa.free(@constCast(e.key_ptr.*));
            gpa.free(@constCast(e.value_ptr.page));
            if (e.value_ptr.anchor.len > 0) gpa.free(@constCast(e.value_ptr.anchor));
        }
        self.pathTargets.deinit();

        var bareIt = self.bareNameTargets.iterator();
        while (bareIt.next()) |e| {
            gpa.free(@constCast(e.key_ptr.*));
            gpa.free(@constCast(e.value_ptr.page));
            if (e.value_ptr.anchor.len > 0) gpa.free(@constCast(e.value_ptr.anchor));
        }
        self.bareNameTargets.deinit();

        var cacheIt = self.hrefCache.iterator();
        while (cacheIt.next()) |e| {
            gpa.free(@constCast(e.key_ptr.*));
            gpa.free(@constCast(e.value_ptr.*));
        }
        self.hrefCache.deinit();
    }

    /// Resolves `path` to an href relative to `fromPage`, or `null`.
    /// Returned slice is owned by `self`.
    fn hrefFor(self: *SymbolIndex, gpa: std.mem.Allocator, path: []const u8, fromPage: []const u8, prettyUrls: bool) !?[]const u8 {
        return self.hrefForIn(gpa, &self.pathTargets, "p", path, fromPage, prettyUrls);
    }

    /// Like `hrefFor`, but resolves a bare unqualified name.
    fn hrefForBareName(self: *SymbolIndex, gpa: std.mem.Allocator, name: []const u8, fromPage: []const u8, prettyUrls: bool) !?[]const u8 {
        return self.hrefForIn(gpa, &self.bareNameTargets, "n", name, fromPage, prettyUrls);
    }

    // `tableTag` keeps the two tables' cache entries from colliding
    // when a bare name equals a full path.
    fn hrefForIn(self: *SymbolIndex, gpa: std.mem.Allocator, table: *std.StringHashMap(Target), tableTag: []const u8, key: []const u8, fromPage: []const u8, prettyUrls: bool) !?[]const u8 {
        const target = table.get(key) orelse return null;

        const cacheKey = try std.fmt.allocPrint(gpa, "{s}\x00{s}\x00{s}", .{ fromPage, tableTag, key });
        if (self.hrefCache.get(cacheKey)) |cached| {
            gpa.free(cacheKey);
            return cached;
        }
        errdefer gpa.free(cacheKey);

        const base = try model.relativeHref(gpa, fromPage, target.page, prettyUrls);
        const href = if (target.anchor.len == 0) base else blk: {
            defer gpa.free(base);
            break :blk try std.fmt.allocPrint(gpa, "{s}#{s}", .{ base, target.anchor });
        };
        errdefer gpa.free(href);

        try self.hrefCache.put(cacheKey, href);
        return href;
    }

    /// Registers a full dotted `path` at `page`/`anchor`. First wins.
    fn putPath(self: *SymbolIndex, gpa: std.mem.Allocator, path: []const u8, page: []const u8, anchor: []const u8) !void {
        try putInto(&self.pathTargets, gpa, path, page, anchor);
    }

    /// Registers a bare unqualified `name` in the best-effort fallback
    /// table. First wins.
    fn putBareName(self: *SymbolIndex, gpa: std.mem.Allocator, name: []const u8, page: []const u8, anchor: []const u8) !void {
        try putInto(&self.bareNameTargets, gpa, name, page, anchor);
    }

    fn putInto(table: *std.StringHashMap(Target), gpa: std.mem.Allocator, key: []const u8, page: []const u8, anchor: []const u8) !void {
        if (table.contains(key)) return;
        const dupedKey = try gpa.dupe(u8, key);
        errdefer gpa.free(dupedKey);
        try table.put(dupedKey, .{ .page = try gpa.dupe(u8, page), .anchor = if (anchor.len == 0) "" else try gpa.dupe(u8, anchor) });
    }
};

/// Bundles a `SymbolIndex` with the page it resolves links from, for
/// doc-comment prose and extracted signature/field/param text. The
/// tokenized-source path uses `CodelinkLookup` instead.
const SymbolLookup = struct {
    index: *SymbolIndex,
    gpa: std.mem.Allocator,
    fromPage: []const u8,
    prettyUrls: bool,
    /// This decl's own name — never links to itself.
    selfName: []const u8,

    fn resolve(context: *const anyopaque, name: []const u8) ?[]const u8 {
        const self: *const SymbolLookup = @ptrCast(@alignCast(context));
        if (std.mem.eql(u8, name, self.selfName)) return null;
        // OOM here can only mean "no link" — resolveFn isn't fallible.
        return self.index.hrefForBareName(self.gpa, name, self.fromPage, self.prettyUrls) catch null;
    }

    fn resolver(self: *const SymbolLookup) sources.ProseLinkResolver {
        return .{ .context = self, .resolveFn = resolve };
    }
};

/// Bundles a decl's own resolved `Section.codelinkTargets` with the
/// page it resolves links from. Only looks up byte ranges extraction
/// already resolved; never guesses from a token's bare text.
const CodelinkLookup = struct {
    index: *SymbolIndex,
    gpa: std.mem.Allocator,
    fromPage: []const u8,
    prettyUrls: bool,
    targets: []const model.CodelinkTarget,

    fn resolve(context: *const anyopaque, start: u32) ?sources.ResolvedSpan {
        const self: *const CodelinkLookup = @ptrCast(@alignCast(context));
        for (self.targets) |t| {
            if (t.start == start) {
                const href = self.index.hrefFor(self.gpa, t.targetPath, self.fromPage, self.prettyUrls) catch return null;
                return .{ .end = t.end, .href = href orelse return null };
            }
        }
        return null;
    }

    fn resolver(self: *const CodelinkLookup) sources.LinkResolver {
        return .{ .context = self, .resolveFn = resolve };
    }
};

/// Maps a file's `sourceFile` display path to its own file-root `Section`
/// — a real one built by extraction, or a synthetic stand-in at
/// `virtualRoot` for a root file with no wrapper of its own. `byModuleName`
/// covers Zig's package-name self-import (`@import("std")` from inside
/// `std` itself). `byDottedPath` covers `--discover ns`'s alias shortcuts:
/// a decl that's itself a cross-file re-export is built there as an empty
/// stand-in carrying only `aliasTargetPath`. Pointers borrow from
/// `tree`/`virtualRoot`; the index must not outlive either.
pub const FileRootIndex = struct {
    byPath: std.StringHashMap(*model.Section),
    byModuleName: std.StringHashMap(*model.Section),
    byDottedPath: std.StringHashMap(*model.Section),
    /// Keyed by bare basename, no directory — matches a filename mentioned
    /// in a comment or string literal. First occurrence wins on collision.
    byBasename: std.StringHashMap(*model.Section),
    /// Fallback for a bare `@import(X)` naming no real package
    /// `byModuleName` knows. Keyed by the name of any top-level decl that's
    /// itself nothing but a re-export. First occurrence wins on collision.
    byBareImportName: std.StringHashMap(*model.Section),

    pub fn deinit(self: *FileRootIndex) void {
        self.byPath.deinit();
        self.byModuleName.deinit();
        self.byDottedPath.deinit();
        self.byBasename.deinit();
        self.byBareImportName.deinit();
    }
};

pub fn buildFileRootIndex(gpa: std.mem.Allocator, tree: model.DocTree, virtualRoot: *model.Section) !FileRootIndex {
    var index: FileRootIndex = .{
        .byPath = std.StringHashMap(*model.Section).init(gpa),
        .byModuleName = std.StringHashMap(*model.Section).init(gpa),
        .byDottedPath = std.StringHashMap(*model.Section).init(gpa),
        .byBasename = std.StringHashMap(*model.Section).init(gpa),
        .byBareImportName = std.StringHashMap(*model.Section).init(gpa),
    };
    errdefer index.deinit();
    if (tree.sourceFile.len > 0) {
        virtualRoot.* = .{
            .name = tree.moduleName,
            .path = tree.moduleName,
            .signature = "",
            .docComment = "",
            .source = "",
            .sourceFile = tree.sourceFile,
            .sourceLine = 0,
            .children = tree.sections,
        };
        try index.byPath.put(tree.sourceFile, virtualRoot);
        try index.byModuleName.put(tree.moduleName, virtualRoot);
        try index.byDottedPath.put(tree.moduleName, virtualRoot);
        const rootBasename = std.fs.path.basename(tree.sourceFile);
        if (!index.byBasename.contains(rootBasename)) try index.byBasename.put(rootBasename, virtualRoot);
    }
    try indexBareAliases(tree.sections, &index.byBareImportName);
    try collectFileRoots(tree.sections, &index.byPath, &index.byBasename, &index.byBareImportName);
    try collectAllPaths(tree.sections, &index.byDottedPath);
    return index;
}

/// Registers every top-level decl in `children` that's itself nothing
/// but a re-export, keyed by its own name — see `FileRootIndex.byBareImportName`.
fn indexBareAliases(children: []model.Section, index: *std.StringHashMap(*model.Section)) !void {
    for (children, 0..) |_, i| {
        const c = &children[i];
        if (c.aliasTargetPath == null and c.pendingCodelinkTargets.len != 1) continue;
        if (!index.contains(c.name)) try index.put(c.name, c);
    }
}

/// Registers every section (not just file roots) under its own `.path`,
/// first occurrence wins on collision.
fn collectAllPaths(sections: []model.Section, index: *std.StringHashMap(*model.Section)) !void {
    for (sections, 0..) |_, i| {
        const s = &sections[i];
        if (!index.contains(s.path)) try index.put(s.path, s);
        try collectAllPaths(s.children, index);
    }
}

fn collectFileRoots(
    sections: []model.Section,
    byPath: *std.StringHashMap(*model.Section),
    byBasename: *std.StringHashMap(*model.Section),
    byBareImportName: *std.StringHashMap(*model.Section),
) !void {
    for (sections, 0..) |_, i| {
        const s = &sections[i];
        if (s.isFileRoot) {
            if (!byPath.contains(s.sourceFile)) try byPath.put(s.sourceFile, s);
            const basename = std.fs.path.basename(s.sourceFile);
            if (!byBasename.contains(basename)) try byBasename.put(basename, s);
            try indexBareAliases(s.children, byBareImportName);
        }
        try collectFileRoots(s.children, byPath, byBasename, byBareImportName);
    }
}

fn findChildByName(children: []model.Section, name: []const u8) ?*model.Section {
    for (children, 0..) |_, i| {
        if (std.mem.eql(u8, children[i].name, name)) return &children[i];
    }
    return null;
}

/// Resolves `child` one hop further if it's itself nothing but a
/// re-export — either a `.zig` alias (`aliasTargetPath`) or another
/// unresolved `@import` (a single pending target) — otherwise returns
/// `child` itself.
fn resolveAliasHop(
    gpa: std.mem.Allocator,
    child: *model.Section,
    fileRoots: *const FileRootIndex,
    depth: usize,
) error{OutOfMemory}!?*model.Section {
    return if (child.aliasTargetPath) |realPath|
        fileRoots.byDottedPath.get(realPath) orelse null
    else if (child.pendingCodelinkTargets.len == 1)
        try resolveImportChain(gpa, child.sourceFile, child.pendingCodelinkTargets[0], fileRoots, depth + 1)
    else
        child;
}

/// Resolves one cross-file reference (an `@import` string plus the dotted
/// path written after it) structurally: hops to the imported file via
/// `fileRoots`, then walks `remainingPath` one segment at a time through
/// `.children`, transparently hopping through any further re-export found
/// along the way. Never assumes a decl's `.path` reflects its position in
/// this chain — `--discover fs` paths are flat basenames unrelated to
/// import structure. Returns `null` when any hop can't be resolved.
fn resolveImportChain(
    gpa: std.mem.Allocator,
    fromFile: []const u8,
    target: model.PendingCodelinkTarget,
    fileRoots: *const FileRootIndex,
    depth: usize,
) error{OutOfMemory}!?*model.Section {
    if (depth > 64) return null; // guards against an import cycle
    var current: *model.Section = if (imports.isRelativeImport(target.importTarget)) blk: {
        const targetFile = imports.resolveImport(gpa, fromFile, target.importTarget) catch return null;
        defer gpa.free(targetFile);
        break :blk fileRoots.byPath.get(targetFile) orelse return null;
    } else if (fileRoots.byModuleName.get(target.importTarget)) |root|
        // Not a relative path: Zig's other `@import` form, the
        // package's own declared name (`@import("std")`, used inside
        // the standard library itself to reference its own root — not
        // an external dependency this tree could never see).
        root
    else blk: {
        // Some non-relative imports name a package that isn't (and
        // never can be) a real file in this tree — the compiler's
        // synthesized `@import("builtin")` chief among them. Fall back
        // to `byBareImportName`: wherever the tree itself re-exports
        // something under this exact name, however deep, is the
        // closest real target a reader clicking this link could mean.
        const child = fileRoots.byBareImportName.get(target.importTarget) orelse return null;
        break :blk try resolveAliasHop(gpa, child, fileRoots, depth) orelse return null;
    };

    var it = std.mem.splitScalar(u8, target.remainingPath, '.');
    while (it.next()) |segment| {
        if (segment.len == 0) continue;
        const child = findChildByName(current.children, segment) orelse return null;
        // `pendingCodelinkTargets` never changes after extraction — unlike
        // `codelinkTargets`, which this same pass may have already filled
        // in for `child` itself if the tree walk reached it first. Keying
        // off that would make the chase order-dependent on tree position.
        current = try resolveAliasHop(gpa, child, fileRoots, depth) orelse return null;
    }
    return current;
}

/// Resolves every `pendingCodelinkTargets` entry in `sections` (and their
/// children) via `resolveImportChain`, merging hits into `codelinkTargets`
/// alongside same-file references extraction already resolved. Also links
/// any other file's bare filename mentioned in a comment or string literal
/// (see `scanFilenameMentions`). Leaves unresolvable references unlinked.
pub fn resolvePendingCodelinks(gpa: std.mem.Allocator, sections: []model.Section, fileRoots: *const FileRootIndex) !void {
    for (sections, 0..) |_, i| {
        const s = &sections[i];
        try resolveSectionPendingCodelinks(gpa, s, fileRoots);
        try scanFilenameMentions(gpa, s, fileRoots);
        try resolvePendingCodelinks(gpa, s.children, fileRoots);
    }
}

/// Single-section body of `resolvePendingCodelinks`, without the recursion into
/// `children` — for a synthetic wrapper whose children were already resolved
/// separately (e.g. `rootSection`, which borrows `tree.sections`).
fn resolveSectionPendingCodelinks(gpa: std.mem.Allocator, s: *model.Section, fileRoots: *const FileRootIndex) !void {
    if (s.pendingCodelinkTargets.len == 0) return;
    var extra: std.ArrayList(model.CodelinkTarget) = .empty;
    defer extra.deinit(gpa);
    for (s.pendingCodelinkTargets) |p| {
        const target = try resolveImportChain(gpa, s.sourceFile, p, fileRoots, 0) orelse continue;
        try extra.append(gpa, .{ .start = p.start, .end = p.end, .targetPath = try gpa.dupe(u8, target.path) });
    }
    if (extra.items.len > 0) {
        const merged = try gpa.alloc(model.CodelinkTarget, s.codelinkTargets.len + extra.items.len);
        @memcpy(merged[0..s.codelinkTargets.len], s.codelinkTargets);
        @memcpy(merged[s.codelinkTargets.len..], extra.items);
        if (s.codelinkTargets.len > 0) gpa.free(s.codelinkTargets);
        s.codelinkTargets = merged;
    }
}

/// True for characters that can appear inside a filename mention (so a
/// match must be bounded by something else — whitespace, quotes,
/// punctuation) without themselves ending the match early. Deliberately
/// wider than a Zig identifier: filenames commonly include `.`, `-`, `/`.
fn isFilenameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c == '/';
}

/// Scans every string-literal and comment span in `s.source` for a
/// whole-word mention of another known file's bare basename, linking just
/// that substring to that file's page. Runs regardless of `--filetypes`,
/// matching any extension actually present in `fileRoots`, not just `.zig`.
fn scanFilenameMentions(gpa: std.mem.Allocator, s: *model.Section, fileRoots: *const FileRootIndex) !void {
    if (s.source.len == 0) return;
    const source = s.source;
    var extra: std.ArrayList(model.CodelinkTarget) = .empty;
    defer extra.deinit(gpa);

    const sentinelSource = try gpa.allocSentinel(u8, source.len, 0);
    defer gpa.free(sentinelSource);
    @memcpy(sentinelSource, source);

    var tokenizer = std.zig.Tokenizer.init(sentinelSource);
    var index: usize = 0;
    while (true) {
        const token = tokenizer.next();

        // Comments sit in the gap the tokenizer skips between tokens —
        // same detection `sources.writeTokensLinked` uses for highlighting.
        while (std.mem.indexOf(u8, source[index..token.loc.start], "//")) |off| {
            const commentStart = index + off;
            const newlineOff = std.mem.indexOfScalar(u8, source[commentStart..token.loc.start], '\n');
            const commentEnd = if (newlineOff) |o| commentStart + o else token.loc.start;
            try scanSpanForFilenames(gpa, s, source, commentStart, commentEnd, fileRoots, &extra);
            index = commentEnd;
        }

        if (token.tag == .eof) break;
        if (token.tag == .string_literal) {
            try scanSpanForFilenames(gpa, s, source, token.loc.start, token.loc.end, fileRoots, &extra);
        }
        index = token.loc.end;
    }

    if (extra.items.len > 0) {
        const merged = try gpa.alloc(model.CodelinkTarget, s.mentionTargets.len + extra.items.len);
        @memcpy(merged[0..s.mentionTargets.len], s.mentionTargets);
        @memcpy(merged[s.mentionTargets.len..], extra.items);
        if (s.mentionTargets.len > 0) gpa.free(s.mentionTargets);
        s.mentionTargets = merged;
    }
}

/// Searches `source[spanStart..spanEnd)` for whole-word basename matches
/// against `fileRoots.byBasename`, appending a resolved target for each —
/// skipping any span that overlaps a target `s` already has (e.g. an
/// `@import(...)` argument, already linked by `resolveSectionPendingCodelinks`).
fn scanSpanForFilenames(gpa: std.mem.Allocator, s: *const model.Section, source: []const u8, spanStart: usize, spanEnd: usize, fileRoots: *const FileRootIndex, extra: *std.ArrayList(model.CodelinkTarget)) !void {
    var i = spanStart;
    while (i < spanEnd) {
        if (!isFilenameChar(source[i])) {
            i += 1;
            continue;
        }
        const wordStart = i;
        while (i < spanEnd and isFilenameChar(source[i])) i += 1;
        var word = source[wordStart..i];
        var wordEnd = i;
        // A filename ending a sentence picks up the period as part of the
        // same run (`.` is a filename char); retry without it.
        if (!fileRoots.byBasename.contains(word) and word.len > 0 and word[word.len - 1] == '.') {
            word = word[0 .. word.len - 1];
            wordEnd -= 1;
        }
        if (overlapsExistingTarget(s, @intCast(wordStart), @intCast(wordEnd))) continue;
        if (fileRoots.byBasename.get(word)) |target| {
            try extra.append(gpa, .{
                .start = @intCast(wordStart),
                .end = @intCast(wordEnd),
                .targetPath = try gpa.dupe(u8, target.path),
            });
        }
    }
}

fn overlapsExistingTarget(s: *const model.Section, start: u32, end: u32) bool {
    for (s.codelinkTargets) |t| {
        if (start < t.end and t.start < end) return true;
    }
    for (s.mentionTargets) |t| {
        if (start < t.end and t.start < end) return true;
    }
    return false;
}

/// Concatenates a section's `codelinkTargets` (identifier/import references)
/// and `mentionTargets` (bare filename mentions) for full-`source` rendering
/// — the one context where both share an offset basis. Caller frees.
fn combineSourceTargets(gpa: std.mem.Allocator, section: model.Section) ![]model.CodelinkTarget {
    if (section.mentionTargets.len == 0) return gpa.dupe(model.CodelinkTarget, section.codelinkTargets);
    const combined = try gpa.alloc(model.CodelinkTarget, section.codelinkTargets.len + section.mentionTargets.len);
    @memcpy(combined[0..section.codelinkTargets.len], section.codelinkTargets);
    @memcpy(combined[section.codelinkTargets.len..], section.mentionTargets);
    return combined;
}

/// Returns how many leading bytes `extractSignature` trimmed from `source`
/// to produce `signature` — the shift a `source`-relative `codelinkTargets`
/// offset needs before it's valid against `signature` instead. Mirrors
/// `extractSignature`'s own `trimStart(u8, ..., " \t")`.
fn leadingTrimLen(source: []const u8) u32 {
    var i: usize = 0;
    while (i < source.len and (source[i] == ' ' or source[i] == '\t')) i += 1;
    return @intCast(i);
}

/// Walks `sections` registering each decl into `index`, mirroring how
/// `writeNode`/`writeSinglePage` route a decl to its own page.
fn buildSymbolIndex(
    gpa: std.mem.Allocator,
    fmt: Format,
    sections: []const model.Section,
    opts: options.Options,
    registry: ?Registry,
    singlePagePath: []const u8,
    rootModuleName: []const u8,
    pages: ?*const PageIndex,
) !SymbolIndex {
    _ = opts;
    _ = rootModuleName;
    var index = SymbolIndex.init(gpa);
    errdefer index.deinit(gpa);

    if (registry == null) {
        try indexSinglePage(gpa, fmt, sections, singlePagePath, &index);
        return index;
    }

    // Path-keyed entries are copied straight from PageIndex, the
    // single source of truth for where a section lives.
    if (pages) |p| {
        var it = p.byPath.iterator();
        while (it.next()) |e| {
            try index.putPath(gpa, e.key_ptr.*, e.value_ptr.page, e.value_ptr.anchor);
        }
    }

    for (sections) |file| {
        try index.putBareName(gpa, file.name, fmt.indexFilename(), "");
        try indexBareNames(gpa, fmt, file.children, &index);
    }
    return index;
}

/// Registers the bare-name (best-effort, tokenizer-fallback) side of
/// the index, looking each name's real page/anchor up in `pathTargets`
/// rather than registering a placeholder.
fn indexBareNames(gpa: std.mem.Allocator, fmt: Format, sections: []const model.Section, index: *SymbolIndex) !void {
    for (sections) |s| {
        if (index.pathTargets.get(s.path)) |target| {
            try index.putBareName(gpa, s.name, target.page, target.anchor);
        }
        try indexBareNames(gpa, fmt, s.children, index);
    }
}

fn indexSinglePage(gpa: std.mem.Allocator, fmt: Format, sections: []const model.Section, page: []const u8, index: *SymbolIndex) !void {
    for (sections) |s| {
        if (s.docOnly) continue;
        const anchor = switch (fmt) {
            .html => try s.anchorSlug(gpa),
            .md => try s.anchorSlugMd(gpa),
        };
        defer gpa.free(anchor);
        try index.putBareName(gpa, s.name, page, anchor);
        try index.putPath(gpa, s.path, page, anchor);
        try indexSinglePage(gpa, fmt, s.children, page, index);
    }
}

/// Output-relative path for a directory's own page: `<dirPath>/index<ext>`.
/// Splits `sections` into its immediate subdirectories and leaf files (one
/// level only, no recursion into subdirectories), rendering each as its own
/// linked list. Caller frees both returned slices.
fn renderDirGroupLists(gpa: std.mem.Allocator, fmt: Format, sections: []const model.Section, dirPath: []const u8, ownPath: []const u8, opts: options.Options, registry: Registry, pages: ?*const PageIndex) !struct { directories: []const u8, files: []const u8 } {
    const sorted = try gpa.dupe(model.Section, sections);
    defer gpa.free(sorted);
    model.sortByFileLabelOrder(sorted, toDirOrder(opts.dirOrder));
    const prefixLen = if (dirPath.len == 0) 0 else dirPath.len + 1;

    var dirNames: std.ArrayList([]const u8) = .empty;
    defer dirNames.deinit(gpa);
    var leaves: std.ArrayList(model.Section) = .empty;
    defer leaves.deinit(gpa);

    const Collector = struct {
        gpa: std.mem.Allocator,
        dirNames: *std.ArrayList([]const u8),
        leaves: *std.ArrayList(model.Section),
        fn onDir(c: @This(), name: []const u8, _: []const model.Section) !void {
            try c.dirNames.append(c.gpa, name);
        }
        fn onLeaf(c: @This(), s: model.Section) !void {
            try c.leaves.append(c.gpa, s);
        }
    };
    try model.forEachDirGroup(sorted, prefixLen, Collector{ .gpa = gpa, .dirNames = &dirNames, .leaves = &leaves }, Collector.onDir, Collector.onLeaf);

    var dirsAw: std.Io.Writer.Allocating = .init(gpa);
    defer dirsAw.deinit();
    if (dirNames.items.len > 0) {
        switch (fmt) {
            .html => try dirsAw.writer.writeAll("<ul>\n"),
            .md => {},
        }
        for (dirNames.items) |name| {
            const childDirPath = if (dirPath.len == 0) name else try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dirPath, name });
            defer if (dirPath.len > 0) gpa.free(childDirPath);
            const filename = try dirPageFilename(gpa, fmt, childDirPath);
            defer gpa.free(filename);
            const href = try model.relativeHref(gpa, ownPath, filename, fmt == .html and opts.prettyUrls);
            defer gpa.free(href);
            switch (fmt) {
                .html => try dirsAw.writer.print("<li><a class=\"index-dir\" href=\"{s}\">{s}/</a></li>\n", .{ href, name }),
                .md => try dirsAw.writer.print("- [{s}/]({s})\n", .{ name, href }),
            }
        }
        switch (fmt) {
            .html => try dirsAw.writer.writeAll("</ul>\n"),
            .md => {},
        }
    }

    var filesAw: std.Io.Writer.Allocating = .init(gpa);
    defer filesAw.deinit();
    if (leaves.items.len > 0) {
        try writeSectionIndex(gpa, fmt, &filesAw.writer, leaves.items, "", ownPath, opts, registry, true, pages, "");
    }

    return .{ .directories = try gpa.dupe(u8, dirsAw.written()), .files = try gpa.dupe(u8, filesAw.written()) };
}

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

/// The `{index}` content for any page with a section index. `linkOut`
/// (`true` in split mode) links a directory group and each decl out to
/// its own page; `false` (single-page mode) labels a directory group
/// without a link and links each decl to its own in-page anchor.
fn writeSectionIndex(gpa: std.mem.Allocator, fmt: Format, writer: *std.Io.Writer, sections: []const model.Section, dirPath: []const u8, ownPath: []const u8, opts: options.Options, registry: Registry, linkOut: bool, pages: ?*const PageIndex, parentSourceFile: []const u8) !void {
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
        try writePageLinkList(gpa, fmt, writer, sections, ownPath, "", ownPath, parentSourceFile, opts, registry, pages);
    } else {
        try writeInPageIndex(gpa, fmt, writer, sections, 0, opts.collapse, opts.showPub);
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

    const collapses = ctx.opts.collapse == .dir or ctx.opts.collapse == .all;
    if (!ctx.linkOut) {
        if (!collapses) {
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
    if (!collapses) {
        try ctx.writer.print("<li><a class=\"index-dir\" href=\"{s}\">{s}/</a>\n<ul>\n", .{ href, name });
    } else {
        try ctx.writer.print("<li><details><summary><span>{s}/</span></summary>\n<a class=\"index-dir\" href=\"{s}\">{s}/</a>\n<ul>\n", .{ name, href, name });
    }
}

fn htmlTreeOnDirEnd(ctx: *HtmlTreeCtx) !void {
    if (ctx.opts.collapse != .dir and ctx.opts.collapse != .all) {
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
        const slug = try s.anchorSlug(ctx.gpa);
        defer ctx.gpa.free(slug);
        try writeIndexItemOpen(ctx.gpa, ctx.writer, s, ctx.opts.showPub);
        try ctx.writer.print("<a href=\"#{s}\">{s}</a>", .{ slug, s.name });
        try writeInPageIndex(ctx.gpa, .html, ctx.writer, s.children, 1, ctx.opts.collapse, ctx.opts.showPub);
        try ctx.writer.writeAll("</li>\n");
        return;
    }

    const filename = try pageFilename(ctx.gpa, .html, s, "", ctx.opts, ctx.registry);
    defer ctx.gpa.free(filename);
    const href = try model.relativeHref(ctx.gpa, ctx.ownPath, filename, ctx.opts.prettyUrls);
    defer ctx.gpa.free(href);
    try writeIndexItemOpen(ctx.gpa, ctx.writer, s, ctx.opts.showPub);
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
        // Single-page mode: no directory page to link to.
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
        const slug = try s.anchorSlugMd(ctx.gpa);
        defer ctx.gpa.free(slug);
        try writeRepeated(ctx.writer, ' ', ctx.depth * 2);
        const target = try std.fmt.allocPrint(ctx.gpa, "#{s}", .{slug});
        defer ctx.gpa.free(target);
        try writeMdIndexLine(ctx.gpa, ctx.writer, s, s.name, target);
        try writeInPageIndex(ctx.gpa, .md, ctx.writer, s.children, ctx.depth + 1, .none, ctx.opts.showPub);
        return;
    }

    const filename = try pageFilename(ctx.gpa, .md, s, "", ctx.opts, ctx.registry);
    defer ctx.gpa.free(filename);
    const href = try model.relativeHref(ctx.gpa, ctx.ownPath, filename, false);
    defer ctx.gpa.free(href);
    try writeRepeated(ctx.writer, ' ', ctx.depth * 2);
    try writeMdIndexLine(ctx.gpa, ctx.writer, s, s.name, href);
}

/// Writes a flat `<ul>`/list of links, one per section, to that section's
/// own page. `docOnly` sections render unlinked with their doc comment
/// shown instead, since they have no page of their own.
pub fn writePageLinkList(gpa: std.mem.Allocator, fmt: Format, writer: *std.Io.Writer, sections: []const model.Section, fromPath: []const u8, parentDeclPath: []const u8, parentPage: []const u8, parentSourceFile: []const u8, opts: options.Options, registry: Registry, pages: ?*const PageIndex) !void {
    _ = parentPage;
    _ = parentSourceFile;
    if (sections.len == 0) return;
    if (fmt == .html) try writer.writeAll("<ul>\n");
    for (sections) |s| {
        var href: []const u8 = "";
        defer if (href.len > 0) gpa.free(href);
        if (!s.docOnly) {
            const ownDeclPath = if (s.isWholeFileWrapper()) try gpa.dupe(u8, "") else try appendDeclPathSegment(gpa, parentDeclPath, s.name, registry);
            defer gpa.free(ownDeclPath);
            href = try sectionHref(gpa, fmt, s, ownDeclPath, fromPath, opts, registry, pages);
        }

        switch (fmt) {
            .html => {
                try writeIndexItemOpen(gpa, writer, s, opts.showPub);
                if (s.docOnly) {
                    try writeEscapedHtml(writer, s.name);
                    if (s.docComment.len > 0) {
                        const rendered = try markdownToHtml(gpa, s.docComment, null);
                        defer gpa.free(rendered);
                        try writer.print("<div class=\"item-doc\">{s}</div>", .{rendered});
                    }
                    try writer.writeAll("</li>\n");
                } else {
                    try writer.print("<a href=\"{s}\">{s}</a></li>\n", .{ href, s.name });
                }
            },
            .md => {
                if (s.docOnly) {
                    const prefix = try mdIndexPrefix(gpa, s);
                    defer gpa.free(prefix);
                    if (prefix.len > 0) {
                        try writer.print("- {s} `{s}`\n", .{ prefix, s.name });
                    } else {
                        try writer.print("- `{s}`\n", .{s.name});
                    }
                    if (s.docComment.len > 0) try writer.print("  {s}\n", .{s.docComment});
                } else {
                    try writeMdIndexLine(gpa, writer, s, s.name, href);
                }
            },
        }
    }
    if (fmt == .html) try writer.writeAll("</ul>\n");
}

/// Whether `child`'s documented content crosses into a different file
/// than `parentSourceFile` (a `--discover ns` `@import` re-export),
/// rather than being an ordinary same-file nested decl. A type
/// function is never a boundary on its own.
fn isFileBoundary(child: model.Section, parentSourceFile: []const u8) bool {
    return !child.isTypeFunction and child.sourceFile.len > 0 and !std.mem.eql(u8, child.sourceFile, parentSourceFile);
}

fn collapsesFor(collapse: options.Collapse, kind: model.Kind, depth: usize) bool {
    return switch (collapse) {
        .none => false,
        .all => true,
        .top => depth == 0,
        .dir => kind == .file,
        .ns => kind == .namespace or kind == .namespace_decl,
    };
}

/// `writeInPageIndex`'s twin for `--split file`: a top-level child crossing
/// into a different file (`isFileBoundary`) gets its own page and links
/// out; every other child anchors in-page, even a nested boundary crossing.
/// `parentSourceFile` stays fixed at this page's top-level `sourceFile`, so
/// only depth-0 items are checked as boundaries.
fn writeInPageIndexNsAware(
    gpa: std.mem.Allocator,
    fmt: Format,
    writer: *std.Io.Writer,
    sections: []const model.Section,
    depth: usize,
    opts: options.Options,
    registry: Registry,
    ownPath: []const u8,
    ownDeclPath: []const u8,
    topSourceFile: []const u8,
    pages: ?*const PageIndex,
) !void {
    switch (fmt) {
        .html => {
            if (depth == 0 and sections.len == 0) return;
            try writer.writeAll("<ul>\n");
            for (sections) |s| {
                const childDeclPath = if (s.isWholeFileWrapper())
                    try registry.slugForFileSection(gpa, s)
                else
                    try appendDeclPathSegment(gpa, ownDeclPath, s.name, registry);
                defer gpa.free(childDeclPath);
                const href = try sectionHref(gpa, fmt, s, childDeclPath, ownPath, opts, registry, pages);
                defer gpa.free(href);
                const crossesPage = depth == 0 and isFileBoundary(s, topSourceFile);

                if (crossesPage) {
                    try writeIndexItemOpen(gpa, writer, s, opts.showPub);
                    try writer.print("<a href=\"{s}\">{s}</a></li>\n", .{ href, s.name });
                    continue;
                }
                if (s.children.len > 0 and collapsesFor(opts.collapse, s.kind, depth)) {
                    // Matches `htmlTreeOnDir`'s shape: the item's own
                    // link sits inside the `<details>`, right after
                    // `<summary>` and above the nested list — not
                    const label = try kindLabel(gpa, s);
                    defer if (s.raw) gpa.free(label);
                    const visClass = if (s.isPub) "item-pub" else "item-priv";
                    const prefixHtml = try indexItemPrefixHtml(gpa, s, opts.showPub);
                    defer gpa.free(prefixHtml);
                    try writer.print("<li class=\"item-{s} {s}\"><details><summary><span>{s}{s}</span></summary>\n{s}<a href=\"{s}\">{s}</a>\n", .{ label, visClass, prefixHtml, s.name, prefixHtml, href, s.name });
                    try writeInPageIndexNsAware(gpa, fmt, writer, s.children, depth + 1, opts, registry, ownPath, childDeclPath, topSourceFile, pages);
                    try writer.writeAll("</details></li>\n");
                    continue;
                }
                try writeIndexItemOpen(gpa, writer, s, opts.showPub);
                try writer.print("<a href=\"{s}\">{s}</a>", .{ href, s.name });
                if (s.children.len > 0) {
                    try writeInPageIndexNsAware(gpa, fmt, writer, s.children, depth + 1, opts, registry, ownPath, childDeclPath, topSourceFile, pages);
                }
                try writer.writeAll("</li>\n");
            }
            try writer.writeAll("</ul>\n");
        },
        .md => {
            for (sections) |s| {
                try writeRepeated(writer, ' ', depth * 2);
                const childDeclPath = if (s.isWholeFileWrapper())
                    try registry.slugForFileSection(gpa, s)
                else
                    try appendDeclPathSegment(gpa, ownDeclPath, s.name, registry);
                defer gpa.free(childDeclPath);
                const href = try sectionHref(gpa, fmt, s, childDeclPath, ownPath, opts, registry, pages);
                defer gpa.free(href);
                if (depth == 0 and isFileBoundary(s, topSourceFile)) {
                    try writeMdIndexLine(gpa, writer, s, s.name, href);
                    continue;
                }
                try writeMdIndexLine(gpa, writer, s, s.path, href);
                try writeInPageIndexNsAware(gpa, fmt, writer, s.children, depth + 1, opts, registry, ownPath, childDeclPath, topSourceFile, pages);
            }
        },
    }
}

/// In-page nested index for a `--split file` page's own decl tree, or
/// (via `writeSectionIndex`'s `linkOut = false` path) single-page
/// mode's whole index.
fn writeInPageIndex(gpa: std.mem.Allocator, fmt: Format, writer: *std.Io.Writer, sections: []const model.Section, depth: usize, collapse: options.Collapse, showPub: bool) !void {
    switch (fmt) {
        .html => {
            if (depth == 0 and sections.len == 0) return;
            try writer.writeAll("<ul>\n");
            for (sections) |s| {
                if (s.docOnly) continue;
                const slug = try s.anchorSlug(gpa);
                defer gpa.free(slug);
                if (s.children.len > 0 and collapsesFor(collapse, s.kind, depth)) {
                    const label = try kindLabel(gpa, s);
                    defer if (s.raw) gpa.free(label);
                    const visClass = if (s.isPub) "item-pub" else "item-priv";
                    const prefixHtml = try indexItemPrefixHtml(gpa, s, showPub);
                    defer gpa.free(prefixHtml);
                    try writer.print("<li class=\"item-{s} {s}\"><details><summary><span>{s}{s}</span></summary>\n{s}<a href=\"#{s}\">{s}</a>\n", .{ label, visClass, prefixHtml, s.name, prefixHtml, slug, s.name });
                    try writeInPageIndex(gpa, fmt, writer, s.children, depth + 1, collapse, showPub);
                    try writer.writeAll("</details></li>\n");
                    continue;
                }
                try writeIndexItemOpen(gpa, writer, s, showPub);
                try writer.print("<a href=\"#{s}\">{s}</a>", .{ slug, s.name });
                if (s.children.len > 0) {
                    try writeInPageIndex(gpa, fmt, writer, s.children, depth + 1, collapse, showPub);
                }
                try writer.writeAll("</li>\n");
            }
            try writer.writeAll("</ul>\n");
        },
        .md => {
            for (sections) |s| {
                if (s.docOnly) continue;
                const slug = try s.anchorSlugMd(gpa);
                defer gpa.free(slug);
                try writeRepeated(writer, ' ', depth * 2);
                const target = try std.fmt.allocPrint(gpa, "#{s}", .{slug});
                defer gpa.free(target);
                try writeMdIndexLine(gpa, writer, s, s.path, target);
                try writeInPageIndex(gpa, fmt, writer, s.children, depth + 1, collapse, showPub);
            }
        },
    }
}

// Below: leaf variable-to-string mapping for one htmldoc/mddoc page or
// one htmlsec/mdsec section.

/// Explicit mapping from `options.DirOrder` to `model.DirOrder`.
fn toDirOrder(order: options.DirOrder) model.DirOrder {
    return switch (order) {
        .first => .first,
        .last => .last,
        .alpha => .alpha,
    };
}

/// Kind slug for the nav prefix — describes the underlying declaration
/// shape, so a namespace-shaped struct reads as "struct" here.
fn navKindLabel(gpa: std.mem.Allocator, section: model.Section) ![]const u8 {
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
        .namespace => "namespace",
        .namespace_decl => "struct",
    };
}

/// Stable, lowercase, CSS-class-safe label for a section, exposed to
/// templates as `{kind}`. A `--filetypes` raw file gets `other-<ext>`
/// instead of plain `file`.
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
        .namespace => "namespace",
        .namespace_decl => "struct",
    };
}

/// Like `kindLabel`, but collapses a raw section's extension-specific label
/// (`other-md`) down to the bare `"other"`. Used for the `pkind-`/`dkind-`
/// page/section classes, which should group all non-zig files together;
/// `item-`/`decl-` classes use `kindLabel` directly to stay extension-specific.
fn genericKindLabel(gpa: std.mem.Allocator, section: model.Section) ![]const u8 {
    if (section.raw) return gpa.dupe(u8, "other");
    return kindLabel(gpa, section);
}

/// English `{page-type}` name for a `Section.kind`. Kept distinct per
/// `Kind` (not lumped into a generic "Type") so a stylesheet or
/// reader can tell a struct from an enum without parsing
/// `{page-classes}`.
fn pageTypeLabel(section: model.Section) []const u8 {
    if (section.raw) return "File";
    if (section.isTypeFunction) return "Type Function";
    return switch (section.kind) {
        .file => "File",
        .fn_decl => "Function",
        .var_decl => "Variable",
        .const_decl => "Constant",
        .struct_decl => "Struct",
        .enum_decl => "Enum",
        .union_decl => "Union",
        .opaque_decl => "Opaque",
        .namespace => "Namespace",
        .namespace_decl => "Namespace",
    };
}

/// `page-`/`decl-` class slug: `"type"` for anything type-shaped, else
/// the same slug as `{kind}`. `.namespace_decl` gets its own
/// `"namespace"` slug rather than the `"struct"` grouping `kindLabel` uses.
fn typeSlugLabel(gpa: std.mem.Allocator, section: model.Section) ![]const u8 {
    if (section.raw) return kindLabel(gpa, section);
    return switch (section.kind) {
        .struct_decl, .enum_decl, .union_decl, .opaque_decl => "type",
        .namespace_decl => "namespace",
        else => kindLabel(gpa, section),
    };
}

/// `{page-classes}` for a decl page: `page-<type-slug>` plus
/// `page-pub`/`page-priv`, and `zd-root` when `isRoot`. Caller owns
/// the returned slice.
fn pageClassesValue(gpa: std.mem.Allocator, section: model.Section, isRoot: bool) ![]u8 {
    const slug = try typeSlugLabel(gpa, section);
    defer if (section.raw) gpa.free(slug);
    const vis = if (!section.raw and (section.kind == .file or section.kind == .namespace)) "" else if (section.isPub) " page-pub" else " page-priv";
    if (isRoot) {
        return std.fmt.allocPrint(gpa, "page-{s}{s} zd-root", .{ slug, vis });
    }
    return std.fmt.allocPrint(gpa, "page-{s}{s}", .{ slug, vis });
}

/// `{decl-classes}` for a section: `decl-<type-slug>` plus
/// `decl-pub`/`decl-priv`, and `decl-root` when this is the page's own
/// decl rather than a nested child.
fn declClassesValue(gpa: std.mem.Allocator, section: model.Section, isPageRoot: bool) ![]u8 {
    const slug = try typeSlugLabel(gpa, section);
    defer if (section.raw) gpa.free(slug);
    const vis = if (!section.raw and (section.kind == .file or section.kind == .namespace)) "" else if (section.isPub) " decl-pub" else " decl-priv";
    const root = if (isPageRoot) " decl-root" else "";
    return std.fmt.allocPrint(gpa, "decl-{s}{s}{s}", .{ slug, vis, root });
}

/// `{nav-classes}` value: distinguishes `--itemorder` at render time.
fn navClassesValue(opts: options.Options) []const u8 {
    return switch (opts.itemOrder) {
        .code => "idx-code",
        .alpha => "idx-alpha",
        .grouped => "idx-grouped",
    };
}

/// The `<span class="prefix">...</span>` an index item shows — empty
/// for a plain whole-file wrapper, else `"pub {kind}"` or `"{kind}"`.
fn indexItemPrefixHtml(gpa: std.mem.Allocator, section: model.Section, showPub: bool) ![]u8 {
    if (section.raw or section.kind == .file or section.kind == .namespace) return gpa.dupe(u8, "");
    const label = try navKindLabel(gpa, section);
    if (showPub and section.isPub) return std.fmt.allocPrint(gpa, "<span class=\"prefix\">pub {s}</span> ", .{label});
    return std.fmt.allocPrint(gpa, "<span class=\"prefix\">{s}</span> ", .{label});
}

/// Writes an index `<li>`'s opening tag: `item-<kind>` class always,
/// plus `item-pub`/`item-priv` and a prefix label for anything but a
/// plain whole-file wrapper.
pub fn writeIndexItemOpen(gpa: std.mem.Allocator, writer: *std.Io.Writer, section: model.Section, showPub: bool) !void {
    const itemClass = try kindLabel(gpa, section);
    defer if (section.raw) gpa.free(itemClass);
    if (section.raw or section.kind == .file or section.kind == .namespace) {
        try writer.print("<li class=\"item-{s}\">", .{itemClass});
        return;
    }
    const label = try navKindLabel(gpa, section);
    const visClass = if (section.isPub) "item-pub" else "item-priv";
    if (showPub and section.isPub) {
        try writer.print("<li class=\"item-{s} {s}\"><span class=\"prefix\">pub {s}</span> ", .{ itemClass, visClass, label });
        return;
    }
    try writer.print("<li class=\"item-{s} {s}\"><span class=\"prefix\">{s}</span> ", .{ itemClass, visClass, label });
}

/// Markdown index-item kind prefix, e.g. `fn `. Empty for a plain
/// whole-file wrapper.
fn mdIndexPrefix(gpa: std.mem.Allocator, section: model.Section) ![]const u8 {
    if (section.raw or section.kind == .file or section.kind == .namespace) return gpa.dupe(u8, "");
    const label = try navKindLabel(gpa, section);
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
/// parser. `links`, when given, codelinks a qualified decl path
/// (e.g. `Foo.bar`) that's the *entire* content of an inline `` `code` ``
/// span — see `codelinkInlineCode`. Caller owns the returned slice.
fn markdownToHtml(gpa: std.mem.Allocator, text: []const u8, links: ?sources.ProseLinkResolver) ![]u8 {
    var parser = try markdown.Parser.init(gpa);
    defer parser.deinit();

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| try parser.feedLine(line);

    var doc = try parser.endInput();
    defer doc.deinit(gpa);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try doc.render(&aw.writer);
    const rendered = try aw.toOwnedSlice();

    const resolver = links orelse return rendered;
    defer gpa.free(rendered);
    return codelinkInlineCode(gpa, rendered, resolver);
}

/// Scans rendered HTML for inline `<code>...</code>` spans (never
/// `<pre><code>` blocks — those are fenced code, not the `` `x` ``
/// spans this targets) and, when a span's whole content resolves to a
/// documented decl, wraps it in a link. Leaves everything else
/// untouched, including spans that don't resolve — no dead links.
fn codelinkInlineCode(gpa: std.mem.Allocator, html: []const u8, links: sources.ProseLinkResolver) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();

    var i: usize = 0;
    while (i < html.len) {
        if (std.mem.startsWith(u8, html[i..], "<code>") and !std.mem.endsWith(u8, aw.written(), "<pre>")) {
            const contentStart = i + "<code>".len;
            if (std.mem.indexOf(u8, html[contentStart..], "</code>")) |closeOff| {
                const contentEnd = contentStart + closeOff;
                const content = html[contentStart..contentEnd];
                if (links.resolve(content)) |href| {
                    try aw.writer.writeAll("<code><a class=\"tok-l\" href=\"");
                    try writeEscapedAttrHtml(&aw.writer, href);
                    try aw.writer.writeAll("\">");
                    try aw.writer.writeAll(content);
                    try aw.writer.writeAll("</a></code>");
                } else {
                    try aw.writer.writeAll(html[i..contentEnd]);
                    try aw.writer.writeAll("</code>");
                }
                i = contentEnd + "</code>".len;
                continue;
            }
        }
        try aw.writer.writeByte(html[i]);
        i += 1;
    }
    return aw.toOwnedSlice();
}

/// HTML-attribute-escapes `text` (as `writeEscapedHtml`, plus `"`).
fn writeEscapedAttrHtml(writer: *std.Io.Writer, text: []const u8) !void {
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

/// Everything needed to render one `htmlsec`/`mdsec` section.
const SectionVars = struct {
    id: []const u8,
    name: []const u8,
    kind: []const u8,
    /// True only for a raw section's allocated "other-<ext>" label.
    kindOwned: bool,
    declType: []const u8,
    declVis: []const u8,
    declClasses: []const u8,
    path: []const u8,
    sig: []const u8,
    comment: []const u8,
    fieldsHeading: []const u8,
    fields: []const u8,
    paramsHeading: []const u8,
    params: []const u8,
    namespacesHeading: []const u8,
    namespaces: []const u8,
    structsHeading: []const u8,
    structs: []const u8,
    typesHeading: []const u8,
    types: []const u8,
    valuesHeading: []const u8,
    values: []const u8,
    functionsHeading: []const u8,
    functions: []const u8,
    errorsHeading: []const u8,
    errors: []const u8,
    testsHeading: []const u8,
    tests: []const u8,
    sourceHeading: []const u8,
    source: []const u8,
    fileHeading: []const u8,
    file: []const u8,
    directoriesHeading: []const u8,
    directories: []const u8,
    filesHeading: []const u8,
    files: []const u8,
    /// `--source tab`/`--pagesource tab` only: source pane HTML, kept
    /// separate from `source` since `writeTabShell` wraps it around
    /// the whole rendered template rather than a slot.
    tabSourceHtml: []const u8,

    pub fn deinit(self: *SectionVars, gpa: std.mem.Allocator) void {
        if (self.id.len > 0) gpa.free(self.id);
        if (self.kindOwned) gpa.free(self.kind);
        gpa.free(self.declClasses);
        gpa.free(self.name);
        gpa.free(self.path);
        if (self.sig.len > 0) gpa.free(self.sig);
        if (self.file.len > 0) gpa.free(self.file);
        if (self.directories.len > 0) gpa.free(self.directories);
        if (self.files.len > 0) gpa.free(self.files);
        if (self.comment.len > 0) gpa.free(self.comment);
        if (self.fields.len > 0) gpa.free(self.fields);
        if (self.params.len > 0) gpa.free(self.params);
        if (self.namespaces.len > 0) gpa.free(self.namespaces);
        if (self.structs.len > 0) gpa.free(self.structs);
        if (self.types.len > 0) gpa.free(self.types);
        if (self.values.len > 0) gpa.free(self.values);
        if (self.functions.len > 0) gpa.free(self.functions);
        if (self.errors.len > 0) gpa.free(self.errors);
        if (self.tests.len > 0) gpa.free(self.tests);
        if (self.source.len > 0) gpa.free(self.source);
        if (self.tabSourceHtml.len > 0) gpa.free(self.tabSourceHtml);
    }
};

/// Which `--show` bucket `child` belongs to, if any. A generic type
/// function goes to `.types` regardless of what its `kind` returns,
/// since it's a type constructor rather than a plain declaration.
fn childBucket(child: model.Section) ?options.ShowFlag {
    if (child.isTypeFunction) return .types;
    return switch (child.kind) {
        .namespace_decl => .namespaces,
        .struct_decl => .structs,
        .enum_decl, .union_decl, .opaque_decl => .types,
        .var_decl, .const_decl => .values,
        .fn_decl => .functions,
        .file, .namespace => null,
    };
}

/// Filters `section.children` to those in `bucket`, and if any match and
/// `opts.subheadings` is on, renders `heading` into `*headingOut`. Empty
/// input or no matches leaves both the returned content and heading empty.
fn renderChildKindIndex(gpa: std.mem.Allocator, fmt: Format, section: model.Section, opts: options.Options, ownPath: []const u8, registry: Registry, pages: ?*const PageIndex, bucket: options.ShowFlag, headingOut: *[]const u8, heading: []const u8, showDocComments: bool, links: ?sources.ProseLinkResolver) ![]const u8 {
    var matched: std.ArrayList(model.Section) = .empty;
    defer matched.deinit(gpa);
    for (section.children) |child| {
        if (childBucket(child) == bucket) try matched.append(gpa, child);
    }
    if (matched.items.len == 0) return "";
    if (opts.subheadings) headingOut.* = heading;

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeChildKindLinkList(gpa, fmt, &aw.writer, matched.items, ownPath, opts, registry, pages, showDocComments, links);
    return gpa.dupe(u8, aw.written());
}

/// Like `writePageLinkList`, but also renders each item's doc comment as a
/// short paragraph under its link, gated behind `showDocComments`.
/// `docOnly` entries render unlinked with the doc comment always shown.
fn writeChildKindLinkList(gpa: std.mem.Allocator, fmt: Format, writer: *std.Io.Writer, sections: []const model.Section, fromPath: []const u8, opts: options.Options, registry: Registry, pages: ?*const PageIndex, showDocComments: bool, links: ?sources.ProseLinkResolver) !void {
    if (sections.len == 0) return;
    if (fmt == .html) try writer.writeAll("<ul>\n");
    for (sections) |s| {
        var href: []const u8 = "";
        defer if (href.len > 0) gpa.free(href);
        if (!s.docOnly) {
            const ownDeclPath = if (s.isWholeFileWrapper()) try gpa.dupe(u8, "") else try appendDeclPathSegment(gpa, "", s.name, registry);
            defer gpa.free(ownDeclPath);
            href = try sectionHref(gpa, fmt, s, ownDeclPath, fromPath, opts, registry, pages);
        }
        const showDoc = showDocComments or s.docOnly;
        switch (fmt) {
            .html => {
                try writeIndexItemOpen(gpa, writer, s, opts.showPub);
                if (s.docOnly) {
                    try writeEscapedHtml(writer, s.name);
                } else {
                    try writer.print("<a href=\"{s}\">{s}</a>", .{ href, s.name });
                }
                if (showDoc and s.docComment.len > 0) {
                    const rendered = try markdownToHtml(gpa, s.docComment, links);
                    defer gpa.free(rendered);
                    try writer.print("<div class=\"item-doc\">{s}</div>", .{rendered});
                }
                try writer.writeAll("</li>\n");
            },
            .md => {
                if (s.docOnly) {
                    const prefix = try mdIndexPrefix(gpa, s);
                    defer gpa.free(prefix);
                    if (prefix.len > 0) {
                        try writer.print("- {s} `{s}`\n", .{ prefix, s.name });
                    } else {
                        try writer.print("- `{s}`\n", .{s.name});
                    }
                } else {
                    try writeMdIndexLine(gpa, writer, s, s.name, href);
                }
                if (showDoc and s.docComment.len > 0) try writer.print("  {s}\n", .{s.docComment});
            },
        }
    }
    if (fmt == .html) try writer.writeAll("</ul>\n");
}

/// Renders a page's `Functions` section. Under `--show funcsigs` each
/// function shows its signature and doc comment, like `renderFields`;
/// otherwise it's the plain link list any other child-kind index gets.
/// `funcsigs` trumps `functions` when both are shown (see `options.parseShow`).
fn renderFunctionsIndex(gpa: std.mem.Allocator, fmt: Format, section: model.Section, opts: options.Options, fromPage: []const u8, registry: Registry, pages: ?*const PageIndex, symbols: ?*SymbolIndex, fileRoots: ?*const FileRootIndex, headingOut: *[]const u8, links: ?sources.ProseLinkResolver) ![]const u8 {
    var matched: std.ArrayList(model.Section) = .empty;
    defer matched.deinit(gpa);
    for (section.children) |child| {
        if (childBucket(child) == .functions) try matched.append(gpa, child);
    }
    if (matched.items.len == 0) return "";
    if (opts.subheadings) headingOut.* = "Functions";

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    if (opts.shows(.funcsigs)) {
        try writeFuncSigList(gpa, fmt, &aw.writer, matched.items, fromPage, opts, registry, pages, symbols, fileRoots, links);
    } else {
        try writeChildKindLinkList(gpa, fmt, &aw.writer, matched.items, fromPage, opts, registry, pages, false, null);
    }
    return gpa.dupe(u8, aw.written());
}

/// `--show funcsigs` sibling of `writeChildKindLinkList`: each function's
/// signature (codelinked the same as its own decl page's `{sig}`) and doc
/// comment, instead of a plain link — except the function's own name in the
/// signature links to its docs, resolved the same way the plain link does.
/// `--omitdoc functions` entries (`s.docOnly`) still get an entry — the
/// signature renders with its name as plain text instead of a link.
fn writeFuncSigList(gpa: std.mem.Allocator, fmt: Format, writer: *std.Io.Writer, sections: []const model.Section, fromPage: []const u8, opts: options.Options, registry: Registry, pages: ?*const PageIndex, symbols: ?*SymbolIndex, fileRoots: ?*const FileRootIndex, links: ?sources.ProseLinkResolver) !void {
    if (sections.len == 0) return;
    if (fmt == .html) try writer.writeAll("<dl class=\"funcsigs\">\n");
    for (sections) |s| {
        var href: []const u8 = "";
        defer if (href.len > 0) gpa.free(href);
        if (!s.docOnly) {
            const ownDeclPath = if (s.isWholeFileWrapper()) try gpa.dupe(u8, "") else try appendDeclPathSegment(gpa, "", s.name, registry);
            defer gpa.free(ownDeclPath);
            href = try sectionHref(gpa, fmt, s, ownDeclPath, fromPage, opts, registry, pages);
        }
        const content = resolveFuncSigContent(s, fileRoots);
        switch (fmt) {
            .html => try writeFuncSigHtml(gpa, writer, content, href, symbols, fromPage, opts, links),
            .md => try writeFuncSigMd(gpa, writer, content, href),
        }
    }
    if (fmt == .html) try writer.writeAll("</dl>\n");
}

/// For a `funcsigs` entry that's itself only an alias stand-in (empty
/// `.signature`, `.aliasTargetPath` set), looks up the real decl it names
/// and uses its content instead. Falls back to `s` unchanged when there's
/// nothing to chase or the target isn't in `fileRoots`.
fn resolveFuncSigContent(s: model.Section, fileRoots: ?*const FileRootIndex) model.Section {
    if (s.signature.len > 0) return s;
    const targetPath = s.aliasTargetPath orelse return s;
    const roots = fileRoots orelse return s;
    const target = roots.byDottedPath.get(targetPath) orelse return s;
    return target.*;
}

/// One `funcsigs` entry, HTML. Collapses the signature to one line
/// (`writeFuncSigCompactHtml`) regardless of how it wraps on the decl's own
/// page, reusing the same codelink resolution as that page's `{sig}`, plus
/// one extra resolvable span for the function's own name (`findSigLayout`),
/// pointing at `href`.
fn writeFuncSigHtml(gpa: std.mem.Allocator, writer: *std.Io.Writer, s: model.Section, href: []const u8, symbols: ?*SymbolIndex, fromPage: []const u8, opts: options.Options, links: ?sources.ProseLinkResolver) !void {
    try writer.writeAll("<dt><pre><code>");
    if (s.signature.len > 0) {
        const sentinelSig = try gpa.allocSentinel(u8, s.signature.len, 0);
        defer gpa.free(sentinelSig);
        @memcpy(sentinelSig, s.signature);
        const layout = findSigLayout(sentinelSig) orelse SigLayout{ .nameStart = std.math.maxInt(u32), .nameEnd = 0, .paramsCloseStart = null };

        var lookupStorage: CodelinkLookup = undefined;
        var sigTargetsBuf: []model.CodelinkTarget = &.{};
        const inner: ?sources.LinkResolver = if (symbols) |idx| blk: {
            // See the matching shift in the decl-page `{sig}` path below:
            // `extractSignature` left-trims `source`'s leading indentation,
            // so a `codelinkTargets` offset needs the same shift here too.
            const shift = leadingTrimLen(s.source);
            sigTargetsBuf = try gpa.alloc(model.CodelinkTarget, s.codelinkTargets.len);
            var n: usize = 0;
            for (s.codelinkTargets) |t| {
                if (t.start < shift or t.end - shift > s.signature.len) continue;
                sigTargetsBuf[n] = .{ .start = t.start - shift, .end = t.end - shift, .targetPath = t.targetPath };
                n += 1;
            }
            lookupStorage = .{ .index = idx, .gpa = gpa, .fromPage = fromPage, .prettyUrls = opts.prettyUrls, .targets = sigTargetsBuf[0..n] };
            break :blk lookupStorage.resolver();
        } else null;
        defer gpa.free(sigTargetsBuf);

        var nameLookup: FuncSigNameLookup = .{
            .inner = inner,
            .nameStart = if (href.len > 0) layout.nameStart else std.math.maxInt(u32),
            .nameEnd = layout.nameEnd,
            .href = href,
        };
        try writeFuncSigCompactHtml(writer, sentinelSig, nameLookup.resolver(), layout);
    } else if (href.len > 0) {
        try writer.print("<a href=\"{s}\">", .{href});
        try writeEscapedHtml(writer, s.name);
        try writer.writeAll("</a>");
    } else {
        try writeEscapedHtml(writer, s.name);
    }
    try writer.writeAll("</code></pre></dt>\n");
    if (s.docComment.len > 0) {
        const rendered = try markdownToHtml(gpa, s.docComment, links);
        defer gpa.free(rendered);
        const ddClass = if (s.docCommentIsFallback) " class=\"doc-fallback\"" else "";
        try writer.print("<dd{s}>{s}</dd>\n", .{ ddClass, rendered });
    }
}

/// One `funcsigs` entry, Markdown. Collapses the signature to one line
/// (`compactSignaturePlain`), then splits it around the function name so
/// the name alone becomes `[name](href)`; the rest stays in backtick code
/// spans either side of it.
fn writeFuncSigMd(gpa: std.mem.Allocator, writer: *std.Io.Writer, s: model.Section, href: []const u8) !void {
    try writer.writeAll("- ");
    if (s.signature.len > 0) {
        const sentinelSig = try gpa.allocSentinel(u8, s.signature.len, 0);
        defer gpa.free(sentinelSig);
        @memcpy(sentinelSig, s.signature);
        if (findSigLayout(sentinelSig)) |layout| {
            const compact = try compactSignaturePlain(gpa, sentinelSig, layout);
            defer gpa.free(compact.text);
            const prefix = compact.text[0..compact.nameStart];
            const name = compact.text[compact.nameStart..compact.nameEnd];
            const suffix = compact.text[compact.nameEnd..];
            if (prefix.len > 0) try writer.print("`{s}`", .{prefix});
            if (href.len > 0) {
                try writer.print("[{s}]({s})", .{ name, href });
            } else {
                try writer.print("`{s}`", .{name});
            }
            if (suffix.len > 0) try writer.print("`{s}`", .{suffix});
        } else {
            try writer.print("`{s}`", .{s.signature});
        }
    } else if (href.len > 0) {
        try writer.print("[{s}]({s})", .{ s.name, href });
    } else {
        try writer.print("`{s}`", .{s.name});
    }
    // Trailing double-space forces a hard line break so the doc comment
    // starts a new line while staying inside this same list item, rather
    // than being soft-wrapped onto the signature's line by the renderer.
    if (s.docComment.len > 0) {
        try writer.writeAll("  \n  ");
        try writer.print("{s}\n", .{s.docComment});
    } else {
        try writer.writeAll("\n");
    }
}

/// Layout facts `writeFuncSigCompactHtml`/`compactSignaturePlain` need from
/// a signature: the function name's byte span, and, if a parameter list
/// follows, the byte offset of its closing `)` — the one place a
/// single-line signature needs a mandatory space before the return type.
const SigLayout = struct { nameStart: u32, nameEnd: u32, paramsCloseStart: ?u32 };

/// Finds `SigLayout` for `signature`. `null` for a malformed or nameless
/// signature (shouldn't happen for a named decl — callers fall back to "no
/// self-link, no forced space" rather than erroring).
fn findSigLayout(signature: [:0]const u8) ?SigLayout {
    var tokenizer = std.zig.Tokenizer.init(signature);
    var prevWasFn = false;
    var name: ?struct { start: u32, end: u32 } = null;
    while (name == null) {
        const token = tokenizer.next();
        if (token.tag == .eof) return null;
        if (prevWasFn and token.tag == .identifier) {
            name = .{ .start = @intCast(token.loc.start), .end = @intCast(token.loc.end) };
        }
        prevWasFn = token.tag == .keyword_fn;
    }
    const n = name.?;
    const open = tokenizer.next();
    if (open.tag != .l_paren) return .{ .nameStart = n.start, .nameEnd = n.end, .paramsCloseStart = null };
    var depth: usize = 1;
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => return .{ .nameStart = n.start, .nameEnd = n.end, .paramsCloseStart = null },
            .l_paren => depth += 1,
            .r_paren => {
                depth -= 1;
                if (depth == 0) return .{ .nameStart = n.start, .nameEnd = n.end, .paramsCloseStart = @intCast(token.loc.start) };
            },
            else => {},
        }
    }
}

/// Whether `writeFuncSigCompactHtml`/`compactSignaturePlain` should put a
/// space between two adjacent tokens when collapsing a signature to one
/// line. Tracks ordinary Zig formatting conventions for the narrow grammar
/// of a function signature (types, `!`/`?` prefixes, calls, generics,
/// slice/pointer modifiers) — not a general formatter.
fn compactSpaceBetween(prev: std.zig.Token.Tag, next: std.zig.Token.Tag) bool {
    switch (next) {
        .r_paren, .r_bracket, .r_brace, .comma, .semicolon, .period, .colon, .bang, .l_paren => return false,
        else => {},
    }
    switch (prev) {
        .l_paren, .l_bracket, .l_brace, .period, .bang, .question_mark, .asterisk, .ampersand, .r_bracket => return false,
        else => {},
    }
    return true;
}

/// Writes `source[layout.nameStart..layout.nameEnd]` and everything around
/// it, collapsed to one line: same codelink-resolved tokens as
/// `sources.writeTokensLinked`, but with `compactSpaceBetween` synthesizing
/// spacing, a trailing comma before a closing bracket dropped, and a
/// mandatory space forced after `layout.paramsCloseStart`. The function's
/// own name additionally gets `tok-fn` for separate styling.
fn writeFuncSigCompactHtml(writer: *std.Io.Writer, source: [:0]const u8, links: sources.LinkResolver, layout: SigLayout) !void {
    var tokenizer = std.zig.Tokenizer.init(source);
    var prevTag: ?std.zig.Token.Tag = null;
    var forceSpace = false;
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        if (token.tag == .doc_comment or token.tag == .container_doc_comment) continue;

        if (token.tag == .comma) {
            var lookahead = tokenizer;
            const after = lookahead.next();
            if (after.tag == .r_paren or after.tag == .r_bracket or after.tag == .r_brace) continue;
        }

        if (prevTag) |pt| {
            if (forceSpace or compactSpaceBetween(pt, token.tag)) try writer.writeByte(' ');
        }
        forceSpace = false;

        var peek = tokenizer;
        const nextTag = peek.next().tag;
        const isFnName = token.loc.start == layout.nameStart or (token.tag == .identifier and sources.isFnNameToken(prevTag, nextTag));

        if (token.tag == .identifier) {
            if (links.resolve(@intCast(token.loc.start))) |span| {
                const extraClass = if (token.loc.start == layout.nameStart) " tok-fn" else "";
                try writer.print("<a class=\"tok-l{s}\" href=\"", .{extraClass});
                try sources.writeEscapedAttr(writer, span.href);
                try writer.writeAll("\">");
                prevTag = try writeFuncSigCompactSpan(writer, source, &tokenizer, token, span.end, prevTag, layout);
                try writer.writeAll("</a>");
                continue;
            }
        }
        try writeFuncSigCompactToken(writer, source, token, isFnName);
        prevTag = token.tag;
        if (layout.paramsCloseStart) |pc| {
            if (token.loc.start == pc) forceSpace = true;
        }
    }
}

/// Writes `firstToken` plus every further token up through byte offset
/// `end`, compactly (see `writeFuncSigCompactHtml`) — the inside of a
/// multi-token linked span (e.g. `array_list.Aligned`). Returns the last
/// token's tag, so the caller's own spacing decision for whatever follows
/// the closing `</a>` stays correct. `prevTag` is the token immediately
/// before `firstToken` — used only for `firstToken`'s own function-name
/// check, never for spacing: the caller already wrote (or omitted) the
/// space before `firstToken` itself, outside the `<a>` this span sits in.
fn writeFuncSigCompactSpan(writer: *std.Io.Writer, source: [:0]const u8, tokenizer: *std.zig.Tokenizer, firstToken: std.zig.Token, end: u32, prevTag: ?std.zig.Token.Tag, layout: SigLayout) !std.zig.Token.Tag {
    var token = firstToken;
    var fnCheckPrev = prevTag;
    var spacingPrev: ?std.zig.Token.Tag = null;
    while (true) {
        if (spacingPrev) |pt| {
            if (compactSpaceBetween(pt, token.tag)) try writer.writeByte(' ');
        }
        var peek = tokenizer.*;
        const nextTag = peek.next().tag;
        const isFnName = token.loc.start == layout.nameStart or (token.tag == .identifier and sources.isFnNameToken(fnCheckPrev, nextTag));
        try writeFuncSigCompactToken(writer, source, token, isFnName);
        fnCheckPrev = token.tag;
        spacingPrev = token.tag;
        if (token.loc.end >= end or token.tag == .eof) break;
        token = tokenizer.next();
    }
    return fnCheckPrev.?;
}

/// Writes one already-tokenized token's text, syntax-highlighted, with no
/// link wrapping — `sources.zig`'s private `writeOneToken`, duplicated
/// here since compact mode's spacing rules mean it can't share that file's
/// token-walking loops, only its per-token escaping/classing.
fn writeFuncSigCompactToken(writer: *std.Io.Writer, source: [:0]const u8, token: std.zig.Token, isFnName: bool) !void {
    const text = source[token.loc.start..token.loc.end];
    if (sources.classFor(token.tag, text, isFnName)) |c| {
        try writer.print("<span class=\"{s}\">", .{c});
        try sources.writeEscaped(writer, text);
        try writer.writeAll("</span>");
    } else {
        try sources.writeEscaped(writer, text);
    }
}

/// Plain-text sibling of `writeFuncSigCompactHtml`, for Markdown: collapses
/// `source` to one line the same way (no HTML, no codelinks — Markdown
/// funcsigs never link anything but the function's own name), and reports
/// where `layout.nameStart..nameEnd` landed in the collapsed text so the
/// caller can split around it. Caller owns `.text`.
fn compactSignaturePlain(gpa: std.mem.Allocator, source: [:0]const u8, layout: SigLayout) !struct { text: []u8, nameStart: u32, nameEnd: u32 } {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    var tokenizer = std.zig.Tokenizer.init(source);
    var prevTag: ?std.zig.Token.Tag = null;
    var forceSpace = false;
    var outNameStart: u32 = 0;
    var outNameEnd: u32 = 0;
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        if (token.tag == .doc_comment or token.tag == .container_doc_comment) continue;

        if (token.tag == .comma) {
            var lookahead = tokenizer;
            const after = lookahead.next();
            if (after.tag == .r_paren or after.tag == .r_bracket or after.tag == .r_brace) continue;
        }

        if (prevTag) |pt| {
            if (forceSpace or compactSpaceBetween(pt, token.tag)) try aw.writer.writeByte(' ');
        }
        forceSpace = false;

        if (token.loc.start == layout.nameStart) outNameStart = @intCast(aw.written().len);
        try aw.writer.writeAll(source[token.loc.start..token.loc.end]);
        if (token.loc.start == layout.nameStart) outNameEnd = @intCast(aw.written().len);

        prevTag = token.tag;
        if (layout.paramsCloseStart) |pc| {
            if (token.loc.start == pc) forceSpace = true;
        }
    }
    return .{ .text = try aw.toOwnedSlice(), .nameStart = outNameStart, .nameEnd = outNameEnd };
}

/// `CodelinkLookup`-plus-one: resolves a signature's ordinary referenced-
/// symbol codelinks (`inner`, may be `null` under `--codelinks off`), plus
/// one extra always-resolvable span — the function's own name — linking to
/// `href` regardless of `inner`.
const FuncSigNameLookup = struct {
    inner: ?sources.LinkResolver,
    nameStart: u32,
    nameEnd: u32,
    href: []const u8,

    fn resolve(context: *const anyopaque, start: u32) ?sources.ResolvedSpan {
        const self: *const FuncSigNameLookup = @ptrCast(@alignCast(context));
        if (start == self.nameStart) return .{ .end = self.nameEnd, .href = self.href };
        if (self.inner) |inner| return inner.resolve(start);
        return null;
    }

    fn resolver(self: *const FuncSigNameLookup) sources.LinkResolver {
        return .{ .context = self, .resolveFn = resolve };
    }
};

/// Directory portion of `path`, including the trailing slash.
fn fileDirPortion(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| return path[0 .. slash + 1];
    return "";
}

/// Maps `options.TestsMode` onto `options.SourceMode` so `--tests`
/// content can reuse `sources.write`'s existing per-mode HTML markup.
fn testsSourceMode(mode: options.TestsMode) options.SourceMode {
    return switch (mode) {
        .none => .none,
        .collapsed => .collapsed,
        .resizable => .resizable,
        .inline_ => .inline_,
    };
}

/// One `--extras` item's content, uniform across fields, params, and
/// error members.
const ExtrasItem = struct {
    name: []const u8,
    typeText: []const u8 = "",
    /// Byte offset of `typeText`'s first character, relative to the
    /// owning `Section.source`'s start — see `model.Field.typeTextStart`.
    typeTextStart: u32 = 0,
    /// A field's `= <default>` initializer; empty for params/errors,
    /// and for fields that have none.
    defaultValueText: []const u8 = "",
    /// Byte offset of `defaultValueText`'s first character — same
    /// purpose as `typeTextStart`, see `model.Field.defaultValueTextStart`.
    defaultValueTextStart: u32 = 0,
    docComment: []const u8 = "",
    /// Wraps the rendered `<dd>` in a distinct class for fallback
    /// (plain `//`) comments vs real `///` doc comments.
    docCommentIsFallback: bool = false,
};

/// Shared renderer behind `renderFields`/`renderParams`/`renderErrors`.
/// `htmlTag`/`htmlClass` are the wrapping element and its class;
/// fields/errors pair each name with a `<dt>`/`<dd>`, params get one
/// flat `<li>` each with its doc comment nested inside instead. `links`
/// (bare-name) resolves `docComment` prose; `typeText`/`defaultValueText`
/// each resolve separately, by position, against `codelinkTargets`
/// filtered to their own range.
fn renderExtrasItems(gpa: std.mem.Allocator, fmt: Format, items: []const ExtrasItem, htmlTag: []const u8, htmlClass: []const u8, links: ?sources.ProseLinkResolver, codelinkTargets: []const model.CodelinkTarget, symbols: ?*SymbolIndex, fromPage: []const u8, prettyUrls: bool) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    switch (fmt) {
        .html => {
            try aw.writer.print("<{s} class=\"{s}\">\n", .{ htmlTag, htmlClass });
            const itemTag = if (std.mem.eql(u8, htmlTag, "dl")) "dt" else "li";
            for (items) |it| {
                try aw.writer.print("<{s}><code>", .{itemTag});
                if (it.name.len > 0) {
                    try writeHighlightedFragment(gpa, &aw.writer, it.name, null);
                    if (it.typeText.len > 0) try aw.writer.writeAll(": ");
                }
                if (it.typeText.len > 0) {
                    try writeExtrasFragment(gpa, &aw.writer, it.typeText, it.typeTextStart, codelinkTargets, symbols, fromPage, prettyUrls);
                }
                if (it.defaultValueText.len > 0) {
                    try aw.writer.writeAll(" = ");
                    try writeExtrasFragment(gpa, &aw.writer, it.defaultValueText, it.defaultValueTextStart, codelinkTargets, symbols, fromPage, prettyUrls);
                }
                if (it.docComment.len == 0) {
                    try aw.writer.print("</code></{s}>\n", .{itemTag});
                } else if (std.mem.eql(u8, htmlTag, "dl")) {
                    try aw.writer.print("</code></{s}>\n", .{itemTag});
                    const ddClass = if (it.docCommentIsFallback) " class=\"doc-fallback\"" else "";
                    try aw.writer.print("<dd{s}>", .{ddClass});
                    const rendered = try markdownToHtml(gpa, it.docComment, links);
                    defer gpa.free(rendered);
                    try aw.writer.writeAll(rendered);
                    try aw.writer.writeAll("</dd>\n");
                } else {
                    try aw.writer.writeAll("</code>");
                    const rendered = try markdownToHtml(gpa, it.docComment, links);
                    defer gpa.free(rendered);
                    const divClass = if (it.docCommentIsFallback) " class=\"item-doc doc-fallback\"" else " class=\"item-doc\"";
                    try aw.writer.print("<div{s}>{s}</div>", .{ divClass, rendered });
                    try aw.writer.print("</{s}>\n", .{itemTag});
                }
            }
            try aw.writer.print("</{s}>\n", .{htmlTag});
        },
        .md => {
            for (items) |it| {
                if (it.name.len > 0 and it.typeText.len > 0) {
                    try aw.writer.print("- `{s}: {s}`", .{ it.name, it.typeText });
                } else if (it.typeText.len > 0) {
                    try aw.writer.print("- `{s}`", .{it.typeText});
                } else {
                    try aw.writer.print("- `{s}`", .{it.name});
                }
                if (it.defaultValueText.len > 0) try aw.writer.print(" = `{s}`", .{it.defaultValueText});
                if (it.docComment.len > 0) try aw.writer.print(" — {s}", .{it.docComment});
                try aw.writer.writeAll("\n");
            }
            try aw.writer.writeAll("\n");
        },
    }
    return aw.toOwnedSlice();
}

/// Writes one `--extras` fragment (a field's type or default-value
/// text) with its own scope-aware codelinks: `codelinkTargets` filtered
/// down to `[fragmentStart, fragmentStart + fragment.len)` and shifted
/// to be relative to `fragment` itself.
fn writeExtrasFragment(gpa: std.mem.Allocator, writer: *std.Io.Writer, fragment: []const u8, fragmentStart: u32, codelinkTargets: []const model.CodelinkTarget, symbols: ?*SymbolIndex, fromPage: []const u8, prettyUrls: bool) !void {
    var lookupStorage: CodelinkLookup = undefined;
    var targetsBuf: []model.CodelinkTarget = &.{};
    defer gpa.free(targetsBuf);
    const fragmentLinks: ?sources.LinkResolver = if (symbols) |idx| blk: {
        targetsBuf = try gpa.alloc(model.CodelinkTarget, codelinkTargets.len);
        var n: usize = 0;
        for (codelinkTargets) |t| {
            if (t.start < fragmentStart) continue;
            if (t.end > fragmentStart + fragment.len) continue;
            targetsBuf[n] = .{ .start = t.start - fragmentStart, .end = t.end - fragmentStart, .targetPath = t.targetPath };
            n += 1;
        }
        lookupStorage = .{ .index = idx, .gpa = gpa, .fromPage = fromPage, .prettyUrls = prettyUrls, .targets = targetsBuf[0..n] };
        break :blk lookupStorage.resolver();
    } else null;
    try writeHighlightedFragment(gpa, writer, fragment, fragmentLinks);
}

/// Tokenizes and codelinks `text` (a field/param type-text fragment)
/// into `writer`, falling back to plain escaped text on allocation
/// failure. `links` resolves by token position within `text`, using
/// codelink targets filtered and shifted to that range by the caller,
/// so it correctly distinguishes e.g. two different types both
/// locally named `Self`.
fn writeHighlightedFragment(gpa: std.mem.Allocator, writer: *std.Io.Writer, text: []const u8, links: ?sources.LinkResolver) !void {
    const sentinel = gpa.allocSentinel(u8, text.len, 0) catch {
        try writeEscapedHtml(writer, text);
        return;
    };
    defer gpa.free(sentinel);
    @memcpy(sentinel, text);
    try sources.writeTokensLinked(writer, sentinel, links);
}

/// Renders `--extras` struct/union field content: one entry per field,
/// each showing its name, type, and (if present) doc comment.
fn renderFields(gpa: std.mem.Allocator, fmt: Format, fields: []const model.Field, links: ?sources.ProseLinkResolver, codelinkTargets: []const model.CodelinkTarget, symbols: ?*SymbolIndex, fromPage: []const u8, prettyUrls: bool) ![]const u8 {
    var items = try gpa.alloc(ExtrasItem, fields.len);
    defer gpa.free(items);
    for (fields, 0..) |f, i| items[i] = .{ .name = f.name, .typeText = f.typeText, .typeTextStart = f.typeTextStart, .defaultValueText = f.defaultValueText, .defaultValueTextStart = f.defaultValueTextStart, .docComment = f.docComment, .docCommentIsFallback = f.docCommentIsFallback };
    return renderExtrasItems(gpa, fmt, items, "dl", "fields", links, codelinkTargets, symbols, fromPage, prettyUrls);
}

/// Renders `--extras` function parameter content: one entry per
/// param, with its doc comment if present (see `model.Param`).
fn renderParams(gpa: std.mem.Allocator, fmt: Format, params: []const model.Param, links: ?sources.ProseLinkResolver, codelinkTargets: []const model.CodelinkTarget, symbols: ?*SymbolIndex, fromPage: []const u8, prettyUrls: bool) ![]const u8 {
    var items = try gpa.alloc(ExtrasItem, params.len);
    defer gpa.free(items);
    for (params, 0..) |p, i| items[i] = .{ .name = p.name, .typeText = p.typeText, .typeTextStart = p.typeTextStart, .docComment = p.docComment, .docCommentIsFallback = p.docCommentIsFallback };
    return renderExtrasItems(gpa, fmt, items, "ul", "params", links, codelinkTargets, symbols, fromPage, prettyUrls);
}

/// Renders `--extras` error-set member content: one entry per member,
/// with its doc comment if present. Error names have no `typeText`
/// (nothing to codelink), so `links` only matters for fields/params.
fn renderErrors(gpa: std.mem.Allocator, fmt: Format, errorMembers: []const model.ErrorMember) ![]const u8 {
    var items = try gpa.alloc(ExtrasItem, errorMembers.len);
    defer gpa.free(items);
    for (errorMembers, 0..) |e, i| items[i] = .{ .name = e.name, .docComment = e.docComment };
    return renderExtrasItems(gpa, fmt, items, "dl", "errors", null, &.{}, null, "", false);
}

/// Builds every variable for one section, in `fmt`'s form only.
/// `linked` controls whether `{id}`/`{path}` produce real anchors and
/// links (true) or bare text (false). `dirHref`/`locPrefix` describe
/// the link shown before `{file}`'s bare filename, or both empty
/// if nothing links there. `rootNameLen` is the doc root's own name
/// length, needed since it may itself contain a `.`.
fn buildSectionVars(
    gpa: std.mem.Allocator,
    fmt: Format,
    section: model.Section,
    opts: options.Options,
    headingLevel: u8,
    linked: bool,
    dirHref: []const u8,
    locPrefix: []const u8,
    symbols: ?*SymbolIndex,
    fromPage: []const u8,
    isPageRoot: bool,
    rootNameLen: usize,
    registry: Registry,
    pages: ?*const PageIndex,
    fileRoots: ?*const FileRootIndex,
) !SectionVars {
    _ = headingLevel;

    var id: []const u8 = "";
    if (linked) {
        const slug = try section.anchorSlug(gpa);
        defer gpa.free(slug);
        id = try gpa.dupe(u8, slug);
    }

    var pathAw: std.Io.Writer.Allocating = .init(gpa);
    defer pathAw.deinit();
    if (!section.isWholeFileWrapper()) {
        // Only the root segment may need a real href (--discover ns +
        // --split file puts it on a separate page).
        const effectiveRootLen = @min(rootNameLen, section.path.len);
        const rootHref = if (linked and symbols != null)
            try symbols.?.hrefFor(gpa, section.path[0..effectiveRootLen], fromPage, opts.prettyUrls)
        else
            null;
        switch (fmt) {
            .html => {
                if (linked) {
                    try model.writePathLinks(gpa, &pathAw.writer, section.path, rootNameLen, rootHref);
                } else {
                    try writeEscapedHtml(&pathAw.writer, section.path);
                }
            },
            .md => {
                if (linked) {
                    try model.writePathLinksMd(gpa, &pathAw.writer, section.path, rootNameLen, rootHref);
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
                var lookupStorage: CodelinkLookup = undefined;
                var sigTargetsBuf: []model.CodelinkTarget = &.{};
                const links: ?sources.LinkResolver = if (symbols) |idx| blk: {
                    // `extractSignature` left-trims leading indentation off
                    // `source` to produce `signature`, so a `codelinkTargets`
                    // offset (computed against `source`) needs the same
                    // shift before it's valid here — otherwise a target
                    // lands on whatever token is now sitting at its old,
                    // pre-trim position instead of the one it was meant for.
                    const shift = leadingTrimLen(section.source);
                    sigTargetsBuf = try gpa.alloc(model.CodelinkTarget, section.codelinkTargets.len);
                    var sigTargetsLen: usize = 0;
                    for (section.codelinkTargets) |t| {
                        if (t.start < shift or t.end - shift > section.signature.len) continue;
                        sigTargetsBuf[sigTargetsLen] = .{ .start = t.start - shift, .end = t.end - shift, .targetPath = t.targetPath };
                        sigTargetsLen += 1;
                    }
                    lookupStorage = .{ .index = idx, .gpa = gpa, .fromPage = fromPage, .prettyUrls = fmt == .html and opts.prettyUrls, .targets = sigTargetsBuf[0..sigTargetsLen] };
                    break :blk lookupStorage.resolver();
                } else null;
                defer gpa.free(sigTargetsBuf);
                try sources.writeTokensLinked(&aw.writer, sentinelSig, links);
                sig = try gpa.dupe(u8, aw.written());
            },
            .md => sig = try std.fmt.allocPrint(gpa, "`{s}`\n\n", .{section.signature}),
        }
    }

    const showFile = opts.shows(.file);
    const showLine = opts.shows(.linenum) and !section.isWholeFileWrapper();
    var fileHeading: []const u8 = "";
    var file: []const u8 = "";
    if (section.sourceFile.len > 0 and (showFile or showLine)) {
        if (opts.subheadings) fileHeading = "File";
        const sourceFileDirLen = if (dirHref.len > 0) fileDirPortion(section.sourceFile).len else 0;
        const dirPart = if (dirHref.len > 0) locPrefix else "";
        const leafPart = section.sourceFile[sourceFileDirLen..];

        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        switch (fmt) {
            .html => {
                if (showFile) {
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
                if (showFile) {
                    if (dirPart.len > 0) try aw.writer.print("[{s}]({s})", .{ dirPart, dirHref });
                    try aw.writer.writeAll(leafPart);
                }
                if (showFile and showLine) try aw.writer.writeAll(":");
                if (showLine) try aw.writer.print("{d}", .{section.sourceLine});
                if (section.raw) try aw.writer.print(" ({d} bytes)", .{section.sizeBytes});
            },
        }
        file = try gpa.dupe(u8, aw.written());
    }

    var extrasLookupStorage: SymbolLookup = undefined;
    const extrasLinks: ?sources.ProseLinkResolver = if (fmt == .html and symbols != null) blk: {
        extrasLookupStorage = .{ .index = symbols.?, .gpa = gpa, .fromPage = fromPage, .prettyUrls = opts.prettyUrls, .selfName = section.name };
        break :blk extrasLookupStorage.resolver();
    } else null;

    var comment: []const u8 = "";
    if (section.docComment.len > 0) {
        comment = switch (fmt) {
            .html => try markdownToHtml(gpa, section.docComment, extrasLinks),
            .md => try gpa.dupe(u8, section.docComment),
        };
        if (fmt == .html and section.docCommentIsFallback) {
            const wrapped = try std.fmt.allocPrint(gpa, "<div class=\"doc-fallback\">{s}</div>", .{comment});
            gpa.free(comment);
            comment = wrapped;
        }
    }

    var fieldsHeading: []const u8 = "";
    var fields: []const u8 = "";
    if (opts.shows(.fields) and section.fields.len > 0) {
        if (opts.subheadings) fieldsHeading = "Fields";
        fields = try renderFields(gpa, fmt, section.fields, extrasLinks, section.codelinkTargets, symbols, fromPage, opts.prettyUrls);
    }

    var paramsHeading: []const u8 = "";
    var params: []const u8 = "";
    if (opts.shows(.parameters) and section.params.len > 0) {
        if (opts.subheadings) paramsHeading = "Params";
        params = try renderParams(gpa, fmt, section.params, extrasLinks, section.codelinkTargets, symbols, fromPage, opts.prettyUrls);
    }

    var namespacesHeading: []const u8 = "";
    var namespaces: []const u8 = "";
    if (opts.shows(.namespaces)) {
        namespaces = try renderChildKindIndex(gpa, fmt, section, opts, fromPage, registry, pages, .namespaces, &namespacesHeading, "Namespaces", false, null);
    }

    var structsHeading: []const u8 = "";
    var structs: []const u8 = "";
    if (opts.shows(.structs)) {
        structs = try renderChildKindIndex(gpa, fmt, section, opts, fromPage, registry, pages, .structs, &structsHeading, "Structs", false, null);
    }

    var typesHeading: []const u8 = "";
    var types: []const u8 = "";
    if (opts.shows(.types)) {
        types = try renderChildKindIndex(gpa, fmt, section, opts, fromPage, registry, pages, .types, &typesHeading, "Types", false, null);
    }

    var valuesHeading: []const u8 = "";
    var values: []const u8 = "";
    if (opts.shows(.values)) {
        values = try renderChildKindIndex(gpa, fmt, section, opts, fromPage, registry, pages, .values, &valuesHeading, "Values", true, extrasLinks);
    }

    var functionsHeading: []const u8 = "";
    var functions: []const u8 = "";
    if (opts.shows(.functions) or opts.shows(.funcsigs)) {
        functions = try renderFunctionsIndex(gpa, fmt, section, opts, fromPage, registry, pages, symbols, fileRoots, &functionsHeading, extrasLinks);
    }

    var errorsHeading: []const u8 = "";
    var errors: []const u8 = "";
    if (opts.shows(.errorsets) and section.errors.len > 0) {
        if (opts.subheadings) errorsHeading = "Errors";
        errors = try renderErrors(gpa, fmt, section.errors);
    }

    var testsHeading: []const u8 = "";
    var tests: []const u8 = "";
    if (opts.tests != .none and section.testSource.len > 0) {
        if (opts.subheadings) testsHeading = "Tests";
        switch (fmt) {
            .html => {
                var aw: std.Io.Writer.Allocating = .init(gpa);
                defer aw.deinit();
                try sources.write(gpa, &aw.writer, section.testSource, testsSourceMode(opts.tests), false, null, 1);
                tests = try gpa.dupe(u8, aw.written());
            },
            .md => {
                tests = try std.fmt.allocPrint(gpa, "```zig\n{s}\n```\n\n", .{section.testSource});
            },
        }
    }

    var sourceHeading: []const u8 = "";
    var source: []const u8 = "";
    // opts.pageSource governs a whole-file wrapper section, plus any
    // section that's a page's sole item under --split item.
    const mode = if ((section.isWholeFileWrapper() and !section.raw) or isPageRoot) opts.pageSource else opts.source;
    // tab mode renders nothing into {source}; the source pane is
    // built and wrapped separately (see writeTabShell).
    var tabSourceHtml: []const u8 = "";
    if (section.isBinary) {
        // No heading, no source pane, no tab pane — nothing to show.
    } else if (section.source.len > 0 and mode != .none and mode != .tab) {
        if (opts.subheadings) sourceHeading = "Code";
        switch (fmt) {
            .html => {
                var aw: std.Io.Writer.Allocating = .init(gpa);
                defer aw.deinit();
                var lookupStorage: CodelinkLookup = undefined;
                var combinedBuf: []model.CodelinkTarget = &.{};
                const links: ?sources.LinkResolver = if (symbols) |idx| blk: {
                    combinedBuf = try combineSourceTargets(gpa, section);
                    lookupStorage = .{ .index = idx, .gpa = gpa, .fromPage = fromPage, .prettyUrls = fmt == .html and opts.prettyUrls, .targets = combinedBuf };
                    break :blk lookupStorage.resolver();
                } else null;
                defer gpa.free(combinedBuf);
                try sources.write(gpa, &aw.writer, section.source, mode, section.raw, links, section.sourceLine);
                source = try gpa.dupe(u8, aw.written());
            },
            .md => {
                const fence = if (section.raw) "" else "zig";
                source = try std.fmt.allocPrint(gpa, "```{s}\n{s}\n```\n\n", .{ fence, section.source });
            },
        }
    } else if (section.source.len > 0 and mode == .tab) {
        // HTML-only (options parsing rejects tab for --format md).
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        var lookupStorage: CodelinkLookup = undefined;
        var combinedBuf: []model.CodelinkTarget = &.{};
        const links: ?sources.LinkResolver = if (symbols) |idx| blk: {
            combinedBuf = try combineSourceTargets(gpa, section);
            lookupStorage = .{ .index = idx, .gpa = gpa, .fromPage = fromPage, .prettyUrls = fmt == .html and opts.prettyUrls, .targets = combinedBuf };
            break :blk lookupStorage.resolver();
        } else null;
        defer gpa.free(combinedBuf);
        try sources.write(gpa, &aw.writer, section.source, mode, section.raw, links, section.sourceLine);
        tabSourceHtml = try gpa.dupe(u8, aw.written());
    }

    const kind = try genericKindLabel(gpa, section);
    const name = switch (fmt) {
        .html => try gpa.dupe(u8, section.name),
        .md => try gpa.dupe(u8, section.path),
    };
    const declVis: []const u8 = if (!section.raw and (section.kind == .file or section.kind == .namespace)) "" else if (section.isPub) "Public" else "Private";
    const declClasses = try declClassesValue(gpa, section, isPageRoot);
    return .{
        .id = id,
        .name = name,
        .kind = kind,
        .kindOwned = section.raw,
        .declType = pageTypeLabel(section),
        .declVis = declVis,
        .declClasses = declClasses,
        .path = path,
        .sig = sig,
        .fileHeading = fileHeading,
        .file = file,
        .directoriesHeading = "",
        .directories = "",
        .filesHeading = "",
        .files = "",
        .comment = comment,
        .fieldsHeading = fieldsHeading,
        .fields = fields,
        .paramsHeading = paramsHeading,
        .params = params,
        .namespacesHeading = namespacesHeading,
        .namespaces = namespaces,
        .structsHeading = structsHeading,
        .structs = structs,
        .typesHeading = typesHeading,
        .types = types,
        .valuesHeading = valuesHeading,
        .values = values,
        .functionsHeading = functionsHeading,
        .functions = functions,
        .errorsHeading = errorsHeading,
        .errors = errors,
        .testsHeading = testsHeading,
        .tests = tests,
        .sourceHeading = sourceHeading,
        .source = source,
        .tabSourceHtml = tabSourceHtml,
    };
}

/// Wraps a rendered section (`wholeSectionHtml`) and its source pane
/// (`sourceHtml`) in a pure-CSS Doc/Source tab pair: two hidden radios
/// + labels, panes shown via the checked-radio sibling selector.
fn writeTabShell(gpa: std.mem.Allocator, wholeSectionHtml: []const u8, sourceHtml: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa,
        \\<div class="tabs">
        \\<input type="radio" name="tab" id="tab-doc" class="tab-i" checked>
        \\<label for="tab-doc" class="tab-label"><span>Doc</span></label>
        \\<input type="radio" name="tab" id="tab-src" class="tab-i">
        \\<label for="tab-src" class="tab-label"><span>Source</span></label>
        \\<div class="tab-panes">
        \\<div class="tab-pane tab-pane-doc">{s}</div>
        \\<div class="tab-pane tab-pane-source">{s}</div>
        \\</div>
        \\</div>
        \\<script>{s}</script>
    , .{ wholeSectionHtml, sourceHtml, tabDocScript });
}

/// Forces `#tab-doc` checked whenever the current hash names an
/// element inside the Doc pane. Runs on load and on every
/// `hashchange`, including a same-page anchor click with no reload.
const tabDocScript =
    \\{
    \\  let fix = (h = location.hash.slice(1), doc = document.getElementById('tab-doc')) =>
    \\    doc && h && (doc.checked = doc.parentElement.querySelector('.tab-pane-doc')?.querySelector('#' + CSS.escape(h)));
    \\  fix();
    \\  window.addEventListener('hashchange', fix);
    \\}
;

/// Renders a single section against `tpl`'s variable slots, with no
/// recursion into children.
fn renderOneSection(gpa: std.mem.Allocator, fmt: Format, tpl: []const u8, vars: SectionVars) ![]u8 {
    const padBlock: ?template.PadBlockFn = if (fmt == .md) template.padMdBlock else null;
    return template.render(gpa, tpl, &.{
        .{ .name = "id", .value = vars.id },
        .{ .name = "name", .value = vars.name },
        .{ .name = "kind", .value = vars.kind },
        .{ .name = "decl-type", .value = vars.declType },
        .{ .name = "decl-vis", .value = vars.declVis },
        .{ .name = "decl-classes", .value = vars.declClasses },
        .{ .name = "path", .value = vars.path },
        .{ .name = "sig", .value = vars.sig },
        .{ .name = "comment", .value = vars.comment },
        .{ .name = "fields-heading", .value = vars.fieldsHeading },
        .{ .name = "fields", .value = vars.fields },
        .{ .name = "params-heading", .value = vars.paramsHeading },
        .{ .name = "params", .value = vars.params },
        .{ .name = "namespaces-heading", .value = vars.namespacesHeading },
        .{ .name = "namespaces", .value = vars.namespaces },
        .{ .name = "structs-heading", .value = vars.structsHeading },
        .{ .name = "structs", .value = vars.structs },
        .{ .name = "types-heading", .value = vars.typesHeading },
        .{ .name = "types", .value = vars.types },
        .{ .name = "values-heading", .value = vars.valuesHeading },
        .{ .name = "values", .value = vars.values },
        .{ .name = "functions-heading", .value = vars.functionsHeading },
        .{ .name = "functions", .value = vars.functions },
        .{ .name = "errors-heading", .value = vars.errorsHeading },
        .{ .name = "errors", .value = vars.errors },
        .{ .name = "tests-heading", .value = vars.testsHeading },
        .{ .name = "tests", .value = vars.tests },
        .{ .name = "source-heading", .value = vars.sourceHeading },
        .{ .name = "source", .value = vars.source },
        .{ .name = "file-heading", .value = vars.fileHeading },
        .{ .name = "file", .value = vars.file },
        .{ .name = "directories-heading", .value = vars.directoriesHeading },
        .{ .name = "directories", .value = vars.directories },
        .{ .name = "files-heading", .value = vars.filesHeading },
        .{ .name = "files", .value = vars.files },
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
    symbols: ?*SymbolIndex,
    fromPage: []const u8,
    rootNameLen: usize,
    registry: Registry,
    pages: ?*const PageIndex,
    fileRoots: ?*const FileRootIndex,
) !void {
    // `--omitdoc`: no content block for this decl — it still has a listing
    // entry in its parent's list, just no page/anchor to point at here.
    // Any children (e.g. a docOnly const's own struct fields) go with it.
    if (section.docOnly) return;

    var vars = try buildSectionVars(gpa, fmt, section, opts, headingLevel, linked, dirHref, locPrefix, symbols, fromPage, false, rootNameLen, registry, pages, fileRoots);
    defer vars.deinit(gpa);

    const rendered = try renderOneSection(gpa, fmt, tpl, vars);
    defer gpa.free(rendered);
    try out.appendSlice(gpa, rendered);

    for (section.children) |child| {
        try renderSection(gpa, fmt, out, tpl, child, opts, headingLevel + 1, linked, dirHref, locPrefix, symbols, fromPage, rootNameLen, registry, pages, fileRoots);
    }
}

/// Writes a breadcrumb trail up to (not including) the current page.
/// `indexLabel` is the target page's own title. `ancestors` runs
/// outermost to innermost.
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
        try writer.writeAll("<span class=\"bc-sep\">&rsaquo;</span>");
        const href = try model.relativeHref(gpa, fromPath, a.target, prettyUrls);
        defer gpa.free(href);
        try writer.print("<a href=\"{s}\">{s}</a>", .{ href, a.name });
    }
    try writer.writeAll("<span class=\"bc-sep\">&rsaquo;</span>");
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