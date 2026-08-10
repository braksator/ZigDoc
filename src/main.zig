//! CLI entry point: parse args, extract, render, and write output.
const std = @import("std");
const options = @import("options.zig");
const extract = @import("extract.zig");
const model = @import("model.zig");
const render = @import("render.zig");
const style = @import("style.zig");
const template = @import("template.zig");
const progress_mod = @import("progress.zig");

/// Process entry point.
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    const opts = options.parseArgs(gpa, args[1..]) catch |err| {
        try printUsageError(err);
        std.process.exit(1);
    };
    defer gpa.free(opts.inputs);
    defer gpa.free(opts.OmitKind);
    defer gpa.free(opts.filetypes);

    run(gpa, init.io, opts) catch |err| {
        std.debug.print("zigdoc: error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

/// Reads the first input, extracts its `DocTree`, and dispatches to a
/// layout-specific writer.
fn run(gpa: std.mem.Allocator, io: std.Io, opts: options.Options) !void {
    if (opts.inputs.len == 0) return error.NoInputs;

    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }
    var labels: std.ArrayList([]const u8) = .empty;
    defer {
        for (labels.items) |l| gpa.free(l);
        labels.deinit(gpa);
    }
    var isZig: std.ArrayList(bool) = .empty;
    defer isZig.deinit(gpa);
    for (opts.inputs) |input| {
        try collectFiles(gpa, io, input, opts.filetypes, &paths, &labels, &isZig);
    }
    if (paths.items.len == 0) return error.NoInputs;

    var trees: std.ArrayList(model.DocTree) = .empty;
    defer {
        for (trees.items) |*t| t.deinit(gpa);
        trees.deinit(gpa);
    }
    var zigLabels: std.ArrayList([]const u8) = .empty;
    defer zigLabels.deinit(gpa); // borrows from `labels`, doesn't own
    var rawSections: std.ArrayList(model.Section) = .empty;
    defer {
        for (rawSections.items) |*s| model.freeSection(gpa, s);
        rawSections.deinit(gpa);
    }
    var progress: progress_mod.Progress = .{};
    for (paths.items, 0..) |path, i| {
        progress.update("documenting {s} ({d}/{d})", .{ labels.items[i], i + 1, paths.items.len });
        if (isZig.items[i]) {
            const source = try readFileSentinel(gpa, io, path);
            defer gpa.free(source);
            const moduleName = moduleNameFromPath(path);
            try trees.append(gpa, try extract.extractFile(gpa, moduleName, path, source, opts.recursive));
            try zigLabels.append(gpa, labels.items[i]);
        } else {
            const content = try readFileRaw(gpa, io, path);
            defer gpa.free(content);
            const moduleName = moduleNameFromPath(path);
            const display = try model.fileDisplayName(gpa, labels.items[i], opts.ext, opts.dir and !opts.tree);
            defer gpa.free(display);
            try rawSections.append(gpa, try model.rawFileSection(gpa, moduleName, display, labels.items[i], content));
        }
    }

    var tree = if (trees.items.len == 1 and rawSections.items.len == 0) blk: {
        // No merge, so no synthetic per-file wrapper — just the file's
        // own top-level decls. Still apply `--ext` to the page's own
        // title/heading for consistency with the merged case; there's
        // no directory to prefix and nothing to nest, so `--dir`/
        // `--tree` don't apply here.
        var t = trees.items[0];
        const display = try model.fileDisplayName(gpa, zigLabels.items[0], opts.ext, false);
        gpa.free(t.moduleName);
        t.moduleName = display;
        break :blk t;
    } else if (trees.items.len == 0 and rawSections.items.len == 1) blk: {
        // A single raw (non-`.zig`) file with nothing to merge against:
        // its own section becomes the page's sole top-level entry.
        const s = rawSections.items[0];
        rawSections.items.len = 0; // ownership moves into `tree.sections` below
        const sections = try gpa.alloc(model.Section, 1);
        sections[0] = s;
        break :blk model.DocTree{ .moduleName = try gpa.dupe(u8, s.name), .rootDocComment = null, .sections = sections };
    } else blk: {
        const rootLabel = try rootModuleName(gpa, io, opts.inputs[0]);
        defer gpa.free(rootLabel);
        const rootIsDir = pathIsDir(io, opts.inputs[0]);
        const rootName = if (rootIsDir)
            try std.fmt.allocPrint(gpa, "{s}/", .{rootLabel})
        else
            try gpa.dupe(u8, rootLabel);
        defer gpa.free(rootName);

        var merged = try model.mergeTrees(gpa, rootName, trees.items, zigLabels.items, opts.ext, opts.dir and !opts.tree);
        trees.items.len = 0; // ownership moved into `merged.sections` above

        if (rawSections.items.len > 0) {
            const combined = try gpa.alloc(model.Section, merged.sections.len + rawSections.items.len);
            @memcpy(combined[0..merged.sections.len], merged.sections);
            @memcpy(combined[merged.sections.len..], rawSections.items);
            gpa.free(merged.sections);
            merged.sections = combined;
            rawSections.items.len = 0; // ownership moved into `merged.sections` above
        }
        break :blk merged;
    };
    trees.items.len = 0; // ownership moved into `tree` above either way
    defer tree.deinit(gpa);
    model.sortSections(tree.sections, toSectionOrder(opts.itemOrder));
    if (opts.OmitKind.len > 0) {
        var excluded: std.ArrayList(model.OmitKind) = .empty;
        defer excluded.deinit(gpa);
        for (opts.OmitKind) |k| try excluded.append(gpa, toModelOmitKind(k));
        try model.filterSections(gpa, &tree.sections, excluded.items);
    }

    const title = if (opts.title) |t| try gpa.dupe(u8, t) else try guessTitle(gpa, io, opts.inputs[0]);
    defer gpa.free(title);

    var templates = try loadTemplates(gpa, io, opts);
    defer templates.deinit(gpa);

    if (opts.clear) try clearOutputDir(gpa, io, opts.out);

    try writeOutput(gpa, io, tree, title, opts, templates, &progress);
}

/// The four resolved template bodies for one run: either the
/// corresponding `--tpl-*` file's contents, or the matching
/// `template.zig` default constant when that option wasn't given. Only
/// the pair matching `opts.format` is ever actually used by a
/// renderer, but both are loaded unconditionally — reading a small
/// text file that then goes unused is cheap, and doing it this way
/// means a person can freely pass `--mddoctpl` alongside `--format
/// html` (say, in a shared build script invoked with different
/// `--format` values) without it being an error, per the "unused
/// tpl-* is just ignored" design.
const Templates = struct {
    htmlDoc: []const u8,
    htmlSec: []const u8,
    mdDoc: []const u8,
    mdSec: []const u8,
    ownedHtmlDoc: bool,
    ownedHtmlSec: bool,
    ownedMdDoc: bool,
    ownedMdSec: bool,

    fn deinit(self: *Templates, gpa: std.mem.Allocator) void {
        if (self.ownedHtmlDoc) gpa.free(self.htmlDoc);
        if (self.ownedHtmlSec) gpa.free(self.htmlSec);
        if (self.ownedMdDoc) gpa.free(self.mdDoc);
        if (self.ownedMdSec) gpa.free(self.mdSec);
    }
};

fn loadTemplates(gpa: std.mem.Allocator, io: std.Io, opts: options.Options) !Templates {
    var t: Templates = .{
        .htmlDoc = template.htmlDoc,
        .htmlSec = template.htmlSec,
        .mdDoc = template.mdDoc,
        .mdSec = template.mdSec,
        .ownedHtmlDoc = false,
        .ownedHtmlSec = false,
        .ownedMdDoc = false,
        .ownedMdSec = false,
    };
    errdefer t.deinit(gpa);

    if (opts.tplHtmlDoc) |path| {
        t.htmlDoc = try readTemplateFile(gpa, io, path);
        t.ownedHtmlDoc = true;
    }
    if (opts.tplHtmlSec) |path| {
        t.htmlSec = try readTemplateFile(gpa, io, path);
        t.ownedHtmlSec = true;
    }
    if (opts.tplMdDoc) |path| {
        t.mdDoc = try readTemplateFile(gpa, io, path);
        t.ownedMdDoc = true;
    }
    if (opts.tplMdSec) |path| {
        t.mdSec = try readTemplateFile(gpa, io, path);
        t.ownedMdSec = true;
    }
    return t;
}

fn readTemplateFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .unlimited, .of(u8), null);
}

/// Guesses a project title from the parent directory name of `path`
/// (e.g. `/home/me/myproject/src` → `myproject`). `path` is resolved to
/// an absolute path against the process cwd first, so a relative input
/// like `./src` or `src` (whose raw `dirname` is `.`, yielding a
/// basename of `.` rather than the actual containing directory) still
/// resolves correctly. Falls back to `path`'s own basename if the
/// resolved path has no parent component — in that fallback case the
/// guess is often just a bare name, which isn't a great title;
/// `--title` overrides this for exactly that situation.
fn guessTitle(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/\\");
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const abs = try std.fs.path.resolve(gpa, &.{ cwd, trimmed });
    defer gpa.free(abs);
    const dir = std.fs.path.dirname(abs) orelse return gpa.dupe(u8, std.fs.path.basename(abs));
    return gpa.dupe(u8, std.fs.path.basename(dir));
}

/// Walks `path` (or, if it's a single file, just records that file),
/// appending every file whose extension is in `filetypes` to `outPaths`
/// and, in the same order, each one's directory-relative label to
/// `outLabels` — the path relative to `path` itself (e.g.
/// `render/foo.zig` for a nested file, or just `foo.zig` for a bare
/// file input), always with `/` separators. `outLabels` is what
/// `--ext`/`--dir`/`--tree` format into a display name / index grouping
/// for a merged multi-file tree. `outIsZig[i]` says whether
/// `outPaths[i]` ends in `.zig` (parsed for decls) or is some other
/// `--filetypes` extension (shown as raw, unhighlighted content only).
fn collectFiles(gpa: std.mem.Allocator, io: std.Io, path: []const u8, filetypes: []const []const u8, outPaths: *std.ArrayList([]const u8), outLabels: *std.ArrayList([]const u8), outIsZig: *std.ArrayList(bool)) !void {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => {
            try outPaths.append(gpa, try normalizeLabelSlashes(gpa, stripDotSlash(path)));
            try outLabels.append(gpa, try gpa.dupe(u8, std.fs.path.basename(path)));
            try outIsZig.append(gpa, hasExtension(std.fs.path.basename(path), "zig"));
            return;
        },
        else => return err,
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const ext = matchExtension(entry.basename, filetypes) orelse continue;
        const dirPrefix = stripDotSlash(path);
        const fullRaw = if (dirPrefix.len == 0)
            try gpa.dupe(u8, entry.path)
        else
            try std.fs.path.join(gpa, &.{ dirPrefix, entry.path });
        defer gpa.free(fullRaw);
        const full = try normalizeLabelSlashes(gpa, fullRaw);
        errdefer gpa.free(full);
        try outPaths.append(gpa, full);
        try outLabels.append(gpa, try normalizeLabelSlashes(gpa, entry.path));
        try outIsZig.append(gpa, std.mem.eql(u8, ext, "zig"));
    }
}

/// Deletes existing `.html`/`.md` files under `path`, recursively, then
/// removes any directory left empty by that. No-op if `path` doesn't
/// exist yet.
fn clearOutputDir(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    var dirs: std.ArrayList([]const u8) = .empty;
    defer {
        for (dirs.items) |d| gpa.free(d);
        dirs.deinit(gpa);
    }

    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .file => {
                if (matchExtension(entry.basename, &.{ "html", "md" }) == null) continue;
                try dir.deleteFile(io, entry.path);
            },
            .directory => try dirs.append(gpa, try gpa.dupe(u8, entry.path)),
            else => {},
        }
    }

    std.mem.sort([]const u8, dirs.items, {}, longestPathFirst);
    for (dirs.items) |d| dir.deleteDir(io, d) catch |err| switch (err) {
        error.DirNotEmpty => {},
        else => return err,
    };
}

/// Sorts deepest paths first so `clearOutputDir` removes a directory's
/// children before the directory itself.
fn longestPathFirst(_: void, a: []const u8, b: []const u8) bool {
    return a.len > b.len;
}

/// Returns the matching entry of `filetypes` if `basename` ends with
/// `.` + that extension, else null.
fn matchExtension(basename: []const u8, filetypes: []const []const u8) ?[]const u8 {
    for (filetypes) |ext| {
        if (hasExtension(basename, ext)) return ext;
    }
    return null;
}

fn hasExtension(basename: []const u8, ext: []const u8) bool {
    if (basename.len < ext.len + 1) return false;
    return basename[basename.len - ext.len - 1] == '.' and
        std.mem.eql(u8, basename[basename.len - ext.len ..], ext);
}

/// Strips a single leading `./` (the display/location path should read
/// `src/foo.zig`, not `./src/foo.zig`, regardless of how the path was
/// given on the command line).
fn stripDotSlash(path: []const u8) []const u8 {
    if (std.mem.eql(u8, path, ".")) return "";
    if (std.mem.startsWith(u8, path, "./")) return path[2..];
    return path;
}

fn ensureDir(io: std.Io, path: []const u8) !void {
    std.Io.Dir.cwd().createDirPath(io, path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn warnIgnoredOptions(opts: options.Options) void {
    if (opts.format == .md and opts.theme != .auto) {
        std.debug.print("zigdoc: warning: --theme has no effect for --format md\n", .{});
    }
    if (opts.format == .md and !std.mem.eql(u8, opts.head, options.defaultHead)) {
        std.debug.print("zigdoc: warning: --head has no effect for --format md\n", .{});
    }
    if (opts.format == .md and opts.collapse != .dir) {
        std.debug.print("zigdoc: warning: --collapse has no effect for --format md\n", .{});
    }
    if (opts.format == .md and opts.css == .external) {
        std.debug.print("zigdoc: warning: --css external has no effect for --format md\n", .{});
    }
    if (opts.split == .none and !opts.extUrls) {
        std.debug.print("zigdoc: warning: --exturls has no effect for --split none\n", .{});
    }
    if (opts.split == .none and !opts.dirUrls) {
        std.debug.print("zigdoc: warning: --dirurls has no effect for --split none\n", .{});
    }
    if (opts.format == .md and opts.prettyUrls) {
        std.debug.print("zigdoc: warning: --prettyurls has no effect for --format md\n", .{});
    }
}

/// Renders `tree` to `opts.out` (creating it if needed) and writes
/// every resulting page — one file for `--split none` (named
/// `opts.filename`), or a directory of interlinked pages for
/// `--split file`/`item` (an always-present `index.<ext>`, one page
/// per input file or per documented declaration, and, when `--tree`
/// is on, a page per directory — every page named from its own
/// slug/qualified path; `--filename` is unused in this mode). Plus
/// `style.css` if `--css external`.
fn writeOutput(gpa: std.mem.Allocator, io: std.Io, tree: model.DocTree, title: []const u8, opts: options.Options, templates: Templates, progress: *progress_mod.Progress) !void {
    try ensureDir(io, opts.out);

    const pages = switch (opts.format) {
        .html => try render.write(gpa, .html, tree, title, opts, templates.htmlDoc, templates.htmlSec, progress),
        .md => try render.write(gpa, .md, tree, title, opts, templates.mdDoc, templates.mdSec, progress),
    };
    defer {
        for (pages) |*p| p.deinit(gpa);
        gpa.free(pages);
    }
    for (pages, 0..) |p, i| {
        progress.update("writing {s} ({d}/{d})", .{ p.filename, i + 1, pages.len });
        try writeOutFile(gpa, io, opts.out, p.filename, p.contents);
    }
    progress.clear();

    warnIgnoredOptions(opts);

    if (opts.css == .external and opts.format == .html) {
        const cssPath = try std.fs.path.join(gpa, &.{ opts.out, "style.css" });
        defer gpa.free(cssPath);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cssPath, .data = style.css(opts.theme) });
    }

    if (opts.split == .none) {
        const outPath = try std.fs.path.join(gpa, &.{ opts.out, opts.filename });
        defer gpa.free(outPath);
        std.debug.print("wrote {s}\n", .{outPath});
    } else {
        std.debug.print("wrote {s}/\n", .{opts.out});
    }
}

/// `filename` may include `/`-separated directory components — any
/// needed parent directories under `outDir` are created first.
fn writeOutFile(gpa: std.mem.Allocator, io: std.Io, outDir: []const u8, filename: []const u8, contents: []const u8) !void {
    const outPath = try std.fs.path.join(gpa, &.{ outDir, filename });
    defer gpa.free(outPath);
    if (std.fs.path.dirname(outPath)) |dir| {
        try ensureDir(io, dir);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = outPath, .data = contents });
}

/// Reads a file fully into a null-terminated buffer, as `Ast.parse` needs.
fn readFileSentinel(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .unlimited, .of(u8), 0);
}

/// Reads a non-`.zig` `--filetypes` file's raw content.
fn readFileRaw(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .unlimited, .of(u8), null);
}

/// Directory-relative labels (`Section.fileLabel`, what `--dir`/`--tree`
/// group and prefix with) are display strings, not real filesystem
/// paths — always `/`-separated regardless of OS, matching every place
/// that splits on it (`model.labelBasename`, `model.writeIndexTree`).
/// `std.Io.Dir.Walker`'s `entry.path` uses the OS's native separator
/// (`\` on Windows), so it needs normalizing before being stored as a
/// label; without this, `labelBasename`/`writeIndexTree` silently find
/// no `/` to split on and treat the whole OS-separated string as one
/// flat, unstrippable leaf name.
fn normalizeLabelSlashes(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const out = try gpa.dupe(u8, path);
    for (out) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return out;
}

/// Derives a module name from a file path's stem.
fn moduleNameFromPath(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    return std.fs.path.stem(base);
}

/// Like `moduleNameFromPath`, but for the merged root's own name, where
/// `path` may be `.` (or resolve to it) rather than a real file/dir
/// name. `moduleNameFromPath` alone can't handle that case — `.` has no
/// name of its own as a bare string — so it falls back to resolving the
/// real current-directory name via `path`.
fn rootModuleName(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const base = moduleNameFromPath(path);
    if (!std.mem.eql(u8, base, ".")) return gpa.dupe(u8, base);
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const abs = try std.fs.path.resolve(gpa, &.{ cwd, path });
    defer gpa.free(abs);
    return gpa.dupe(u8, std.fs.path.basename(abs));
}

/// Explicit, exhaustive mapping from `options.ItemOrder` to
/// `model.SectionOrder` — no reliance on the two enums sharing tag
/// order, since `model.zig` deliberately doesn't import `options.zig`.
fn toSectionOrder(order: options.ItemOrder) model.SectionOrder {
    return switch (order) {
        .code => .code,
        .alpha => .alpha,
        .grouped => .grouped,
    };
}

/// Explicit, exhaustive mapping from `options.OmitKind` to
/// `model.OmitKind` — same reasoning as `toSectionOrder`.
fn toModelOmitKind(k: options.OmitKind) model.OmitKind {
    return switch (k) {
        .fn_decl => .fn_decl,
        .var_decl => .var_decl,
        .const_decl => .const_decl,
        .struct_decl => .struct_decl,
        .enum_decl => .enum_decl,
        .union_decl => .union_decl,
        .opaque_decl => .opaque_decl,
    };
}

/// Whether `path` is a directory. Used to decide whether a merged
/// tree's root title (built from the CLI input path, not a file) gets
/// a trailing "/" — the same convention `--tree`'s index directory
/// headers use — to signal it's a directory rather than a file/module.
fn pathIsDir(io: std.Io, path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return false;
    dir.close(io);
    return true;
}

/// Prints an argument-parsing error alongside CLI usage.
fn printUsageError(err: options.ParseError) !void {
    std.debug.print(
        \\zigdoc: error: {s}
        \\
        \\usage: zigdoc [options] <input-path>...
        \\
        \\common:
        \\  --format html|md          (default: html)
        \\  --split none|file|item    (default: none)
        \\  --index on|off            (default: on)
        \\  --ext on|off              (default: on; multi-file input only)
        \\  --dir on|off              (default: on; multi-file input only)
        \\  --tree on|off             (default: on; multi-file input only)
        \\  --exturls on|off          (default: on; split modes only)
        \\  --dirurls on|off          (default: on; split modes only)
        \\  --filetypes <ext,...>     (default: zig; e.g. zig,md)
        \\  --itemorder code|alpha|grouped (default: code; recursive)
        \\  --dirorder first|last|alpha (default: first; multi-file input only)
        \\  --out <dir>               (default: zigdoc)
        \\  --filename <name>         (default: index.html for html, index.md for md; --split none only)
        \\  --title <name>            (default: guessed from the input path's parent directory)
        \\  --rootname <name>         (default: derived from the input path)
        \\  --recursive on|off        (default: on)
        \\  --location on|off         (default: on)
        \\  --linenum on|off          (default: on)
        \\  --subheadings on|off      (default: off)
        \\  --breadcrumb on|off       (default: on; split modes only)
        \\  --prepend <html/md>       (default: none)
        \\  --append <html/md>        (default: none)
        \\  --desc <html/md>          (default: none)
        \\  --rootcomment <md>       (default: none; overrides root's {{comment}})
        \\  --htmldoctpl <path>      (default: built in; see README "Templating")
        \\  --htmlsectpl <path>      (default: built in; see README "Templating")
        \\  --mddoctpl <path>        (default: built in; see README "Templating")
        \\  --mdsectpl <path>        (default: built in; see README "Templating")
        \\
        \\html only:
        \\  --source none|collapsed|resizable|inline  (default: resizable)
        \\  --filesource none|collapsed|resizable|inline  (default: none)
        \\  --css embed|external      (default: embed)
        \\  --theme auto|light|dark   (default: auto)
        \\  --collapse dir|all|none   (default: dir)
        \\  --head <html>             (default: a self-contained favicon <link>)
        \\  --prettyurls on|off       (default: off)
        \\
        \\md only:
        \\  --source none|inline      (default: none)
        \\  --filesource none|inline  (default: none)
        \\
    , .{@errorName(err)});
}

test {
    // Pulls every imported module's own test blocks (and, transitively,
    // theirs) into this file's test set, so `zig build test` rooted
    // here covers all of `src/`.
    std.testing.refAllDecls(@This());
}
